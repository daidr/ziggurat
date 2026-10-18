const std = @import("std");
const api = @import("root.zig");
const Point = api.Point;
pub const Ellipse = struct {
    center: Point,
    x_axis: Point,
    y_axis: Point,
    start: f64,
    sweep: f64,
    pub fn at(self: Ellipse, angle: f64) Point {
        return .{ .x = self.center.x + (self.x_axis.x * @cos(angle) + self.y_axis.x * @sin(angle)), .y = self.center.y + (self.x_axis.y * @cos(angle) + self.y_axis.y * @sin(angle)) };
    }
};
pub const Result = union(enum) { none, line: Point, ellipse: Ellipse };
/// Shared endpoint conversion for flattening and analytic bounds. Degenerate
/// arcs keep the same line/empty semantics in both consumers.
pub const resolve = Conversion(.geometry).convert;
pub const directions = Conversion(.directions).convert;
const Projection = enum { geometry, directions };
fn Conversion(comptime projection: Projection) type {
    return struct {
        const Output = if (projection == .geometry) Result else ?api.Arc.Directions;
        fn convert(start: Point, value: api.Arc) !Output {
            if (start.x == value.end.x and start.y == value.end.y) {
                return if (projection == .geometry) .none else null;
            }
            var rx = @abs(value.radius.x);
            var ry = @abs(value.radius.y);
            if (rx == 0 or ry == 0) {
                if (projection == .geometry) {
                    return .{ .line = value.end };
                } else {
                    const direction: Point = .{ .x = value.end.x - start.x, .y = value.end.y - start.y };
                    return api.Arc.Directions{ .outgoing = direction, .incoming = direction };
                }
            }
            const phi = @mod(value.rotation, 360) * (std.math.pi / 180.0);
            const cosine = @cos(phi);
            const sine = @sin(phi);
            const delta: Point = .{ .x = (start.x - value.end.x) * 0.5, .y = (start.y - value.end.y) * 0.5 };
            const prime: Point = .{ .x = cosine * delta.x + sine * delta.y, .y = -sine * delta.x + cosine * delta.y };
            const ratio = std.math.hypot(prime.x / rx, prime.y / ry);
            if (!std.math.isFinite(ratio) or ratio == 0) return error.UnsupportedArcPrecision;
            if (ratio > 1) {
                rx *= ratio;
                ry *= ratio;
            }
            if (!std.math.isFinite(rx) or !std.math.isFinite(ry) or rx > 1e9 or ry > 1e9) return error.UnsupportedArcPrecision;
            const u = prime.x / rx;
            const w = prime.y / ry;
            const lambda = u * u + w * w;
            if (lambda == 0) return error.UnsupportedArcPrecision;
            var coefficient = @sqrt(@max(0, (1 - lambda) / lambda));
            // A nonzero subnormal lambda can still overflow the division. Reject it
            // here before Inf multiplied by a zero component creates a NaN ellipse.
            if (!std.math.isFinite(coefficient)) return error.UnsupportedArcPrecision;
            if (value.large == value.sweep) coefficient = -coefficient;
            const center_prime: Point = .{ .x = coefficient * rx * w, .y = -coefficient * ry * u };
            const middle: Point = .{ .x = (start.x + value.end.x) * 0.5, .y = (start.y + value.end.y) * 0.5 };
            const first: Point = .{ .x = (prime.x - center_prime.x) / rx, .y = (prime.y - center_prime.y) / ry };
            const last: Point = .{ .x = (-prime.x - center_prime.x) / rx, .y = (-prime.y - center_prime.y) / ry };
            var sweep = std.math.atan2(first.x * last.y - first.y * last.x, first.x * last.x + first.y * last.y);
            if (value.sweep and sweep < 0) sweep += 2 * std.math.pi;
            if (!value.sweep and sweep > 0) sweep -= 2 * std.math.pi;
            if (sweep == 0 and value.large) sweep = if (value.sweep) 2 * std.math.pi else -2 * std.math.pi;
            const ellipse: Ellipse = .{
                .center = .{ .x = middle.x + (cosine * center_prime.x - sine * center_prime.y), .y = middle.y + (sine * center_prime.x + cosine * center_prime.y) },
                .x_axis = .{ .x = rx * cosine, .y = rx * sine },
                .y_axis = .{ .x = -ry * sine, .y = ry * cosine },
                .start = std.math.atan2(first.y, first.x),
                .sweep = sweep,
            };
            // Both analytic bounds and flattening consume this same value. Success
            // never publishes a nonfinite center, axis or angular parameter.
            inline for (.{ ellipse.center, ellipse.x_axis, ellipse.y_axis }) |point| {
                if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.UnsupportedArcPrecision;
            }
            if (!std.math.isFinite(ellipse.start) or !std.math.isFinite(ellipse.sweep)) return error.UnsupportedArcPrecision;
            if (projection == .geometry) {
                return .{ .ellipse = ellipse };
            } else {
                // first/last are the converted radial components, before atan2.
                // Differentiating X*cos(theta)+Y*sin(theta) preserves the endpoint
                // limits without another trig round trip or a flattened chord.
                return api.Arc.Directions{
                    .outgoing = try tangent(ellipse, first, value.sweep),
                    .incoming = try tangent(ellipse, last, value.sweep),
                };
            }
        }
    };
}
fn tangent(ellipse: Ellipse, radial: Point, positive: bool) !Point {
    const sign: f64 = if (positive) 1 else -1;
    const direction: Point = .{
        .x = sign * (-ellipse.x_axis.x * radial.y + ellipse.y_axis.x * radial.x),
        .y = sign * (-ellipse.x_axis.y * radial.y + ellipse.y_axis.y * radial.x),
    };
    if (!std.math.isFinite(direction.x) or !std.math.isFinite(direction.y) or (direction.x == 0 and direction.y == 0)) return error.UnsupportedArcPrecision;
    return direction;
}
