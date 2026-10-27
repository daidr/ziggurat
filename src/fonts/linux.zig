const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const files = @import("files.zig");

extern fn zfont_add_file(path: [*:0]const u8) c_int;
extern fn zfont_list(context: *anyopaque, each: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) void) c_int;

/// The user's cache directory: macOS's, or as the XDG base directories name it.
fn cacheDir(buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .macos) {
        if (std.posix.getenv("HOME")) |home| if (home.len > 0) return std.fmt.bufPrint(buffer, "{s}/Library/Caches", .{home});
        return "/tmp";
    }
    if (std.posix.getenv("XDG_CACHE_HOME")) |dir| if (dir.len > 0) return dir;
    if (std.posix.getenv("HOME")) |home| if (home.len > 0) return std.fmt.bufPrint(buffer, "{s}/.cache", .{home});
    return "/tmp";
}

pub fn add(allocator: std.mem.Allocator, data: []const u8, hash: *const [16]u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try files.write(allocator, try cacheDir(&buffer), data, hash);
    defer allocator.free(path);
    const terminated = try allocator.dupeZ(u8, path);
    defer allocator.free(terminated);
    if (zfont_add_file(terminated) != 0) return error.UnreadableFont;
}

pub const List = struct {
    items: []root.SystemFamily = &.{},
    names: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(root.SystemFamily) = .empty,
    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(struct { start: usize, len: usize, monospaced: bool }) = .empty,
    failed: bool = false,
    fn each(context: *anyopaque, name: [*:0]const u8, monospaced: c_int) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        const bytes = std.mem.span(name);
        const start = self.names.items.len;
        self.names.appendSlice(self.allocator, bytes) catch {
            self.failed = true;
            return;
        };
        self.spans.append(self.allocator, .{ .start = start, .len = bytes.len, .monospaced = monospaced != 0 }) catch {
            self.failed = true;
        };
    }
};

pub fn systemFamilies(allocator: std.mem.Allocator) !List {
    var collector: Collector = .{ .allocator = allocator };
    defer collector.spans.deinit(allocator);
    errdefer collector.names.deinit(allocator);
    if (zfont_list(&collector, Collector.each) != 0) return error.FontListUnavailable;
    if (collector.failed) return error.OutOfMemory;
    var list: List = .{ .names = collector.names };
    errdefer list.entries.deinit(allocator);
    for (collector.spans.items) |span| try list.entries.append(allocator, .{ .name = list.names.items[span.start..][0..span.len], .monospaced = span.monospaced });
    list.items = list.entries.items;
    return list;
}
