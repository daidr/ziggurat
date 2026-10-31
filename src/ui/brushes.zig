const std = @import("std");
const geometry = @import("geometry.zig");
pub const color_interpolation = @import("gradient_color.zig");
pub const InterpolationSpace = color_interpolation.Space;
pub const Point = @import("layout.zig").Point;
pub const Color = geometry.Color;
pub const max_brushes = 32;
pub const max_stops = 16;
pub const Stop = struct { offset: f32, color: Color };
pub const Direction = enum { clockwise, counter_clockwise };
pub const Spread = enum(u8) { pad, repeat, reflect };
pub const max_angle_radians = 1048576 * (2 * std.math.pi);
pub const Gradient = union(enum) {
    linear: struct { start: Point, end: Point, stops: []const Stop, interpolation: InterpolationSpace = .srgb, spread: Spread = .pad },
    radial: struct { center: Point, radius: Point, stops: []const Stop, interpolation: InterpolationSpace = .srgb, spread: Spread = .pad },
    /// Zero is local +X; screen +Y is clockwise. Preparation normalizes and
    /// narrows the angle to f32. The exact center samples the outgoing seam.
    conic: struct { center: Point, start_angle_radians: f64 = 0, direction: Direction = .clockwise, stops: []const Stop, interpolation: InterpolationSpace = .srgb },

    pub fn translated(self: Gradient, offset: Point) Gradient {
        var copy = self;
        switch (copy) {
            .linear => |*linear| {
                linear.start.x += offset.x;
                linear.start.y += offset.y;
                linear.end.x += offset.x;
                linear.end.y += offset.y;
            },
            .radial => |*radial| {
                radial.center.x += offset.x;
                radial.center.y += offset.y;
            },
            .conic => |*conic| {
                conic.center.x += offset.x;
                conic.center.y += offset.y;
            },
        }
        return copy;
    }
};
pub const Error = error{ InvalidGradient, GradientStopsFull };
pub const Kind = enum(u32) { linear, radial, conic };
pub const NativeStop = extern struct { offset: f32, rgba: u32 };
pub const Native = extern struct { kind: u32, x0: f32, y0: f32, x1: f32, y1: f32, len: u32, stops: [max_stops]NativeStop };

