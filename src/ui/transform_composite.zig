const std = @import("std");
const zio = @import("ziggurat_io");
const affine = @import("affine.zig");
const composite = @import("composite.zig");

/// Borrowed premultiplied BGRA planes. Stride counts pixels, not bytes.
pub const Plane = struct { pixels: [*]u32, width: u32, height: u32, stride: u32 };
pub const Result = struct { visits: u64 = 0, bounds: [4]u32 = .{ 0, 0, 0, 0 } };

/// The source includes one transparent guard texel on each side. Local DIP
/// zero lies at physical coordinate (1,1). Only this bounded rectangle is read;
/// the remaining prepared pool may contain earlier scopes.
pub fn draw(source: Plane, destination: Plane, to_parent: affine.Affine, scale: f32, parent_origin: [2]f64, clip: [4]f64) !u64 {
    return (try drawWithBounds(source, destination, to_parent, scale, parent_origin, clip)).visits;
}

/// All fallible geometry checks precede the first write. The caller may mark
/// this exact physical rectangle dirty after synchronously returning the borrow.
pub fn drawWithBounds(source: Plane, destination: Plane, to_parent: affine.Affine, scale: f32, parent_origin: [2]f64, clip: [4]f64) !Result {
    const inverse = try to_parent.inverse();
    const padded = try to_parent.mapBounds(.{ .x = -1 / @as(f64, scale), .y = -1 / @as(f64, scale), .width = @as(f64, @floatFromInt(source.width)) / scale, .height = @as(f64, @floatFromInt(source.height)) / scale });
    const left = @max(0, @floor(@max(clip[0], padded.x * scale + parent_origin[0])));
    const top = @max(0, @floor(@max(clip[1], padded.y * scale + parent_origin[1])));
    const right = @min(@as(f64, @floatFromInt(destination.width)), @ceil(@min(clip[2], (padded.x + padded.width) * scale + parent_origin[0])));
    const bottom = @min(@as(f64, @floatFromInt(destination.height)), @ceil(@min(clip[3], (padded.y + padded.height) * scale + parent_origin[1])));
    if (left >= right or top >= bottom) return .{};
    const x0: u32 = @intFromFloat(left);
    const y0: u32 = @intFromFloat(top);
    const x1: u32 = @intFromFloat(right);
    const y1: u32 = @intFromFloat(bottom);
    if (Grid.init(inverse, scale, parent_origin)) |grid| {
        drawGrid(source, destination, grid, .{ x0, y0, x1, y1 }, clip);
        return .{ .visits = @as(u64, x1 - x0) * (y1 - y0), .bounds = .{ x0, y0, x1, y1 } };
    }
    for (y0..y1) |y| {
        const py = (@as(f64, @floatFromInt(y)) + 0.5 - parent_origin[1]) / scale;
        const fy: f64 = @floatFromInt(y);
        const row_amount = @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1]));
        const full_left: u32 = @intFromFloat(@ceil(@max(left, clip[0])));
        const full_right: u32 = @intFromFloat(@floor(@min(right, clip[2])));
        if (row_amount == 1 and full_left < full_right) {
            filteredRun(source, destination, inverse, scale, parent_origin, clip, y, py, row_amount, x0, full_left);
            var x = full_left;
            while (full_right - x >= 8) : (x += 8) {
                const pixels = mappedSamples(source, inverse, scale, parent_origin[0], x, py);
                overRow(destination.pixels[y * destination.stride + x ..][0..8], &pixels, 0, 1);
            }
            filteredRun(source, destination, inverse, scale, parent_origin, clip, y, py, row_amount, x, x1);
        } else {
            filteredRun(source, destination, inverse, scale, parent_origin, clip, y, py, row_amount, x0, x1);
        }
    }
    return .{ .visits = @as(u64, x1 - x0) * (y1 - y0), .bounds = .{ x0, y0, x1, y1 } };
}

