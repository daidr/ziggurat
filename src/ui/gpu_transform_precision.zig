//! GPU raster-scope eligibility, independent of content and native handles.
//! Common scope/resource validation precedes this pass. This is a conservative
//! supported profile, not a proof of every driver's internal D2D arithmetic.
const std = @import("std");
const commands = @import("commands.zig");
const layers = @import("layers.zig");
const affine = @import("affine.zig");

const Error = error{UnsupportedTransformPrecision};
const source_error_limit: f64 = 1.0 / 256.0;
const physical_limit: f64 = 65536;
const linear_limit: f64 = 64;
const inverse_limit: f64 = 16;
const unit_roundoff: f64 = 0x1p-24;

const Interval = struct { low: f64, high: f64 };
const Vertex = struct { x: Interval, y: Interval };
const State = struct {
    // A new raster source resets the native transform. Logical ancestors are
    // sampled later; they are not applied while drawing this source's children.
    native_parent: affine.Affine = .{},
    origin: f64 = 0,
    cumulative: affine.Affine = .{},
    chain_error: f64 = 0,
};

/// Call after complete common preflightScopes validation. Reject the entire GPU
/// replay before its first command draw; software may consume the same Buffer.
/// No transforms is O(1); otherwise this is one walk and fixed four-level state.
pub fn preflight(ops: []const commands.Command, transforms: []const layers.NativeTransform, scale: f32) Error!void {
    if (transforms.len == 0) return;
    if (!std.math.isFinite(scale) or scale <= 0) return error.UnsupportedTransformPrecision;
    var state: State = .{};
    var saved: [layers.max_depth]State = undefined;
    var depth: usize = 0;
    for (ops) |op| switch (op) {
        .begin_group => {
            std.debug.assert(depth < saved.len);
            saved[depth] = state;
            depth += 1;
        },
        .begin_transform => |slot| {
            std.debug.assert(depth < saved.len and slot < transforms.len);
            saved[depth] = state;
            depth += 1;
            const value = transforms[slot];
            const local = value.matrix();
            const native = (local.then(state.native_parent) catch return error.UnsupportedTransformPrecision).narrowed() catch return error.UnsupportedTransformPrecision;
            const cumulative = local.then(state.cumulative) catch return error.UnsupportedTransformPrecision;
            try profile(native);
            try profile(cumulative);
            try cumulativeBounds(cumulative, value, scale);
            const error_value = try stageError(value, native, state.origin, scale);
            // Bilinear sampling is non-expansive in the byte-raster sup norm.
            // Sum stage coordinate contributions instead of pretending nested
            // filtering is one sample through a flattened matrix. Native byte
            // quantization/filter errors remain separately tested per stage.
            const total = upward(state.chain_error + error_value);
            if (total > source_error_limit) return error.UnsupportedTransformPrecision;
            state = .{
                .native_parent = .{ .x0 = narrow(1 / @as(f64, scale)), .y0 = narrow(1 / @as(f64, scale)) },
                .origin = 1,
                .cumulative = cumulative,
                .chain_error = total,
            };
        },
        .end_group, .end_transform => {
            std.debug.assert(depth != 0);
            depth -= 1;
            state = saved[depth];
        },
        else => {},
    };
    std.debug.assert(depth == 0);
}

fn narrow(value: f64) f64 {
    const result: f32 = @floatCast(value);
    return result;
}
fn upward(value: f64) f64 {
    return if (value == 0) 0 else std.math.nextAfter(f64, value, std.math.inf(f64));
}
fn profile(matrix: affine.Affine) Error!void {
    for ([_]f64{ matrix.xx, matrix.xy, matrix.yx, matrix.yy }) |value| if (!std.math.isFinite(value) or @abs(value) > linear_limit) return error.UnsupportedTransformPrecision;
    const inverse = matrix.inverse() catch return error.UnsupportedTransformPrecision;
    if (@max(@abs(inverse.xx) + @abs(inverse.xy), @abs(inverse.yx) + @abs(inverse.yy)) > inverse_limit) return error.UnsupportedTransformPrecision;
}

