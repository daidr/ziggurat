const std = @import("std");
const file_uri = @import("file_uri.zig");
const positions = @import("positions.zig");

pub const Folder = struct { uri: []const u8, name: []const u8 };
pub const Options = struct {
    root_uri: ?[]const u8 = null,
    /// null: single-file mode; empty: an open workspace with no folders.
    folders: ?[]const Folder = null,
    path_case: file_uri.Case = .sensitive,
    cancellation: ?*const positions.Cancellation = null,
};
pub const Limits = struct {
    folders: usize = 32,
    bytes: usize = 64 * 1024,
    work_bytes: usize = 1024 * 1024,
    products: usize = 4,
    incoming: usize = 4,
    pub fn validate(self: Limits) !void {
        if (self.folders > 32 or self.bytes < @sizeOf(Snapshot) or self.bytes > 1024 * 1024 or self.work_bytes == 0 or self.work_bytes > 16 * 1024 * 1024 or self.products == 0 or self.products > 8 or self.incoming == 0 or self.incoming > 16) return error.InvalidLimits;
    }
};
pub fn cancelled(flag: ?*const positions.Cancellation) !void {
    if (flag) |value| if (value.requested.load(.acquire)) return error.Cancelled;
}
/// Immutable, owner-thread reference counted snapshot. Workers may read it only
/// while a captured product owns a reference; retain/release are owner-only.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    root_uri: ?[]const u8,
    folders: ?[]Folder,
    path_case: file_uri.Case,
    storage: []u8,
    bytes: usize,
    references: usize = 1,
    busy: bool = false,
    pub fn create(allocator: std.mem.Allocator, options: Options, limits: Limits) !*Snapshot {
        try limits.validate();
        try cancelled(options.cancellation);
        const folders = options.folders orelse &.{};
        if (folders.len > limits.folders) return error.WorkspaceCapacityExceeded;
        var bytes: usize = @sizeOf(Snapshot) + folders.len * @sizeOf(Folder);
        var work: usize = 0;
        if (options.root_uri) |uri| {
            if (uri.len > 4096) return error.InvalidFileUri;
            try charge(&work, 16 * uri.len, limits.work_bytes);
            try file_uri.validate(uri);
            try charge(&bytes, uri.len, limits.bytes);
        }
        for (folders, 0..) |folder, index| {
            try cancelled(options.cancellation);
            if (folder.uri.len > 4096 or folder.name.len > 256) return error.WorkspaceCapacityExceeded;
            try charge(&work, 16 * folder.uri.len + 4 * folder.name.len, limits.work_bytes);
            try file_uri.validate(folder.uri);
            if (folder.name.len == 0 or folder.name.len > 256 or !std.unicode.utf8ValidateSlice(folder.name) or std.mem.indexOfScalar(u8, folder.name, 0) != null) return error.InvalidFolderName;
            try charge(&bytes, folder.uri.len + folder.name.len, limits.bytes);
            for (folders[0..index]) |before| {
                try charge(&work, 32 * (before.uri.len + folder.uri.len), limits.work_bytes);
                if (try file_uri.contains(before.uri, folder.uri, options.path_case) and try file_uri.contains(folder.uri, before.uri, options.path_case)) return error.DuplicateFolder;
            }
        }
        if (bytes > limits.bytes) return error.WorkspaceCapacityExceeded;
        const self = try allocator.create(Snapshot);
        errdefer allocator.destroy(self);
        const items = try allocator.alloc(Folder, folders.len);
        errdefer allocator.free(items);
        const storage = try allocator.alloc(u8, bytes - @sizeOf(Snapshot) - folders.len * @sizeOf(Folder));
        errdefer allocator.free(storage);
        var at: usize = 0;
        const root = if (options.root_uri) |uri| copy(storage, &at, uri) else null;
        for (folders, items) |folder, *item| item.* = .{ .uri = copy(storage, &at, folder.uri), .name = copy(storage, &at, folder.name) };
        try cancelled(options.cancellation);
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .root_uri = root, .folders = if (options.folders != null) items else null, .path_case = options.path_case, .storage = storage, .bytes = bytes };
        return self;
    }
    pub fn retain(self: *Snapshot) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
        if (self.references == std.math.maxInt(usize)) return error.CapacityExceeded;
        self.references += 1;
    }
    pub fn release(self: *Snapshot) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId() and !self.busy and self.references != 0);
        self.references -= 1;
        if (self.references != 0) return;
        self.busy = true;
        const allocator = self.allocator;
        if (self.folders) |folders| allocator.free(folders);
        allocator.free(self.storage);
        allocator.destroy(self);
    }
    /// Longest decoded segment ancestor; this is lexical routing, never proof
    /// that a filesystem object belongs to a directory or security boundary.
    pub fn folderFor(self: *const Snapshot, uri: []const u8) !?usize {
        try file_uri.validate(uri);
        var result: ?usize = null;
        var best: usize = 0;
        for (self.folders orelse &.{}, 0..) |folder, index| {
            if (try file_uri.contains(folder.uri, uri, self.path_case)) {
                const length = try file_uri.decodedPathLength(folder.uri);
                if (result == null or length > best) {
                    result = index;
                    best = length;
                }
            }
        }
        return result;
    }
};
fn copy(storage: []u8, at: *usize, value: []const u8) []const u8 {
    const result = storage[at.*..][0..value.len];
    @memcpy(result, value);
    at.* += value.len;
    return result;
}
fn charge(total: *usize, amount: usize, limit: usize) !void {
    if (total.* > limit or amount > limit - total.*) return error.WorkspaceCapacityExceeded;
    total.* += amount;
}
fn owned(allocator: std.mem.Allocator) !void {
    const snapshot = try Snapshot.create(allocator, .{ .root_uri = "file:///a", .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///a/b", .name = "B" } } }, .{});
    defer snapshot.release();
    try std.testing.expectEqual(@as(?usize, 1), try snapshot.folderFor("file:///a/b/c"));
    try std.testing.expectEqual(@as(?usize, null), try snapshot.folderFor("file:///abc"));
    try snapshot.retain();
    snapshot.release();
}
test "workspace snapshots own names and URIs with bounded candidate failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, owned, .{});
    try std.testing.expectError(error.DuplicateFolder, Snapshot.create(std.testing.allocator, .{ .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///%61/", .name = "Alias" } } }, .{}));
    var cancellation: positions.Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, Snapshot.create(std.testing.allocator, .{ .cancellation = &cancellation }, .{}));
}
