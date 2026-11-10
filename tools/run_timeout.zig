//! Runs a command and ends it when it outlives a limit:
//! `ziggurat-run-timeout SECONDS COMMAND [ARGUMENTS...]`. The command keeps
//! this process's standard streams and environment, and its exit code is
//! this one's; a command that ran out of time exits with 124 after saying so.
//! The build runs every smoke through it, so one that hangs fails by name
//! instead of holding the whole build.
const std = @import("std");
const builtin = @import("builtin");

var finished: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: ziggurat-run-timeout SECONDS COMMAND [ARGUMENTS...]\n", .{});
        std.process.exit(2);
    }
    const seconds = std.fmt.parseInt(u32, args[1], 10) catch {
        std.debug.print("ziggurat-run-timeout: {s} is not a number of seconds\n", .{args[1]});
        std.process.exit(2);
    };
    var child = try std.process.spawn(init.io, .{ .argv = args[2..], .environ_map = init.environ_map });
    const guard = try std.Thread.spawn(.{}, watch, .{ init.io, child.id.?, seconds });
    guard.detach();
    const term = try child.wait(init.io);
    finished.store(true, .release);
    if (timed_out.load(.acquire)) {
        std.debug.print("ziggurat-run-timeout: {s} ran longer than {d} s and was ended\n", .{ std.fs.path.basename(args[2]), seconds });
        std.process.exit(124);
    }
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => {
            std.debug.print("ziggurat-run-timeout: {s} ended with {f}\n", .{ std.fs.path.basename(args[2]), term });
            std.process.exit(1);
        },
    }
}

var timed_out: std.atomic.Value(bool) = .init(false);

fn watch(io: std.Io, id: std.process.Child.Id, seconds: u32) void {
    io.sleep(.fromSeconds(seconds), .awake) catch return;
    if (finished.load(.acquire)) return;
    timed_out.store(true, .release);
    // Until the waiting thread reaps the command, its handle or ID still
    // names it.
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(@intCast(124)));
    } else {
        std.posix.kill(id, .KILL) catch {};
    }
}
