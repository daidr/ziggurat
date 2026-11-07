//! A minimal PNG encoder for icons made from pixels: 8-bit RGBA, rows
//! unfiltered, in a zlib stream of stored (uncompressed) blocks. Icons are
//! small, so the bytes stay small enough without compression.
const std = @import("std");

const signature = "\x89PNG\r\n\x1a\n";

/// A PNG of `width` by `height` straight-alpha RGBA pixels, row by row from
/// the top, `stride` bytes apart; the caller frees it.
pub fn encodeRgba(allocator: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, stride: usize) ![]u8 {
    return encode(allocator, rgba, width, height, stride, .rgba);
}

/// A PNG of top-down premultiplied BGRA8 pixels, as drawing images and
/// prepared SVG images hold them; the caller frees it.
pub fn encodePremultipliedBgra(allocator: std.mem.Allocator, bgra: []const u8, width: u32, height: u32, stride: usize) ![]u8 {
    return encode(allocator, bgra, width, height, stride, .premultiplied_bgra);
}

const Layout = enum { rgba, premultiplied_bgra };

fn encode(allocator: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, stride: usize, layout: Layout) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidImage;
    const row_bytes = @as(usize, width) * 4;
    if (stride < row_bytes or pixels.len < stride * (height - 1) + row_bytes) return error.InvalidImage;
    const raw_len = (row_bytes + 1) * height;
    const blocks = (raw_len + 65534) / 65535;
    const zlib_len = 2 + blocks * 5 + raw_len + 4;
    const total = signature.len + (12 + 13) + (12 + zlib_len) + 12;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var at: usize = 0;
    @memcpy(out[0..signature.len], signature);
    at += signature.len;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    at = chunk(out, at, "IHDR", &ihdr);

    // IDAT: its length, then the stream written in place.
    std.mem.writeInt(u32, out[at..][0..4], @intCast(zlib_len), .big);
    const kind_at = at + 4;
    @memcpy(out[kind_at..][0..4], "IDAT");
    var z = kind_at + 4;
    out[z] = 0x78;
    out[z + 1] = 0x01;
    z += 2;
    var adler: std.hash.Adler32 = .{};
    var left = raw_len;
    var block_left: usize = 0;
    var row: usize = 0;
    var column: usize = 0; // bytes of the row written, the filter byte first
    while (left > 0) {
        if (block_left == 0) {
            const n: u16 = @intCast(@min(left, 65535));
            out[z] = @intFromBool(n == left);
            std.mem.writeInt(u16, out[z + 1 ..][0..2], n, .little);
            std.mem.writeInt(u16, out[z + 3 ..][0..2], ~n, .little);
            z += 5;
            block_left = n;
        }
        // One byte at a time keeps blocks and rows independent.
        var byte: u8 = 0;
        if (column != 0) {
            const offset = column - 1;
            const pixel = pixels[row * stride + offset - offset % 4 ..][0..4];
            byte = switch (layout) {
                .rgba => pixel[offset % 4],
                .premultiplied_bgra => straight(pixel, offset % 4),
            };
        }
        out[z] = byte;
        adler.update(out[z..][0..1]);
        z += 1;
        block_left -= 1;
        left -= 1;
        column += 1;
        if (column == row_bytes + 1) {
            column = 0;
            row += 1;
        }
    }
    std.mem.writeInt(u32, out[z..][0..4], adler.adler, .big);
    z += 4;
    std.mem.writeInt(u32, out[z..][0..4], std.hash.Crc32.hash(out[kind_at..z]), .big);
    at = z + 4;
    at = chunk(out, at, "IEND", "");
    std.debug.assert(at == total);
    return out;
}

/// Channel `index` (R, G, B, A) of a premultiplied BGRA pixel, unpremultiplied.
fn straight(pixel: *const [4]u8, index: usize) u8 {
    const alpha = pixel[3];
    if (index == 3) return alpha;
    if (alpha == 0) return 0;
    const value: u32 = pixel[2 - index];
    return @intCast(@min(255, (value * 255 + alpha / 2) / alpha));
}

fn chunk(out: []u8, at: usize, kind: *const [4]u8, body: []const u8) usize {
    std.mem.writeInt(u32, out[at..][0..4], @intCast(body.len), .big);
    @memcpy(out[at + 4 ..][0..4], kind);
    @memcpy(out[at + 8 ..][0..body.len], body);
    const end = at + 8 + body.len;
    std.mem.writeInt(u32, out[end..][0..4], std.hash.Crc32.hash(out[at + 4 .. end]), .big);
    return end + 4;
}

test "pixels encode as a PNG whose stream inflates back to its rows" {
    const allocator = std.testing.allocator;
    // Two by two, premultiplied BGRA: opaque red, half-transparent green,
    // clear, opaque white.
    const bgra = [_]u8{ 0, 0, 255, 255, 0, 64, 0, 128, 0, 0, 0, 0, 255, 255, 255, 255 };
    const png = try encodePremultipliedBgra(allocator, &bgra, 2, 2, 8);
    defer allocator.free(png);
    try std.testing.expectEqualStrings(signature, png[0..8]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", png[37..41]);
    const stream = png[41..][0..idat_len];
    var in: std.Io.Reader = .fixed(stream);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var decompress: std.compress.flate.Decompress = .init(&in, .zlib, window);
    const rows = try decompress.reader.allocRemaining(allocator, .limited(64));
    defer allocator.free(rows);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255, 255 }, rows);
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 ..][0..4]);
    // A larger image spans several stored blocks.
    const big = try allocator.alloc(u8, 200 * 200 * 4);
    defer allocator.free(big);
    for (big, 0..) |*byte, index| byte.* = @truncate(index);
    const large = try encodeRgba(allocator, big, 200, 200, 800);
    defer allocator.free(large);
    var in2: std.Io.Reader = .fixed(large[41..][0..std.mem.readInt(u32, large[33..37], .big)]);
    var decompress2: std.compress.flate.Decompress = .init(&in2, .zlib, window);
    const rows2 = try decompress2.reader.allocRemaining(allocator, .limited(1 << 20));
    defer allocator.free(rows2);
    try std.testing.expectEqual(@as(usize, 801 * 200), rows2.len);
    try std.testing.expectEqualSlices(u8, big[800..1600], rows2[802..1602]);
}
