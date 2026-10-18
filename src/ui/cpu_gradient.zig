const std = @import("std");
const geometry = @import("geometry.zig");
const brushes = @import("brushes.zig");

/// Borrowed native software plane. Clip edges are in physical pixels.
pub const Surface = extern struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: u32,
    scale: f32,
    clip: [4]f64,
    origin: [2]f64 = .{ 0, 0 },
};
pub const Dirty = struct { left: u32, top: u32, right: u32, bottom: u32 };

/// Command-local constants, never cached through a borrowed descriptor.
const Sampler = struct {
    kind: brushes.Kind,
    x: f64,
    y: f64,
    u: f64,
    v: f64,
    offsets: [brushes.max_stops]f64 = undefined,
    inverse_steps: [brushes.max_stops]f64 = @splat(0),
    colors: [brushes.max_stops]brushes.Sample = undefined,
    len: usize,
    fn init(stored: *const brushes.Stored) Sampler {
        var result: Sampler = .{ .kind = stored.kind, .x = stored.a.x, .y = stored.a.y, .u = 0, .v = 0, .len = stored.len };
        if (stored.kind == .linear) {
            const dx = @as(f64, stored.b.x) - stored.a.x;
            const dy = @as(f64, stored.b.y) - stored.a.y;
            const length = dx * dx + dy * dy;
            result.u = dx / length;
            result.v = dy / length;
        } else if (stored.kind == .radial) {
            result.u = 1 / @as(f64, stored.b.x);
            result.v = 1 / @as(f64, stored.b.y);
        } else {
            result.u = stored.b.x;
            result.v = stored.b.y;
        }
        for (stored.stops[0..stored.len], 0..) |stop, index| {
            const alpha = @as(f64, @floatFromInt(stop.color.a)) / 255;
            result.offsets[index] = stop.offset;
            result.colors[index] = .{ .r = @as(f64, @floatFromInt(stop.color.r)) * alpha, .g = @as(f64, @floatFromInt(stop.color.g)) * alpha, .b = @as(f64, @floatFromInt(stop.color.b)) * alpha, .a = alpha };
            if (index > 0 and stop.offset > stored.stops[index - 1].offset) result.inverse_steps[index] = 1 / (@as(f64, stop.offset) - stored.stops[index - 1].offset);
        }
        return result;
    }
    fn sample(self: *const Sampler, x: f64, row: f64) brushes.Sample {
        const dx = (x - self.x) * self.u;
        const t = if (self.kind == .linear) dx + row else @sqrt(dx * dx + row);
        return self.at(t, self.upper(t));
    }
    fn upper(self: *const Sampler, t: f64) usize {
        var low: usize = 0;
        var high = self.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.offsets[middle] <= t) low = middle + 1 else high = middle;
        }
        return low;
    }
    fn at(self: *const Sampler, t: f64, low: usize) brushes.Sample {
        if (low == 0) return self.colors[0];
        if (low == self.len) return self.colors[self.len - 1];
        const a = self.colors[low - 1];
        const b = self.colors[low];
        const weight = (t - self.offsets[low - 1]) * self.inverse_steps[low];
        return .{ .r = a.r + (b.r - a.r) * weight, .g = a.g + (b.g - a.g) * weight, .b = a.b + (b.b - a.b) * weight, .a = a.a + (b.a - a.a) * weight };
    }
    fn blendEight(self: *const Sampler, comptime opaque_target: bool, pixels: [*]u32, coordinates: @Vector(8, f64), index: usize, all_opaque: bool) void {
        const F = @Vector(8, f64);
        const U = @Vector(8, u32);
        const zero: F = @splat(0);
        const one: F = @splat(1);
        const max_channel: F = @splat(255);
        const a = self.colors[if (index == 0) 0 else index - 1];
        const b = self.colors[if (index == self.len) self.len - 1 else index];
        const weights: F = if (index == 0 or index == self.len) zero else (coordinates - @as(F, @splat(self.offsets[index - 1]))) * @as(F, @splat(self.inverse_steps[index]));
        var red: F = @as(F, @splat(a.r)) + @as(F, @splat(b.r - a.r)) * weights;
        var green: F = @as(F, @splat(a.g)) + @as(F, @splat(b.g - a.g)) * weights;
        var blue: F = @as(F, @splat(a.b)) + @as(F, @splat(b.b - a.b)) * weights;
        const destination: *align(1) U = @ptrCast(pixels);
        var output_alpha: U = @splat(255);
        if (!all_opaque) {
            const inverse: F = @as(F, @splat(1 - a.a)) - @as(F, @splat(b.a - a.a)) * weights;
            const old = destination.*;
            red += @as(F, @floatFromInt((old >> @as(U, @splat(16))) & @as(U, @splat(255)))) * inverse;
            green += @as(F, @floatFromInt((old >> @as(U, @splat(8))) & @as(U, @splat(255)))) * inverse;
            blue += @as(F, @floatFromInt(old & @as(U, @splat(255)))) * inverse;
            if (!opaque_target) output_alpha = @intFromFloat(@round(@min(max_channel, @max(zero, (one - inverse) * max_channel + @as(F, @floatFromInt(old >> @as(U, @splat(24)))) * inverse))));
        }
        const r: U = @intFromFloat(@round(@min(max_channel, @max(zero, red))));
        const g: U = @intFromFloat(@round(@min(max_channel, @max(zero, green))));
        const b_channel: U = @intFromFloat(@round(@min(max_channel, @max(zero, blue))));
        destination.* = (output_alpha << @as(U, @splat(24))) | (r << @as(U, @splat(16))) | (g << @as(U, @splat(8))) | b_channel;
    }
};

