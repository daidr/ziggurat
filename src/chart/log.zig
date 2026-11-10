//! Logarithmic and symmetric log scales: `Log` puts equal ratios equal
//! distances apart, for data over several orders of magnitude, and
//! `SymLog` keeps a nearly linear region around zero, for signed data.
//! Their positions, inversions, ticks and nice domains follow d3-scale's
//! `scaleLog` and `scaleSymlog`, which `log_tests.zig` checks against
//! values generated from it.
const std = @import("std");
const scale = @import("scale.zig");

const math = std.math;
const Span = scale.Span;
const Tick = scale.Tick;
const Format = scale.Format;
const Error = scale.Error;
const Linear = scale.Linear;

fn finite(v: f64) bool {
    return math.isFinite(v);
}
fn clampValue(v: f64, lo: f64, hi: f64) f64 {
    return @max(@min(lo, hi), @min(@max(lo, hi), v));
}
fn nan32() f32 {
    return math.nan(f32);
}

/// The natural logarithm, also of subnormals, which are scaled up by an
/// exact power of two first.
fn positiveLog(v: f64) f64 {
    if (v > 0 and v < math.floatMin(f64)) return @log(v * 0x1p52) - 52 * math.ln2;
    return @log(v);
}

/// log(v / lo), without overflowing a ratio across the range of f64 and
/// keeping the difference of ends whose logarithms round alike.
fn logRatio(v: f64, lo: f64) f64 {
    const relative = (v - lo) / lo;
    if (@abs(relative) < 0.5) return math.log1p(relative);
    return positiveLog(v) - positiveLog(lo);
}

fn logBase(v: f64, base: f64) f64 {
    if (v < math.floatMin(f64)) return positiveLog(v) / @log(base);
    if (base == 10) return @log10(v);
    if (base == 2) return @log2(v);
    if (base == math.e) return @log(v);
    return @log(v) / @log(base);
}

const pow10_small = blk: {
    @setEvalBranchQuota(200000);
    var table: [32]f64 = undefined;
    for (&table, 0..) |*slot, i| slot.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{i})) catch unreachable;
    break :blk table;
};
const pow10_up = blk: {
    @setEvalBranchQuota(200000);
    var table: [10]f64 = undefined;
    for (&table, 0..) |*slot, i| slot.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{i * 32})) catch unreachable;
    break :blk table;
};
const pow10_down = blk: {
    @setEvalBranchQuota(200000);
    var table: [11]f64 = undefined;
    for (&table, 0..) |*slot, i| slot.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e-{d}", .{i * 32})) catch unreachable;
    break :blk table;
};

/// 10 to a whole power, from tables of exact powers.
fn pow10(n: i32) f64 {
    if (n >= 0 and n <= 308) {
        const k: usize = @intCast(n);
        return pow10_up[k / 32] * pow10_small[k % 32];
    }
    if (n < 0 and n >= -323) {
        const k: usize = @intCast(-n);
        return pow10_down[k / 32] / pow10_small[k % 32];
    }
    return if (n > 0) math.inf(f64) else 0;
}

fn powerBase(exponent: f64, base: f64) f64 {
    if (base == 10 and exponent == @trunc(exponent) and exponent >= -324 and exponent <= 309) return pow10(@intFromFloat(exponent));
    if (base == 2) return @exp2(exponent);
    if (base == math.e) return @exp(exponent);
    return math.pow(f64, base, exponent);
}

