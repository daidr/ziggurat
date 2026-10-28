const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const offscreen = ui.offscreen;
const drawing = ui.drawing;
const options: offscreen.Options = .{ .size = .{ .width = 8, .height = 8, .scale = 1 } };

const Hook = struct {
    backing: std.mem.Allocator,
    armed: enum { none, allocation, free } = .none,
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque) anyerror!void = null,
    failure: ?anyerror = null,
    calls: usize = 0,
    live: usize = 0,
    fail_at: ?usize = null,
    free_skip: usize = 0,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn fire(self: *Hook) void {
        self.armed = .none;
        self.callback.?(self.context.?) catch |err| {
            self.failure = err;
        };
    }
    fn check(self: *Hook) !void {
        if (self.failure) |err| return err;
        try std.testing.expect(self.armed == .none);
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        const index = self.calls;
        self.calls += 1;
        if (self.armed == .allocation) self.fire();
        if (self.fail_at) |failure_index| if (failure_index == index) return null;
        const value = self.backing.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        return value;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.armed == .free) {
            if (self.free_skip == 0) self.fire() else self.free_skip -= 1;
        }
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret);
    }
};
fn plain(buffer: *ui.commands.Buffer) !void {
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
}
fn red(snapshot: *offscreen.Snapshot) !void {
    const view = try snapshot.view();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128 }, view.levels[0].pixels[0..4]);
}

fn budgets(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var hook: Hook = .{ .backing = allocator };
    const a = hook.allocator();
    var invalid = options;
    invalid.total_bytes = 1;
    try std.testing.expectError(error.OffscreenBudgetExceeded, offscreen.Surface.create(app, a, invalid));
    try std.testing.expectEqual(@as(usize, 0), hook.calls);
    const probe = try offscreen.Surface.create(app, a, options);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try plain(&buffer);
    const example = try probe.render(&buffer);
    const cost = (try example.stats()).owned_bytes;
    try example.close();
    try probe.close();
    var small = options;
    small.output_bytes = cost * 2;
    const surface = try offscreen.Surface.create(app, a, small);
    const first = try surface.render(&buffer);
    const after_first = hook.calls;
    hook.fail_at = after_first;
    try std.testing.expectError(error.OutOfMemory, surface.render(&buffer));
    try std.testing.expectEqual(cost, (try surface.stats()).output_peak);
    try std.testing.expectEqual(cost, (try surface.stats()).output_current);
    hook.fail_at = hook.calls + 1;
    try std.testing.expectError(error.OutOfMemory, surface.render(&buffer));
    try std.testing.expectEqual(cost + (cost - 8 * 8 * 4), (try surface.stats()).output_peak);
    try std.testing.expectEqual(cost, (try surface.stats()).output_current);
    hook.fail_at = null;
    const second = try surface.render(&buffer);
    const before = hook.calls;
    try std.testing.expectError(error.OutputBudgetExceeded, surface.render(&buffer));
    try std.testing.expectEqual(before, hook.calls);
    try std.testing.expectEqual(cost * 2, (try surface.stats()).output_current);
    try red(first);
    try second.close();
    const third = try surface.render(&buffer);
    try std.testing.expect((try third.view()).identity != (try first.view()).identity);
    try std.testing.expectEqual(cost * 2, (try surface.stats()).output_peak);
    try third.close();
    const committed = (try surface.stats()).layers.committed_frames;
    const aborted = (try surface.stats()).layers.aborted_frames;
    try surface.injectExportFailureForTest();
    try std.testing.expectError(error.OffscreenExportFailed, surface.render(&buffer));
    try std.testing.expectEqual(committed, (try surface.stats()).layers.committed_frames);
    try std.testing.expectEqual(aborted + 1, (try surface.stats()).layers.aborted_frames);
    try std.testing.expectEqual(cost, (try surface.stats()).output_current);
    buffer.storage[0].shape.radius = std.math.nan(f32);
    const calls = hook.calls;
    try std.testing.expectError(error.InvalidGeometry, surface.render(&buffer));
    try std.testing.expectEqual(calls, hook.calls);
    try std.testing.expectEqual(@as(u64, 3), (try surface.stats()).renders);
    try red(first);
    try surface.close();
    try red(first);
    try first.close();
    try std.testing.expectEqual(@as(usize, 0), hook.live);
    buffer.reset();
    try plain(&buffer);
    var limited = options;
    limited.render_work = 8 * 8 * 3 - 1;
    const work = try offscreen.Surface.create(app, a, limited);
    const allocation_count = hook.calls;
    try std.testing.expectError(error.RenderWorkExceeded, work.render(&buffer));
    try std.testing.expectEqual(allocation_count, hook.calls);
    try std.testing.expectEqual(@as(usize, 0), (try work.stats()).output_current);
    try work.close();
    try std.testing.expectEqual(@as(usize, 0), hook.live);
}

