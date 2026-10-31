//! The file a registered font is read from: `<cache>/ziggurat/fonts/<hash>.font`,
//! written once, through a temporary file renamed into place.
const std = @import("std");
const zio = @import("ziggurat_io");

pub fn write(allocator: std.mem.Allocator, cache: []const u8, data: []const u8, hash: *const [16]u8) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ cache, "ziggurat", "fonts" });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(zio.io(), dir);
    const hex = std.fmt.bytesToHex(hash.*, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.font", .{ dir, std.fs.path.sep, &hex });
    errdefer allocator.free(path);
    if (std.Io.Dir.cwd().access(zio.io(), path, .{})) |_| return path else |_| {}
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = temporary, .data = data });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, zio.io());
    return path;
}
