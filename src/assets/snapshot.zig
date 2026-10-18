const std = @import("std");
const builtin = @import("builtin");

pub const Asset = struct { path: []const u8, mime: []const u8, bytes: []const u8, digest: [32]u8 };
pub const Limits = struct {
    max_files: usize = 4096,
    max_entries: usize = 8192,
    max_depth: usize = 32,
    max_path_bytes: usize = 4096,
    max_file_bytes: usize = 16 * 1024 * 1024,
    max_total_bytes: usize = 64 * 1024 * 1024,
};

/// Immutable owned bytes. Move, do not copy ownership. `deinit` is legal only
/// after every reader (including an attached View) has released these bytes.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    files: []const Asset,
    digest: [32]u8,
    total_bytes: usize,

    /// The directory is borrowed only during this synchronous call. It must
    /// permit iteration. Concurrent edits may fail or produce a mixed snapshot;
    /// callers retain the previous snapshot on error and rescan on next notice.
    pub fn load(allocator: std.mem.Allocator, directory: std.fs.Dir, limits: Limits) !Snapshot {
        if (limits.max_files == 0 or limits.max_entries == 0 or limits.max_depth == 0 or
            limits.max_path_bytes == 0 or limits.max_file_bytes == 0 or limits.max_total_bytes == 0) return error.InvalidLimits;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        var builder: Builder = .{ .allocator = arena.allocator(), .limits = limits };
        try builder.scan(directory, "", 0);
        const files = try builder.files.toOwnedSlice(builder.allocator);
        std.mem.sort(Asset, files, {}, struct {
            fn less(_: void, a: Asset, b: Asset) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        for (files) |file| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, file.path.len, .little);
            hash.update(&length);
            hash.update(file.path);
            std.mem.writeInt(u64, &length, file.bytes.len, .little);
            hash.update(&length);
            hash.update(&file.digest);
        }
        return .{ .arena = arena, .files = files, .digest = hash.finalResult(), .total_bytes = builder.total_bytes };
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// Exact normalized URL path. Query/fragment stripping belongs to transport.
    pub fn find(self: *const Snapshot, path: []const u8) ?*const Asset {
        var low: usize = 0;
        var high = self.files.len;
        while (low < high) {
            const index = low + (high - low) / 2;
            switch (std.mem.order(u8, path, self.files[index].path)) {
                .lt => high = index,
                .gt => low = index + 1,
                .eq => return &self.files[index],
            }
        }
        return null;
    }
    pub fn sameContent(self: *const Snapshot, other: *const Snapshot) bool {
        return std.mem.eql(u8, &self.digest, &other.digest);
    }
    /// Explicit allocation; the resulting table borrows this snapshot's bytes.
    /// The entry document is passed as View.Options.html rather than a resource.
    pub fn resourceTable(self: *const Snapshot, comptime Resource: type, allocator: std.mem.Allocator, entry_path: []const u8) ![]Resource {
        if (self.find(entry_path) == null) return error.EntryNotFound;
        const result = try allocator.alloc(Resource, self.files.len - 1);
        var index: usize = 0;
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, entry_path)) continue;
            result[index] = .{ .path = file.path, .mime = file.mime, .bytes = file.bytes };
            index += 1;
        }
        return result;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    files: std.ArrayList(Asset) = .empty,
    total_bytes: usize = 0,
    entries: usize = 0,
    fn scan(self: *Builder, directory: std.fs.Dir, prefix: []const u8, depth: usize) anyerror!void {
        var iterator = directory.iterate();
        while (try iterator.next()) |entry| {
            if (self.entries == self.limits.max_entries) return error.TooManyEntries;
            self.entries += 1;
            if (!validName(entry.name)) return error.InvalidAssetPath;
            const size = std.math.add(usize, prefix.len + 1, entry.name.len) catch return error.AssetPathTooLong;
            if (size > self.limits.max_path_bytes) return error.AssetPathTooLong;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.name });
            switch (entry.kind) {
                .directory => {
                    if (depth == self.limits.max_depth) return error.AssetTreeTooDeep;
                    var child = try directory.openDir(entry.name, .{ .iterate = true, .no_follow = true });
                    defer child.close();
                    const stat = try (std.fs.File{ .handle = child.fd }).stat();
                    if (stat.kind != .directory) return error.NonRegularAsset;
                    try self.scan(child, path, depth + 1);
                },
                .file => {
                    if (self.files.items.len == self.limits.max_files) return error.TooManyAssets;
                    var file = try openRegular(directory, entry.name);
                    defer file.close();
                    const before = try file.stat();
                    if (before.kind != .file) return error.NonRegularAsset;
                    const remaining = self.limits.max_total_bytes - self.total_bytes;
                    const maximum = @min(self.limits.max_file_bytes, remaining);
                    if (before.size > maximum) return error.AssetBytesExceeded;
                    const bytes = try self.allocator.alloc(u8, @intCast(before.size));
                    const length = try file.preadAll(bytes, 0);
                    var extra: [1]u8 = undefined;
                    if (length != bytes.len or try file.preadAll(&extra, bytes.len) != 0) return error.AssetChangedDuringRead;
                    const after = try file.stat();
                    if (before.size != after.size or before.mtime != after.mtime or before.size != bytes.len) return error.AssetChangedDuringRead;
                    self.total_bytes += bytes.len;
                    var digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                    try self.files.append(self.allocator, .{ .path = path, .mime = mimeForPath(path), .bytes = bytes, .digest = digest });
                },
                else => return error.NonRegularAsset,
            }
        }
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or name[name.len - 1] == '.') return false;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    return true;
}