const Foreign = struct {
    app: *z.App,
    surface: *offscreen.Surface,
    snapshot: *offscreen.Snapshot,
    allocator: std.mem.Allocator,
    failure: ?anyerror = null,
    fn run(self: *Foreign) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn check(self: *Foreign) !void {
        try std.testing.expectError(error.WrongThread, offscreen.Surface.create(self.app, self.allocator, options));
        try std.testing.expectError(error.WrongThread, self.surface.stats());
        try std.testing.expectError(error.WrongThread, self.surface.close());
        try std.testing.expectError(error.WrongThread, self.snapshot.view());
        try std.testing.expectError(error.WrongThread, self.snapshot.close());
        // No input/native read may precede the process-main owner check.
        try std.testing.expectError(error.WrongThread, self.surface.render(@ptrFromInt(@alignOf(ui.commands.Buffer))));
    }
};
fn pinsAndFailures(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var hook: Hook = .{ .backing = allocator };
    const surface = try offscreen.Surface.create(app, hook.allocator(), options);
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try plain(&buffer);
    const snapshot = try surface.render(&buffer);
    defer snapshot.close() catch unreachable;
    var foreign: Foreign = .{ .app = app, .surface = surface, .snapshot = snapshot, .allocator = allocator };
    const thread = try std.Thread.spawn(.{}, Foreign.run, .{&foreign});
    thread.join();
    if (foreign.failure) |err| return err;
    buffer.reset();
    var leases = [_]drawing.Lease{ drawing.Lease.init(std.Thread.getCurrentId()), drawing.Lease.init(std.Thread.getCurrentId()) };
    const bytes = [_]u8{ 0, 128, 0, 128 };
    const levels = [_]drawing.ImageLevel{.{ .pixels = &bytes, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }};
    for (&leases) |*lease| try buffer.image(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{ .lease = lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels }, .{});
    leases[1].pins = std.math.maxInt(usize);
    const calls = hook.calls;
    try std.testing.expectError(error.ResourcePinsFull, surface.render(&buffer));
    try std.testing.expectEqual(@as(usize, 1), leases[0].pins);
    try std.testing.expectEqual(std.math.maxInt(usize), leases[1].pins);
    try std.testing.expectEqual(calls, hook.calls);
    leases[1].pins = 1;
    if (builtin.os.tag == .linux) {
        // A genuine post-begin replay failure, after a candidate has already
        // changed its work plane. Unbound images cannot publish a new front.
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0x0000ff);
        const view: drawing.ImageView = .{ .lease = &leases[0], .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
        try buffer.image(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, view, .{});
        const before = try surface.stats();
        try std.testing.expectError(error.ImageNotUploaded, surface.render(&buffer));
        const after = try surface.stats();
        try std.testing.expectEqual(before.renders, after.renders);
        try std.testing.expectEqual(before.layers.committed_frames, after.layers.committed_frames);
        try std.testing.expectEqual(before.layers.aborted_frames + 1, after.layers.aborted_frames);
        try std.testing.expectEqual(before.output_current, after.output_current);
        try red(snapshot);
        try surface.uploadImage(view);
        const repaired = try surface.render(&buffer);
        try repaired.close();
    }
}

const Reset = struct {
    surface: *offscreen.Surface,
    buffer: *ui.commands.Buffer,
    lease: *drawing.Lease,
    fn call(context: *anyopaque) !void {
        const self: *Reset = @ptrCast(@alignCast(context));
        self.buffer.reset();
        // The source's pin is gone; the independent capture still holds one.
        try std.testing.expectEqual(@as(usize, 1), self.lease.pins - self.lease.residency_pins);
        try std.testing.expectError(error.ResourceInUse, self.lease.ensureUnused());
        try std.testing.expectError(error.Busy, self.surface.close());
        try std.testing.expectError(error.Busy, self.surface.render(self.buffer));
        try std.testing.expectError(error.Busy, self.surface.stats());
    }
};
const Closed = struct {
    snapshot: *offscreen.Snapshot,
    surface: ?*offscreen.Surface = null,
    app: ?*z.App = null,
    fn call(context: *anyopaque) !void {
        const self: *Closed = @ptrCast(@alignCast(context));
        try std.testing.expectError(error.Closed, self.snapshot.view());
        try std.testing.expectError(error.Closed, self.snapshot.stats());
        try std.testing.expectError(error.Closed, self.snapshot.close());
        if (self.surface) |surface| {
            try std.testing.expectError(error.Busy, surface.close());
            try std.testing.expectError(error.Busy, surface.stats());
            try std.testing.expectError(error.Busy, surface.render(@ptrFromInt(@alignOf(ui.commands.Buffer))));
        }
        if (self.app) |app| {
            app.quit();
            // Native teardown can finish even while output allocation is gated.
            try app.finishShutdown();
        }
    }
};
fn reentrant(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var hook: Hook = .{ .backing = allocator };
    const surface = try offscreen.Surface.create(app, hook.allocator(), options);
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = @as([64]u8, @splat(128));
    const mask: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 8, .height = 8, .stride = 8, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    try surface.uploadCoverage(mask);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.coverage(.{}, mask, ui.Color.rgb(0xff0000));
    var reset: Reset = .{ .surface = surface, .buffer = &buffer, .lease = &lease };
    hook.context = &reset;
    hook.callback = Reset.call;
    hook.armed = .allocation;
    const snapshot = try surface.render(&buffer);
    try hook.check();
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    try std.testing.expectEqual(lease.residency_pins, lease.pins);
    try red(snapshot);
    const second = try surface.render(&buffer);
    var closing_second: Closed = .{ .snapshot = second, .surface = surface, .app = app };
    hook.context = &closing_second;
    hook.callback = Closed.call;
    hook.armed = .free;
    hook.free_skip = 1; // fire in shell deallocation, after pixels/account release
    try second.close();
    try hook.check();
    try std.testing.expectEqual(@as(usize, 0), (try surface.stats()).workspace_bytes);
    try surface.close();
    try lease.ensureUnused();
    var closed: Closed = .{ .snapshot = snapshot };
    hook.context = &closed;
    hook.callback = Closed.call;
    hook.armed = .free;
    try snapshot.close();
    try hook.check();
    try std.testing.expectEqual(@as(usize, 0), hook.live);
}