inline fn mappedSample(source: Plane, inverse: affine.Affine, scale: f32, origin_x: f64, x: usize, py: f64) u32 {
    const px = (@as(f64, @floatFromInt(x)) + 0.5 - origin_x) / scale;
    const sx = (inverse.xx * px + inverse.xy * py + inverse.x0) * scale + 0.5;
    const sy = (inverse.yx * px + inverse.yy * py + inverse.y0) * scale + 0.5;
    return sample(source, sx, sy);
}

fn mappedSamples(source: Plane, inverse: affine.Affine, scale: f32, origin_x: f64, x: u32, py: f64) [8]u32 {
    const V = @Vector(8, f64);
    const U = @Vector(8, u32);
    const positions = @as(V, @splat(@as(f64, @floatFromInt(x)))) + V{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const half: V = @splat(0.5);
    const scales: V = @splat(scale);
    const px = (positions + half - @as(V, @splat(origin_x))) / scales;
    const sx = (@as(V, @splat(inverse.xx)) * px + @as(V, @splat(inverse.xy * py)) + @as(V, @splat(inverse.x0))) * scales + half;
    const sy = (@as(V, @splat(inverse.yx)) * px + @as(V, @splat(inverse.yy * py)) + @as(V, @splat(inverse.y0))) * scales + half;
    // Convert indices only after all lanes are in the four-tap interior. The
    // boundary fallback also handles arbitrarily distant mapped coordinates.
    const interior = (sx >= @as(V, @splat(0))) & (sy >= @as(V, @splat(0))) & (sx < @as(V, @splat(@as(f64, @floatFromInt(source.width)) - 1))) & (sy < @as(V, @splat(@as(f64, @floatFromInt(source.height)) - 1)));
    if (!@reduce(.And, interior)) {
        var result: [8]u32 = undefined;
        for (&result, 0..) |*pixel, i| pixel.* = mappedSample(source, inverse, scale, origin_x, @as(usize, x) + i, py);
        return result;
    }
    const bx = @floor(sx);
    const by = @floor(sy);
    const ix: @Vector(8, u32) = @intFromFloat(bx);
    const iy: @Vector(8, u32) = @intFromFloat(by);
    const fx = sx - bx;
    const fy = sy - by;
    const one: V = @splat(1);
    const weights = [4]V{ (one - fx) * (one - fy), fx * (one - fy), (one - fx) * fy, fx * fy };
    var taps: [4]U = undefined;
    inline for (0..8) |lane| {
        const index = @as(usize, iy[lane]) * source.stride + ix[lane];
        taps[0][lane] = source.pixels[index];
        taps[1][lane] = source.pixels[index + 1];
        taps[2][lane] = source.pixels[index + source.stride];
        taps[3][lane] = source.pixels[index + source.stride + 1];
    }
    var result: U = @splat(0);
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const shifts: @Vector(8, u5) = @splat(shift);
        var values: V = @as(V, @floatFromInt((taps[0] >> shifts) & @as(U, @splat(255)))) * weights[0];
        inline for (1..4) |tap| values += @as(V, @floatFromInt((taps[tap] >> shifts) & @as(U, @splat(255)))) * weights[tap];
        values = @min(@as(V, @splat(255)), @max(@as(V, @splat(0)), values));
        const base = @floor(values);
        const rounded: U = @intFromFloat(base + @select(f64, values - base >= half, one, @as(V, @splat(0))));
        result |= rounded << shifts;
    }
    return result;
}

fn filteredRun(source: Plane, destination: Plane, inverse: affine.Affine, scale: f32, origin: [2]f64, clip: [4]f64, y: usize, py: f64, row_amount: f64, left: u32, right: u32) void {
    for (left..right) |x| {
        const pixel = mappedSample(source, inverse, scale, origin[0], x, py);
        if (pixel >> 24 == 0) continue;
        const fx: f64 = @floatFromInt(x);
        const amount = @max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0])) * row_amount;
        const index = y * destination.stride + x;
        destination.pixels[index] = if (amount == 1) composite.overFull(pixel, destination.pixels[index]) else composite.over(pixel, destination.pixels[index], amount);
    }
}

