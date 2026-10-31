//! Encodes a captured window as PNG: 8-bit RGBA, one zlib stream.
const std = @import("std");
const flate = std.compress.flate;

/// `pixels` are premultiplied BGRA rows from the top, as `Window.capture`
/// gives them; the image is straight RGBA.
pub fn encode(arena: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) error{OutOfMemory}![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, pixels.len / 4 + 1024);
    write(&out.writer, arena, width, height, pixels) catch return error.OutOfMemory;
    return out.written();
}

fn write(w: *std.Io.Writer, arena: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) !void {
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &header);

    // Each row is its filter byte, 0, then its pixels.
    var data: std.Io.Writer.Allocating = try .initCapacity(arena, pixels.len / 4 + 1024);
    const window = try arena.alloc(u8, flate.max_window_len);
    const compress = try arena.create(flate.Compress);
    compress.* = try .init(&data.writer, window, .zlib, .fastest);
    const row_bytes = @as(usize, width) * 4;
    const row = try arena.alloc(u8, row_bytes + 1);
    for (0..height) |y| {
        row[0] = 0;
        const source = pixels[y * row_bytes ..][0..row_bytes];
        for (0..width) |x| {
            const bgra = source[x * 4 ..][0..4];
            const alpha: u32 = bgra[3];
            const rgba = row[1 + x * 4 ..][0..4];
            rgba.* = if (alpha == 0) .{ 0, 0, 0, 0 } else .{ unpremultiply(bgra[2], alpha), unpremultiply(bgra[1], alpha), unpremultiply(bgra[0], alpha), @intCast(alpha) };
        }
        try compress.writer.writeAll(row);
    }
    try compress.finish();
    try chunk(w, "IDAT", data.written());
    try chunk(w, "IEND", "");
}

fn unpremultiply(channel: u8, alpha: u32) u8 {
    return @intCast(@min(255, (@as(u32, channel) * 255 + alpha / 2) / alpha));
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "a captured image round-trips through the PNG it encodes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Opaque red, half-transparent green (premultiplied), transparent.
    const pixels = [_]u8{ 0, 0, 255, 255, 0, 128, 0, 128, 0, 0, 0, 0, 255, 0, 0, 255 };
    const encoded = try encode(arena, 2, 2, &pixels);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", encoded[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[16..20], .big));
    // The IDAT chunk decompresses to the filtered rows.
    const idat_len = std.mem.readInt(u32, encoded[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", encoded[37..41]);
    var input: std.Io.Reader = .fixed(encoded[41..][0..idat_len]);
    var buffer: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &buffer);
    var rows: [18]u8 = undefined;
    try decompress.reader.readSliceAll(&rows);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 0, 0, 0, 0, 0, 255, 255 }, &rows);
}
