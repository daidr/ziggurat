//! Video in native UI, as a launcher's store page shows it: a short GIF
//! loops at the top of the window, and a trailer with sound plays in its
//! place, with controls to pause it, seek, mute it and close it.
//!
//! Run it with `zig build run-video`.
//!
//! The GIF decodes in the app (`ziggurat_view_video.GifDecoder`), on every
//! system: each frame asks for one pass through `View.wakeAt`, which
//! `ziggurat_view_timer` turns into a one-shot timer, so the window draws
//! one frame for each of the clip's and none between. It stands still while
//! the window is out of sight, and shows its first frame while the desktop
//! asks for less motion.
//!
//! The trailer, an MP4 of H.264 and AAC embedded in the app, plays with the
//! system's media framework (`ziggurat_video`): AVFoundation on macOS,
//! GStreamer on Linux and the video element in browsers, which decode it in
//! hardware where they can and play its sound in sync. Its pictures reach
//! the window's renderer where the decoder left them, on the GPU.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const view_timer = @import("ziggurat_view_timer");
const video = @import("ziggurat_view_video");
const system_video = @import("ziggurat_video");
const ui = @import("ziggurat_ui");
const zio = @import("ziggurat_io");

/// Drawn by scripts/make-waves-gif.py.
const waves_gif = @embedFile("assets/waves.gif");
/// Encoded by scripts/make-video-clips.sh.
const trailer_mp4 = @embedFile("assets/trailer.mp4");

const white: u32 = 0xffffff;

const Screen = struct {
    allocator: std.mem.Allocator,
    host: *view.Host,
    waves: *video.Player,
    /// The trailer's player once opened, at a stable address.
    trailer: ?*video.Player = null,
    /// What stopped the trailer from opening, as a system without a media
    /// framework.
    trailer_error: ?anyerror = null,

    /// Opens the trailer, which plays once the view shows it.
    fn watch(self: *Screen) void {
        const player = self.allocator.create(video.Player) catch |err| {
            self.trailer_error = err;
            return;
        };
        player.* = system_video.openData(self.allocator, self.host, trailer_mp4) catch |err| {
            self.allocator.destroy(player);
            self.trailer_error = err;
            return;
        };
        self.trailer = player;
        self.trailer_error = null;
        // The background holds still while the trailer plays.
        self.waves.pause();
    }
    /// Stops the trailer and its sound.
    fn closeTrailer(self: *Screen) void {
        const player = self.trailer orelse return;
        player.deinit();
        self.allocator.destroy(player);
        self.trailer = null;
        self.waves.play();
    }

    fn build(self: *Screen, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .gap = 12, .padding = .all(16), .background = 0x0b1d3a });
        if (self.trailer) |player| {
            try self.trailerView(v, player);
        } else {
            try self.waves.show(v, .{ .fit = .cover, .alt = "Waves" }, .{ .grow = 1, .self_align = .stretch, .radius = 8 });
            try v.text("Wavelength", .{ .font = .{ .size = 32, .weight = .bold }, .color = white });
            try v.row(.{ .gap = 8, .alignment = .center });
            if (try v.button(if (self.waves.playing()) "Pause" else "Play", .{ .width = 96 })) {
                if (self.waves.playing()) self.waves.pause() else self.waves.play();
            }
            if (try v.button("Watch the trailer", .{})) self.watch();
            try v.end();
            if (self.trailer_error) |err| try v.textf("The trailer does not play here: {s}", .{@errorName(err)}, .{ .color = white });
        }
        try v.end();
    }

    /// The trailer and its controls.
    fn trailerView(self: *Screen, v: *view.View, player: *video.Player) !void {
        try player.show(v, .{ .fit = .contain, .alt = "Trailer" }, .{ .grow = 1, .self_align = .stretch, .radius = 6, .background = 0x000000 });
        if (player.err()) |err| {
            try v.textf("The trailer stopped: {s}", .{@errorName(err)}, .{ .color = white });
        } else if (!player.ready() or player.buffering()) {
            try v.loadingIndicator(.arc, .{ .color = white }, .{ .name = "Loading the trailer", .self_align = .center });
        }
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button(if (player.playing()) "Pause" else "Play", .{ .width = 72 })) {
            if (player.playing()) player.pause() else player.play();
        }
        var at = seconds(player.position());
        const length = seconds(player.duration());
        if (try v.slider(&at, .{ .minimum = 0, .maximum = @max(length, 0.001), .step = 0.1 }, .{ .grow = 1, .name = "Position" })) {
            player.seek(@intFromFloat(@max(at, 0) * std.time.ns_per_s));
        }
        try v.textf("{d}:{d:0>2} / {d}:{d:0>2}", .{ whole(at) / 60, whole(at) % 60, whole(length) / 60, whole(length) % 60 }, .{ .color = white });
        if (try v.button(if (player.muted()) "Unmute" else "Mute", .{ .width = 92 })) player.setMuted(!player.muted());
        if (try v.button("Close", .{})) self.closeTrailer();
        try v.end();
    }
};

