//! Animation timeline: four staggered tracks with different easing curves
//! share one `ziggurat_animation.Timeline`, and a `Playhead` drives it from
//! the view's monotonic clock. Play, pause, reverse, restart and scrub; turn
//! on looping or reduced motion. While the playhead moves, each pass asks
//! `View.wakeAt` for the next frame and `ziggurat_view_timer` arms one
//! one-shot timer for it; once paused or finished nothing is scheduled and
//! the idle window does no work.
//!
//! Run with `zig build run-timeline`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const animation = @import("ziggurat_animation");

const ms = std.time.ns_per_ms;
/// About 60 updates a second while playing; the timer coalesces nothing.
const frame_ns: u64 = 16_666_667;

const lanes = [_]struct { name: []const u8, color: u32, track: animation.Track }{
    .{ .name = "Linear", .color = 0x2a7fd4, .track = .{ .at_ns = 0, .from = 0, .to = 1, .tween = .{ .duration_ns = 2000 * ms, .easing = .linear } } },
    .{ .name = "Smoothstep", .color = 0x2f9e6e, .track = .{ .at_ns = 250 * ms, .from = 0, .to = 1, .tween = .{ .duration_ns = 2000 * ms, .easing = .smoothstep } } },
    .{ .name = "Cubic out", .color = 0xd4762a, .track = .{ .at_ns = 500 * ms, .from = 0, .to = 1, .tween = .{ .duration_ns = 2000 * ms, .easing = .cubic_out } } },
    .{ .name = "Return", .color = 0x9a4fc4, .track = .{ .at_ns = 1500 * ms, .from = 1, .to = 0, .tween = .{ .duration_ns = 1000 * ms, .easing = .smoothstep } } },
};

