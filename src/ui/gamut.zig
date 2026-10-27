//! Conversions between sRGB, Display P3, Oklab and Oklch, and gamut mapping
//! as CSS Color 4 defines it.
//!
//! Colors travel as extended sRGB: encoded with the sRGB curve mirrored
//! around zero, so a color outside the sRGB gamut (but inside Display P3)
//! has components below 0 or above 1.
const std = @import("std");

/// An RGB gamut colors are mapped into.
pub const Space = enum(u8) { srgb, display_p3 };

/// Linear light of an sRGB-encoded component, which may lie outside 0..1.
pub fn decode(v: f64) f64 {
    const a = @abs(v);
    if (a <= 0.04045) return v / 12.92;
    return std.math.copysign(std.math.pow(f64, (a + 0.055) / 1.055, 2.4), v);
}

/// Inverse of `decode`.
pub fn encode(v: f64) f64 {
    const a = @abs(v);
    if (a <= 0.0031308) return v * 12.92;
    return std.math.copysign(1.055 * std.math.pow(f64, a, 1.0 / 2.4) - 0.055, v);
}

/// Linear sRGB to Oklab.
pub fn oklab(r: f64, g: f64, b: f64) [3]f64 {
    const lc = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const mc = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const sc = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
        1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
        0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc,
    };
}

/// Oklab to linear sRGB, unclamped.
pub fn linearSrgb(l: f64, a: f64, b: f64) [3]f64 {
    var lc = l + 0.3963377774 * a + 0.2158037573 * b;
    var mc = l - 0.1055613458 * a - 0.0638541728 * b;
    var sc = l - 0.0894841775 * a - 1.2914855480 * b;
    lc = lc * lc * lc;
    mc = mc * mc * mc;
    sc = sc * sc * sc;
    return .{
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
    };
}

/// Linear sRGB to linear Display P3.
pub fn linearSrgbToP3(r: f64, g: f64, b: f64) [3]f64 {
    return .{
        0.8224621 * r + 0.1775380 * g,
        0.0331941 * r + 0.9668058 * g,
        0.0170827 * r + 0.0723974 * g + 0.9105199 * b,
    };
}

/// Linear Display P3 to linear sRGB.
pub fn linearP3ToSrgb(r: f64, g: f64, b: f64) [3]f64 {
    return .{
        1.2249401 * r - 0.2249404 * g,
        -0.0420569 * r + 1.0420571 * g,
        -0.0196376 * r - 0.0786361 * g + 1.0982735 * b,
    };
}

/// Oklab to Oklch, the hue in degrees from 0 to 360.
pub fn oklch(l: f64, a: f64, b: f64) [3]f64 {
    var h = std.math.atan2(b, a) * 180 / std.math.pi;
    if (h < 0) h += 360;
    return .{ l, std.math.hypot(a, b), h };
}

/// Oklch, the hue in degrees, to Oklab.
pub fn fromOklch(l: f64, c: f64, h: f64) [3]f64 {
    const radians = h * std.math.pi / 180;
    return .{ l, c * @cos(radians), c * @sin(radians) };
}

fn toSpace(space: Space, l: f64, a: f64, b: f64) [3]f64 {
    const rgb = linearSrgb(l, a, b);
    return if (space == .display_p3) linearSrgbToP3(rgb[0], rgb[1], rgb[2]) else rgb;
}

fn fromSpace(space: Space, r: f64, g: f64, b: f64) [3]f64 {
    const rgb = if (space == .display_p3) linearP3ToSrgb(r, g, b) else [3]f64{ r, g, b };
    return oklab(rgb[0], rgb[1], rgb[2]);
}

/// The Oklab distance CSS Color 4 treats as imperceptible.
const jnd = 0.02;
/// Ends the chroma search and absorbs the matrices' rounding.
const epsilon = 0.0001;
const in_gamut = 0.00001;
/// Beyond the chroma of any color a display shows; larger requests start
/// their search here.
const max_chroma = 1;

fn within(rgb: [3]f64) bool {
    for (rgb) |v| if (!(v >= -in_gamut and v <= 1 + in_gamut)) return false;
    return true;
}

fn clip(v: f64) f64 {
    return @max(0, @min(v, 1));
}

/// The Oklch color as linear RGB inside the gamut of `space`. Chroma is
/// reduced, keeping lightness and hue, until clipping what is left changes
/// the color imperceptibly (CSS Color 4's gamut mapping to a destination
/// space). A negative or NaN chroma is 0, a NaN lightness 0 and a hue that
/// is not finite 0.
pub fn map(space: Space, l: f64, c_in: f64, h_in: f64) [3]f64 {
    if (l >= 1) return .{ 1, 1, 1 };
    if (!(l > 0)) return .{ 0, 0, 0 };
    var c = if (c_in > 0) c_in else 0;
    c = @min(c, max_chroma);
    const h = if (std.math.isFinite(h_in)) h_in else 0;
    const lab = fromOklch(l, c, h);
    const direct = toSpace(space, l, lab[1], lab[2]);
    if (within(direct)) return .{ clip(direct[0]), clip(direct[1]), clip(direct[2]) };
    const Clipped = struct { rgb: [3]f64, e: f64 };
    const clipped = struct {
        fn run(sp: Space, lightness: f64, a: f64, b: f64) Clipped {
            const rgb = toSpace(sp, lightness, a, b);
            const out = [3]f64{ clip(rgb[0]), clip(rgb[1]), clip(rgb[2]) };
            const back = fromSpace(sp, out[0], out[1], out[2]);
            const dl = back[0] - lightness;
            const da = back[1] - a;
            const db = back[2] - b;
            return .{ .rgb = out, .e = @sqrt(dl * dl + da * da + db * db) };
        }
    }.run;
    var result = clipped(space, l, lab[1], lab[2]);
    if (result.e < jnd) return result.rgb;
    var lo: f64 = 0;
    var hi: f64 = c;
    var lo_in = true;
    while (hi - lo > epsilon) {
        const mid = (lo + hi) / 2;
        const at = fromOklch(l, mid, h);
        if (lo_in and within(toSpace(space, l, at[1], at[2]))) {
            lo = mid;
            continue;
        }
        result = clipped(space, l, at[1], at[2]);
        if (result.e < jnd) {
            if (jnd - result.e < epsilon) return result.rgb;
            lo_in = false;
            lo = mid;
        } else hi = mid;
    }
    return result.rgb;
}

