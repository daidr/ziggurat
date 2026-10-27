//! Shows what plays through the platform's media controls and delivers
//! commands through the backend's path to the owner thread: the play/pause
//! key by state, offered commands only, and nothing after clear.
const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

const s = std.time.ns_per_s;

const State = struct {
    app: *z.App,
    now: system.NowPlaying = undefined,
    commands: [8]system.now_playing.Command = undefined,
    positions: [8]u64 = undefined,
    count: usize = 0,
    phase: u16 = 0,
    failure: ?[]const u8 = null,

    fn onCommand(context: *anyopaque, command: system.now_playing.Command, position_ns: u64) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.commands[self.count] = command;
        self.positions[self.count] = position_ns;
        self.count += 1;
        if (command == .pause) self.now.setPlayback(.paused, position_ns);
    }

    fn run(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.now = system.NowPlaying.init(std.heap.page_allocator, self, onCommand);
        self.now.start(self.app) catch return self.fail("start");
        self.now.set(.{
            .title = "Spring",
            .artist = "Vivaldi",
            .album = "Seasons",
            .duration_ns = 200 * s,
            .position_ns = 20 * s,
            .commands = .{ .play = true, .pause = true, .seek = true },
        }) catch return self.fail("set");
        // The play/pause key while playing, a command not offered, and a seek.
        system.now_playing.simulateForTesting(4, 0);
        system.now_playing.simulateForTesting(16, 0);
        system.now_playing.simulateForTesting(64, 30 * s);
        self.app.post(.{ .context = self, .call = verify }) catch return self.fail("post");
    }

    fn verify(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.count < 2) {
            // The window's messages come after this task. A turn runs at
            // most 256 tasks before it reads the message queue, so look again
            // across more than one turn.
            self.phase += 1;
            if (self.phase > 1000) return self.fail("commands did not arrive");
            self.app.post(.{ .context = self, .call = verify }) catch return self.fail("post");
            return;
        }
        if (self.count != 2 or self.commands[0] != .pause or self.commands[1] != .seek) return self.fail("commands");
        if (self.positions[0] < 20 * s or self.positions[0] > 21 * s or self.positions[1] != 30 * s) return self.fail("positions");
        const info = self.now.current() orelse return self.fail("current");
        if (info.state != .paused or !std.mem.eql(u8, info.title, "Spring")) return self.fail("info");
        self.now.clear();
        if (self.now.current() != null) return self.fail("clear");
        system.now_playing.simulateForTesting(1, 0);
        self.app.post(.{ .context = self, .call = finish }) catch return self.fail("post");
    }

    fn finish(context: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(context));
        if (self.count != 2) return self.fail("command after clear");
        self.now.stop();
        if (self.now.running()) return self.fail("stop");
        self.app.quit();
    }

    fn fail(self: *State, reason: []const u8) void {
        self.failure = reason;
        self.app.quit();
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
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
        std.debug.print("now playing smoke failed: {s}\n", .{failure});
        return error.SmokeFailed;
    }
}