/// Work is bounded by clip intersection, with fixed 16-stop command scratch.
/// The owner flushes native writes before calling and marks the plane dirty after.
pub fn draw(surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    return drawMode(true, surface, plan, stored);
}
pub fn drawTransparent(surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    return drawMode(false, surface, plan, stored);
}
fn blend(comptime opaque_target: bool, value: brushes.Sample, background: u32, coverage: u8) u32 {
    return if (opaque_target) value.over(background, coverage) else value.overAlpha(background, coverage);
}
fn drawMode(comptime opaque_target: bool, surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    if (stored.spread != .pad) return drawSpread(opaque_target, surface, plan, stored);
    if (stored.interpolation != .srgb) return drawConverted(opaque_target, surface, plan, stored, false);
    if (stored.kind == .conic) return drawConic(opaque_target, surface, plan, stored);
    return drawLinearRadial(opaque_target, surface, plan, stored);
}

/// Opt-in command scratch. Stop conversion happens once, not in the pixel
/// loop. The legacy Sampler and its encoded-RGB vector loops stay unchanged.
const ConvertedSampler = struct {
    colors: [brushes.max_stops]brushes.color_interpolation.Coordinates = undefined,
    fn init(stored: *const brushes.Stored) ConvertedSampler {
        var result: ConvertedSampler = .{};
        for (stored.stops[0..stored.len], result.colors[0..stored.len]) |stop, *out| out.* = .fromColor(stored.interpolation, stop.color);
        return result;
    }
    fn at(self: *const ConvertedSampler, stored: *const brushes.Stored, t: f64) brushes.Sample {
        var low: usize = 0;
        var high: usize = stored.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (stored.stops[middle].offset <= t) low = middle + 1 else high = middle;
        }
        if (low == 0) return .from(stored.stops[0].color);
        if (low == stored.len) return .from(stored.stops[stored.len - 1].color);
        const before = stored.stops[low - 1];
        if (t == before.offset) return .from(before.color);
        const weight = (t - before.offset) / (@as(f64, stored.stops[low].offset) - before.offset);
        return .fromEncoded(brushes.color_interpolation.Coordinates.mix(self.colors[low - 1], self.colors[low], weight).encoded(stored.interpolation));
    }
};

noinline fn drawSpread(comptime opaque_target: bool, surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    return drawConverted(opaque_target, surface, plan, stored, true);
}

