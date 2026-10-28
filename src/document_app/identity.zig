const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const max_path = 4096;

/// Bounded inline path bytes. Values are copied, never borrowed, so registry
/// slots and recent entries keep stable ownership without an allocator.
pub const Path = struct {
    len: u16 = 0,
    bytes: [max_path]u8 = undefined,
    pub fn init(value: []const u8) !Path {
        if (value.len == 0 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidPath;
        if (value.len > max_path) return error.PathTooLong;
        var path: Path = .{ .len = @intCast(value.len) };
        @memcpy(path.bytes[0..value.len], value);
        return path;
    }
    pub fn slice(self: *const Path) []const u8 {
        return self.bytes[0..self.len];
    }
    /// Windows paths compare with ASCII case folding; other systems compare bytes.
    pub fn eql(self: *const Path, other: *const Path) bool {
        return pathEql(self.slice(), other.slice());
    }
    pub fn basename(self: *const Path) []const u8 {
        return std.fs.path.basename(self.slice());
    }
};

pub fn pathEql(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

/// Filesystem object identity. Zero means unknown; atomic replacement by this
/// module or another editor gives the same path a new key.
pub const FileKey = struct {
    device: u64 = 0,
    inode: u64 = 0,
    pub fn known(self: FileKey) bool {
        return self.inode != 0;
    }
    pub fn eql(self: FileKey, other: FileKey) bool {
        return self.known() and other.known() and self.device == other.device and self.inode == other.inode;
    }
};

/// Disk observation used for external-modification detection. Equal stamps
/// are treated as unchanged content; a same-size write inside one timestamp
/// tick of a coarse filesystem is not detectable from metadata alone.
pub const Stamp = struct {
    size: u64,
    mtime_ns: i128,
    key: FileKey,
    /// POSIX mode bits; 0 on Windows.
    mode: u32 = 0,
    pub fn eql(self: Stamp, other: Stamp) bool {
        return self.size == other.size and self.mtime_ns == other.mtime_ns and self.key.device == other.key.device and self.key.inode == other.key.inode;
    }
};

/// A file-backed document's identity: the canonical absolute path after
/// symlink resolution, plus the object key observed when it was resolved.
/// Two identities name one document when their paths match, or when both keys
/// are known and match (hard links or alternate spellings of one file).
pub const Identity = struct {
    path: Path,
    key: FileKey = .{},
    pub fn eql(self: *const Identity, other: *const Identity) bool {
        return self.path.eql(&other.path) or self.key.eql(other.key);
    }
};

const ByHandleFileInformation = extern struct {
    attributes: u32,
    creation: [2]u32,
    access: [2]u32,
    write: [2]u32,
    volume_serial: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
extern "kernel32" fn GetFileInformationByHandle(file: std.os.windows.HANDLE, info: *ByHandleFileInformation) callconv(.winapi) std.os.windows.BOOL;

pub fn fileKey(file: std.Io.File) !FileKey {
    switch (builtin.os.tag) {
        .windows => {
            var info: ByHandleFileInformation = undefined;
            if (GetFileInformationByHandle(file.handle, &info) == .FALSE) return error.Unexpected;
            return .{ .device = info.volume_serial, .inode = (@as(u64, info.index_high) << 32) | info.index_low };
        },
        .linux, .macos, .freebsd, .netbsd, .openbsd => {
            const st = try zio.posix.fstat(file.handle);
            return .{ .device = @intCast(st.dev), .inode = @intCast(st.ino) };
        },
        else => return .{},
    }
}

pub fn stamp(file: std.Io.File) !Stamp {
    const st = try file.stat(zio.io());
    if (st.kind != .file) return error.NotAFile;
    return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds, .key = try fileKey(file), .mode = zio.modeOf(st.permissions) };
}
