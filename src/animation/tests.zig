const std = @import("std");
const a = @import("root.zig");
const second = std.time.ns_per_s;

test "tween delay sleeps to start and final sample removes every wake" {
    var channel = try a.Channel.init(10);
    try channel.retarget(100, 20, .{ .delay_ns = second, .motion = .{ .tween = .{ .duration_ns = second, .easing = .linear } } });
    try std.testing.expectEqual(@as(?u64, second + 100), try channel.nextWake(100, 16_000_000));
    try std.testing.expectEqual(@as(f64, 10), (try channel.advance(second / 2)).value);
    try std.testing.expectEqual(@as(f64, 15), (try channel.advance(second + second / 2 + 100)).value);
    try std.testing.expectEqual(@as(f64, 10), channel.velocity);
    try std.testing.expectEqual(@as(f64, 20), (try channel.advance(2 * second + 100)).value);
    try std.testing.expectEqual(a.EndReason.finished, channel.last_end.?);
    try std.testing.expectEqual(@as(?u64, null), try channel.nextWake(3 * second, 16_000_000));
}

test "critical spring agrees with independent closed form and frame partition has no drift" {
    const options: a.Retarget = .{ .motion = .{ .spring = .{ .frequency_hz = 1, .position_epsilon = 1e-12, .velocity_epsilon = 1e-12 } } };
    var direct = try a.Channel.init(0);
    try direct.retarget(0, 1, options);
    var partitioned = direct;
    for (1..100) |step| _ = try partitioned.advance(step * 1_000_000);
    const actual = try direct.advance(second / 10);
    const partitioned_result = try partitioned.advance(second / 10);
    try std.testing.expectEqual(actual, partitioned_result);
    const omega = 2 * std.math.pi;
    const decay = @exp(-omega * 0.1);
    try std.testing.expectApproxEqAbs(1 - (1 + omega * 0.1) * decay, actual.value, 1e-14);
    try std.testing.expectApproxEqAbs(omega * omega * 0.1 * decay, actual.velocity, 1e-14);
}

fn acceleration(position: f64, velocity: f64, ratio: f64) f64 {
    const omega = 2 * std.math.pi;
    return -omega * omega * position - 2 * ratio * omega * velocity;
}
fn integrate(ratio: f64) struct { position: f64, velocity: f64 } {
    var x: f64 = -1;
    var v: f64 = 0;
    const h: f64 = 0.00001;
    for (0..20000) |_| {
        const k1x = v;
        const k1v = acceleration(x, v, ratio);
        const k2x = v + h / 2 * k1v;
        const k2v = acceleration(x + h / 2 * k1x, v + h / 2 * k1v, ratio);
        const k3x = v + h / 2 * k2v;
        const k3v = acceleration(x + h / 2 * k2x, v + h / 2 * k2v, ratio);
        const k4x = v + h * k3v;
        const k4v = acceleration(x + h * k3x, v + h * k3v, ratio);
        x += h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x);
        v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v);
    }
    return .{ .position = x + 1, .velocity = v };
}
test "under critical and over damping agree with an independent RK4 oracle" {
    for ([_]f64{ 0, 0.3, 1, 2, 10 }) |ratio| {
        var channel = try a.Channel.init(0);
        try channel.retarget(0, 1, .{ .motion = .{ .spring = .{ .frequency_hz = 1, .damping_ratio = ratio, .position_epsilon = 1e-12, .velocity_epsilon = 1e-12 } } });
        const actual = try channel.advance(second / 5);
        const expected = integrate(ratio);
        try std.testing.expectApproxEqAbs(expected.position, actual.value, 1e-10);
        try std.testing.expectApproxEqAbs(expected.velocity, actual.velocity, 1e-10);
    }
}

test "near critical samples remain continuous without reclassifying damping" {
    var samples: [3]a.Sample = undefined;
    for ([_]f64{ 1 - std.math.floatEps(f64), 1, 1 + std.math.floatEps(f64) }, &samples) |ratio, *sample| {
        var channel = try a.Channel.init(0);
        try channel.retarget(0, 1, .{ .motion = .{ .spring = .{ .frequency_hz = 1, .damping_ratio = ratio } } });
        sample.* = try channel.advance(second / 10);
    }
    for (samples) |sample| {
        try std.testing.expectApproxEqAbs(samples[1].value, sample.value, 1e-14);
        try std.testing.expectApproxEqAbs(samples[1].velocity, sample.velocity, 1e-14);
    }
}

