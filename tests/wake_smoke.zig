const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const wake = @import("ziggurat_wake");
const animation = @import("ziggurat_animation");
const Watchdog = @import("watchdog.zig").Watchdog;

const Motion = struct {
    app: *z.App,
    clock: zio.Timer,
    channel: animation.Channel,
    calls: u32 = 0,
    closed: u32 = 0,
    failure: ?anyerror = null,
    fn fire(context: *anyopaque, timer: *wake.OneShot, token: wake.Token) void {
        const self: *Motion = @ptrCast(@alignCast(context));
        self.update(timer, token) catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
    fn update(self: *Motion, timer: *wake.OneShot, token: wake.Token) !void {
        self.calls += 1;
        try std.testing.expect(!try timer.cancel(token));
        const now = self.clock.read();
        const sample = try self.channel.advance(now);
        if (try self.channel.nextWake(now, std.time.ns_per_ms)) |at| {
            try std.testing.expect(sample.active);
            _ = try timer.armAfter(@max(1, at - now));
        } else {
            try std.testing.expect(!sample.active and sample.value == 1);
            try std.testing.expectEqual(wake.CloseResult.deferred, try timer.close());
            try std.testing.expectError(error.Closed, timer.stats());
        }
    }
    fn onClosed(context: *anyopaque) void {
        const self: *Motion = @ptrCast(@alignCast(context));
        self.closed += 1;
        self.app.quit();
    }
};

fn motion(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var state: Motion = .{ .app = app, .clock = try .start(), .channel = try animation.Channel.init(0) };
    try state.channel.retarget(0, 1, .{ .motion = .{ .tween = .{ .duration_ns = 30 * std.time.ns_per_ms } } });
    const timer = try wake.OneShot.create(app, allocator, .{ .context = &state, .fire = Motion.fire }, .{ .on_closed = .{ .context = &state, .call = Motion.onClosed } });
    const old = try timer.armAfter(100 * std.time.ns_per_ms);
    const current = try timer.armAfter(std.time.ns_per_ms);
    try std.testing.expect(!try timer.cancel(old));
    try std.testing.expect(current.generation > old.generation);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.calls > 0 and state.closed == 1);
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
}

const Rearm = struct {
    app: *z.App,
    timers: [2]*wake.OneShot = undefined,
    clock: zio.Timer,
    start: u64 = 0,
    calls: u32 = 0,
    closed: u32 = 0,
    failure: ?anyerror = null,
    action: enum { rearm, close } = .rearm,
    fn fire(context: *anyopaque, timer: *wake.OneShot, _: wake.Token) void {
        const self: *Rearm = @ptrCast(@alignCast(context));
        self.check(timer) catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
    fn check(self: *Rearm, timer: *wake.OneShot) !void {
        self.calls += 1;
        if (self.calls == 1) {
            const other = if (timer == self.timers[0]) self.timers[1] else self.timers[0];
            if (self.action == .close) {
                try std.testing.expectEqual(wake.CloseResult.closed, try other.close());
            } else {
                self.start = self.clock.read();
                _ = try other.armAfter(30 * std.time.ns_per_ms);
            }
        } else {
            // Detect an already selected GLib dispatch firing the replacement
            // immediately; this is not a sub-millisecond latency measurement.
            try std.testing.expectEqual(@as(u32, 2), self.calls);
            try std.testing.expect(self.clock.read() - self.start >= 20 * std.time.ns_per_ms);
        }
        try std.testing.expectEqual(wake.CloseResult.deferred, try timer.close());
    }
    fn onClosed(context: *anyopaque) void {
        const self: *Rearm = @ptrCast(@alignCast(context));
        self.closed += 1;
        if (self.closed == 2) self.app.quit();
    }
};
fn selectedRearm(allocator: std.mem.Allocator, close: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var state: Rearm = .{ .app = app, .clock = try .start(), .action = if (close) .close else .rearm };
    for (&state.timers) |*timer| timer.* = try wake.OneShot.create(app, allocator, .{ .context = &state, .fire = Rearm.fire }, .{ .on_closed = .{ .context = &state, .call = Rearm.onClosed } });
    for (state.timers) |timer| _ = try timer.armAfter(1);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.calls == (if (close) @as(u32, 1) else 2) and state.closed == 2);
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}
fn shutdown(allocator: std.mem.Allocator) !void {
    const Probe = struct {
        calls: u32 = 0,
        fn fire(context: *anyopaque, _: *wake.OneShot, _: wake.Token) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
        }
    };
    const app = try z.App.init(allocator);
    var probe: Probe = .{};
    const timer = try wake.OneShot.create(app, allocator, .{ .context = &probe, .fire = Probe.fire }, .{});
    _ = try timer.armAfter(1);
    app.quit();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
    try std.testing.expect((try timer.stats()).stopped and !(try timer.stats()).armed);
    try std.testing.expectError(error.Closed, timer.armAfter(1));
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
    app.deinit();
    try std.testing.expectEqual(wake.CloseResult.closed, try timer.close());
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    try motion(allocator.allocator());
    try selectedRearm(allocator.allocator(), false);
    try selectedRearm(allocator.allocator(), true);
    try shutdown(allocator.allocator());
    try @import("wake_lifetime.zig").run(allocator.allocator());
    std.debug.print("one-shot native: explicit animation cadence, rearm/cancel, callback close and native resources=0 passed\n", .{});
}
