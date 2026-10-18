const std = @import("std");

// Private, clock-free classification. Native and semantic owners supply
// separate exact keys and enforce press/current-operation authority themselves.
pub const Position = struct { x: f64, y: f64, domain: u64 };
pub const Edges = packed struct(u8) {
    min_x_inclusive: bool = true,
    max_x_inclusive: bool = false,
    min_y_inclusive: bool = true,
    max_y_inclusive: bool = false,
    time_inclusive: bool = true,
    reserved: u3 = 0,
};
pub const Policy = struct {
    interval_ms: u32,
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,
    edges: Edges = .{},

    pub fn valid(self: Policy) bool {
        return self.edges.reserved == 0 and self.interval_ms < 0x80000000 and
            std.math.isFinite(self.min_x) and std.math.isFinite(self.max_x) and
            std.math.isFinite(self.min_y) and std.math.isFinite(self.max_y) and
            self.contains(0, 0);
    }
    fn contains(self: Policy, x: f64, y: f64) bool {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return false;
        return lower(x, self.min_x, self.edges.min_x_inclusive) and
            upper(x, self.max_x, self.edges.max_x_inclusive) and
            lower(y, self.min_y, self.edges.min_y_inclusive) and
            upper(y, self.max_y, self.edges.max_y_inclusive);
    }
};
pub const Timing = struct { tick_ms: u32, position: Position, policy: Policy };

fn lower(value: f64, bound: f64, inclusive: bool) bool {
    return if (inclusive) value >= bound else value > bound;
}
fn upper(value: f64, bound: f64, inclusive: bool) bool {
    return if (inclusive) value <= bound else value < bound;
}
fn finite(position: Position) bool {
    return std.math.isFinite(position.x) and std.math.isFinite(position.y);
}

/// A false result is sticky in the owning held press. It affects continuation,
/// never the ordinary action, receipt or proposed count of that press.
pub fn motionEligible(press: Timing, motion: ?Position) bool {
    const point = motion orelse return false;
    return press.policy.valid() and finite(press.position) and finite(point) and
        point.domain == press.position.domain and
        press.policy.contains(point.x - press.position.x, point.y - press.position.y);
}

pub fn Classifier(comptime Key: type) type {
    return struct {
        pub const History = struct {
            key: Key,
            first: Position,
            policy: Policy,
            last_tick_ms: u32,
            count: u8,
        };
        pub const Proposal = struct { count: u8, history: ?History };

        /// `previous` must be a completed eligible press from this owner.
        /// Null/invalid timing preserves ordinary count one without seeding.
        pub fn propose(previous: ?History, key: Key, timing: ?Timing) Proposal {
            const input = timing orelse return .{ .count = 1, .history = null };
            if (!input.policy.valid() or !finite(input.position)) return .{ .count = 1, .history = null };
            var next: History = .{
                .key = key,
                .first = input.position,
                .policy = input.policy,
                .last_tick_ms = input.tick_ms,
                .count = 1,
            };
            if (previous) |old| {
                const elapsed = input.tick_ms -% old.last_tick_ms;
                if (old.count >= 1 and old.count < 3 and finite(old.first) and
                    std.meta.eql(old.key, key) and old.first.domain == input.position.domain and
                    std.meta.eql(old.policy, input.policy) and elapsed < 0x80000000 and
                    (if (input.policy.edges.time_inclusive) elapsed <= input.policy.interval_ms else elapsed < input.policy.interval_ms) and
                    input.policy.contains(input.position.x - old.first.x, input.position.y - old.first.y))
                {
                    next.first = old.first;
                    next.count = old.count + 1;
                }
            }
            return .{ .count = next.count, .history = next };
        }

        /// Phase matching, sticky qualification and owner acceptance are
        /// independent facts. None may be inferred from the point/count.
        pub fn complete(proposal: Proposal, matched: bool, eligible: bool, accepted: bool) ?History {
            return if (matched and eligible and accepted) proposal.history else null;
        }
    };
}

const TestKey = struct { owner: u64 = 1, target: u64 = 1, button: u8 = 0 };
const C = Classifier(TestKey);
const rectangle: Policy = .{ .interval_ms = 500, .min_x = -2, .max_x = 3, .min_y = -3, .max_y = 3 };
fn sample(tick: u32, x: f64, y: f64) Timing {
    return .{ .tick_ms = tick, .position = .{ .x = x, .y = y, .domain = 7 }, .policy = rectangle };
}

test "completed bursts restart after three and use original consecutive times" {
    var history: ?C.History = null;
    for ([_]u32{ 0, 400, 800, 1200, 1600, 2000 }, [_]u8{ 1, 2, 3, 1, 2, 3 }) |tick, count| {
        const proposal = C.propose(history, .{}, sample(tick, 10, 10));
        try std.testing.expectEqual(count, proposal.count);
        history = C.complete(proposal, true, true, true);
    }
}