fn drawConverted(comptime opaque_target: bool, surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored, comptime periodic: bool) Dirty {
    const scale: f64 = surface.scale;
    const clip = surface.clip;
    const sw: f64 = @floatFromInt(surface.width);
    const sh: f64 = @floatFromInt(surface.height);
    const left: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[0], @as(f64, plan.bounds.x) * scale + surface.origin[0])), 0, sw));
    const top: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[1], @as(f64, plan.bounds.y) * scale + surface.origin[1])), 0, sh));
    const right: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[2], (@as(f64, plan.bounds.x) + plan.bounds.width) * scale + surface.origin[0])), 0, sw));
    const bottom: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[3], (@as(f64, plan.bounds.y) + plan.bounds.height) * scale + surface.origin[1])), 0, sh));
    const dirty: Dirty = .{ .left = left, .top = top, .right = @max(left, right), .bottom = @max(top, bottom) };
    if (right <= left or bottom <= top) return dirty;
    const sampler = ConvertedSampler.init(stored);
    const inverse_scale = 1 / scale;
    const projection: if (periodic) brushes.PeriodicProjection else void = if (periodic) .init(stored, scale) else {};
    const vx = if (periodic) @as(f64, 0) else @as(f64, stored.b.x) - stored.a.x;
    const vy = if (periodic) @as(f64, 0) else @as(f64, stored.b.y) - stored.a.y;
    const length = vx * vx + vy * vy;
    var y = top;
    while (y < bottom) : (y += 1) {
        const py = (@as(f64, @floatFromInt(y)) + 0.5 - surface.origin[1]) * inverse_scale;
        var x = left;
        while (x < right) : (x += 1) {
            const px = (@as(f64, @floatFromInt(x)) + 0.5 - surface.origin[0]) * inverse_scale;
            var coverage = geometry.coverage(plan, px, py, inverse_scale);
            if (coverage == 0) continue;
            const clip_coverage = @max(0, @min(@as(f64, @floatFromInt(x + 1)), clip[2]) - @max(@as(f64, @floatFromInt(x)), clip[0])) * @max(0, @min(@as(f64, @floatFromInt(y + 1)), clip[3]) - @max(@as(f64, @floatFromInt(y)), clip[1]));
            if (clip_coverage < 1) coverage = @intFromFloat(@round(@as(f64, @floatFromInt(coverage)) * clip_coverage));
            if (coverage == 0) continue;
            // Periodic hard seams cannot tolerate the avoidable error from
            // pixel*inverse_scale before projection. Keep their color math in
            // physical source coordinates; geometric coverage stays unchanged.
            const t = if (periodic) projection.parameter(@as(f64, @floatFromInt(x)) + 0.5 - surface.origin[0], @as(f64, @floatFromInt(y)) + 0.5 - surface.origin[1]) else value: {
                const dx = px - stored.a.x;
                const dy = py - stored.a.y;
                break :value switch (stored.kind) {
                    .linear => (dx * vx + dy * vy) / length,
                    .radial => @sqrt((dx / stored.b.x) * (dx / stored.b.x) + (dy / stored.b.y) * (dy / stored.b.y)),
                    .conic => brushes.conicParameter(dx, dy, stored.b.x, stored.b.y),
                };
            };
            const index = @as(usize, y) * surface.stride + x;
            surface.pixels[index] = blend(opaque_target, sampler.at(stored, t), surface.pixels[index], coverage);
        }
    }
    return dirty;
}
fn drawLinearRadial(comptime opaque_target: bool, surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    const scale: f64 = surface.scale;
    const clip = surface.clip;
    const sw: f64 = @floatFromInt(surface.width);
    const sh: f64 = @floatFromInt(surface.height);
    const left: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[0], @as(f64, plan.bounds.x) * scale + surface.origin[0])), 0, sw));
    const top: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[1], @as(f64, plan.bounds.y) * scale + surface.origin[1])), 0, sh));
    const right: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[2], (@as(f64, plan.bounds.x) + plan.bounds.width) * scale + surface.origin[0])), 0, sw));
    const bottom: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[3], (@as(f64, plan.bounds.y) + plan.bounds.height) * scale + surface.origin[1])), 0, sh));
    const dirty: Dirty = .{ .left = left, .top = top, .right = @max(left, right), .bottom = @max(top, bottom) };
    if (right <= left or bottom <= top) return dirty;
    const sampler = Sampler.init(stored);
    const inverse_scale = 1 / scale;
    const half_pixel = inverse_scale * 0.5;
    const rectangular = plan.radius == 0 and plan.stroke_width == 0;
    var all_opaque = true;
    for (sampler.colors[0..sampler.len]) |color| if (color.a != 1) {
        all_opaque = false;
        break;
    };
    // A horizontal opaque rectangle has the same final color on every fully
    // covered row, independent of the previous destination. Reuse that row in
    // the owned plane; partially covered shape/clip edges are still blended.
    const repeat_row = rectangular and all_opaque and sampler.kind == .linear and sampler.v == 0;
    const full_left: u32 = @intFromFloat(std.math.clamp(@ceil(@max(clip[0], @as(f64, plan.bounds.x) * scale + surface.origin[0])), 0, sw));
    const full_top: u32 = @intFromFloat(std.math.clamp(@ceil(@max(clip[1], @as(f64, plan.bounds.y) * scale + surface.origin[1])), 0, sh));
    const full_right: u32 = @intFromFloat(std.math.clamp(@floor(@min(clip[2], (@as(f64, plan.bounds.x) + plan.bounds.width) * scale + surface.origin[0])), 0, sw));
    const full_bottom: u32 = @intFromFloat(std.math.clamp(@floor(@min(clip[3], (@as(f64, plan.bounds.y) + plan.bounds.height) * scale + surface.origin[1])), 0, sh));
    var source_row: ?u32 = null;
    const plain_rectangle = rectangular and full_left == left and full_right == right and full_top == top and full_bottom == bottom;
    var y = top;
    while (y < bottom) : (y += 1) {
        const full_row = repeat_row and y >= full_top and y < full_bottom and full_right > full_left;
        const copied = full_row and source_row != null;
        if (copied) {
            const destination = @as(usize, y) * surface.stride;
            const source = @as(usize, source_row.?) * surface.stride;
            @memcpy(surface.pixels[destination + full_left .. destination + full_right], surface.pixels[source + full_left .. source + full_right]);
            if (plain_rectangle) continue;
        }
        const py = (@as(f64, @floatFromInt(y)) + 0.5 - surface.origin[1]) * inverse_scale;
        const dy = (py - sampler.y) * sampler.v;
        const row = if (sampler.kind == .linear) dy else dy * dy;
        if (plain_rectangle) {
            const base = @as(usize, y) * surface.stride;
            if (all_opaque and sampler.kind == .linear and sampler.u == 0) {
                @memset(surface.pixels[base + left .. base + right], sampler.sample(0, row).over(0, 255));
            } else {
                var px_index = left;
                if (sampler.kind == .linear) {
                    while (right - px_index >= 8) : (px_index += 8) {
                        const X = @Vector(8, f64);
                        const positions: X = @as(X, @splat(@as(f64, @floatFromInt(px_index)))) + X{ 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5 };
                        const t = ((positions - @as(X, @splat(surface.origin[0]))) * @as(X, @splat(inverse_scale)) - @as(X, @splat(sampler.x))) * @as(X, @splat(sampler.u)) + @as(X, @splat(row));
                        const first = sampler.upper(t[0]);
                        if (first == sampler.upper(t[7])) {
                            sampler.blendEight(opaque_target, surface.pixels + base + px_index, t, first, all_opaque);
                        } else {
                            for (0..8) |lane| {
                                const offset = base + px_index + lane;
                                surface.pixels[offset] = blend(opaque_target, sampler.at(t[lane], sampler.upper(t[lane])), surface.pixels[offset], 255);
                            }
                        }
                    }
                }
                while (px_index < right) : (px_index += 1) {
                    const offset = base + px_index;
                    surface.pixels[offset] = blend(opaque_target, sampler.sample((@as(f64, @floatFromInt(px_index)) + 0.5 - surface.origin[0]) * inverse_scale, row), surface.pixels[offset], 255);
                }
            }
            if (full_row and source_row == null) source_row = y;
            continue;
        }
        var x = left;
        while (x < right) : (x += 1) {
            if (copied and x == full_left) {
                x = full_right;
                if (x >= right) break;
            }
            const px = (@as(f64, @floatFromInt(x)) + 0.5 - surface.origin[0]) * inverse_scale;
            const full = rectangular and px - half_pixel >= plan.bounds.x and py - half_pixel >= plan.bounds.y and px + half_pixel <= @as(f64, plan.bounds.x) + plan.bounds.width and py + half_pixel <= @as(f64, plan.bounds.y) + plan.bounds.height;
            var coverage = if (full) @as(u8, 255) else geometry.coverage(plan, px, py, inverse_scale);
            if (coverage == 0) continue;
            const clip_coverage = @max(0, @min(@as(f64, @floatFromInt(x + 1)), clip[2]) - @max(@as(f64, @floatFromInt(x)), clip[0])) * @max(0, @min(@as(f64, @floatFromInt(y + 1)), clip[3]) - @max(@as(f64, @floatFromInt(y)), clip[1]));
            if (clip_coverage < 1) coverage = @intFromFloat(@round(@as(f64, @floatFromInt(coverage)) * clip_coverage));
            if (coverage == 0) continue;
            const index = @as(usize, y) * surface.stride + x;
            surface.pixels[index] = blend(opaque_target, sampler.sample(px, row), surface.pixels[index], coverage);
        }
        if (full_row and source_row == null) source_row = y;
    }
    return dirty;
}

