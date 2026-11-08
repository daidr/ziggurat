//! Videos that play in a declarative view: a `Player` plays the frames a
//! `Decoder` gives it, or a video an `Engine` of the system's media
//! framework plays (`ziggurat_video` opens them), and `Player.show` lays it
//! out, fits and names it as `View.image` does a bitmap. `GifDecoder`
//! decodes animated GIFs and `ApngDecoder` animated PNGs.
//!
//! Everything runs on the main thread. Building a playing decoder's video
//! asks for a pass when its frame ends; the pass that finds it due posts a
//! task that, after paint, decodes the next frame into the player's
//! `ui.PixelImage`, commits it and repaints. Frames that came due while the
//! window drew nothing are decoded and passed over, so the video keeps to
//! its clock. A decoder's video moves on only while views build it; one
//! that went out of the view, or whose window stopped painting, goes on
//! from where it stood. Under reduced motion it shows its first frame and
//! decodes nothing.
//!
//! An engine decodes, plays the sound and keeps the clock itself, on
//! threads of its own: it wakes the player as each picture comes, or the
//! player asks for a pass as each comes due, and a task posted after paint
//! commits the picture where the engine left it (`ui.VideoImage`). A video
//! with sound plays on while out of sight, as a browser's does; a muted
//! one is a picture, as a decoder's: it holds while out of the view or
//! the window out of sight, and under reduced motion.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const gif = @import("ziggurat_gif");
const apng = @import("ziggurat_apng");

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
    /// The video's length in nanoseconds, which `Player.duration` reports;
    /// null, or 0, while unknown.
    duration: ?*const fn (context: *anyopaque) u64 = null,
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
    length: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !GifDecoder {
        return .{ .animation = try gif.Animation.init(allocator, bytes) };
    }
    pub fn deinit(self: *GifDecoder) void {
        self.animation.deinit();
    }
    pub fn decoder(self: *GifDecoder) Decoder {
        return .{ .context = self, .width = self.animation.frames.width, .height = self.animation.frames.height, .next = next, .rewind = rewind, .duration = duration };
    }
    fn next(ptr: *anyopaque, pixels: []u8) anyerror!?u64 {
        const self: *GifDecoder = @ptrCast(@alignCast(ptr));
        const delay = (try self.animation.next()) orelse return null;
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
        return delay;
    }
    fn rewind(ptr: *anyopaque) anyerror!void {
        const self: *GifDecoder = @ptrCast(@alignCast(ptr));
        self.animation.rewind();
    }
    /// The delays of all the frames, as `next` reports them.
    fn duration(ptr: *anyopaque) u64 {
        const self: *GifDecoder = @ptrCast(@alignCast(ptr));
        if (self.length) |known| return known;
        var frames = self.animation.frames;
        frames.reset();
        var total: u64 = 0;
        while (frames.next() catch null) |frame| {
            const delay: u64 = if (frame.delay <= 1) 10 else frame.delay;
            total += delay * 10 * std.time.ns_per_ms;
        }
        self.length = total;
        return total;
    }
};

/// An animated PNG as a `Decoder`, as browsers show one: each frame drawn
/// over what the ones before it left, as its disposal and blending say,
/// and a frame of 10 ms or less shown for 100 ms. A PNG that is not
/// animated is a video of one frame. Frames stay compressed and decode as
/// they play; the bytes need not outlive the decoder. The player's loop,
/// not the PNG's count of plays, says whether it plays again. Keep it at a
/// stable address while a player uses it.
pub const ApngDecoder = struct {
    animation: apng.Animation,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !ApngDecoder {
        return .{ .animation = try apng.Animation.init(allocator, bytes) };
    }
    pub fn deinit(self: *ApngDecoder) void {
        self.animation.deinit();
    }
    pub fn decoder(self: *ApngDecoder) Decoder {
        return .{ .context = self, .width = self.animation.width, .height = self.animation.height, .next = next, .rewind = rewind, .duration = length };
    }
    /// The length of the animation, in nanoseconds.
    pub fn duration(self: *const ApngDecoder) u64 {
        return self.animation.duration();
    }
    fn length(ptr: *anyopaque) u64 {
        const self: *ApngDecoder = @ptrCast(@alignCast(ptr));
        return self.duration();
    }
    fn next(ptr: *anyopaque, pixels: []u8) anyerror!?u64 {
        const self: *ApngDecoder = @ptrCast(@alignCast(ptr));
        if (pixels.len != self.animation.canvas.len) return error.InvalidValue;
        const shows = (try self.animation.next()) orelse return null;
        @memcpy(pixels, self.animation.canvas);
        return shows;
    }
    fn rewind(ptr: *anyopaque) anyerror!void {
        const self: *ApngDecoder = @ptrCast(@alignCast(ptr));
        self.animation.rewind();
    }
};

/// How loading and playing go for an `Engine`.
pub const State = enum {
    /// Before the video's first picture and size are known.
    loading,
    /// Playing or paused with pictures to show.
    ready,
    /// Waiting for data a stream is still downloading.
    buffering,
    /// Past the end of a video that does not loop.
    ended,
    /// Stopped with an error.
    failed,
};

/// A picture an engine has due, and whether it is another than the one it
/// gave last.
pub const Frame = struct {
    picture: ui.drawing.VideoPicture,
    changed: bool,
};

/// What an engine calls, from any thread, when the window showing its video
/// should take a picture or a change of state.
pub const Wake = struct {
    context: *anyopaque,
    call: *const fn (context: *anyopaque) void,
};

