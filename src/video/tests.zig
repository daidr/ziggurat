//! The system's engine playing a short clip: rgb.mp4 is 1.2 s of H.264 at
//! 10 fps, 64×48, and silent AAC: 0.4 s red, then green, then blue. It has
//! no B-frames, so no edit list shifts its pictures' times. Tests skip on a
//! system without an engine or an H.264 decoder.
const std = @import("std");
const zio = @import("ziggurat_io");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const video = @import("ziggurat_view_video");
const root = @import("root.zig");

const rgb_mp4 = root.test_clip;
const ms = std.time.ns_per_ms;

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

const Screen = struct {
    player: *video.Player,
    fn build(self: *Screen, v: *view.View) anyerror!void {
        try self.player.show(v, .{ .alt = "Clip" }, .{ .width = 64, .height = 48 });
    }
};

const Windowless = struct {
    var state: Windowless = .{};
    var storage: view.Storage(4, 64) = .{};
    fn build(_: *Windowless, _: *view.View) anyerror!void {}
};

const Played = struct {
    host: view.Host,
    player: video.Player,
    screen: Screen,
    storage: view.Storage(8, 256),
    harness: view.Harness,
    uploads: Uploads,

    /// Open the clip as `open` does and show it, skipping the test on a
    /// system that has no engine or no decoder.
    fn init(self: *Played, open: anytype, args: anytype) !void {
        self.host = view.Host.init(&Windowless.state, Windowless.build, Windowless.storage.buffers(), .{});
        self.player = @call(.auto, open, .{ std.testing.allocator, &self.host } ++ args) catch |err| switch (err) {
            error.Unsupported => return error.SkipZigTest,
            else => return err,
        };
        self.player.setMuted(true);
        self.screen = .{ .player = &self.player };
        self.storage = .{};
        self.harness = view.Harness.init(&self.screen, Screen.build, self.storage.buffers(), .{});
        self.uploads = .{};
        self.wait(struct {
            fn ready(p: *Played) bool {
                return p.player.ready();
            }
        }.ready) catch |err| {
            if (self.player.err() != null) {
                self.player.deinit();
                return error.SkipZigTest;
            }
            return err;
        };
    }
    fn deinit(self: *Played) void {
        self.player.deinit();
    }
    /// A frame: the build, then the picture the engine has.
    fn frame(self: *Played) !void {
        self.harness.clock += 10 * ms;
        try self.harness.render();
        self.player.performEngine(&self.uploads);
    }
    fn wait(self: *Played, comptime done: fn (*Played) bool) !void {
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            try self.frame();
            if (self.player.err() != null) return error.VideoFailed;
            if (done(self)) return;
            zio.sleep(10 * ms);
        }
        return error.Timeout;
    }
    /// The color of the picture's middle, as the software renderer draws it.
    fn shows(self: *Played) [3]u8 {
        const ep = self.player.engine.?;
        const picture = ep.picture.view() orelse return .{ 0, 0, 0 };
        if (!picture.video.?.ensure(picture)) return .{ 0, 0, 0 };
        const level = picture.levels[0];
        const p = level.pixels[(level.height / 2) * level.stride + (level.width / 2) * 4 ..][0..4];
        return .{ p[2], p[1], p[0] };
    }
};

fn near(color: [3]u8, want: [3]u8) bool {
    for (color, want) |a, b| if (@max(a, b) - @min(a, b) > 24) return false;
    return true;
}
const red = [3]u8{ 255, 0, 0 };
const green = [3]u8{ 0, 255, 0 };
const blue = [3]u8{ 0, 0, 255 };

fn showing(comptime want: [3]u8) fn (*Played) bool {
    return struct {
        fn check(p: *Played) bool {
            return near(p.shows(), want);
        }
    }.check;
}
fn ended(p: *Played) bool {
    return p.player.ended();
}

test "a video in memory plays its frames in order to its end, reporting its length" {
    var played: Played = undefined;
    try played.init(root.openData, .{rgb_mp4});
    defer played.deinit();
    const player = &played.player;
    try std.testing.expectEqual(view.Size{ .width = 64, .height = 48 }, player.size());
    const length = player.duration();
    try std.testing.expect(length >= 1100 * ms and length <= 1300 * ms);
    try played.wait(showing(red));
    try played.wait(showing(green));
    try played.wait(showing(blue));
    try played.wait(ended);
    try std.testing.expect(!player.playing() and near(played.shows(), blue));
}

test "a paused video shows the picture a seek asks for, and one played again after its end starts over" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(zio.io(), .{ .sub_path = "a video.mp4", .data = rgb_mp4 });
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try zio.realpath(tmp.dir, ".", &dir_buffer);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/a video.mp4", .{dir});

    var played: Played = undefined;
    try played.init(root.open, .{path});
    defer played.deinit();
    const player = &played.player;
    player.pause();
    const stops = [_]struct { at: u64, check: *const fn (*Played) bool }{
        .{ .at = 900 * ms, .check = showing(blue) },
        .{ .at = 500 * ms, .check = showing(green) },
        .{ .at = 100 * ms, .check = showing(red) },
    };
    for (stops) |stop| {
        player.seek(stop.at);
        var tries: usize = 0;
        while (!stop.check(&played)) : (tries += 1) {
            if (tries == 1000) return error.Timeout;
            try played.frame();
            zio.sleep(10 * ms);
        }
        const at = player.position();
        try std.testing.expect(at + 100 * ms >= stop.at and at <= stop.at + 100 * ms);
        try std.testing.expect(!player.playing());
    }
    player.seek(1000 * ms);
    player.play();
    try played.wait(ended);
    player.play();
    try played.wait(showing(red));
}
