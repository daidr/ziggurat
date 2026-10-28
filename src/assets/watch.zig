const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

/// A Windows change-notification handle, with no thread, timer or I/O buffer.
/// Register `nativeHandle` with App.watchNative. Its callback must call `rearm`
/// once after the wait fires, then re-register the one-shot App watch. Start a
/// caller-managed snapshot worker; publish only a changed successful snapshot.
/// Unregister before deinit. Changes to the root directory itself and remote
/// filesystems need caller-specific handling; this is a local development tool.
pub const DirectoryWatch = struct {
    native: ?*anyopaque,
    last_error: u32 = 0,

    /// `failure_code` captures GetLastError even if initialization fails.
    pub fn init(allocator: std.mem.Allocator, absolute_path: []const u8, failure_code: ?*u32) !DirectoryWatch {
        if (failure_code) |code| code.* = 0;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (!std.fs.path.isAbsolute(absolute_path)) return error.AbsolutePathRequired;
        if (std.mem.indexOfScalar(u8, absolute_path, 0) != null) return error.EmbeddedNul;
        const path = try std.unicode.utf8ToUtf16LeAllocZ(allocator, absolute_path);
        defer allocator.free(path);
        const handle = c.FindFirstChangeNotificationW(path.ptr, c.TRUE, c.FILE_NOTIFY_CHANGE_FILE_NAME | c.FILE_NOTIFY_CHANGE_DIR_NAME | c.FILE_NOTIFY_CHANGE_SIZE | c.FILE_NOTIFY_CHANGE_LAST_WRITE);
        if (handle == c.INVALID_HANDLE_VALUE or handle == null) {
            if (failure_code) |code| code.* = c.GetLastError();
            return error.WatchFailed;
        }
        return .{ .native = handle };
    }
    pub fn nativeHandle(self: *const DirectoryWatch) !*anyopaque {
        return self.native orelse error.Closed;
    }
    pub fn rearm(self: *DirectoryWatch) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const handle = self.native orelse return error.Closed;
        if (c.FindNextChangeNotification(handle) == 0) {
            self.last_error = c.GetLastError();
            return error.WatchFailed;
        }
    }
    pub fn deinit(self: *DirectoryWatch) void {
        if (builtin.os.tag == .windows) if (self.native) |handle| {
            std.debug.assert(c.FindCloseChangeNotification(handle) != 0);
        };
        self.native = null;
    }
};
