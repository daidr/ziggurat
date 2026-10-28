//! Application icons from one square PNG: the Windows .ico the resource
//! compiler embeds, with a PNG image at each of `windows_sizes`, and the
//! scaling behind it.
const std = @import("std");
const png = @import("png.zig");

/// The sizes of a Windows icon, in pixels.
pub const windows_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256 };

/// An icon must be a square PNG.
pub fn validate(source: []const u8) !void {
    const header = png.readHeader(source) catch return error.IconNotPng;
    if (header.width != header.height) return error.IconNotSquare;
}

/// Scale `image` to a `size` x `size` square: area averaging when
/// shrinking, bilinear sampling when enlarging, over premultiplied colors
/// so transparent pixels do not darken edges.
pub fn resize(allocator: std.mem.Allocator, image: png.Image, size: u32) !png.Image {
    var out: png.Image = try .init(allocator, size, size);
    errdefer out.deinit(allocator);
    const w: i64 = image.width;
    const h: i64 = image.height;
    const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(size));
    const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(size));
    const Sample = struct { r: f64, g: f64, b: f64, a: f64 };
    const at = struct {
        fn get(img: png.Image, x: i64, y: i64) Sample {
            const cx: u32 = @intCast(std.math.clamp(x, 0, @as(i64, img.width) - 1));
            const cy: u32 = @intCast(std.math.clamp(y, 0, @as(i64, img.height) - 1));
            const p = img.at(cx, cy);
            const a: f64 = @floatFromInt(p[3]);
            return .{ .r = @as(f64, @floatFromInt(p[0])) * a, .g = @as(f64, @floatFromInt(p[1])) * a, .b = @as(f64, @floatFromInt(p[2])) * a, .a = a };
        }
    }.get;
    for (0..size) |yu| for (0..size) |xu| {
        const x: f64 = @floatFromInt(xu);
        const y: f64 = @floatFromInt(yu);
        var r: f64 = 0;
        var g: f64 = 0;
        var b: f64 = 0;
        var a: f64 = 0;
        var n: f64 = 0;
        if (sx >= 1) {
            const x0: i64 = @intFromFloat(x * sx);
            const x1: i64 = @max(@as(i64, @intFromFloat((x + 1) * sx)), x0 + 1);
            const y0: i64 = @intFromFloat(y * sy);
            const y1: i64 = @max(@as(i64, @intFromFloat((y + 1) * sy)), y0 + 1);
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    const s = at(image, xx, yy);
                    r += s.r;
                    g += s.g;
                    b += s.b;
                    a += s.a;
                    n += 1;
                }
            }
        } else {
            const fx = (x + 0.5) * sx - 0.5;
            const fy = (y + 0.5) * sy - 0.5;
            // Truncation toward zero, as the integer conversion of the
            // sampling position.
            const x0: i64 = @intFromFloat(fx);
            const y0: i64 = @intFromFloat(fy);
            const dx = fx - @as(f64, @floatFromInt(x0));
            const dy = fy - @as(f64, @floatFromInt(y0));
            const taps = [4]struct { x: i64, y: i64, wt: f64 }{
                .{ .x = x0, .y = y0, .wt = (1 - dx) * (1 - dy) },
                .{ .x = x0 + 1, .y = y0, .wt = dx * (1 - dy) },
                .{ .x = x0, .y = y0 + 1, .wt = (1 - dx) * dy },
                .{ .x = x0 + 1, .y = y0 + 1, .wt = dx * dy },
            };
            for (taps) |tap| {
                const s = at(image, tap.x, tap.y);
                r += s.r * tap.wt;
                g += s.g * tap.wt;
                b += s.b * tap.wt;
                a += s.a * tap.wt;
                n += tap.wt;
            }
        }
        if (a == 0) continue;
        out.pixels[(yu * size + xu) * 4 ..][0..4].* = .{ channel(r / a + 0.5), channel(g / a + 0.5), channel(b / a + 0.5), channel(a / n + 0.5) };
    };
    return out;
}

fn channel(value: f64) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 255));
}

/// The PNG images of `source` at each of `windows_sizes`.
pub fn windowsImages(allocator: std.mem.Allocator, source: []const u8) ![windows_sizes.len][]u8 {
    try validate(source);
    const image = try png.decode(allocator, source);
    defer image.deinit(allocator);
    var images: [windows_sizes.len][]u8 = undefined;
    var made: usize = 0;
    errdefer for (images[0..made]) |bytes| allocator.free(bytes);
    for (windows_sizes, 0..) |size, i| {
        const scaled = try resize(allocator, image, size);
        defer scaled.deinit(allocator);
        images[i] = try png.encode(allocator, scaled);
        made += 1;
    }
    return images;
}

/// A Windows .ico holding `source` at each of `windows_sizes` as PNG.
pub fn pngToIco(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const images = try windowsImages(allocator, source);
    defer for (images) |bytes| allocator.free(bytes);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little); // an icon
    try w.writeInt(u16, windows_sizes.len, .little);
    var offset: u32 = 6 + 16 * windows_sizes.len;
    for (windows_sizes, images) |size, bytes| {
        const dimension: u8 = if (size >= 256) 0 else @intCast(size);
        try w.writeAll(&.{ dimension, dimension, 0, 0 });
        try w.writeInt(u16, 1, .little); // planes
        try w.writeInt(u16, 32, .little); // bits per pixel
        try w.writeInt(u32, @intCast(bytes.len), .little);
        try w.writeInt(u32, offset, .little);
        offset += @intCast(bytes.len);
    }
    for (images) |bytes| try w.writeAll(bytes);
    return out.toOwnedSlice();
}

