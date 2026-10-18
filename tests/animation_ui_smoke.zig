const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const animation = @import("ziggurat_animation");
const wake = @import("ziggurat_wake");
const Watchdog = @import("watchdog.zig").Watchdog;

// This fixture follows the ordinary native queue. It does not force paint or
// assume one display frame per timer callback; the OS may coalesce damage.
const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    clock: std.time.Timer,
    timeline: animation.Timeline,
    playhead: animation.Playhead,
    timer: ?*wake.OneShot = null,
    x: f32 = 8,
    updates: usize = 0,
    queued: bool = false,
    verified: bool = false,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        self.failure = err;
        self.app.quit();
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        frame.clear(frame.currentTheme().palette.background);
        frame.button(1, .{ .x = self.x, .y = 8, .width = 32, .height = 24 }, "") catch |err| {
            frame.failure = err;
            self.fail(err);
            return;
        };
        if (!self.playhead.playing and !self.queued) {
            self.queued = true;
            // Verify after Context has committed the successful Frame's hit
            // snapshot. Business state is not updated from a draw callback.
            self.app.post(.{ .context = self, .call = verifyTask }) catch |err| self.fail(err);
        }
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn fire(ptr: *anyopaque, _: *wake.OneShot, _: wake.Token) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.update() catch |err| self.fail(err);
    }
    fn update(self: *State) !void {
        const now = self.clock.read();
        const position = try self.playhead.advance(now);
        const value: f32 = @floatCast((try self.timeline.sample(0, position)).value);
        if (self.x != value) {
            const left = @min(self.x, value);
            const right = @max(self.x, value) + 32;
            self.x = value;
            self.updates += 1;
            try self.window.invalidateRect(.{ .x = left, .y = 8, .width = right - left, .height = 24 });
        }
        if (try self.playhead.nextWake(now, 2 * std.time.ns_per_ms)) |at| {
            _ = try self.timer.?.armAfter(@max(1, at - now));
        } else {
            // A reduced-motion sequence can finish before its first timer.
            // Ensure its final value receives the normal native paint path.
            try self.window.invalidateRect(.{ .x = self.x, .y = 8, .width = 32, .height = 24 });
        }
    }
    fn verifyTask(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.verify() catch |err| self.fail(err);
    }
    fn verify(self: *State) !void {
        try std.testing.expect(!self.playhead.playing);
        try std.testing.expectEqual(@as(u32, 3), self.playhead.completed_iterations);
        try std.testing.expectEqual(@as(f32, 88), self.x);
        try std.testing.expect(!((try self.timer.?.stats()).armed));
        try std.testing.expectEqual(@as(?u64, null), try self.playhead.nextWake(self.clock.read(), 2 * std.time.ns_per_ms));
        try std.testing.expect(self.context.frames > 0);
        try std.testing.expectEqual(@as(usize, 1), self.context.input_state.len);
        try std.testing.expectEqual(@as(f32, 88), self.context.input_state.hits[0].rect.x);
        self.verified = true;
        self.app.quit();
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const timer = self.timer;
        self.timer = null;
        if (timer) |value| _ = value.close() catch |err| {
            self.failure = err;
            return;
        };
    }
};

fn run(allocator: std.mem.Allocator, reduced: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const timeline = try animation.Timeline.init(&.{.{ .from = 8, .to = 88, .tween = .{ .duration_ns = 15 * std.time.ns_per_ms, .easing = .smoothstep } }});
    var state: State = .{ .app = app, .clock = try .start(), .timeline = timeline, .playhead = try .init(timeline.duration_ns) };
    try state.playhead.configureRepeat(.{ .iterations = 3, .alternate = true });
    try state.playhead.setReducedMotion(0, reduced);
    try state.playhead.play(0, .forward);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    state.window = try app.createWindow(.{ .width = 140, .height = 48, .on_closed = .{ .context = &state, .notify = State.closed } });
    try state.context.attach(state.window);
    state.timer = try wake.OneShot.create(app, allocator, .{ .context = &state, .fire = State.fire }, .{});
    defer if (state.timer) |timer| {
        state.timer = null;
        _ = timer.close() catch unreachable;
    };
    try state.window.setClientBounds(.{ .position = .{ .x = -16000, .y = -16000 }, .width = 140, .height = 48 });
    try state.update();
    try state.window.perform(.show);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    if (state.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.verified and state.updates != 0);
    try std.testing.expect(state.context.window == null and state.timer == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    try std.testing.expectEqual(wake.NativeCounts{}, wake.nativeCounts());
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    try run(allocator.allocator(), false);
    try run(allocator.allocator(), true);
    std.debug.print("animation UI: event-driven finite timeline, native coalesced damage, committed hit state, reduced motion and native resources=0 passed\n", .{});
}
