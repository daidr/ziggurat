const std = @import("std");

pub const Resource = struct {
    path: []const u8,
    mime: []const u8,
    /// Immutable storage, borrowed by an attached View until resource release.
    bytes: []const u8,
};
pub const FileResource = struct { path: []const u8, mime: []const u8, file: std.fs.File };
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *@This()) void {
        self.requested.store(true, .release);
    }
    fn check(self: *const @This()) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const Limits = struct {
    max_files: u16 = 128,
    max_file_bytes: usize = 16 * 1024 * 1024,
    max_total_bytes: usize = 32 * 1024 * 1024,
    cancellation: ?*const Cancellation = null,
};

/// Owning, noncopyable after initialization. The caller supplies already-opened
/// regular files, retains/ closes their handles, and explicitly manages a worker.
/// Reads use offsets and do not change the file cursor. This is a byte snapshot,
/// not an atomic filesystem transaction; concurrent writers must be coordinated.
pub const FileSnapshot = struct {
    allocator: std.mem.Allocator,
    html: []const u8,
    resources: []const Resource,
    pub fn init(allocator: std.mem.Allocator, main_thread: std.Thread.Id, document: std.fs.File, files: []const FileResource, limits: Limits) !FileSnapshot {
        if (std.Thread.getCurrentId() == main_thread) return error.UiThreadForbidden;
        if (limits.max_files == 0 or limits.max_files > 4096 or files.len >= limits.max_files) return error.TooManyFiles;
        if (limits.max_file_bytes == 0 or limits.max_total_bytes == 0 or limits.max_total_bytes > 256 * 1024 * 1024) return error.InvalidLimits;
        if (limits.cancellation) |cancel| try cancel.check();
        // Reject metadata before touching the files; paths are routes, never
        // filesystem authority or directory containment checks.
        for (files, 0..) |file, i| {
            if (!validPath(file.path) or std.mem.eql(u8, file.path, "/")) return error.InvalidResourcePath;
            if (file.mime.len == 0 or file.mime.len > 127) return error.InvalidMime;
            for (file.mime) |byte| if (byte < 32 or byte > 126) return error.InvalidMime;
            for (files[0..i]) |other| if (std.mem.eql(u8, file.path, other.path)) return error.DuplicateResourcePath;
        }
        const descriptors = try std.math.mul(usize, files.len, @sizeOf(Resource));
        if (descriptors > limits.max_total_bytes) return error.SnapshotTooLarge;
        var remaining = limits.max_total_bytes - descriptors;
        const html = try read(allocator, document, limits, &remaining);
        errdefer allocator.free(html);
        if (!std.unicode.utf8ValidateSlice(html) or std.mem.indexOfScalar(u8, html, 0) != null) return error.InvalidDocument;
        const resources = try allocator.alloc(Resource, files.len);
        errdefer allocator.free(resources);
        var initialized: usize = 0;
        errdefer for (resources[0..initialized]) |resource| {
            allocator.free(resource.path);
            allocator.free(resource.mime);
            allocator.free(resource.bytes);
        };
        for (resources, files) |*destination, source| {
            const metadata = try std.math.add(usize, source.path.len, source.mime.len);
            if (metadata > remaining) return error.SnapshotTooLarge;
            remaining -= metadata;
            const path = try allocator.dupe(u8, source.path);
            errdefer allocator.free(path);
            const mime = try allocator.dupe(u8, source.mime);
            errdefer allocator.free(mime);
            const bytes = try read(allocator, source.file, limits, &remaining);
            destination.* = .{ .path = path, .mime = mime, .bytes = bytes };
            initialized += 1;
        }
        return .{ .allocator = allocator, .html = html, .resources = resources };
    }
    pub fn deinit(self: *FileSnapshot) void {
        for (self.resources) |resource| {
            self.allocator.free(resource.path);
            self.allocator.free(resource.mime);
            self.allocator.free(resource.bytes);
        }
        self.allocator.free(self.resources);
        self.allocator.free(self.html);
        self.* = undefined;
    }
    fn read(allocator: std.mem.Allocator, file: std.fs.File, limits: Limits, remaining: *usize) ![]u8 {
        if (limits.cancellation) |cancel| try cancel.check();
        const stat = try file.stat();
        if (stat.kind != .file) return error.RegularFileRequired;
        if (stat.size > limits.max_file_bytes or stat.size > remaining.*) return error.SnapshotTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (limits.cancellation) |cancel| try cancel.check();
            const end = @min(bytes.len, offset + 64 * 1024);
            const count = try file.pread(bytes[offset..end], offset);
            if (count == 0) return error.FileChanged;
            offset += count;
        }
        var extra: [1]u8 = undefined;
        if (try file.pread(&extra, stat.size) != 0) return error.FileChanged;
        if (limits.cancellation) |cancel| try cancel.check();
        remaining.* -= bytes.len;
        return bytes;
    }
};
fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] != '/') return false;
    for (path) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-_.", byte) != null)) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    return true;
}

