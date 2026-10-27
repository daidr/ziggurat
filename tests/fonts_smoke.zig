//! Registers a copy of a system font under a name of the application's own
//! and checks that the family list and text layout know it by that name.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const fonts = @import("ziggurat_fonts");
const text = @import("ziggurat_text_layout");

const alias = "Ziggurat Smoke Sans";

fn findFont(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        const windir = try zio.getEnvVarOwned(allocator, "WINDIR");
        defer allocator.free(windir);
        return std.fs.path.join(allocator, &.{ windir, "Fonts", "arial.ttf" });
    }
    for ([_][]const u8{ "/usr/share/fonts", "/usr/local/share/fonts" }) |root| {
        var dir = std.Io.Dir.openDirAbsolute(zio.io(), root, .{ .iterate = true }) catch continue;
        defer dir.close(zio.io());
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(zio.io())) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".ttf")) return std.fs.path.join(allocator, &.{ root, entry.path });
        }
    }
    return error.NoSystemFont;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const path = try findFont(allocator);
    defer allocator.free(path);
    const data = try std.Io.Dir.cwd().readFileAlloc(zio.io(), path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(data);

    const id = try fonts.register(allocator, data, alias);
    try std.testing.expectEqualStrings(alias, fonts.name(id));
    const own = fonts.systemName(id);
    try std.testing.expect(own.len > 0 and !std.mem.eql(u8, own, alias));
    try std.testing.expectEqualStrings(own, fonts.resolve(alias));
    // The same data again adds nothing but its name.
    const generation = fonts.generation();
    try std.testing.expectEqual(id, try fonts.register(allocator, data, alias));
    try std.testing.expectEqual(generation, fonts.generation());

    const list = try fonts.families(allocator);
    defer fonts.freeFamilies(allocator, list);
    try std.testing.expect(list.len > 1);
    try std.testing.expect(list[0].registered and std.mem.eql(u8, list[0].name, alias));
    for (list[1..]) |item| {
        try std.testing.expect(!item.registered);
        try std.testing.expect(!std.ascii.eqlIgnoreCase(item.name, own));
    }

    // Text laid out in the registered name measures as in the font's own.
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const sample = "Registered fonts lay out by name";
    const by_alias = try engine.layout(sample, .{ .family = alias, .size = 20 });
    defer by_alias.close() catch unreachable;
    const by_own = try engine.layout(sample, .{ .family = own, .size = 20 });
    defer by_own.close() catch unreachable;
    try std.testing.expectEqual((try by_own.metrics()).bounds.width, (try by_alias.metrics()).bounds.width);
    std.debug.print("fonts smoke: registered {s} as {s}; {d} families\n", .{ own, alias, list.len });
}
