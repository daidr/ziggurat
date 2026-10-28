//! Private live-filter arithmetic. Existing f64 snapshot Processor is separate.
const std = @import("std");

pub const max_radius = 128;
pub const weight_sum: u32 = 1 << 24;
pub const capacity = max_radius * 2 + 1;
pub const Spec = struct { sigma: f32, scale: f32 = 1 };
pub const Kernel = extern struct {
    sigma: f32,
    scale: f32,
    radius: u32,
    weights: [capacity]u32 = @splat(0),

    /// Explicit preparation, never invoked by replay. Preserve pair symmetry
    /// and exact total with a bounded symmetric largest-remainder projection.
    pub fn prepare(spec: Spec) !Kernel {
        if (!std.math.isFinite(spec.sigma) or spec.sigma < 0 or !std.math.isFinite(spec.scale) or spec.scale < 0.0625 or spec.scale > 16) return error.InvalidGaussian;
        const sigma = @as(f64, spec.sigma) * spec.scale;
        const extent = @ceil(3 * sigma);
        if (extent > max_radius) return error.GaussianRadiusExceeded;
        var result: Kernel = .{ .sigma = spec.sigma, .scale = spec.scale, .radius = @intFromFloat(extent) };
        if (result.radius == 0) {
            result.weights[0] = weight_sum;
            return result;
        }
        var raw: [max_radius + 1]f64 = undefined;
        raw[0] = 1;
        var sum: f64 = 1;
        for (1..result.radius + 1) |index| {
            const x: f64 = @floatFromInt(index);
            raw[index] = @exp(-(x * x) / (2 * sigma * sigma));
            sum += 2 * raw[index];
        }
        const Pair = struct { fraction: f64, index: usize };
        var pairs: [max_radius]Pair = undefined;
        const center: u32 = @intFromFloat(@floor(weight_sum / sum));
        result.weights[result.radius] = center;
        var assigned: u32 = center;
        for (1..result.radius + 1) |index| {
            const exact = raw[index] * weight_sum / sum;
            const integer: u32 = @intFromFloat(@floor(exact));
            result.weights[result.radius - index] = integer;
            result.weights[result.radius + index] = integer;
            assigned += 2 * integer;
            pairs[index - 1] = .{ .fraction = exact - @floor(exact), .index = index };
        }
        std.debug.assert(assigned <= weight_sum);
        const remainder = weight_sum - assigned;
        result.weights[result.radius] += remainder & 1;
        const count = remainder / 2;
        std.debug.assert(count <= result.radius);
        std.mem.sort(Pair, pairs[0..result.radius], {}, struct {
            fn before(_: void, a: Pair, b: Pair) bool {
                return a.fraction > b.fraction or (a.fraction == b.fraction and a.index < b.index);
            }
        }.before);
        for (pairs[0..count]) |pair| {
            result.weights[result.radius - pair.index] += 1;
            result.weights[result.radius + pair.index] += 1;
        }
        try result.validate();
        return result;
    }
    pub fn validate(self: *const Kernel) !void {
        if (!std.math.isFinite(self.sigma) or self.sigma < 0 or !std.math.isFinite(self.scale) or self.scale < 0.0625 or self.scale > 16 or self.radius > max_radius or @ceil(3 * @as(f64, self.sigma) * self.scale) != @as(f64, @floatFromInt(self.radius))) return error.InvalidGaussian;
        var total: u64 = 0;
        for (self.weights[0 .. self.radius * 2 + 1], 0..) |value, index| {
            if (value != self.weights[self.radius * 2 - index]) return error.InvalidGaussian;
            total += value;
        }
        if (total != weight_sum) return error.InvalidGaussian;
        for (self.weights[self.radius * 2 + 1 ..]) |value| if (value != 0) return error.InvalidGaussian;
    }
    pub fn samples(self: *const Kernel, width: u32, height: u32, limit: u64) !u64 {
        try self.validate();
        if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidGaussianSurface;
        const work = if (self.radius == 0) 0 else @as(u64, width) * height * (self.radius * 2 + 1) * 2;
        if (work > limit) return error.GaussianWorkExceeded;
        return work;
    }
};

pub const Plane = struct { pixels: []u32, width: u32, height: u32, stride: u32 };
comptime {
    if (@sizeOf(Kernel) != 1040 or @offsetOf(Kernel, "weights") != 12) @compileError("Gaussian kernel ABI mismatch");
}
fn checkPlane(plane: Plane) !void {
    if (plane.width == 0 or plane.height == 0 or plane.width > 16384 or plane.height > 16384 or @as(u64, plane.width) * plane.height > 16 * 1024 * 1024 or plane.stride < plane.width or @as(u64, plane.stride) * (plane.height - 1) + plane.width > plane.pixels.len) return error.InvalidGaussianSurface;
}
fn overlaps(first: Plane, second: Plane) !bool {
    const first_len = @as(usize, first.stride) * (first.height - 1) + first.width;
    const second_len = @as(usize, second.stride) * (second.height - 1) + second.width;
    const first_end = std.math.add(usize, @intFromPtr(first.pixels.ptr), std.math.mul(usize, first_len, 4) catch return error.InvalidGaussianSurface) catch return error.InvalidGaussianSurface;
    const second_end = std.math.add(usize, @intFromPtr(second.pixels.ptr), std.math.mul(usize, second_len, 4) catch return error.InvalidGaussianSurface) catch return error.InvalidGaussianSurface;
    return @intFromPtr(first.pixels.ptr) < second_end and @intFromPtr(second.pixels.ptr) < first_end;
}

