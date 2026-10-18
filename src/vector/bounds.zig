const std = @import("std");
const api = @import("root.zig");
const arcs = @import("arc.zig");
const Point = api.Point;
pub const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };
const Accumulator = struct {
    minimum: ?Point = null,
    maximum: Point = .{},
    fn add(self: *Accumulator, point: Point) !void {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidGeometry;
        if (self.minimum) |minimum| {
            self.minimum = .{ .x = @min(minimum.x, point.x), .y = @min(minimum.y, point.y) };
            self.maximum = .{ .x = @max(self.maximum.x, point.x), .y = @max(self.maximum.y, point.y) };
        } else {
            self.minimum = point;
            self.maximum = point;
        }
    }
    fn finish(self: Accumulator) ?Bounds {
        const minimum = self.minimum orelse return null;
        return .{ .x = minimum.x, .y = minimum.y, .width = self.maximum.x - minimum.x, .height = self.maximum.y - minimum.y };
    }
};
fn interpolate(a: Point, b: Point, t: f64) Point {
    return .{ .x = (1 - t) * a.x + t * b.x, .y = (1 - t) * a.y + t * b.y };
}
fn cubic(a: Point, b: Point, c: Point, d: Point, t: f64) Point {
    return interpolate(interpolate(interpolate(a, b, t), interpolate(b, c, t), t), interpolate(interpolate(b, c, t), interpolate(c, d, t), t), t);
}
fn includeCubic(result: *Accumulator, a: Point, b: Point, c: Point, d: Point, t: f64) !void {
    if (t > 0 and t < 1) try result.add(cubic(a, b, c, d, t));
}
fn cubicExtrema(result: *Accumulator, points: [4]Point, values: [4]f64) !void {
    const d0 = values[1] - values[0];
    const d1 = values[2] - values[1];
    const d2 = values[3] - values[2];
    const a = d0 - 2 * d1 + d2;
    const b = 2 * (d1 - d0);
    const c = d0;
    if (a == 0) {
        if (b != 0) try includeCubic(result, points[0], points[1], points[2], points[3], -c / b);
        return;
    }
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return;
    const q = -0.5 * (b + std.math.copysign(@sqrt(discriminant), b));
    try includeCubic(result, points[0], points[1], points[2], points[3], q / a);
    if (q != 0) try includeCubic(result, points[0], points[1], points[2], points[3], c / q);
}
fn vector(matrix: api.Transform, point: Point) Point {
    return .{ .x = matrix.xx * point.x + matrix.xy * point.y, .y = matrix.yx * point.x + matrix.yy * point.y };
}
fn arcExtremum(result: *Accumulator, ellipse: arcs.Ellipse, angle: f64) !void {
    const distance = if (ellipse.sweep >= 0) @mod(angle - ellipse.start, 2 * std.math.pi) else @mod(ellipse.start - angle, 2 * std.math.pi);
    if (distance <= @abs(ellipse.sweep)) try result.add(ellipse.at(angle));
}
pub fn calculate(commands: []const api.Command, matrix: api.Transform, cancellation: ?*const api.Cancellation) !?Bounds {
    var result: Accumulator = .{};
    var pen: Point = .{};
    var start: Point = .{};
    for (commands) |command| {
        if (cancellation) |cancel| try cancel.check();
        switch (command) {
            .move => |point| {
                pen = point;
                start = point;
            },
            .line => |point| {
                try result.add(matrix.apply(pen));
                try result.add(matrix.apply(point));
                pen = point;
            },
            .close => {
                try result.add(matrix.apply(pen));
                try result.add(matrix.apply(start));
                pen = start;
            },
            .quadratic => |q| {
                const a = matrix.apply(pen);
                const b = matrix.apply(q.control);
                const c = matrix.apply(q.end);
                try result.add(a);
                try result.add(c);
                inline for (.{ "x", "y" }) |axis| {
                    const d0 = @field(b, axis) - @field(a, axis);
                    const d1 = @field(c, axis) - @field(b, axis);
                    if (d0 != d1) {
                        const t = d0 / (d0 - d1);
                        if (t > 0 and t < 1) try result.add(interpolate(interpolate(a, b, t), interpolate(b, c, t), t));
                    }
                }
                pen = q.end;
            },
            .cubic => |q| {
                const a = matrix.apply(pen);
                const b = matrix.apply(q.first);
                const c = matrix.apply(q.second);
                const e = matrix.apply(q.end);
                try result.add(a);
                try result.add(e);
                try cubicExtrema(&result, .{ a, b, c, e }, .{ a.x, b.x, c.x, e.x });
                try cubicExtrema(&result, .{ a, b, c, e }, .{ a.y, b.y, c.y, e.y });
                pen = q.end;
            },
            .arc => |arc| {
                switch (try arcs.resolve(pen, arc)) {
                    .none => {},
                    .line => |point| {
                        try result.add(matrix.apply(pen));
                        try result.add(matrix.apply(point));
                    },
                    .ellipse => |value| {
                        var ellipse = value;
                        ellipse.center = matrix.apply(value.center);
                        ellipse.x_axis = vector(matrix, value.x_axis);
                        ellipse.y_axis = vector(matrix, value.y_axis);
                        try result.add(matrix.apply(pen));
                        try result.add(matrix.apply(arc.end));
                        for ([_]f64{ std.math.atan2(ellipse.y_axis.x, ellipse.x_axis.x), std.math.atan2(ellipse.y_axis.y, ellipse.x_axis.y) }) |angle| {
                            try arcExtremum(&result, ellipse, angle);
                            try arcExtremum(&result, ellipse, angle + std.math.pi);
                        }
                    },
                }
                pen = arc.end;
            },
        }
    }
    return result.finish();
}
