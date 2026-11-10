//! A voice that plays more than one source frame an output frame, a sound
//! of more than 48 kHz or one sped up, would fold what it has above the
//! output's Nyquist frequency, 24 kHz, back below it: a spline does not
//! remove it. Such a voice interpolates with a windowed sinc instead, a
//! low-pass at the output's rate: a Kaiser window over `sinc_reach` output
//! frames either side, flat to 20 kHz, -6 dB at 22 kHz and at least 80 dB
//! down from 24 kHz. In source frames, the kernel is as much wider as the
//! source is faster, and its cutoff as much lower.
const std = @import("std");
const output = @import("output.zig");

/// Output frames either side.
const sinc_reach = 32;
/// Of the output's rate.
const sinc_cutoff = 22000.0 / @as(f64, output.sample_rate);
/// The Kaiser window's: 80 dB.
const sinc_beta = 7.857;
/// Entries of `sinc_table` an output frame.
const sinc_resolution = 256;
/// The kernels a voice keeps for the phases between two source frames (as
/// many an output frame, so fewer the faster), and interpolates between.
const sinc_phases = 128;

/// The most source frames the kernel reaches either side: the whole kernel
/// up to 8 source frames an output frame. Faster, the window narrows to
/// these, which widens the band from what it passes to what it stops as
/// much, and the cutoff comes down for that band to end at 24 kHz still,
/// as far as half of it.
pub const max_reach = 256;
/// The frames a voice keeps around where it is: enough for the kernel to
/// grow to `max_reach` while it holds frames as far ahead.
pub const ring_frames = 2 * max_reach;
pub const ring_mask = ring_frames - 1;

/// The most weights a bank holds at any step: (rows + 1) × 2 × reach.
const max_weights = 2 * sinc_phases * sinc_reach + 2 * sinc_phases + 4 * max_reach + 4;

/// The source frames around a voice's output, stereo: frame f at f mod
/// `ring_frames`, and again `ring_frames` after, so that any `ring_frames`
/// in a row are in a row.
pub const Ring = [2 * ring_frames][2]f32;

