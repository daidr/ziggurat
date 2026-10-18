const std = @import("std");
const math = @import("radial_math.zig");
const Big = std.math.big.int.Managed;
const allocator = std.testing.allocator;
const Circle = struct { cx: f64 = 0, cy: f64 = 0, fx: f64 = 0, fy: f64 = 0, first: f64 = 0, last: f64 };

// Encode every finite binary64 as an integer times 2^-1074. All subtraction,
// squaring and classification below is integer arithmetic, independent of the
// floating-point production predicate and of binary128 rounding.
fn integer(value: f64) !Big {
    const bits: u64 = @bitCast(value);
    const exponent = (bits >> 52) & 0x7ff;
    std.debug.assert(exponent != 0x7ff);
    const fraction = bits & 0x000f_ffff_ffff_ffff;
    const significand = if (exponent == 0) fraction else fraction | (@as(u64, 1) << 52);
    var result = try Big.initSet(allocator, significand);
    errdefer result.deinit();
    if (exponent != 0) try result.shiftLeft(&result, @intCast(exponent - 1));
    result.setSign(bits >> 63 == 0);
    return result;
}
fn squaredDifference(a: f64, b: f64) !Big {
    var left = try integer(a);
    defer left.deinit();
    var right = try integer(b);
    defer right.deinit();
    var difference = try Big.init(allocator);
    defer difference.deinit();
    try difference.sub(&left, &right);
    var result = try Big.init(allocator);
    errdefer result.deinit();
    try result.mul(&difference, &difference);
    return result;
}
fn exactSign(circle: Circle) !std.math.Order {
    var xx = try squaredDifference(circle.cx, circle.fx);
    defer xx.deinit();
    var yy = try squaredDifference(circle.cy, circle.fy);
    defer yy.deinit();
    var rr = try squaredDifference(circle.last, circle.first);
    defer rr.deinit();
    var sum = try Big.init(allocator);
    defer sum.deinit();
    try sum.add(&xx, &yy);
    return sum.toConst().order(rr.toConst());
}
fn coefficient(circle: Circle) !f64 {
    const dx = try math.subtract(circle.cx, circle.fx);
    const dy = try math.subtract(circle.cy, circle.fy);
    const dr = try math.subtract(circle.last, circle.first);
    const extent = @max(@abs(dx.value), @abs(dy.value), circle.first, circle.last);
    const unit = std.math.ldexp(@as(f64, 1), std.math.frexp(extent).exponent - 1);
    return math.quadratic(dx, dy, dr, unit);
}
fn verify(circle: Circle) !bool {
    const expected = try exactSign(circle);
    const a = coefficient(circle) catch |err| {
        try std.testing.expectEqual(error.UnsupportedRadialPrecision, err);
        return false;
    };
    try std.testing.expectEqual(expected, std.math.order(a, @as(f64, 0)));
    return true;
}

test "radial exact dyadic predicate preserves tiny perpendicular separation" {
    const tiny = 1e-30;
    // Direct binary128 addition loses tiny^2 between the two unit squares.
    try std.testing.expectEqual(@as(f128, 0), 1 + @as(f128, tiny) * tiny - 1);
    const a = try coefficient(.{ .fx = 1, .cx = 2, .cy = tiny, .last = 1 });
    try std.testing.expect(a > 0);
    try std.testing.expect(try verify(.{ .fx = 1, .cx = 2, .cy = tiny, .last = 1 }));
    try std.testing.expectError(error.UnsupportedRadialPrecision, coefficient(.{ .cx = 1, .cy = std.math.floatTrueMin(f64), .last = 1 }));
}

