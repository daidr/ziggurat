const std = @import("std");

/// Independent test oracle: separate XYZ matrices, f128 interpolation, and
/// linear traversal. It does not import the production color or brush code.
pub const Palette = struct {
    mode: u8,
    len: usize,
    offsets: [16]f64 = undefined,
    original: [16][4]f128 = undefined,
    coordinates: [16][4]f128 = undefined,
    pub fn init(mode: u8, stops: anytype) Palette {
        var result: Palette = .{ .mode = mode, .len = stops.len };
        for (stops, 0..) |stop, index| {
            const alpha = @as(f128, @floatFromInt(stop.color.a)) / 255;
            var rgb: [3]f128 = .{ @as(f128, @floatFromInt(stop.color.r)) / 255, @as(f128, @floatFromInt(stop.color.g)) / 255, @as(f128, @floatFromInt(stop.color.b)) / 255 };
            result.offsets[index] = stop.offset;
            result.original[index] = .{ rgb[0] * alpha, rgb[1] * alpha, rgb[2] * alpha, alpha };
            if (mode != 0) {
                for (&rgb) |*channel| channel.* = if (channel.* <= 0.04045) channel.* / 12.92 else pow((channel.* + 0.055) / 1.055, 2.4);
            }
            if (mode == 2) {
                const xyz: [3]f128 = .{
                    506752.0 / 1228815.0 * rgb[0] + 87881.0 / 245763.0 * rgb[1] + 12673.0 / 70218.0 * rgb[2],
                    87098.0 / 409605.0 * rgb[0] + 175762.0 / 245763.0 * rgb[1] + 12673.0 / 175545.0 * rgb[2],
                    7918.0 / 409605.0 * rgb[0] + 87881.0 / 737289.0 * rgb[1] + 1001167.0 / 1053270.0 * rgb[2],
                };
                const l = root(0.8190224379967030 * xyz[0] + 0.3619062600528904 * xyz[1] - 0.1288737815209879 * xyz[2]);
                const m = root(0.0329836539323885 * xyz[0] + 0.9292868615863434 * xyz[1] + 0.0361446663506424 * xyz[2]);
                const s = root(0.0481771893596242 * xyz[0] + 0.2642395317527308 * xyz[1] + 0.6335478284694309 * xyz[2]);
                rgb = .{ 0.2104542683093140 * l + 0.7936177747023054 * m - 0.0040720430116193 * s, 1.9779985324311684 * l - 2.4285922420485799 * m + 0.4505937096174110 * s, 0.0259040424655478 * l + 0.7827717124575296 * m - 0.8086757549230774 * s };
            }
            result.coordinates[index] = .{ rgb[0] * alpha, rgb[1] * alpha, rgb[2] * alpha, alpha };
        }
        return result;
    }
    pub fn at(self: *const Palette, t: f64) [4]f128 {
        var upper: usize = 0;
        while (upper < self.len and self.offsets[upper] <= t) : (upper += 1) {}
        if (upper == 0) return self.original[0];
        if (upper == self.len) return self.original[self.len - 1];
        if (t == self.offsets[upper - 1]) return self.original[upper - 1];
        const weight = (@as(f128, t) - self.offsets[upper - 1]) / (@as(f128, self.offsets[upper]) - self.offsets[upper - 1]);
        var out: [4]f128 = undefined;
        for (&out, self.coordinates[upper - 1], self.coordinates[upper]) |*value, a, b| value.* = a * (1 - weight) + b * weight;
        if (out[3] == 0) return .{ 0, 0, 0, 0 };
        if (self.mode == 0) return out;
        for (out[0..3]) |*value| value.* /= out[3];
        if (self.mode == 2) {
            const l = cube(out[0] + 0.3963377773761749 * out[1] + 0.2158037573099136 * out[2]);
            const m = cube(out[0] - 0.1055613458156586 * out[1] - 0.0638541728258133 * out[2]);
            const s = cube(out[0] - 0.0894841775298119 * out[1] - 1.2914855480194092 * out[2]);
            const xyz: [3]f128 = .{ 1.2268798758459243 * l - 0.5578149944602171 * m + 0.2813910456659647 * s, -0.0405757452148008 * l + 1.1122868032803170 * m - 0.0717110580655164 * s, -0.0763729366746601 * l - 0.4214933324022432 * m + 1.5869240198367816 * s };
            out[0] = 3.2409699419045226 * xyz[0] - 1.5373831775700940 * xyz[1] - 0.4986107602930034 * xyz[2];
            out[1] = -0.9692436362808796 * xyz[0] + 1.8759675015077202 * xyz[1] + 0.0415550574071756 * xyz[2];
            out[2] = 0.0556300796969937 * xyz[0] - 0.2039769588889765 * xyz[1] + 1.0569715142428786 * xyz[2];
        }
        for (out[0..3]) |*value| {
            const clipped = @min(1, @max(0, value.*));
            value.* = (if (clipped <= 0.0031308) clipped * 12.92 else 1.055 * pow(clipped, 1.0 / 2.4) - 0.055) * out[3];
        }
        return out;
    }
};
fn pow(value: f128, exponent: f64) f128 {
    return std.math.pow(f64, @floatCast(value), exponent);
}
fn cube(value: f128) f128 {
    return value * value * value;
}
fn root(value: f128) f128 {
    if (value == 0) return 0;
    var estimate: f128 = 1;
    for (0..32) |_| estimate = (2 * estimate + @abs(value) / (estimate * estimate)) / 3;
    return if (value < 0) -estimate else estimate;
}
pub fn over(value: [4]f128, background: u32, mask: u8) u32 {
    const coverage = @as(f128, @floatFromInt(mask)) / 255;
    const inverse = 1 - value[3] * coverage;
    var result: u32 = 0;
    for (value, [_]u5{ 16, 8, 0, 24 }, 0..) |channel, shift, index| {
        const bg: f128 = @floatFromInt((background >> shift) & 255);
        const source = if (index == 3) value[3] else channel;
        result |= @as(u32, @intFromFloat(@round(std.math.clamp(source * 255 * coverage + bg * inverse, 0, 255)))) << shift;
    }
    return result;
}
test "independent XYZ oracle retains literal midpoints and transparent hidden colors" {
    const Color = struct { r: u8, g: u8, b: u8, a: u8 = 255 };
    const Stop = struct { offset: f32, color: Color };
    const stops = [_]Stop{ .{ .offset = 0, .color = .{ .r = 0, .g = 0, .b = 0 } }, .{ .offset = 1, .color = .{ .r = 255, .g = 255, .b = 255 } } };
    for ([_]u32{ 0xff808080, 0xffbcbcbc, 0xff636363 }, 0..) |expected, mode| {
        const palette = Palette.init(@intCast(mode), &stops);
        try std.testing.expectEqual(expected, over(palette.at(0.5), 0, 255));
    }
    const hidden = [_]Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 255 } } };
    for (0..3) |mode| {
        const palette = Palette.init(@intCast(mode), &hidden);
        try std.testing.expectEqual(@as(u32, 0xff8080ff), over(palette.at(0.5), 0xffffffff, 255));
    }
}