/// Source already has its transparent halo. Horizontal completes before the
/// vertical pass, so source and destination may alias; scratch must not alias
/// either. All validation/work checks precede the first write. No allocations,
/// native calls, callbacks, or ownership changes occur during the borrow.
pub fn apply(kernel: *const Kernel, source: Plane, scratch: Plane, destination: Plane, work_limit: u64, cancellation: ?*const std.atomic.Value(bool), performed: *u64) !void {
    const work = try kernel.samples(source.width, source.height, work_limit);
    try checkPlane(source);
    try checkPlane(destination);
    if (source.width != destination.width or source.height != destination.height) return error.InvalidGaussianSurface;
    if (kernel.radius != 0) {
        try checkPlane(scratch);
        if (scratch.width != source.width or scratch.height != source.height or try overlaps(source, scratch) or try overlaps(destination, scratch)) return error.GaussianPlaneAlias;
    }
    if (cancellation) |flag| if (flag.load(.acquire)) return error.Cancelled;
    if (kernel.radius == 0) {
        if (source.pixels.ptr == destination.pixels.ptr and source.stride == destination.stride) return;
        if (try overlaps(source, destination)) return error.GaussianPlaneAlias;
        for (0..source.height) |y| @memcpy(destination.pixels[y * destination.stride ..][0..source.width], source.pixels[y * source.stride ..][0..source.width]);
        return;
    }
    try pass(kernel, source, scratch, false, cancellation, performed);
    try pass(kernel, scratch, destination, true, cancellation, performed);
    std.debug.assert(work == @as(u64, source.width) * source.height * (kernel.radius * 2 + 1) * 2);
}
noinline fn pass(kernel: *const Kernel, source: Plane, destination: Plane, vertical: bool, cancellation: ?*const std.atomic.Value(bool), performed: *u64) !void {
    const radius: i64 = kernel.radius;
    for (0..source.height) |y| for (0..source.width) |x| {
        if (x % 64 == 0) if (cancellation) |flag| if (flag.load(.acquire)) return error.Cancelled;
        var sum = [_]u32{ 0, 0, 0, 0 };
        for (kernel.weights[0 .. kernel.radius * 2 + 1], 0..) |weight, tap| {
            performed.* +|= 1;
            const delta = @as(i64, @intCast(tap)) - radius;
            const sx = @as(i64, @intCast(x)) + if (vertical) @as(i64, 0) else delta;
            const sy = @as(i64, @intCast(y)) + if (vertical) delta else @as(i64, 0);
            if (sx < 0 or sy < 0 or sx >= source.width or sy >= source.height) continue;
            const pixel = source.pixels[@as(usize, @intCast(sy)) * source.stride + @as(usize, @intCast(sx))];
            inline for (0..4) |channel| sum[channel] += ((pixel >> (channel * 8)) & 255) * weight;
        }
        var output: u32 = 0;
        inline for (0..4) |channel| output |= ((sum[channel] + (weight_sum / 2)) >> 24) << (channel * 8);
        destination.pixels[y * destination.stride + x] = output;
    };
}

test "live Gaussian Q24 kernels normalize exactly and preserve symmetry without epsilon" {
    for ([_]f32{ 0, 1.0e-40, 0.25, 1, 4, 42.5 }) |sigma| {
        const value = try Kernel.prepare(.{ .sigma = sigma });
        try value.validate();
        try std.testing.expectEqual(@as(u32, @intFromFloat(@ceil(3 * @as(f64, sigma)))), value.radius);
        var total: u64 = 0;
        for (value.weights[0 .. value.radius * 2 + 1]) |weight| total += weight;
        try std.testing.expectEqual(@as(u64, weight_sum), total);
    }
    const tiny = try Kernel.prepare(.{ .sigma = 1.0e-40 });
    try std.testing.expectEqual(@as(u32, 1), tiny.radius);
    try std.testing.expectEqual(weight_sum, tiny.weights[1]);
    try std.testing.expectError(error.InvalidGaussian, Kernel.prepare(.{ .sigma = -1 }));
    try std.testing.expectError(error.InvalidGaussian, Kernel.prepare(.{ .sigma = std.math.nan(f32) }));
    try std.testing.expectError(error.GaussianRadiusExceeded, Kernel.prepare(.{ .sigma = 43 }));
}

