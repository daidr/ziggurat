const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");

/// Packed premultiplied BGRA in native little-endian memory. The opaque
/// renderer fast path deliberately remains separate from transparent layers.
pub fn over(source: u32, destination: u32, opacity: f64) u32 {
    const amount = std.math.clamp(opacity, 0, 1);
    const alpha = @as(f64, @floatFromInt(source >> 24)) * amount / 255;
    if (alpha == 0) return destination;
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const before: f64 = @floatFromInt((destination >> shift) & 255);
        const channel: f64 = @floatFromInt((source >> shift) & 255);
        const value: u32 = @intFromFloat(std.math.clamp(@round(channel * amount + before * (1 - alpha)), 0, 255));
        result |= value << shift;
    }
    return result;
}
pub fn tint(rgb: u32, alpha: f64) u32 {
    const a = std.math.clamp(alpha, 0, 255);
    var result = @as(u32, @intFromFloat(@round(a))) << 24;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const color: f64 = @floatFromInt((rgb >> shift) & 255);
        result |= @as(u32, @intFromFloat(@round(color * a / 255))) << shift;
    }
    return result;
}
/// Integer paths for an already quantized premultiplied source. The odd
/// denominators have no half ties; these implement nearest rounding exactly.
pub inline fn tintByte(rgb: u32, alpha: u32) u32 {
    var result = alpha << 24;
    inline for ([_]u5{ 0, 8, 16 }) |shift| result |= ((((rgb >> shift) & 255) * alpha + 127) / 255) << shift;
    return result;
}
pub inline fn overFull(source: u32, destination: u32) u32 {
    const alpha = source >> 24;
    if (alpha == 0) return destination;
    if (alpha == 255) return source;
    const inverse = 255 - alpha;
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| result |= @as(u32, @min(255, ((source >> shift) & 255) + (((destination >> shift) & 255) * inverse + 127) / 255)) << shift;
    return result;
}
pub inline fn overByte(source: u32, destination: u32, opacity: u8) u32 {
    if (opacity == 255) return overFull(source, destination);
    if (opacity == 0 or source >> 24 == 0) return destination;
    const amount: @TypeOf(@as(u32, 0)) = opacity;
    const inverse = 65025 - (source >> 24) * amount;
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const numerator = ((source >> shift) & 255) * amount * 255 + ((destination >> shift) & 255) * inverse;
        result |= ((numerator + 32512) / 65025) << shift;
    }
    return result;
}
/// x/y are texel indices, so an integral origin reads exactly one A8 byte.
/// All four outside neighbors are transparent, including nonzero mask edges.
pub fn sample(mask: drawing.Coverage, x: f64, y: f64) f64 {
    if (x <= -1 or y <= -1 or x >= @as(f64, @floatFromInt(mask.width)) or y >= @as(f64, @floatFromInt(mask.height))) return 0;
    const bx: i64 = @intFromFloat(@floor(x));
    const by: i64 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var result: f64 = 0;
    for (0..2) |iy| for (0..2) |ix| {
        const px = bx + @as(i64, @intCast(ix));
        const py = by + @as(i64, @intCast(iy));
        if (px < 0 or py < 0 or px >= mask.width or py >= mask.height) continue;
        result += @as(f64, @floatFromInt(mask.pixels[@as(usize, @intCast(py)) * mask.stride + @as(usize, @intCast(px))])) * (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
    };
    return result;
}

test "transparent source-over preserves alpha and group opacity is applied once" {
    const red = tint(0xff0000, 128);
    const blue = tint(0x0000ff, 128);
    const group = over(blue, red, 1);
    try std.testing.expectEqual(@as(u32, 0xc0400080), group);
    try std.testing.expectEqual(@as(u32, 0xffbf9fdf), over(group, 0xffffffff, 0.5));
    try std.testing.expect(over(group, 0xffffffff, 0.5) != over(blue, over(red, 0xffffffff, 0.5), 0.5));
    try std.testing.expectEqual(@as(u32, 0), over(0, 0, 0.5));
    try std.testing.expectEqual(@as(u32, 0x12345678), over(0, 0x12345678, 1));
}

test "integer premultiplied source over matches the fractional scalar oracle" {
    var random = std.Random.DefaultPrng.init(923414);
    const r = random.random();
    for (0..20000) |_| {
        const source = tintByte(r.int(u32) & 0xffffff, r.int(u8));
        const destination = tintByte(r.int(u32) & 0xffffff, r.int(u8));
        const opacity = r.int(u8);
        try std.testing.expectEqual(over(source, destination, @as(f64, @floatFromInt(opacity)) / 255), overByte(source, destination, opacity));
        try std.testing.expectEqual(over(source, destination, 1), overFull(source, destination));
    }
}
