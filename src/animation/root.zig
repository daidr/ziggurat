const std = @import("std");

/// All times use one caller-supplied monotonic nanosecond clock. This module
/// owns no App, timer, thread, callback, allocator or drawing state.
pub const max_duration_ns: u64 = 3600 * std.time.ns_per_s;
pub const Easing = enum { linear, smoothstep, cubic_out };
pub const Tween = struct { duration_ns: u64, easing: Easing = .smoothstep };
pub const Spring = struct {
    frequency_hz: f64 = 3,
    damping_ratio: f64 = 1,
    position_epsilon: f64 = 0.001,
    velocity_epsilon: f64 = 0.001,
    /// Explicit cutoff, including undamped springs. A cutoff is reported as
    /// deadline, not as physical settling. Delay is outside this duration.
    max_duration_ns: u64 = 60 * std.time.ns_per_s,
    initial_velocity: ?f64 = null,
};
pub const Motion = union(enum) { instant, tween: Tween, spring: Spring };
pub const Retarget = struct { motion: Motion = .{ .spring = .{} }, delay_ns: u64 = 0 };
pub const EndReason = enum { finished, settled, deadline, cancelled, reduced_motion, jumped };
pub const Sample = struct { value: f64, velocity: f64, active: bool };
pub const Timeline = @import("timeline.zig").Timeline;
pub const Track = @import("timeline.zig").Track;
pub const Playhead = @import("timeline.zig").Playhead;
pub const Direction = @import("timeline.zig").Direction;
pub const Repetition = @import("timeline.zig").Repetition;

const Run = struct {
    start: u64,
    end: u64,
    from: f64,
    velocity: f64,
    motion: Motion,
};

/// Caller-owned, exclusively accessed value state. Retargeting samples the old
/// motion at that exact time; a spring preserves that velocity unless explicitly
/// overridden. Every error leaves the complete channel unchanged.
pub const Channel = struct {
    value: f64,
    velocity: f64 = 0,
    target: f64,
    last_now: ?u64 = null,
    run: ?Run = null,
    reduce_motion: bool = false,
    last_end: ?EndReason = null,

    pub fn init(value: f64) !Channel {
        try validValue(value);
        return .{ .value = value, .target = value };
    }
    pub fn sample(self: *const Channel) Sample {
        return .{ .value = self.value, .velocity = self.velocity, .active = self.run != null };
    }
    pub fn advance(self: *Channel, now: u64) !Sample {
        try self.checkTime(now);
        var next = self.*;
        next.last_now = now;
        if (next.run) |run| {
            if (now >= run.end) {
                next.finish(if (run.motion == .spring) .deadline else .finished);
            } else if (now < run.start) {
                next.value = run.from;
                next.velocity = 0;
            } else switch (run.motion) {
                .instant => unreachable,
                .tween => |tween| {
                    const duration: f64 = @floatFromInt(tween.duration_ns);
                    const fraction = @as(f64, @floatFromInt(now - run.start)) / duration;
                    const ease = eased(tween.easing, fraction);
                    next.value = (1 - ease.value) * run.from + ease.value * next.target;
                    next.velocity = (next.target - run.from) * ease.derivative * std.time.ns_per_s / duration;
                },
                .spring => |spring| spring_sample: {
                    if (now == run.start) {
                        next.value = run.from;
                        next.velocity = run.velocity;
                        break :spring_sample;
                    }
                    const seconds = @as(f64, @floatFromInt(now - run.start)) / std.time.ns_per_s;
                    const state = solve(spring, run.from - next.target, run.velocity, seconds);
                    next.value = next.target + state.value;
                    next.velocity = state.velocity;
                    if (@abs(state.value) <= spring.position_epsilon and @abs(state.velocity) <= spring.velocity_epsilon) next.finish(.settled);
                },
            }
        }
        if (!std.math.isFinite(next.value) or !std.math.isFinite(next.velocity)) return error.NumericalRange;
        self.* = next;
        return self.sample();
    }
    pub fn retarget(self: *Channel, now: u64, target: f64, options: Retarget) !void {
        try validValue(target);
        try validOptions(options);
        var next = self.*;
        _ = try next.advance(now);
        next.target = target;
        if (next.reduce_motion or options.motion == .instant) {
            next.finish(if (next.reduce_motion) .reduced_motion else .finished);
        } else {
            const duration = switch (options.motion) {
                .instant => unreachable,
                .tween => |tween| tween.duration_ns,
                .spring => |spring| spring.max_duration_ns,
            };
            const velocity = switch (options.motion) {
                .spring => |spring| spring.initial_velocity orelse next.velocity,
                else => 0,
            };
            const start = std.math.add(u64, now, options.delay_ns) catch return error.ClockExhausted;
            const end = std.math.add(u64, start, duration) catch return error.ClockExhausted;
            next.run = .{ .start = start, .end = end, .from = next.value, .velocity = velocity, .motion = options.motion };
            next.velocity = if (options.delay_ns != 0) 0 else velocity;
            next.last_end = null;
            if (next.value == target and velocity == 0) next.finish(.settled);
            _ = try next.advance(now);
        }
        self.* = next;
    }
    /// Returns the next requested wake, never starts or arms a timer. Delayed
    /// motion sleeps straight to its start. Resting channels request no wake.
    pub fn nextWake(self: *const Channel, now: u64, cadence_ns: u64) !?u64 {
        try self.checkTime(now);
        if (cadence_ns == 0 or cadence_ns > std.time.ns_per_s) return error.InvalidCadence;
        const run = self.run orelse return null;
        if (now < run.start) return run.start;
        return @max(now, @min(now +| cadence_ns, run.end));
    }
    pub fn cancel(self: *Channel, now: u64) !void {
        var next = self.*;
        _ = try next.advance(now);
        next.target = next.value;
        next.finish(.cancelled);
        self.* = next;
    }
    pub fn jump(self: *Channel, now: u64, value: f64) !void {
        try self.checkTime(now);
        try validValue(value);
        self.last_now = now;
        self.target = value;
        self.finish(.jumped);
    }
    pub fn setReducedMotion(self: *Channel, now: u64, enabled: bool) !void {
        var next = self.*;
        _ = try next.advance(now);
        next.reduce_motion = enabled;
        if (enabled and next.run != null) next.finish(.reduced_motion);
        self.* = next;
    }
    fn checkTime(self: *const Channel, now: u64) !void {
        if (self.last_now) |last| if (now < last) return error.ClockMovedBackwards;
    }
    fn finish(self: *Channel, reason: EndReason) void {
        self.value = self.target;
        self.velocity = 0;
        self.run = null;
        self.last_end = reason;
    }
};

