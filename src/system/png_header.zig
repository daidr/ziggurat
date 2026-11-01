//! The size of a PNG image, read from its header without decoding it.
const std = @import("std");

/// Larger images are rejected before they are decoded.
pub const max_size = 1024;
pub const Size = struct { width: u32, height: u32 };

/// Reads the size of a PNG stream from its header, without decoding it.
pub fn pngSize(png: []const u8) !Size {
    if (png.len < 33 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, png[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, png[16..20], .big);
    const height = std.mem.readInt(u32, png[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPng;
    if (width > max_size or height > max_size) return error.IconTooLarge;
    return .{ .width = width, .height = height };
}

test "png sizes come from the header and are bounded" {
    var png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x20\x00\x00\x00\x10\x08\x06\x00\x00\x00\x00\x00\x00\x00".*;
    try std.testing.expectEqual(Size{ .width = 32, .height = 16 }, try pngSize(&png));
    png[18] = 0x10;
    try std.testing.expectError(error.IconTooLarge, pngSize(&png));
    png[18] = 0;
    png[19] = 0;
    try std.testing.expectError(error.InvalidPng, pngSize(&png));
    try std.testing.expectError(error.InvalidPng, pngSize("GIF89a"));
}