test "retarget preserves velocity and reduced motion snaps existing and future work" {
    var channel = try a.Channel.init(0);
    try channel.retarget(0, 10, .{});
    const before = try channel.advance(second / 20);
    try channel.retarget(second / 20, -10, .{});
    const after = try channel.advance(second / 20);
    try std.testing.expectEqual(before.value, after.value);
    try std.testing.expectEqual(before.velocity, after.velocity);
    try channel.setReducedMotion(second / 10, true);
    try std.testing.expectEqual(@as(f64, -10), channel.value);
    try std.testing.expectEqual(a.EndReason.reduced_motion, channel.last_end.?);
    try channel.retarget(second / 10, 20, .{ .delay_ns = second });
    try std.testing.expectEqual(@as(f64, 20), channel.value);
    try std.testing.expectEqual(@as(?u64, null), try channel.nextWake(second / 10, 1));
    try channel.setReducedMotion(second / 10, false);
    try channel.retarget(second / 10, 0, .{});
    try std.testing.expect(channel.sample().active);
}

test "cutoff and cancel are explicit and invalid time or parameters are transactional" {
    var channel = try a.Channel.init(0);
    try channel.retarget(10, 1, .{ .motion = .{ .spring = .{ .damping_ratio = 0, .max_duration_ns = second } } });
    const before = channel;
    try std.testing.expectError(error.ClockMovedBackwards, channel.advance(9));
    try std.testing.expectEqualDeep(before, channel);
    try std.testing.expectError(error.InvalidSpring, channel.retarget(11, 2, .{ .motion = .{ .spring = .{ .frequency_hz = 0 } } }));
    try std.testing.expectEqualDeep(before, channel);
    try std.testing.expectError(error.ClockExhausted, channel.retarget(std.math.maxInt(u64), 2, .{}));
    try std.testing.expectEqualDeep(before, channel);
    _ = try channel.advance(second + 10);
    try std.testing.expectEqual(a.EndReason.deadline, channel.last_end.?);
    try channel.retarget(second + 10, 2, .{});
    try channel.cancel(second + 20);
    try std.testing.expectEqual(a.EndReason.cancelled, channel.last_end.?);
    try std.testing.expectEqual(@as(?u64, null), try channel.nextWake(second + 20, 1));
}

test "extreme accepted spring configurations stay finite and settle or reach their cutoff" {
    for ([_]f64{ 0.001, 3, 1000 }) |frequency| for ([_]f64{ 0, 1 - std.math.floatEps(f64), 1, 1 + std.math.floatEps(f64), 1000 }) |ratio| {
        var channel = try a.Channel.init(-1e12);
        try channel.retarget(0, 1e12, .{ .motion = .{ .spring = .{ .frequency_hz = frequency, .damping_ratio = ratio, .initial_velocity = 1e12, .max_duration_ns = a.max_duration_ns } } });
        for ([_]u64{ 0, 1, 1000, 1_000_000, second, 100 * second, a.max_duration_ns }) |now| {
            const sample = try channel.advance(now);
            try std.testing.expect(std.math.isFinite(sample.value) and std.math.isFinite(sample.velocity));
        }
        try std.testing.expect(!channel.sample().active);
    };
}

test "a stationary tween cancels previous velocity without scheduling empty motion" {
    var channel = try a.Channel.init(0);
    try channel.retarget(0, 10, .{});
    const value = (try channel.advance(second / 10)).value;
    try channel.retarget(second / 10, value, .{ .motion = .{ .tween = .{ .duration_ns = second } } });
    try std.testing.expectEqual(@as(f64, 0), channel.velocity);
    try std.testing.expectEqual(@as(?u64, null), try channel.nextWake(second / 10, 1));
}

test "timeline owns bounded overlapping tracks and reuses channel easing" {
    var source = [_]a.Track{
        .{ .from = 0, .to = 10, .tween = .{ .duration_ns = second, .easing = .linear } },
        .{ .at_ns = second / 2, .from = 20, .to = 40, .tween = .{ .duration_ns = second, .easing = .smoothstep } },
    };
    const timeline = try a.Timeline.init(&source);
    source[0].to = 99;
    try std.testing.expectEqual(@as(u64, second + second / 2), timeline.duration_ns);
    try std.testing.expectEqual(@as(f64, 5), (try timeline.sample(0, second / 2)).value);
    try std.testing.expectEqual(@as(f64, 20), (try timeline.sample(1, second / 4)).value);
    try std.testing.expectEqual(@as(f64, 30), (try timeline.sample(1, second)).value);
    try std.testing.expectEqual(@as(f64, 40), (try timeline.sample(1, std.math.maxInt(u64))).value);
    try std.testing.expectError(error.InvalidTrack, timeline.sample(2, 0));
    try std.testing.expectError(error.InvalidTrackCount, a.Timeline.init(&.{}));
}