/// A value snapshot. No pointer refers back into Buffer or the caller's stops.
pub const Stored = struct {
    kind: Kind,
    a: Point,
    b: Point,
    len: u8,
    interpolation: InterpolationSpace = .srgb,
    spread: Spread = .pad,
    stops: [max_stops]Stop = undefined,

    pub fn init(gradient: Gradient) Error!Stored {
        const stops = switch (gradient) {
            inline else => |value| value.stops,
        };
        if (stops.len > max_stops) return error.GradientStopsFull;
        if (stops.len < 2) return error.InvalidGradient;
        var stored: Stored = switch (gradient) {
            .linear => |value| .{ .kind = .linear, .a = value.start, .b = value.end, .len = @intCast(stops.len) },
            .radial => |value| .{ .kind = .radial, .a = value.center, .b = value.radius, .len = @intCast(stops.len) },
            .conic => |value| .{ .kind = .conic, .a = value.center, .b = .{ .x = try normalizedAngle(value.start_angle_radians), .y = if (value.direction == .clockwise) 1 else -1 }, .len = @intCast(stops.len) },
        };
        stored.interpolation = switch (gradient) {
            inline else => |value| value.interpolation,
        };
        stored.spread = switch (gradient) {
            inline .linear, .radial => |value| value.spread,
            .conic => .pad,
        };
        if (!finite(stored.a) or !finite(stored.b)) return error.InvalidGradient;
        if (stored.kind == .linear) {
            if (stored.a.x == stored.b.x and stored.a.y == stored.b.y) return error.InvalidGradient;
        } else if (stored.kind == .radial and (stored.b.x <= 0 or stored.b.y <= 0)) return error.InvalidGradient;
        var previous: f32 = 0;
        var count: usize = 0;
        for (stops, 0..) |stop, index| {
            if (!std.math.isFinite(stop.offset) or stop.offset < previous or stop.offset < 0 or stop.offset > 1) return error.InvalidGradient;
            if (index > 0 and stop.offset == previous) {
                if (std.meta.eql(stop.color, stored.stops[count - 1].color)) continue;
            }
            stored.stops[count] = stop;
            count += 1;
            previous = stop.offset;
        }
        if (count == 1) {
            stored.stops[0].offset = 0;
            stored.stops[1] = .{ .offset = 1, .color = stored.stops[0].color };
            count = 2;
        }
        stored.len = @intCast(count);
        return stored;
    }
    pub fn eql(a: *const Stored, b: *const Stored) bool {
        if (a.kind != b.kind or a.len != b.len or a.interpolation != b.interpolation or a.spread != b.spread or !std.meta.eql(a.a, b.a) or !std.meta.eql(a.b, b.b)) return false;
        for (a.stops[0..a.len], b.stops[0..b.len]) |left, right| if (left.offset != right.offset or !std.meta.eql(left.color, right.color)) return false;
        return true;
    }
    pub fn validate(self: *const Stored) Error!void {
        if (self.len > max_stops) return error.GradientStopsFull;
        if (self.len < 2) return error.InvalidGradient;
        _ = try Stored.init(switch (self.kind) {
            .linear => .{ .linear = .{ .start = self.a, .end = self.b, .stops = self.stops[0..self.len], .interpolation = self.interpolation, .spread = self.spread } },
            .radial => .{ .radial = .{ .center = self.a, .radius = self.b, .stops = self.stops[0..self.len], .interpolation = self.interpolation, .spread = self.spread } },
            .conic => blk: {
                if (self.spread != .pad or self.b.x < 0 or self.b.x >= @as(f32, 2 * std.math.pi) or (self.b.y != 1 and self.b.y != -1)) return error.InvalidGradient;
                break :blk .{ .conic = .{ .center = self.a, .start_angle_radians = self.b.x, .direction = if (self.b.y == 1) .clockwise else .counter_clockwise, .stops = self.stops[0..self.len], .interpolation = self.interpolation } };
            },
        });
    }
    pub fn isTransparent(self: *const Stored) bool {
        for (self.stops[0..self.len]) |stop| if (stop.color.a != 0) return false;
        return true;
    }
    /// Conservative analytic-GPU envelope. Hard/steep or discontinuous-seam
    /// inputs remain valid software gradients; no stop is moved or softened.
    pub fn conicGpuSupported(self: *const Stored, bounds: geometry.Rect, scale: f32) bool {
        if (self.kind != .conic or self.isTransparent()) return true;
        if (!std.math.isFinite(scale) or scale <= 0) return false;
        if (self.stops[0].offset != 0 or self.stops[self.len - 1].offset != 1 or !std.meta.eql(self.stops[0].color, self.stops[self.len - 1].color)) return false;
        for (self.stops[1..self.len], self.stops[0 .. self.len - 1]) |next, previous| if (@as(f64, next.offset) - previous.offset < 1.0 / 1024.0) return false;
        const ax = @as(f64, self.a.x) * scale;
        const ay = @as(f64, self.a.y) * scale;
        // Exact f32 centers keep a true center/half-pixel tie from moving to
        // another angle as constants are transferred to the shader.
        for ([_]f64{ ax, ay }) |value| {
            if (!std.math.isFinite(value) or @abs(value) > 65536) return false;
            const narrowed: f32 = @floatCast(value);
            if (@as(f64, narrowed) != value) return false;
        }
        for ([_]f64{ @as(f64, bounds.x) * scale, @as(f64, bounds.y) * scale, @as(f64, bounds.width) * scale, @as(f64, bounds.height) * scale }) |value| if (!std.math.isFinite(value) or @abs(value) > 65536) return false;
        return true;
    }
    pub fn native(self: *const Stored) Native {
        var result: Native = .{ .kind = @backingInt(self.kind), .x0 = self.a.x, .y0 = self.a.y, .x1 = self.b.x, .y1 = self.b.y, .len = self.len, .stops = @splat(.{ .offset = 0, .rgba = 0 }) };
        for (self.stops[0..self.len], result.stops[0..self.len]) |stop, *out| out.* = .{ .offset = stop.offset, .rgba = stop.color.rgba() };
        return result;
    }
    /// Low-level point query. Periodic modes require a finite projected
    /// binary64 parameter; arbitrary finite f64 points with a tiny radius or
    /// segment can exceed that domain. Raster callers use bounded f32 source
    /// geometry. Phase is defined by this computed parameter, not exact-real
    /// arithmetic or a high-frequency antialias/prefilter guarantee.
    pub fn sample(self: *const Stored, x: f64, y: f64) Sample {
        const t = if (self.spread != .pad) PeriodicProjection.init(self, 1).parameter(x, y) else value: {
            const dx = x - self.a.x;
            const dy = y - self.a.y;
            break :value switch (self.kind) {
                .linear => blk: {
                    const vx = @as(f64, self.b.x) - self.a.x;
                    const vy = @as(f64, self.b.y) - self.a.y;
                    break :blk (dx * vx + dy * vy) / (vx * vx + vy * vy);
                },
                .radial => @sqrt((dx / self.b.x) * (dx / self.b.x) + (dy / self.b.y) * (dy / self.b.y)),
                .conic => conicParameter(dx, dy, self.b.x, self.b.y),
            };
        };
        // Upper bound makes repeated stops right-continuous: the final stop
        // at an equal offset owns the sample exactly at that offset.
        var low: usize = 0;
        var high: usize = self.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.stops[middle].offset <= t) low = middle + 1 else high = middle;
        }
        if (low == 0) return Sample.from(self.stops[0].color);
        if (low == self.len) return Sample.from(self.stops[self.len - 1].color);
        const before = self.stops[low - 1];
        const after = self.stops[low];
        const weight = (t - before.offset) / (@as(f64, after.offset) - before.offset);
        if (self.interpolation != .srgb) {
            if (t == before.offset) return Sample.from(before.color);
            return Sample.fromEncoded(color_interpolation.Coordinates.mix(.fromColor(self.interpolation, before.color), .fromColor(self.interpolation, after.color), weight).encoded(self.interpolation));
        }
        const a = Sample.from(before.color);
        const b = Sample.from(after.color);
        return .{ .r = a.r + (b.r - a.r) * weight, .g = a.g + (b.g - a.g) * weight, .b = a.b + (b.b - a.b) * weight, .a = a.a + (b.a - a.a) * weight };
    }
};

