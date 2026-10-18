const std = @import("std");
const v = @import("ziggurat_vector");
const d = @import("document.zig");
const refs = @import("references.zig");
const names = @import("names.zig");
const n = @import("numbers.zig");
const s = @import("style.zig");
const css = @import("css.zig");
const paints = @import("paint.zig");
const shapes = @import("shape.zig");
const parsing = @import("parse_work.zig");
const radial_math = @import("radial_math.zig");
pub const max_stops = 64;
const Stop = struct { offset: f64, channels: [4]f64 };
const Spread = enum { pad, repeat, reflect };
const Kind = union(enum) { linear: struct { start: v.Point, delta: v.Point, denominator: f64 }, radial: Radial };
const Parameter = union(enum) { value: f64, transparent, limit };
const Radial = struct {
    focus: v.Point,
    delta: v.Point,
    first_radius: f64,
    radius_delta: f64,
    unit: f64,
    quadratic: f64,
    focal_tangent: bool,
    fn init(focus: v.Point, center: v.Point, first: f64, last: f64) !Radial {
        const difference_x = try radial_math.subtract(center.x, focus.x);
        const difference_y = try radial_math.subtract(center.y, focus.y);
        const difference_r = try radial_math.subtract(last, first);
        const dx = difference_x.value;
        const dy = difference_y.value;
        const dr = difference_r.value;
        const extent = @max(@abs(dx), @abs(dy), first, last);
        if (extent == 0 or !std.math.isFinite(extent)) return error.UnsupportedRadialPrecision;
        const unit = std.math.ldexp(@as(f64, 1), std.math.frexp(extent).exponent - 1);
        // A power-of-two normalized scale avoids squaring tiny radii to zero or
        // overflowing distant centers. Classify its sign/zero before rastering;
        // a rounded square sum must not turn an external focus into a tangent.
        const nx = dx / unit;
        const ny = dy / unit;
        const nr = dr / unit;
        const a = try radial_math.quadratic(difference_x, difference_y, difference_r, unit);
        // SVG specifies the point-focus tangent limit. The corresponding
        // nonzero-circle common-tangent singularity has no public contract here.
        if (first > 0 and a == 0) return error.UnsupportedRadialFocus;
        return .{ .focus = focus, .delta = .{ .x = nx, .y = ny }, .first_radius = first / unit, .radius_delta = nr, .unit = unit, .quadratic = a, .focal_tangent = first == 0 and a == 0 and dr > 0 };
    }
    fn parameter(self: Radial, point: v.Point) !Parameter {
        const x = (point.x - self.focus.x) / self.unit;
        const y = (point.y - self.focus.y) / self.unit;
        if (self.delta.x == 0 and self.delta.y == 0) return .{ .value = (std.math.hypot(x, y) - self.first_radius) / self.radius_delta };
        const a = self.quadratic;
        const b = -2 * @mulAdd(f64, x, self.delta.x, @mulAdd(f64, y, self.delta.y, self.first_radius * self.radius_delta));
        const c = @mulAdd(f64, x, x, @mulAdd(f64, y, y, -self.first_radius * self.first_radius));
        if (!std.math.isFinite(b) or !std.math.isFinite(c)) return error.UnsupportedRadialPrecision;
        var candidates: [2]f64 = undefined;
        var count: usize = 0;
        if (a == 0) {
            if (b == 0) return if (self.focal_tangent) .limit else .transparent;
            candidates[0] = -c / b;
            count = 1;
        } else {
            const discriminant = @mulAdd(f64, -4 * a, c, b * b);
            if (!std.math.isFinite(discriminant)) return error.UnsupportedRadialPrecision;
            if (discriminant < 0) return .transparent;
            const q = -0.5 * (b + std.math.copysign(@sqrt(discriminant), b));
            candidates[0] = q / a;
            candidates[1] = if (q == 0) candidates[0] else c / q;
            count = 2;
        }
        var best: ?f64 = null;
        for (candidates[0..count]) |candidate| {
            if (!std.math.isFinite(candidate)) return error.UnsupportedRadialPrecision;
            // Negative-radius roots describe the other cone nappe and must
            // never color this point. Zero-radius apices retain their limit.
            if (@mulAdd(f64, candidate, self.radius_delta, self.first_radius) < 0) continue;
            if (best == null or candidate > best.?) best = candidate;
        }
        if (best) |value| return .{ .value = value };
        return if (self.focal_tangent) .limit else .transparent;
    }
};
pub const Resolved = struct {
    stops: [max_stops]Stop = undefined,
    count: usize = 0,
    inverse: ?v.Transform = null,
    kind: Kind = .{ .linear = .{ .start = .{}, .delta = .{}, .denominator = 0 } },
    spread: Spread = .pad,
    interpolation: s.Interpolation = .srgb,
    average: [4]f64 = @splat(0),
    pub fn sample(self: *const Resolved, point: v.Point) ![4]f64 {
        if (self.count == 0) return @splat(0);
        const map = self.inverse orelse return @splat(0);
        const p = map.apply(point);
        var t: f64 = switch (self.kind) {
            .linear => |line| if (line.denominator == 0) 1 else ((p.x - line.start.x) * line.delta.x + (p.y - line.start.y) * line.delta.y) / line.denominator,
            .radial => |radial| switch (try radial.parameter(p)) {
                .value => |value| value,
                .transparent => return @splat(0),
                .limit => {
                    if (self.spread == .pad) return self.convert(self.stops[self.count - 1].channels);
                    return self.convert(self.average);
                },
            },
        };
        if (!std.math.isFinite(t)) return error.UnsupportedGradientPrecision;
        const constant = self.kind == .linear and self.kind.linear.denominator == 0;
        if (!constant) switch (self.spread) {
            .pad => t = std.math.clamp(t, 0, 1),
            .repeat => {
                if (@abs(t) > 0x1p48) return error.UnsupportedGradientPrecision;
                t = @mod(t, 1);
            },
            .reflect => {
                if (@abs(t) > 0x1p48) return error.UnsupportedGradientPrecision;
                const period = @mod(t, 2);
                t = if (period <= 1) period else 2 - period;
            },
        };
        var left: usize = 0;
        var right = self.count;
        while (left < right) {
            const middle = left + (right - left) / 2;
            if (self.stops[middle].offset <= t) left = middle + 1 else right = middle;
        }
        var channels: [4]f64 = undefined;
        if (left == 0) channels = self.stops[0].channels else if (left == self.count) channels = self.stops[self.count - 1].channels else {
            const a = self.stops[left - 1];
            const b = self.stops[left];
            const amount = (t - a.offset) / (b.offset - a.offset);
            for (&channels, a.channels, b.channels) |*channel, first, last| channel.* = first * (1 - amount) + last * amount;
        }
        return self.convert(channels);
    }
    fn convert(self: *const Resolved, straight: [4]f64) [4]f64 {
        // SVG interpolates straight colors. Premultiplication follows the
        // interpolation (including the degenerate repeating-circle average).
        var channels = straight;
        for (channels[0..3]) |*channel| {
            if (self.interpolation == .linear_rgb) channel.* = encode(channel.*);
            channel.* *= channels[3] * 255;
        }
        channels[3] *= 255;
        return channels;
    }
    fn computeAverage(self: *Resolved) void {
        if (self.count == 0) return;
        var left = self.stops[0];
        for (&self.average, left.channels) |*channel, value| channel.* = value * left.offset;
        for (self.stops[1..self.count]) |right| {
            for (&self.average, left.channels, right.channels) |*channel, a, b| channel.* += (a + b) * 0.5 * (right.offset - left.offset);
            left = right;
        }
        for (&self.average, left.channels) |*channel, value| channel.* += value * (1 - left.offset);
        // Preserve constant components exactly. In particular, constant RGB
        // with changing alpha has one unambiguous premultiplied period mean.
        for (0..4) |component| {
            const first = self.stops[0].channels[component];
            var constant = true;
            for (self.stops[1..self.count]) |stop| if (stop.channels[component] != first) {
                constant = false;
                break;
            };
            if (constant) self.average[component] = first;
        }
    }
};
pub const Source = struct {
    reject_object_bounds: bool = false,
    nodes: []const d.Node,
    references: *const refs.Index,
    sheet: *const css.Sheet,
    style_work: *css.Work,
    parse_work: *parsing.Work,
    node_visits: *usize,
    node_limit: usize,
    reference_depth: usize,
    stops: usize,
    current_color: paints.Color,
    cancellation: ?*const v.Cancellation,
    fn visit(self: Source) !void {
        if (self.cancellation) |cancel| try cancel.check();
        if (self.node_visits.* == self.node_limit) return error.NodeWorkExceeded;
        self.node_visits.* += 1;
    }
    fn computed(self: Source, index: usize) !s.Style {
        var ancestors: [64]usize = undefined;
        var count: usize = 0;
        var at: ?usize = index;
        while (at) |node| {
            if (count == ancestors.len) return error.RenderDepthFull;
            ancestors[count] = node;
            count += 1;
            at = self.nodes[node].parent;
        }
        var style: s.Style = .{ .color = self.current_color };
        while (count != 0) {
            try self.visit();
            count -= 1;
            const node = ancestors[count];
            try self.parse_work.node(self.nodes[node]);
            style = try self.sheet.derive(style, self.nodes[node], try names.localName(self.nodes, node), self.style_work);
        }
        return style;
    }
    pub fn compile(self: Source, index: usize, viewport: shapes.Viewport, bounds: ?v.Bounds, outer: v.Transform) !Resolved {
        if (self.stops == 0 or self.stops > max_stops) return error.InvalidGradientLimits;
        const kind = try names.localName(self.nodes, index);
        const linear = std.mem.eql(u8, kind, "linearGradient");
        if (!linear and !std.mem.eql(u8, kind, "radialGradient")) return error.UnsupportedPaintReference;
        const keys = [_][]const u8{ "gradientUnits", "gradientTransform", "spreadMethod", "x1", "y1", "x2", "y2", "cx", "cy", "r", "fx", "fy", "fr" };
        var attributes: [keys.len]?[]const u8 = @splat(null);
        var chain: [32]usize = undefined;
        var count: usize = 0;
        var current = index;
        var stop_parent: ?usize = null;
        while (true) {
            try self.visit();
            if (count == self.reference_depth or count == chain.len) return error.ReferenceDepthFull;
            for (chain[0..count]) |previous| if (previous == current) return error.ReferenceCycle;
            chain[count] = current;
            count += 1;
            const node = self.nodes[current];
            try self.parse_work.node(node);
            const name = try names.localName(self.nodes, current);
            if (!std.mem.eql(u8, name, "linearGradient") and !std.mem.eql(u8, name, "radialGradient")) return error.UnsupportedPaintReference;
            inline for (keys, 0..) |key, i| if (attributes[i] == null) {
                attributes[i] = node.attribute(key);
            };
            if (stop_parent == null) {
                var child = node.first_child;
                while (child) |at| {
                    try self.visit();
                    const value = self.nodes[at];
                    if (value.kind == .element and std.mem.eql(u8, try names.localName(self.nodes, at), "stop")) {
                        stop_parent = current;
                        break;
                    }
                    child = value.next_sibling;
                }
            }
            if (node.attribute("href") == null and node.attribute("xlink:href") == null) break;
            current = self.references.find(try refs.href(self.nodes, current)) orelse return error.ReferenceNotFound;
        }
        var result: Resolved = .{};
        const gradient_style = try self.computed(index);
        result.interpolation = gradient_style.interpolation;
        if (attributes[2]) |spread| result.spread = if (std.mem.eql(u8, spread, "pad")) .pad else if (std.mem.eql(u8, spread, "repeat")) .repeat else if (std.mem.eql(u8, spread, "reflect")) .reflect else return error.InvalidSpreadMethod;
        if (stop_parent) |parent| {
            var child = self.nodes[parent].first_child;
            while (child) |at| {
                try self.visit();
                const node = self.nodes[at];
                child = node.next_sibling;
                if (node.kind != .element or !std.mem.eql(u8, try names.localName(self.nodes, at), "stop")) continue;
                if (result.count == self.stops) return error.GradientStopsFull;
                const style = try self.computed(at);
                const color = switch (style.stop_color) {
                    .color => |color| color,
                    .current_color => style.color,
                    .none => unreachable,
                };
                const offset = try paints.opacity(node.attribute("offset") orelse "0");
                const normalized = if (result.count == 0) offset else @max(result.stops[result.count - 1].offset, offset);
                var channels: [4]f64 = .{ @as(f64, @floatFromInt(color.b)) / 255, @as(f64, @floatFromInt(color.g)) / 255, @as(f64, @floatFromInt(color.r)) / 255, @as(f64, @floatFromInt(color.a)) / 255 * style.stop_opacity };
                if (result.interpolation == .linear_rgb) for (channels[0..3]) |*channel| {
                    channel.* = decode(channel.*);
                };
                result.stops[result.count] = .{ .offset = normalized, .channels = channels };
                result.count += 1;
            }
        }
        result.computeAverage();
        const units = attributes[0] orelse "objectBoundingBox";
        const object = std.mem.eql(u8, units, "objectBoundingBox");
        if (object and self.reject_object_bounds) return error.UnsupportedTextBoundingBox;
        if (!object and !std.mem.eql(u8, units, "userSpaceOnUse")) return error.InvalidGradientUnits;
        var matrix = outer;
        var reference = viewport;
        if (object) {
            const box = bounds orelse return result;
            if (box.width == 0 or box.height == 0) return result;
            matrix = (v.Transform{ .xx = box.width, .yy = box.height, .x0 = box.x, .y0 = box.y }).then(matrix);
            reference = .{ .width = 1, .height = 1 };
        }
        if (attributes[1]) |value| matrix = (try n.transform(value)).then(matrix);
        result.inverse = try inverse(matrix);
        if (linear) {
            const start: v.Point = .{ .x = try coordinate(attributes[3], "0%", reference.width, object), .y = try coordinate(attributes[4], "0%", reference.height, object) };
            const end: v.Point = .{ .x = try coordinate(attributes[5], "100%", reference.width, object), .y = try coordinate(attributes[6], "0%", reference.height, object) };
            const delta: v.Point = .{ .x = end.x - start.x, .y = end.y - start.y };
            const denominator = delta.x * delta.x + delta.y * delta.y;
            if (denominator == 0 and (delta.x != 0 or delta.y != 0)) return error.UnsupportedGradientPrecision;
            result.kind = .{ .linear = .{ .start = start, .delta = delta, .denominator = denominator } };
        } else {
            const diagonal = std.math.hypot(reference.width, reference.height) / @sqrt(@as(f64, 2));
            const center: v.Point = .{ .x = try coordinate(attributes[7], "50%", reference.width, object), .y = try coordinate(attributes[8], "50%", reference.height, object) };
            const radius = try coordinate(attributes[9], "50%", diagonal, object);
            const focus: v.Point = .{ .x = if (attributes[10] != null) try coordinate(attributes[10], "0", reference.width, object) else center.x, .y = if (attributes[11] != null) try coordinate(attributes[11], "0", reference.height, object) else center.y };
            const first_radius = try coordinate(attributes[12], "0", diagonal, object);
            if (radius < 0 or first_radius < 0) return error.InvalidRadialRadius;
            if (radius == 0) {
                result.kind = .{ .linear = .{ .start = .{}, .delta = .{}, .denominator = 0 } };
                return result;
            }
            if (focus.x == center.x and focus.y == center.y and first_radius == radius) {
                result.count = 0;
                return result;
            }
            result.kind = .{ .radial = try Radial.init(focus, center, first_radius, radius) };
            if (result.kind.radial.focal_tangent and result.spread != .pad and result.count > 1) {
                // Constant alpha, or constant RGB with varying alpha, makes
                // the weighted mean independent of premultiplication order.
                // A general varying RGB+alpha period still has no contract.
                const alpha = result.stops[0].channels[3];
                const rgb = result.stops[0].channels[0..3];
                var same_alpha = true;
                var same_rgb = true;
                for (result.stops[1..result.count]) |stop| {
                    if (stop.channels[3] != alpha) same_alpha = false;
                    for (rgb, stop.channels[0..3]) |a, b| if (a != b) {
                        same_rgb = false;
                    };
                }
                if (!same_alpha and !same_rgb) return error.UnsupportedRadialAverage;
            }
        }
        return result;
    }
};
fn coordinate(input: ?[]const u8, fallback: []const u8, reference: f64, object: bool) !f64 {
    const value = input orelse fallback;
    if (object) {
        var scan: n.Scanner = .{ .input = value };
        _ = scan.space();
        _ = try scan.number();
        if (scan.at < value.len and value[scan.at] == '%') scan.at += 1;
        _ = scan.space();
        if (scan.at != value.len) return error.UnsupportedBoundingBoxUnit;
    }
    return try (try n.length(value)).resolve(reference);
}
fn inverse(matrix: v.Transform) !?v.Transform {
    const determinant = matrix.xx * matrix.yy - matrix.xy * matrix.yx;
    if (determinant == 0) return null;
    const result: v.Transform = .{ .xx = matrix.yy / determinant, .xy = -matrix.xy / determinant, .yx = -matrix.yx / determinant, .yy = matrix.xx / determinant, .x0 = (matrix.xy * matrix.y0 - matrix.yy * matrix.x0) / determinant, .y0 = (matrix.yx * matrix.x0 - matrix.xx * matrix.y0) / determinant };
    inline for (std.meta.fields(v.Transform)) |field| if (!std.math.isFinite(@field(result, field.name)) or @abs(@field(result, field.name)) > 1e15) return error.UnsupportedGradientPrecision;
    return result;
}
fn decode(value: f64) f64 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}
fn encode(value: f64) f64 {
    // Preserve the exact sRGB endpoints, including half-alpha tie rounding.
    if (value == 0 or value == 1) return value;
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
}