fn cumulativeBounds(matrix: affine.Affine, value: layers.NativeTransform, scale: f64) Error!void {
    // Include guard texels, not the unpadded logical source rectangle.
    for ([_]f64{ -1, @as(f64, @floatFromInt(value.pixel_width)) + 1 }) |x| {
        for ([_]f64{ -1, @as(f64, @floatFromInt(value.pixel_height)) + 1 }) |y| {
            const mx = @abs(matrix.xx * x) + @abs(matrix.xy * y) + @abs(matrix.x0 * scale);
            const my = @abs(matrix.yx * x) + @abs(matrix.yy * y) + @abs(matrix.y0 * scale);
            if (!std.math.isFinite(mx) or !std.math.isFinite(my) or @max(mx, my) > physical_limit) return error.UnsupportedTransformPrecision;
        }
    }
}

fn representable(value: f64) bool {
    return std.math.isFinite(value) and narrow(value) == value;
}
fn exactSum(terms: [3]f64) bool {
    // Account for reassociation/FMA without forcing one unpromised native order.
    for ([_][3]u2{ .{ 0, 1, 2 }, .{ 0, 2, 1 }, .{ 1, 2, 0 } }) |order| {
        const sum = terms[order[0]] + terms[order[1]];
        if (!representable(sum) or !representable(sum + terms[order[2]])) return false;
    }
    return true;
}
fn exactEvaluation(a: f64, b: f64, t: f64, x: f64, y: f64, scale: f64) bool {
    const terms = [3]f64{ a * x, b * y, t };
    for (terms) |term| if (!representable(term)) return false;
    if (!exactSum(terms)) return false;
    const scaled = [3]f64{ a * scale, b * scale, t * scale };
    for (scaled) |term| if (!representable(term)) return false;
    const products = [3]f64{ scaled[0] * x, scaled[1] * y, scaled[2] };
    for (products) |term| if (!representable(term)) return false;
    return exactSum(products) and representable((terms[0] + terms[1] + terms[2]) * scale);
}
fn evaluation(a: f64, b: f64, t: f64, x: f64, y: f64, scale: f64) Error!Interval {
    const mid = (a * x + b * y + t) * scale;
    const magnitude = (@abs(a * x) + @abs(b * y) + @abs(t)) * scale;
    if (!std.math.isFinite(mid) or !std.math.isFinite(magnitude) or magnitude > physical_limit) return error.UnsupportedTransformPrecision;
    // The represented matrix/rect values are exact inputs. Eight elementary
    // fp32 operations cover their multiply/add/DPI evaluation, including a
    // reciprocal-scale composition. Exact lattice cases retain zero error.
    const amount = if (exactEvaluation(a, b, t, x, y, scale)) 0 else upward((8 * unit_roundoff / (1 - 8 * unit_roundoff)) * magnitude);
    return if (amount == 0) .{ .low = mid, .high = mid } else .{
        .low = std.math.nextAfter(f64, mid - amount, -std.math.inf(f64)),
        .high = std.math.nextAfter(f64, mid + amount, std.math.inf(f64)),
    };
}
fn snap(value: Interval) Interval {
    // All nearest 1/256-grid results, including either tie direction. The
    // interval also covers a rounding-boundary crossed by fp32 evaluation.
    return .{
        .low = @ceil(std.math.nextAfter(f64, value.low * 256 - 0.5, -std.math.inf(f64))) / 256,
        .high = @floor(std.math.nextAfter(f64, value.high * 256 + 0.5, std.math.inf(f64))) / 256,
    };
}
fn uvError(length: f64, pixels: u32, scale: f64) f64 {
    const actual = length * scale;
    const error_value = if (representable(actual)) 0 else (2 * unit_roundoff / (1 - 2 * unit_roundoff)) * @abs(actual);
    return upward(@abs(actual - (@as(f64, @floatFromInt(pixels)) + 2)) + error_value);
}

