const std = @import("std");
const layout = @import("layout.zig");
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
};
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