/// The kernel at a step, in source frames an output frame: the weights of
/// the 2 × reach frames from reach - 1 before the output's to reach after
/// it, for each of rows + 1 phases from 0 to 1, each with the difference to
/// the next phase's.
pub const SincBank = struct {
    step: f64 = 0,
    reach: usize = 0,
    rows: usize = 0,
    /// Of the output's rate.
    cutoff: f64 = sinc_cutoff,
    weights: [max_weights][2]f32 = undefined,

    /// Makes the bank's kernels those at `step`, unless they are.
    pub fn set(self: *SincBank, step: f64) void {
        if (self.step == step) return;
        self.step = step;
        self.reach = @min(@as(usize, @intFromFloat(@ceil(sinc_reach * step))), max_reach);
        self.rows = @intFromFloat(@ceil(sinc_phases / step));
        self.cutoff = sinc_cutoff;
        if (sinc_reach * step > max_reach) {
            // Half the band from what it passes to what it stops, as many
            // times wider as the window is narrower.
            const half = (0.5 - sinc_cutoff) * sinc_reach * step / max_reach;
            self.cutoff = @max(0.5 - half, half);
        }
        const n = 2 * self.reach;
        for (0..self.rows + 1) |p| self.kernel(self.weights[p * n ..][0..n], @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(self.rows)));
        for (0..self.rows) |p| {
            const w = self.weights[p * n ..][0..n];
            const next = self.weights[(p + 1) * n ..][0..n];
            for (w, next) |*weight, after| weight[1] = after[0] - weight[0];
        }
        for (self.weights[self.rows * n ..][0..n]) |*weight| weight[1] = 0;
    }

    /// Sets the weights in `w` for an output phase past the frame reach - 1
    /// after w's first, summing to 1 so that what is constant stays as it is.
    fn kernel(self: *const SincBank, w: [][2]f32, phase: f64) void {
        // Source frames from the output to w's first.
        const d0 = @as(f64, @floatFromInt(1 - @as(i64, @intCast(self.reach)))) - phase;
        var sum: f64 = 0;
        if (sinc_reach * self.step <= max_reach) {
            const dx = sinc_resolution / self.step;
            for (w, 0..) |*weight, j| {
                const x = @abs(d0 + @as(f64, @floatFromInt(j))) * dx;
                const i: usize = @intFromFloat(x);
                const h = @as(f64, sinc_table[i][0]) + (x - @as(f64, @floatFromInt(i))) * @as(f64, sinc_table[i][1]);
                weight[0] = @floatCast(h);
                sum += h;
            }
        } else {
            // The ring cannot hold the whole kernel: the sinc at the cutoff,
            // by rotation from one frame to the next, in a window as wide as
            // the frames reached.
            const end = kaiser_table.len - 1;
            const dk = @as(f64, @floatFromInt(end)) / @as(f64, @floatFromInt(self.reach));
            // Radians a source frame.
            const a = std.math.pi * 2 * self.cutoff / self.step;
            var s = @sin(a * d0);
            var c = @cos(a * d0);
            const sa = @sin(a);
            const ca = @cos(a);
            for (w, 0..) |*weight, j| {
                const d = d0 + @as(f64, @floatFromInt(j));
                var h: f64 = 0;
                const u = @abs(d) * dk;
                if (u < @as(f64, @floatFromInt(end))) {
                    const i: usize = @intFromFloat(u);
                    h = kaiser_table[i] + (u - @as(f64, @floatFromInt(i))) * (kaiser_table[i + 1] - kaiser_table[i]);
                    const th = a * d;
                    if (@abs(th) > 1e-9) h *= s / th;
                }
                weight[0] = @floatCast(h);
                sum += h;
                const rotated = s * ca + c * sa;
                c = c * ca - s * sa;
                s = rotated;
            }
        }
        for (w) |*weight| weight[0] = @floatCast(@as(f64, weight[0]) / sum);
    }

    /// Interpolates `ring`'s frames where the output is, `phase` past frame
    /// `index`, with the bank's kernel, between those of the phases either
    /// side.
    pub fn sample(self: *const SincBank, ring: *const Ring, index: i64, phase: f64, mono: bool) struct { f32, f32 } {
        const n = 2 * self.reach;
        const u = phase * @as(f64, @floatFromInt(self.rows));
        const p: usize = @min(@as(usize, @intFromFloat(u)), self.rows);
        const f: f32 = @floatCast(u - @as(f64, @floatFromInt(p)));
        const w = self.weights[p * n ..][0..n];
        const first: usize = @intCast((index - @as(i64, @intCast(self.reach)) + 1) & ring_mask);
        const x = ring[first..][0..n];
        var left: f32 = 0;
        var right: f32 = 0;
        if (mono) {
            for (w, x) |e, frame| left += (e[0] + f * e[1]) * frame[0];
            return .{ left, left };
        }
        if (f == 0) {
            // On a phase of the bank, as every frame at a whole number of
            // source frames an output frame.
            for (w, x) |e, frame| {
                left += e[0] * frame[0];
                right += e[0] * frame[1];
            }
        } else for (w, x) |e, frame| {
            const h = e[0] + f * e[1];
            left += h * frame[0];
            right += h * frame[1];
        }
        return .{ left, right };
    }
};

/// The kernel from 0 to `sinc_reach` output frames, `sinc_resolution`
/// entries a frame, each with the difference to the next for interpolating
/// between them, and zeros as far after as a kernel's last frame reaches.
const sinc_table: [sinc_reach * sinc_resolution + 2 * sinc_resolution][2]f32 = blk: {
    @setEvalBranchQuota(20_000_000);
    const n = sinc_reach * sinc_resolution;
    var table: [n + 2 * sinc_resolution][2]f32 = @splat(.{ 0, 0 });
    var next: f64 = 0;
    var i: usize = n + 1;
    while (i > 0) {
        i -= 1;
        const x = @as(f64, @floatFromInt(i)) / sinc_resolution;
        const h = sinc(2 * sinc_cutoff * x) * kaiser(x / sinc_reach);
        table[i] = .{ @floatCast(h), @floatCast(next - h) };
        next = h;
    }
    break :blk table;
};

/// The window from its middle to its edge, for kernels the ring cannot
/// hold whole.
const kaiser_table: [1025]f64 = blk: {
    @setEvalBranchQuota(5_000_000);
    var table: [1025]f64 = undefined;
    for (&table, 0..) |*entry, i| entry.* = kaiser(@as(f64, @floatFromInt(i)) / 1024);
    break :blk table;
};

fn sinc(x: f64) f64 {
    if (x == 0) return 1;
    return @sin(std.math.pi * x) / (std.math.pi * x);
}

/// The Kaiser window at `u`, from -1 to 1.
fn kaiser(u: f64) f64 {
    return bessel0(sinc_beta * @sqrt(@max(1 - u * u, 0))) / bessel0(sinc_beta);
}

/// The modified Bessel function of the first kind, of order zero.
fn bessel0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (term > 1e-12 * sum) : (k += 1) {
        const h = x / 2 / k;
        term *= h * h;
        sum += term;
    }
    return sum;
}
