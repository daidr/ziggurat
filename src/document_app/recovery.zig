const std = @import("std");
const zio = @import("ziggurat_io");
const id = @import("identity.zig");
const Files = @import("files.zig").Files;
const RecoveryName = @import("registry.zig").RecoveryName;

const magic = "ZGRECOV1";
const extension = ".zrec";
const lock_name = "lock";
const fixed_len = magic.len + 1 + 2 + (8 + 16 + 8 + 8) + 8 + 16 + 8;

/// Unsaved document content captured for crash recovery. Slices borrow the
/// caller's buffers when encoding and the decoded bytes when reading.
pub const Snapshot = struct {
    /// Canonical path of a file document; null for untitled documents.
    path: ?[]const u8 = null,
    /// Disk stamp the unsaved edits were based on, for conflict review on restore.
    base: ?id.Stamp = null,
    revision: u64,
    saved_ns: i128,
    content: []const u8,

    pub fn encodedLen(self: Snapshot) usize {
        return fixed_len + (if (self.path) |path| path.len else 0) + self.content.len + 4;
    }
    pub fn encode(self: Snapshot, output: []u8) ![]const u8 {
        const path = self.path orelse "";
        if (path.len > id.max_path) return error.PathTooLong;
        if (output.len < self.encodedLen()) return error.NoSpaceLeft;
        var writer: std.Io.Writer = .fixed(output);
        const base = self.base orelse id.Stamp{ .size = 0, .mtime_ns = 0, .key = .{} };
        writer.writeAll(magic) catch unreachable;
        writer.writeByte(@as(u8, @intFromBool(self.path != null)) | (@as(u8, @intFromBool(self.base != null)) << 1)) catch unreachable;
        writer.writeInt(u16, @intCast(path.len), .little) catch unreachable;
        writer.writeInt(u64, base.size, .little) catch unreachable;
        writer.writeInt(i128, base.mtime_ns, .little) catch unreachable;
        writer.writeInt(u64, base.key.device, .little) catch unreachable;
        writer.writeInt(u64, base.key.inode, .little) catch unreachable;
        writer.writeInt(u64, self.revision, .little) catch unreachable;
        writer.writeInt(i128, self.saved_ns, .little) catch unreachable;
        writer.writeInt(u64, self.content.len, .little) catch unreachable;
        writer.writeAll(path) catch unreachable;
        writer.writeAll(self.content) catch unreachable;
        writer.writeInt(u32, std.hash.Crc32.hash(writer.buffered()), .little) catch unreachable;
        return writer.buffered();
    }
    /// Rejects truncated, corrupted or foreign files.
    pub fn decode(bytes: []const u8) !Snapshot {
        if (bytes.len < fixed_len + 4 or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidFormat;
        const body = bytes[0 .. bytes.len - 4];
        if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little)) return error.Corrupt;
        var reader: std.Io.Reader = .fixed(body[magic.len..]);
        const flags = reader.takeByte() catch unreachable;
        if (flags & ~@as(u8, 3) != 0) return error.InvalidFormat;
        const path_len = reader.takeInt(u16, .little) catch unreachable;
        var base: id.Stamp = .{ .size = undefined, .mtime_ns = undefined, .key = .{} };
        base.size = reader.takeInt(u64, .little) catch unreachable;
        base.mtime_ns = reader.takeInt(i128, .little) catch unreachable;
        base.key.device = reader.takeInt(u64, .little) catch unreachable;
        base.key.inode = reader.takeInt(u64, .little) catch unreachable;
        const revision = reader.takeInt(u64, .little) catch unreachable;
        const saved_ns = reader.takeInt(i128, .little) catch unreachable;
        const content_len = reader.takeInt(u64, .little) catch unreachable;
        if (path_len > id.max_path or (flags & 1 == 0 and path_len != 0) or (flags & 1 != 0 and path_len == 0)) return error.InvalidFormat;
        if (body.len != fixed_len + path_len + content_len) return error.InvalidFormat;
        const path = body[fixed_len..][0..path_len];
        return .{ .path = if (flags & 1 != 0) path else null, .base = if (flags & 2 != 0) base else null, .revision = revision, .saved_ns = saved_ns, .content = body[fixed_len + path_len ..] };
    }
};

fn sessionName(buffer: *[17]u8, nonce: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "s{x:0>16}", .{nonce}) catch unreachable;
}
fn fileName(buffer: *[32]u8, name: *const RecoveryName) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}" ++ extension, .{name.slice()}) catch unreachable;
}

