const std = @import("std");
const layout = @import("layout.zig");
const gamut = @import("gamut.zig");
const gradient_color = @import("gradient_color.zig");
pub const Rect = layout.Rect;

/// Explicit bound for the adapters' reusable 32-bit software surfaces.
pub const max_surface_dimension = 32768;
pub const max_surface_bytes = 256 * 1024 * 1024;
pub fn validateSurface(width: u32, height: u32, scale: f32) error{InvalidGeometry}!usize {
    if (width == 0 or height == 0 or width > max_surface_dimension or height > max_surface_dimension or !std.math.isFinite(scale) or scale <= 0 or @as(f64, scale) * 16 > std.math.maxInt(i32)) return error.InvalidGeometry;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidGeometry;
    const bytes = std.math.mul(usize, pixels, 4) catch return error.InvalidGeometry;
    if (bytes > max_surface_bytes) return error.InvalidGeometry;
    return bytes;
}

/// Straight-alpha encoded RGB. Existing u32 fill/text APIs remain opaque RGB.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
    pub fn rgb(value: u32) Color {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }
    pub fn rgba(self: Color) u32 {
        return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | self.a;
    }
    /// 0xRRGGBB without alpha, the form of `Style.background` and palettes.
    pub fn hex(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }
    /// The color with its alpha multiplied by `alpha` in 0..1.
    pub fn withAlpha(self: Color, alpha: f32) Color {
        var copy = self;
        copy.a = alphaByte(@as(f32, @floatFromInt(self.a)) / 255 * alpha);
        return copy;
    }
    /// CSS `oklch(l c h)`: lightness from 0 to 1, chroma from 0 to about 0.4
    /// and hue in degrees; `withAlpha` gives `oklch(l c h / a)`. A color
    /// Display P3 cannot show first loses chroma, keeping lightness and hue,
    /// and a negative chroma is 0, as in CSS. Windows draw sRGB, so a color
    /// outside it shows as the nearest sRGB color, found as CSS Color 4 does.
    pub fn oklch(l: f32, c: f32, h: f32) Color {
        const p3 = gamut.map(.display_p3, l, c, h);
        const linear = gamut.linearP3ToSrgb(p3[0], p3[1], p3[2]);
        return extended(@floatCast(gamut.encode(linear[0])), @floatCast(gamut.encode(linear[1])), @floatCast(gamut.encode(linear[2])));
    }
    /// CSS `color(display-p3 r g b)`: components from 0 to 1, encoded with
    /// the sRGB curve, shown as the nearest sRGB color.
    pub fn displayP3(r: f32, g: f32, b: f32) Color {
        const linear = gamut.linearP3ToSrgb(gamut.decode(std.math.clamp(r, 0, 1)), gamut.decode(std.math.clamp(g, 0, 1)), gamut.decode(std.math.clamp(b, 0, 1)));
        return extended(@floatCast(gamut.encode(linear[0])), @floatCast(gamut.encode(linear[1])), @floatCast(gamut.encode(linear[2])));
    }
    /// The color `t` of the way from `a` to `b` (0 is `a`, 1 is `b`), mixed
    /// premultiplied in sRGB, as a transition moves colors.
    pub fn mix(a: Color, b: Color, t: f32) Color {
        return mixIn(.srgb, a, b, t);
    }
    /// `mix` in Oklab, as a gradient's `.oklab` interpolation mixes: the
    /// way between two saturated colors keeps their lightness and
    /// saturation instead of going through a dull, darker middle, so that
    /// yellow and blue meet in a blue rather than in sRGB's gray.
    pub fn mixOklab(a: Color, b: Color, t: f32) Color {
        return mixIn(.oklab, a, b, t);
    }
    fn mixIn(space: gradient_color.Space, a: Color, b: Color, t: f32) Color {
        const weight: f64 = if (std.math.isFinite(t)) std.math.clamp(t, 0, 1) else 0;
        const mixed = gradient_color.Coordinates.mix(.fromColor(space, a), .fromColor(space, b), weight).encoded(space);
        if (!(mixed.alpha > 0)) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        var bytes: [3]u8 = undefined;
        for (&bytes, mixed.channels) |*out, value| out.* = @intFromFloat(@round(std.math.clamp(value / mixed.alpha, 0, 255)));
        return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = @intFromFloat(@round(std.math.clamp(mixed.alpha, 0, 1) * 255)) };
    }
    /// The opaque color of extended sRGB components, mapped into sRGB when
    /// outside it; components that are not finite give opaque black.
    pub fn extended(r: f32, g: f32, b: f32) Color {
        const mapped = gamut.nearestSrgb(r, g, b) orelse return .{ .r = 0, .g = 0, .b = 0 };
        const byte = struct {
            fn run(v: f64) u8 {
                return @intFromFloat(@max(0, @min(v, 1)) * 255 + 0.5);
            }
        }.run;
        return .{ .r = byte(mapped[0]), .g = byte(mapped[1]), .b = byte(mapped[2]) };
    }
};
fn alphaByte(a: f32) u8 {
    if (!(a > 0)) return 0;
    if (a >= 1) return 255;
    return @intFromFloat(a * 255 + 0.5);
}