/// Private per-command value used by the scalar query and software raster.
/// Scale1 accepts local coordinates; other scales accept physical source
/// coordinates. Construct once outside the raster loop. No persistent owner.
pub const PeriodicProjection = struct {
    kind: Kind,
    spread: Spread,
    ax: f64,
    ay: f64,
    vx: f64,
    vy: f64,
    length: f64,
    pub fn init(stored: *const Stored, scale: f64) PeriodicProjection {
        std.debug.assert(stored.kind != .conic and stored.spread != .pad);
        const ax = @as(f64, stored.a.x) * scale;
        const ay = @as(f64, stored.a.y) * scale;
        const vx = @as(f64, stored.b.x) * scale - (if (stored.kind == .linear) ax else 0);
        const vy = @as(f64, stored.b.y) * scale - (if (stored.kind == .linear) ay else 0);
        return .{ .kind = stored.kind, .spread = stored.spread, .ax = ax, .ay = ay, .vx = vx, .vy = vy, .length = vx * vx + vy * vy };
    }
    pub fn parameter(self: PeriodicProjection, x: f64, y: f64) f64 {
        const dx = x - self.ax;
        const dy = y - self.ay;
        const t = if (self.kind == .linear) (dx * self.vx + dy * self.vy) / self.length else @sqrt((dx / self.vx) * (dx / self.vx) + (dy / self.vy) * (dy / self.vy));
        std.debug.assert(std.math.isFinite(t));
        return spreadParameter(self.spread, t);
    }
};