test "playhead pause seek reverse and skipped frames keep exact integer positions" {
    var playhead = try a.Playhead.init(second);
    try playhead.play(100, .forward);
    try std.testing.expectEqual(@as(u64, second / 4), try playhead.advance(second / 4 + 100));
    try playhead.pause(second / 4 + 100);
    try std.testing.expectEqual(@as(?u64, null), try playhead.nextWake(second, 1));
    try std.testing.expectEqual(@as(u64, second / 4), try playhead.advance(2 * second));
    try playhead.play(2 * second, .backward);
    try std.testing.expectEqual(@as(u64, 0), try playhead.advance(3 * second));
    try std.testing.expect(!playhead.playing);
    try playhead.seek(3 * second, second / 2);
    try playhead.play(3 * second, .forward);
    try std.testing.expectEqual(@as(?u64, 3 * second + second / 2), try playhead.nextWake(3 * second, second));
    try playhead.setReducedMotion(3 * second, true);
    try std.testing.expectEqual(@as(u64, second), playhead.position_ns);
    try std.testing.expect(!playhead.playing);
    try playhead.restart(3 * second, .backward);
    try std.testing.expectEqual(@as(u64, 0), playhead.position_ns);
    try std.testing.expect(!playhead.playing);
}

test "playhead failures preserve state and cannot create an unrepresentable deadline" {
    var playhead = try a.Playhead.init(second);
    try playhead.play(100, .forward);
    const before = playhead;
    try std.testing.expectError(error.ClockMovedBackwards, playhead.pause(99));
    try std.testing.expectEqualDeep(before, playhead);
    try std.testing.expectError(error.InvalidPosition, playhead.seek(100, second + 1));
    try std.testing.expectEqualDeep(before, playhead);
    try std.testing.expectError(error.ClockExhausted, playhead.restart(std.math.maxInt(u64), .forward));
    try std.testing.expectEqualDeep(before, playhead);
    try playhead.seek(std.math.maxInt(u64), second);
    try playhead.play(std.math.maxInt(u64), .forward);
    try std.testing.expectEqual(@as(?u64, null), try playhead.nextWake(std.math.maxInt(u64), 1));
}

test "finite repetitions and alternate directions match an independent traversal oracle" {
    for ([_]bool{ false, true }) |alternate| for ([_]a.Direction{ .forward, .backward }) |direction| {
        for (1..8) |count| for (0..70) |elapsed| {
            var head = try a.Playhead.init(7);
            try head.configureRepeat(.{ .iterations = @intCast(count), .alternate = alternate });
            try head.restart(100, direction);
            const position = try head.advance(100 + elapsed);
            const finished = elapsed >= count * 7;
            const leg = if (finished) count - 1 else elapsed / 7;
            const forward = (direction == .forward) != (alternate and leg % 2 == 1);
            const part = if (finished) 7 else elapsed % 7;
            try std.testing.expectEqual(@as(u64, @intCast(if (forward) part else 7 - part)), position);
            try std.testing.expectEqual(!finished, head.playing);
            try std.testing.expectEqual(@as(u32, @intCast(if (finished) count else leg)), head.completed_iterations);
            if (finished) try std.testing.expectEqual(@as(?u64, null), try head.nextWake(100 + elapsed, 1));
        };
    };
}

test "repetition skips are frame independent and reduced motion finishes the final direction" {
    var once = try a.Playhead.init(10);
    try once.configureRepeat(.{ .iterations = 1_000_000, .alternate = true });
    try once.restart(100, .forward);
    var divided = once;
    for ([_]u64{ 103, 105, 119, 121, 153, 1073, 9876543 }) |now| _ = try divided.advance(now);
    _ = try once.advance(9876543);
    try std.testing.expectEqualDeep(once, divided);
    try once.pause(9876543);
    const paused = once;
    try std.testing.expectError(error.InvalidRepetition, once.configureRepeat(.{ .iterations = 0 }));
    try std.testing.expectEqualDeep(paused, once);
    try once.configureRepeat(.{ .iterations = 4, .alternate = true });
    try once.restart(9876543, .forward);
    try std.testing.expectError(error.Playing, once.configureRepeat(.{}));
    try once.setReducedMotion(9876544, true);
    try std.testing.expectEqual(@as(u64, 0), once.position_ns);
    try std.testing.expectEqual(@as(u32, 4), once.completed_iterations);
    try std.testing.expect(!once.playing);
    try once.restart(9876545, .backward);
    try std.testing.expectEqual(@as(u64, 10), once.position_ns);
    try once.setReducedMotion(9876546, false);
    try once.seek(9876547, 4);
    try std.testing.expectEqual(@as(u32, 0), once.completed_iterations);
    try once.play(9876547, .forward);
    try std.testing.expectEqual(@as(u64, 0), try once.advance(9876583));
    try std.testing.expect(!once.playing);
}

test "repetition duration and clock overflow do not publish partial transport state" {
    var head = try a.Playhead.init(second);
    const before = head;
    try std.testing.expectError(error.InvalidRepetition, head.configureRepeat(.{ .iterations = 3601 }));
    try std.testing.expectEqualDeep(before, head);
    try head.configureRepeat(.{ .iterations = 3, .alternate = true });
    const configured = head;
    try std.testing.expectError(error.ClockExhausted, head.restart(std.math.maxInt(u64) - second, .forward));
    try std.testing.expectEqualDeep(configured, head);
}