test "oklch colors match CSS's sRGB results" {
    // oklch(62.8% 0.2577 29.23) is sRGB red.
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, Color.oklch(0.6279554, 0.2576833, 29.2338851));
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, Color.oklch(1, 0.1, 30));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, Color.oklch(0, 0.1, 30));
    // Gray when chroma is zero or negative.
    const gray = Color.oklch(0.5, -1, 200);
    try std.testing.expect(gray.r == gray.g and gray.g == gray.b);
    try std.testing.expectEqual(Color.oklch(0.5, 0, 0), gray);
    // A vivid P3 green maps to a saturated sRGB green.
    const green = Color.oklch(0.85, 0.35, 145);
    try std.testing.expect(green.g > 200 and green.r < green.g and green.b < green.g);
    try std.testing.expectEqual(@as(u8, 128), Color.oklch(0.5, 0.1, 30).withAlpha(0.5).a);
    try std.testing.expectEqual(@as(u32, 0xff0000), Color.oklch(0.6279554, 0.2576833, 29.2338851).hex());
}

test "colors mix in sRGB and in Oklab" {
    const yellow = Color.rgb(0xffff00);
    const blue = Color.rgb(0x0000ff);
    try std.testing.expectEqual(yellow, Color.mixOklab(yellow, blue, 0));
    try std.testing.expectEqual(blue, Color.mixOklab(yellow, blue, 1));
    try std.testing.expectEqual(blue, Color.mix(yellow, blue, 1));
    // sRGB meets in a gray; Oklab keeps more of the colors' saturation.
    const plain = Color.mix(yellow, blue, 0.5);
    try std.testing.expect(plain.r == 128 and plain.g == 128 and plain.b == 128);
    const lab = Color.mixOklab(yellow, blue, 0.5);
    try std.testing.expect(lab.b > lab.r);
    try std.testing.expect(lab.r != lab.g or lab.g != lab.b);
    // Alpha mixes premultiplied: a transparent end takes the other's hue.
    const half = Color.mixOklab(.{ .r = 0, .g = 0, .b = 0, .a = 0 }, blue, 0.5);
    try std.testing.expectEqual(@as(u8, 128), half.a);
    try std.testing.expectEqual(@as(u8, 255), half.b);
}

test "display P3 primaries show as the nearest sRGB colors" {
    try std.testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, Color.displayP3(1, 1, 1));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, Color.displayP3(0, 0, 0));
    const red = Color.displayP3(1, 0, 0);
    try std.testing.expect(red.r == 255 and red.g < 40 and red.b < 40);
    // Inside sRGB a P3 color converts exactly.
    const mid = Color.displayP3(0.5, 0.5, 0.5);
    try std.testing.expect(mid.r == mid.g and mid.g == mid.b and (mid.r == 127 or mid.r == 128));
}
pub const Shape = struct { bounds: Rect, color: Color, radius: f32 = 0, stroke_width: f32 = 0 };
pub const Plan = struct {
    bounds: Rect,
    inner: Rect,
    radius: f32,
    inner_radius: f32,
    stroke_width: f32,
    color: Color,
};

/// Bounds enclose the complete primitive. Stroke lies inside these bounds.
/// Radius always describes the outer contour; the hole's radius is max(0,r-w).
pub fn plan(shape: Shape) !Plan {
    if (!layout.validRect(shape.bounds) or !std.math.isFinite(shape.bounds.x + shape.bounds.width) or !std.math.isFinite(shape.bounds.y + shape.bounds.height) or !std.math.isFinite(shape.radius) or shape.radius < 0 or !std.math.isFinite(shape.stroke_width) or shape.stroke_width < 0) return error.InvalidGeometry;
    const b = shape.bounds;
    const half = @min(b.width, b.height) * 0.5;
    const stroke = @min(shape.stroke_width, half);
    const radius = @min(shape.radius, half);
    const inner: Rect = .{ .x = b.x + stroke, .y = b.y + stroke, .width = @max(0, b.width - stroke * 2), .height = @max(0, b.height - stroke * 2) };
    if (!layout.validRect(inner)) return error.InvalidGeometry;
    return .{ .bounds = b, .inner = inner, .radius = radius, .inner_radius = @max(0, radius - stroke), .stroke_width = stroke, .color = shape.color };
}