// A separate command-level branch keeps atan2 and its parameter plumbing out
// of the existing linear/radial hot loops. No raster or heap scratch is built.
fn drawConic(comptime opaque_target: bool, surface: Surface, plan: geometry.Plan, stored: *const brushes.Stored) Dirty {
    const scale: f64 = surface.scale;
    const clip = surface.clip;
    const sw: f64 = @floatFromInt(surface.width);
    const sh: f64 = @floatFromInt(surface.height);
    const left: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[0], @as(f64, plan.bounds.x) * scale + surface.origin[0])), 0, sw));
    const top: u32 = @intFromFloat(std.math.clamp(@floor(@max(clip[1], @as(f64, plan.bounds.y) * scale + surface.origin[1])), 0, sh));
    const right: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[2], (@as(f64, plan.bounds.x) + plan.bounds.width) * scale + surface.origin[0])), 0, sw));
    const bottom: u32 = @intFromFloat(std.math.clamp(@ceil(@min(clip[3], (@as(f64, plan.bounds.y) + plan.bounds.height) * scale + surface.origin[1])), 0, sh));
    const dirty: Dirty = .{ .left = left, .top = top, .right = @max(left, right), .bottom = @max(top, bottom) };
    if (right <= left or bottom <= top) return dirty;
    const sampler = Sampler.init(stored);
    const inverse_scale = 1 / scale;
    var y = top;
    while (y < bottom) : (y += 1) {
        const py = (@as(f64, @floatFromInt(y)) + 0.5 - surface.origin[1]) * inverse_scale;
        var x = left;
        while (x < right) : (x += 1) {
            const px = (@as(f64, @floatFromInt(x)) + 0.5 - surface.origin[0]) * inverse_scale;
            var coverage = geometry.coverage(plan, px, py, inverse_scale);
            if (coverage == 0) continue;
            const clip_coverage = @max(0, @min(@as(f64, @floatFromInt(x + 1)), clip[2]) - @max(@as(f64, @floatFromInt(x)), clip[0])) * @max(0, @min(@as(f64, @floatFromInt(y + 1)), clip[3]) - @max(@as(f64, @floatFromInt(y)), clip[1]));
            if (clip_coverage < 1) coverage = @intFromFloat(@round(@as(f64, @floatFromInt(coverage)) * clip_coverage));
            if (coverage == 0) continue;
            const t = brushes.conicParameter(px - sampler.x, py - sampler.y, stored.b.x, stored.b.y);
            const index = @as(usize, y) * surface.stride + x;
            surface.pixels[index] = blend(opaque_target, sampler.at(t, sampler.upper(t)), surface.pixels[index], coverage);
        }
    }
    return dirty;
}