fn intervalSubtract(a: Interval, b: Interval) Interval {
    return .{ .low = std.math.nextAfter(f64, a.low - b.high, -std.math.inf(f64)), .high = std.math.nextAfter(f64, a.high - b.low, std.math.inf(f64)) };
}
fn intervalAdd(a: Interval, b: Interval) Interval {
    return .{ .low = std.math.nextAfter(f64, a.low + b.low, -std.math.inf(f64)), .high = std.math.nextAfter(f64, a.high + b.high, std.math.inf(f64)) };
}
fn point(value: f64) Interval {
    return .{ .low = value, .high = value };
}
fn intervalMultiply(a: Interval, b: Interval) Interval {
    const p = [4]f64{ a.low * b.low, a.low * b.high, a.high * b.low, a.high * b.high };
    return .{ .low = std.math.nextAfter(f64, @min(@min(p[0], p[1]), @min(p[2], p[3])), -std.math.inf(f64)), .high = std.math.nextAfter(f64, @max(@max(p[0], p[1]), @max(p[2], p[3])), std.math.inf(f64)) };
}
fn intervalRatio(numerator: f64, denominator: Interval) Error!Interval {
    if (denominator.low <= 0 and denominator.high >= 0) return error.UnsupportedTransformPrecision;
    const a = numerator / denominator.low;
    const b = numerator / denominator.high;
    return .{ .low = std.math.nextAfter(f64, @min(a, b), -std.math.inf(f64)), .high = std.math.nextAfter(f64, @max(a, b), std.math.inf(f64)) };
}
fn oriented(a: Vertex, b: Vertex, c: Vertex, positive: bool) bool {
    const abx = intervalSubtract(b.x, a.x);
    const aby = intervalSubtract(b.y, a.y);
    const acx = intervalSubtract(c.x, a.x);
    const acy = intervalSubtract(c.y, a.y);
    const cross = intervalSubtract(intervalMultiply(abx, acy), intervalMultiply(aby, acx));
    return if (positive) cross.low > 0 else cross.high < 0;
}
fn stageError(value: layers.NativeTransform, native: affine.Affine, origin: f64, scale: f64) Error!f64 {
    // Even the host inverse/error calculation needs outward rounding. A plain
    // f64 inverse plus one final nextAfter can underbound a rational result.
    const determinant = intervalSubtract(intervalMultiply(point(value.xx), point(value.yy)), intervalMultiply(point(value.xy), point(value.yx)));
    const inverse_xx = try intervalRatio(value.yy, determinant);
    const inverse_xy = try intervalRatio(-value.xy, determinant);
    const inverse_yx = try intervalRatio(-value.yx, determinant);
    const inverse_yy = try intervalRatio(value.xx, determinant);
    // Mirror the C float rectangle construction, including right/bottom add.
    const start = narrow(-1 / scale);
    const width = narrow(@as(f64, @floatFromInt(value.pixel_width + 2)) / scale);
    const height = narrow(@as(f64, @floatFromInt(value.pixel_height + 2)) / scale);
    const xs = [2]f64{ start, narrow(start + width) };
    const ys = [2]f64{ start, narrow(start + height) };
    const ux = [2]f64{ -1, @as(f64, @floatFromInt(value.pixel_width)) + 1 };
    const uy = [2]f64{ -1, @as(f64, @floatFromInt(value.pixel_height)) + 1 };
    const uvx = uvError(width, value.pixel_width, scale);
    const uvy = uvError(height, value.pixel_height, scale);
    var vertices: [4]Vertex = undefined;
    var result: f64 = 0;
    for ([_][2]u1{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } }, 0..) |index, i| {
        const x = index[0];
        const y = index[1];
        const vertex: Vertex = .{
            .x = snap(try evaluation(native.xx, native.xy, native.x0, xs[x], ys[y], scale)),
            .y = snap(try evaluation(native.yx, native.yy, native.y0, xs[x], ys[y], scale)),
        };
        vertices[i] = vertex;
        const ideal_x = intervalAdd(intervalAdd(intervalAdd(intervalMultiply(point(value.xx), point(ux[x])), intervalMultiply(point(value.xy), point(uy[y]))), intervalMultiply(point(value.x0), point(scale))), point(origin));
        const ideal_y = intervalAdd(intervalAdd(intervalAdd(intervalMultiply(point(value.yx), point(ux[x])), intervalMultiply(point(value.yy), point(uy[y]))), intervalMultiply(point(value.y0), point(scale))), point(origin));
        const delta_x = intervalSubtract(vertex.x, ideal_x);
        const delta_y = intervalSubtract(vertex.y, ideal_y);
        for ([_]f64{ delta_x.low, delta_x.high }) |dx| {
            for ([_]f64{ delta_y.low, delta_y.high }) |dy| {
                const sx = intervalAdd(intervalMultiply(inverse_xx, point(dx)), intervalMultiply(inverse_xy, point(dy)));
                const sy = intervalAdd(intervalMultiply(inverse_yx, point(dx)), intervalMultiply(inverse_yy, point(dy)));
                const delta = upward(@max(@abs(sx.low), @abs(sx.high)) + @max(@abs(sy.low), @abs(sy.high)));
                const error_value = upward(upward(delta + (if (x != 0) uvx else 0)) + (if (y != 0) uvy else 0));
                result = @max(result, error_value);
            }
        }
    }
    const positive = value.xx * value.yy - value.xy * value.yx > 0;
    // Both diagonals must retain orientation, not just one assumed native split.
    for ([_][3]u2{ .{ 0, 1, 2 }, .{ 0, 2, 3 }, .{ 0, 1, 3 }, .{ 1, 2, 3 } }) |triangle| {
        if (!oriented(vertices[triangle[0]], vertices[triangle[1]], vertices[triangle[2]], positive)) return error.UnsupportedTransformPrecision;
    }
    if (!std.math.isFinite(result) or result > source_error_limit) return error.UnsupportedTransformPrecision;
    return result;
}