/// A signed permutation preserves the physical texel lattice. Both physical
/// translations must be exact half-integers before the half-texel phase is
/// combined; the final phase must be integral. The bounded i64 map then selects
/// exactly the one nonzero tap of the bilinear kernel, including guard texels.
const Grid = struct {
    xx: i64,
    xy: i64,
    yx: i64,
    yy: i64,
    x0: i64,
    y0: i64,

    fn init(inverse: affine.Affine, scale: f32, origin: [2]f64) ?Grid {
        const diagonal = @abs(inverse.xx) == 1 and @abs(inverse.yy) == 1 and inverse.xy == 0 and inverse.yx == 0;
        const swapped = @abs(inverse.xy) == 1 and @abs(inverse.yx) == 1 and inverse.xx == 0 and inverse.yy == 0;
        if (!diagonal and !swapped) return null;
        if (!std.math.isFinite(scale) or scale < 0.25 or scale > 8) return null;
        const tx = inverse.x0 * scale;
        const ty = inverse.y0 * scale;
        // FMA checks the product residual; a rounded large integer is not an
        // exact physical translation. Restrict cancellation as well: with u32
        // destination indices, scale [.25,8] and these bounded terms, the old
        // divide/add/multiply map differs by less than 1/4096 texel per axis.
        // Two bilinear axes then change a byte by <2*255/4096, below half a
        // byte. Thus its rounded sample is the exact lattice texel too.
        if (@mulAdd(f64, inverse.x0, scale, -tx) != 0 or @mulAdd(f64, inverse.y0, scale, -ty) != 0) return null;
        for ([_]f64{ tx, ty, origin[0], origin[1] }) |value| {
            if (!std.math.isFinite(value) or @abs(value) > 65536 or value * 2 != @trunc(value * 2)) return null;
        }
        const x = (inverse.xx + inverse.xy + 1) * 0.5 + tx - inverse.xx * origin[0] - inverse.xy * origin[1];
        const y = (inverse.yx + inverse.yy + 1) * 0.5 + ty - inverse.yx * origin[0] - inverse.yy * origin[1];
        if (x != @trunc(x) or y != @trunc(y)) return null;
        return .{ .xx = @intFromFloat(inverse.xx), .xy = @intFromFloat(inverse.xy), .yx = @intFromFloat(inverse.yx), .yy = @intFromFloat(inverse.yy), .x0 = @intFromFloat(x), .y0 = @intFromFloat(y) };
    }
};

fn drawGrid(source: Plane, destination: Plane, grid: Grid, bounds: [4]u32, clip: [4]f64) void {
    for (bounds[1]..bounds[3]) |y| {
        const yi: i64 = @intCast(y);
        const fy: f64 = @floatFromInt(y);
        const row_amount = @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1]));
        const sy = grid.yy * yi + grid.y0;
        if (grid.xy == 0 and row_amount == 1 and sy >= 0 and sy < source.height) {
            const source_left = if (grid.xx == 1) -grid.x0 else grid.x0 - source.width + 1;
            const source_right = if (grid.xx == 1) @as(i64, source.width) - grid.x0 else grid.x0 + 1;
            const full_left = @max(@as(i64, @intFromFloat(@ceil(@max(@as(f64, @floatFromInt(bounds[0])), clip[0])))), source_left);
            const full_right = @min(@as(i64, @intFromFloat(@floor(@min(@as(f64, @floatFromInt(bounds[2])), clip[2])))), source_right);
            if (full_left < full_right) {
                const left: u32 = @intCast(zio.asUnsigned(full_left));
                const right: u32 = @intCast(zio.asUnsigned(full_right));
                drawGridRun(source, destination, grid, y, bounds[0], left, row_amount, clip);
                const sx = grid.xx * full_left + grid.x0;
                overRow(destination.pixels[y * destination.stride + left ..][0 .. right - left], source.pixels, @as(usize, @intCast(sy)) * source.stride + @as(usize, @intCast(sx)), grid.xx);
                drawGridRun(source, destination, grid, y, right, bounds[2], row_amount, clip);
                continue;
            }
        }
        drawGridRun(source, destination, grid, y, bounds[0], bounds[2], row_amount, clip);
    }
}