test "burst first anchor prevents cumulative drift and owns a fresh fourth anchor" {
    const first = C.propose(null, .{}, sample(10, 0, 0));
    const second = C.propose(first.history, .{}, sample(20, 2, 0));
    try std.testing.expectEqual(@as(u8, 2), second.count);
    const outside = C.propose(second.history, .{}, sample(30, 4, 0));
    try std.testing.expectEqual(@as(u8, 1), outside.count);
    try std.testing.expectEqual(@as(f64, 4), outside.history.?.first.x);
    const third = C.propose(second.history, .{}, sample(30, 1, 0));
    const fourth = C.propose(third.history, .{}, sample(40, 2, 0));
    try std.testing.expectEqual(@as(u8, 1), fourth.count);
    try std.testing.expectEqual(@as(f64, 2), fourth.history.?.first.x);
}

test "modular ticks accept wrap but reject backwards and half-range ambiguity" {
    const first = C.propose(null, .{}, sample(0xfffffff0, 0, 0));
    try std.testing.expectEqual(@as(u8, 2), C.propose(first.history, .{}, sample(0x10, 0, 0)).count);
    for ([_]u32{ 0xffffffef, 0x7ffffff0, 0x80000010 }) |tick| {
        try std.testing.expectEqual(@as(u8, 1), C.propose(first.history, .{}, sample(tick, 0, 0)).count);
    }
    const zero = C.propose(null, .{}, sample(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 2), C.propose(zero.history, .{}, sample(500, 0, 0)).count);
    try std.testing.expectEqual(@as(u8, 1), C.propose(zero.history, .{}, sample(501, 0, 0)).count);
}

test "edge policy is exact and changing it or the structured owner starts one" {
    const first = C.propose(null, .{}, sample(0, 0, 0));
    const cases = [_]struct { x: f64, y: f64, expected: u8 }{
        .{ .x = -2, .y = -3, .expected = 2 },
        .{ .x = 2.999, .y = 2.999, .expected = 2 },
        .{ .x = 3, .y = 0, .expected = 1 },
        .{ .x = 0, .y = 3, .expected = 1 },
        .{ .x = -2.001, .y = 0, .expected = 1 },
    };
    for (cases) |entry| try std.testing.expectEqual(entry.expected, C.propose(first.history, .{}, sample(1, entry.x, entry.y)).count);
    for ([_]TestKey{ .{ .owner = 2 }, .{ .target = 2 }, .{ .button = 1 } }) |key|
        try std.testing.expectEqual(@as(u8, 1), C.propose(first.history, key, sample(1, 0, 0)).count);
    var other = sample(1, 0, 0);
    other.position.domain = 8;
    try std.testing.expectEqual(@as(u8, 1), C.propose(first.history, .{}, other).count);
    other = sample(1, 0, 0);
    other.policy.edges.time_inclusive = false;
    try std.testing.expectEqual(@as(u8, 1), C.propose(first.history, .{}, other).count);
    const exclusive = C.propose(null, .{}, other);
    other.tick_ms = 501;
    try std.testing.expectEqual(@as(u8, 1), C.propose(exclusive.history, .{}, other).count);
    other.tick_ms = 500;
    try std.testing.expectEqual(@as(u8, 2), C.propose(exclusive.history, .{}, other).count);
}

test "unqualified and rejected phases never seed a history" {
    const first = C.propose(null, .{}, sample(0, 0, 0));
    const no_timing = C.propose(first.history, .{}, null);
    try std.testing.expectEqual(@as(u8, 1), no_timing.count);
    try std.testing.expect(no_timing.history == null);
    for (0..7) |bits| {
        try std.testing.expect(C.complete(first, bits & 1 != 0, bits & 2 != 0, bits & 4 != 0) == null);
    }
    try std.testing.expect(C.complete(first, true, true, true) != null);
    var bad = sample(1, 0, 0);
    bad.position.x = std.math.nan(f64);
    try std.testing.expect(C.propose(first.history, .{}, bad).history == null);
    bad = sample(1, 0, 0);
    bad.policy.interval_ms = 0x80000000;
    try std.testing.expect(C.propose(first.history, .{}, bad).history == null);
    bad = sample(1, 0, 0);
    bad.policy.max_x = std.math.inf(f64);
    try std.testing.expect(C.propose(first.history, .{}, bad).history == null);
    bad = sample(1, 0, 0);
    bad.policy.edges.reserved = 1;
    try std.testing.expect(C.propose(first.history, .{}, bad).history == null);
}

