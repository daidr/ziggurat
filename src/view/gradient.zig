//! Gradients a view node paints in place of its background or border color:
//! along a line at an angle, around a point, or out from a point in circles,
//! placed in fractions of the node's box so they follow it as it resizes.
const std = @import("std");
const ui = @import("ziggurat_ui");

const Rect = ui.Rect;
const Point = ui.layout.Point;

/// Most stops a gradient keeps; later ones are dropped.
pub const max_stops = ui.commands.brushes.max_stops;

/// A color of a gradient at its place `at`, from 0 to 1. Stops out of order
/// are moved up to the one before, as CSS places them.
pub const Stop = struct { color: ui.Color, at: f32 };

pub const Gradient = union(enum) {
    /// Colors along a line through the middle of the box, as CSS's
    /// `linear-gradient()`: `angle` is the line's direction in degrees
    /// clockwise from upwards, so 180 runs from top to bottom and 90 from
    /// left to right, and the line is as long as the box is across it.
    linear: struct { angle: f32 = 180, stops: []const Stop, oklab: bool = false },
    /// Colors turning around `center`, as CSS's `conic-gradient()`: from
    /// `angle`, in degrees clockwise from upwards, a full turn clockwise.
    /// `center` is in fractions of the box from its top left corner; null
    /// is its middle.
    conic: struct { center: ?Point = null, angle: f32 = 0, stops: []const Stop, oklab: bool = false },
    /// Colors spreading out from `center` in circles, as CSS's
    /// `radial-gradient()`: from 0 at the center to 1 at `radius` DIP away,
    /// or at the corner of the box farthest from the center when `radius`
    /// is 0, as CSS's `farthest-corner`. The first color shows before the
    /// center and the last past the radius, for glows, spotlights and
    /// vignettes. `center` is in fractions of the box; null is its middle.
    radial: struct { center: ?Point = null, radius: f32 = 0, stops: []const Stop, oklab: bool = false },

    /// The stops of the gradient, whatever its shape.
    pub fn stopsOf(self: Gradient) []const Stop {
        return switch (self) {
            inline else => |value| value.stops,
        };
    }
};

/// The recorder's gradient for `gradient` over `bounds`, its stops copied in
/// order into `buffer`; null when it has no stops or the box is not finite.
pub fn resolve(gradient: Gradient, bounds: Rect, buffer: *[max_stops]ui.commands.brushes.Stop) ?ui.commands.Gradient {
    const source = gradient.stopsOf();
    if (source.len == 0) return null;
    if (!finite(bounds.x) or !finite(bounds.y) or !finite(bounds.width) or !finite(bounds.height)) return null;
    const count = @min(source.len, max_stops);
    var last: f32 = -std.math.inf(f32);
    for (source[0..count], buffer[0..count]) |stop, *out| {
        // In order, as CSS puts them; NaN reads as the place before.
        const at = if (std.math.isNan(stop.at)) last else @max(stop.at, last);
        last = at;
        out.* = .{ .offset = std.math.clamp(if (std.math.isInf(at)) @as(f32, 0) else at, 0, 1), .color = stop.color };
    }
    // A gradient needs at least two stops; one is a solid color.
    var len = count;
    if (len == 1) {
        buffer[1] = buffer[0];
        buffer[0].offset = 0;
        buffer[1].offset = 1;
        len = 2;
    }
    const stops = buffer[0..len];
    switch (gradient) {
        .linear => |value| {
            const radians = @as(f64, value.angle) * std.math.pi / 180;
            const dx: f32 = @floatCast(@sin(radians));
            const dy: f32 = @floatCast(-@cos(radians));
            if (!finite(dx) or !finite(dy)) return null;
            var half = (@abs(bounds.width * dx) + @abs(bounds.height * dy)) / 2;
            // At least half a DIP each way, as in an empty box: a hard edge.
            half = @max(half, 0.25);
            const cx = bounds.x + bounds.width / 2;
            const cy = bounds.y + bounds.height / 2;
            return .{ .linear = .{
                .start = .{ .x = cx - dx * half, .y = cy - dy * half },
                .end = .{ .x = cx + dx * half, .y = cy + dy * half },
                .stops = stops,
                .interpolation = if (value.oklab) .oklab else .srgb,
            } };
        },
        .conic => |value| {
            const c = value.center orelse Point{ .x = 0.5, .y = 0.5 };
            if (!finite(c.x) or !finite(c.y) or !finite(value.angle)) return null;
            // Zero is upwards here and the +X axis for the recorder.
            return .{ .conic = .{
                .center = .{ .x = bounds.x + bounds.width * c.x, .y = bounds.y + bounds.height * c.y },
                .start_angle_radians = (@as(f64, value.angle) - 90) * std.math.pi / 180,
                .stops = stops,
                .interpolation = if (value.oklab) .oklab else .srgb,
            } };
        },
        .radial => |value| {
            const c = value.center orelse Point{ .x = 0.5, .y = 0.5 };
            if (!finite(c.x) or !finite(c.y) or !finite(value.radius)) return null;
            const cx = bounds.x + bounds.width * c.x;
            const cy = bounds.y + bounds.height * c.y;
            var radius = value.radius;
            if (radius <= 0) {
                // The farthest corner, as CSS's farthest-corner.
                const dx = @max(@abs(cx - bounds.x), @abs(bounds.x + bounds.width - cx));
                const dy = @max(@abs(cy - bounds.y), @abs(bounds.y + bounds.height - cy));
                radius = @sqrt(dx * dx + dy * dy);
            }
            // At least half a DIP, as in an empty box: its stops a hard edge.
            radius = @max(radius, 0.5);
            return .{ .radial = .{
                .center = .{ .x = cx, .y = cy },
                .radius = .{ .x = radius, .y = radius },
                .stops = stops,
                .interpolation = if (value.oklab) .oklab else .srgb,
            } };
        },
    }
}

fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

const red = ui.Color.rgb(0xff0000);
const blue = ui.Color.rgb(0x0000ff);

test "radial gradients reach the farthest corner without a radius and their radius with one" {
    var buffer: [max_stops]ui.commands.brushes.Stop = undefined;
    const box: Rect = .{ .x = 10, .y = 20, .width = 100, .height = 100 };
    const stops = [_]Stop{ .{ .color = red, .at = 0 }, .{ .color = blue, .at = 1 } };
    const middle = resolve(.{ .radial = .{ .stops = &stops } }, box, &buffer).?.radial;
    try std.testing.expectEqual(@as(f32, 60), middle.center.x);
    try std.testing.expectEqual(@as(f32, 70), middle.center.y);
    // The farthest corner, 50√2 away.
    try std.testing.expectApproxEqAbs(@as(f32, 50 * std.math.sqrt2), middle.radius.x, 0.001);
    // Off center: the farthest corners are on the right and bottom.
    const off = resolve(.{ .radial = .{ .center = .{ .x = 0.2, .y = 0.5 }, .stops = &stops } }, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, &buffer).?.radial;
    try std.testing.expectApproxEqAbs(@as(f32, @sqrt(80 * 80 + 50 * 50)), off.radius.x, 0.001);
    const fixed = resolve(.{ .radial = .{ .radius = 24, .stops = &stops, .oklab = true } }, box, &buffer).?.radial;
    try std.testing.expectEqual(@as(f32, 24), fixed.radius.y);
    try std.testing.expectEqual(ui.commands.brushes.InterpolationSpace.oklab, fixed.interpolation);
    // An empty box still has a usable radius.
    const empty = resolve(.{ .radial = .{ .stops = &stops } }, .{ .x = 5, .y = 5, .width = 0, .height = 0 }, &buffer).?.radial;
    try std.testing.expectEqual(@as(f32, 0.5), empty.radius.x);
}

test "linear gradients run along their angle across the box and conic ones start upwards" {
    var buffer: [max_stops]ui.commands.brushes.Stop = undefined;
    const box: Rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    const stops = [_]Stop{ .{ .color = red, .at = 0 }, .{ .color = blue, .at = 1 } };
    const down = resolve(.{ .linear = .{ .stops = &stops } }, box, &buffer).?.linear;
    try std.testing.expectApproxEqAbs(@as(f32, 100), down.start.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), down.start.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), down.end.y, 0.001);
    const right = resolve(.{ .linear = .{ .angle = 90, .stops = &stops } }, box, &buffer).?.linear;
    try std.testing.expectApproxEqAbs(@as(f32, 0), right.start.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), right.end.x, 0.001);
    const turn = resolve(.{ .conic = .{ .stops = &stops } }, box, &buffer).?.conic;
    try std.testing.expectApproxEqAbs(-std.math.pi / 2.0, turn.start_angle_radians, 1e-9);
    try std.testing.expectEqual(@as(f32, 100), turn.center.x);
}

test "gradient stops go in order, a lone stop is a solid color and none paint nothing" {
    var buffer: [max_stops]ui.commands.brushes.Stop = undefined;
    const box: Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const unordered = [_]Stop{ .{ .color = red, .at = 0.6 }, .{ .color = blue, .at = 0.2 } };
    const g = resolve(.{ .radial = .{ .stops = &unordered } }, box, &buffer).?.radial;
    try std.testing.expectEqual(@as(f32, 0.6), g.stops[1].offset);
    const lone = resolve(.{ .linear = .{ .stops = &.{.{ .color = red, .at = 0.3 }} } }, box, &buffer).?.linear;
    try std.testing.expectEqual(@as(usize, 2), lone.stops.len);
    try std.testing.expectEqual(red, lone.stops[1].color);
    try std.testing.expect(resolve(.{ .conic = .{ .stops = &.{} } }, box, &buffer) == null);
    // The recorder accepts what resolve makes.
    _ = try ui.commands.brushes.Stored.init(.{ .radial = g });
}