fn drawGridRun(source: Plane, destination: Plane, grid: Grid, y: usize, left: u32, right: u32, row_amount: f64, clip: [4]f64) void {
    const yi: i64 = @intCast(y);
    var sx = grid.xx * left + grid.xy * yi + grid.x0;
    var sy = grid.yx * left + grid.yy * yi + grid.y0;
    for (left..right) |x| {
        defer {
            sx += grid.xx;
            sy += grid.yx;
        }
        if (sx < 0 or sy < 0 or sx >= source.width or sy >= source.height) continue;
        const pixel = source.pixels[@as(usize, @intCast(sy)) * source.stride + @as(usize, @intCast(sx))];
        if (pixel >> 24 == 0) continue;
        const fx: f64 = @floatFromInt(x);
        const amount = row_amount * @max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0]));
        const index = y * destination.stride + x;
        destination.pixels[index] = if (amount == 1) composite.overFull(pixel, destination.pixels[index]) else composite.over(pixel, destination.pixels[index], amount);
    }
}

fn overRow(destination: []u32, source: [*]const u32, initial: usize, direction: i64) void {
    const V = @Vector(8, u32);
    var i: usize = 0;
    while (destination.len - i >= 8) : (i += 8) {
        const input: V = if (direction == 1) source[initial + i ..][0..8].* else @shuffle(u32, source[initial - i - 7 ..][0..8].*, undefined, [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 });
        const alpha = input >> @as(@Vector(8, u5), @splat(24));
        if (@reduce(.And, alpha == @as(V, @splat(255)))) {
            destination[i..][0..8].* = input;
        } else if (!@reduce(.And, alpha == @as(V, @splat(0)))) {
            const before: V = destination[i..][0..8].*;
            const inverse = @as(V, @splat(255)) - alpha;
            var result: V = @splat(0);
            inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const shifts: @Vector(8, u5) = @splat(shift);
                const eights: @Vector(8, u5) = @splat(8);
                const term = ((before >> shifts) & @as(V, @splat(255))) * inverse + @as(V, @splat(128));
                // For products in [0,65025], this is exactly round(n/255).
                const channel: V = @min(@as(V, @splat(255)), ((input >> shifts) & @as(V, @splat(255))) + ((term + (term >> eights)) >> eights));
                result |= channel << shifts;
            }
            destination[i..][0..8].* = @select(u32, alpha == @as(V, @splat(0)), before, result);
        }
    }
    while (i < destination.len) : (i += 1) {
        destination[i] = composite.overFull(source[if (direction == 1) initial + i else initial - i], destination[i]);
    }
}

fn sample(source: Plane, x: f64, y: f64) u32 {
    if (x <= -1 or y <= -1 or x >= @as(f64, @floatFromInt(source.width)) or y >= @as(f64, @floatFromInt(source.height))) return 0;
    const floor_x = @floor(x);
    const floor_y = @floor(y);
    const ix: i64 = @intFromFloat(floor_x);
    const iy: i64 = @intFromFloat(floor_y);
    const fx = x - floor_x;
    const fy = y - floor_y;
    if (ix >= 0 and iy >= 0 and ix + 1 < source.width and iy + 1 < source.height) {
        const index = @as(usize, @intCast(iy)) * source.stride + @as(usize, @intCast(ix));
        return interpolate(source.pixels[index], source.pixels[index + 1], source.pixels[index + source.stride], source.pixels[index + source.stride + 1], fx, fy);
    }
    var channels: [4]f64 = @splat(0);
    for (0..2) |dy| for (0..2) |dx| {
        const sx = ix + @as(i64, @intCast(dx));
        const sy = iy + @as(i64, @intCast(dy));
        if (sx < 0 or sy < 0 or sx >= source.width or sy >= source.height) continue;
        const weight = (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy);
        const pixel = source.pixels[@as(usize, @intCast(sy)) * source.stride + @as(usize, @intCast(sx))];
        inline for (0..4) |channel| channels[channel] += @as(f64, @floatFromInt((pixel >> @as(u5, @intCast(channel * 8))) & 255)) * weight;
    };
    var result: u32 = 0;
    inline for (0..4) |channel| result |= @as(u32, @intFromFloat(std.math.clamp(@round(channels[channel]), 0, 255))) << @as(u5, @intCast(channel * 8));
    return result;
}