/// A video that the system's media framework plays: it decodes, plays the
/// sound and keeps the clock. Its functions are called on the main thread,
/// one at a time; `ziggurat_video` makes them.
pub const Engine = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The wake the engine calls, from any thread, as its first
        /// picture comes, its state changes or a seek lands, and, for an
        /// engine of no `interval`, as each picture comes. A change
        /// `frame` itself makes, as loading to ready by the first picture,
        /// needs none. Null stops it.
        set_wake: *const fn (context: *anyopaque, wake: ?Wake) void,
        /// The picture due `ahead` nanoseconds from now, as the frame being
        /// built shows; null while there is none yet. It stays valid until
        /// `frame` returns another, or the engine closes.
        frame: *const fn (context: *anyopaque, ahead: u64) ?Frame,
        /// How long a picture shows at the video's rate at rate 1, for the
        /// player to ask for a pass as each comes due; 0 for an engine that
        /// wakes the player as each comes.
        interval: *const fn (context: *anyopaque) u64,
        state: *const fn (context: *anyopaque) State,
        /// What stopped the video, once `state` is failed.
        failure: *const fn (context: *anyopaque) ?anyerror,
        /// The size of the pictures in pixels, 0×0 until known.
        size: *const fn (context: *anyopaque) [2]u32,
        /// The length in nanoseconds; 0 until known, or for a live stream.
        duration: *const fn (context: *anyopaque) u64,
        position: *const fn (context: *anyopaque) u64,
        play: *const fn (context: *anyopaque) void,
        pause: *const fn (context: *anyopaque) void,
        seek: *const fn (context: *anyopaque, at: u64) void,
        set_loop: *const fn (context: *anyopaque, loop: bool) void,
        set_rate: *const fn (context: *anyopaque, rate: f64) void,
        set_volume: *const fn (context: *anyopaque, volume: f64) void,
        set_muted: *const fn (context: *anyopaque, muted: bool) void,
        /// Stops the video and its sound and frees the engine; the last
        /// picture stays valid until the player released it.
        close: *const fn (context: *anyopaque) void,
    };
};