test "motion qualification uses the held down sample and never manufactures authority" {
    const press = sample(0, 10, 20);
    try std.testing.expect(motionEligible(press, .{ .x = 8, .y = 17, .domain = 7 }));
    try std.testing.expect(!motionEligible(press, .{ .x = 13, .y = 20, .domain = 7 }));
    try std.testing.expect(!motionEligible(press, .{ .x = 10, .y = 20, .domain = 8 }));
    try std.testing.expect(!motionEligible(press, null));
    try std.testing.expect(!motionEligible(press, .{ .x = std.math.inf(f64), .y = 20, .domain = 7 }));
    var sticky = true;
    for ([_]?Position{ .{ .x = 13, .y = 20, .domain = 7 }, .{ .x = 10, .y = 20, .domain = 7 } }) |point|
        sticky = sticky and motionEligible(press, point);
    try std.testing.expect(!sticky);
    const proposed = C.propose(null, .{}, press);
    try std.testing.expectEqual(@as(u8, 1), proposed.count);
    try std.testing.expect(C.complete(proposed, true, sticky, true) == null);
}

test "raw and semantic owners classify independent completed keys" {
    var raw: ?C.History = null;
    var semantic: ?C.History = null;
    const keys = [_]TestKey{ .{ .target = 1 }, .{ .target = 2 }, .{ .target = 2 }, .{ .target = 2 } };
    for (keys, [_]u8{ 1, 2, 3, 1 }, [_]u8{ 1, 1, 2, 3 }, 0..) |key, raw_count, semantic_count, index| {
        const timing = sample(@intCast(index * 10), 0, 0);
        const raw_proposal = C.propose(raw, .{}, timing);
        const semantic_proposal = C.propose(semantic, key, timing);
        try std.testing.expectEqual(raw_count, raw_proposal.count);
        try std.testing.expectEqual(semantic_count, semantic_proposal.count);
        raw = C.complete(raw_proposal, true, true, true);
        semantic = C.complete(semantic_proposal, true, true, true);
    }
    // The owner finalizes an unclaimed/denied intermediate ingress as null.
    semantic = null;
    try std.testing.expectEqual(@as(u8, 1), C.propose(semantic, keys[3], sample(50, 0, 0)).count);
}

test "inclusive distance and exclusive interval including zero thresholds" {
    var timing = sample(0, 0, 0);
    timing.policy = .{ .interval_ms = 100, .min_x = -2, .max_x = 2, .min_y = -2, .max_y = 2, .edges = .{
        .max_x_inclusive = true,
        .max_y_inclusive = true,
        .time_inclusive = false,
    } };
    const first = C.propose(null, .{}, timing);
    timing.position.x = 2;
    timing.position.y = -2;
    timing.tick_ms = 99;
    try std.testing.expectEqual(@as(u8, 2), C.propose(first.history, .{}, timing).count);
    timing.tick_ms = 100;
    try std.testing.expectEqual(@as(u8, 1), C.propose(first.history, .{}, timing).count);
    timing.policy.min_x = 0;
    timing.policy.max_x = 0;
    timing.policy.min_y = 0;
    timing.policy.max_y = 0;
    timing.position = .{ .x = 0, .y = 0, .domain = 7 };
    try std.testing.expect(timing.policy.valid());
    try std.testing.expect(motionEligible(timing, timing.position));
    timing.policy.interval_ms = 0;
    const no_interval = C.propose(null, .{}, timing);
    try std.testing.expectEqual(@as(u8, 1), C.propose(no_interval.history, .{}, timing).count);
    timing.policy.edges.time_inclusive = true;
    const same_tick = C.propose(null, .{}, timing);
    try std.testing.expectEqual(@as(u8, 2), C.propose(same_tick.history, .{}, timing).count);
}

test "all short elapsed intervals follow the captured inclusive flag across wrap" {
    for ([_]u32{ 0, 0xffffff00 }) |start| for ([_]bool{ false, true }) |inclusive| {
        var timing = sample(start, 0, 0);
        timing.policy.edges.time_inclusive = inclusive;
        const first = C.propose(null, .{}, timing);
        for (0..512) |elapsed| {
            timing.tick_ms = start +% @as(u32, @intCast(elapsed));
            const expected: u8 = if (elapsed < 500 or (inclusive and elapsed == 500)) 2 else 1;
            try std.testing.expectEqual(expected, C.propose(first.history, .{}, timing).count);
        }
    };
    std.debug.print("Pure click declarations: Position={d} Policy={d} Timing={d} Key={d} History={d} Proposal={d}; no owner/native integration\n", .{
        @sizeOf(Position), @sizeOf(Policy), @sizeOf(Timing), @sizeOf(TestKey), @sizeOf(C.History), @sizeOf(C.Proposal),
    });
}