fn unpack(pixel: u32) @Vector(4, f64) {
    const values = (@as(@Vector(4, u32), @splat(pixel)) >> @as(@Vector(4, u5), .{ 0, 8, 16, 24 })) & @as(@Vector(4, u32), @splat(255));
    return @floatFromInt(values);
}

fn interpolate(a: u32, b: u32, c: u32, d: u32, x: f64, y: f64) u32 {
    const V = @Vector(4, f64);
    // Preserve the scalar tap order and its f64 weights. All four channels
    // share the same samples; positive half-away rounding uses an exact
    // fraction comparison, avoiding the half-predecessor trap of floor(v+.5).
    var values = unpack(a) * @as(V, @splat((1 - x) * (1 - y)));
    values += unpack(b) * @as(V, @splat(x * (1 - y)));
    values += unpack(c) * @as(V, @splat((1 - x) * y));
    values += unpack(d) * @as(V, @splat(x * y));
    values = @min(@as(V, @splat(255)), @max(@as(V, @splat(0)), values));
    const base = @floor(values);
    const rounded: @Vector(4, u32) = @intFromFloat(base + @select(f64, values - base >= @as(V, @splat(0.5)), @as(V, @splat(1)), @as(V, @splat(0))));
    const shifted = rounded << @as(@Vector(4, u5), .{ 0, 8, 16, 24 });
    return @reduce(.Or, shifted);
}

test "guarded affine sampling keeps premultiplication and consumes parent clip once" {
    var source = [_]u32{ 0, 0, 0, 0, 0, 0xffff0000, 0xffff0000, 0, 0, 0xffff0000, 0xffff0000, 0, 0, 0, 0, 0 };
    var output: [64]u32 = @splat(0);
    const plane: Plane = .{ .pixels = &source, .width = 4, .height = 4, .stride = 4 };
    const target: Plane = .{ .pixels = &output, .width = 8, .height = 8, .stride = 8 };
    _ = try draw(plane, target, .{ .x0 = 2, .y0 = 2 }, 1, .{ 0, 0 }, .{ 0, 0, 8, 8 });
    try std.testing.expectEqual(@as(u32, 0xffff0000), output[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0), output[2 * 8 + 1]);
    @memset(&output, 0);
    _ = try draw(plane, target, .{ .x0 = 2.5, .y0 = 2 }, 1, .{ 0, 0 }, .{ 2.25, 0, 8, 8 });
    try std.testing.expectEqual(@as(u32, 0x60600000), output[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), output[2 * 8 + 3]);
    try std.testing.expectEqual(@as(u32, 0x80800000), output[2 * 8 + 4]);
}

test "raster scope reflection maps the full transparent source and arbitrary parent origins" {
    var source = [_]u32{ 0, 0, 0, 0, 0, 0xff0000ff, 0xffff0000, 0, 0, 0, 0, 0 };
    var output: [36]u32 = @splat(0);
    _ = try draw(.{ .pixels = &source, .width = 4, .height = 3, .stride = 4 }, .{ .pixels = &output, .width = 6, .height = 6, .stride = 6 }, .{ .xx = -1, .x0 = 3, .y0 = 1 }, 1, .{ 1, 1 }, .{ 0, 0, 6, 6 });
    try std.testing.expectEqual(@as(u32, 0xffff0000), output[2 * 6 + 2]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), output[2 * 6 + 3]);
}

