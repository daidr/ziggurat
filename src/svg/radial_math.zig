const std = @import("std");

/// The exact difference of two encoded binary64 inputs is value + residual.
/// Keeping the residual prevents rounded coordinate differences from inventing
/// a tangent circle. This type is private to the SVG implementation.
pub const Difference = struct { value: f64, residual: f64 = 0 };

pub fn subtract(a: f64, b: f64) !Difference {
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return error.UnsupportedRadialPrecision;
    const value = a - b;
    const virtual_b = a - value;
    const virtual_a = value + virtual_b;
    const round_b = virtual_b - b;
    const round_a = a - virtual_a;
    const residual = round_a + round_b;
    if (!std.math.isFinite(value) or !std.math.isFinite(virtual_b) or !std.math.isFinite(virtual_a) or !std.math.isFinite(residual)) return error.UnsupportedRadialPrecision;
    return .{ .value = value, .residual = residual };
}

/// Return the normalized binary64 coefficient, with a reliable sign/zero
/// classification for the exact differences of the encoded input coordinates.
/// This is not an exact-arithmetic claim for subsequent per-pixel roots.
pub fn quadratic(dx: Difference, dy: Difference, dr: Difference, unit: f64) !f64 {
    if (!(unit > 0) or !std.math.isFinite(unit)) return error.UnsupportedRadialPrecision;
    for ([_]Difference{ dx, dy, dr }) |difference| {
        if (!std.math.isFinite(difference.value) or !std.math.isFinite(difference.residual)) return error.UnsupportedRadialPrecision;
    }
    const x: f128 = @max(@abs(dx.value), @abs(dy.value));
    const y: f128 = @min(@abs(dx.value), @abs(dy.value));
    const r: f128 = @abs(dr.value);
    // For x >= r, both terms are nonnegative, with an exact zero criterion.
    // For r >= 2*x, r^2 dominates x^2+y^2 by at least a factor of two.
    // In the remaining cancellation interval x < r < 2*x, x-r is exact
    // (Sterbenz), x+r needs at most 54 bits, and their product at most 107.
    // y*y needs at most 106. These terms fit binary128's 113-bit significand;
    // their near cancellation therefore cannot create a false sign or zero.
    // Its exponent range also covers squares of every finite binary64 input.
    const high = (x - r) * (x + r) + y * y;
    if (dx.residual != 0 or dy.residual != 0 or dr.residual != 0) {
        // Coordinate/radius subtraction can itself round. Bound all missing
        // 2*high*low + low^2 terms with outward-rounded positive additions.
        var correction: f128 = 0;
        for ([_]Difference{ dx, dy, dr }) |difference| {
            const h: f128 = difference.value;
            const l: f128 = difference.residual;
            correction = up(correction + @abs(2 * h * l));
            correction = up(correction + l * l);
        }
        const xx: f128 = @as(f128, dx.value) * dx.value;
        const yy: f128 = @as(f128, dy.value) * dy.value;
        const rr: f128 = @as(f128, dr.value) * dr.value;
        const low = down(down(down(xx + yy) - rr) - correction);
        const upper = up(up(up(xx + yy) - rr) + correction);
        // A residual interval containing zero cannot establish tangent status.
        // Reject it explicitly instead of choosing a visually plausible cone.
        if (low <= 0 and upper >= 0) return error.UnsupportedRadialPrecision;
        if ((low > 0 and high <= 0) or (upper < 0 and high >= 0)) return error.UnsupportedRadialPrecision;
    }
    const normalized = high / (@as(f128, unit) * unit);
    const result: f64 = @floatCast(normalized);
    if (!std.math.isFinite(result) or (result == 0 and high != 0)) return error.UnsupportedRadialPrecision;
    return result;
}

fn up(value: f128) f128 {
    return std.math.nextAfter(f128, value, std.math.inf(f128));
}
fn down(value: f128) f128 {
    return std.math.nextAfter(f128, value, -std.math.inf(f128));
}