test "radial factored sign agrees with exact integers across axes signs and exponents" {
    var accepted: usize = 0;
    const triples = [_][3]f64{ .{ 3, 4, 5 }, .{ 5, 12, 13 }, .{ 8, 15, 17 }, .{ 7, 24, 25 } };
    for ([_]i32{ -1000, -500, -1, 0, 500, 1000 }) |exponent| {
        const scale = std.math.ldexp(@as(f64, 1), exponent);
        for (triples) |triple| for ([_]bool{ false, true }) |swap| for ([_]f64{ -1, 1 }) |sx| for ([_]f64{ -1, 1 }) |sy| {
            const radius = triple[2] * scale;
            for ([_]f64{ std.math.nextAfter(f64, radius, 0), radius, std.math.nextAfter(f64, radius, std.math.inf(f64)) }) |last| {
                const circle: Circle = .{ .cx = sx * triple[@intFromBool(swap)] * scale, .cy = sy * triple[@intFromBool(!swap)] * scale, .last = last };
                try std.testing.expect(try verify(circle));
                accepted += 1;
            }
        };
        // Dominated and nonnegative branches of the max-axis factorization.
        for ([_]f64{ 0, 0.25, 1, 1.5, 2, 4 }) |radius| {
            try std.testing.expect(try verify(.{ .cx = scale, .cy = 0.25 * scale, .last = radius * scale }));
            accepted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 612), accepted);
}

test "radial coordinate residuals cannot invent exact tangent or change its sign" {
    const ambiguous: Circle = .{ .fx = 1, .cx = -1e-30, .last = 1 };
    const difference = try math.subtract(ambiguous.cx, ambiguous.fx);
    try std.testing.expectEqual(@as(f64, -1), difference.value);
    try std.testing.expect(difference.residual != 0);
    try std.testing.expectEqual(std.math.Order.gt, try exactSign(ambiguous));
    try std.testing.expectError(error.UnsupportedRadialPrecision, coefficient(ambiguous));
    var random = std.Random.DefaultPrng.init(0xf5a2_81cb_6739_0d4e);
    var accepted: usize = 0;
    for (0..1024) |index| {
        const exponent: i32 = @as(i32, @intCast(index % 1201)) - 600;
        const scale = std.math.ldexp(@as(f64, 1), exponent);
        const rng = random.random();
        const circle: Circle = .{
            .cx = (rng.float(f64) - 0.5) * scale,
            .cy = (rng.float(f64) - 0.5) * scale,
            .fx = (rng.float(f64) - 0.5) * scale,
            .fy = (rng.float(f64) - 0.5) * scale,
            .first = rng.float(f64) * scale,
            .last = rng.float(f64) * scale,
        };
        if (try verify(circle)) accepted += 1;
    }
    try std.testing.expect(accepted > 1000);
}

test "radial extreme exponent separation retains sign or explicitly refuses precision" {
    const maximum = std.math.floatMax(f64);
    const minimum = std.math.floatTrueMin(f64);
    for ([_]Circle{
        .{ .cx = maximum, .cy = maximum, .last = maximum },
        .{ .cx = minimum, .cy = minimum, .last = minimum },
        .{ .cx = maximum, .last = maximum / 2 },
        .{ .cx = minimum, .last = maximum },
    }) |circle| try std.testing.expect(try verify(circle));
    for ([_]i32{ -1074, -1022, -800, -600, -500, -100, -54, -53, -52, 0 }) |exponent| {
        const tiny = std.math.ldexp(@as(f64, 1), exponent);
        for ([_]bool{ false, true }) |swap| for ([_]f64{ -1, 1 }) |sign| {
            // Tiny perpendicular components may be representable in A, or
            // explicitly underflow after normalization. Neither may become 0.
            _ = try verify(.{ .cx = if (swap) tiny else sign, .cy = if (swap) sign else tiny, .last = 1 });
            // Subtracting a tiny center from a unit focus has a real residual.
            // The exact integer oracle also covers the original coordinates.
            _ = try verify(.{ .fx = if (swap) 0 else sign, .fy = if (swap) sign else 0, .cx = if (swap) 0 else tiny, .cy = if (swap) tiny else 0, .last = 1 });
        };
    }
}

test "radial subtraction rejects overflow before native or raster work" {
    try std.testing.expectError(error.UnsupportedRadialPrecision, math.subtract(std.math.floatMax(f64), -std.math.floatMax(f64)));
    try std.testing.expectError(error.UnsupportedRadialPrecision, math.subtract(std.math.inf(f64), 0));
}