test "opaque and transparent optimized gradients preserve scalar premultiplied blending with clips and row padding" {
    const alpha = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    const hard = [_]brushes.Stop{ .{ .offset = 0.5, .color = .rgb(0xff0000) }, .{ .offset = 0.5, .color = .rgb(0x0000ff) } };
    const values = [_]brushes.Gradient{
        .{ .linear = .{ .start = .{ .x = 0.1 }, .end = .{ .x = 20.1 }, .stops = &hard } },
        .{ .linear = .{ .start = .{ .y = 0.1 }, .end = .{ .y = 20.1 }, .stops = &hard } },
        .{ .linear = .{ .start = .{}, .end = .{ .x = 20.1, .y = 10.25 }, .stops = &alpha } },
        .{ .radial = .{ .center = .{ .x = 11, .y = 9 }, .radius = .{ .x = 7, .y = 5 }, .stops = &alpha } },
        .{ .conic = .{ .center = .{ .x = 11, .y = 9 }, .start_angle_radians = 0.25, .stops = &alpha } },
        .{ .conic = .{ .center = .{ .x = 11, .y = 9 }, .direction = .counter_clockwise, .stops = &hard } },
    };
    for (values) |base_value| for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| for ([_]f32{ 1, 1.5, 2 }) |scale| for (0..3) |shape_index| for ([_]bool{ true, false }) |opaque_target| {
        var value = base_value;
        switch (value) {
            inline else => |*descriptor| descriptor.interpolation = space,
        }
        const stored = try brushes.Stored.init(value);
        const shape = try geometry.plan(.{ .bounds = if (shape_index == 0) .{ .x = 0, .y = 0, .width = 20, .height = 16 } else .{ .x = -2.25, .y = -1.5, .width = 23.375, .height = 18.75 }, .color = .rgb(0), .radius = if (shape_index == 2) 3 else 0, .stroke_width = if (shape_index == 2) 1.5 else 0 });
        var actual: [67 * 48]u32 = undefined;
        var expected: [67 * 48]u32 = undefined;
        for (&actual, &expected, 0..) |*a, *b, index| {
            const color = if (opaque_target) 0xff000000 | @as(u32, @intCast((index * 2797) & 0xffffff)) else 0x80604020 | @as(u32, @intCast(index & 31));
            a.* = color;
            b.* = color;
        }
        const sw: u32 = @intFromFloat(32 * scale);
        const sh: u32 = @intFromFloat(24 * scale);
        const clip: [4]f64 = if (shape_index == 0) .{ 0, 0, @floatFromInt(sw), @floatFromInt(sh) } else .{ 3.25, 2.5, 30.75, 23.75 };
        const surface: Surface = .{ .pixels = &actual, .width = sw, .height = sh, .stride = 67, .scale = scale, .clip = clip };
        _ = if (opaque_target) draw(surface, shape, &stored) else drawTransparent(surface, shape, &stored);
        for (0..sh) |y| for (0..sw) |x| {
            const px: f64 = @floatFromInt(x);
            const py: f64 = @floatFromInt(y);
            var coverage = geometry.coverage(shape, (px + 0.5) / scale, (py + 0.5) / scale, 1 / @as(f64, scale));
            const mask = @max(0, @min(px + 1, clip[2]) - @max(px, clip[0])) * @max(0, @min(py + 1, clip[3]) - @max(py, clip[1]));
            coverage = @intFromFloat(@round(@as(f64, @floatFromInt(coverage)) * mask));
            const index = y * 67 + x;
            const sampled = stored.sample((px + 0.5) / scale, (py + 0.5) / scale);
            expected[index] = if (opaque_target) sampled.over(expected[index], coverage) else sampled.overAlpha(expected[index], coverage);
        };
        for (actual, expected) |a, b| for ([_]u5{ 0, 8, 16, 24 }) |shift| {
            const difference = @abs(@as(i32, @intCast((a >> shift) & 255)) - @as(i32, @intCast((b >> shift) & 255)));
            try std.testing.expect(difference <= 1);
        };
    };
}

