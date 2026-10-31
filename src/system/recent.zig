//! Recent documents: the application's own newest-first list, kept in a file
//! of its choosing (for example under `paths.get(.user_data)`) for an Open
//! Recent menu, and the system's record of them. Windows adds the file to
//! the user's recent items and to the Recent category of the application's
//! jump list (see `jump_list`); Linux adds it to the recently used files that
//! file choosers and file managers show.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux;
// Unit tests link no native objects.
const native = !builtin.is_test;

pub const capabilities = .{ .system_recent = windows or linux };

/// As many documents as the list keeps.
pub const default_capacity = 10;

extern fn ziggurat_system_recent_add(path: [*:0]const u16) callconv(.c) void;
extern fn zsr_recent_add(path: [*:0]const u8, app_name: [*:0]const u8) callconv(.c) c_int;

/// Records an absolute path with the system. `app_name` names the
/// application in the Linux list. A blocking file or shell call: use it from
/// the owner thread only when the delay is acceptable, otherwise a worker.
pub fn addToSystem(allocator: std.mem.Allocator, path: []const u8, app_name: []const u8) !void {
    try validatePath(path);
    if (app_name.len == 0 or std.mem.indexOfScalar(u8, app_name, 0) != null or !std.unicode.utf8ValidateSlice(app_name)) return error.InvalidName;
    if (comptime !native) return;
    if (comptime windows) {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(wide);
        ziggurat_system_recent_add(wide.ptr);
    } else if (comptime linux) {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);
        const name_z = try allocator.dupeSentinel(u8, app_name, 0);
        defer allocator.free(name_z);
        switch (zsr_recent_add(path_z.ptr, name_z.ptr)) {
            0 => {},
            1 => return error.InvalidPath,
            else => return error.RecentListUnavailable,
        }
    } else return error.UnsupportedCapability;
}
fn validatePath(path: []const u8) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
}

/// The application's recent documents, newest first. Owns its paths. Load,
/// change and save it on one thread.
pub const RecentDocuments = struct {
    allocator: std.mem.Allocator,
    /// The JSON file holding the list; owned.
    file: []u8,
    capacity: usize,
    paths: std.ArrayList([]u8) = .empty,

    /// Reads `file` when it exists. A missing or unreadable file starts an
    /// empty list, as a damaged list is not worth failing startup for.
    pub fn load(allocator: std.mem.Allocator, file: []const u8, capacity: usize) !RecentDocuments {
        if (capacity == 0) return error.InvalidCapacity;
        var self: RecentDocuments = .{ .allocator = allocator, .file = try allocator.dupe(u8, file), .capacity = capacity };
        errdefer self.deinit();
        const data = std.Io.Dir.cwd().readFileAlloc(zio.io(), file, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self,
        };
        defer allocator.free(data);
        const parsed = std.json.parseFromSlice([]const []const u8, allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self,
        };
        defer parsed.deinit();
        for (parsed.value) |path| {
            if (self.paths.items.len == capacity) break;
            validatePath(path) catch continue;
            if (self.indexOf(path) != null) continue;
            const copy = try allocator.dupe(u8, path);
            self.paths.append(allocator, copy) catch |err| {
                allocator.free(copy);
                return err;
            };
        }
        return self;
    }
    pub fn deinit(self: *RecentDocuments) void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.deinit(self.allocator);
        self.allocator.free(self.file);
        self.* = undefined;
    }
    /// Newest first; valid until the next change.
    pub fn items(self: *const RecentDocuments) []const []const u8 {
        return self.paths.items;
    }
    /// Moves `path` to the front, drops the oldest beyond capacity and saves.
    /// It does not record the path with the system; call `addToSystem` too.
    pub fn add(self: *RecentDocuments, path: []const u8) !void {
        try validatePath(path);
        if (self.indexOf(path)) |index| {
            const existing = self.paths.orderedRemove(index);
            self.paths.insertAssumeCapacity(0, existing);
        } else {
            const copy = try self.allocator.dupe(u8, path);
            self.paths.insert(self.allocator, 0, copy) catch |err| {
                self.allocator.free(copy);
                return err;
            };
            while (self.paths.items.len > self.capacity) self.allocator.free(self.paths.pop().?);
        }
        try self.save();
    }
    pub fn remove(self: *RecentDocuments, path: []const u8) !void {
        const index = self.indexOf(path) orelse return;
        self.allocator.free(self.paths.orderedRemove(index));
        try self.save();
    }
    /// Empties the application's list. The system's records are left alone.
    pub fn clear(self: *RecentDocuments) !void {
        for (self.paths.items) |path| self.allocator.free(path);
        self.paths.clearRetainingCapacity();
        try self.save();
    }
    fn indexOf(self: *const RecentDocuments, path: []const u8) ?usize {
        for (self.paths.items, 0..) |item, index| if (std.mem.eql(u8, item, path)) return index;
        return null;
    }
    /// Writes a temporary file beside the list and renames it over the list.
    fn save(self: *RecentDocuments) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(self.paths.items, .{}, &out.writer);
        if (std.fs.path.dirname(self.file)) |directory| try std.Io.Dir.cwd().createDirPath(zio.io(), directory);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(zio.io(), self.file, .{ .replace = true });
        defer atomic.deinit(zio.io());
        try atomic.file.writeStreamingAll(zio.io(), out.written());
        try atomic.replace(zio.io());
    }
};

