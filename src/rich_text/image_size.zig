//! The pixel size of an encoded image, from its header, for images that
//! pasted text carries: PNG, GIF, JPEG and BMP.
const std = @import("std");

/// How many pixels a pasted picture may have, so that a small file that
/// claims a huge size takes no gigabytes to decode.
pub const max_pixels = 1 << 25;

pub const Size = struct { width: f32, height: f32 };

/// The size of an image small enough to decode, or null.
pub fn of(data: []const u8) ?Size {
    const size = header(data) orelse return null;
    if (size.width == 0 or size.height == 0 or @as(u64, size.width) * size.height > max_pixels) return null;
    return .{ .width = @floatFromInt(size.width), .height = @floatFromInt(size.height) };
}

const Pixels = struct { width: u32, height: u32 };

fn header(d: []const u8) ?Pixels {
    if (d.len >= 24 and std.mem.eql(u8, d[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, d[12..16], "IHDR"))
        return .{ .width = std.mem.readInt(u32, d[16..20], .big), .height = std.mem.readInt(u32, d[20..24], .big) };
    if (d.len >= 10 and (std.mem.eql(u8, d[0..6], "GIF87a") or std.mem.eql(u8, d[0..6], "GIF89a")))
        return .{ .width = std.mem.readInt(u16, d[6..8], .little), .height = std.mem.readInt(u16, d[8..10], .little) };
    if (d.len >= 26 and d[0] == 'B' and d[1] == 'M') {
        const w = std.mem.readInt(i32, d[18..22], .little);
        const h = std.mem.readInt(i32, d[22..26], .little);
        return .{ .width = @abs(w), .height = @abs(h) };
    }
    if (d.len >= 4 and d[0] == 0xff and d[1] == 0xd8) return jpeg(d);
    return null;
}

/// The size in a JPEG's start of frame.
fn jpeg(d: []const u8) ?Pixels {
    var at: usize = 2;
    while (at + 4 <= d.len) {
        if (d[at] != 0xff) return null;
        const marker = d[at + 1];
        if (marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01 or marker == 0xff) {
            at += if (marker == 0xff) 1 else 2;
            continue;
        }
        const length = std.mem.readInt(u16, d[at + 2 ..][0..2], .big);
        const sof = (marker >= 0xc0 and marker <= 0xcf) and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (sof) {
            if (at + 9 > d.len) return null;
            return .{ .height = std.mem.readInt(u16, d[at + 5 ..][0..2], .big), .width = std.mem.readInt(u16, d[at + 7 ..][0..2], .big) };
        }
        at += 2 + length;
    }
    return null;
}

test "sizes of headers" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x02\x00\x00\x00\x03";
    try std.testing.expectEqual(Size{ .width = 2, .height = 3 }, of(png).?);
    try std.testing.expectEqual(Size{ .width = 5, .height = 1 }, of("GIF89a\x05\x00\x01\x00").?);
    try std.testing.expect(of("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x7f\xff\xff\xff\x7f\xff\xff\xff") == null);
    try std.testing.expect(of("not an image") == null);
}