fn openRegular(directory: std.fs.Dir, name: []const u8) !std.fs.File {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const path = try windows.sliceToPrefixedFileW(directory.fd, name);
        var name_w: windows.UNICODE_STRING = .{
            .Length = @intCast(path.span().len * 2),
            .MaximumLength = @intCast(path.span().len * 2),
            .Buffer = @constCast(path.span().ptr),
        };
        var attributes: windows.OBJECT_ATTRIBUTES = .{
            .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
            .RootDirectory = directory.fd,
            .Attributes = 0,
            .ObjectName = &name_w,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        var handle: windows.HANDLE = undefined;
        var io: windows.IO_STATUS_BLOCK = undefined;
        // Open relative to the held parent and never follow the final reparse
        // point. Synchronous I/O is explicit so std.fs.File reads can be used.
        const status = windows.ntdll.NtCreateFile(&handle, windows.GENERIC_READ | windows.SYNCHRONIZE, &attributes, &io, null, windows.FILE_ATTRIBUTE_NORMAL, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE, windows.FILE_OPEN, windows.FILE_NON_DIRECTORY_FILE | windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT, null, 0);
        switch (status) {
            .SUCCESS => return .{ .handle = handle },
            .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .ACCESS_DENIED => return error.AccessDenied,
            .FILE_IS_A_DIRECTORY => return error.NonRegularAsset,
            else => return windows.unexpectedStatus(status),
        }
    }
    if (builtin.os.tag == .wasi) return error.UnsupportedPlatform;
    return .{ .handle = try std.posix.openat(directory.fd, name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0) };
}

pub fn mimeForPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const Pair = struct { []const u8, []const u8 };
    const entries = [_]Pair{
        .{ ".html", "text/html; charset=utf-8" },     .{ ".htm", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" }, .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },       .{ ".json", "application/json" },
        .{ ".txt", "text/plain; charset=utf-8" },     .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },                     .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },                   .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },                   .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" },             .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },                  .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },                      .{ ".pdf", "application/pdf" },
        .{ ".map", "application/json" },
    };
    for (entries) |pair| if (std.ascii.eqlIgnoreCase(extension, pair[0])) return pair[1];
    return "application/octet-stream";
}

test "snapshot sorts immutable bytes, hashes content and builds an explicit resource table" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "z.js", .data = "one" });
    try temporary.dir.writeFile(.{ .sub_path = "index.html", .data = "<html>first</html>" });
    try temporary.dir.makeDir("nested");
    try temporary.dir.writeFile(.{ .sub_path = "nested/file.bin", .data = "\x00\xff" });
    var first = try Snapshot.load(std.testing.allocator, temporary.dir, .{});
    defer first.deinit();
    try std.testing.expectEqualStrings("/index.html", first.files[0].path);
    try std.testing.expectEqualStrings("\x00\xff", first.find("/nested/file.bin").?.bytes);
    const Resource = struct { path: []const u8, mime: []const u8, bytes: []const u8 };
    const table = try first.resourceTable(Resource, std.testing.allocator, "/index.html");
    defer std.testing.allocator.free(table);
    try std.testing.expectEqual(2, table.len);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", table[1].mime);
    var same = try Snapshot.load(std.testing.allocator, temporary.dir, .{});
    defer same.deinit();
    try std.testing.expect(first.sameContent(&same));
    try temporary.dir.writeFile(.{ .sub_path = "z.js", .data = "two" });
    var changed = try Snapshot.load(std.testing.allocator, temporary.dir, .{});
    defer changed.deinit();
    try std.testing.expect(!first.sameContent(&changed));
    try std.testing.expectEqualStrings("one", first.find("/z.js").?.bytes);
    try temporary.dir.deleteFile("nested/file.bin");
    var deleted = try Snapshot.load(std.testing.allocator, temporary.dir, .{});
    defer deleted.deinit();
    try std.testing.expect(!changed.sameContent(&deleted));
}

test "snapshot bounds files entries bytes depth and portable paths" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "a.txt", .data = "abc" });
    try std.testing.expectError(error.AssetBytesExceeded, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_file_bytes = 2 }));
    try std.testing.expectError(error.AssetBytesExceeded, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_total_bytes = 2 }));
    try std.testing.expectError(error.AssetPathTooLong, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_path_bytes = 2 }));
    try temporary.dir.writeFile(.{ .sub_path = "b.txt", .data = "abc" });
    try std.testing.expectError(error.TooManyAssets, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_files = 1 }));
    try std.testing.expectError(error.TooManyEntries, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_entries = 1 }));
    try temporary.dir.makePath("nested/child");
    try std.testing.expectError(error.AssetTreeTooDeep, Snapshot.load(std.testing.allocator, temporary.dir, .{ .max_depth = 1 }));
    try temporary.dir.writeFile(.{ .sub_path = "bad name", .data = "" });
    try std.testing.expectError(error.InvalidAssetPath, Snapshot.load(std.testing.allocator, temporary.dir, .{}));
}

test "snapshot rejects symbolic links instead of embedding their target" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "a.txt", .data = "private" });
    temporary.dir.symLink("a.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectError(error.NonRegularAsset, Snapshot.load(std.testing.allocator, temporary.dir, .{}));
}

test "snapshot releases every allocation on construction failure" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(.{ .sub_path = "index.html", .data = "<html>entry</html>" });
    try temporary.dir.makePath("nested");
    try temporary.dir.writeFile(.{ .sub_path = "nested/file.txt", .data = "snapshot" });
    const Probe = struct {
        fn load(allocator: std.mem.Allocator, directory: std.fs.Dir) !void {
            var snapshot = try Snapshot.load(allocator, directory, .{});
            defer snapshot.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.load, .{temporary.dir});
}