/// Plays a decoder's frames, or an engine's video, for `show`. Make it
/// once, not in the build, keep it at a stable address, and show it in one
/// place at a time. Call its methods on the main thread; `deinit` outside
/// paint before the Host's Context detaches.
pub const Player = struct {
    allocator: std.mem.Allocator,
    host: *view.Host,
    /// The decoder's frames: a decoder's player only.
    decoder: Decoder,
    image: ui.PixelImage,
    /// The first frame, shown under reduced motion and to play again.
    first: []u8,
    first_duration: u64,
    /// The frame shown before reduced motion put the first one up.
    stash: []u8 = &.{},
    /// How long the shown frame shows, in the video's time.
    duration_shown: u64,
    /// Where the shown frame starts in the video.
    frame_at: u64 = 0,
    /// When the shown frame ends, once a pass built the playing video.
    due: ?u64 = null,
    /// What is left of the shown frame while paused, in the window's time.
    held: ?u64 = null,
    /// The time of the last pass that built the video.
    seen: ?u64 = null,
    /// The shown frame is the first one, from the start.
    at_start: bool = true,
    /// Reduced motion put the first frame up over `stash`.
    stilled: bool = false,
    paused: bool = false,
    looping: bool = false,
    ended_: bool = false,
    closed: bool = false,
    /// What stopped the video before its end.
    failure: ?anyerror = null,
    /// The upload or post that last failed.
    last_error: ?anyerror = null,
    /// What the posted task does next.
    wanted: Want = .none,
    queued: bool = false,
    /// Where a seek asked for goes, until the task decodes to it.
    seek_to: ?u64 = null,
    rate_: f64 = 1,
    volume_: f64 = 1,
    muted_: bool = false,
    /// The engine playing the video, for an engine's player.
    engine: ?*EnginePlay = null,

    pub const Want = enum { none, commit, advance, still, unstill, restart, seek, picture };

    /// Decode the first frame at once, which shows from the first pass and
    /// tells a video that does not decode. A new player plays as soon as a
    /// view shows it.
    pub fn init(allocator: std.mem.Allocator, host: *view.Host, decoder: Decoder) !Player {
        var image = try ui.PixelImage.init(allocator, decoder.width, decoder.height);
        errdefer image.deinit();
        const first = try allocator.alloc(u8, image.pixels().len);
        errdefer allocator.free(first);
        const first_length = (try decoder.next(decoder.context, first)) orelse return error.EmptyVideo;
        @memcpy(image.pixels(), first);
        const length = if (first_length == 0) default_frame else first_length;
        return .{ .allocator = allocator, .host = host, .decoder = decoder, .image = image, .first = first, .first_duration = length, .duration_shown = length, .wanted = .commit };
    }
    /// A player of a video `engine` plays, which `ziggurat_video` opens. It
    /// holds the engine paused until a view shows the video, then plays
    /// it, unless paused. Closing the player closes the engine.
    pub fn initEngine(allocator: std.mem.Allocator, host: *view.Host, engine: Engine) !Player {
        const ep = try allocator.create(EnginePlay);
        errdefer allocator.destroy(ep);
        const waker = try allocator.create(Waker);
        waker.* = .{ .allocator = allocator };
        ep.* = .{ .engine = engine, .picture = ui.VideoImage.init(allocator), .waker = waker };
        engine.vtable.set_wake(engine.context, .{ .context = waker, .call = Waker.wake });
        return .{ .allocator = allocator, .host = host, .decoder = undefined, .image = undefined, .first = &.{}, .first_duration = 0, .duration_shown = 0, .engine = ep };
    }
    /// Release the pixels and close the engine; a decoder stays the
    /// caller's.
    pub fn deinit(self: *Player) void {
        if (self.engine) |ep| {
            self.close();
            if (ep.view) |v| v.forgetMedia(self);
            if (self.host.context.window != null) ep.picture.release(&self.host.context);
            ep.picture.deinit();
            ep.waker.retire();
            self.allocator.destroy(ep);
            self.* = undefined;
            return;
        }
        if (self.host.context.window != null) self.image.release(&self.host.context);
        self.image.deinit();
        self.allocator.free(self.first);
        if (self.stash.len != 0) self.allocator.free(self.stash);
        self.* = undefined;
    }

    /// Whether the video plays: neither paused nor ended nor stopped. It
    /// plays while out of sight too, though a decoder's does not move on
    /// then.
    pub fn playing(self: *const Player) bool {
        if (self.engine) |ep| return ep.playing();
        return !self.paused and !self.ended_ and self.failure == null and !self.closed;
    }
    /// Whether the video played to its end, and stands at its last frame;
    /// `play` plays it again.
    pub fn ended(self: *const Player) bool {
        if (self.engine) |ep| return ep.state == .ended;
        return self.ended_ and !self.closed and self.failure == null;
    }
    /// Whether the video has a picture to show: always for a decoder's,
    /// and for an engine's once its first picture came.
    pub fn ready(self: *const Player) bool {
        if (self.engine) |ep| return ep.ready;
        return true;
    }
    /// Whether a stream waits for data it downloads, as a player shows a
    /// spinner for.
    pub fn buffering(self: *const Player) bool {
        if (self.engine) |ep| return ep.state == .buffering;
        return false;
    }
    /// What stopped the video before its end, as a frame that did not
    /// decode or a stream that broke off: the video shows the frame before
    /// it.
    pub fn err(self: *const Player) ?anyerror {
        if (self.engine) |ep| return ep.failure;
        return self.failure;
    }
    /// Whether the video plays again as it ends.
    pub fn loop(self: *const Player) bool {
        return self.looping;
    }

    /// Hold the frame shown now.
    pub fn pause(self: *Player) void {
        if (self.engine) |ep| {
            if (ep.closed) return;
            ep.paused = true;
            ep.engine.vtable.pause(ep.engine.context);
            self.invalidate();
            return;
        }
        if (self.paused) return;
        self.paused = true;
        if (self.due) |due| self.held = due -| self.host.time();
        self.due = null;
    }
    /// Go on from where it was paused, or play again from the start once
    /// the video ended or a frame failed to decode.
    pub fn play(self: *Player) void {
        if (self.engine) |ep| {
            if (ep.closed) return;
            ep.paused = false;
            if (ep.state == .ended) {
                ep.engine.vtable.seek(ep.engine.context, 0);
                ep.state = .ready;
            }
            if (!ep.held) ep.engine.vtable.play(ep.engine.context);
            self.invalidate();
            return;
        }
        if (self.closed) return;
        if (self.ended_ or self.failure != null) {
            self.ended_ = false;
            self.failure = null;
            self.paused = false;
            self.due = null;
            self.held = null;
            self.seek_to = null;
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
        if (self.engine) |ep| if (!ep.closed) ep.engine.vtable.set_loop(ep.engine.context, value);
    }

    /// The length of the video in nanoseconds: 0 while unknown, as for a
    /// live stream, or a decoder that does not report it.
    pub fn duration(self: *const Player) u64 {
        if (self.engine) |ep| return if (ep.closed) 0 else ep.engine.vtable.duration(ep.engine.context);
        const of = self.decoder.duration orelse return 0;
        return of(self.decoder.context);
    }
    /// The time of the video the player shows, in nanoseconds.
    pub fn position(self: *const Player) u64 {
        if (self.engine) |ep| return if (ep.closed) ep.last_position else ep.engine.vtable.position(ep.engine.context);
        if (self.seek_to) |target| return target;
        if (self.ended_) return self.frame_at + self.duration_shown;
        // What is left of the shown frame in the window's time, as it
        // plays, or as it was paused.
        const left: u64 = if (self.due) |due| due -| self.host.time() else self.held orelse return self.frame_at;
        return self.frame_at + (self.duration_shown -| self.videoSpan(left));
    }
    /// Show the video at `at` nanoseconds from its start, and go on playing
    /// from there unless paused: a decoder's video decodes from its start
    /// up to the frame showing then, after paint.
    pub fn seek(self: *Player, at: u64) void {
        if (self.engine) |ep| {
            if (ep.closed) return;
            ep.engine.vtable.seek(ep.engine.context, at);
            if (ep.state == .ended) ep.state = .ready;
            self.invalidate();
            return;
        }
        if (self.closed) return;
        self.seek_to = at;
        self.want(.seek);
    }
    /// Play the video `value` times as fast, keeping the pitch of its
    /// sound: 0.5 at half speed, 2 at double. A rate of none or less is 1.
    pub fn setRate(self: *Player, value: f64) void {
        const new_rate = if (value > 0 and std.math.isFinite(value)) value else 1;
        if (self.engine) |ep| {
            self.rate_ = new_rate;
            if (!ep.closed) ep.engine.vtable.set_rate(ep.engine.context, new_rate);
            return;
        }
        // What is left of the shown frame goes on at the new rate.
        if (self.due) |due| {
            const now = self.host.time();
            const left = self.videoSpan(due -| now);
            self.rate_ = new_rate;
            self.due = now + self.hostSpan(left);
        } else if (self.held) |held| {
            const left = self.videoSpan(held);
            self.rate_ = new_rate;
            self.held = self.hostSpan(left);
        } else self.rate_ = new_rate;
    }
    /// How fast the video plays (`setRate`).
    pub fn rate(self: *const Player) f64 {
        return self.rate_;
    }
    /// Set the volume of the video's sound, from 0 to 1, the full volume
    /// it has from the start. A decoder's video has no sound.
    pub fn setVolume(self: *Player, value: f64) void {
        self.volume_ = if (std.math.isNan(value)) 1 else std.math.clamp(value, 0, 1);
        if (self.engine) |ep| if (!ep.closed) ep.engine.vtable.set_volume(ep.engine.context, self.volume_);
    }
    pub fn volume(self: *const Player) f64 {
        return self.volume_;
    }
    /// Silence the video's sound, or play it again. A muted video is a
    /// picture only, as a background is: it holds while out of sight and
    /// shows its first frame under reduced motion, rather than play.
    pub fn setMuted(self: *Player, value: bool) void {
        self.muted_ = value;
        if (self.engine) |ep| {
            if (ep.closed) return;
            ep.engine.vtable.set_muted(ep.engine.context, value);
            // Held while muted out of the view, it plays on, unseen, with
            // its sound.
            if (!value and ep.shown) ep.hold(false);
        }
    }
    pub fn muted(self: *const Player) bool {
        return self.muted_;
    }
    /// Stop decoding, or stop the engine and its sound. The video shows
    /// the frame it was at.
    pub fn close(self: *Player) void {
        if (self.engine) |ep| {
            if (ep.closed) return;
            ep.last_position = ep.engine.vtable.position(ep.engine.context);
            ep.closed = true;
            // The engine frees its pictures: the one shown stays as BGRA.
            ep.picture.keep();
            ep.engine.vtable.set_wake(ep.engine.context, null);
            ep.engine.vtable.close(ep.engine.context);
            ep.state = .ended;
            return;
        }
        if (self.closed) return;
        self.closed = true;
        self.ended_ = true;
        self.due = null;
        self.seek_to = null;
        if (self.wanted == .advance or self.wanted == .seek or self.wanted == .restart) self.wanted = .none;
    }

    /// The video's own size in pixels, which `show` lays it out at as DIP
    /// unless the style says otherwise: 0×0 until an engine's video is
    /// ready.
    pub fn size(self: *const Player) view.Size {
        if (self.engine) |ep| {
            if (ep.picture.committed == null) return .{};
            return .{ .width = @floatFromInt(ep.picture.width), .height = @floatFromInt(ep.picture.height) };
        }
        return .{ .width = @floatFromInt(self.image.width), .height = @floatFromInt(self.image.height) };
    }

    /// Show the video's current frame as `View.image` shows a bitmap, and
    /// move the video on while it plays.
    pub fn show(self: *Player, v: *view.View, options: view.ImageOptions, style: view.Style) view.Error!void {
        const picture = if (self.engine) |ep| ep.picture.view() else self.image.view();
        if (picture) |drawn| {
            try v.image(drawn, options, style);
        } else {
            // Before the first commit, keep the place the video takes: an
            // engine's, of no size yet, a point unless the style sizes it.
            const natural = self.size();
            try v.svg(.{ .context = self, .width = @max(natural.width, 1), .height = @max(natural.height, 1), .paint = paintNothing }, options, style);
        }
        if (self.engine != null) return self.stepEngine(v);
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
        if (!self.playing() or self.seek_to != null) return;
        const due = self.due orelse blk: {
            const start = now + (self.held orelse self.hostSpan(self.duration_shown));
            self.held = null;
            self.due = start;
            break :blk start;
        };
        if (now >= due) return self.want(.advance);
        v.wakeAt(due);
    }
    /// A span of the video's time in the window's, at the rate.
    fn hostSpan(self: *const Player, span: u64) u64 {
        if (self.rate_ == 1) return span;
        return @intFromFloat(@as(f64, @floatFromInt(span)) / self.rate_);
    }
    fn videoSpan(self: *const Player, span: u64) u64 {
        if (self.rate_ == 1) return span;
        return @intFromFloat(@as(f64, @floatFromInt(span)) * self.rate_);
    }

    fn want(self: *Player, what: Want) void {
        // A restart, seek, still or first commit outranks moving on.
        if (self.wanted == .none or what != .advance) self.wanted = what;
        self.post();
    }
    fn post(self: *Player) void {
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |e| {
            self.last_error = e;
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
        if (self.engine != null) {
            self.wanted = .none;
            return self.takePicture();
        }
        self.perform(self.host.time(), &self.host.context) catch |e| {
            self.last_error = e;
        };
        self.invalidate();
    }

    /// Do what the last build asked for at `now` and commit the picture
    /// into `context`, outside paint.
    pub fn perform(self: *Player, now: u64, context: anytype) !void {
        const what = self.wanted;
        self.wanted = .none;
        const changed = switch (what) {
            .none, .picture => false,
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
                self.restart() catch |e| {
                    self.failure = e;
                    break :blk false;
                };
                break :blk true;
            },
            .seek => self.seekDecoder(now),
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
            const length = self.decoder.next(self.decoder.context, pixels) catch |e| {
                self.failure = e;
                break;
            } orelse {
                if (!self.looping) {
                    self.ended_ = true;
                    break;
                }
                self.restart() catch |e| {
                    self.failure = e;
                    break;
                };
                due += self.hostSpan(self.duration_shown);
                decoded = true;
                continue;
            };
            self.frame_at += self.duration_shown;
            self.duration_shown = if (length == 0) default_frame else length;
            self.at_start = false;
            due += self.hostSpan(self.duration_shown);
            decoded = true;
        }
        // Far behind: the frame shown now starts now.
        if (due <= now) due = now + self.hostSpan(self.duration_shown);
        self.due = if (self.playing()) due else null;
        return decoded;
    }
    /// Show the first frame again, with the decoder just past it.
    fn restart(self: *Player) !void {
        try self.decoder.rewind(self.decoder.context);
        const pixels = self.image.pixels();
        _ = (try self.decoder.next(self.decoder.context, pixels)) orelse return error.EmptyVideo;
        self.duration_shown = self.first_duration;
        self.frame_at = 0;
        self.at_start = true;
    }
    /// Decode from the start to the frame showing at the seek's time, or
    /// the last frame, ended, for a time at or past the end of a video that
    /// does not loop; true when it decoded one.
    fn seekDecoder(self: *Player, now: u64) bool {
        const target = self.seek_to orelse return false;
        self.seek_to = null;
        self.decoder.rewind(self.decoder.context) catch |e| {
            self.failure = e;
            return false;
        };
        const pixels = self.image.pixels();
        var at: u64 = 0;
        var length: u64 = 0;
        var found = false;
        var end = false;
        while (true) {
            const next = self.decoder.next(self.decoder.context, pixels) catch |e| {
                self.failure = e;
                return found;
            } orelse {
                end = true;
                break;
            };
            if (found) at += length;
            length = if (next == 0) default_frame else next;
            found = true;
            if (at + length > target) break;
        }
        if (!found) {
            self.failure = error.EmptyVideo;
            return false;
        }
        self.failure = null;
        self.frame_at = at;
        self.duration_shown = length;
        self.at_start = at == 0;
        // The shown frame under reduced motion is the first; this one
        // shows once motion is back.
        self.stilled = false;
        if (end and !self.looping) {
            // Past the end: the last frame, ended, and played again from
            // the start by `play`.
            self.ended_ = true;
            self.due = null;
            self.held = null;
            return true;
        }
        self.ended_ = false;
        // Looping past the end, the decoder stands at the end: the frame
        // after the last plays the video again from its start.
        const left = self.hostSpan(length - @min(length, target - at));
        if (self.paused) {
            self.held = left;
            self.due = null;
        } else {
            self.held = null;
            self.due = if (self.seen != null) now + left else null;
            if (self.due == null) self.held = left;
        }
        return true;
    }
    // An engine's video.

    /// The build's part: hold or play the engine as the video shows, and
    /// have the posted task take its picture.
    fn stepEngine(self: *Player, v: *view.View) void {
        const ep = self.engine.?;
        v.showsMedia(.{ .context = self, .unseen = unseen });
        ep.view = v;
        ep.shown = true;
        if (ep.closed) return;
        if (self.host.context.window) |window| {
            ep.waker.attach(window.app, self);
        }
        ep.refresh(self.looping);
        // A muted video is a picture, as a background is: it plays only
        // while some of it shows, and stands still for less motion.
        const hidden = v.windowHidden();
        ep.hidden = hidden;
        ep.hold(self.muted_ and (hidden or v.preferences.reduce_motion));
        if (hidden) return;
        ep.ahead = 0;
        self.wanted = .picture;
        self.post();
        const interval = ep.engine.vtable.interval(ep.engine.context);
        if (interval > 0 and ep.playing() and !ep.held and ep.state != .loading) v.wakeAt(v.time() + self.hostSpan(interval));
    }
    fn unseen(ptr: *anyopaque) void {
        const self: *Player = @ptrCast(@alignCast(ptr));
        const ep = self.engine orelse return;
        if (self.muted_) ep.hold(true);
    }
    /// The engine's part of the posted task, and of its wakes: take the
    /// picture due and the state, and draw a frame for what changed.
    fn takePicture(self: *Player) void {
        if (self.host.context.window == null) return;
        self.performEngine(&self.host.context);
    }
    /// Take the picture due and the state into `context`, outside paint,
    /// as the posted task does.
    pub fn performEngine(self: *Player, context: anytype) void {
        const ep = self.engine.?;
        if (ep.closed) return;
        const state = ep.state;
        const failed = ep.failure != null;
        const was_ready = ep.ready;
        ep.refresh(self.looping);
        var committed = false;
        if (!ep.hidden) if (ep.engine.vtable.frame(ep.engine.context, ep.ahead)) |frame| {
            ep.ready = true;
            if (frame.changed or ep.picture.committed == null) {
                ep.picture.commit(context, frame.picture) catch |e| {
                    self.last_error = e;
                };
                committed = true;
            }
            // The first picture makes the engine ready: it plays on from
            // this frame, with no wake to come for it.
            if (ep.state == .loading) ep.refresh(self.looping);
        };
        if (committed or state != ep.state or failed != (ep.failure != null) or was_ready != ep.ready) self.invalidate();
    }
};

/// What an engine's player keeps of the engine playing its video, at a
/// stable address.
const EnginePlay = struct {
    engine: Engine,
    picture: ui.VideoImage,
    waker: *Waker,
    state: State = .loading,
    failure: ?anyerror = null,
    /// The engine gave a picture, which the image shows.
    ready: bool = false,
    /// The app's pause; held is a pause of the player's own, while nothing
    /// shows the video or, muted, while it is out of the view or the
    /// window out of sight, or the desktop asks for less motion.
    paused: bool = false,
    held: bool = true,
    closed: bool = false,
    /// A view showed the video.
    shown: bool = false,
    /// The window was out of sight as the video last built.
    hidden: bool = false,
    /// How far ahead the picture the task takes shows.
    ahead: u64 = 0,
    last_position: u64 = 0,
    /// The view that last showed the video, which tells it as it no
    /// longer does.
    view: ?*view.View = null,

    fn playing(self: *const EnginePlay) bool {
        return !self.closed and !self.paused and self.state != .ended and self.state != .failed;
    }
    fn refresh(self: *EnginePlay, looping: bool) void {
        var state = self.engine.vtable.state(self.engine.context);
        if (state == .ended and looping) state = .ready;
        self.state = state;
        self.failure = if (state == .failed) self.engine.vtable.failure(self.engine.context) orelse error.VideoFailed else null;
    }
    /// Pause the engine for the player, or let it play again.
    fn hold(self: *EnginePlay, on: bool) void {
        if (self.closed or self.held == on) return;
        self.held = on;
        if (on and !self.paused) {
            self.engine.vtable.pause(self.engine.context);
        } else if (!on and self.playing()) {
            self.engine.vtable.play(self.engine.context);
        }
    }
};

/// The engine's way back to the main thread: its wakes post a task that
/// takes the picture. It outlives the player while a task it posted is
/// queued.
const Waker = struct {
    allocator: std.mem.Allocator,
    queued: std.atomic.Value(bool) = .init(false),
    /// Set on the main thread as a view first shows the video; read by
    /// the engine's threads.
    app: std.atomic.Value(?*z.App) = .init(null),
    player: ?*Player = null,
    retired: bool = false,

    fn attach(self: *Waker, app: *z.App, player: *Player) void {
        self.player = player;
        self.app.store(app, .release);
    }
    /// From any thread.
    fn wake(ptr: *anyopaque) void {
        const self: *Waker = @ptrCast(@alignCast(ptr));
        const app = self.app.load(.acquire) orelse return;
        if (self.queued.swap(true, .acq_rel)) return;
        app.post(.{ .context = self, .call = run }) catch {
            self.queued.store(false, .release);
        };
    }
    fn run(ptr: *anyopaque) void {
        const self: *Waker = @ptrCast(@alignCast(ptr));
        self.queued.store(false, .release);
        if (self.retired) return self.allocator.destroy(self);
        if (self.player) |player| player.takePicture();
    }
    /// The player goes, its engine closed: no wake comes any more.
    fn retire(self: *Waker) void {
        if (self.queued.load(.acquire)) {
            self.retired = true;
            self.player = null;
            return;
        }
        self.allocator.destroy(self);
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
    /// The Host's clock, which tests move.
    var now: u64 = 0;
    fn build(_: *Windowless, _: *view.View) anyerror!void {}
    fn time(_: ?*anyopaque) u64 {
        return now;
    }
};
/// A Host never attached to a window: the player's tasks are not posted.
fn hostless() view.Host {
    Windowless.now = 0;
    return view.Host.init(&Windowless.state, Windowless.build, Windowless.storage.buffers(), .{ .clock = .{ .now = Windowless.time } });
}
fn frameOf(player: *Player) u8 {
    return player.image.buffers[player.image.back ^ 1][0];
}
fn pass(harness: *view.Harness, player: *Player, uploads: *Uploads, at: u64) !void {
    harness.clock = at;
    Windowless.now = at;
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
    try std.testing.expect(player.ended() and !player.playing());
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

test "an animated PNG decodes into premultiplied BGRA frames and tells its length" {
    // One pixel: opaque red for 30 ms, then half transparent blue, which
    // replaces it, for 10 ms, shown for 100 ms.
    const bytes = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01" ++
        "\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x08\x61\x63\x54\x4c\x00\x00\x00\x02\x00\x00\x00" ++
        "\x00\xf3\x8d\x93\x70\x00\x00\x00\x1a\x66\x63\x54\x4c\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00" ++
        "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x64\x00\x00\x62\xf6\x85\x9a\x00\x00\x00\x0d\x49" ++
        "\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x1a" ++
        "\x66\x63\x54\x4c\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x01\x00\x0a\x00\x00\xc1\x0c\xda\x04\x00\x00\x00\x11\x66\x64\x41\x54\x00\x00\x00\x02\x78\x9c" ++
        "\x63\x60\x60\xf8\xdf\x00\x00\x02\x83\x01\x80\x50\xb7\x56\x7a\x00\x00\x00\x00\x49\x45\x4e\x44\xae" ++
        "\x42\x60\x82";
    var decoder = try ApngDecoder.init(std.testing.allocator, bytes);
    defer decoder.deinit();
    try std.testing.expectEqual(@as(u64, 130 * ms), decoder.duration());
    const source = decoder.decoder();
    try std.testing.expectEqual(@as(u32, 1), source.width);
    var pixels: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?u64, 30 * ms), try source.next(source.context, &pixels));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &pixels);
    try std.testing.expectEqual(@as(?u64, 100 * ms), try source.next(source.context, &pixels));
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, &pixels);
    try std.testing.expectEqual(@as(?u64, null), try source.next(source.context, &pixels));
    try source.rewind(source.context);
    try std.testing.expectEqual(@as(?u64, 30 * ms), try source.next(source.context, &pixels));
}