const Studio = struct {
    timeline: animation.Timeline,
    playhead: animation.Playhead,
    /// Playhead position as a fraction, bound to the scrub slider.
    scrub: f64 = 0,
    loop: bool = false,
    reduced_motion: bool = false,
    /// Track values sampled for the current position; paint only reads them.
    values: [lanes.len]f64 = undefined,
    /// The deadline the last pass asked for, shown in the status line.
    wake: ?u64 = null,

    fn init() !Studio {
        var tracks: [lanes.len]animation.Track = undefined;
        for (lanes, &tracks) |lane, *track| track.* = lane.track;
        const timeline = try animation.Timeline.init(&tracks);
        return .{ .timeline = timeline, .playhead = try animation.Playhead.init(timeline.duration_ns) };
    }

    fn atEnd(self: *const Studio, direction: animation.Direction) bool {
        const p = self.playhead.position_ns;
        return if (direction == .forward) p == self.playhead.duration_ns else p == 0;
    }

    /// Play toward `direction`, starting over from the far end when already there.
    fn start(self: *Studio, now: u64, direction: animation.Direction) !void {
        if (self.atEnd(direction) and !self.loop) {
            try self.playhead.restart(now, direction);
        } else try self.playhead.play(now, direction);
    }

    /// A finite repetition is configured while paused; looping alternates
    /// direction at each end for as long as one hour allows.
    fn setLoop(self: *Studio, now: u64) !void {
        const was_playing = self.playhead.playing;
        const direction = self.playhead.direction;
        try self.playhead.pause(now);
        const most: u32 = @intCast(animation.max_duration_ns / self.playhead.duration_ns);
        try self.playhead.configureRepeat(if (self.loop) .{ .iterations = most, .alternate = true } else .{});
        if (was_playing) try self.playhead.play(now, direction);
    }

    fn build(self: *Studio, v: *view.View) anyerror!void {
        const now = v.time();
        // The update stage: bring the playhead to this pass's time before
        // controls act on it. Advancing to the same time again changes nothing.
        _ = try self.playhead.advance(now);

        try v.text("Animation timeline", .{ .font = view.Font.heading3 });
        try v.toolbar(.{ .gap = 8, .alignment = .center, .name = "Transport" });
        const playing = self.playhead.playing;
        if (try v.button(if (playing) "Pause" else "Play", .{ .width = 88 })) {
            if (playing) try self.playhead.pause(now) else try self.start(now, .forward);
        }
        if (try v.button("Reverse", .{})) try self.start(now, .backward);
        if (try v.button("Restart", .{})) try self.playhead.restart(now, .forward);
        if (try v.checkbox(&self.loop, "Loop", .{})) try self.setLoop(now);
        if (try v.checkbox(&self.reduced_motion, "Reduce motion", .{})) try self.playhead.setReducedMotion(now, self.reduced_motion);
        try v.end();

        try v.embed(.{ .context = self, .measure = measure, .paint = paint }, .{ .grow = 1, .self_align = .stretch, .key = 1 });

        const duration = self.playhead.duration_ns;
        self.scrub = @as(f64, @floatFromInt(self.playhead.position_ns)) / @as(f64, @floatFromInt(duration));
        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch, .key = 2 });
        try v.text("Scrub", .{});
        // Dragging seeks, which also pauses.
        if (try v.slider(&self.scrub, .{ .minimum = 0, .maximum = 1, .step = 0.01 }, .{ .grow = 1, .name = "Playhead position" })) {
            try self.playhead.seek(now, @intFromFloat(self.scrub * @as(f64, @floatFromInt(duration))));
        }
        try v.end();

        for (&self.values, 0..) |*value, i| value.* = (try self.timeline.sample(i, self.playhead.position_ns)).value;

        // Schedule the next frame only while the playhead moves.
        self.wake = try self.playhead.nextWake(now, frame_ns);
        if (self.wake) |deadline| v.wakeAt(deadline);

        const seconds = @as(f64, @floatFromInt(self.playhead.position_ns)) / std.time.ns_per_s;
        const total = @as(f64, @floatFromInt(duration)) / std.time.ns_per_s;
        if (self.wake != null) {
            try v.textf("{d:.2} s / {d:.2} s, playing {s}; next wake in {d:.1} ms", .{ seconds, total, @tagName(self.playhead.direction), @as(f64, @floatFromInt(self.wake.? -| now)) / ms }, .{ .color = 0x536475 });
        } else {
            try v.textf("{d:.2} s / {d:.2} s, idle: no wake scheduled", .{ seconds, total }, .{ .color = 0x536475 });
        }
    }

    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 240, .height = 200 }, .preferred = .{ .width = 640, .height = 260 } };
    }

    /// Draw one lane per track, each ball at its eased value, and a ruler
    /// along the bottom with every track's active span and the playhead.
    fn paint(context: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *Studio = @ptrCast(@alignCast(context));
        const palette = frame.currentTheme().palette;
        frame.roundedRect(bounds, 8, ui.Color.rgb(palette.field));
        const label_width: f32 = 112;
        const pad: f32 = 16;
        const ball: f32 = 18;
        const ruler: f32 = 36;
        const left = bounds.x + label_width;
        const width = @max(0, bounds.width - label_width - pad - ball);
        const lane_height = (bounds.height - ruler - pad) / @as(f32, @floatFromInt(lanes.len));
        for (lanes, self.values, 0..) |lane, value, i| {
            const y = bounds.y + pad / 2 + lane_height * @as(f32, @floatFromInt(i));
            const middle = y + lane_height / 2;
            frame.label(.{ .x = bounds.x + pad, .y = middle - 12, .width = label_width - pad, .height = 24 }, lane.name, palette.text);
            frame.roundedRect(.{ .x = left, .y = middle - 2, .width = width + ball, .height = 4 }, 2, ui.Color.rgb(palette.trough));
            const x = left + width * @as(f32, @floatCast(value));
            frame.roundedRect(.{ .x = x, .y = middle - ball / 2, .width = ball, .height = ball }, ball / 2, ui.Color.rgb(lane.color));
        }
        // Ruler: each track's span on the time axis, then the playhead.
        const duration: f32 = @floatFromInt(self.playhead.duration_ns);
        const base = bounds.y + bounds.height - ruler;
        for (lanes, 0..) |lane, i| {
            const from = @as(f32, @floatFromInt(lane.track.at_ns)) / duration;
            const span = @as(f32, @floatFromInt(lane.track.tween.duration_ns)) / duration;
            const c = ui.Color.rgb(lane.color);
            frame.roundedRect(.{ .x = left + (width + ball) * from, .y = base + 4 + @as(f32, @floatFromInt(i)) * 5, .width = (width + ball) * span, .height = 3 }, 1.5, .{ .r = c.r, .g = c.g, .b = c.b, .a = 160 });
        }
        const at = @as(f32, @floatFromInt(self.playhead.position_ns)) / duration;
        frame.rect(.{ .x = left + (width + ball) * at - 1, .y = base, .width = 2, .height = 26 }, palette.accent);
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var studio = try Studio.init();
    var storage: view.Storage(64, 2048) = .{};
    var host = view.Host.init(&studio, Studio.build, storage.buffers(), .{});
    var timer = view_timer.Timer.init(&host);

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Ziggurat - Animation timeline", .width = 760, .height = 480, .min_width = 480, .min_height = 380 });
    try host.attach(window);
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    // App stop released the native timer; closing frees its shell.
    try timer.close();
}

test "the playhead wakes the view only while it moves" {
    var studio = try Studio.init();
    var storage: view.Storage(64, 2048) = .{};
    var h = view.Harness.init(&studio, Studio.build, storage.buffers(), .{});
    try h.render();
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    try h.click(.{ .text = "Play" });
    try std.testing.expect(h.deadline() != null);
    try h.advance(1000 * ms);
    try std.testing.expect(studio.values[0] > 0.4 and studio.values[0] < 0.6);
    try h.advance(2000 * ms);
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    try std.testing.expectEqual(@as(f64, 1), studio.values[0]);
    // Scrubbing seeks and pauses.
    try h.change(.{ .kind = .slider }, .{ .steps = -50 });
    try std.testing.expect(!studio.playhead.playing);
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
}
