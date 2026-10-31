const std = @import("std");
const zio = @import("ziggurat_io");
const root = @import("root.zig");
const files = @import("files.zig");

const HANDLE = ?*anyopaque;
extern "gdi32" fn AddFontMemResourceEx(data: *const anyopaque, size: u32, reserved: ?*anyopaque, fonts: *u32) callconv(.winapi) HANDLE;
extern fn zfont_add_file(path: [*:0]const u16) c_int;
extern fn zfont_list(context: *anyopaque, each: *const fn (*anyopaque, [*]const u16, u32, c_int) callconv(.c) void) c_int;

pub fn add(allocator: std.mem.Allocator, data: []const u8, hash: *const [16]u8) !void {
    const local = zio.getEnvVarOwned(allocator, "LOCALAPPDATA") catch try zio.getEnvVarOwned(allocator, "TEMP");
    defer allocator.free(local);
    const path = try files.write(allocator, local, data, hash);
    defer allocator.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    // GDI keeps the fonts of the data for the process; DirectWrite reads
    // the file.
    var installed: u32 = 0;
    if (AddFontMemResourceEx(data.ptr, @intCast(data.len), null, &installed) == null) return error.UnreadableFont;
    if (zfont_add_file(wide) != 0) return error.TooManyFamilies;
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
    fn each(context: *anyopaque, name: [*]const u16, length: u32, monospaced: c_int) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        const utf8 = std.unicode.utf16LeToUtf8Alloc(self.allocator, name[0..length]) catch {
            self.failed = true;
            return;
        };
        defer self.allocator.free(utf8);
        const start = self.names.items.len;
        self.names.appendSlice(self.allocator, utf8) catch {
            self.failed = true;
            return;
        };
        self.spans.append(self.allocator, .{ .start = start, .len = utf8.len, .monospaced = monospaced != 0 }) catch {
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
