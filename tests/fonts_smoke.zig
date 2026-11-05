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

extern fn FcFreeTypeQuery(file: [*:0]const u8, id: c_int, blanks: ?*anyopaque, count: *c_int) ?*anyopaque;
extern fn FcPatternGetString(pattern: *anyopaque, object: [*:0]const u8, n: c_int, out: *?[*:0]const u8) c_int;
extern fn FcPatternDestroy(pattern: *anyopaque) void;
extern fn FcPatternGetInteger(pattern: *anyopaque, object: [*:0]const u8, n: c_int, out: *c_int) c_int;
extern fn FcWeightToOpenType(weight: c_int) c_int;

/// The weight and slant of the font file's first face.
const Face = struct { weight: u32 = 400, italic: bool = false };
fn ownFace(allocator: std.mem.Allocator, path: []const u8) !Face {
    if (builtin.os.tag != .linux) return .{};
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    var faces: c_int = 0;
    const pattern = FcFreeTypeQuery(terminated, 0, null, &faces) orelse return error.UnreadableFont;
    defer FcPatternDestroy(pattern);
    var weight: c_int = 80;
    var slant: c_int = 0;
    _ = FcPatternGetInteger(pattern, "weight", 0, &weight);
    _ = FcPatternGetInteger(pattern, "slant", 0, &slant);
    return .{ .weight = @intCast(FcWeightToOpenType(weight)), .italic = slant != 0 };
}

/// The family the font file names itself, as fontconfig reads it.
fn ownFamily(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const terminated = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(terminated);
    var faces: c_int = 0;
    const pattern = FcFreeTypeQuery(terminated, 0, null, &faces) orelse return error.UnreadableFont;
    defer FcPatternDestroy(pattern);
    var family: ?[*:0]const u8 = null;
    if (FcPatternGetString(pattern, "family", 0, &family) != 0 or family == null) return error.UnreadableFont;
    return allocator.dupe(u8, std.mem.span(family.?));
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
    // Linux holds the faces under the name given, apart from the font's
    // own family; Windows gives the system the font's own.
    const own = if (builtin.os.tag == .linux) try ownFamily(allocator, path) else fonts.systemName(id);
    defer if (builtin.os.tag == .linux) allocator.free(own);
    try std.testing.expect(own.len > 0 and !std.mem.eql(u8, own, alias));
    const system_name = if (builtin.os.tag == .linux) alias else own;
    try std.testing.expectEqualStrings(system_name, fonts.systemName(id));
    try std.testing.expectEqualStrings(system_name, fonts.resolve(alias));
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

    // Text laid out in the registered name measures as in the font's own,
    // in the face registered: on Linux the name holds that face alone, so
    // it takes it whatever weight and style are asked for.
    const face = try ownFace(allocator, path);
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const sample = "Registered fonts lay out by name";
    const by_alias = try engine.layout(sample, .{ .family = alias, .size = 20 });
    defer by_alias.close() catch unreachable;
    const by_own = try engine.layout(sample, .{ .family = own, .size = 20, .weight = face.weight, .italic = face.italic });
    defer by_own.close() catch unreachable;
    try std.testing.expectEqual((try by_own.metrics()).bounds.width, (try by_alias.metrics()).bounds.width);
    if (builtin.os.tag == .linux) {
        // The name given takes only this file's faces: another name for the
        // same data holds them too, and the font's own family keeps them.
        const second = try fonts.register(allocator, data, "Ziggurat Smoke Other");
        try std.testing.expectEqualStrings("Ziggurat Smoke Other", fonts.systemName(second));
        const by_other = try engine.layout(sample, .{ .family = "Ziggurat Smoke Other", .size = 20 });
        defer by_other.close() catch unreachable;
        try std.testing.expectEqual((try by_own.metrics()).bounds.width, (try by_other.metrics()).bounds.width);
    }
    std.debug.print("fonts smoke: registered {s} as {s}; {d} families\n", .{ own, alias, list.len });
}