test "a decoder's video seeks, reports its position and length, and plays at another rate" {
    var host = hostless();
    var frames: Frames = .{ .count = 3 };
    var length: Length = .{};
    var source = frames.decoder();
    source.duration = Length.of;
    _ = &length;
    var player = try Player.init(std.testing.allocator, &host, source);
    defer player.deinit();
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};

    try std.testing.expectEqual(@as(u64, 120 * ms), player.duration());
    try pass(&harness, &player, &uploads, 0);
    try pass(&harness, &player, &uploads, 10 * ms);
    try std.testing.expectEqual(@as(u64, 10 * ms), player.position());
    // A seek shows the frame playing then, and goes on from within it.
    player.seek(90 * ms);
    try std.testing.expectEqual(@as(u64, 90 * ms), player.position());
    try pass(&harness, &player, &uploads, 20 * ms);
    try std.testing.expectEqual(@as(u8, 2), frameOf(&player));
    try std.testing.expectEqual(@as(u64, 90 * ms), player.position());
    try pass(&harness, &player, &uploads, 25 * ms);
    try std.testing.expectEqual(@as(?u64, 50 * ms), harness.view.wake);
    // Paused, a seek holds the frame it shows.
    player.pause();
    player.seek(45 * ms);
    try pass(&harness, &player, &uploads, 30 * ms);
    try std.testing.expectEqual(@as(u8, 1), frameOf(&player));
    try std.testing.expect(!player.playing());
    try std.testing.expectEqual(@as(u64, 45 * ms), player.position());
    try pass(&harness, &player, &uploads, 500 * ms);
    try std.testing.expectEqual(@as(u64, 45 * ms), player.position());
    // At double speed, the 35 ms left of it show for 17.5 ms.
    player.setRate(2);
    try std.testing.expectEqual(@as(f64, 2), player.rate());
    player.play();
    try pass(&harness, &player, &uploads, 600 * ms);
    try std.testing.expectEqual(@as(?u64, 600 * ms + 17_500_000), harness.view.wake);
    try pass(&harness, &player, &uploads, 610 * ms);
    try std.testing.expectEqual(@as(u64, 65 * ms), player.position());
    // A seek past the end shows the last frame, ended.
    player.seek(5000 * ms);
    try pass(&harness, &player, &uploads, 620 * ms);
    try std.testing.expect(player.ended() and !player.playing());
    try std.testing.expectEqual(@as(u8, 2), frameOf(&player));
    try std.testing.expectEqual(@as(u64, 120 * ms), player.position());
    player.play();
    try pass(&harness, &player, &uploads, 700 * ms);
    try std.testing.expectEqual(@as(u8, 0), frameOf(&player));
    try std.testing.expectEqual(@as(u64, 0), player.position());
    // Closed, it stands at its frame and decodes nothing more.
    player.close();
    try pass(&harness, &player, &uploads, 800 * ms);
    try std.testing.expect(!player.playing() and !player.ended());
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
    try std.testing.expect(player.ready() and !player.buffering());
    player.setVolume(4);
    try std.testing.expectEqual(@as(f64, 1), player.volume());
}

