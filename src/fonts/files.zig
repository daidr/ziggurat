//! The file a registered font is read from: `<cache>/ziggurat/fonts/<hash>.font`,
//! written once, through a temporary file renamed into place.
const std = @import("std");

pub fn write(allocator: std.mem.Allocator, cache: []const u8, data: []const u8, hash: *const [16]u8) ![]u8 {
    const dir = try std.fs.path.join(allocator, &.{ cache, "ziggurat", "fonts" });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const hex = std.fmt.bytesToHex(hash.*, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.font", .{ dir, std.fs.path.sep, &hex });
    errdefer allocator.free(path);
    if (std.fs.cwd().access(path, .{})) |_| return path else |_| {}
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    try std.fs.cwd().writeFile(.{ .sub_path = temporary, .data = data });
    try std.fs.cwd().rename(temporary, path);
    return path;
}
