//! Videos that play in a declarative view: a `Player` plays the frames a
//! `Decoder` gives it, and `Player.show` lays it out, fits and names it as
//! `View.image` does a bitmap. `GifDecoder` decodes animated GIFs.
//!
//! Everything runs on the main thread. Building a playing video asks for a
//! pass when its frame ends; the pass that finds it due posts a task that,
//! after paint, decodes the next frame into the player's `ui.PixelImage`,
//! commits it and repaints. Frames that came due while the window drew
//! nothing are decoded and passed over, so the video keeps to its clock.
//! A video moves on only while views build it; one that went out of the
//! view, or whose window stopped painting, goes on from where it stood.
//! Under reduced motion it shows its first frame and decodes nothing.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const gif = @import("ziggurat_gif");

/// Decodes a video's frames one after another for a `Player`.
pub const Decoder = struct {
    context: *anyopaque,
    /// Size of every frame in pixels.
    width: u32,
    height: u32,
    /// Decode the next frame into `pixels`, premultiplied BGRA rows from
    /// the top, `width * height * 4` bytes, and return how long it shows
    /// in nanoseconds; null after the last frame. A frame of no duration
    /// shows for 100 ms.
    next: *const fn (context: *anyopaque, pixels: []u8) anyerror!?u64,
    /// Go back to before the first frame, to play again.
    rewind: *const fn (context: *anyopaque) anyerror!void,
};

/// Duration of a frame that gives none, as browsers show GIF frames.
pub const default_frame: u64 = 100 * std.time.ns_per_ms;
/// Frames decoded at most in one step; a video further behind than that
/// starts its frame again from now.
pub const max_skipped = 64;
/// A pass this long after the last one that built the video is a return to
/// it: the time between does not count.
pub const resume_gap: u64 = 250 * std.time.ns_per_ms;

/// An animated GIF as a `Decoder`: each frame drawn over what the ones
/// before it left, as its disposal says. Keep it at a stable address and
/// the bytes alive while a player uses it.
pub const GifDecoder = struct {
    animation: gif.Animation,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !GifDecoder {
        return .{ .animation = try gif.Animation.init(allocator, bytes) };
    }
    pub fn deinit(self: *GifDecoder) void {
        self.animation.deinit();
    }
    pub fn decoder(self: *GifDecoder) Decoder {
        return .{ .context = self, .width = self.animation.frames.width, .height = self.animation.frames.height, .next = next, .rewind = rewind };
    }
    fn next(ptr: *anyopaque, pixels: []u8) anyerror!?u64 {
        const self: *GifDecoder = @ptrCast(@alignCast(ptr));
        const duration = (try self.animation.next()) orelse return null;
        const canvas = self.animation.canvas;
        if (pixels.len != canvas.len) return error.InvalidValue;
        // Alpha is all or nothing, so premultiplying is clearing.
        var at: usize = 0;
        while (at < canvas.len) : (at += 4) {
            if (canvas[at + 3] == 0) {
                @memset(pixels[at..][0..4], 0);
            } else {
                pixels[at] = canvas[at + 2];
                pixels[at + 1] = canvas[at + 1];
                pixels[at + 2] = canvas[at];
                pixels[at + 3] = 255;
            }
        }
        return duration;
    }
    fn rewind(ptr: *anyopaque) anyerror!void {
        const self: *GifDecoder = @ptrCast(@alignCast(ptr));
        self.animation.rewind();
    }
};