test "recent documents keep newest first, unique and bounded, and persist" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try zio.realPathAlloc(dir.dir, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const file = try std.fs.path.join(std.testing.allocator, &.{ root, "state", "recent.json" });
    defer std.testing.allocator.free(file);
    const a = if (windows) "C:\\docs\\a.txt" else "/docs/a.txt";
    const b = if (windows) "C:\\docs\\b.txt" else "/docs/b.txt";
    const c = if (windows) "C:\\docs\\c.txt" else "/docs/c.txt";
    {
        var recent = try RecentDocuments.load(std.testing.allocator, file, 2);
        defer recent.deinit();
        try std.testing.expectEqual(@as(usize, 0), recent.items().len);
        try recent.add(a);
        try recent.add(b);
        try recent.add(a);
        try std.testing.expectEqualStrings(a, recent.items()[0]);
        try std.testing.expectEqualStrings(b, recent.items()[1]);
        try recent.add(c);
        try std.testing.expectEqual(@as(usize, 2), recent.items().len);
        try std.testing.expectEqualStrings(c, recent.items()[0]);
        try std.testing.expectError(error.InvalidPath, recent.add("relative.txt"));
    }
    {
        var recent = try RecentDocuments.load(std.testing.allocator, file, 10);
        defer recent.deinit();
        try std.testing.expectEqual(@as(usize, 2), recent.items().len);
        try std.testing.expectEqualStrings(c, recent.items()[0]);
        try std.testing.expectEqualStrings(a, recent.items()[1]);
        try recent.remove(a);
        try std.testing.expectEqual(@as(usize, 1), recent.items().len);
        try recent.clear();
    }
    var recent = try RecentDocuments.load(std.testing.allocator, file, 10);
    defer recent.deinit();
    try std.testing.expectEqual(@as(usize, 0), recent.items().len);
    try dir.dir.writeFile(zio.io(), .{ .sub_path = "state/recent.json", .data = "{not json" });
    var damaged = try RecentDocuments.load(std.testing.allocator, file, 10);
    defer damaged.deinit();
    try std.testing.expectEqual(@as(usize, 0), damaged.items().len);
}

test "system records reject relative paths and empty names" {
    try std.testing.expectError(error.InvalidPath, addToSystem(std.testing.allocator, "a.txt", "App"));
    try std.testing.expectError(error.InvalidName, addToSystem(std.testing.allocator, if (windows) "C:\\a.txt" else "/a.txt", ""));
}