/// Fold a finite, already-projected gradient parameter. No integer conversion
/// or iteration depends on period count. Reflection uses |t| so a negative
/// subnormal never needs the unrepresentable sum 2-|t|. Repeat stays below1
/// even when rounding 1-fraction would land on the other side of a hard seam.
pub fn spreadParameter(spread: Spread, parameter: f64) f64 {
    if (spread == .pad) return parameter;
    const magnitude = @abs(parameter);
    if (spread == .reflect) {
        const phase = magnitude - 2 * @floor(magnitude * 0.5);
        return if (phase <= 1) phase else 2 - phase;
    }
    const fraction = magnitude - @floor(magnitude);
    if (parameter >= 0 or fraction == 0) return fraction;
    const reversed = 1 - fraction;
    return if (reversed == 1) std.math.nextAfter(f64, 1, 0) else reversed;
}

/// Premultiplied encoded RGB in 0..255 and alpha in 0..1.
pub const Sample = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
    pub fn from(color: Color) Sample {
        const alpha = @as(f64, @floatFromInt(color.a)) / 255;
        return .{ .r = @as(f64, @floatFromInt(color.r)) * alpha, .g = @as(f64, @floatFromInt(color.g)) * alpha, .b = @as(f64, @floatFromInt(color.b)) * alpha, .a = alpha };
    }
    pub fn fromEncoded(value: color_interpolation.Encoded) Sample {
        return .{ .r = value.channels[0], .g = value.channels[1], .b = value.channels[2], .a = value.alpha };
    }
    pub fn over(self: Sample, background: u32, coverage: u8) u32 {
        const mask = @as(f64, @floatFromInt(coverage)) / 255;
        const inverse = 1 - self.a * mask;
        const red: u32 = @intFromFloat(@min(255, @max(0, @round(self.r * mask + @as(f64, @floatFromInt((background >> 16) & 255)) * inverse))));
        const green: u32 = @intFromFloat(@min(255, @max(0, @round(self.g * mask + @as(f64, @floatFromInt((background >> 8) & 255)) * inverse))));
        const blue: u32 = @intFromFloat(@min(255, @max(0, @round(self.b * mask + @as(f64, @floatFromInt(background & 255)) * inverse))));
        return 0xff000000 | (red << 16) | (green << 8) | blue;
    }
    pub fn overAlpha(self: Sample, background: u32, coverage: u8) u32 {
        const alpha = self.a * @as(f64, @floatFromInt(coverage)) / 255;
        const result: u32 = @intFromFloat(std.math.clamp(@round(alpha * 255 + @as(f64, @floatFromInt(background >> 24)) * (1 - alpha)), 0, 255));
        return (self.over(background, coverage) & 0xffffff) | (result << 24);
    }
};
fn finite(point: Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

test "interpolation is part of owned brush identity and public samples remain encoded" {
    const stops = [_]Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.5, .color = .rgb(0x112233) }, .{ .offset = 0.5, .color = .{ .r = 200, .g = 20, .b = 240, .a = 123 } }, .{ .offset = 1, .color = .rgb(0xffffff) } };
    var previous: ?Stored = null;
    for ([_]InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        const value: Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &stops, .interpolation = space } };
        const stored = try Stored.init(value);
        try stored.validate();
        try std.testing.expectEqual(space, value.translated(.{ .x = 3 }).linear.interpolation);
        try std.testing.expectEqual(Sample.from(stops[0].color), stored.sample(-1, 0));
        try std.testing.expectEqual(Sample.from(stops[2].color), stored.sample(0.5, 0));
        try std.testing.expectEqual(Sample.from(stops[3].color), stored.sample(2, 0));
        if (previous) |other| try std.testing.expect(!stored.eql(&other));
        previous = stored;
        const midpoint = try Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &.{ stops[0], stops[3] }, .interpolation = space } });
        const expected: u32 = switch (space) {
            .srgb => 0xff808080,
            .srgb_linear => 0xffbcbcbc,
            .oklab => 0xff636363,
        };
        try std.testing.expectEqual(expected, midpoint.sample(0.5, 0).over(0, 255));
    }
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(Stored));
    try std.testing.expectEqual(@as(usize, 4864), @sizeOf([max_brushes]Stored));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(Native));
}