/// Plays a decoder's frames for `show`. Make it once, not in the build,
/// keep it at a stable address, and show it in one place at a time. Call
/// its methods on the main thread; `deinit` outside paint before the
/// Host's Context detaches.
pub const Player = struct {
    allocator: std.mem.Allocator,
    host: *view.Host,
    decoder: Decoder,
    image: ui.PixelImage,
    /// The first frame, shown under reduced motion and to play again.
    first: []u8,
    first_duration: u64,
    /// The frame shown before reduced motion put the first one up.
    stash: []u8 = &.{},
    /// How long the shown frame shows.
    duration: u64,
    /// When the shown frame ends, once a pass built the playing video.
    due: ?u64 = null,
    /// What is left of the shown frame while paused.
    held: ?u64 = null,
    /// The time of the last pass that built the video.
    seen: ?u64 = null,
    /// The shown frame is the first one, from the start.
    at_start: bool = true,
    /// Reduced motion put the first frame up over `stash`.
    stilled: bool = false,
    paused: bool = false,
    looping: bool = false,
    ended: bool = false,
    /// What stopped the video before its end.
    failure: ?anyerror = null,
    /// The upload or post that last failed.
    last_error: ?anyerror = null,
    /// What the posted task does next.
    wanted: Want = .none,
    queued: bool = false,

    pub const Want = enum { none, commit, advance, still, unstill, restart };

    /// Decode the first frame at once, which shows from the first pass and
    /// tells a video that does not decode. A new player plays as soon as a
    /// view shows it.
    pub fn init(allocator: std.mem.Allocator, host: *view.Host, decoder: Decoder) !Player {
        var image = try ui.PixelImage.init(allocator, decoder.width, decoder.height);
        errdefer image.deinit();
        const first = try allocator.alloc(u8, image.pixels().len);
        errdefer allocator.free(first);
        const duration = (try decoder.next(decoder.context, first)) orelse return error.EmptyVideo;
        @memcpy(image.pixels(), first);
        const length = if (duration == 0) default_frame else duration;
        return .{ .allocator = allocator, .host = host, .decoder = decoder, .image = image, .first = first, .first_duration = length, .duration = length, .wanted = .commit };
    }
    /// Release the pixels; the decoder stays the caller's.
    pub fn deinit(self: *Player) void {
        if (self.host.context.window != null) self.image.release(&self.host.context);
        self.image.deinit();
        self.allocator.free(self.first);
        if (self.stash.len != 0) self.allocator.free(self.stash);
        self.* = undefined;
    }

    /// Whether the video plays: neither paused nor ended nor stopped.
    pub fn playing(self: *const Player) bool {
        return !self.paused and !self.ended and self.failure == null;
    }
    /// Hold the frame shown now.
    pub fn pause(self: *Player) void {
        if (self.paused) return;
        self.paused = true;
        if (self.due) |due| self.held = due -| self.host.time();
        self.due = null;
    }
    /// Go on from where it was paused, or play again from the start once
    /// the video ended or a frame failed to decode.
    pub fn play(self: *Player) void {
        if (self.ended or self.failure != null) {
            self.ended = false;
            self.failure = null;
            self.paused = false;
            self.due = null;
            self.held = null;
            self.want(.restart);
            return;
        }
        if (!self.paused) return;
        self.paused = false;
        self.invalidate();
    }
    /// Play again from the start each time the video ends, without a gap.
    pub fn setLoop(self: *Player, value: bool) void {
        self.looping = value;
    }

    /// The video's own size in pixels, which `show` lays it out at as DIP
    /// unless the style says otherwise.
    pub fn size(self: *const Player) view.Size {
        return .{ .width = @floatFromInt(self.image.width), .height = @floatFromInt(self.image.height) };
    }

    /// Show the video's current frame as `View.image` shows a bitmap, and
    /// move the video on while it plays.
    pub fn show(self: *Player, v: *view.View, options: view.ImageOptions, style: view.Style) view.Error!void {
        if (self.image.view()) |picture| {
            try v.image(picture, options, style);
        } else {
            // Before the first commit, keep the place the video takes.
            const natural = self.size();
            try v.svg(.{ .context = self, .width = natural.width, .height = natural.height, .paint = paintNothing }, options, style);
        }
        self.step(v.time(), v.preferences.reduce_motion, v);
    }
    fn paintNothing(_: *anyopaque, _: *ui.Frame, _: view.Rect, _: ui.Color) anyerror!void {}

    /// The build's part: note the pass, and ask for the frame that is due
    /// or a pass when it will be.
    fn step(self: *Player, now: u64, still: bool, v: *view.View) void {
        if (self.seen) |seen| if (now -| seen > resume_gap) {
            if (self.due) |*due| due.* += now - seen;
        };
        self.seen = now;
        if (self.wanted != .none) self.post();
        if (still) {
            if (!self.at_start and !self.stilled) self.want(.still);
            return;
        }
        if (self.stilled) return self.want(.unstill);
        if (!self.playing()) return;
        const due = self.due orelse blk: {
            const start = now + (self.held orelse self.duration);
            self.held = null;
            self.due = start;
            break :blk start;
        };
        if (now >= due) return self.want(.advance);
        v.wakeAt(due);
    }

    fn want(self: *Player, what: Want) void {
        // A restart, still or first commit outranks moving on.
        if (self.wanted == .none or what != .advance) self.wanted = what;
        self.post();
    }
    fn post(self: *Player) void {
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| {
            self.last_error = err;
            return;
        };
        self.queued = true;
    }
    fn invalidate(self: *Player) void {
        if (self.host.context.window) |window| window.invalidate();
    }
    /// Posted after paint.
    fn run(ptr: *anyopaque) void {
        const self: *Player = @ptrCast(@alignCast(ptr));
        self.queued = false;
        if (self.host.context.window == null) return;
        self.perform(self.host.time(), &self.host.context) catch |err| {
            self.last_error = err;
        };
        self.invalidate();
    }

    /// Do what the last build asked for at `now` and commit the picture
    /// into `context`, outside paint.
    pub fn perform(self: *Player, now: u64, context: anytype) !void {
        const what = self.wanted;
        self.wanted = .none;
        const changed = switch (what) {
            .none => false,
            .commit => true,
            .advance => self.advance(now),
            .still => blk: {
                if (self.stash.len == 0) self.stash = try self.allocator.alloc(u8, self.first.len);
                @memcpy(self.stash, self.shown());
                @memcpy(self.image.pixels(), self.first);
                self.stilled = true;
                if (self.due) |due| self.held = due -| now;
                self.due = null;
                break :blk true;
            },
            .unstill => blk: {
                @memcpy(self.image.pixels(), self.stash);
                self.stilled = false;
                break :blk true;
            },
            .restart => blk: {
                self.restart() catch |err| {
                    self.failure = err;
                    break :blk false;
                };
                break :blk true;
            },
        };
        if (changed) try self.image.commit(context);
    }
    /// The picture committed last, or the one about to be.
    fn shown(self: *Player) []const u8 {
        return if (self.image.view() == null) self.image.pixels() else self.image.buffers[self.image.back ^ 1];
    }
    /// Decode the frames due at `now`; true when a new one is ready.
    fn advance(self: *Player, now: u64) bool {
        var due = self.due orelse return false;
        var decoded = false;
        var count: usize = 0;
        while (due <= now and count < max_skipped) : (count += 1) {
            const pixels = self.image.pixels();
            const length = self.decoder.next(self.decoder.context, pixels) catch |err| {
                self.failure = err;
                break;
            } orelse {
                if (!self.looping) {
                    self.ended = true;
                    break;
                }
                self.restart() catch |err| {
                    self.failure = err;
                    break;
                };
                due += self.duration;
                decoded = true;
                continue;
            };
            self.duration = if (length == 0) default_frame else length;
            self.at_start = false;
            due += self.duration;
            decoded = true;
        }
        // Far behind: the frame shown now starts now.
        if (due <= now) due = now + self.duration;
        self.due = if (self.playing()) due else null;
        return decoded;
    }
    /// Show the first frame again, with the decoder just past it.
    fn restart(self: *Player) !void {
        try self.decoder.rewind(self.decoder.context);
        const pixels = self.image.pixels();
        _ = (try self.decoder.next(self.decoder.context, pixels)) orelse return error.EmptyVideo;
        self.duration = self.first_duration;
        self.at_start = true;
    }
};

