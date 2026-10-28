const std = @import("std");
const brushes = @import("brushes.zig");
const geometry = @import("geometry.zig");
pub const Stats = extern struct {
    /// Conservative owner-storage reservation. After loss only the stable
    /// control/factory owner remains; driver JIT/cache storage is not counted.
    metadata_reserved: u64 = 0,
    metadata_actual: u64 = 0,
    constant_uploads: u64 = 0,
    ready: u32 = 0,
    effect_creations: u32 = 0,
    draws: u32 = 0,
    device_losses: u32 = 0,
};

/// Synchronously copied by the optional program. The ordinary encoded-RGB
/// entry point and its 624-byte constants never receive this packet.
pub const Packet = extern struct {
    space: u32,
    len: u32,
    reserved: [2]u32 = .{ 0, 0 },
    colors: [brushes.max_stops][4]f32 = @splat(.{ 0, 0, 0, 0 }),

    pub fn prepare(brush: *const brushes.Stored) Packet {
        std.debug.assert(brush.interpolation != .srgb);
        var packet: Packet = .{ .space = @backingInt(brush.interpolation), .len = brush.len };
        for (brush.stops[0..brush.len], packet.colors[0..brush.len]) |stop, *out| {
            const value = brushes.color_interpolation.Coordinates.fromColor(brush.interpolation, stop.color);
            for (out[0..3], value.channels) |*channel, coordinate| channel.* = @floatCast(coordinate);
            out[3] = @floatCast(value.alpha);
        }
        return packet;
    }
};

/// Source-plane numeric profile. Groups, fractional clips and prepared affine
/// scopes use the same physical raster; their composition has its own gate.
/// This does not promise arbitrary finite geometry or angular discontinuities.
pub fn supports(brush: *const brushes.Stored, shape: geometry.Plan, scale: f32) bool {
    if (brush.spread != .pad and !brush.isTransparent()) return false;
    if (brush.interpolation == .srgb) return true;
    if (!std.math.isFinite(scale) or scale < 0.0625 or scale > 16) return false;
    const ax = @as(f64, brush.a.x) * scale;
    const ay = @as(f64, brush.a.y) * scale;
    for ([_]f64{ ax, ay, @as(f64, shape.bounds.x) * scale, @as(f64, shape.bounds.y) * scale, (@as(f64, shape.bounds.x) + shape.bounds.width) * scale, (@as(f64, shape.bounds.y) + shape.bounds.height) * scale }) |value| if (!physicalCoordinate(value)) return false;
    const bx = @as(f64, brush.b.x) * scale;
    const by = @as(f64, brush.b.y) * scale;
    var span: f64 = undefined;
    switch (brush.kind) {
        .linear => {
            if (!physicalCoordinate(bx) or !physicalCoordinate(by)) return false;
            span = @sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
            if (span < 8) return false;
        },
        .radial => {
            if (!physicalCoordinate(bx) or !physicalCoordinate(by) or bx < 4 or by < 4) return false;
            span = @min(bx, by);
        },
        .conic => {
            // A discontinuous seam or a center moved by narrowing remains a
            // valid software gradient, rather than changing the angle rule.
            if (!brush.conicGpuSupported(shape.bounds, scale)) return false;
            span = 1;
        },
    }
    var previous: f64 = 0;
    var minimum_gap = std.math.inf(f64);
    var exact_axis = brush.kind == .linear and ((ax == bx) != (ay == by)) and
        halfGrid(ax) and halfGrid(ay) and halfGrid(bx) and halfGrid(by);
    for (brush.stops[0..brush.len], 0..) |stop, index| {
        const position = @as(f64, stop.offset) * span;
        exact_axis = exact_axis and position * 64 == @floor(position * 64);
        if (index != 0) {
            const distance = position - previous;
            if (distance == 0) {
                // Exact axis projections preserve hard-stop side ownership.
                // Curved/oblique discontinuities retain software precision.
                if (brush.kind != .linear or ((ax == bx) == (ay == by)) or
                    !halfGrid(ax) or !halfGrid(ay) or !halfGrid(bx) or !halfGrid(by) or
                    position * 64 != @floor(position * 64)) return false;
            } else {
                if (distance < (if (brush.kind == .conic) @as(f64, 0.0009765625) else 0.125)) return false;
                minimum_gap = @min(minimum_gap, distance);
            }
        }
        previous = position;
    }
    const weight_error = switch (brush.kind) {
        .linear => if (exact_axis) 12 * unit_roundoff else linearWeightError(ax, ay, bx, by, span, minimum_gap, shape.bounds, scale),
        .radial => blk: {
            // C clamps the radial frame to the visible integer box. An exact
            // center leaves either a zero displacement or an exact integer
            // clamp; the quadratic and linear terms then have the same sign.
            if (@as(f64, @as(f32, @floatCast(ax))) != ax or @as(f64, @as(f32, @floatCast(ay))) != ay) return false;
            break :blk 16 * unit_roundoff / (minimum_gap / span) + 12 * unit_roundoff;
        },
        // Angular arithmetic and atan2 share this deliberately narrow tested
        // envelope. A finite coordinate/minimum gap alone is not a proof of
        // arbitrary driver transcendental accuracy.
        .conic => 16 * unit_roundoff / minimum_gap + 12 * unit_roundoff,
    };
    // Reserve half a channel for geometry; conversion/packing has the other
    // half. Low alpha is included: A*d(P/A)/dt=a0*a1/A*(c1-c0), factor <=1.
    const sensitivity: f64 = if (brush.interpolation == .oklab) 300 else 14;
    return weight_error <= 0.5 / (255 * sensitivity);
}
const unit_roundoff: f64 = 0x1p-24;