test "tracked affine composition reports tight physical writes and empty clips do not write" {
    var source: [16]u32 = @splat(0);
    source[5] = 0xffff0000;
    var output: [64]u32 = @splat(0);
    const src: Plane = .{ .pixels = &source, .width = 4, .height = 4, .stride = 4 };
    const dst: Plane = .{ .pixels = &output, .width = 8, .height = 8, .stride = 8 };
    const result = try drawWithBounds(src, dst, .{}, 1, .{ 0, 0 }, .{ 0, 0, 8, 8 });
    try std.testing.expectEqual(@as(u64, 9), result.visits);
    try std.testing.expectEqual([4]u32{ 0, 0, 3, 3 }, result.bounds);
    const before = output;
    try std.testing.expectEqualDeep(Result{}, try drawWithBounds(src, dst, .{}, 1, .{ 0, 0 }, .{ 4, 4, 8, 8 }));
    try std.testing.expectEqualSlices(u32, &before, &output);
    try std.testing.expectError(error.InvalidTransform, drawWithBounds(src, dst, .{ .xx = 0 }, 1, .{ 0, 0 }, .{ 0, 0, 8, 8 }));
    try std.testing.expectEqualSlices(u32, &before, &output);
}

test "one tap eligibility requires an exact signed physical lattice" {
    try std.testing.expect(Grid.init(.{}, 1.5, .{ 1, 1 }) != null);
    try std.testing.expect(Grid.init(.{ .x0 = 2, .y0 = -2 }, 1.5, .{ 1, 1 }) != null);
    try std.testing.expect(Grid.init(.{ .x0 = 1 }, 1.5, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .xx = 0, .yy = 0, .xy = -1, .yx = 1 }, 2, .{ 1, 1 }) != null);
    try std.testing.expect(Grid.init(.{ .x0 = 0.25 }, 1, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .xx = 0.5 }, 1, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .xy = 1 }, 1, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .x0 = 0x1.0000000000001p40 }, 1.5, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .x0 = 0x1p49 }, 1, .{ 0, 0 }) == null);
    try std.testing.expect(Grid.init(.{ .x0 = 0x1p47 }, 1.5, .{ 3 * 0x1p46, 0 }) == null);
}