const Quit = struct {
    app: *z.App,
    surface: ?*offscreen.Surface = null,
    fn call(context: *anyopaque) !void {
        const self: *Quit = @ptrCast(@alignCast(context));
        self.app.quit();
        try std.testing.expectError(error.Busy, self.app.finishShutdown());
        if (self.surface) |surface| try std.testing.expectError(error.Busy, surface.close());
    }
};
fn interrupted(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    var hook: Hook = .{ .backing = allocator };
    const surface = try offscreen.Surface.create(app, hook.allocator(), options);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try plain(&buffer);
    const snapshot = try surface.render(&buffer);
    const cost = (try snapshot.stats()).owned_bytes;
    var quit: Quit = .{ .app = app, .surface = surface };
    hook.context = &quit;
    hook.callback = Quit.call;
    hook.armed = .allocation;
    try std.testing.expectError(error.Closed, surface.render(&buffer));
    try hook.check();
    try std.testing.expectEqual(cost, (try surface.stats()).output_current);
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 0), (try surface.stats()).workspace_bytes);
    try std.testing.expectEqual(@as(u32, 0), (try surface.stats()).layers.native_objects);
    try std.testing.expectError(error.Closed, surface.render(&buffer));
    try surface.close();
    app.deinit();
    try red(snapshot);
    try snapshot.close();
    try std.testing.expectEqual(@as(usize, 0), hook.live);

    const next = try z.App.init(allocator);
    defer next.deinit();
    var create_hook: Hook = .{ .backing = allocator };
    var create_quit: Quit = .{ .app = next };
    create_hook.context = &create_quit;
    create_hook.callback = Quit.call;
    create_hook.armed = .allocation;
    try std.testing.expectError(error.Closed, offscreen.Surface.create(next, create_hook.allocator(), options));
    try create_hook.check();
    try std.testing.expectEqual(@as(usize, 0), create_hook.live);
    try next.finishShutdown();
}

const Remove = struct {
    surface: *offscreen.Surface,
    calls: usize = 0,
    fn call(context: *anyopaque) !void {
        const self: *Remove = @ptrCast(@alignCast(context));
        self.calls += 1;
        try std.testing.expectError(error.StopInProgress, self.surface.close());
    }
};
fn registration(allocator: std.mem.Allocator) !void {
    const app = try z.App.initWithOptions(allocator, .{ .stop_capacity = 1 });
    var dummy: usize = 0;
    var node: z.StopParticipant = .{ .context = &dummy, .stop = struct {
        fn call(_: *anyopaque) !void {}
    }.call };
    const token = try app.registerStop(&node);
    try std.testing.expectError(error.Full, offscreen.Surface.create(app, allocator, options));
    try std.testing.expectEqual(@as(usize, 1), app.resourceStats().stop_participants);
    try std.testing.expect(try app.cancelStop(token));
    app.deinit();
    const next = try z.App.init(allocator);
    const surface = try offscreen.Surface.create(next, allocator, options);
    var remove: Remove = .{ .surface = surface };
    var other: z.StopParticipant = .{ .context = &remove, .stop = Remove.call };
    _ = try next.registerStop(&other);
    next.quit();
    try next.finishShutdown();
    try std.testing.expectEqual(@as(usize, 1), remove.calls);
    try std.testing.expectEqual(@as(usize, 0), next.resourceStats().stop_participants);
    try surface.close();
    next.deinit();
}

pub fn run(allocator: std.mem.Allocator) !void {
    try budgets(allocator);
    try reentrant(allocator);
    try interrupted(allocator);
    try registration(allocator);
    try pinsAndFailures(allocator);
}