/// Cancellation is measured in projected physical distance, not coordinate
/// magnitude alone. C narrows both the unit basis and every projected stop;
/// HLSL subtracts those stops from a two-component float dot product.
noinline fn linearWeightError(ax: f64, ay: f64, bx: f64, by: f64, span: f64, gap: f64, rect: geometry.Rect, scale: f32) f64 {
    const left = @floor(@as(f64, rect.x) * scale);
    const top = @floor(@as(f64, rect.y) * scale);
    const right = @ceil((@as(f64, rect.x) + rect.width) * scale);
    const bottom = @ceil((@as(f64, rect.y) + rect.height) * scale);
    const ux = @abs((bx - ax) / span) * (1 + unit_roundoff);
    const uy = @abs((by - ay) / span) * (1 + unit_roundoff);
    const dot_extent = (right - left + 1) * ux + (bottom - top + 1) * uy;
    const a_extent = @max(@abs(ax - left), @abs(ax - right)) * ux + @max(@abs(ay - top), @abs(ay - bottom)) * uy;
    const b_extent = @max(@abs(bx - left), @abs(bx - right)) * ux + @max(@abs(by - top), @abs(by - bottom)) * uy;
    const dot_error = (2 * unit_roundoff / (1 - 2 * unit_roundoff)) * dot_extent;
    const stop_error = unit_roundoff * @max(a_extent, b_extent) + 0x1p-30;
    const basis_error = unit_roundoff * (a_extent + span);
    const denominator = gap - 2 * stop_error;
    if (denominator <= 0) return std.math.inf(f64);
    return (dot_error + 3 * stop_error + basis_error) / denominator + 12 * unit_roundoff;
}
fn physicalCoordinate(value: f64) bool {
    return std.math.isFinite(value) and @abs(value) <= 16384;
}
fn halfGrid(value: f64) bool {
    return physicalCoordinate(value) and value * 2 == @floor(value * 2);
}