const spread_test_stops = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 1, .color = .rgb(0xffffff) } };

fn spreadTestBrush(comptime spread: brushes.Spread, space: brushes.InterpolationSpace, period: f32) !brushes.Stored {
    var value: brushes.Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = period }, .stops = &spread_test_stops, .interpolation = space } };
    value.linear.spread = spread;
    return brushes.Stored.init(value);
}

test "gradient spread repeat and reflect own negative periods exact seams and endpoints" {
    const repeated = try spreadTestBrush(.repeat, .srgb, 1);
    const reflected = try spreadTestBrush(.reflect, .srgb, 1);
    const probes = [_]struct { t: f64, repeat: u8, reflect: u8 }{
        .{ .t = -2, .repeat = 0, .reflect = 0 },
        .{ .t = -1.25, .repeat = 191, .reflect = 191 },
        .{ .t = -1, .repeat = 0, .reflect = 255 },
        .{ .t = -0.25, .repeat = 191, .reflect = 64 },
        .{ .t = -0x1p-1074, .repeat = 255, .reflect = 0 },
        .{ .t = 0, .repeat = 0, .reflect = 0 },
        .{ .t = 0.25, .repeat = 64, .reflect = 64 },
        .{ .t = 1, .repeat = 0, .reflect = 255 },
        .{ .t = 1.25, .repeat = 64, .reflect = 191 },
        .{ .t = 2, .repeat = 0, .reflect = 0 },
        .{ .t = 0x1p52 - 0.5, .repeat = 128, .reflect = 128 },
        .{ .t = 0x1p52 + 1, .repeat = 0, .reflect = 255 },
        .{ .t = -0x1p52 - 1, .repeat = 0, .reflect = 255 },
        .{ .t = std.math.floatMax(f64), .repeat = 0, .reflect = 0 },
        .{ .t = -std.math.floatMax(f64), .repeat = 0, .reflect = 0 },
    };
    for (probes) |probe| {
        try std.testing.expectEqual(probe.repeat, @as(u8, @truncate(repeated.sample(probe.t, 0).over(0, 255))));
        try std.testing.expectEqual(probe.reflect, @as(u8, @truncate(reflected.sample(probe.t, 0).over(0, 255))));
    }
}

test "gradient spread repeat maps before right continuous duplicate stop ownership" {
    const hard = [_]brushes.Stop{
        .{ .offset = 0, .color = .rgb(0xff0000) },
        .{ .offset = 0.5, .color = .rgb(0xff0000) },
        .{ .offset = 0.5, .color = .rgb(0x0000ff) },
        .{ .offset = 1, .color = .rgb(0x00ff00) },
    };
    var value: brushes.Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &hard } };
    value.linear.spread = .repeat;
    const repeated = try brushes.Stored.init(value);
    try std.testing.expectEqual(@as(u32, 0xffff0000), repeated.sample(1, 0).over(0, 255));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), repeated.sample(-0.5, 0).over(0, 255));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), repeated.sample(1.5, 0).over(0, 255));
}

