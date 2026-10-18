const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const wake = @import("ziggurat_wake");
const Watchdog = @import("watchdog.zig").Watchdog;

const Probe = struct {
    calls: usize = 0,
    fn fire(context: *anyopaque, _: *wake.OneShot, _: wake.Token) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
    fn stop(_: *anyopaque) !void {}
};
fn creationFailure(allocator: std.mem.Allocator) !void {
    const app = try z.App.initWithOptions(allocator, .{ .stop_capacity = 1 });
    defer app.deinit();
    var probe: Probe = .{};
    var full: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
    _ = try app.registerStop(&full);
    const callback: wake.Callback = .{ .context = &probe, .fire = Probe.fire };
    try std.testing.expectError(error.Full, wake.OneShot.create(app, allocator, callback, .{}));
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
    var fault: std.testing.FailingAllocator = .init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, wake.OneShot.create(app, fault.allocator(), callback, .{}));
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}
fn foreignThread(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    const timer = try wake.OneShot.create(app, allocator, .{ .context = &probe, .fire = Probe.fire }, .{});
    defer _ = timer.close() catch unreachable;
    const Worker = struct {
        timer: *wake.OneShot,
        rejected: bool = false,
        fn run(self: *@This()) void {
            _ = self.timer.armAfter(0) catch |err| {
                if (err != error.WrongThread) return;
                _ = self.timer.stats() catch |next| {
                    if (next != error.WrongThread) return;
                    _ = self.timer.close() catch |last| {
                        self.rejected = last == error.WrongThread;
                        return;
                    };
                    return;
                };
                return;
            };
        }
    };
    var worker: Worker = .{ .timer = timer };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expect(worker.rejected and !(try timer.stats()).armed);
}
fn takenStop(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    const timer = try wake.OneShot.create(app, allocator, .{ .context = &probe, .fire = Probe.fire }, .{});
    _ = try timer.armAfter(1);
    const Taken = struct {
        timer: *wake.OneShot,
        checked: bool = false,
        fn stop(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectError(error.StopInProgress, self.timer.close());
            self.checked = true;
        }
    };
    var taken: Taken = .{ .timer = timer };
    var node: z.StopParticipant = .{ .context = &taken, .stop = Taken.stop };
    _ = try app.registerStop(&node);
    app.quit();
    try app.finishShutdown();
    try std.testing.expect(taken.checked and (try timer.stats()).stopped);
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
    try std.testing.expectEqual(wake.CloseResult.closed, try timer.close());
}
const Hook = struct {
    backing: std.mem.Allocator,
    target: ?*wake.OneShot = null,
    quit_on_allocate: ?*z.App = null,
    shutdown_on_free: ?*z.App = null,
    failure: *?anyerror,
    checked: *bool,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn allocate(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.quit_on_allocate) |app| {
            self.quit_on_allocate = null;
            app.quit();
        }
        return self.backing.rawAlloc(len, alignment, ret);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.target) |target| {
            self.target = null;
            std.testing.expectError(error.Closed, target.stats()) catch |err| {
                self.failure.* = err;
            };
            std.testing.expectError(error.Closed, target.close()) catch |err| {
                self.failure.* = err;
            };
            self.checked.* = true;
            if (self.shutdown_on_free) |app| {
                app.quit();
                std.testing.expectError(error.Busy, app.finishShutdown()) catch |err| {
                    self.failure.* = err;
                };
            }
        }
        self.backing.rawFree(memory, alignment, ret);
    }
};
fn allocationQuit(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var failure: ?anyerror = null;
    var checked = false;
    var hook: Hook = .{ .backing = allocator, .quit_on_allocate = app, .failure = &failure, .checked = &checked };
    var probe: Probe = .{};
    try std.testing.expectError(error.Closed, wake.OneShot.create(app, hook.allocator(), .{ .context = &probe, .fire = Probe.fire }, .{}));
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}
fn freeWholeContext(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var done = false;
    var checked = false;
    var failure: ?anyerror = null;
    const Heap = struct {
        app: *z.App,
        hook: Hook,
        done: *bool,
        fn fire(context: *anyopaque, timer: *wake.OneShot, _: wake.Token) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.testing.expectEqual(wake.CloseResult.deferred, timer.close() catch |err| {
                self.hook.failure.* = err;
                self.app.quit();
                return;
            }) catch |err| {
                self.hook.failure.* = err;
            };
        }
        fn closed(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const owner = self.app;
            const finished = self.done;
            const backing = self.hook.backing;
            backing.destroy(self);
            finished.* = true;
            owner.quit();
        }
    };
    const heap = try allocator.create(Heap);
    heap.* = .{ .app = app, .hook = .{ .backing = allocator, .failure = &failure, .checked = &checked, .shutdown_on_free = app }, .done = &done };
    const timer = try wake.OneShot.create(app, heap.hook.allocator(), .{ .context = heap, .fire = Heap.fire }, .{ .on_closed = .{ .context = heap, .call = Heap.closed } });
    heap.hook.target = timer;
    _ = try timer.armAfter(1);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (failure) |err| return err;
    try std.testing.expect(!watchdog.expired and done and checked);
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}
fn watchCapacity(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Probe = .{};
    var timers: [17]*wake.OneShot = undefined;
    var created: usize = 0;
    defer for (timers[0..created]) |timer| {
        _ = timer.close() catch unreachable;
    };
    for (&timers) |*timer| {
        timer.* = try wake.OneShot.create(app, allocator, .{ .context = &probe, .fire = Probe.fire }, .{});
        created += 1;
    }
    for (timers[0..16]) |timer| _ = try timer.armAfter(3600 * std.time.ns_per_s);
    try std.testing.expectError(error.TooManyWaitables, timers[16].armAfter(1));
    try std.testing.expect(!(try timers[16].stats()).armed);
    try std.testing.expect(try timers[0].cancel(.{ .generation = 1 }));
    _ = try timers[16].armAfter(1);
    try std.testing.expect((try timers[16].stats()).armed);
}
pub fn run(allocator: std.mem.Allocator) !void {
    try creationFailure(allocator);
    try foreignThread(allocator);
    try takenStop(allocator);
    try allocationQuit(allocator);
    try freeWholeContext(allocator);
    try watchCapacity(allocator);
}
