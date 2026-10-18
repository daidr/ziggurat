const std = @import("std");
const Color = @import("geometry.zig").Color;

/// Selects stop interpolation only. Inputs remain straight-alpha sRGB bytes;
/// compositing and the render target remain encoded, premultiplied sRGB.
pub const Space = enum(u8) { srgb, srgb_linear, oklab };

/// Premultiplied rectangular coordinates. Oklab a/b may be negative and must
/// not be clipped before interpolation or unpremultiplication.
pub const Coordinates = struct {
    channels: [3]f64,
    alpha: f64,

    pub fn fromColor(space: Space, color: Color) Coordinates {
        const alpha = @as(f64, @floatFromInt(color.a)) / 255;
        if (alpha == 0) return .{ .channels = .{ 0, 0, 0 }, .alpha = 0 };
        var channels: [3]f64 = .{ @as(f64, @floatFromInt(color.r)) / 255, @as(f64, @floatFromInt(color.g)) / 255, @as(f64, @floatFromInt(color.b)) / 255 };
        if (space != .srgb) {
            for (&channels) |*value| value.* = decode(value.*);
            if (space == .oklab) channels = labFromLinear(channels);
        }
        for (&channels) |*value| value.* *= alpha;
        return .{ .channels = channels, .alpha = alpha };
    }

    pub fn mix(a: Coordinates, b: Coordinates, weight: f64) Coordinates {
        var channels: [3]f64 = undefined;
        for (&channels, a.channels, b.channels) |*out, first, next| out.* = first + (next - first) * weight;
        return .{ .channels = channels, .alpha = a.alpha + (b.alpha - a.alpha) * weight };
    }

    pub fn encoded(self: Coordinates, space: Space) Encoded {
        if (self.alpha == 0) return .{ .channels = .{ 0, 0, 0 }, .alpha = 0 };
        var channels = self.channels;
        if (space != .srgb) {
            for (&channels) |*value| value.* /= self.alpha;
            if (space == .oklab) channels = linearFromLab(channels);
            // This is output-channel clipping, not perceptual gamut mapping.
            for (&channels) |*value| value.* = encode(std.math.clamp(value.*, 0, 1)) * self.alpha;
        }
        for (&channels) |*value| value.* *= 255;
        return .{ .channels = channels, .alpha = self.alpha };
    }
};

/// Encoded RGB in 0..255, already premultiplied by alpha in 0..1.
pub const Encoded = struct { channels: [3]f64, alpha: f64 };

fn decode(value: f64) f64 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}
fn encode(value: f64) f64 {
    if (value == 1) return 1;
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
}
fn labFromLinear(rgb: [3]f64) [3]f64 {
    const l = std.math.cbrt(0.4122214708 * rgb[0] + 0.5363325363 * rgb[1] + 0.0514459929 * rgb[2]);
    const m = std.math.cbrt(0.2119034982 * rgb[0] + 0.6806995451 * rgb[1] + 0.1073969566 * rgb[2]);
    const s = std.math.cbrt(0.0883024619 * rgb[0] + 0.2817188376 * rgb[1] + 0.6299787005 * rgb[2]);
    return .{ 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s };
}
fn linearFromLab(lab: [3]f64) [3]f64 {
    const l = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    const m = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    const s = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    const ll = l * l * l;
    const mm = m * m * m;
    const ss = s * s * s;
    return .{ 4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss, -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss, -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss };
}

test "three interpolation spaces have distinct literal black white midpoints" {
    for ([_]Space{ .srgb, .srgb_linear, .oklab }, [_]u8{ 128, 188, 99 }) |space, expected| {
        const value = Coordinates.mix(.fromColor(space, .rgb(0)), .fromColor(space, .rgb(0xffffff)), 0.5).encoded(space);
        for (value.channels) |channel| try std.testing.expectEqual(expected, @as(u8, @intFromFloat(@round(channel))));
        try std.testing.expectEqual(@as(f64, 1), value.alpha);
    }
}
test "alpha premultiplies signed coordinates and hidden transparent color cannot leak" {
    for ([_]Space{ .srgb, .srgb_linear, .oklab }) |space| {
        const hidden = Coordinates.fromColor(space, .{ .r = 255, .g = 0, .b = 0, .a = 0 });
        try std.testing.expectEqual([3]f64{ 0, 0, 0 }, hidden.channels);
        const value = Coordinates.mix(hidden, .fromColor(space, .rgb(0x0000ff)), 0.5).encoded(space);
        try std.testing.expectApproxEqAbs(@as(f64, 0), value.channels[0], 0.001);
        try std.testing.expectApproxEqAbs(@as(f64, 0), value.channels[1], 0.001);
        try std.testing.expectApproxEqAbs(@as(f64, 127.5), value.channels[2], 0.001);
        try std.testing.expectEqual(@as(f64, 0.5), value.alpha);
        const tiny = Coordinates.mix(hidden, .fromColor(space, .rgb(0x0000ff)), 1e-12).encoded(space);
        try std.testing.expect(tiny.alpha > 0 and tiny.channels[2] > 0);
    }
    const green = Coordinates.fromColor(.oklab, .rgb(0x00ff00));
    try std.testing.expect(green.channels[1] < 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.86643961), green.channels[0], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, -0.23388757), green.channels[1], 1e-7);
    try std.testing.expectApproxEqAbs(@as(f64, 0.17949848), green.channels[2], 1e-7);
}
test "output clips linear channels only after inverse conversion" {
    const value = (Coordinates{ .channels = .{ 0.7, 0.5, 0.5 }, .alpha = 1 }).encoded(.oklab);
    try std.testing.expectEqual(@as(f64, 255), value.channels[0]);
    try std.testing.expectEqual(@as(f64, 0), value.channels[1]);
    try std.testing.expectEqual(@as(f64, 0), value.channels[2]);
    const transparent = (Coordinates{ .channels = .{ 1, -1, 1 }, .alpha = 0 }).encoded(.oklab);
    try std.testing.expectEqual([3]f64{ 0, 0, 0 }, transparent.channels);
}
test "bounded byte palette round trips through each rectangular space" {
    for ([_]Space{ .srgb, .srgb_linear, .oklab }) |space| for ([_]u8{ 0, 1, 10, 64, 128, 255 }) |red| for ([_]u8{ 0, 16, 85, 170, 254, 255 }) |green| for ([_]u8{ 0, 8, 51, 127, 200, 255 }) |blue| for ([_]u8{ 1, 17, 128, 255 }) |alpha| {
        const original: Color = .{ .r = red, .g = green, .b = blue, .a = alpha };
        const value = Coordinates.fromColor(space, original).encoded(space);
        for (value.channels, [_]u8{ red, green, blue }) |actual, expected| try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(expected)) * @as(f64, @floatFromInt(alpha)) / 255, actual, 0.001);
    };
}
