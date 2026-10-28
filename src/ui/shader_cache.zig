//! The on-disk cache of compiled GPU effect code. Direct3D compiles an
//! effect's HLSL with the system compiler the first time a program draws;
//! the bytecode is kept here, named by the SHA-256 of what it was compiled
//! from, so later launches skip the compiler. One directory serves every
//! application of the user, as the system's own shader cache does: the
//! names say what the files hold. Files are written under a temporary name
//! and renamed, as another process may read them, and the least recently
//! used go first once the directory holds more than `default_limit` bytes.
//! Every failure means doing without the cache.
const std = @import("std");
const zio = @import("ziggurat_io");

/// Bytes kept before the least recently used files are removed.
pub const default_limit: u64 = 32 << 20;
/// Largest file the cache reads back.
pub const max_file_bytes = 4 << 20;

/// A file name: 64 hex digits of SHA-256 and an extension.
pub const Name = struct {
    buffer: [72]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Name) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The name of the code compiled from `source` with `flags` (the target,
/// entry point and compiler options), with extension `extension`.
pub fn name(flags: []const u8, source: []const u8, extension: []const u8) Name {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(flags);
    hash.update(source);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var result: Name = .{};
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(result.buffer[0..hex.len], &hex);
    const ext = extension[0..@min(extension.len, result.buffer.len - hex.len)];
    @memcpy(result.buffer[hex.len..][0..ext.len], ext);
    result.len = hex.len + ext.len;
    return result;
}

/// Whether `bytes` look like whole DXBC bytecode: its magic and the size
/// its header gives. Direct3D checks the checksum.
pub fn validDxbc(bytes: []const u8) bool {
    return bytes.len >= 32 and std.mem.eql(u8, bytes[0..4], "DXBC") and std.mem.readInt(u32, bytes[24..28], .little) == bytes.len;
}

pub const DiskCache = struct {
    dir: ?std.Io.Dir = null,
    limit: u64 = default_limit,

    /// The user's cache directory: `%LOCALAPPDATA%\Ziggurat\ShaderCache` on
    /// Windows, `$XDG_CACHE_HOME/ziggurat/shader-cache` (or
    /// `~/.cache/...`) elsewhere. Without one the cache keeps nothing.
    pub fn openDefault(allocator: std.mem.Allocator) DiskCache {
        const builtin = @import("builtin");
        const base, const sub = if (builtin.os.tag == .windows)
            .{ zio.getEnvVarOwned(allocator, "LOCALAPPDATA") catch return .{}, "Ziggurat\\ShaderCache" }
        else if (zio.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |value|
            .{ value, "ziggurat/shader-cache" }
        else |_|
            .{ zio.getEnvVarOwned(allocator, "HOME") catch return .{}, ".cache/ziggurat/shader-cache" };
        defer allocator.free(base);
        if (base.len == 0) return .{};
        var root = std.Io.Dir.openDirAbsolute(zio.io(), base, .{}) catch return .{};
        defer root.close(zio.io());
        return openAt(root, sub) catch .{};
    }
    /// The cache in `sub_path` of `root`, created if missing.
    pub fn openAt(root: std.Io.Dir, sub_path: []const u8) !DiskCache {
        return .{ .dir = try root.createDirPathOpen(zio.io(), sub_path, .{ .open_options = .{ .iterate = true } }) };
    }
    pub fn close(self: *DiskCache) void {
        if (self.dir) |*dir| dir.close(zio.io());
        self.dir = null;
    }

    /// The file `file_name` if it holds valid code, refreshed as the most
    /// recently used. The caller frees it with `allocator`.
    pub fn load(self: *DiskCache, allocator: std.mem.Allocator, file_name: []const u8, valid: *const fn ([]const u8) bool) ?[]u8 {
        const dir = self.dir orelse return null;
        const bytes = dir.readFileAlloc(zio.io(), file_name, allocator, .limited(max_file_bytes)) catch return null;
        if (!valid(bytes)) {
            allocator.free(bytes);
            return null;
        }
        if (dir.openFile(zio.io(), file_name, .{ .mode = .read_write })) |file| {
            defer file.close(zio.io());
            file.setTimestampsNow(zio.io()) catch {};
        } else |_| {}
        return bytes;
    }

    /// Keep `bytes` as `file_name`, then trim the cache.
    pub fn store(self: *DiskCache, file_name: []const u8, bytes: []const u8) void {
        const dir = self.dir orelse return;
        var temporary: [96]u8 = undefined;
        var random: [8]u8 = undefined;
        zio.random.bytes(&random);
        const temporary_name = std.fmt.bufPrint(&temporary, "{s}.{x}.tmp", .{ file_name[0..@min(file_name.len, 64)], std.mem.readInt(u64, &random, .little) }) catch return;
        const file = dir.createFile(zio.io(), temporary_name, .{ .exclusive = true }) catch return;
        const written = blk: {
            file.writeStreamingAll(zio.io(), bytes) catch break :blk false;
            break :blk true;
        };
        file.close(zio.io());
        if (!written) {
            dir.deleteFile(zio.io(), temporary_name) catch {};
            return;
        }
        dir.rename(temporary_name, dir, file_name, zio.io()) catch {
            dir.deleteFile(zio.io(), temporary_name) catch {};
            return;
        };
        self.trim();
    }

    /// Remove the least recently used files while the cache holds more
    /// than its limit.
    pub fn trim(self: *DiskCache) void {
        const dir = self.dir orelse return;
        const Entry = struct { name: [96]u8, len: u8, size: u64, used: i128 };
        var entries: [512]Entry = undefined;
        var count: usize = 0;
        var total: u64 = 0;
        var iterator = dir.iterate();
        while (iterator.next(zio.io()) catch null) |entry| {
            if (entry.kind != .file or entry.name.len > 96) continue;
            const stat = dir.statFile(zio.io(), entry.name, .{}) catch continue;
            total += stat.size;
            const item: Entry = .{ .name = undefined, .len = @intCast(entry.name.len), .size = stat.size, .used = stat.mtime.nanoseconds };
            if (count < entries.len) {
                entries[count] = item;
                @memcpy(entries[count].name[0..entry.name.len], entry.name);
                count += 1;
            } else {
                // Keep the oldest; a newer file than all of them stays.
                var newest: usize = 0;
                for (entries[0..count], 0..) |e, i| if (e.used > entries[newest].used) {
                    newest = i;
                };
                if (item.used < entries[newest].used) {
                    entries[newest] = item;
                    @memcpy(entries[newest].name[0..entry.name.len], entry.name);
                }
            }
        }
        if (total <= self.limit) return;
        std.mem.sort(Entry, entries[0..count], {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.used < b.used;
            }
        }.less);
        for (entries[0..count]) |e| {
            if (total <= self.limit) break;
            dir.deleteFile(zio.io(), e.name[0..e.len]) catch continue;
            total -|= e.size;
        }
    }
};

fn fakeCode(comptime len: usize, fill: u8) [len]u8 {
    var bytes: [len]u8 = @splat(fill);
    @memcpy(bytes[0..4], "DXBC");
    std.mem.writeInt(u32, bytes[24..28], len, .little);
    return bytes;
}

test "names hash flags and source" {
    const a = name("ps_4_0", "float4 main()", ".dxbc");
    const b = name("ps_5_0", "float4 main()", ".dxbc");
    try std.testing.expectEqual(@as(usize, 69), a.slice().len);
    try std.testing.expect(!std.mem.eql(u8, a.slice(), b.slice()));
    try std.testing.expect(std.mem.endsWith(u8, a.slice(), ".dxbc"));
    try std.testing.expectEqualStrings(a.slice(), name("ps_4_0", "float4 main()", ".dxbc").slice());
}

test "the cache keeps valid code and trims the least recently used" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var cache = try DiskCache.openAt(tmp.dir, "ShaderCache");
    defer cache.close();
    cache.limit = 300;
    const first = fakeCode(128, 1);
    const second = fakeCode(128, 2);
    const a = name("x", "first", ".dxbc");
    const b = name("x", "second", ".dxbc");
    try std.testing.expect(cache.load(std.testing.allocator, a.slice(), validDxbc) == null);
    cache.store(a.slice(), &first);
    const loaded = cache.load(std.testing.allocator, a.slice(), validDxbc).?;
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualSlices(u8, &first, loaded);
    // Make the first file the older one, then a third file overflows.
    const old: i128 = 1_000_000_000 * std.time.ns_per_s;
    {
        const file = try cache.dir.?.openFile(zio.io(), a.slice(), .{ .mode = .read_write });
        defer file.close(zio.io());
        try file.setTimestamps(zio.io(), .{ .access_timestamp = .{ .new = .fromNanoseconds(old) }, .modify_timestamp = .{ .new = .fromNanoseconds(old) } });
    }
    cache.store(b.slice(), &second);
    const c = name("x", "third", ".dxbc");
    cache.store(c.slice(), &fakeCode(128, 3));
    try std.testing.expect(cache.load(std.testing.allocator, a.slice(), validDxbc) == null);
    const kept = cache.load(std.testing.allocator, b.slice(), validDxbc).?;
    std.testing.allocator.free(kept);
    // Truncated or foreign bytes are not code.
    try cache.dir.?.writeFile(zio.io(), .{ .sub_path = a.slice(), .data = first[0..64] });
    try std.testing.expect(cache.load(std.testing.allocator, a.slice(), validDxbc) == null);
    try std.testing.expect(!validDxbc("DXBC"));
    // No temporary files stay behind.
    var iterator = cache.dir.?.iterate();
    while (try iterator.next(zio.io())) |entry| try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
}

test "without a directory the cache keeps nothing" {
    var cache: DiskCache = .{};
    cache.store("name", "bytes");
    try std.testing.expect(cache.load(std.testing.allocator, "name", validDxbc) == null);
    cache.close();
}
