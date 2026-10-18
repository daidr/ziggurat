const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
/// Coordinates use pixel edges. Clamping happens after the half-pixel shift,
/// so a prepared crop never samples pixels belonging to its former neighbor.
pub fn sample(level: drawing.ImageLevel, sx: f64, sy: f64, linear: bool) [4]u8 {
    const pixels = level.pixels[0..level.byte_len];
    const max_x: f64 = @floatFromInt(level.width - 1);
    const max_y: f64 = @floatFromInt(level.height - 1);
    const x = @min(max_x, @max(0, sx - (if (linear) @as(f64, 0.5) else 0)));
    const y = @min(max_y, @max(0, sy - (if (linear) @as(f64, 0.5) else 0)));
    const ix: usize = @intFromFloat(@floor(x));
    const iy: usize = @intFromFloat(@floor(y));
    if (!linear) return pixels[iy * level.stride + ix * 4 ..][0..4].*;
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var sum = [_]f64{ 0, 0, 0, 0 };
    for (0..2) |yy| for (0..2) |xx| {
        const px = @min(level.width - 1, ix + xx);
        const py = @min(level.height - 1, iy + yy);
        const weight = (if (xx == 0) 1 - fx else fx) * (if (yy == 0) 1 - fy else fy);
        for (0..4) |channel| sum[channel] += @as(f64, @floatFromInt(pixels[py * level.stride + px * 4 + channel])) * weight;
    };
    var color: [4]u8 = undefined;
    for (&color, sum) |*value, channel| value.* = @intFromFloat(@round(channel));
    return color;
}
pub fn over(color: [4]u8, background: u32, multiplier: f64) u32 {
    const alpha = @as(f64, @floatFromInt(color[3])) * multiplier / 255;
    var result: u32 = 0xff000000;
    for (0..3) |channel| {
        const shift: u5 = @intCast(channel * 8);
        const source = @as(f64, @floatFromInt(color[channel])) * multiplier;
        const destination: f64 = @floatFromInt((background >> shift) & 255);
        const value: u32 = @intFromFloat(@min(255, @max(0, @round(source + destination * (1 - alpha)))));
        result |= value << shift;
    }
    return result;
}
pub fn overAlpha(color: [4]u8, background: u32, multiplier: f64) u32 {
    const alpha = @as(f64, @floatFromInt(color[3])) * multiplier / 255;
    const result: u32 = @intFromFloat(std.math.clamp(@round(alpha * 255 + @as(f64, @floatFromInt(background >> 24)) * (1 - alpha)), 0, 255));
    return (over(color, background, multiplier) & 0xffffff) | (result << 24);
}

test "premultiplied linear samples never leak transparent RGB and clamp borders" {
    const bytes = [_]u8{ 0, 0, 255, 255, 0, 0, 0, 0 };
    const level: drawing.ImageLevel = .{ .pixels = &bytes, .byte_len = bytes.len, .width = 2, .height = 1, .stride = 8 };
    try std.testing.expectEqual([4]u8{ 0, 0, 128, 128 }, sample(level, 1, 0.5, true));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, sample(level, -1e20, 0.5, true));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, sample(level, 1e20, 0.5, true));
    try std.testing.expectEqual(@as(u32, 0xffff7f7f), over(sample(level, 1, 0.5, true), 0xffffff, 1));
}