test "optional GPU interpolation packet and original brush ABI remain bounded" {
    try std.testing.expectEqual(@as(usize, 272), @sizeOf(Packet));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(brushes.Native));
    const stops = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0x00ff00) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    const brush = try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 32 }, .stops = &stops, .interpolation = .oklab } });
    const packet = Packet.prepare(&brush);
    try std.testing.expectEqual([2]u32{ 0, 0 }, packet.reserved);
    try std.testing.expect(packet.colors[0][1] < 0);
    try std.testing.expectEqual(@as(f32, 1), packet.colors[0][3]);
}
test "optional GPU interpolation retains precision gates without opaque axis restrictions" {
    const stops = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.25, .color = .rgb(0x00ff00) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
    var brush = try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 16 }, .stops = &stops, .interpolation = .srgb_linear } });
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 24 }, .color = .rgb(0) });
    for ([_]f32{ 1, 1.5, 2 }) |scale| try std.testing.expect(supports(&brush, shape, scale));
    try std.testing.expect(supports(&brush, shape, 1.25));
    brush.stops[1].color.a = 254;
    try std.testing.expect(supports(&brush, shape, 1));
    brush.stops[1].color.a = 255;
    brush.stops[1].offset = 0.250001;
    try std.testing.expect(supports(&brush, shape, 1));
    brush.stops[1].offset = 1.0 / 256.0;
    try std.testing.expect(!supports(&brush, shape, 1));
    brush.stops[1].offset = 0.25;
    brush.b.y = 1;
    try std.testing.expect(supports(&brush, shape, 1));
    brush.b.y = 0;
    var altered = shape;
    altered.radius = 1;
    try std.testing.expect(supports(&brush, altered, 1));
    altered = shape;
    altered.bounds.x = 0.25;
    try std.testing.expect(supports(&brush, altered, 1));
    altered.bounds.x = 16384;
    try std.testing.expect(!supports(&brush, altered, 1));
    try std.testing.expect(!supports(&brush, shape, 32));
}

test "prepared analytic interpolation supports the shared geometry and alpha envelope" {
    const stops = [_]brushes.Stop{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 40, .a = 128 } },
        .{ .offset = 1, .color = .rgb(0x0000ff) },
    };
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0.25, .y = 0.5, .width = 40, .height = 28 }, .radius = 4, .stroke_width = 2, .color = .rgb(0) });
    for ([_]brushes.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
        const linear = try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 2, .y = 4 }, .end = .{ .x = 42, .y = 20 }, .stops = &stops, .interpolation = space } });
        const radial = try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 24.5, .y = 16.5 }, .radius = .{ .x = 18, .y = 12 }, .stops = &stops, .interpolation = space } });
        for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
            try std.testing.expect(supports(&linear, shape, scale));
            try std.testing.expect(supports(&radial, shape, scale));
        }
    }
}

test "prepared packet keeps hidden transparent stops zero and signed coordinates premultiplied" {
    const stops = [_]brushes.Stop{
        .{ .offset = 0, .color = .{ .r = 255, .g = 41, .b = 92, .a = 0 } },
        .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 1 } },
        .{ .offset = 1, .color = .rgb(0x0000ff) },
    };
    for ([_]brushes.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
        const value = try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 32 }, .stops = &stops, .interpolation = space } });
        const packet = Packet.prepare(&value);
        try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, packet.colors[0]);
        try std.testing.expectEqual(@as(f32, 1.0 / 255.0), packet.colors[1][3]);
        if (space == .oklab) try std.testing.expect(packet.colors[1][1] < 0);
        for (packet.colors[0..packet.len]) |color| for (color) |channel| try std.testing.expect(std.math.isFinite(channel));
    }
}