fn distance(bounds: Rect, radius: f32, x: f64, y: f64) f64 {
    const half_x = @as(f64, bounds.width) * 0.5;
    const half_y = @as(f64, bounds.height) * 0.5;
    const qx = @abs(x - (@as(f64, bounds.x) + half_x)) - (half_x - radius);
    const qy = @abs(y - (@as(f64, bounds.y) + half_y)) - (half_y - radius);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - radius;
}

/// Analytic full/empty classification; only boundary pixels use fixed 4x4
/// coverage samples. Coordinates are DIP; pixel_size is one physical pixel.
pub fn coverage(p: Plan, x: f64, y: f64, pixel_size: f64) u8 {
    if (p.bounds.width == 0 or p.bounds.height == 0) return 0;
    const margin = pixel_size * 0.7071067811865476;
    const outer = distance(p.bounds, p.radius, x, y);
    if (outer > margin) return 0;
    const hole = p.stroke_width > 0 and p.inner.width > 0 and p.inner.height > 0;
    const inner = if (hole) distance(p.inner, p.inner_radius, x, y) else std.math.inf(f64);
    if (inner < -margin) return 0;
    if (outer < -margin and inner > margin) return 255;
    var count: u32 = 0;
    for (0..4) |row| for (0..4) |column| {
        const sx = x + (@as(f64, @floatFromInt(column)) * 0.25 - 0.375) * pixel_size;
        const sy = y + (@as(f64, @floatFromInt(row)) * 0.25 - 0.375) * pixel_size;
        if (distance(p.bounds, p.radius, sx, sy) <= 0 and (!hole or distance(p.inner, p.inner_radius, sx, sy) >= 0)) count += 1;
    };
    return @intCast((count * 255 + 8) / 16);
}

test "shape planning clamps dimensions and preserves outer radius with thick strokes" {
    const fill = try plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 10 }, .color = Color.rgb(0x123456), .radius = 999 });
    try std.testing.expectEqual(@as(f32, 5), fill.radius);
    try std.testing.expectEqual(@as(u32, 0x123456ff), fill.color.rgba());
    const stroke = try plan(.{ .bounds = fill.bounds, .color = fill.color, .radius = 1, .stroke_width = 4 });
    try std.testing.expectEqual(@as(f32, 1), stroke.radius);
    try std.testing.expectEqual(@as(f32, 4), stroke.inner.x);
    try std.testing.expectEqual(@as(u8, 0), coverage(stroke, 10, 5, 1));
    try std.testing.expectEqual(@as(u8, 255), coverage(stroke, 1.5, 5, 1));
    try std.testing.expectError(error.InvalidGeometry, plan(.{ .bounds = fill.bounds, .color = fill.color, .radius = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidGeometry, plan(.{ .bounds = fill.bounds, .color = fill.color, .stroke_width = -1 }));
}

test "software surfaces reject invalid or oversized dimensions before native work" {
    try std.testing.expectEqual(4 * 1920 * 1080, try validateSurface(1920, 1080, 1.5));
    try std.testing.expectEqual(max_surface_bytes, try validateSurface(8192, 8192, 1));
    try std.testing.expectError(error.InvalidGeometry, validateSurface(0, 1, 1));
    try std.testing.expectError(error.InvalidGeometry, validateSurface(1, std.math.maxInt(u32), 1));
    try std.testing.expectError(error.InvalidGeometry, validateSurface(32768, 32768, 1));
    try std.testing.expectError(error.InvalidGeometry, validateSurface(1, 1, std.math.nan(f32)));
    try std.testing.expectError(error.InvalidGeometry, validateSurface(1, 1, std.math.floatMax(f32)));
}

test "colors mix with premultiplied alpha, as CSS's color-mix" {
    const red: Color = .{ .r = 255, .g = 0, .b = 0 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 255 };
    const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    try std.testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0, .a = 128 }, red.mixOklab(clear, 0.5));
    try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 255, .a = 64 }, clear.mixOklab(blue, 0.25));
    try std.testing.expectEqual(clear, clear.mixOklab(clear, 0.5));
    const translucent = red.withAlpha(0.25).mixOklab(blue, 0.5);
    try std.testing.expectEqual(@as(u8, 160), translucent.a);
    try std.testing.expect(translucent.b > translucent.r);
}