/// A directory of snapshots for one running process, identified by a host
/// nonce and held by an exclusive lock on its `lock` file. The lock is
/// released by the operating system if the process dies, which is how a
/// later launch tells crashed sessions from live ones sharing the root.
pub const Session = struct {
    files: Files,
    dir: std.Io.Dir,
    lock: std.Io.File,

    fn openLocked(files: Files, root: std.Io.Dir, nonce: u64, create: bool) !Session {
        try files.worker();
        var buffer: [17]u8 = undefined;
        const name = sessionName(&buffer, nonce);
        var dir = if (create) try root.createDirPathOpen(zio.io(), name, .{ .open_options = .{ .iterate = true } }) else try root.openDir(zio.io(), name, .{ .iterate = true });
        errdefer dir.close(zio.io());
        const lock = dir.createFile(zio.io(), lock_name, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.WouldBlock => return error.SessionInUse,
            else => return err,
        };
        return .{ .files = files, .dir = dir, .lock = lock };
    }
    /// Creates and locks this process's session directory under `root`.
    pub fn open(files: Files, root: std.Io.Dir, nonce: u64) !Session {
        return openLocked(files, root, nonce, true);
    }
    /// Locks a crashed session found by `orphans` so no other instance
    /// restores it concurrently. Fails with SessionInUse while it is live.
    pub fn adopt(files: Files, root: std.Io.Dir, nonce: u64) !Session {
        return openLocked(files, root, nonce, false);
    }
    /// Releases the lock and keeps the snapshots for a later launch.
    pub fn close(self: *Session) void {
        self.lock.close(zio.io());
        self.dir.close(zio.io());
    }
    /// Releases the lock and deletes the session with every snapshot in it,
    /// after a clean exit or once an adopted session has been restored.
    pub fn finish(self: *Session, root: std.Io.Dir, nonce: u64) !void {
        try self.files.worker();
        self.close();
        var buffer: [17]u8 = undefined;
        try root.deleteTree(zio.io(), sessionName(&buffer, nonce));
    }
    /// Atomically replaces the snapshot file. `buffer` holds the encoding.
    pub fn write(self: *Session, name: *const RecoveryName, snapshot: Snapshot, buffer: []u8, write_buffer: []u8) !void {
        try self.files.worker();
        const bytes = try snapshot.encode(buffer);
        var file_buffer: [32]u8 = undefined;
        var atomic = try zio.AtomicFile.init(self.dir, fileName(&file_buffer, name), .{ .write_buffer = write_buffer });
        defer atomic.deinit();
        atomic.file_writer.interface.writeAll(bytes) catch return atomic.file_writer.err orelse error.WriteFailed;
        try atomic.flush();
        try atomic.file_writer.file.sync(zio.io());
        try atomic.renameIntoPlace();
    }
    pub fn remove(self: *Session, name: *const RecoveryName) !void {
        try self.files.worker();
        var file_buffer: [32]u8 = undefined;
        self.dir.deleteFile(zio.io(), fileName(&file_buffer, name)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    /// Snapshot names in this session; unrelated files are ignored.
    pub fn list(self: *Session, output: []RecoveryName) ![]RecoveryName {
        try self.files.worker();
        var length: usize = 0;
        var iterator = self.dir.iterate();
        while (try iterator.next(zio.io())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, extension)) continue;
            const name = RecoveryName.parse(entry.name[0 .. entry.name.len - extension.len]) catch continue;
            if (length == output.len) return error.CapacityExceeded;
            output[length] = name;
            length += 1;
        }
        return output[0..length];
    }
    /// Reads and validates one snapshot into `output`.
    pub fn read(self: *Session, name: *const RecoveryName, output: []u8) !Snapshot {
        try self.files.worker();
        var file_buffer: [32]u8 = undefined;
        const bytes = try self.dir.readFile(zio.io(), fileName(&file_buffer, name), output);
        if (bytes.len == output.len) {
            const size = (try self.dir.statFile(zio.io(), fileName(&file_buffer, name), .{})).size;
            if (size > output.len) return error.CapacityExceeded;
        }
        return Snapshot.decode(bytes);
    }
};

/// Session nonces under `root` whose lock is not held: sessions of processes
/// that ended without `finish`. `own` excludes the caller's live session.
pub fn orphans(files: Files, root: std.Io.Dir, own: ?u64, output: []u64) ![]u64 {
    try files.worker();
    var length: usize = 0;
    var iterator = root.iterate();
    while (try iterator.next(zio.io())) |entry| {
        if (entry.kind != .directory or entry.name.len != 17 or entry.name[0] != 's') continue;
        const nonce = std.fmt.parseInt(u64, entry.name[1..], 16) catch continue;
        if (own == nonce) continue;
        var session = Session.adopt(files, root, nonce) catch |err| switch (err) {
            error.SessionInUse => continue,
            else => return err,
        };
        session.close();
        if (length == output.len) return error.CapacityExceeded;
        output[length] = nonce;
        length += 1;
    }
    return output[0..length];
}
