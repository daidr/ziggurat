//! What the app plays, shown where the system shows media: the media
//! controls of the volume flyout and the lock screen on Windows
//! (SystemMediaTransportControls), and MPRIS clients on Linux, as GNOME's and
//! KDE's media controls, their lock screens and playerctl. The media keys of
//! keyboards and headsets, and those controls, send commands to the app while
//! it shows something.
//!
//!     var now = system.NowPlaying.init(allocator, &player_state, onCommand);
//!     try now.start(app);
//!     defer now.stop();
//!     try now.set(.{ .title = "Spring", .artist = "Vivaldi", .duration_ns = 200 * std.time.ns_per_s,
//!         .commands = .{ .play = true, .pause = true, .next = true, .seek = true } });
//!
//! Every call runs on the App owner thread, and so does `on_command`. One
//! NowPlaying shows at a time in a process.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const os = builtin.os.tag;
const enabled = !builtin.is_test and (os == .windows or os == .linux);
const native = if (enabled and os == .windows) @import("now_playing_windows.zig") else if (enabled) linux else struct {};

pub const capabilities = .{ .now_playing = os == .windows or os == .linux };

/// A command of the media keys and the system's media controls.
pub const Command = enum {
    /// `play` and `pause` are also what the play/pause key sends: `pause`
    /// while the state is `playing`, else `play`.
    play,
    pause,
    stop,
    next,
    previous,
    /// Moves to the position `on_command` gets: the system's scrubber, and
    /// on Linux MPRIS's Seek and SetPosition.
    seek,
};

/// The commands the system's controls offer. None set offers play, pause
/// and stop.
pub const Commands = struct {
    play: bool = false,
    pause: bool = false,
    stop: bool = false,
    next: bool = false,
    previous: bool = false,
    seek: bool = false,

    pub fn has(self: Commands, command: Command) bool {
        return switch (command) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn bits(self: Commands) u32 {
        var value: u32 = 0;
        inline for (std.meta.fields(Command)) |field| {
            if (@field(self, field.name)) value |= bit(@enumFromInt(field.value));
        }
        return value;
    }

    fn empty(self: Commands) bool {
        return self.bits() == 0;
    }
};

/// The native bit of a command; `toggle_bit` is the play/pause key.
fn bit(command: Command) u32 {
    return switch (command) {
        .play => 1,
        .pause => 2,
        .stop => 8,
        .next => 16,
        .previous => 32,
        .seek => 64,
    };
}
const toggle_bit: u32 = 4;

pub const State = enum { playing, paused, stopped };

/// What the app plays. Strings and the artwork are copied.
pub const Info = struct {
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    /// The image of the album or the episode, PNG or JPEG.
    artwork: []const u8 = "",
    /// How long the track is; 0 is unknown, as for a live stream, which
    /// shows no progress.
    duration_ns: u64 = 0,
    /// Where playback is as the info is set. The system advances it while
    /// the state is `playing`, at `rate`, so the app sets it again only when
    /// playback jumps (`setPlayback`).
    position_ns: u64 = 0,
    /// The speed of playback; 0 is 1.
    rate: f64 = 0,
    /// `playing` by default: an app usually shows what it plays as it starts.
    state: State = .playing,
    commands: Commands = .{},
};

/// A player `NowPlaying.control` drives, as a `ziggurat_audio` Player.
pub const Player = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        play: *const fn (*anyopaque) void,
        pause: *const fn (*anyopaque) void,
        stop: *const fn (*anyopaque) void,
        is_playing: *const fn (*anyopaque) bool,
        seek: *const fn (*anyopaque, u64) void,
        position: *const fn (*anyopaque) u64,
        duration: *const fn (*anyopaque) ?u64,
    };

    /// Adapts a pointer to a value with `play`, `pause`, `stop`,
    /// `isPlaying`, `seek(ns)`, `position()` and `duration()` (nanoseconds,
    /// null unknown), as an audio Player handle. The pointee must outlive
    /// the control.
    pub fn of(pointer: anytype) Player {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        const Adapter = struct {
            fn get(context: *anyopaque) *T {
                return @ptrCast(@alignCast(context));
            }
            fn play(context: *anyopaque) void {
                get(context).play();
            }
            fn pause(context: *anyopaque) void {
                get(context).pause();
            }
            fn stop(context: *anyopaque) void {
                get(context).stop();
            }
            fn isPlaying(context: *anyopaque) bool {
                return get(context).isPlaying();
            }
            fn seek(context: *anyopaque, position_ns: u64) void {
                get(context).seek(position_ns);
            }
            fn position(context: *anyopaque) u64 {
                return get(context).position();
            }
            fn duration(context: *anyopaque) ?u64 {
                return get(context).duration();
            }
            const vtable: VTable = .{ .play = play, .pause = pause, .stop = stop, .is_playing = isPlaying, .seek = seek, .position = position, .duration = duration };
        };
        return .{ .context = @ptrCast(pointer), .vtable = &Adapter.vtable };
    }
};