test "nearest grid model explains the preserved tiny-scale solid source failure" {
    const scale: f64 = 1.0 / 4096.0;
    const translation: f64 = 8.5 - 8.5 / 4096.0;
    const left = snap(try evaluation(scale, 0, translation, -1, -1, 1));
    const right = snap(try evaluation(scale, 0, translation, 17, -1, 1));
    try std.testing.expectEqual(@as(f64, 8.49609375), left.low);
    try std.testing.expectEqual(left.low, left.high);
    try std.testing.expectEqual(@as(f64, 8.50390625), right.low);
    try std.testing.expectEqual(right.low, right.high);
    // Independent one-dimensional barycentric inverse of the snapped quad.
    const position = -1 + (8.5 - left.low) * 18 / (right.low - left.low);
    try std.testing.expectEqual(@as(f64, 8), position);
    try std.testing.expectEqual(@as(f64, 8.5), (8.5 - translation) / scale);
    const raster = [4][3]u8{ .{ 128, 128, 255 }, .{ 255, 255, 255 }, .{ 0, 0, 255 }, .{ 255, 0, 0 } };
    for ([_]u8{ 160, 96, 191 }, 0..) |want, channel| {
        var sum: f64 = 0;
        for (raster) |pixel| sum += @as(f64, @floatFromInt(pixel[channel])) / 4;
        try std.testing.expectEqual(want, @as(u8, @intFromFloat(@round(sum))));
    }
}

test "GPU eligibility is content independent and software descriptors stay legal" {
    const tiny = try layers.NativeTransform.init(.{ .xx = 1.0 / 4096.0, .yy = 1.0 / 4096.0, .x0 = 8.5 - 8.5 / 4096.0, .y0 = 8.5 - 8.5 / 4096.0 }, .{ .width = 16, .height = 16 }, 1);
    const shear = try layers.NativeTransform.init(.{ .xy = 65536, .x0 = -557056 }, .{ .width = 16, .height = 16 }, 1);
    const ops = [_]commands.Command{ .{ .fill = .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .color = 0 } }, .{ .begin_transform = 0 }, .{ .fill = .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .color = 0xff0000 } }, .end_transform };
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&ops, &.{tiny}, 1));
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&ops, &.{shear}, 1));
    try tiny.validate(1);
    try shear.validate(1);
    try preflight(&.{}, &.{}, std.math.nan(f32));
}