test "snapshot files are explicit, bounded, cancelled and worker-only" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const document = try temp.dir.createFile("document.html", .{ .read = true });
    defer document.close();
    try document.writeAll("<title>private snapshot</title>");
    const asset = try temp.dir.createFile("data.txt", .{ .read = true });
    defer asset.close();
    try asset.writeAll("private asset");
    const Probe = struct {
        main: std.Thread.Id,
        document: std.fs.File,
        asset: std.fs.File,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |err| {
                self.err = err;
            };
        }
        fn check(self: *@This()) !void {
            const files = [_]FileResource{.{ .path = "/data.txt", .mime = "text/plain", .file = self.asset }};
            var result = try FileSnapshot.init(std.testing.allocator, self.main, self.document, &files, .{});
            defer result.deinit();
            try std.testing.expectEqualStrings("<title>private snapshot</title>", result.html);
            try std.testing.expectEqualStrings("private asset", result.resources[0].bytes);
            try std.testing.expectEqual(@as(u64, "<title>private snapshot</title>".len), try self.document.getPos());
            try std.testing.expectError(error.SnapshotTooLarge, FileSnapshot.init(std.testing.allocator, self.main, self.document, &files, .{ .max_total_bytes = 1 }));
            try std.testing.expectError(error.TooManyFiles, FileSnapshot.init(std.testing.allocator, self.main, self.document, &files, .{ .max_files = 1 }));
            var cancelled: Cancellation = .{};
            cancelled.request();
            try std.testing.expectError(error.Cancelled, FileSnapshot.init(std.testing.allocator, self.main, self.document, &files, .{ .cancellation = &cancelled }));
            const invalid = [_]FileResource{.{ .path = "/../escape", .mime = "text/plain", .file = self.asset }};
            try std.testing.expectError(error.InvalidResourcePath, FileSnapshot.init(std.testing.allocator, self.main, self.document, &invalid, .{}));
            const duplicate = [_]FileResource{ files[0], files[0] };
            try std.testing.expectError(error.DuplicateResourcePath, FileSnapshot.init(std.testing.allocator, self.main, self.document, &duplicate, .{}));
            try std.testing.checkAllAllocationFailures(std.testing.allocator, allocate, .{ self.main, self.document, self.asset });
        }
        fn allocate(allocator: std.mem.Allocator, main: std.Thread.Id, source_document: std.fs.File, source_asset: std.fs.File) !void {
            const files = [_]FileResource{.{ .path = "/asset", .mime = "text/plain", .file = source_asset }};
            var snapshot = try FileSnapshot.init(allocator, main, source_document, &files, .{});
            defer snapshot.deinit();
            try std.testing.expectEqualStrings("private asset", snapshot.resources[0].bytes);
        }
    };
    var probe: Probe = .{ .main = std.Thread.getCurrentId(), .document = document, .asset = asset };
    try std.testing.expectError(error.UiThreadForbidden, FileSnapshot.init(std.testing.allocator, probe.main, document, &.{}, .{}));
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    if (probe.err) |err| return err;
}