/// Maps a domain of positive numbers, or of negative numbers, onto the
/// plot with equal ratios the same distance apart: 1, 10 and 100 are
/// equally spaced. Zero and domains crossing it are invalid; use `SymLog`
/// for those. `lo` and `hi` may be reversed. An invalid domain or base
/// gives NaN positions and no ticks, rather than a misleading plot.
pub const Log = struct {
    lo: f64,
    hi: f64,
    /// The powers `nice` and `ticks` use, 10 when 0. It must be finite and
    /// greater than 1, as 2 or e; it does not change `at`.
    base: f64 = 10,
    /// Keep values outside the domain at its ends, zero included.
    clamp: bool = false,
    /// Labels every tick when set. Null labels with six significant digits
    /// and leaves crowded minor ticks without labels.
    format: ?Format = null,

    pub fn init(lo: f64, hi: f64) Log {
        return .{ .lo = lo, .hi = hi };
    }

    fn baseOf(self: Log) f64 {
        return if (self.base == 0) 10 else self.base;
    }
    fn valid(self: Log) bool {
        const b = self.baseOf();
        return finite(self.lo) and finite(self.hi) and finite(b) and b > 1 and
            ((self.lo > 0 and self.hi > 0) or (self.lo < 0 and self.hi < 0));
    }

    /// Where `v` is along the plot. Without `clamp`, a value of the other
    /// sign is NaN and zero is infinitely far off the plot; NaN stays NaN,
    /// which paths leave as a gap.
    pub fn at(self: Log, v_in: f64) f32 {
        if (!self.valid() or math.isNan(v_in)) return nan32();
        var v = v_in;
        if (self.clamp) v = clampValue(v, self.lo, self.hi);
        if ((self.lo > 0 and v < 0) or (self.lo < 0 and v > 0)) return nan32();
        if (self.lo == self.hi) return 0.5;
        return @floatCast(logRatio(@abs(v), @abs(self.lo)) / logRatio(@abs(self.hi), @abs(self.lo)));
    }

    /// The value at `f` along the plot, as under the pointer.
    pub fn invert(self: Log, f_in: f32) f64 {
        if (!self.valid() or math.isNan(f_in)) return math.nan(f64);
        var f = f_in;
        if (self.clamp) f = @max(0, @min(1, f));
        if (f == 0 or self.lo == self.hi) return self.lo;
        if (f == 1) return self.hi;
        const lo = @abs(self.lo);
        const r = logRatio(@abs(self.hi), lo);
        const ff: f64 = f;
        const v = if (@abs(r) < 0.5) lo + lo * math.expm1(ff * r) else @exp(positiveLog(lo) + ff * r);
        return math.copysign(v, self.lo);
    }

    /// The stretch from `a` to `b`. A logarithmic bar needs a baseline
    /// other than zero.
    pub fn span(self: Log, a: f64, b: f64) Span {
        return .{ .lo = self.at(a), .hi = self.at(b) };
    }

    /// The domain extended out to powers of the base. At the limits of f64,
    /// an end whose next power is zero or infinite stays. An invalid scale
    /// stays as it is.
    pub fn nice(self: Log) Log {
        if (!self.valid()) return self;
        const base = self.baseOf();
        var lo = @min(@abs(self.lo), @abs(self.hi));
        var hi = @max(@abs(self.lo), @abs(self.hi));
        const a = powerBase(@floor(logBase(lo, base)), base);
        const b = powerBase(@ceil(logBase(hi, base)), base);
        if (a > 0 and finite(a) and a <= lo) lo = a;
        if (b > 0 and finite(b) and b >= hi) hi = b;
        if (@abs(self.lo) > @abs(self.hi)) std.mem.swap(f64, &lo, &hi);
        var out = self;
        out.lo = math.copysign(lo, self.lo);
        out.hi = math.copysign(hi, self.hi);
        return out;
    }

    /// The powers of the base within the domain and, for a whole base over
    /// a short domain, their multiples, written to `out` in the domain's
    /// order. `count` is how dense to make them, which minor ticks may
    /// pass; a domain with few of them takes round linear ticks instead,
    /// and 0 gives none. A domain of one value has one tick there.
    pub fn ticks(self: Log, count: usize, out: []Tick) Error![]Tick {
        if (!self.valid() or count == 0) return out[0..0];
        const lo = @min(@abs(self.lo), @abs(self.hi));
        const hi = @max(@abs(self.lo), @abs(self.hi));
        const base = self.baseOf();
        const n: f64 = @floatFromInt(count);
        const a = logBase(lo, base);
        const b = logBase(hi, base);
        var len: usize = 0;
        // Bounds the work of minor ticks for very large whole bases; powers
        // work for every valid base.
        if (base == @trunc(base) and b - a < n and base * @ceil(b - a + 2) <= 10000) {
            var exponent = @floor(a);
            while (exponent <= @ceil(b)) : (exponent += 1) {
                const p = powerBase(exponent, base);
                var k: f64 = 1;
                while (k < base) : (k += 1) {
                    var v = k * p;
                    if (exponent < 0) {
                        const divisor = powerBase(-exponent, base);
                        if (finite(divisor)) v = k / divisor;
                    }
                    if (v >= lo and v <= hi and v > 0 and finite(v)) {
                        if (len >= out.len) return error.TooManyTicks;
                        out[len] = .{ .at = 0, .value = v };
                        len += 1;
                    }
                }
            }
            if (len * 2 < count) {
                len = 0;
                var values = scale.tickValues(lo, hi, n);
                if (values.len > out.len) return error.TooManyTicks;
                while (values.next()) |v| : (len += 1) out[len] = .{ .at = 0, .value = v };
            }
        } else {
            var exponents = scale.tickValues(a, b, @min(b - a, n));
            while (exponents.next()) |e| {
                const v = powerBase(e, base);
                if (v > 0 and finite(v)) {
                    if (len >= out.len) return error.TooManyTicks;
                    out[len] = .{ .at = 0, .value = v };
                    len += 1;
                }
            }
        }
        if (lo == hi) {
            if (out.len == 0) return error.TooManyTicks;
            out[0] = .{ .at = 0, .value = lo };
            len = 1;
        }
        const ticked = out[0..len];
        if (self.lo < 0) {
            for (ticked) |*tick| tick.value = -tick.value;
            std.mem.reverse(Tick, ticked);
        }
        if (self.hi < self.lo) std.mem.reverse(Tick, ticked);
        const threshold = @max(1, base * n / @as(f64, @floatFromInt(len)));
        var buffer: [64]u8 = undefined;
        for (ticked) |*tick| {
            const v = tick.value;
            tick.at = self.at(v);
            if (self.format) |format| {
                tick.setLabel(format.call(format.context, v, &buffer));
            } else {
                const exponent = @floor(logBase(@abs(v), base) + 1e-12);
                const coefficient = @abs(v) / powerBase(exponent, base);
                if (len == 1 or coefficient <= threshold + 1e-10) tick.setLabel(formatSignificant(&buffer, v, 6));
            }
        }
        return ticked;
    }
};