const Length = struct {
    fn of(_: *anyopaque) u64 {
        return 120 * ms;
    }
};

/// An engine of a test: its pictures and state are what the test sets.
const FakeEngine = struct {
    state: State = .loading,
    picture: ?ui.drawing.VideoPicture = null,
    changed: bool = false,
    playing: bool = false,
    plays: usize = 0,
    pauses: usize = 0,
    seeks: usize = 0,
    sought: u64 = 0,
    loop: bool = false,
    rate: f64 = 1,
    volume: f64 = 1,
    muted: bool = false,
    closed: bool = false,
    wake: ?Wake = null,
    interval: u64 = 0,

    const vtable: Engine.VTable = .{
        .set_wake = setWake,
        .frame = frame,
        .interval = intervalOf,
        .state = stateOf,
        .failure = failureOf,
        .size = sizeOf,
        .duration = durationOf,
        .position = positionOf,
        .play = playIt,
        .pause = pauseIt,
        .seek = seekIt,
        .set_loop = setLoop,
        .set_rate = setRate,
        .set_volume = setVolume,
        .set_muted = setMuted,
        .close = closeIt,
    };
    fn engine(self: *FakeEngine) Engine {
        return .{ .context = self, .vtable = &vtable };
    }
    fn cast(ptr: *anyopaque) *FakeEngine {
        return @ptrCast(@alignCast(ptr));
    }
    fn setWake(ptr: *anyopaque, wake: ?Wake) void {
        cast(ptr).wake = wake;
    }
    fn frame(ptr: *anyopaque, _: u64) ?Frame {
        const self = cast(ptr);
        const picture = self.picture orelse return null;
        defer self.changed = false;
        if (self.state == .loading) self.state = .ready;
        return .{ .picture = picture, .changed = self.changed };
    }
    fn intervalOf(ptr: *anyopaque) u64 {
        return cast(ptr).interval;
    }
    fn stateOf(ptr: *anyopaque) State {
        return cast(ptr).state;
    }
    fn failureOf(ptr: *anyopaque) ?anyerror {
        return if (cast(ptr).state == .failed) error.BrokenStream else null;
    }
    fn sizeOf(ptr: *anyopaque) [2]u32 {
        const picture = cast(ptr).picture orelse return .{ 0, 0 };
        return .{ picture.width, picture.height };
    }
    fn durationOf(_: *anyopaque) u64 {
        return 1200 * ms;
    }
    fn positionOf(ptr: *anyopaque) u64 {
        return cast(ptr).sought;
    }
    fn playIt(ptr: *anyopaque) void {
        cast(ptr).playing = true;
        cast(ptr).plays += 1;
    }
    fn pauseIt(ptr: *anyopaque) void {
        cast(ptr).playing = false;
        cast(ptr).pauses += 1;
    }
    fn seekIt(ptr: *anyopaque, at: u64) void {
        cast(ptr).sought = at;
        cast(ptr).seeks += 1;
    }
    fn setLoop(ptr: *anyopaque, value: bool) void {
        cast(ptr).loop = value;
    }
    fn setRate(ptr: *anyopaque, value: f64) void {
        cast(ptr).rate = value;
    }
    fn setVolume(ptr: *anyopaque, value: f64) void {
        cast(ptr).volume = value;
    }
    fn setMuted(ptr: *anyopaque, value: bool) void {
        cast(ptr).muted = value;
    }
    fn closeIt(ptr: *anyopaque) void {
        cast(ptr).closed = true;
        cast(ptr).playing = false;
    }
};