/// The icon types of a macOS .icns with the size of their PNG images.
pub const icns_entries = [_]struct { kind: *const [4]u8, size: u32 }{
    .{ .kind = "ic11", .size = 32 },  .{ .kind = "ic12", .size = 64 },
    .{ .kind = "ic07", .size = 128 }, .{ .kind = "ic13", .size = 256 },
    .{ .kind = "ic08", .size = 256 }, .{ .kind = "ic14", .size = 512 },
    .{ .kind = "ic09", .size = 512 }, .{ .kind = "ic10", .size = 1024 },
};

/// A macOS .icns holding `source` at each of `icns_entries` as PNG.
pub fn pngToIcns(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    try validate(source);
    const image = try png.decode(allocator, source);
    defer image.deinit(allocator);
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    for (icns_entries) |entry| {
        const scaled = try resize(allocator, image, entry.size);
        defer scaled.deinit(allocator);
        const bytes = try png.encode(allocator, scaled);
        defer allocator.free(bytes);
        try body.writer.writeAll(entry.kind);
        try body.writer.writeInt(u32, @intCast(bytes.len + 8), .big);
        try body.writer.writeAll(bytes);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("icns");
    try out.writer.writeInt(u32, @intCast(body.written().len + 8), .big);
    try out.writer.writeAll(body.written());
    return out.toOwnedSlice();
}

test "icons are square PNGs" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IconNotPng, validate("not a png"));
    var wide: png.Image = try .init(allocator, 4, 2);
    defer wide.deinit(allocator);
    const bytes = try png.encode(allocator, wide);
    defer allocator.free(bytes);
    try std.testing.expectError(error.IconNotSquare, validate(bytes));
}

test "shrinking averages areas and keeps transparent edges clean" {
    const allocator = std.testing.allocator;
    var image: png.Image = try .init(allocator, 4, 4);
    defer image.deinit(allocator);
    // Left half opaque red, right half fully transparent white.
    for (0..4) |y| for (0..4) |x| {
        image.pixels[(y * 4 + x) * 4 ..][0..4].* = if (x < 2) .{ 255, 0, 0, 255 } else .{ 255, 255, 255, 0 };
    };
    const small = try resize(allocator, image, 2);
    defer small.deinit(allocator);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, small.at(0, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, small.at(1, 0));
    const one = try resize(allocator, image, 1);
    defer one.deinit(allocator);
    // Half covered, and still pure red: the white is weighted by alpha 0.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 128 }, one.at(0, 0));
}

test "enlarging samples bilinearly" {
    const allocator = std.testing.allocator;
    var image: png.Image = try .init(allocator, 2, 1);
    defer image.deinit(allocator);
    image.pixels[0..8].* = .{ 0, 0, 0, 255, 200, 100, 50, 255 };
    const big = try resize(allocator, image, 4);
    defer big.deinit(allocator);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, big.at(0, 0));
    try std.testing.expectEqual([4]u8{ 50, 25, 13, 255 }, big.at(1, 0));
    try std.testing.expectEqual([4]u8{ 150, 75, 38, 255 }, big.at(2, 0));
    try std.testing.expectEqual([4]u8{ 200, 100, 50, 255 }, big.at(3, 0));
}

test "the ico directory lists every size with PNG payloads" {
    const allocator = std.testing.allocator;
    var image: png.Image = try .init(allocator, 64, 64);
    defer image.deinit(allocator);
    for (0..64 * 64) |i| image.pixels[i * 4 ..][0..4].* = .{ 30, 120, 220, 255 };
    const source = try png.encode(allocator, image);
    defer allocator.free(source);
    const ico = try pngToIco(allocator, source);
    defer allocator.free(ico);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico[2..4], .little));
    try std.testing.expectEqual(@as(u16, windows_sizes.len), std.mem.readInt(u16, ico[4..6], .little));
    for (windows_sizes, 0..) |size, i| {
        const entry = ico[6 + 16 * i ..][0..16];
        try std.testing.expectEqual(if (size >= 256) 0 else size, entry[0]);
        try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, entry[6..8], .little));
        const length = std.mem.readInt(u32, entry[8..12], .little);
        const offset = std.mem.readInt(u32, entry[12..16], .little);
        const payload = ico[offset..][0..length];
        const decoded = try png.decode(allocator, payload);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(size, decoded.width);
        try std.testing.expectEqual([4]u8{ 30, 120, 220, 255 }, decoded.at(size / 2, size / 2));
    }
}

test "the icns holds every entry as a PNG of its size" {
    const allocator = std.testing.allocator;
    var image: png.Image = try .init(allocator, 64, 64);
    defer image.deinit(allocator);
    for (0..64 * 64) |i| image.pixels[i * 4 ..][0..4].* = .{ 30, 120, 220, 255 };
    const source = try png.encode(allocator, image);
    defer allocator.free(source);
    const icns = try pngToIcns(allocator, source);
    defer allocator.free(icns);
    try std.testing.expectEqualStrings("icns", icns[0..4]);
    try std.testing.expectEqual(@as(u32, @intCast(icns.len)), std.mem.readInt(u32, icns[4..8], .big));
    var offset: usize = 8;
    for (icns_entries) |entry| {
        try std.testing.expectEqualStrings(entry.kind, icns[offset..][0..4]);
        const length = std.mem.readInt(u32, icns[offset + 4 ..][0..4], .big);
        const decoded = try png.decode(allocator, icns[offset + 8 .. offset + length]);
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(entry.size, decoded.width);
        offset += length;
    }
    try std.testing.expectEqual(icns.len, offset);
}
