//! Drives the MPRIS player from a client on its own bus connection: the
//! bus name, metadata and artwork file, the offered commands, the play/pause
//! key, seeking, and leaving the bus on clear. Needs a session bus and an X11
//! display: dbus-run-session -- xvfb-run.
const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn znpf_start() c_int;
extern fn znpf_pending() c_int;
extern fn znpf_text() [*:0]const u8;
extern fn znpf_player() [*:0]const u8;
extern fn znpf_find_player() void;
extern fn znpf_call([*:0]const u8) void;
extern fn znpf_seek(i64) void;
extern fn znpf_set_position([*:0]const u8, i64) void;
extern fn znpf_open_uri([*:0]const u8) void;
extern fn znpf_get([*:0]const u8, [*:0]const u8) void;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;

const player_interface = "org.mpris.MediaPlayer2.Player";
const artwork = "\x89PNG\r\n\x1a\nnot really an image";
const s = std.time.ns_per_s;

const Received = struct { command: system.now_playing.Command, position_ns: u64 };

const State = struct {
    app: *z.App,
    now: system.NowPlaying = undefined,
    step: usize = 0,
    issued: bool = false,
    received: [8]Received = undefined,
    received_len: usize = 0,
    art_path: [512]u8 = undefined,
    art_len: usize = 0,
    failure: ?[]const u8 = null,

    fn onCommand(context: *anyopaque, command: system.now_playing.Command, position_ns: u64) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.received[self.received_len] = .{ .command = command, .position_ns = position_ns };
        self.received_len += 1;
        // The app plays as asked and says so.
        switch (command) {
            .play => self.now.setPlayback(.playing, position_ns),
            .pause => self.now.setPlayback(.paused, position_ns),
            .seek => self.now.setPlayback(self.now.info.state, position_ns),
            else => {},
        }
    }

    fn text() []const u8 {
        return std.mem.span(znpf_text());
    }

    fn expectText(self: *State, needle: []const u8) void {
        if (std.mem.indexOf(u8, text(), needle) == null) {
            std.debug.print("expected {s} in {s}\n", .{ needle, text() });
            self.failure = "unexpected reply";
        }
    }

    fn expectCommand(self: *State, index: usize, command: system.now_playing.Command, low_ns: u64, high_ns: u64) void {
        if (self.received_len <= index) {
            self.failure = "missing command";
            return;
        }
        const got = self.received[index];
        if (got.command != command or got.position_ns < low_ns or got.position_ns > high_ns) {
            std.debug.print("command {d}: {s} at {d}\n", .{ index, @tagName(got.command), got.position_ns });
            self.failure = "unexpected command";
        }
    }

    /// Issues the step's request; false once it is checked after its reply.
    fn act(self: *State) void {
        switch (self.step) {
            0 => znpf_find_player(),
            1 => znpf_get(player_interface, "Metadata"),
            2 => znpf_get(player_interface, "PlaybackStatus"),
            3 => znpf_get(player_interface, "CanGoPrevious"),
            4 => znpf_get(player_interface, "CanSeek"),
            5 => znpf_call("PlayPause"),
            6 => znpf_get(player_interface, "PlaybackStatus"),
            7 => znpf_call("Previous"),
            8 => znpf_call("Next"),
            9 => znpf_set_position("/org/ziggurat/track/1", 50 * std.time.us_per_s),
            10 => znpf_set_position("/org/ziggurat/track/9", 60 * std.time.us_per_s),
            11 => znpf_seek(5 * std.time.us_per_s),
            12 => znpf_open_uri("file:///tmp/song.ogg"),
            13 => {
                self.now.clear();
                znpf_find_player();
            },
            else => {},
        }
    }

    fn check(self: *State) void {
        switch (self.step) {
            0 => {
                const name = std.mem.span(znpf_player());
                var expected: [64]u8 = undefined;
                const suffix = std.fmt.bufPrint(&expected, ".instance{d}", .{std.c.getpid()}) catch unreachable;
                if (!std.mem.startsWith(u8, name, "org.mpris.MediaPlayer2.now-playing-smoke") or !std.mem.endsWith(u8, name, suffix)) {
                    std.debug.print("player name {s}\n", .{name});
                    self.failure = "player name";
                }
            },
            1 => {
                for ([_][]const u8{ "'xesam:title': <'Spring'>", "'xesam:artist': <['Vivaldi']>", "'xesam:album': <'Seasons'>", "'mpris:length': <int64 200000000>", "'mpris:trackid': <objectpath '/org/ziggurat/track/1'>", "'mpris:artUrl': <'file://" }) |needle| self.expectText(needle);
                const reply = text();
                const start = (std.mem.indexOf(u8, reply, "'file://") orelse return) + "'file://".len;
                const end = std.mem.indexOfScalarPos(u8, reply, start, '\'') orelse return;
                @memcpy(self.art_path[0 .. end - start], reply[start..end]);
                self.art_len = end - start;
                const file = std.Io.Dir.openFileAbsolute(zio.io(), self.art_path[0..self.art_len], .{}) catch {
                    self.failure = "artwork file";
                    return;
                };
                defer file.close(zio.io());
                var content: [64]u8 = undefined;
                const length = file.readPositionalAll(zio.io(), &content, 0) catch 0;
                if (!std.mem.eql(u8, content[0..length], artwork)) self.failure = "artwork content";
            },
            2 => self.expectText("'Paused'"),
            3 => self.expectText("<false>"),
            4 => self.expectText("<true>"),
            5 => self.expectCommand(0, .play, 10 * s, 10 * s + s / 2),
            6 => self.expectText("'Playing'"),
            // Not offered: nothing comes.
            7 => if (self.received_len != 1) {
                self.failure = "previous was delivered";
            },
            8 => self.expectCommand(1, .next, 10 * s, 12 * s),
            9 => self.expectCommand(2, .seek, 50 * s, 50 * s),
            // Another track's position is ignored.
            10 => if (self.received_len != 3) {
                self.failure = "other track seek was delivered";
            },
            11 => self.expectCommand(3, .seek, 55 * s, 57 * s),
            12 => self.expectText("NotSupported"),
            13 => {
                if (std.mem.span(znpf_player()).len != 0) self.failure = "player stayed on the bus";
                if (std.Io.Dir.accessAbsolute(zio.io(), self.art_path[0..self.art_len], .{})) |_| {
                    self.failure = "artwork file stayed";
                } else |_| {}
            },
            else => {},
        }
    }

    fn poll(raw: ?*anyopaque) callconv(.c) c_int {
        const self: *State = @ptrCast(@alignCast(raw.?));
        if (znpf_pending() != 0) return 1;
        if (self.issued) {
            self.check();
            self.issued = false;
            self.step += 1;
            if (self.failure != null or self.step == 14) {
                self.app.quit();
                return 0;
            }
        }
        self.act();
        self.issued = true;
        return 1;
    }

    fn run(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.now = system.NowPlaying.init(std.heap.page_allocator, self, onCommand);
        self.now.start(self.app) catch {
            self.failure = "start";
            return self.app.quit();
        };
        self.now.set(.{
            .title = "Spring",
            .artist = "Vivaldi",
            .album = "Seasons",
            .artwork = artwork,
            .duration_ns = 200 * s,
            .position_ns = 10 * s,
            .state = .paused,
            .commands = .{ .play = true, .pause = true, .next = true, .seek = true },
        }) catch {
            self.failure = "set";
            return self.app.quit();
        };
        _ = g_timeout_add(2, poll, self);
    }
};

extern fn g_set_prgname([*:0]const u8) void;

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    g_set_prgname("now-playing-smoke");
    if (znpf_start() == 0) return error.SessionBusUnavailable;
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    _ = try app.createWindow(.{ .title = "Now playing smoke", .width = 200, .height = 120 });
    try app.post(.{ .context = &state, .call = State.run });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |failure| {
        std.debug.print("now playing smoke failed at step {d}: {s}\n", .{ state.step, failure });
        return error.SmokeFailed;
    }
    try std.testing.expect(!state.now.running());
}