test "new interpolation rejects curved hard boundaries and preserves finite source-plane limits" {
    const stops = [_]brushes.Stop{
        .{ .offset = 0, .color = .rgb(0x00ff00) },
        .{ .offset = 0.5, .color = .rgb(0x0000ff) },
        .{ .offset = 0.5, .color = .rgb(0xffffff) },
        .{ .offset = 1, .color = .rgb(0x00ff00) },
    };
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 64, .height = 64 }, .color = .rgb(0) });
    var value = try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 32 }, .stops = &stops, .interpolation = .oklab } });
    try std.testing.expect(supports(&value, shape, 1));
    value.b.y = 1;
    try std.testing.expect(!supports(&value, shape, 1));
    value = try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 32, .y = 32 }, .radius = .{ .x = 16, .y = 16 }, .stops = &stops, .interpolation = .oklab } });
    try std.testing.expect(!supports(&value, shape, 1));
    value = try brushes.Stored.init(.{ .conic = .{ .center = .{ .x = 32, .y = 32 }, .stops = &.{ stops[0], stops[1], stops[3] }, .interpolation = .oklab } });
    try std.testing.expect(supports(&value, shape, 1));
    value.stops[2].color = .rgb(0xff0000);
    try std.testing.expect(!supports(&value, shape, 1));
    value.stops[2].color = value.stops[0].color;
    try std.testing.expect(!supports(&value, shape, std.math.nan(f32)));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(brushes.Native));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(brushes.Stored));
}

test "geometry conditioning reserves the same half-channel budget in every interpolation space" {
    const stops = [_]brushes.Stop{
        .{ .offset = 0, .color = .rgb(0) },
        .{ .offset = 0.015625, .color = .rgb(0xffffff) },
        .{ .offset = 1, .color = .rgb(0xffffff) },
    };
    const wide_shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 4096, .height = 512 }, .color = .rgb(0) });
    for ([_]brushes.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
        const diagonal = try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 0.49985000491142273, .y = 0.49985000491142273 }, .end = .{ .x = 6.156704425811768, .y = 6.156704425811768 }, .stops = &stops, .interpolation = space } });
        try std.testing.expect(!supports(&diagonal, wide_shape, 1));
        // The original axis branch really transfers every projected stop and
        // physical pixel dot exactly: half-grid endpoints, 1/64 stop grid.
        const axis = try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 4096 }, .stops = &stops, .interpolation = space } });
        try std.testing.expect(supports(&axis, wide_shape, 1));
        for (axis.stops[0..axis.len]) |stop| {
            const projected = @as(f64, stop.offset) * 4096 - 2048;
            try std.testing.expectEqual(projected, @as(f64, @as(f32, @floatCast(projected))));
        }
        for ([_]f32{ 0.5, 2048.5, 4095.5 }) |pixel| {
            const dot: f32 = (pixel - 2048) * 1 + @as(f32, 0.5 - 256) * 0;
            try std.testing.expectEqual(@as(f64, pixel) - 2048, @as(f64, dot));
        }
    }
    const small = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 48, .height = 32 }, .color = .rgb(0) });
    const periodic = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.1875, .color = .rgb(0xffffff) }, .{ .offset = 1, .color = .rgb(0) } };
    var radial = try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 24.5, .y = 16.5 }, .radius = .{ .x = 18, .y = 12 }, .stops = &periodic, .interpolation = .oklab } });
    var conic = try brushes.Stored.init(.{ .conic = .{ .center = .{ .x = 24.5, .y = 16.5 }, .stops = &periodic, .interpolation = .oklab } });
    try std.testing.expect(supports(&radial, small, 1));
    try std.testing.expect(supports(&conic, small, 1));
    radial.stops[1].offset = 0.125;
    conic.stops[1].offset = 0.125;
    try std.testing.expect(!supports(&radial, small, 1));
    try std.testing.expect(!supports(&conic, small, 1));
    // The smaller sensitivity of linear-sRGB permits the same finite gap.
    radial.interpolation = .srgb_linear;
    conic.interpolation = .srgb_linear;
    try std.testing.expect(supports(&radial, small, 1));
    try std.testing.expect(supports(&conic, small, 1));
    radial.a.x = 24.500002;
    try std.testing.expect(!supports(&radial, small, 1.5));
}