test "an engine's video plays once shown, takes its pictures and holds while muted out of sight" {
    var host = hostless();
    var fake: FakeEngine = .{};
    var player = try Player.initEngine(std.testing.allocator, &host, fake.engine());
    defer player.deinit();
    try std.testing.expect(fake.wake != null);
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};

    // Held until a view shows it, then played; not ready before a picture.
    try std.testing.expect(!fake.playing and !player.ready());
    try std.testing.expectEqual(view.Size{}, player.size());
    try harness.render();
    try std.testing.expect(fake.playing and player.playing());
    player.performEngine(&uploads);
    try std.testing.expect(!player.ready() and uploads.count == 0);
    const luma: [4]u8 = @splat(16);
    const chroma: [2]u8 = @splat(128);
    fake.picture = .{ .width = 2, .height = 2, .planes = .{ &luma, &chroma }, .strides = .{ 2, 2 } };
    fake.changed = true;
    player.performEngine(&uploads);
    try std.testing.expect(player.ready() and uploads.count == 1);
    try std.testing.expectEqual(view.Size{ .width = 2, .height = 2 }, player.size());
    // The same picture again commits nothing.
    player.performEngine(&uploads);
    try std.testing.expectEqual(@as(usize, 1), uploads.count);
    try harness.render();
    try std.testing.expect((try harness.find(.{ .name = "Waves" })).kind == .image);

    // With sound, it plays on out of the view; muted, it holds there.
    screen.shown = false;
    try harness.render();
    try std.testing.expect(fake.playing);
    screen.shown = true;
    try harness.render();
    player.setMuted(true);
    try std.testing.expect(fake.muted);
    screen.shown = false;
    try harness.render();
    try std.testing.expect(!fake.playing and player.playing());
    screen.shown = true;
    try harness.render();
    try std.testing.expect(fake.playing);
    // Muted, it holds in a window out of sight, and under reduced motion.
    try harness.windowHidden(true);
    try std.testing.expect(!fake.playing);
    try harness.windowHidden(false);
    try std.testing.expect(fake.playing);
    harness.view.preferences.reduce_motion = true;
    try harness.render();
    try std.testing.expect(!fake.playing);
    harness.view.preferences.reduce_motion = false;
    try harness.render();
    try std.testing.expect(fake.playing);
    // Unmuted out of the view, it plays on.
    screen.shown = false;
    try harness.render();
    try std.testing.expect(!fake.playing);
    player.setMuted(false);
    try std.testing.expect(fake.playing);
    screen.shown = true;

    // Paused, it stays paused through holds; at its end, play starts over.
    player.pause();
    try std.testing.expect(!fake.playing and !player.playing());
    try harness.render();
    try std.testing.expect(!fake.playing);
    player.play();
    try std.testing.expect(fake.playing);
    fake.state = .ended;
    player.performEngine(&uploads);
    try std.testing.expect(player.ended() and !player.playing());
    player.play();
    try std.testing.expect(!player.ended() and fake.sought == 0 and fake.seeks == 1);
    // A loop does not end.
    player.setLoop(true);
    try std.testing.expect(fake.loop and player.loop());
    player.performEngine(&uploads);
    try std.testing.expect(!player.ended());
    fake.state = .buffering;
    player.performEngine(&uploads);
    try std.testing.expect(player.buffering());
    fake.state = .failed;
    player.performEngine(&uploads);
    try std.testing.expectEqual(@as(?anyerror, error.BrokenStream), player.err());
    fake.state = .ready;
    player.seek(600 * ms);
    try std.testing.expectEqual(@as(u64, 600 * ms), player.position());
    try std.testing.expectEqual(@as(u64, 1200 * ms), player.duration());
    player.setRate(0.5);
    player.setVolume(0.25);
    try std.testing.expect(fake.rate == 0.5 and fake.volume == 0.25);
    player.close();
    try std.testing.expect(fake.closed and fake.wake == null and !player.playing());
    try std.testing.expectEqual(@as(u64, 600 * ms), player.position());
    player.play();
    try std.testing.expect(!fake.playing);
}