// Tests run headless: a fake Context takes the commits and the build runs
// in a Harness, whose clock moves only when told.

const Frames = struct {
    count: u8,
    at: u8 = 0,
    failing: ?u8 = null,
    rewinds: usize = 0,
    fn decoder(self: *Frames) Decoder {
        return .{ .context = self, .width = 1, .height = 1, .next = next, .rewind = rewind };
    }
    fn next(ptr: *anyopaque, pixels: []u8) anyerror!?u64 {
        const self: *Frames = @ptrCast(@alignCast(ptr));
        if (self.at == self.count) return null;
        if (self.failing == self.at) return error.BrokenFrame;
        pixels[0] = self.at;
        self.at += 1;
        return 40 * std.time.ns_per_ms;
    }
    fn rewind(ptr: *anyopaque) anyerror!void {
        const self: *Frames = @ptrCast(@alignCast(ptr));
        self.at = 0;
        self.rewinds += 1;
    }
};
const Uploads = struct {
    count: usize = 0,
    pub fn uploadDynamicImage(self: *Uploads, _: ui.drawing.ImageView) !void {
        self.count += 1;
    }
    pub fn updateImage(self: *Uploads, _: u64, _: ui.drawing.ImageView) !void {
        self.count += 1;
    }
    pub fn releaseImage(_: *Uploads, _: u64) !bool {
        return true;
    }
};
const Screen = struct {
    player: *Player,
    shown: bool = true,
    fn build(self: *Screen, v: *view.View) anyerror!void {
        if (self.shown) try self.player.show(v, .{ .alt = "Waves" }, .{});
    }
};
const ms = std.time.ns_per_ms;