/// A symmetric logarithmic scale, sign(v)·log1p(|v|/constant): unlike
/// `Log` it takes zero and both signs. It is nearly linear around zero
/// and logarithmic for larger magnitudes; its ticks and nice domains are
/// round values in the data's units, placed along the curve.
pub const SymLog = struct {
    lo: f64,
    hi: f64,
    /// The size of the linear region, 1 when 0. It must be finite and
    /// positive; a larger constant makes more of the plot linear.
    constant: f64 = 1,
    clamp: bool = false,
    format: ?Format = null,

    pub fn init(lo: f64, hi: f64) SymLog {
        return .{ .lo = lo, .hi = hi };
    }

    fn constantOf(self: SymLog) f64 {
        return if (self.constant == 0) 1 else self.constant;
    }
    fn valid(self: SymLog) bool {
        const c = self.constantOf();
        return finite(self.lo) and finite(self.hi) and finite(c) and c > 0;
    }

    fn transform(v: f64, c: f64) f64 {
        const r = @abs(v) / c;
        if (math.isInf(r)) return math.copysign(positiveLog(@abs(v)) - positiveLog(c), v);
        return math.copysign(math.log1p(r), v);
    }
    fn untransform(v: f64, c: f64) f64 {
        if (@abs(v) > 700) return math.copysign(@exp(positiveLog(c) + @abs(v)), v);
        return math.copysign(c * math.expm1(@abs(v)), v);
    }

    /// Where `v` is along the plot; NaN stays NaN, a missing value.
    pub fn at(self: SymLog, v_in: f64) f32 {
        if (!self.valid() or math.isNan(v_in)) return nan32();
        var v = v_in;
        if (self.clamp) v = clampValue(v, self.lo, self.hi);
        const c = self.constantOf();
        const a = transform(self.lo, c);
        const b = transform(self.hi, c);
        if (a == b) return Linear.init(self.lo, self.hi).at(v);
        return @floatCast((transform(v, c) - a) / (b - a));
    }

    /// The value at `f` along the plot.
    pub fn invert(self: SymLog, f_in: f32) f64 {
        if (!self.valid() or math.isNan(f_in)) return math.nan(f64);
        var f = f_in;
        if (self.clamp) f = @max(0, @min(1, f));
        if (f == 0 or self.lo == self.hi) return self.lo;
        if (f == 1) return self.hi;
        const c = self.constantOf();
        const a = transform(self.lo, c);
        const b = transform(self.hi, c);
        if (a == b) return Linear.init(self.lo, self.hi).invert(f);
        const ff: f64 = f;
        return untransform(a + ff * (b - a), c);
    }

    /// The stretch from `a` to `b`, as a signed bar's from 0.
    pub fn span(self: SymLog, a: f64, b: f64) Span {
        return .{ .lo = self.at(a), .hi = self.at(b) };
    }

    /// The domain extended to round values, as `Linear.nice` does. A count
    /// of 0, or one that does not settle on a domain, leaves it as it is.
    pub fn nice(self: SymLog, count: usize) SymLog {
        if (!self.valid() or count == 0) return self;
        const n = Linear.init(self.lo, self.hi).nice(count);
        if (!finite(n.lo) or !finite(n.hi)) return self;
        // Very sparse counts can keep widening round domains: keep the
        // domain rather than the last of them.
        const again = n.nice(count);
        if (again.lo != n.lo or again.hi != n.hi) return self;
        var out = self;
        out.lo = n.lo;
        out.hi = n.hi;
        return out;
    }

    /// Round values in the domain, placed along the curve, written to
    /// `out`.
    pub fn ticks(self: SymLog, count: usize, out: []Tick) Error![]Tick {
        if (!self.valid()) return out[0..0];
        const ticked = try (Linear{ .lo = self.lo, .hi = self.hi, .format = self.format }).ticks(count, out);
        for (ticked) |*tick| tick.at = self.at(tick.value);
        return ticked;
    }
};

