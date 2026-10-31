//! Device independent bitmaps, the clipboard's own image format on Windows,
//! as PNG streams. Pure byte conversion, the same on every platform.
const std = @import("std");

/// Output larger than this is rejected, as the clipboard's entries are.
pub const max_pixels_bytes = 64 * 1024 * 1024;
const stored_block = 65535;

const Layout = struct {
    width: u32,
    height: u32,
    bits: u16,
    offset: usize,
    stride: usize,
    bottom_up: bool,
    alpha: bool,

    fn raw(self: Layout) usize {
        return @as(usize, self.height) * (1 + 4 * @as(usize, self.width));
    }
    fn idat(self: Layout) usize {
        const raw_len = self.raw();
        const blocks = (raw_len + stored_block - 1) / stored_block;
        return 2 + raw_len + 5 * blocks + 4;
    }
    fn png(self: Layout) usize {
        return 8 + (12 + 13) + (12 + self.idat()) + 12;
    }
};

/// Uncompressed 24 and 32-bit bitmaps, top-down or bottom-up, with a
/// BITMAPINFOHEADER or a later header. The alpha channel counts only with a
/// later header; older 32-bit bitmaps leave the fourth byte undefined.
fn layout(dib: []const u8) !Layout {
    if (dib.len < 40) return error.ClipboardMalformed;
    const header = std.mem.readInt(u32, dib[0..4], .little);
    const width = std.mem.readInt(i32, dib[4..8], .little);
    const height = std.mem.readInt(i32, dib[8..12], .little);
    const bits = std.mem.readInt(u16, dib[14..16], .little);
    const compression = std.mem.readInt(u32, dib[16..20], .little);
    if (width <= 0 or height == 0 or height == std.math.minInt(i32) or (bits != 24 and bits != 32) or (compression != 0 and compression != 3)) return error.ClipboardMalformed;
    if (header < 40 or header > dib.len) return error.ClipboardMalformed;
    var offset: usize = header;
    // BI_BITFIELDS masks follow a BITMAPINFOHEADER.
    if (compression == 3 and header == 40) offset += 12;
    const w: u32 = @intCast(width);
    const h: u32 = @abs(height);
    if (w > max_pixels_bytes / 4 or h > max_pixels_bytes / (4 * @as(usize, w))) return error.ClipboardMalformed;
    const stride = ((@as(usize, w) * bits + 31) / 32) * 4;
    if (offset > dib.len or h > (dib.len - offset) / stride) return error.ClipboardMalformed;
    return .{ .width = w, .height = h, .bits = bits, .offset = offset, .stride = stride, .bottom_up = height > 0, .alpha = bits == 32 and header > 40 };
}

/// The exact size of the PNG stream `dibToPng` writes.
pub fn pngLength(dib: []const u8) !usize {
    return (try layout(dib)).png();
}

/// Writes the bitmap as an 8-bit RGBA PNG stream of stored (uncompressed)
/// deflate blocks, at the start of `destination`.
pub fn dibToPng(dib: []const u8, destination: []u8) ![]u8 {
    const info = try layout(dib);
    const total = info.png();
    if (destination.len < total) return error.CapacityExceeded;
    var writer = std.Io.Writer.fixed(destination);
    writer.writeAll("\x89PNG\r\n\x1a\n") catch unreachable;
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], info.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], info.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA, deflate, adaptive, no interlace
    chunk(&writer, "IHDR", &ihdr);

    const idat_len = info.idat();
    writer.writeInt(u32, @intCast(idat_len), .big) catch unreachable;
    const crc_start = writer.end;
    writer.writeAll("IDAT") catch unreachable;
    writer.writeAll(&.{ 0x78, 0x01 }) catch unreachable;
    var adler: std.hash.Adler32 = .{};
    var left = info.raw();
    var in_block: usize = 0;
    for (0..info.height) |y| {
        const row = if (info.bottom_up) info.height - 1 - y else y;
        const line = dib[info.offset + row * info.stride ..];
        var pixel: [4]u8 = undefined;
        // A filter byte, then the row's pixels.
        for (0..1 + @as(usize, info.width)) |x| {
            const bytes: []const u8 = if (x == 0) &.{0} else blk: {
                const p = line[(x - 1) * (info.bits / 8) ..];
                pixel = .{ p[2], p[1], p[0], if (info.alpha) p[3] else 255 };
                break :blk &pixel;
            };
            for (bytes) |byte| {
                if (in_block == 0) {
                    const size: u16 = @intCast(@min(left, stored_block));
                    writer.writeByte(if (left <= stored_block) 1 else 0) catch unreachable;
                    writer.writeInt(u16, size, .little) catch unreachable;
                    writer.writeInt(u16, ~size, .little) catch unreachable;
                    in_block = size;
                }
                writer.writeByte(byte) catch unreachable;
                in_block -= 1;
                left -= 1;
            }
            adler.update(bytes);
        }
    }
    writer.writeInt(u32, adler.adler, .big) catch unreachable;
    writer.writeInt(u32, std.hash.Crc32.hash(destination[crc_start..writer.end]), .big) catch unreachable;
    chunk(&writer, "IEND", "");
    std.debug.assert(writer.end == total);
    return destination[0..total];
}