test "gradient spread repeat software literal planes preserve origin clips and transparent targets" {
    for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        const repeated = try spreadTestBrush(.repeat, space, 1);
        // Every pixel center has mapped t=0.5, in every independent period.
        const expected: u32 = switch (space) {
            .srgb => 0xff808080,
            .srgb_linear => 0xffbcbcbc,
            .oklab => 0xff636363,
        };
        var pixels: [16]u32 = @splat(0xabcdef01);
        const plan = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 1 }, .color = .rgb(0) });
        _ = drawTransparent(.{ .pixels = &pixels, .width = 8, .height = 1, .stride = 16, .scale = 1, .clip = .{ 0, 0, 8, 1 } }, plan, &repeated);
        for (pixels[0..8]) |value| try std.testing.expectEqual(expected, value);
        for (pixels[8..]) |value| try std.testing.expectEqual(@as(u32, 0xabcdef01), value);
    }
    const repeated = try spreadTestBrush(.repeat, .srgb, 4);
    var plane: [8]u32 = @splat(0);
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 1 }, .color = .rgb(0) });
    _ = drawTransparent(.{ .pixels = &plane, .width = 8, .height = 1, .stride = 8, .scale = 1, .clip = .{ 0.25, 0, 7.75, 1 } }, shape, &repeated);
    const colors = [_]u8{ 32, 96, 159, 223, 32, 96, 159, 223 };
    for (plane, colors, 0..) |pixel, channel, x| {
        const alpha: u32 = if (x == 0 or x == 7) 191 else 255;
        const rgb: u32 = if (alpha == 255) channel else @intFromFloat(@round(@as(f64, @floatFromInt(channel)) * 191.0 / 255.0));
        try std.testing.expectEqual((alpha << 24) | (rgb << 16) | (rgb << 8) | rgb, pixel);
    }
}

test "gradient spread pad baseline pixels layouts and descriptor identity" {
    const LegacyStored = struct { kind: brushes.Kind, a: brushes.Point, b: brushes.Point, len: u8, interpolation: brushes.InterpolationSpace = .srgb, stops: [brushes.max_stops]brushes.Stop = undefined };
    try std.testing.expectEqual(@sizeOf(LegacyStored), @sizeOf(brushes.Stored));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(brushes.Native));
    std.debug.print("gradient_spread_sizes stored={d} native={d} gradient={d} stops_offset={d}\n", .{ @sizeOf(brushes.Stored), @sizeOf(brushes.Native), @sizeOf(brushes.Gradient), @offsetOf(brushes.Stored, "stops") });
    var planes: [3 * 3 * 64]u32 = undefined;
    for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }, 0..) |space, si| for ([_]f32{ 1, 1.5, 2 }, 0..) |scale, di| {
        const value = try spreadTestBrush(.pad, space, 6);
        const plan = try geometry.plan(.{ .bounds = .{ .x = -0.25, .y = 0.125, .width = 4, .height = 4 }, .radius = 1, .stroke_width = 0.75, .color = .rgb(0) });
        const plane = planes[(si * 3 + di) * 64 ..][0..64];
        @memset(plane, 0x80706050);
        _ = drawTransparent(.{ .pixels = plane.ptr, .width = 8, .height = 8, .stride = 8, .scale = scale, .clip = .{ 0.25, 0.5, 7.75, 7.5 } }, plan, &value);
    };
    std.debug.print("gradient_pad_fingerprint={x}\n", .{std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&planes))});
    try std.testing.expectEqual(@as(u64, 0x20b4c7fbdc43939d), std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&planes)));
}

test "gradient spread repeat transparent stops and gradient identity stay owned across every space" {
    const colors = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 37, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        var descriptor: brushes.Gradient = .{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &colors, .interpolation = space, .spread = .repeat } };
        const repeated = try brushes.Stored.init(descriptor);
        descriptor.linear.spread = .reflect;
        const reflected = try brushes.Stored.init(descriptor);
        descriptor.linear.spread = .pad;
        const padded = try brushes.Stored.init(descriptor);
        // Existing Oklab matrices may round the mathematically128 blue to127;
        // preserve that pad conversion exactly, and independently bound the
        // one output byte while alpha/red/green remain exact.
        const midpoint = padded.sample(0.5, 0).overAlpha(0, 255);
        try std.testing.expectEqual(@as(u32, 0x80000000), midpoint & 0xffffff00);
        try std.testing.expect((midpoint & 255) == 127 or (midpoint & 255) == 128);
        for ([_]f64{ -1.5, -0.5, 0.5, 1.5 }) |x| try std.testing.expectEqual(midpoint, repeated.sample(x, 0).overAlpha(0, 255));
        try std.testing.expect(!repeated.eql(&reflected) and !repeated.eql(&padded));
        try repeated.validate();
        try reflected.validate();
        descriptor.linear.spread = .repeat;
        try std.testing.expectEqual(brushes.Spread.repeat, descriptor.translated(.{ .x = 5 }).linear.spread);
    }
}