fn normalizedAngle(value: f64) Error!f32 {
    if (!std.math.isFinite(value) or @abs(value) > max_angle_radians) return error.InvalidGradient;
    const angle: f32 = @floatCast(@mod(value, 2 * std.math.pi));
    // Narrowing just below a complete turn can round up to the seam.
    return if (angle == 0 or angle >= @as(f32, 2 * std.math.pi)) 0 else angle;
}

/// Periodic half-open parameter. A rounded incoming limit remains strictly
/// below one: stops at one never replace the outgoing stop at zero.
pub fn conicParameter(dx: f64, dy: f64, angle: f32, direction: f32) f64 {
    if (dx == 0 and dy == 0) return 0;
    const turns = (std.math.atan2(dy, dx) - @as(f64, angle)) * (@as(f64, direction) / (2 * std.math.pi));
    const t = turns - @floor(turns);
    return if (t >= 1) std.math.nextAfter(f64, 1, 0) else if (t == 0) 0 else t;
}

test "gradients interpolate premultiplied encoded RGB and duplicate stops have a defined side" {
    var stops = [_]Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = Color.rgb(0x0000ff) } };
    const stored = try Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 100 }, .stops = &stops } });
    stops[0].color = Color.rgb(0xff0000);
    try std.testing.expectEqual(@as(u32, 0xff8080ff), stored.sample(50, 0).over(0xffffff, 255));
    const duplicate = try Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 100 }, .stops = &.{ .{ .offset = 0.5, .color = Color.rgb(0xff0000) }, .{ .offset = 0.5, .color = Color.rgb(0x00ff00) }, .{ .offset = 0.5, .color = Color.rgb(0x0000ff) } } } });
    try std.testing.expectEqual(@as(u32, 0xffff0000), duplicate.sample(49, 0).over(0, 255));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), duplicate.sample(50, 0).over(0, 255));
}

test "gradient geometry and stop validation has explicit finite bounds" {
    const stops = [_]Stop{ .{ .offset = 0, .color = Color.rgb(0) }, .{ .offset = 1, .color = Color.rgb(0xffffff) } };
    try std.testing.expectError(error.InvalidGradient, Stored.init(.{ .linear = .{ .start = .{ .x = std.math.nan(f32) }, .end = .{ .x = 1 }, .stops = &stops } }));
    try std.testing.expectError(error.InvalidGradient, Stored.init(.{ .radial = .{ .center = .{}, .radius = .{ .x = 1, .y = std.math.inf(f32) }, .stops = &stops } }));
    try std.testing.expectError(error.InvalidGradient, Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = stops[0..1] } }));
    var invalid = stops;
    invalid[0].offset = 0.75;
    invalid[1].offset = 0.25;
    try std.testing.expectError(error.InvalidGradient, Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &invalid } }));
    var full: [max_stops]Stop = undefined;
    for (&full, 0..) |*stop, index| stop.* = .{ .offset = @as(f32, @floatFromInt(index)) / (max_stops - 1), .color = Color.rgb(@intCast(index)) };
    const stored = try Stored.init(.{ .radial = .{ .center = .{}, .radius = .{ .x = 1, .y = 2 }, .stops = &full } });
    try std.testing.expectEqual(max_stops, stored.len);
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(Native));
}