fn seconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
}
fn whole(value: f64) u64 {
    return @intFromFloat(@round(@max(value, 0)));
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var decoder = try video.GifDecoder.init(allocator, waves_gif);
    defer decoder.deinit();
    var screen: Screen = .{ .allocator = allocator, .host = undefined, .waves = undefined };
    var storage: view.Storage(48, 768) = .{};
    var host = view.Host.init(&screen, Screen.build, storage.buffers(), .{});
    screen.host = &host;
    var timer = view_timer.Timer.init(&host);
    var waves = try video.Player.init(allocator, &host, decoder.decoder());
    waves.setLoop(true);
    waves.setMuted(true);
    screen.waves = &waves;

    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Video", .width = 640, .height = 440, .min_width = 480, .min_height = 320 });
    try host.attach(window);
    defer waves.deinit();
    defer screen.closeTrailer();
    try timer.attach(app, allocator);
    window.show();
    try app.run();
    try timer.close();
}

const Fixture = struct {
    decoder: video.GifDecoder,
    screen: Screen,
    host_storage: view.Storage(48, 768),
    host: view.Host,
    waves: video.Player,
    storage: view.Storage(48, 768),
    harness: view.Harness,

    fn init(self: *Fixture) !void {
        self.decoder = try video.GifDecoder.init(std.testing.allocator, waves_gif);
        errdefer self.decoder.deinit();
        self.screen = .{ .allocator = std.testing.allocator, .host = &self.host, .waves = &self.waves };
        self.host_storage = .{};
        self.host = view.Host.init(&self.screen, Screen.build, self.host_storage.buffers(), .{});
        self.waves = try video.Player.init(std.testing.allocator, &self.host, self.decoder.decoder());
        self.waves.setLoop(true);
        self.waves.setMuted(true);
        self.storage = .{};
        self.harness = view.Harness.init(&self.screen, Screen.build, self.storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 640, .height = 440 } });
    }
    fn deinit(self: *Fixture) void {
        self.screen.closeTrailer();
        self.waves.deinit();
        self.decoder.deinit();
    }
};

/// What the window's renderer does with the trailer's pictures, here
/// nothing: the player commits each to it.
const Uploads = struct {
    held: ?u64 = null,
    pub fn uploadDynamicImage(self: *Uploads, next: ui.drawing.ImageView) !void {
        self.held = next.identity;
    }
    pub fn updateImage(self: *Uploads, old: u64, next: ui.drawing.ImageView) !void {
        if (self.held != old) return error.ImageNotUploaded;
        self.held = next.identity;
    }
    pub fn releaseImage(self: *Uploads, identity: u64) !bool {
        if (self.held != identity) return false;
        self.held = null;
        return true;
    }
};

test "the background loops, and its button pauses it and plays it again" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = &f.harness;
    try h.render();
    _ = try h.find(.{ .name = "Waves" });
    _ = try h.find(.{ .text = "Wavelength" });
    try std.testing.expect(f.waves.playing() and f.waves.looping);
    try std.testing.expect(h.deadline() != null);
    try h.click(.{ .text = "Pause" });
    try std.testing.expect(!f.waves.playing());
    try h.click(.{ .text = "Play" });
    try std.testing.expect(f.waves.playing());
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

test "the trailer opens in the background's place, plays, mutes, pauses and closes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const h = &f.harness;
    try h.render();
    try h.click(.{ .text = "Watch the trailer" });
    if (f.screen.trailer_error) |err| {
        try std.testing.expectEqual(error.Unsupported, err);
        _ = try h.find(.{ .text = "The trailer does not play here: Unsupported" });
        return error.SkipZigTest;
    }
    const trailer = f.screen.trailer.?;
    try std.testing.expect(!f.waves.playing());
    var uploads: Uploads = .{};
    var tries: usize = 0;
    trailer.setMuted(true);
    while (!trailer.ready()) : (tries += 1) {
        // A system without an H.264 decoder fails the trailer.
        if (trailer.err() != null) return error.SkipZigTest;
        if (tries == 2000) return error.Timeout;
        h.clock += 10 * std.time.ns_per_ms;
        try h.render();
        trailer.performEngine(&uploads);
        zio.sleep(10 * std.time.ns_per_ms);
    }
    // The trailer is six seconds long, and a slow machine takes most of
    // them to show its first picture: looping keeps it playing for the
    // clicks below, where it would end and Pause would show Play.
    trailer.setLoop(true);
    try h.render();
    try std.testing.expectEqual(view.Size{ .width = 480, .height = 270 }, trailer.size());
    const length = trailer.duration();
    try std.testing.expect(length >= 5 * std.time.ns_per_s and length <= 7 * std.time.ns_per_s);
    _ = try h.find(.{ .name = "Trailer" });
    _ = try h.find(.{ .name = "Position" });
    try h.click(.{ .text = "Unmute" });
    try std.testing.expect(!trailer.muted());
    try h.click(.{ .text = "Mute" });
    try std.testing.expect(trailer.muted());
    try h.click(.{ .text = "Pause" });
    try std.testing.expect(!trailer.playing());
    try h.click(.{ .text = "Close" });
    try std.testing.expect(f.screen.trailer == null and f.waves.playing());
    _ = try h.find(.{ .text = "Wavelength" });
}
