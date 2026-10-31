//! A looping animated GIF played by `ziggurat_view_video`, fitted to cover
//! its box, with a button that pauses and plays it. Each frame of the clip
//! asks for one pass through `View.wakeAt`, which `ziggurat_view_timer`
//! turns into a one-shot timer; a paused clip schedules nothing.
//!
//! Run it with `zig build run-video`.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const video = @import("ziggurat_view_video");

/// Drawn by scripts/make-waves-gif.py.
const waves_gif = @embedFile("assets/waves.gif");

const Screen = struct {
    waves: *video.Player,

    fn build(self: *Screen, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .gap = 12, .padding = .all(16) });
        try self.waves.show(v, .{ .fit = .cover, .alt = "Waves" }, .{ .grow = 1, .self_align = .stretch, .radius = 8 });
        try v.row(.{ .gap = 12, .alignment = .center });
        if (try v.button(if (self.waves.playing()) "Pause" else "Play", .{})) {
            if (self.waves.playing()) self.waves.pause() else self.waves.play();
        }
        var looping = self.waves.looping;
        if (try v.checkbox(&looping, "Loop", .{})) self.waves.setLoop(looping);
        try v.end();
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var decoder = try video.GifDecoder.init(allocator, waves_gif);
    defer decoder.deinit();
    var screen: Screen = .{ .waves = undefined };
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&screen, Screen.build, storage.buffers(), .{});
    var timer = view_timer.Timer.init(&host);
    var waves = try video.Player.init(allocator, &host, decoder.decoder());
    waves.setLoop(true);
    screen.waves = &waves;

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Video", .width = 640, .height = 440, .min_width = 320, .min_height = 260 });
    try host.attach(window);
    defer waves.deinit();
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
}

test "the clip shows from its first frame and the button pauses it" {
    var decoder = try video.GifDecoder.init(std.testing.allocator, waves_gif);
    defer decoder.deinit();
    var screen: Screen = .{ .waves = undefined };
    var host_storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&screen, Screen.build, host_storage.buffers(), .{});
    var waves = try video.Player.init(std.testing.allocator, &host, decoder.decoder());
    defer waves.deinit();
    waves.setLoop(true);
    screen.waves = &waves;
    var storage: view.Storage(32, 512) = .{};
    var h = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .name = "Waves" });
    try std.testing.expect(h.deadline() != null);
    try h.click(.{ .text = "Pause" });
    try std.testing.expect(!waves.playing());
    try std.testing.expectEqual(@as(?u64, null), h.deadline());
    _ = try h.find(.{ .text = "Play" });
}

test "every frame of the clip decodes" {
    var decoder = try video.GifDecoder.init(std.testing.allocator, waves_gif);
    defer decoder.deinit();
    const source = decoder.decoder();
    const pixels = try std.testing.allocator.alloc(u8, @as(usize, source.width) * source.height * 4);
    defer std.testing.allocator.free(pixels);
    var frames: usize = 0;
    while (try source.next(source.context, pixels)) |_| frames += 1;
    try std.testing.expectEqual(@as(usize, 24), frames);
}