const Windowless = struct {
    var state: Windowless = .{};
    var storage: view.Storage(4, 64) = .{};
    fn build(_: *Windowless, _: *view.View) anyerror!void {}
};
/// A Host never attached to a window: the player's tasks are not posted.
fn hostless() view.Host {
    return view.Host.init(&Windowless.state, Windowless.build, Windowless.storage.buffers(), .{});
}
fn frameOf(player: *Player) u8 {
    return player.image.buffers[player.image.back ^ 1][0];
}
fn pass(harness: *view.Harness, player: *Player, uploads: *Uploads, at: u64) !void {
    harness.clock = at;
    harness.view.wake = null;
    try harness.render();
    try player.perform(at, uploads);
}

test "frames show as they come due and the view asks for a pass when the next one is" {
    var host = hostless();
    var frames: Frames = .{ .count = 3 };
    var player = try Player.init(std.testing.allocator, &host, frames.decoder());
    defer player.deinit();
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};

    try pass(&harness, &player, &uploads, 0);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    try std.testing.expectEqual(@as(?u64, 40 * ms), harness.view.wake);
    try std.testing.expect((try harness.find(.{ .name = "Waves" })).kind == .svg);
    try pass(&harness, &player, &uploads, 10 * ms);
    try std.testing.expect((try harness.find(.{ .name = "Waves" })).kind == .image);
    try std.testing.expectEqual(@as(usize, 1), uploads.count);
    try pass(&harness, &player, &uploads, 40 * ms);
    try std.testing.expectEqual(@as(u8, 1), frameOf(&player));
    try std.testing.expectEqual(@as(usize, 2), uploads.count);
    try pass(&harness, &player, &uploads, 50 * ms);
    try std.testing.expectEqual(@as(?u64, 80 * ms), harness.view.wake);
    // A late pass passes over the frames that came due meanwhile.
    try pass(&harness, &player, &uploads, 125 * ms);
    try std.testing.expectEqual(@as(u8, 2), frameOf(&player));
    try std.testing.expectEqual(@as(usize, 3), uploads.count);
    // It ends on its last frame and asks for nothing more.
    try pass(&harness, &player, &uploads, 160 * ms);
    try std.testing.expect(player.ended and !player.playing());
    try std.testing.expectEqual(@as(u8, 2), frameOf(&player));
    try pass(&harness, &player, &uploads, 170 * ms);
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
    // Playing again starts over.
    player.play();
    try pass(&harness, &player, &uploads, 200 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    try std.testing.expect(player.playing());
}