test "an engine that does not wake for each picture asks for a pass as each comes due" {
    var host = hostless();
    var fake: FakeEngine = .{ .interval = 40 * ms };
    var player = try Player.initEngine(std.testing.allocator, &host, fake.engine());
    defer player.deinit();
    var screen: Screen = .{ .player = &player };
    var storage: view.Storage(8, 256) = .{};
    var harness = view.Harness.init(&screen, Screen.build, storage.buffers(), .{});
    var uploads: Uploads = .{};
    harness.clock = 100 * ms;
    try harness.render();
    // Loading: no pass is asked for until the first picture.
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
    const luma: [4]u8 = @splat(16);
    const chroma: [2]u8 = @splat(128);
    fake.picture = .{ .width = 2, .height = 2, .planes = .{ &luma, &chroma }, .strides = .{ 2, 2 } };
    fake.changed = true;
    player.performEngine(&uploads);
    harness.view.wake = null;
    try harness.render();
    try std.testing.expectEqual(@as(?u64, 140 * ms), harness.view.wake);
    player.setRate(2);
    harness.view.wake = null;
    try harness.render();
    try std.testing.expectEqual(@as(?u64, 120 * ms), harness.view.wake);
    player.pause();
    harness.view.wake = null;
    try harness.render();
    try std.testing.expectEqual(@as(?u64, null), harness.view.wake);
}