test "one tap matches four tap scalar output for guards strides permutations and fractional clip" {
    var random = std.Random.DefaultPrng.init(0xa781987);
    const rng = random.random();
    var source: [17 * 9]u32 = @splat(0);
    var actual: [33 * 19]u32 = undefined;
    var expected: [33 * 19]u32 = undefined;
    const src: Plane = .{ .pixels = &source, .width = 13, .height = 9, .stride = 17 };
    const dst: Plane = .{ .pixels = &actual, .width = 29, .height = 19, .stride = 33 };
    for (0..768) |iteration| {
        for (&source, 0..) |*pixel, i| {
            pixel.* = if (i % 17 >= 1 and i % 17 < 12 and i / 17 >= 1 and i / 17 < 8) composite.tintByte(rng.int(u32), rng.int(u8)) else 0;
        }
        for (&actual) |*pixel| pixel.* = composite.tintByte(rng.int(u32), rng.int(u8));
        expected = actual;
        const scale: f32 = ([_]f32{ 1, 1.5, 2 })[iteration % 3];
        const origin = [2]f64{ @floatFromInt(iteration % 2), @floatFromInt((iteration / 2) % 2) };
        const mx: f64 = if (iteration % 2 == 0) 1 else -1;
        const my: f64 = if ((iteration / 2) % 2 == 0) 1 else -1;
        const swapped = (iteration / 4) % 2 == 0;
        const transform: affine.Affine = .{
            .xx = if (swapped) 0 else mx,
            .xy = if (swapped) mx else 0,
            .yx = if (swapped) my else 0,
            .yy = if (swapped) 0 else my,
            .x0 = @floatFromInt(2 * rng.intRangeAtMost(i32, -3, 10)),
            .y0 = @floatFromInt(2 * rng.intRangeAtMost(i32, -3, 8)),
        };
        const inverse = try transform.inverse();
        try std.testing.expect(Grid.init(inverse, scale, origin) != null);
        const clip = [4]f64{ @as(f64, @floatFromInt(rng.intRangeAtMost(u32, 0, 4))) + 0.25, 0.75, 28.5, 18.25 };
        _ = try drawWithBounds(src, dst, transform, scale, origin, clip);
        for (0..19) |y| for (0..29) |x| {
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            const px = (fx + 0.5 - origin[0]) / scale;
            const py = (fy + 0.5 - origin[1]) / scale;
            const sx = (inverse.xx * px + inverse.xy * py + inverse.x0) * scale + 0.5;
            const sy = (inverse.yx * px + inverse.yy * py + inverse.y0) * scale + 0.5;
            const pixel = sample(src, sx, sy);
            const amount = @max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0])) * @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1]));
            if (amount == 0 or pixel >> 24 == 0) continue;
            const index = y * 33 + x;
            expected[index] = if (amount == 1) composite.overFull(pixel, expected[index]) else composite.over(pixel, expected[index], amount);
        };
        try std.testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "packed contiguous rows exactly preserve source over in both directions and all tails" {
    for (0..256) |a| for (0..256) |b| {
        const product = a * b;
        const term = product + 128;
        try std.testing.expectEqual((product + 127) / 255, (term + (term >> 8)) >> 8);
    };
    var random = std.Random.DefaultPrng.init(0x8b4e);
    const rng = random.random();
    var source: [48]u32 = undefined;
    var actual: [40]u32 = undefined;
    var expected: [40]u32 = undefined;
    for (0..512) |iteration| {
        for (&source) |*pixel| pixel.* = switch (iteration % 4) {
            0 => rng.int(u32) | 0xff000000,
            1 => rng.int(u32) & 0x00ffffff,
            else => rng.int(u32),
        };
        for (&actual) |*pixel| pixel.* = rng.int(u32);
        expected = actual;
        const count = iteration % 41;
        const reverse = iteration % 2 != 0;
        const initial: usize = if (reverse) 45 else 3;
        for (expected[0..count], 0..) |*pixel, i| pixel.* = composite.overFull(source[if (reverse) initial - i else initial + i], pixel.*);
        overRow(actual[0..count], &source, initial, if (reverse) -1 else 1);
        try std.testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "four channel interpolation is exactly the scalar tap and rounding order" {
    var random = std.Random.DefaultPrng.init(0xbee789d);
    const rng = random.random();
    for (0..50000) |iteration| {
        const pixels = [4]u32{ rng.int(u32), rng.int(u32), rng.int(u32), rng.int(u32) };
        const x: f64 = switch (iteration % 6) {
            0 => 0,
            1 => 1,
            2 => std.math.nextAfter(f64, 0.5, 0),
            3 => std.math.nextAfter(f64, 0.5, 1),
            4 => 0.5,
            else => rng.float(f64),
        };
        const y = rng.float(f64);
        var channels: [4]f64 = @splat(0);
        for (0..2) |dy| for (0..2) |dx| {
            const weight = (if (dx == 0) 1 - x else x) * (if (dy == 0) 1 - y else y);
            inline for (0..4) |channel| channels[channel] += @as(f64, @floatFromInt((pixels[dy * 2 + dx] >> @as(u5, @intCast(channel * 8))) & 255)) * weight;
        };
        var expected: u32 = 0;
        inline for (0..4) |channel| expected |= @as(u32, @intFromFloat(std.math.clamp(@round(channels[channel]), 0, 255))) << @as(u5, @intCast(channel * 8));
        try std.testing.expectEqual(expected, interpolate(pixels[0], pixels[1], pixels[2], pixels[3], x, y));
    }
    try std.testing.expectEqual(@as(u32, 0), interpolate(0, 0x01010101, 0, 0, std.math.nextAfter(f64, 0.5, 0), 0));
    try std.testing.expectEqual(@as(u32, 0x01010101), interpolate(0, 0x01010101, 0, 0, 0.5, 0));
}

test "filtered batches preserve scalar mapping quantization clipping and partial tails" {
    var random = std.Random.DefaultPrng.init(0x6b78df);
    const rng = random.random();
    var source: [27 * 17]u32 = @splat(0);
    var actual: [37 * 27]u32 = undefined;
    var expected: [37 * 27]u32 = undefined;
    const src: Plane = .{ .pixels = &source, .width = 23, .height = 17, .stride = 27 };
    const dst: Plane = .{ .pixels = &actual, .width = 33, .height = 27, .stride = 37 };
    for (0..256) |iteration| {
        for (&source, 0..) |*pixel, i| pixel.* = if (i % 27 >= 1 and i % 27 < 22 and i / 27 >= 1 and i / 27 < 16) composite.tintByte(rng.int(u32), rng.int(u8)) else 0;
        for (&actual) |*pixel| pixel.* = composite.tintByte(rng.int(u32), rng.int(u8));
        expected = actual;
        const scale: f32 = ([_]f32{ 1, 1.5, 2 })[iteration % 3];
        const origin = [2]f64{ @floatFromInt(iteration % 2), @floatFromInt((iteration / 2) % 2) };
        const transform: affine.Affine = .{ .xx = 0.5 + rng.float(f64), .xy = rng.float(f64) - 0.5, .yx = rng.float(f64) - 0.5, .yy = 0.75 + rng.float(f64), .x0 = 4 * rng.float(f64) - 2, .y0 = 4 * rng.float(f64) - 2 };
        const inverse = try transform.inverse();
        const clip = [4]f64{ @as(f64, @floatFromInt(iteration % 6)) + 0.25, 0.75, 33 - @as(f64, @floatFromInt((iteration / 6) % 5)) - 0.5, 26.25 };
        _ = try drawWithBounds(src, dst, transform, scale, origin, clip);
        for (0..27) |y| for (0..33) |x| {
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            const px = (fx + 0.5 - origin[0]) / scale;
            const py = (fy + 0.5 - origin[1]) / scale;
            const sx = (inverse.xx * px + inverse.xy * py + inverse.x0) * scale + 0.5;
            const sy = (inverse.yx * px + inverse.yy * py + inverse.y0) * scale + 0.5;
            const pixel = sample(src, sx, sy);
            const amount = @max(0, @min(fx + 1, clip[2]) - @max(fx, clip[0])) * @max(0, @min(fy + 1, clip[3]) - @max(fy, clip[1]));
            if (amount == 0 or pixel >> 24 == 0) continue;
            const index = y * 37 + x;
            expected[index] = if (amount == 1) composite.overFull(pixel, expected[index]) else composite.over(pixel, expected[index], amount);
        };
        try std.testing.expectEqualSlices(u32, &expected, &actual);
    }
}

test "eight pixel SoA preserves per lane mapping and all scalar taps including boundaries" {
    var random = std.Random.DefaultPrng.init(0xcaf9b3);
    const rng = random.random();
    var pixels: [79 * 53]u32 = undefined;
    for (&pixels) |*pixel| pixel.* = rng.int(u32);
    const plane: Plane = .{ .pixels = &pixels, .width = 70, .height = 53, .stride = 79 };
    for (0..25000) |iteration| {
        const scale = ([_]f32{ 0.25, 0.5, 1, 1.5, 2, 8 })[iteration % 6];
        const inverse: affine.Affine = .{ .xx = 0.125 + rng.float(f64), .xy = rng.float(f64) - 0.5, .yx = rng.float(f64) - 0.5, .yy = 0.25 + rng.float(f64), .x0 = 20 * rng.float(f64) - 10, .y0 = 20 * rng.float(f64) - 10 };
        const origin: f64 = switch (iteration % 3) {
            0 => 1,
            1 => -1000000,
            else => rng.float(f64),
        };
        const x = rng.intRangeAtMost(u32, 0, 100);
        const py = rng.float(f64) * 50;
        const result = mappedSamples(plane, inverse, scale, origin, x, py);
        for (result, 0..) |actual, lane| try std.testing.expectEqual(mappedSample(plane, inverse, scale, origin, x + lane, py), actual);
    }
}