/// `value` with up to `digits` significant digits, without trailing
/// zeros, in exponent form below 1e-4 or from 10 to the power of
/// `digits`: 0.001, 1000, 1e+06, 3.16228e-05.
pub fn formatSignificant(buffer: []u8, value: f64, digits: usize) []const u8 {
    if (value == 0) return std.fmt.bufPrint(buffer, "0", .{}) catch buffer[0..0];
    if (!finite(value)) return std.fmt.bufPrint(buffer, "{d}", .{value}) catch buffer[0..0];
    var scientific: [64]u8 = undefined;
    // The exponent after rounding to the digits, as 999999.5 is 1e+06.
    const rounded = std.fmt.bufPrint(&scientific, "{e:.[1]}", .{ value, digits - 1 }) catch return buffer[0..0];
    const e_at = std.mem.indexOfScalar(u8, rounded, 'e') orelse return buffer[0..0];
    const exponent = std.fmt.parseInt(i32, rounded[e_at + 1 ..], 10) catch return buffer[0..0];
    if (exponent < -4 or exponent >= @as(i32, @intCast(digits))) {
        const mantissa = trimZeros(rounded[0..e_at]);
        const sign: u8 = if (exponent < 0) '-' else '+';
        const magnitude: u32 = @abs(exponent);
        return std.fmt.bufPrint(buffer, "{s}e{c}{d:0>2}", .{ mantissa, sign, magnitude }) catch buffer[0..0];
    }
    const decimals: usize = @intCast(@max(0, @as(i32, @intCast(digits)) - 1 - exponent));
    const fixed = std.fmt.bufPrint(buffer, "{d:.[1]}", .{ value, decimals }) catch return buffer[0..0];
    return trimZeros(fixed);
}

fn trimZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}