/// The bytes of info strings and artwork the system is given at most.
pub const max_text_bytes = 1024;
pub const max_artwork_bytes = 16 * 1024 * 1024;

var active: ?*NowPlaying = null;

/// Caller-owned. After `start` it must not move, and its context must stay
/// valid until `stop` returns or App shutdown stops it.
pub const NowPlaying = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    /// Called with each command while something shows: `position_ns` is
    /// where `seek` moves to, within the track, and for the other commands
    /// where playback is as the command comes, so that
    /// `setPlayback(.paused, position_ns)` keeps the place. The app plays,
    /// pauses or moves as it asks, and says so with `setPlayback` (or `set`,
    /// for another track). It may call any method, `stop` included.
    on_command: *const fn (context: *anyopaque, command: Command, position_ns: u64) void,
    app: ?*z.App = null,
    stop_node: z.StopParticipant,
    token: ?z.StopToken = null,
    showing: bool = false,
    info: Info = .{},
    /// Owns the info's strings and artwork.
    storage: []u8 = &.{},
    /// When `info.position_ns` was.
    at: ?std.time.Instant = null,
    player: ?Player = null,

    pub fn init(allocator: std.mem.Allocator, context: *anyopaque, on_command: *const fn (*anyopaque, Command, u64) void) NowPlaying {
        return .{ .allocator = allocator, .context = context, .on_command = on_command, .stop_node = .{ .context = context, .stop = stopFromApp } };
    }

    /// Registers with the App stop protocol; nothing shows until `set`.
    pub fn start(self: *NowPlaying, app: *z.App) !void {
        app.assertOwner();
        if (self.app != null) return error.AlreadyStarted;
        if (comptime !enabled) return error.UnsupportedCapability;
        if (active != null) return error.AlreadyActive;
        self.stop_node = .{ .context = self, .stop = stopFromApp };
        self.token = try app.registerStop(&self.stop_node);
        self.app = app;
        active = self;
    }

    /// Stops showing and releases the system's controls. Idempotent; safe
    /// inside `on_command`.
    pub fn stop(self: *NowPlaying) void {
        const app = self.app orelse return;
        app.assertOwner();
        if (self.token) |token| _ = app.cancelStop(token) catch false;
        self.revoke();
    }

    pub fn running(self: *const NowPlaying) bool {
        return self.app != null;
    }

    fn revoke(self: *NowPlaying) void {
        if (self.showing) {
            self.showing = false;
            self.apply();
        }
        self.allocator.free(self.storage);
        self.storage = &.{};
        self.info = .{};
        self.player = null;
        self.app = null;
        self.token = null;
        if (active == self) active = null;
    }

    fn stopFromApp(pointer: *anyopaque) anyerror!void {
        const self: *NowPlaying = @ptrCast(@alignCast(pointer));
        self.token = null;
        if (self.app != null) self.revoke();
    }

    /// Shows `info`, replacing what showed.
    pub fn set(self: *NowPlaying, info: Info) !void {
        const app = self.app orelse return error.NotStarted;
        app.assertOwner();
        for ([_][]const u8{ info.title, info.artist, info.album }) |text| {
            if (text.len > max_text_bytes or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidText;
        }
        if (info.artwork.len > max_artwork_bytes) return error.ArtworkTooLarge;
        if (std.math.isNan(info.rate) or info.rate < 0 or std.math.isInf(info.rate)) return error.InvalidRate;
        const total = info.title.len + info.artist.len + info.album.len + info.artwork.len;
        const storage = try self.allocator.alloc(u8, total);
        var copy = info;
        var offset: usize = 0;
        inline for (.{ "title", "artist", "album", "artwork" }) |name| {
            const value = @field(info, name);
            @memcpy(storage[offset..][0..value.len], value);
            @field(copy, name) = storage[offset..][0..value.len];
            offset += value.len;
        }
        self.allocator.free(self.storage);
        self.storage = storage;
        self.info = copy;
        self.at = std.time.Instant.now() catch null;
        self.showing = true;
        _ = self.syncPlayer();
        self.apply();
    }

    /// Changes the state and position of what shows, as the app plays,
    /// pauses, stops or seeks.
    pub fn setPlayback(self: *NowPlaying, state: State, position_ns: u64) void {
        const app = self.app orelse return;
        app.assertOwner();
        self.info.state = state;
        self.info.position_ns = position_ns;
        self.at = std.time.Instant.now() catch null;
        if (self.showing) self.apply();
    }

    /// Removes what shows: the system's controls no longer show the app,
    /// and the media keys go to other apps.
    pub fn clear(self: *NowPlaying) void {
        const app = self.app orelse return;
        app.assertOwner();
        if (!self.showing) return;
        self.showing = false;
        self.apply();
    }

    /// What shows, with its position where playback is now, or null. The
    /// strings are borrowed until the next `set` or `stop`.
    pub fn current(self: *const NowPlaying) ?Info {
        if (!self.showing) return null;
        var info = self.info;
        info.position_ns = self.position();
        return info;
    }

    /// Lets the media keys and the system's controls drive `player`: they
    /// play, pause, stop and seek it, and what shows takes its state,
    /// position and duration. The commands it handles are offered on top of
    /// those the info sets, `seek` when the player knows its duration;
    /// `next` and `previous` still go to `on_command`, for the app to change
    /// tracks, and so do the others after the player handled them. After
    /// the app plays, pauses, stops or moves the player itself, or the
    /// player ends, call `sync`. Null stops driving it.
    pub fn control(self: *NowPlaying, player: ?Player) void {
        const app = self.app orelse return;
        app.assertOwner();
        self.player = player;
        self.sync();
    }

    /// Shows the state, position and duration of the player `control`
    /// drives.
    pub fn sync(self: *NowPlaying) void {
        if (self.syncPlayer() and self.showing) self.apply();
    }

    fn syncPlayer(self: *NowPlaying) bool {
        const player = self.player orelse return false;
        const position_ns = player.vtable.position(player.context);
        const duration_ns = player.vtable.duration(player.context) orelse 0;
        self.info.state = if (player.vtable.is_playing(player.context))
            .playing
        else if (position_ns == 0 or (duration_ns > 0 and position_ns >= duration_ns))
            .stopped
        else
            .paused;
        self.info.position_ns = position_ns;
        self.info.duration_ns = duration_ns;
        self.at = std.time.Instant.now() catch null;
        return true;
    }

    fn rate(self: *const NowPlaying) f64 {
        return if (self.info.rate > 0) self.info.rate else 1;
    }

    /// Where playback is now.
    pub fn position(self: *const NowPlaying) u64 {
        var value: f64 = @floatFromInt(self.info.position_ns);
        if (self.info.state == .playing) if (self.at) |at| if (std.time.Instant.now()) |now| {
            value += @as(f64, @floatFromInt(now.since(at))) * self.rate();
        } else |_| {};
        var result: u64 = @intFromFloat(@min(value, @as(f64, @floatFromInt(std.math.maxInt(u63)))));
        if (self.info.duration_ns > 0) result = @min(result, self.info.duration_ns);
        return result;
    }

    /// The commands offered.
    pub fn offered(self: *const NowPlaying) Commands {
        var commands = self.info.commands;
        if (commands.empty() or self.player != null) {
            commands.play = true;
            commands.pause = true;
            commands.stop = true;
        }
        if (self.player != null and self.info.duration_ns > 0) commands.seek = true;
        return commands;
    }

    fn apply(self: *NowPlaying) void {
        if (comptime !enabled) return;
        if (!self.showing) return native.set(null);
        const info = self.info;
        native.set(&.{
            .title = info.title,
            .artist = info.artist,
            .album = info.album,
            .artwork = info.artwork,
            .duration_ns = info.duration_ns,
            .position_ns = self.position(),
            .rate = self.rate(),
            .state = info.state,
            .commands = self.offered().bits(),
        });
    }

    /// A command from the backend, on the owner thread.
    fn command(self: *NowPlaying, raw: u32, requested_ns: u64) void {
        const app = self.app orelse return;
        if (!self.showing) return;
        const which: Command = switch (raw) {
            toggle_bit => if (self.info.state == .playing) .pause else .play,
            1 => .play,
            2 => .pause,
            8 => .stop,
            16 => .next,
            32 => .previous,
            64 => .seek,
            else => return,
        };
        if (!self.offered().has(which)) return;
        var position_ns = if (which == .seek) requested_ns else self.position();
        if (self.info.duration_ns > 0) position_ns = @min(position_ns, self.info.duration_ns);
        const scope = app.beginCallback() orelse return;
        defer scope.end();
        if (self.player) |player| {
            switch (which) {
                .play => player.vtable.play(player.context),
                .pause => player.vtable.pause(player.context),
                .stop => player.vtable.stop(player.context),
                .seek => player.vtable.seek(player.context, position_ns),
                .next, .previous => {},
            }
            if (which != .next and which != .previous) self.sync();
        }
        // The NowPlaying may be stopped or freed inside; do not touch it afterwards.
        self.on_command(self.context, which, position_ns);
    }
};