test "live Gaussian two passes use transparent extension and the independent byte oracle" {
    const kernel = try Kernel.prepare(.{ .sigma = 0.75 });
    const size = 7;
    var pixels = @as([size * size]u32, @splat(0));
    pixels[3 * size + 3] = 0x80402010;
    var scratch = @as([size * size]u32, @splat(0));
    var output = @as([size * size]u32, @splat(0));
    var visits: u64 = 0;
    try apply(&kernel, .{ .pixels = &pixels, .width = size, .height = size, .stride = size }, .{ .pixels = &scratch, .width = size, .height = size, .stride = size }, .{ .pixels = &output, .width = size, .height = size, .stride = size }, 686, null, &visits);
    try std.testing.expectEqual(@as(u64, 686), visits);
    for (0..size) |y| for (0..size) |x| {
        var expected: u32 = 0;
        // An impulse makes the two independent one-dimensional quotients
        // literal; no production sampler is used to compute the oracle.
        inline for (0..4) |channel| {
            const byte: u64 = (pixels[3 * size + 3] >> (channel * 8)) & 255;
            const horizontal = (byte * kernel.weights[x] + (1 << 23)) / (1 << 24);
            const value: u32 = @intCast((horizontal * kernel.weights[y] + (1 << 23)) / (1 << 24));
            expected |= value << (channel * 8);
        }
        try std.testing.expectEqual(expected, output[y * size + x]);
        inline for (0..3) |channel| try std.testing.expect(((output[y * size + x] >> (channel * 8)) & 255) <= output[y * size + x] >> 24);
    };
    try std.testing.expect(output[2 * size + 3] >> 24 > 0);
    try std.testing.expect(output[3 * size + 3] >> 24 < 128);
}

test "live Gaussian rejects budget and aliases before writes and identity needs no scratch" {
    const kernel = try Kernel.prepare(.{ .sigma = 0.25 });
    var source = @as([9]u32, @splat(0xffabcdef));
    var temporary = @as([9]u32, @splat(0));
    var output = @as([9]u32, @splat(0x12345678));
    const first: Plane = .{ .pixels = &source, .width = 3, .height = 3, .stride = 3 };
    const middle: Plane = .{ .pixels = &temporary, .width = 3, .height = 3, .stride = 3 };
    const last: Plane = .{ .pixels = &output, .width = 3, .height = 3, .stride = 3 };
    var visits: u64 = 0;
    try std.testing.expectError(error.GaussianWorkExceeded, apply(&kernel, first, middle, last, 53, null, &visits));
    try std.testing.expectError(error.GaussianPlaneAlias, apply(&kernel, first, first, last, 54, null, &visits));
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Cancelled, apply(&kernel, first, middle, last, 54, &cancelled, &visits));
    try std.testing.expectEqual(@as(u64, 0), visits);
    try std.testing.expectEqualSlices(u32, &(@as([9]u32, @splat(0x12345678))), &output);
    const identity = try Kernel.prepare(.{ .sigma = 0 });
    try apply(&identity, first, .{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0 }, last, 0, null, &visits);
    try std.testing.expectEqualSlices(u32, &source, &output);
    try apply(&kernel, first, middle, first, 54, null, &visits);
    try std.testing.expectEqual(@as(u64, 54), visits);
}

test "live Gaussian rounds only after a full sum and bounds maximum byte accumulation" {
    const kernel = try Kernel.prepare(.{ .sigma = 1 });
    var source = @as([49]u32, @splat(0xffffffff));
    var scratch = @as([49]u32, @splat(0));
    var output = @as([49]u32, @splat(0));
    var visits: u64 = 0;
    try apply(&kernel, .{ .pixels = &source, .width = 7, .height = 7, .stride = 7 }, .{ .pixels = &scratch, .width = 7, .height = 7, .stride = 7 }, .{ .pixels = &output, .width = 7, .height = 7, .stride = 7 }, 686, null, &visits);
    try std.testing.expectEqual(@as(u32, 0xffffffff), output[24]);
    // All seven horizontal taps are present at x=3. An independent rational
    // sum differs from per-tap rounding (which would incorrectly total 256).
    var rounded_each: u64 = 0;
    for (kernel.weights[0..7]) |weight| rounded_each += (@as(u64, weight) * 255 + (1 << 23)) / (1 << 24);
    try std.testing.expect(rounded_each != 255);
    for (0..7) |y| {
        var sum: u64 = 0;
        for (0..7) |row| {
            const tap = @as(i64, @intCast(row)) - @as(i64, @intCast(y)) + 3;
            if (tap >= 0 and tap < 7) sum += @as(u64, kernel.weights[@intCast(tap)]) * 255;
        }
        const expected: u32 = @intCast((sum + (1 << 23)) / (1 << 24));
        try std.testing.expectEqual(expected * 0x01010101, output[y * 7 + 3]);
    }
}
