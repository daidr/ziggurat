const std = @import("std");
const builtin = @import("builtin");
const zio = @import("ziggurat_io");
const root = @import("root.zig");
const files = @import("files.zig");

extern fn zfont_add_file(path: [*:0]const u8) c_int;
extern fn zfont_add_family(path: [*:0]const u8, family: [*:0]const u8) c_int;
extern fn zfont_list(context: *anyopaque, each: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) void) c_int;

/// The user's cache directory: macOS's, or as the XDG base directories name it.
fn cacheDir(buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .macos) {
        if (zio.getenv("HOME")) |home| if (home.len > 0) return std.fmt.bufPrint(buffer, "{s}/Library/Caches", .{home});
        return "/tmp";
    }
    if (zio.getenv("XDG_CACHE_HOME")) |dir| if (dir.len > 0) return dir;
    if (zio.getenv("HOME")) |home| if (home.len > 0) return std.fmt.bufPrint(buffer, "{s}/.cache", .{home});
    return "/tmp";
}

pub fn add(allocator: std.mem.Allocator, data: []const u8, hash: *const [16]u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try files.write(allocator, try cacheDir(&buffer), data, hash);
    defer allocator.free(path);
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    if (zfont_add_file(terminated) != 0) return error.UnreadableFont;
}

/// Linux: adds the font's faces again under `family` alone (fontconfig),
/// apart from its own family's.
pub fn addFamily(allocator: std.mem.Allocator, data: []const u8, hash: *const [16]u8, family: [:0]const u8) !void {
    if (comptime builtin.os.tag != .linux) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try files.write(allocator, try cacheDir(&buffer), data, hash);
    defer allocator.free(path);
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    if (zfont_add_family(terminated, family) != 0) return error.UnreadableFont;
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

extern fn zfont_test_rgba(gray: c_int, text: [*:0]const u8, color: *c_int) c_int;
extern fn zfont_test_load_rule(xml: [*:0]const u8) c_int;

test "text drawn in gray asks fonts for no subpixel order, which fontconfig gives them, and keeps color emoji" {
    if (builtin.os.tag != .linux) return;
    // Where fontconfig gives every font subpixel antialiasing, as a rule of
    // target "font" does, and old cairo would draw ordinary glyphs as color
    // glyphs in the subpixels' colors.
    const rgb_rule = "<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig><match target=\"font\"><edit name=\"rgba\" mode=\"assign\"><const>rgb</const></edit></match></fontconfig>";
    try std.testing.expectEqual(0, zfont_test_load_rule(rgb_rule));
    const fc_rgba_rgb = 1;
    const fc_rgba_none = 5;
    var color: c_int = 0;
    // A plain font map keeps the subpixel order, for subpixel text.
    const plain = zfont_test_rgba(0, "Candle", &color);
    if (plain < 0) return error.SkipZigTest; // no fonts
    try std.testing.expectEqual(fc_rgba_rgb, plain);
    for ([_][*:0]const u8{ "Candle", "显示右侧边栏" }) |text| {
        try std.testing.expectEqual(fc_rgba_none, zfont_test_rgba(1, text, &color));
        try std.testing.expectEqual(0, color);
    }
    // A color emoji font still has its color glyphs.
    const emoji = zfont_test_rgba(1, "\u{1f600}", &color);
    if (emoji >= 0 and color == 1) try std.testing.expectEqual(fc_rgba_none, emoji);
}