/// What the backend shows; strings are borrowed for the call.
pub const NativeInfo = struct {
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    artwork: []const u8,
    duration_ns: u64,
    position_ns: u64,
    rate: f64,
    state: State,
    /// Command bits.
    commands: u32,
};

/// Backend delivery of a command, on the owner thread.
pub fn deliver(raw: u32, position_ns: u64) void {
    const self = active orelse return;
    self.command(raw, position_ns);
}

/// Test hook: a command as the system's controls send it, through the
/// backend's own path to the owner thread (on Windows the window's message
/// queue). Bits as `Commands.bits`, 4 for the play/pause key.
pub fn simulateForTesting(raw: u32, position_ns: u64) void {
    if (comptime enabled and os == .windows) return native.post(raw, @intCast(position_ns / 100));
    deliver(raw, position_ns);
}

const linux = struct {
    const CInfo = extern struct {
        title: [*:0]const u8,
        artist: [*:0]const u8,
        album: [*:0]const u8,
        artwork: ?[*]const u8,
        artwork_len: usize,
        duration_us: i64,
        position_us: i64,
        rate: f64,
        state: c_int,
        commands: u32,
    };
    extern fn znp_set(info: ?*const CInfo, deliver: *const fn (u32, i64) callconv(.c) void) c_int;

    fn received(raw: u32, position_us: i64) callconv(.c) void {
        deliver(raw, @as(u64, @intCast(@max(position_us, 0))) * std.time.ns_per_us);
    }

    fn set(info: ?*const NativeInfo) void {
        const value = info orelse {
            _ = znp_set(null, received);
            return;
        };
        var title: [max_text_bytes + 1]u8 = undefined;
        var artist: [max_text_bytes + 1]u8 = undefined;
        var album: [max_text_bytes + 1]u8 = undefined;
        const c_info: CInfo = .{
            .title = terminated(&title, value.title),
            .artist = terminated(&artist, value.artist),
            .album = terminated(&album, value.album),
            .artwork = if (value.artwork.len > 0) value.artwork.ptr else null,
            .artwork_len = value.artwork.len,
            .duration_us = @intCast(value.duration_ns / std.time.ns_per_us),
            .position_us = @intCast(value.position_ns / std.time.ns_per_us),
            .rate = value.rate,
            .state = @intFromEnum(value.state),
            .commands = value.commands,
        };
        _ = znp_set(&c_info, received);
    }

    fn terminated(storage: *[max_text_bytes + 1]u8, text: []const u8) [*:0]const u8 {
        @memcpy(storage[0..text.len], text);
        storage[text.len] = 0;
        return storage[0..text.len :0];
    }
};

test "commands default to play, pause and stop, with seek for a controlled player of known length" {
    var now = NowPlaying.init(std.testing.allocator, undefined, undefined);
    try std.testing.expectEqual(@as(u32, 1 | 2 | 8), now.offered().bits());
    now.info.commands = .{ .next = true, .seek = true };
    try std.testing.expectEqual(@as(u32, 16 | 64), now.offered().bits());
    try std.testing.expect(now.offered().has(.next));
    try std.testing.expect(!now.offered().has(.play));
}

test "the position advances at the rate while playing, within the track" {
    var now = NowPlaying.init(std.testing.allocator, undefined, undefined);
    now.info = .{ .position_ns = 5, .duration_ns = 10, .state = .paused };
    now.at = try std.time.Instant.now();
    try std.testing.expectEqual(@as(u64, 5), now.position());
    now.info.state = .playing;
    now.info.rate = 1e12;
    std.Thread.sleep(1000);
    try std.testing.expectEqual(@as(u64, 10), now.position());
}