test "conic cardinal direction center half turns and repeated endpoints have literal colors" {
    const stops = [_]Stop{
        .{ .offset = 0, .color = .rgb(0xff0000) },
        .{ .offset = 0.25, .color = .rgb(0x00ff00) },
        .{ .offset = 0.5, .color = .rgb(0x0000ff) },
        .{ .offset = 0.75, .color = .rgb(0xffffff) },
        .{ .offset = 1, .color = .rgb(0x000000) },
    };
    const cw = try Stored.init(.{ .conic = .{ .center = .{}, .stops = &stops } });
    const ccw = try Stored.init(.{ .conic = .{ .center = .{}, .direction = .counter_clockwise, .stops = &stops } });
    for ([_][3]f64{ .{ 1, 0, 0xff0000 }, .{ 0, 1, 0x00ff00 }, .{ -1, 0, 0x0000ff }, .{ 0, -1, 0xffffff }, .{ 0, 0, 0xff0000 }, .{ 1, -0.0, 0xff0000 }, .{ 1, 1, 0x808000 } }) |entry| {
        try std.testing.expectEqual(@as(u32, 0xff000000) | @as(u32, @intFromFloat(entry[2])), cw.sample(entry[0], entry[1]).over(0, 255));
    }
    try std.testing.expectEqual(@as(u32, 0xffffffff), ccw.sample(0, 1).over(0, 255));
    const edge = try Stored.init(.{ .conic = .{ .center = .{}, .stops = &.{
        .{ .offset = 0, .color = .rgb(0xff0000) },
        .{ .offset = 0, .color = .rgb(0x00ff00) },
        .{ .offset = 1, .color = .rgb(0x0000ff) },
        .{ .offset = 1, .color = .rgb(0xffffff) },
    } } });
    try std.testing.expectEqual(@as(u32, 0xff00ff00), edge.sample(1, 0).over(0, 255));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), edge.sample(1, -1e-30).over(0, 255));
    const translucent = try Stored.init(.{ .conic = .{ .center = .{}, .stops = &.{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 1, .color = .rgb(0x0000ff) },
    } } });
    try std.testing.expectEqual(@as(u32, 0xff8080ff), translucent.sample(-1, 0).over(0xffffff, 255));
}

test "conic angle preparation normalizes bounded turns without changing ABI or borrowed inputs" {
    const stops = [_]Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
    inline for (.{ @as(f64, -0.0), 2 * std.math.pi, -4 * std.math.pi, 2048 * std.math.pi }) |angle| {
        const stored = try Stored.init(.{ .conic = .{ .center = .{}, .start_angle_radians = angle, .stops = &stops } });
        try std.testing.expectEqual(@as(f32, 0), stored.b.x);
        try std.testing.expect(!std.math.signbit(stored.b.x));
        try stored.validate();
    }
    inline for (.{ std.math.inf(f64), std.math.nan(f64), max_angle_radians * 2 }) |angle| try std.testing.expectError(error.InvalidGradient, Stored.init(.{ .conic = .{ .center = .{}, .start_angle_radians = angle, .stops = &stops } }));
    const translated = Gradient.translated(.{ .conic = .{ .center = .{ .x = 1, .y = 2 }, .start_angle_radians = 1, .stops = &stops } }, .{ .x = 4, .y = 8 });
    try std.testing.expectEqual(Point{ .x = 5, .y = 10 }, translated.conic.center);
    try std.testing.expectEqual(@as(f64, 1), translated.conic.start_angle_radians);
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(Native));
}

test "conic analytic envelope rejects hard steep seam and inexact large physical centers before drawing" {
    const rect: geometry.Rect = .{ .x = 0, .y = 0, .width = 64, .height = 64 };
    const stops = [_]Stop{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 0.5, .color = .rgb(0x0000ff) }, .{ .offset = 1, .color = .rgb(0xff0000) } };
    var stored = try Stored.init(.{ .conic = .{ .center = .{ .x = 32, .y = 32 }, .stops = &stops } });
    for ([_]f32{ 1, 1.5, 2 }) |scale| try std.testing.expect(stored.conicGpuSupported(rect, scale));
    stored.stops[2].color = .rgb(0x00ff00);
    try std.testing.expect(!stored.conicGpuSupported(rect, 1));
    stored.stops[2].color = stops[2].color;
    stored.stops[1].offset = 0;
    try std.testing.expect(!stored.conicGpuSupported(rect, 1));
    stored.stops[1].offset = 1.0 / 2048.0;
    try std.testing.expect(!stored.conicGpuSupported(rect, 1));
    stored.stops[1].offset = 0.5;
    stored.a.x = 0.1;
    try std.testing.expect(!stored.conicGpuSupported(rect, 1.5));
    stored.a.x = 65537;
    try std.testing.expect(!stored.conicGpuSupported(rect, 1));
    stored.a.x = 32;
    try std.testing.expect(stored.conicGpuSupported(rect, 1));
    try std.testing.expect(!stored.conicGpuSupported(.{ .x = 0, .y = 0, .width = 1000000, .height = 64 }, 1));
}
