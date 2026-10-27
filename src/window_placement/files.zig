const std = @import("std");
const zio = @import("ziggurat_io");
const codec = @import("codec.zig");

/// Explicit blocking worker I/O. Dir/path/bytes/buffers belong to the host and
/// must cover the call. Capture/encode on the owner first; publish/decode on the
/// owner after App.post. This object does not start, join or retain a worker.
pub const Files = struct {
    ui_thread: std.Thread.Id,
    fn worker(self: Files) !void {
        if (std.Thread.getCurrentId() == self.ui_thread) return error.UiThreadIo;
    }
    fn validPath(path: []const u8) !void {
        if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "/\\\x00:") != null or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return error.InvalidPath;
    }
    pub fn read(self: Files, directory: std.Io.Dir, path: []const u8, output: []u8) ![]const u8 {
        try self.worker();
        try validPath(path);
        const file = try directory.openFile(zio.io(), path, .{});
        defer file.close(zio.io());
        const size = (try file.stat(zio.io())).size;
        if (size > codec.max_bytes or size > output.len) return error.CapacityExceeded;
        const length = try zio.readAll(file, output[0..@intCast(size)]);
        if (length != size) return error.FileChanged;
        var extra: [1]u8 = undefined;
        if (try zio.readAll(file, &extra) != 0) return error.FileChanged;
        return output[0..length];
    }
    /// A failed write/flush/sync/rename leaves the prior destination in place.
    /// No directories are created. Successful replacement is atomic visibility,
    /// not a promise of power-loss durability for the parent directory entry.
    pub fn save(self: Files, directory: std.Io.Dir, path: []const u8, input: []const u8, write_buffer: []u8) !void {
        try self.worker();
        try validPath(path);
        if (input.len > codec.max_bytes) return error.CapacityExceeded;
        var atomic = try zio.AtomicFile.init(directory, path, .{ .write_buffer = write_buffer });
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(input) catch return atomic.file_writer.err orelse error.WriteFailed;
        try atomic.flush();
        try atomic.file_writer.file.sync(zio.io());
        try atomic.renameIntoPlace();
    }
};