test "exact aligned minification reflection and physical DPI guards remain eligible" {
    const ops = [_]commands.Command{ .{ .begin_transform = 0 }, .end_transform };
    for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]affine.Affine{
        .{},
        .{ .xx = -1, .x0 = 16 },
        .{ .xx = 0, .xy = -1, .yx = 1, .yy = 0, .x0 = 16 },
        .{ .xy = 2, .x0 = -8 },
        .{ .xx = 0.5, .yy = 0.5, .x0 = 8.5 - 8.5 * 0.5, .y0 = 8.5 - 8.5 * 0.5 },
        .{ .xx = 0.125, .yy = 0.125, .x0 = 8.5 - 8.5 * 0.125, .y0 = 8.5 - 8.5 * 0.125 },
    }) |matrix| {
        const descriptor = try layers.NativeTransform.init(matrix, .{ .width = 16, .height = 16 }, scale);
        try preflight(&ops, &.{descriptor}, scale);
    };
}

test "nested stages cannot hide behind cancellation and siblings restore their budget" {
    const source: @import("layout.zig").Size = .{ .width = 16, .height = 16 };
    const tiny = try layers.NativeTransform.init(.{ .xx = 1.0 / 4096.0, .yy = 1.0 / 4096.0 }, source, 1);
    const reciprocal = try layers.NativeTransform.init(.{ .xx = 4096, .yy = 4096 }, source, 1);
    const nested = [_]commands.Command{ .{ .begin_transform = 0 }, .{ .begin_group = .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 } } }, .{ .begin_transform = 1 }, .end_transform, .end_group, .end_transform };
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&nested, &.{ tiny, reciprocal }, 1));
    const quarter = try layers.NativeTransform.init(.{ .xx = 0.25, .yy = 0.25 }, source, 1);
    const eighth = try layers.NativeTransform.init(.{ .xx = 0.125, .yy = 0.125 }, source, 1);
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&nested, &.{ quarter, eighth }, 1));
    const identity = try layers.NativeTransform.init(.{}, source, 1);
    const siblings = [_]commands.Command{ .{ .begin_transform = 0 }, .end_transform, .{ .begin_transform = 1 }, .end_transform };
    try preflight(&siblings, &.{ eighth, identity }, 1);
}

test "snap contribution is a shared budget along the complete raster chain" {
    const descriptor = try layers.NativeTransform.init(.{ .x0 = 3.0 / 2048.0 }, .{ .width = 16, .height = 16 }, 1);
    const one = [_]commands.Command{ .{ .begin_transform = 0 }, .end_transform };
    const two = [_]commands.Command{ .{ .begin_transform = 0 }, .{ .begin_transform = 0 }, .end_transform, .end_transform };
    const three = [_]commands.Command{ .{ .begin_transform = 0 }, .{ .begin_transform = 0 }, .{ .begin_transform = 0 }, .end_transform, .end_transform, .end_transform };
    try preflight(&one, &.{descriptor}, 1);
    try preflight(&two, &.{descriptor}, 1);
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&three, &.{descriptor}, 1));
    // Every individual stage fits; the third failure is the accumulated budget.
    const error_value = try stageError(descriptor, descriptor.matrix(), 0, 1);
    try std.testing.expect(error_value >= 3.0 / 2048.0);
    try std.testing.expect(error_value * 2 < source_error_limit and error_value * 3 > source_error_limit);
}

test "source-grid phase and fp32 cancellation reject before content while a large aligned source stays legal" {
    const ops = [_]commands.Command{ .{ .begin_transform = 0 }, .end_transform };
    const misaligned = try layers.NativeTransform.init(.{ .xx = 0.125, .yy = 0.125, .x0 = 7.4375 + 1.0 / 1024.0, .y0 = 7.4375 }, .{ .width = 16, .height = 16 }, 1);
    try profile(misaligned.matrix());
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&ops, &.{misaligned}, 1));
    const cancellation = try layers.NativeTransform.init(.{ .xx = 64, .x0 = -32768 }, .{ .width = 1024, .height = 2 }, 1);
    try profile(cancellation.matrix());
    try std.testing.expectError(error.UnsupportedTransformPrecision, preflight(&ops, &.{cancellation}, 1));
    const large = try layers.NativeTransform.init(.{}, .{ .width = 32766, .height = 1 }, 1);
    try preflight(&ops, &.{large}, 1);
}