fn validValue(value: f64) !void {
    if (!std.math.isFinite(value) or @abs(value) > 1e12) return error.InvalidValue;
}
fn validOptions(options: Retarget) !void {
    if (options.delay_ns > max_duration_ns) return error.InvalidDuration;
    switch (options.motion) {
        .instant => if (options.delay_ns != 0) return error.InvalidDuration,
        .tween => |tween| if (tween.duration_ns == 0 or tween.duration_ns > max_duration_ns) return error.InvalidDuration,
        .spring => |spring| {
            if (!std.math.isFinite(spring.frequency_hz) or spring.frequency_hz < 0.001 or spring.frequency_hz > 1000 or
                !std.math.isFinite(spring.damping_ratio) or spring.damping_ratio < 0 or spring.damping_ratio > 1000 or
                !std.math.isFinite(spring.position_epsilon) or spring.position_epsilon <= 0 or spring.position_epsilon > 1e12 or
                !std.math.isFinite(spring.velocity_epsilon) or spring.velocity_epsilon <= 0 or spring.velocity_epsilon > 1e12) return error.InvalidSpring;
            if (spring.max_duration_ns == 0 or spring.max_duration_ns > max_duration_ns) return error.InvalidDuration;
            if (spring.initial_velocity) |velocity| validValue(velocity) catch return error.InvalidSpring;
        },
    }
}
const Ease = struct { value: f64, derivative: f64 };
fn eased(easing: Easing, t: f64) Ease {
    return switch (easing) {
        .linear => .{ .value = t, .derivative = 1 },
        .smoothstep => .{ .value = t * t * (3 - 2 * t), .derivative = 6 * t * (1 - t) },
        .cubic_out => .{ .value = 1 - (1 - t) * (1 - t) * (1 - t), .derivative = 3 * (1 - t) * (1 - t) },
    };
}
fn sinc(value: f64) f64 {
    if (@abs(value) >= 0.001) return @sin(value) / value;
    const square = value * value;
    return 1 - square / 6 + square * square / 120;
}
fn sinhc(value: f64) f64 {
    const square = value * value;
    return 1 + square / 6 + square * square / 120;
}
/// Analytic damped oscillator. Each sample uses the fixed retarget origin;
/// skipped frames neither accumulate integration error nor require catch-up.
fn solve(spring: Spring, displacement: f64, velocity: f64, seconds: f64) struct { value: f64, velocity: f64 } {
    const omega = 2 * std.math.pi * spring.frequency_hz;
    const alpha = spring.damping_ratio * omega;
    var c: f64 = undefined;
    var s: f64 = undefined;
    if (spring.damping_ratio < 1) {
        const beta = omega * @sqrt((1 - spring.damping_ratio) * (1 + spring.damping_ratio));
        const angle = beta * seconds;
        const decay = @exp(-alpha * seconds);
        c = decay * @cos(angle);
        s = decay * seconds * sinc(angle);
    } else if (spring.damping_ratio == 1) {
        c = @exp(-alpha * seconds);
        s = c * seconds;
    } else {
        const root = @sqrt((spring.damping_ratio - 1) * (spring.damping_ratio + 1));
        const beta = omega * root;
        const angle = beta * seconds;
        if (angle < 0.001) {
            const decay = @exp(-alpha * seconds);
            const square = angle * angle;
            c = decay * (1 + square / 2 + square * square / 24);
            s = decay * seconds * sinhc(angle);
        } else {
            const sum = spring.damping_ratio + root;
            const slow = @exp((-omega / sum) * seconds);
            const fast = @exp((-omega * sum) * seconds);
            c = (slow + fast) / 2;
            s = (slow - fast) / (2 * beta);
        }
    }
    return .{ .value = displacement * c + (velocity + alpha * displacement) * s, .velocity = velocity * c - (alpha * velocity + omega * omega * displacement) * s };
}

test {
    _ = @import("tests.zig");
    _ = @import("timeline.zig");
}