/// The nearest color in the sRGB gamut, sRGB-encoded in 0..1, of extended
/// sRGB components. Components inside the gamut are kept; a color outside
/// it is mapped as CSS Color 4 does. Components are first held at the
/// fixed precision of a wide color (1/8192 steps up to ±4), so a color
/// mixed with itself maps to itself.
pub fn nearestSrgb(r: f32, g: f32, b: f32) ?[3]f64 {
    if (!std.math.isFinite(r) or !std.math.isFinite(g) or !std.math.isFinite(b)) return null;
    const fixed = struct {
        fn run(v: f32) f32 {
            const one: f64 = 1 << 13;
            const q = @max(-32767.0, @min(@round(@as(f64, v) * one), 32767.0));
            return @floatCast(q / one);
        }
    }.run;
    const rgb = [3]f32{ fixed(r), fixed(g), fixed(b) };
    const eps: f32 = 1.0 / 512.0;
    var inside = true;
    for (rgb) |v| inside = inside and v >= -eps and v <= 1 + eps;
    if (inside) return .{ @max(0, @min(rgb[0], 1)), @max(0, @min(rgb[1], 1)), @max(0, @min(rgb[2], 1)) };
    const lab = oklab(decode(rgb[0]), decode(rgb[1]), decode(rgb[2]));
    const lch = oklch(lab[0], lab[1], lab[2]);
    const linear = map(.srgb, lch[0], lch[1], lch[2]);
    return .{ encode(linear[0]), encode(linear[1]), encode(linear[2]) };
}

test "sRGB curves are mirrored inverses" {
    for ([_]f64{ -1.5, -0.2, 0, 0.002, 0.04, 0.5, 1, 1.3 }) |v| try std.testing.expectApproxEqAbs(v, encode(decode(v)), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.21404114048223255), decode(0.5), 1e-12);
}

test "Oklab round-trips through linear sRGB and Oklch" {
    const lab = oklab(1, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 1), lab[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0), lab[1], 1e-6);
    const red = oklab(1, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6279553606), red[0], 1e-6);
    const lch = oklch(red[0], red[1], red[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2577), lch[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 29.2339), lch[2], 1e-3);
    const back = fromOklch(lch[0], lch[1], lch[2]);
    const rgb = linearSrgb(back[0], back[1], back[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), rgb[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0), rgb[1], 1e-6);
    const p3 = linearSrgbToP3(1, 0, 0);
    const srgb = linearP3ToSrgb(p3[0], p3[1], p3[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), srgb[0], 1e-5);
}

test "mapping keeps colors in gamut and reduces chroma outside it" {
    // In gamut: unchanged.
    const red = oklab(1, 0, 0);
    const lch = oklch(red[0], red[1], red[2]);
    const mapped = map(.srgb, lch[0], lch[1], lch[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 1), mapped[0], 1e-4);
    // Lightness out of range is white or black.
    try std.testing.expectEqual([3]f64{ 1, 1, 1 }, map(.srgb, 1.2, 0.3, 40));
    try std.testing.expectEqual([3]f64{ 0, 0, 0 }, map(.srgb, std.math.nan(f64), 0.3, 40));
    // Far out of gamut: every component lands in 0..1, and Display P3 keeps
    // more chroma than sRGB does.
    for ([_]f64{ 0, 60, 145, 250, 330 }) |h| {
        const s = map(.srgb, 0.7, 0.4, h);
        const p = map(.display_p3, 0.7, 0.4, h);
        for (s) |v| try std.testing.expect(v >= 0 and v <= 1);
        for (p) |v| try std.testing.expect(v >= 0 and v <= 1);
        const s_lab = fromSpace(.srgb, s[0], s[1], s[2]);
        const p_lab = fromSpace(.display_p3, p[0], p[1], p[2]);
        try std.testing.expect(std.math.hypot(p_lab[1], p_lab[2]) >= std.math.hypot(s_lab[1], s_lab[2]) - 1e-3);
        try std.testing.expectApproxEqAbs(@as(f64, 0.7), s_lab[0], 0.03);
    }
}

test "nearest sRGB keeps in-gamut components and maps wide ones" {
    try std.testing.expectEqual([3]f64{ 0.5, 0, 1 }, nearestSrgb(0.5, 0, 1).?);
    try std.testing.expect(nearestSrgb(std.math.nan(f32), 0, 0) == null);
    const wide = nearestSrgb(1.09, -0.23, -0.15).?;
    for (wide) |v| try std.testing.expect(v >= 0 and v <= 1);
    try std.testing.expect(wide[0] > 0.9 and wide[1] < 0.2);
}