test "snap intervals reject collapsed flipped and uncertain native triangles" {
    const vertex = struct {
        fn make(x: f64, y: f64) Vertex {
            return .{ .x = .{ .low = x, .high = x }, .y = .{ .low = y, .high = y } };
        }
    }.make;
    const a = vertex(0, 0);
    const b = vertex(1, 0);
    const c = vertex(0, 1);
    try std.testing.expect(oriented(a, b, c, true));
    try std.testing.expect(oriented(a, c, b, false));
    try std.testing.expect(!oriented(a, b, b, true));
    try std.testing.expect(!oriented(a, c, b, true));
    var uncertain = c;
    uncertain.y.low = -1.0 / 256.0;
    try std.testing.expect(!oriented(a, b, uncertain, true));
    const tie = snap(.{ .low = 0.5 / 256.0, .high = 0.5 / 256.0 });
    try std.testing.expect(tie.low == 0 and tie.high == 1.0 / 256.0);
}

test "independent f128 barycentric oracle bounds source error for both snapped quad diagonals" {
    var random = std.Random.DefaultPrng.init(0x7783b02de6251941);
    const rng = random.random();
    var accepted: usize = 0;
    for (0..512) |_| {
        const matrix: affine.Affine = .{
            .xx = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, 16, 48))) / 32,
            .xy = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, -16, 16))) / 32,
            .yx = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, -16, 16))) / 32,
            .yy = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, 16, 48))) / 32,
            .x0 = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, -32, 32))) / 1024,
            .y0 = @as(f64, @floatFromInt(rng.intRangeAtMost(i16, -32, 32))) / 1024,
        };
        const descriptor = layers.NativeTransform.init(matrix, .{ .width = 16, .height = 16 }, 1) catch continue;
        profile(matrix) catch continue;
        const bound = stageError(descriptor, matrix, 0, 1) catch continue;
        accepted += 1;
        const a: f128 = matrix.xx;
        const b: f128 = matrix.xy;
        const c: f128 = matrix.yx;
        const d: f128 = matrix.yy;
        const tx: f128 = matrix.x0;
        const ty: f128 = matrix.y0;
        const determinant = a * d - b * c;
        const source = [4][2]f128{ .{ -1, -1 }, .{ 17, -1 }, .{ 17, 17 }, .{ -1, 17 } };
        var snapped: [4][2]f128 = undefined;
        for (source, 0..) |p, i| {
            // This independent oracle uses exact dyadic native inputs. It does
            // not call evaluation/snap, inverse(), or the interval arithmetic.
            snapped[i] = .{
                @floor((a * p[0] + b * p[1] + tx) * 256 + 0.5) / 256,
                @floor((c * p[0] + d * p[1] + ty) * 256 + 0.5) / 256,
            };
        }
        for ([_][3]u2{ .{ 0, 1, 2 }, .{ 0, 2, 3 }, .{ 0, 1, 3 }, .{ 1, 2, 3 } }) |triangle| {
            for ([_][3]f128{ .{ 0.25, 0.25, 0.5 }, .{ 0.5, 0.25, 0.25 }, .{ 0.25, 0.5, 0.25 } }) |weights| {
                var px: f128 = 0;
                var py: f128 = 0;
                var sx: f128 = 0;
                var sy: f128 = 0;
                for (triangle, weights) |i, weight| {
                    px += weight * snapped[i][0];
                    py += weight * snapped[i][1];
                    sx += weight * source[i][0];
                    sy += weight * source[i][1];
                }
                const ideal_x = (d * (px - tx) - b * (py - ty)) / determinant;
                const ideal_y = (a * (py - ty) - c * (px - tx)) / determinant;
                const difference = @abs(ideal_x - sx) + @abs(ideal_y - sy);
                try std.testing.expect(difference <= @as(f128, bound) + 1e-25);
            }
        }
    }
    try std.testing.expect(accepted >= 128);
}