fn chunk(writer: *std.Io.Writer, comptime kind: *const [4]u8, data: []const u8) void {
    writer.writeInt(u32, @intCast(data.len), .big) catch unreachable;
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    writer.writeAll(kind) catch unreachable;
    writer.writeAll(data) catch unreachable;
    writer.writeInt(u32, crc.final(), .big) catch unreachable;
}

fn testHeader(buffer: []u8, size: u32, width: i32, height: i32, bits: u16) void {
    @memset(buffer[0..size], 0);
    std.mem.writeInt(u32, buffer[0..4], size, .little);
    std.mem.writeInt(i32, buffer[4..8], width, .little);
    std.mem.writeInt(i32, buffer[8..12], height, .little);
    std.mem.writeInt(u16, buffer[12..14], 1, .little);
    std.mem.writeInt(u16, buffer[14..16], bits, .little);
}

test "bitmaps become RGBA PNG streams that a decoder reads back" {
    // A bottom-up 2x2 32-bit bitmap with a V5 header: alpha counts.
    var dib: [124 + 16]u8 = undefined;
    testHeader(&dib, 124, 2, 2, 32);
    // Bottom row first: blue, white; then the top row: red, half green.
    @memcpy(dib[124..], &[_]u8{ 255, 0, 0, 255, 255, 255, 255, 255, 0, 0, 255, 255, 0, 255, 0, 128 });
    var out: [256]u8 = undefined;
    const png = try dibToPng(&dib, &out);
    try std.testing.expectEqual(try pngLength(&dib), png.len);
    try std.testing.expectError(error.CapacityExceeded, dibToPng(&dib, out[0 .. png.len - 1]));
    // IDAT holds a zlib stream of filter bytes and top-down RGBA rows.
    const idat = png[8 + 25 + 8 ..][0..std.mem.readInt(u32, png[8 + 25 ..][0..4], .big)];
    var input: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    var raw: [18]u8 = undefined;
    try inflate.reader.readSliceAll(&raw);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 0, 255, 255, 255, 255, 255, 255 }, &raw);
    try std.testing.expectEqualStrings("IEND", png[png.len - 8 .. png.len - 4]);
}

test "older 32-bit headers are opaque and 24-bit rows are padded" {
    var dib: [40 + 8]u8 = undefined;
    testHeader(&dib, 40, 2, -1, 24); // top-down, 6 bytes padded to 8
    @memcpy(dib[40..], &[_]u8{ 1, 2, 3, 4, 5, 6, 0xee, 0xee });
    var out: [128]u8 = undefined;
    const png = try dibToPng(&dib, &out);
    const idat = png[8 + 25 + 8 ..][0..std.mem.readInt(u32, png[8 + 25 ..][0..4], .big)];
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 2, 1, 255, 6, 5, 4, 255 }, idat[2 + 5 ..][0..9]);
    var opaque_dib: [40 + 4]u8 = undefined;
    testHeader(&opaque_dib, 40, 1, 1, 32);
    @memcpy(opaque_dib[40..], &[_]u8{ 9, 8, 7, 0 });
    const second = try dibToPng(&opaque_dib, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 7, 8, 9, 255 }, second[8 + 25 + 8 + 2 + 5 ..][0..5]);
}

test "bitmap geometry is untrusted" {
    var dib: [40 + 4]u8 = undefined;
    testHeader(&dib, 40, 1, 1, 32);
    try std.testing.expect(try pngLength(&dib) > 0);
    std.mem.writeInt(i32, dib[8..12], std.math.minInt(i32), .little);
    try std.testing.expectError(error.ClipboardMalformed, pngLength(&dib));
    std.mem.writeInt(i32, dib[8..12], 2, .little); // rows beyond the data
    try std.testing.expectError(error.ClipboardMalformed, pngLength(&dib));
    std.mem.writeInt(i32, dib[8..12], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 8, .little); // palettes are not read
    try std.testing.expectError(error.ClipboardMalformed, pngLength(&dib));
    try std.testing.expectError(error.ClipboardMalformed, pngLength(dib[0..39]));
}

test "large bitmaps split into stored blocks" {
    const width = 200;
    const height = 100; // 80100 raw bytes: two blocks
    var dib: [40 + width * height * 4]u8 = undefined;
    testHeader(&dib, 40, width, height, 32);
    for (dib[40..], 0..) |*byte, index| byte.* = @truncate(index);
    var out: [90000]u8 = undefined;
    const png = try dibToPng(&dib, &out);
    const idat = png[8 + 25 + 8 ..][0..std.mem.readInt(u32, png[8 + 25 ..][0..4], .big)];
    var input: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    var raw: [height * (1 + width * 4)]u8 = undefined;
    try inflate.reader.readSliceAll(&raw);
    // The first raw row is the bitmap's last: bottom-up.
    try std.testing.expectEqual(@as(u8, @truncate(40 + (height - 1) * width * 4 + 2 - 40)), raw[1]);
}
