//! Restarting the application: quit through the ordinary close path, then
//! start the executable again once the event loop has returned.
//!
//!     var relaunch: system.relaunch.Relaunch = .{};
//!     // From a menu or after an update, on the owner thread:
//!     _ = relaunch.request(app);
//!     // In main, after `app.run()` returns and resources are released:
//!     _ = try relaunch.finish(allocator, .{});
//!
//! The new process starts only after this one has released its windows,
//! single-instance lock and files, so it does not find them held.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const windows = builtin.os.tag == .windows;

pub const capabilities = .{ .relaunch = windows or builtin.os.tag == .linux };

extern "user32" fn AllowSetForegroundWindow(process: u32) callconv(.winapi) c_int;
const any_process: u32 = 0xffff_ffff;

pub const Options = struct {
    /// Absolute program path; null is this executable.
    executable: ?[]const u8 = null,
    /// Arguments after the program; null repeats this process's own.
    arguments: ?[]const []const u8 = null,
    /// Working directory; null keeps the current one.
    cwd: ?[]const u8 = null,
};

pub const Relaunch = struct {
    requested: bool = false,

    /// Asks the App to quit, as `requestQuit` does: close handlers run and
    /// can cancel, which also cancels the relaunch. Call on the owner thread.
    pub fn request(self: *Relaunch, app: *z.App) z.App.QuitResult {
        app.assertOwner();
        if (comptime windows and !builtin.is_test) {
            // Windows hands foreground rights back as the windows close; pass
            // them on while this process still holds them, so the new
            // process's first window can come to the front.
            _ = AllowSetForegroundWindow(any_process);
        }
        const result = app.requestQuit();
        self.requested = result == .accepted;
        return result;
    }
    /// Starts the new process when a relaunch was accepted, and reports
    /// whether it did. Call after `App.run` returns, once the App and the
    /// resources a new instance needs are released. The child is not waited
    /// for; this process should exit soon after.
    pub fn finish(self: *Relaunch, allocator: std.mem.Allocator, options: Options) !bool {
        if (!self.requested) return false;
        self.requested = false;
        if (comptime !capabilities.relaunch) return error.UnsupportedCapability;
        try spawn(allocator, options);
        return true;
    }
};

/// Starts the program detached from this process's lifetime.
pub fn spawn(allocator: std.mem.Allocator, options: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const executable = options.executable orelse try std.fs.selfExePathAlloc(arena);
    if (!std.fs.path.isAbsolute(executable)) return error.RelativePath;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, executable);
    if (options.arguments) |arguments| {
        try argv.appendSlice(arena, arguments);
    } else {
        const own = try std.process.argsAlloc(arena);
        if (own.len > 1) try argv.appendSlice(arena, own[1..]);
    }
    var child = std.process.Child.init(argv.items, arena);
    child.cwd = options.cwd;
    child.stdin_behavior = .Ignore;
    try child.spawn();
    // Not waited for. Windows: release the handles; the process runs on.
    if (comptime windows) {
        std.os.windows.CloseHandle(child.id);
        std.os.windows.CloseHandle(child.thread_handle);
    }
}

test "a cancelled quit does not relaunch" {
    const Veto = struct {
        fn request(_: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
            return .cancel;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: u8 = 0;
    _ = try app.createWindow(.{ .on_close = .{ .context = &context, .request = Veto.request } });
    var relaunch: Relaunch = .{};
    try std.testing.expectEqual(z.App.QuitResult.cancelled, relaunch.request(app));
    try std.testing.expect(!relaunch.requested);
    try std.testing.expect(!try relaunch.finish(std.testing.allocator, .{}));
}

test "an accepted quit relaunches once" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    _ = try app.createWindow(.{});
    var relaunch: Relaunch = .{};
    try std.testing.expectEqual(z.App.QuitResult.accepted, relaunch.request(app));
    try std.testing.expect(relaunch.requested);
    // finish would start a process; the smoke covers that.
    relaunch.requested = false;
    try std.testing.expect(!try relaunch.finish(std.testing.allocator, .{}));
}