test "looping, pausing, leaving the view and reduced motion" {
    var host = hostless();
    var frames: Frames = .{ .count = 2 };
    var player = try Player.init(std.testing.allocator, &host, frames.decoder());
    defer player.deinit();
    player.setLoop(true);
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};

    try pass(&harness, &player, &uploads, 0);
    try pass(&harness, &player, &uploads, 40 * ms);
    try std.testing.expectEqual(@as(u8, 1), frameOf(&player));
    // The end plays again from the start without a gap.
    try pass(&harness, &player, &uploads, 80 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    try std.testing.expectEqual(@as(usize, 1), frames.rewinds);
    try std.testing.expectEqual(@as(?u64, 120 * ms), player.due);

    // Out of the view, it stands still; back, it goes on where it stood.
    screen.shown = false;
    try pass(&harness, &player, &uploads, 100 * ms);
    try pass(&harness, &player, &uploads, 5000 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    screen.shown = true;
    try pass(&harness, &player, &uploads, 5010 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    // It had 40 ms of its frame left when it was last built.
    try std.testing.expectEqual(@as(?u64, 5050 * ms), harness.view.wake);

    // Reduced motion shows the first frame and asks for no pass.
    try pass(&harness, &player, &uploads, 5050 * ms);
    try std.testing.expectEqual(@as(u8, 1), frameOf(&player));
    harness.view.preferences.reduce_motion = true;
    try pass(&harness, &player, &uploads, 5060 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    try pass(&harness, &player, &uploads, 5100 * ms);
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
    harness.view.preferences.reduce_motion = false;
    try pass(&harness, &player, &uploads, 5110 * ms);
    try std.testing.expectEqual(@as(u8, 1), frameOf(&player));
    try pass(&harness, &player, &uploads, 5112 * ms);
    try std.testing.expectEqual(@as(?u64, 5142 * ms), harness.view.wake);

    // Paused, it holds its frame and what was left of it.
    player.pause();
    try pass(&harness, &player, &uploads, 9000 * ms);
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
    try std.testing.expect(!player.playing());
}

test "a frame that fails to decode stops the video on the last good one" {
    var host = hostless();
    var frames: Frames = .{ .count = 3, .failing = 1 };
    var player = try Player.init(std.testing.allocator, &host, frames.decoder());
    defer player.deinit();
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};
    try pass(&harness, &player, &uploads, 0);
    try pass(&harness, &player, &uploads, 40 * ms);
    try std.testing.expectEqual(@as(?anyerror, error.BrokenFrame), player.failure);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    var empty: Frames = .{ .count = 0 };
    try std.testing.expectError(error.EmptyVideo, Player.init(std.testing.allocator, &host, empty.decoder()));
}

test "a GIF decodes into premultiplied BGRA frames" {
    const bytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\xff\x00" ++
        "\x21\xf9\x04\x08\x03\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00" ++
        "\x21\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00;";
    var decoder = try GifDecoder.init(std.testing.allocator, bytes);
    defer decoder.deinit();
    const source = decoder.decoder();
    var pixels: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?u64, 30 * ms), try source.next(source.context, &pixels));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pixels);
    // The second frame's only pixel is transparent.
    try std.testing.expectEqual(@as(?u64, 100 * ms), try source.next(source.context, &pixels));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &pixels);
    try std.testing.expectEqual(@as(?u64, null), try source.next(source.context, &pixels));
}