test "gradient spread repeat radial rings and reflected radial endpoints have literal planes" {
    inline for (.{ brushes.Spread.repeat, brushes.Spread.reflect }) |spread| {
        const brush = try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 0, .y = 0.5 }, .radius = .{ .x = 2, .y = 1 }, .stops = &spread_test_stops, .spread = spread } });
        var plane: [8]u32 = @splat(0);
        const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 1 }, .color = .rgb(0) });
        _ = drawTransparent(.{ .pixels = &plane, .width = 8, .height = 1, .stride = 8, .scale = 1, .clip = .{ 0, 0, 8, 1 } }, shape, &brush);
        const literal = if (spread == .repeat) [_]u8{ 64, 191, 64, 191, 64, 191, 64, 191 } else [_]u8{ 64, 191, 191, 64, 64, 191, 191, 64 };
        for (plane, literal) |pixel, value| try std.testing.expectEqual(@as(u32, 0xff000000) | @as(u32, value) * 0x010101, pixel);
        try std.testing.expectEqual(if (spread == .repeat) @as(u32, 0xff000000) else 0xffffffff, brush.sample(2, 0.5).over(0, 255));
    }
}

test "gradient spread repeat origin displacement clips once and degenerate geometry remains invalid" {
    const brush = try spreadTestBrush(.repeat, .srgb, 4);
    var plane: [8]u32 = @splat(0);
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 8, .height = 1 }, .color = .rgb(0) });
    _ = drawTransparent(.{ .pixels = &plane, .width = 8, .height = 1, .stride = 8, .scale = 1, .clip = .{ 0, 0, 8, 1 }, .origin = .{ 0.5, 0 } }, shape, &brush);
    const literal = [_]u8{ 0, 64, 128, 191, 0, 64, 128, 191 };
    for (plane, literal, 0..) |pixel, value, x| {
        const alpha: u32 = if (x == 0) 128 else 255;
        try std.testing.expectEqual((alpha << 24) | @as(u32, value) * 0x010101, pixel);
    }
    inline for (.{ brushes.Spread.pad, brushes.Spread.repeat, brushes.Spread.reflect }) |spread| {
        try std.testing.expectError(error.InvalidGradient, brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{}, .stops = &spread_test_stops, .spread = spread } }));
        try std.testing.expectError(error.InvalidGradient, brushes.Stored.init(.{ .radial = .{ .center = .{}, .radius = .{ .x = 0, .y = 1 }, .stops = &spread_test_stops, .spread = spread } }));
    }
}

test "gradient spread physical DPI seam retains exact right stop ownership" {
    const hard = [_]brushes.Stop{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 192, .a = 0 } },
        .{ .offset = 0.25, .color = .{ .r = 16, .g = 240, .b = 48, .a = 192 } },
        .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
        .{ .offset = 0.5, .color = .{ .r = 255, .g = 0, .b = 0, .a = 224 } },
        .{ .offset = 1, .color = .{ .r = 32, .g = 64, .b = 255, .a = 255 } },
    };
    const shape = try geometry.plan(.{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 20 }, .color = .rgb(0) });
    for ([_]brushes.Spread{ .repeat, .reflect }) |spread| for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        const brush = try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 12, .y = 7 }, .end = .{ .x = 18, .y = 11 }, .stops = &hard, .spread = spread, .interpolation = space } });
        const projection = brushes.PeriodicProjection.init(&brush, 1.5);
        // (-2.5*9-6*6)/117=-.5, then both periodic maps give .5.
        try std.testing.expectEqual(@as(f64, 0.5), projection.parameter(15.5, 4.5));
        var plane: [48 * 30]u32 = @splat(0xff183048);
        _ = drawTransparent(.{ .pixels = &plane, .width = 48, .height = 30, .stride = 48, .scale = 1.5, .clip = .{ 0, 0, 48, 30 } }, shape, &brush);
        try std.testing.expectEqual(@as(u32, 0xffe30609), plane[4 * 48 + 15]);
    };
    std.debug.print("gradient_spread_projection_bytes={d}\n", .{@sizeOf(brushes.PeriodicProjection)});
}
