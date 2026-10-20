const std = @import("std");
const builtin = @import("builtin");
const id = @import("identity.zig");

pub const Loaded = struct { bytes: []const u8, stamp: id.Stamp };
pub const Probe = union(enum) { unchanged, modified: id.Stamp, missing };
pub const SaveOptions = struct {
    /// The stamp the document was loaded or last saved with. A differing disk
    /// stamp returns `.conflict` without replacing the file. Null skips the
    /// check (a new file, Save As, or an explicit overwrite after a conflict).
    expected: ?id.Stamp = null,
    /// Best-effort flush of the parent directory entry after the rename on POSIX.
    durable_directory: bool = true,
};
pub const SaveResult = union(enum) { saved: id.Stamp, conflict: Probe };

/// Explicit blocking worker I/O. Paths, bytes and buffers belong to the host
/// and must cover the call. Owner-thread state changes go back through
/// `App.post`. `ui_thread` rejects calls from the App owner thread; pass null
/// only for work after `App.run` returns. Nothing here starts or retains a worker.
pub const Files = struct {
    ui_thread: ?std.Thread.Id,
    pub fn worker(self: Files) !void {
        if (self.ui_thread) |ui| if (std.Thread.getCurrentId() == ui) return error.UiThreadIo;
    }
    fn absolute(path: []const u8) !void {
        if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    }
    /// Canonicalizes an existing file: absolute path with symlinks resolved and
    /// its current object key. Directories and missing files are rejected.
    pub fn resolve(self: Files, path: []const u8) !id.Identity {
        try self.worker();
        try absolute(path);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const canonical = try std.fs.cwd().realpath(path, &buffer);
        const file = try std.fs.cwd().openFile(canonical, .{});
        defer file.close();
        const observed = try id.stamp(file);
        return .{ .path = try id.Path.init(canonical), .key = observed.key };
    }
    /// Canonical identity for a Save As target that may not exist yet: the
    /// parent directory is resolved and the file name kept. An existing target
    /// resolves like `resolve`.
    pub fn resolveTarget(self: Files, path: []const u8) !id.Identity {
        try self.worker();
        try absolute(path);
        if (self.resolve(path)) |existing| return existing else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
        const name = std.fs.path.basename(path);
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try std.fs.cwd().realpath(parent, &buffer);
        var joined: [id.max_path]u8 = undefined;
        const separator = std.fs.path.sep_str;
        const full = std.fmt.bufPrint(&joined, "{s}{s}{s}", .{ directory, if (std.mem.endsWith(u8, directory, separator)) "" else separator, name }) catch return error.PathTooLong;
        return .{ .path = try id.Path.init(full) };
    }
    /// Reads the whole file into `output` with the stamp observed while open.
    pub fn read(self: Files, path: []const u8, output: []u8) !Loaded {
        try self.worker();
        try absolute(path);
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const before = try id.stamp(file);
        if (before.size > output.len) return error.CapacityExceeded;
        const length = try file.readAll(output[0..@intCast(before.size)]);
        var extra: [1]u8 = undefined;
        if (length != before.size or try file.read(&extra) != 0) return error.FileChanged;
        const after = try id.stamp(file);
        if (!after.eql(before)) return error.FileChanged;
        return .{ .bytes = output[0..length], .stamp = before };
    }
    /// Compares the disk with a known stamp without reading content.
    pub fn probe(self: Files, path: []const u8, known: id.Stamp) !Probe {
        try self.worker();
        try absolute(path);
        const current = try observe(path) orelse return .missing;
        return if (current.eql(known)) .unchanged else .{ .modified = current };
    }
    fn observe(path: []const u8) !?id.Stamp {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();
        return try id.stamp(file);
    }
    fn conflict(path: []const u8, expected: ?id.Stamp) !?Probe {
        const known = expected orelse return null;
        const current = try observe(path) orelse return .missing;
        return if (current.eql(known)) null else .{ .modified = current };
    }
    /// Writes a sibling temporary file, syncs it and renames it over `path`.
    /// Any failure, or a conflict, leaves the prior destination in place. The
    /// conflict check runs before writing and again before the rename; a write
    /// by another process between that check and the rename is not detectable.
    /// POSIX permission bits of the replaced file are kept. Returns the new stamp.
    pub fn save(self: Files, path: []const u8, input: []const u8, write_buffer: []u8, options: SaveOptions) !SaveResult {
        try self.worker();
        try absolute(path);
        if (try conflict(path, options.expected)) |found| return .{ .conflict = found };
        const mode: std.fs.File.Mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else if (try observe(path)) |current| current.mode & 0o7777 else std.fs.File.default_mode;
        var atomic = try std.fs.cwd().atomicFile(path, .{ .mode = mode, .write_buffer = write_buffer });
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(input) catch return atomic.file_writer.err orelse error.WriteFailed;
        try atomic.flush();
        try atomic.file_writer.file.sync();
        if (try conflict(path, options.expected)) |found| return .{ .conflict = found };
        try atomic.renameIntoPlace();
        if (options.durable_directory and builtin.os.tag != .windows) syncParent(path);
        const written = try observe(path) orelse return error.FileChanged;
        if (written.size != input.len) return error.FileChanged;
        return .{ .saved = written };
    }
    fn syncParent(path: []const u8) void {
        const parent = std.fs.path.dirname(path) orelse return;
        var dir = std.fs.cwd().openDir(parent, .{ .iterate = true }) catch return;
        defer dir.close();
        // Raw call: some filesystems reject directory fsync with EINVAL, which
        // std.posix treats as unreachable. The rename already succeeded.
        _ = std.posix.system.fsync(dir.fd);
    }
};
