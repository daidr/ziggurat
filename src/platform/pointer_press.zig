const std = @import("std");
const clicks = @import("pointer_classifier");

// Private raw ownership only. Native adapters advance Operation before any
// callback, then supply that stamp here. Core must additionally validate its
// real active ingress, Window/native identity, permission and callback pins.
// A monotonic stamp alone is not native authority: Core must compare the
// actual adapter counter after foreign work before it calls begin/revoke.
pub const Button = enum(u3) { primary, secondary, middle, back, forward };
pub const Phase = enum { down, up };
pub const Receipt = struct {
    sequence: u64 = 0,
    window_count: u8 = 1,
    eligible: bool = false,
    qualified: bool = false,
};
pub const Timing = clicks.Timing;
pub const Position = clicks.Position;
pub const Snapshot = struct {
    timing: ?Timing,
    continuation_eligible: bool,
    button: Button,
    // A raw completion fact, not a semantic claim or the current press count.
    // Only the current matching down can expose this captured predecessor.
    previous_completed_sequence: u64 = 0,
};

const exhausted: u64 = std.math.maxInt(u64);

/// One native-owned value, also needed with the optional raw owner disabled.
/// Zero is not issued; MAX is permanent retirement, not a reusable operation.
pub const Operation = struct {
    value: u64 = 0,

    pub fn advance(self: *Operation) u64 {
        self.value = if (self.value >= exhausted - 1) exhausted else self.value + 1;
        return self.value;
    }

    pub fn retire(self: *Operation) void {
        self.value = exhausted;
    }

    pub fn matches(self: Operation, value: u64) bool {
        return usable(value) and self.value == value;
    }
};

/// A call-local ticket, never a public claim capability. A native up gets a
/// fresh operation while retaining its matching down's receipt and count.
pub const Transition = struct {
    operation: u64,
    button: ?Button,
    phase: Phase,
    press: Receipt,
};

// 'delivered' means the native raw delivery was permitted and completed. It is
// not a UI handler/target acceptance. Consumed input is still observed; denied
// input cannot retain a permitted pair. Revoke is a separate earlier transition.
pub const Disposition = enum { delivered, consumed, denied };

const C = clicks.Classifier(Button);
const PairPhase = enum { empty, down_pending, held, releasing, releasing_unfinished };
const Latch = struct {
    sequence: u64 = 0,
    timing: ?Timing = null,
    count: u8 = 1,
    eligible: bool = false,
    phase: PairPhase = .empty,

    fn receipt(self: *const Latch) Receipt {
        return .{
            .sequence = self.sequence,
            .window_count = self.count,
            .eligible = self.eligible,
            .qualified = self.timing != null,
        };
    }
};
const Latest = struct { sequence: u64, previous_completed_sequence: u64, button: Button, proposal: C.Proposal };

pub const Owner = struct {
    // This observes the adapter's counter; it does not issue another operation.
    operation: u64 = 0,
    last_sequence: u64 = 0,
    latches: [5]Latch = @splat(.{}),
    history: ?C.History = null,
    latest: ?Latest = null,

    /// Each real adapter down supplies a new operation, including unknown
    /// button/timing, consumed native decoration and denied business delivery.
    /// Null return rejects stale/exhausted operation; ordinary native delivery
    /// may still use a default receipt without claiming raw authority.
    pub fn beginDown(self: *Owner, operation: u64, button: ?Button, timing: ?Timing) ?Transition {
        if (!self.enter(operation)) return null;
        const previous = self.history;
        const previous_completed_sequence = if (previous != null) self.last_sequence else 0;
        self.history = null;
        self.latest = null;
        for (&self.latches) |*latch| latch.eligible = false;
        const input = button orelse return unpaired(operation, null, .down);
        if (self.last_sequence >= exhausted - 1) {
            self.last_sequence = exhausted;
            self.clear();
            return unpaired(operation, input, .down);
        }
        self.last_sequence += 1;
        const qualified = validTiming(timing);
        const proposal = C.propose(previous, input, qualified);
        const latch = &self.latches[index(input)];
        latch.* = .{
            .sequence = self.last_sequence,
            .timing = qualified,
            .count = proposal.count,
            .eligible = qualified != null,
            .phase = .down_pending,
        };
        self.latest = .{ .sequence = latch.sequence, .previous_completed_sequence = previous_completed_sequence, .button = input, .proposal = proposal };
        return .{ .operation = operation, .button = input, .phase = .down, .press = latch.receipt() };
    }

    /// Finish exactly this pending down. A stale outer finalizer cannot alter a
    /// nested new press or clear its aggregate history/latest proposal.
    pub fn finishDown(self: *Owner, transition: Transition, disposition: Disposition) bool {
        const latch = self.match(transition, .down) orelse return false;
        switch (disposition) {
            .delivered => latch.phase = .held,
            .consumed => {
                latch.phase = .held;
                latch.eligible = false;
                self.dropLatest(transition.press.sequence);
            },
            .denied => {
                latch.* = .{};
                self.dropLatest(transition.press.sequence);
            },
        }
        return true;
    }

    /// Every native up also advances the native operation first. An old
    /// button's receipt remains pairable after a different button was observed.
    pub fn beginUp(self: *Owner, operation: u64, button: ?Button) ?Transition {
        if (!self.enter(operation)) return null;
        const input = button orelse return unpaired(operation, null, .up);
        const latch = &self.latches[index(input)];
        switch (latch.phase) {
            .held => latch.phase = .releasing,
            .down_pending => {
                // Up reentered before the down's final delivery guard. Pair it,
                // but do not turn an unfinished down into completed history.
                latch.phase = .releasing_unfinished;
                latch.eligible = false;
            },
            .empty => return unpaired(operation, input, .up),
            .releasing, .releasing_unfinished => {
                // A duplicate nested up supersedes the old up's operation.
                // Retire only this pair; leave any newer other-button history.
                self.dropLatest(latch.sequence);
                latch.* = .{};
                return unpaired(operation, input, .up);
            },
        }
        return .{ .operation = operation, .button = input, .phase = .up, .press = latch.receipt() };
    }

    /// Called after all callback-producing native release work and its final
    /// authority check. Qualification is read now, never from an old Snapshot.
    pub fn finishUp(self: *Owner, transition: Transition, disposition: Disposition) bool {
        const latch = self.match(transition, .up) orelse return false;
        if (self.latest) |latest| {
            if (latest.sequence == latch.sequence and latest.button == transition.button.?) {
                self.history = C.complete(latest.proposal, true, latch.eligible, disposition == .delivered and latch.phase == .releasing);
                self.latest = null;
            }
        }
        latch.* = .{};
        return true;
    }

    /// Pure current-operation/pair guard for native tails. This alone does not
    /// prove actual capture ownership, permission or Core active ingress.
    pub fn current(self: *const Owner, transition: Transition) bool {
        return self.matchConst(transition, transition.phase) != null;
    }

    /// Rebuild the current value from a compact native operation/receipt ticket.
    /// This does not issue identity or authorize the caller's native ingress.
    pub fn lookup(self: *const Owner, operation: u64, sequence: u64, button: Button, phase: Phase) ?Transition {
        const latch = &self.latches[index(button)];
        if (sequence == 0 or latch.sequence != sequence) return null;
        const value: Transition = .{ .operation = operation, .button = button, .phase = phase, .press = latch.receipt() };
        return if (self.matchConst(value, phase) != null) value else null;
    }

    /// Core supplies its real active transition and expected Event phase.
    /// Event.eligible is deliberately not part of identity equality.
    pub fn snapshot(self: *const Owner, active: Transition, press: Receipt, expected_phase: Phase) error{StalePointerInput}!Snapshot {
        const latch = self.matchConst(active, expected_phase) orelse return error.StalePointerInput;
        if (!sameReceipt(latch, press)) return error.StalePointerInput;
        var result: Snapshot = .{ .timing = latch.timing, .continuation_eligible = latch.eligible, .button = active.button.? };
        if (expected_phase == .down) {
            if (self.latest) |latest| {
                if (latest.sequence == latch.sequence and latest.button == active.button.?) result.previous_completed_sequence = latest.previous_completed_sequence;
            }
        }
        return result;
    }

    /// Read only a completed down that has not begun release. Core separately
    /// checks its live Window, input permission and the native operation. This
    /// exposes no event, timing or click-continuation authority.
    pub fn held(self: *const Owner, press: Receipt, button: Button) error{StalePointerInput}!void {
        const latch = &self.latches[index(button)];
        if (!usable(self.operation) or latch.phase != .held or !sameReceipt(latch, press)) return error.StalePointerInput;
    }

    /// A normal raw motion does not advance the operation or cancel ordinary
    /// pairing/action. Unknown samples are explicitly sticky disqualification.
    pub fn motion(self: *Owner, operation: u64, position: ?Position) bool {
        if (!usable(operation) or operation != self.operation) return false;
        for (&self.latches) |*latch| {
            if (latch.phase != .empty and latch.eligible) {
                latch.eligible = if (latch.timing) |timing| clicks.motionEligible(timing, position) else false;
            }
        }
        return true;
    }

    /// Explicit native loss/denial/domain revocation. The adapter advances its
    /// operation before this and before native cancellation can call back.
    pub fn revoke(self: *Owner, operation: u64) bool {
        if (!self.enter(operation)) return false;
        self.clear();
        return true;
    }

    /// Close/native retirement is permanent for this fixed owner. A new native
    /// Window requires a different Owner, never reset() on this one.
    pub fn retire(self: *Owner) void {
        self.operation = exhausted;
        self.clear();
    }

    fn enter(self: *Owner, operation: u64) bool {
        if (operation == exhausted) {
            self.retire();
            return false;
        }
        if (!usable(operation) or operation <= self.operation) return false;
        self.operation = operation;
        return true;
    }

    fn clear(self: *Owner) void {
        self.latches = @splat(.{});
        self.history = null;
        self.latest = null;
    }

    fn dropLatest(self: *Owner, sequence: u64) void {
        if (self.latest) |latest| {
            if (latest.sequence == sequence) self.latest = null;
        }
    }

    fn match(self: *Owner, transition: Transition, phase: Phase) ?*Latch {
        _ = self.matchConst(transition, phase) orelse return null;
        return &self.latches[index(transition.button.?)];
    }

    fn matchConst(self: *const Owner, transition: Transition, phase: Phase) ?*const Latch {
        if (!usable(transition.operation) or transition.operation != self.operation or transition.phase != phase) return null;
        const input = transition.button orelse return null;
        const latch = &self.latches[index(input)];
        if (!sameReceipt(latch, transition.press)) return null;
        if (phase == .down) {
            if (latch.phase != .down_pending) return null;
        } else if (latch.phase != .releasing and latch.phase != .releasing_unfinished) return null;
        return latch;
    }
};

fn usable(value: u64) bool {
    return value != 0 and value != exhausted;
}
fn index(button: Button) usize {
    return @backingInt(button);
}
fn unpaired(operation: u64, button: ?Button, phase: Phase) Transition {
    return .{ .operation = operation, .button = button, .phase = phase, .press = .{} };
}
fn sameReceipt(latch: *const Latch, press: Receipt) bool {
    return press.sequence != 0 and latch.sequence == press.sequence and
        latch.count == press.window_count and (latch.timing != null) == press.qualified;
}
fn validTiming(timing: ?Timing) ?Timing {
    const input = timing orelse return null;
    return if (input.policy.valid() and std.math.isFinite(input.position.x) and std.math.isFinite(input.position.y)) input else null;
}

const Test = struct {
    owner: Owner = .{},
    operation: Operation = .{},

    fn down(self: *Test, button: ?Button, timing: ?Timing) Transition {
        const operation = self.operation.advance();
        return self.observedDown(operation, button, timing).?;
    }
    fn observedDown(self: *Test, operation: u64, button: ?Button, timing: ?Timing) ?Transition {
        if (!self.operation.matches(operation)) return null;
        return self.owner.beginDown(operation, button, timing);
    }
    fn up(self: *Test, button: ?Button) Transition {
        return self.owner.beginUp(self.operation.advance(), button).?;
    }
    fn complete(self: *Test, button: Button, timing: ?Timing) !Receipt {
        const pressed = self.down(button, timing);
        try std.testing.expect(self.owner.finishDown(pressed, .delivered));
        const released = self.up(button);
        try std.testing.expectEqual(pressed.press.sequence, released.press.sequence);
        try std.testing.expectEqual(pressed.press.window_count, released.press.window_count);
        try std.testing.expect(self.owner.finishUp(released, .delivered));
        return pressed.press;
    }
};
fn sample(tick: u32, x: f64, y: f64) Timing {
    return .{
        .tick_ms = tick,
        .position = .{ .x = x, .y = y, .domain = 7 },
        .policy = .{ .interval_ms = 500, .min_x = -2, .max_x = 3, .min_y = -3, .max_y = 3 },
    };
}

test "native operation is independent of nullable timing and never wraps" {
    std.debug.print("raw press layouts operation={d} receipt={d} snapshot={d} transition={d} latch={d} history={d} latest={d} owner={d}\n", .{ @sizeOf(Operation), @sizeOf(Receipt), @sizeOf(Snapshot), @sizeOf(Transition), @sizeOf(Latch), @sizeOf(C.History), @sizeOf(Latest), @sizeOf(Owner) });
    var operation: Operation = .{};
    try std.testing.expect(!operation.matches(0));
    try std.testing.expectEqual(@as(u64, 1), operation.advance());
    try std.testing.expect(operation.matches(1));
    try std.testing.expectEqual(@as(u64, 2), operation.advance());
    try std.testing.expect(!operation.matches(1));
    operation.value = exhausted - 2;
    try std.testing.expectEqual(exhausted - 1, operation.advance());
    try std.testing.expectEqual(exhausted, operation.advance());
    try std.testing.expectEqual(exhausted, operation.advance());
    try std.testing.expect(!operation.matches(exhausted));
}

test "paired completed history counts 1 2 3 1 with qualified tick zero" {
    var state: Test = .{};
    for ([_]u32{ 0, 400, 800, 1200 }, [_]u8{ 1, 2, 3, 1 }) |tick, count| {
        const press = try state.complete(.primary, sample(tick, 10, 20));
        try std.testing.expectEqual(count, press.window_count);
        try std.testing.expect(press.sequence != 0 and press.qualified and press.eligible);
    }
    try std.testing.expectEqual(@as(u64, 4), state.owner.last_sequence);
    try std.testing.expectEqual(@as(u64, 8), state.operation.value);
}

test "null timing retains native identity and matching count one without history" {
    var state: Test = .{};
    _ = try state.complete(.primary, sample(0, 0, 0));
    const down = state.down(.primary, null);
    try std.testing.expect(down.press.sequence != 0 and !down.press.qualified and !down.press.eligible);
    try std.testing.expectEqual(@as(u8, 1), down.press.window_count);
    const snapshot = try state.owner.snapshot(down, down.press, .down);
    try std.testing.expect(snapshot.timing == null and !snapshot.continuation_eligible);
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    const up = state.up(.primary);
    try std.testing.expectEqualDeep(down.press, up.press);
    try std.testing.expect((try state.owner.snapshot(up, up.press, .up)).timing == null);
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expect(state.owner.history == null);
    try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(10, 0, 0))).window_count);
}

test "invalid timing is unqualified without suppressing ordinary paired input" {
    const cases = [_]Timing{ blk: {
        var value = sample(0, 0, 0);
        value.position.x = std.math.nan(f64);
        break :blk value;
    }, blk: {
        var value = sample(0, 0, 0);
        value.policy.interval_ms = 0x80000000;
        break :blk value;
    }, blk: {
        var value = sample(0, 0, 0);
        value.policy.edges.reserved = 1;
        break :blk value;
    } };
    for (cases) |timing| {
        var state: Test = .{};
        const press = try state.complete(.primary, timing);
        try std.testing.expect(press.sequence != 0 and !press.qualified and !press.eligible);
        try std.testing.expectEqual(@as(u8, 1), press.window_count);
        try std.testing.expect(state.owner.history == null);
    }
}

test "motion out and back changes snapshot eligibility not identity count or ordinary pairing" {
    var state: Test = .{};
    _ = try state.complete(.primary, sample(0, 10, 20));
    const down = state.down(.primary, sample(10, 10, 20));
    try std.testing.expectEqual(@as(u8, 2), down.press.window_count);
    const before = try state.owner.snapshot(down, down.press, .down);
    try std.testing.expect(before.continuation_eligible);
    try std.testing.expect(state.owner.motion(state.operation.value, .{ .x = 13, .y = 20, .domain = 7 }));
    try std.testing.expect(state.owner.motion(state.operation.value, .{ .x = 10, .y = 20, .domain = 7 }));
    const after = try state.owner.snapshot(down, down.press, .down);
    try std.testing.expect(!after.continuation_eligible and after.timing != null);
    try std.testing.expect(down.press.eligible); // Old Event bit is not identity.
    try std.testing.expect(state.owner.current(down));
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    const up = state.up(.primary);
    try std.testing.expectEqual(down.press.sequence, up.press.sequence);
    try std.testing.expectEqual(down.press.window_count, up.press.window_count);
    try std.testing.expect(!up.press.eligible and up.press.qualified);
    var ordinary_actions: usize = 0;
    if (state.owner.current(up)) ordinary_actions += 1;
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expectEqual(@as(usize, 1), ordinary_actions);
    try std.testing.expect(state.owner.history == null);
    try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(20, 10, 20))).window_count);
}

test "unknown nonfinite and changed-domain motion are sticky including during up" {
    const positions = [_]?Position{ null, .{ .x = std.math.inf(f64), .y = 0, .domain = 7 }, .{ .x = 0, .y = 0, .domain = 8 } };
    for (positions) |position| {
        var state: Test = .{};
        const down = state.down(.primary, sample(0, 0, 0));
        try std.testing.expect(state.owner.finishDown(down, .delivered));
        const up = state.up(.primary);
        const old_snapshot = try state.owner.snapshot(up, up.press, .up);
        try std.testing.expect(old_snapshot.continuation_eligible);
        try std.testing.expect(state.owner.motion(state.operation.value, position));
        try std.testing.expect(state.owner.motion(state.operation.value, .{ .x = 0, .y = 0, .domain = 7 }));
        try std.testing.expect(!(try state.owner.snapshot(up, up.press, .up)).continuation_eligible);
        try std.testing.expect(state.owner.finishUp(up, .delivered));
        try std.testing.expect(state.owner.history == null);
    }
}

test "five button latches pair independently but only one latest press can seed" {
    var state: Test = .{};
    var presses: [5]Receipt = undefined;
    inline for (std.meta.tags(Button), 0..) |button, i| {
        const down = state.down(button, sample(@intCast(i * 10), 0, 0));
        presses[i] = down.press;
        try std.testing.expect(state.owner.finishDown(down, .delivered));
    }
    inline for (std.meta.tags(Button), 0..) |button, i| {
        const up = state.up(button);
        try std.testing.expectEqual(presses[i].sequence, up.press.sequence);
        try std.testing.expectEqual(presses[i].window_count, up.press.window_count);
        try std.testing.expectEqual(i == 4, up.press.eligible);
        try std.testing.expect(state.owner.finishUp(up, .delivered));
    }
    try std.testing.expectEqual(Button.forward, state.owner.history.?.key);
    try std.testing.expectEqual(@as(u8, 2), (try state.complete(.forward, sample(100, 0, 0))).window_count);
}

test "older button up cannot clear newer completed aggregate history" {
    var state: Test = .{};
    const older = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.finishDown(older, .delivered));
    _ = try state.complete(.secondary, sample(10, 0, 0));
    const old_up = state.up(.primary);
    try std.testing.expectEqual(older.press.sequence, old_up.press.sequence);
    try std.testing.expect(!old_up.press.eligible);
    try std.testing.expect(state.owner.finishUp(old_up, .delivered));
    try std.testing.expectEqual(Button.secondary, state.owner.history.?.key);
    try std.testing.expectEqual(@as(u8, 2), (try state.complete(.secondary, sample(20, 0, 0))).window_count);
}

test "unknown consumed and denied down break completed continuity on every return" {
    var unknown: Test = .{};
    _ = try unknown.complete(.primary, sample(0, 0, 0));
    const ignored = unknown.down(null, sample(10, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), ignored.press.sequence);
    try std.testing.expect(!unknown.owner.current(ignored));
    try std.testing.expectEqual(@as(u8, 1), (try unknown.complete(.primary, sample(20, 0, 0))).window_count);
    for ([_]Disposition{ .consumed, .denied }) |disposition| {
        var state: Test = .{};
        _ = try state.complete(.primary, sample(0, 0, 0));
        const down = state.down(.primary, sample(10, 0, 0));
        try std.testing.expectEqual(@as(u8, 2), down.press.window_count);
        try std.testing.expect(state.owner.finishDown(down, disposition));
        const up = state.up(.primary);
        if (disposition == .consumed) {
            try std.testing.expectEqual(down.press.sequence, up.press.sequence);
            try std.testing.expect(state.owner.finishUp(up, .delivered));
        } else try std.testing.expectEqual(@as(u64, 0), up.press.sequence);
        try std.testing.expect(state.owner.history == null);
        try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(20, 0, 0))).window_count);
    }
}

test "unknown button breaks continuation without deleting another held pairing" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    _ = state.down(null, null);
    const up = state.up(.primary);
    try std.testing.expectEqual(down.press.sequence, up.press.sequence);
    try std.testing.expectEqual(down.press.window_count, up.press.window_count);
    try std.testing.expect(!up.press.eligible);
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expect(state.owner.history == null);
}

test "nonaccepted up cannot seed even when down delivery and timing were valid" {
    for ([_]Disposition{ .consumed, .denied }) |disposition| {
        var state: Test = .{};
        _ = try state.complete(.primary, sample(0, 0, 0));
        const down = state.down(.primary, sample(10, 0, 0));
        try std.testing.expect(state.owner.finishDown(down, .delivered));
        const up = state.up(.primary);
        try std.testing.expectEqual(@as(u8, 2), up.press.window_count);
        try std.testing.expect((try state.owner.snapshot(up, up.press, .up)).continuation_eligible);
        try std.testing.expect(state.owner.finishUp(up, disposition));
        try std.testing.expect(state.owner.history == null);
        try std.testing.expect(!state.owner.finishUp(up, .delivered));
        try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(20, 0, 0))).window_count);
    }
}

test "nested down supersedes old down and restored transition cannot revive it" {
    var state: Test = .{};
    const old = state.down(.primary, sample(0, 0, 0));
    const nested = state.down(.primary, sample(1, 0, 0));
    try std.testing.expect(!state.owner.finishDown(old, .denied));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(old, old.press, .down));
    try std.testing.expect(state.owner.current(nested));
    try std.testing.expect(state.owner.finishDown(nested, .delivered));
    const up = state.up(.primary);
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expect(!state.owner.finishDown(old, .consumed));
    try std.testing.expectEqual(@as(u8, 2), (try state.complete(.primary, sample(2, 0, 0))).window_count);
}

test "nested new down makes old release tail inert before and after new completion" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    const old_up = state.up(.primary);
    const newer = state.down(.primary, sample(1, 0, 0));
    try std.testing.expect(!state.owner.current(old_up));
    try std.testing.expect(!state.owner.finishUp(old_up, .denied));
    try std.testing.expect(state.owner.finishDown(newer, .delivered));
    const newer_up = state.up(.primary);
    try std.testing.expect(state.owner.finishUp(newer_up, .delivered));
    try std.testing.expect(!state.owner.finishUp(old_up, .delivered));
    try std.testing.expectEqual(@as(u8, 2), (try state.complete(.primary, sample(2, 0, 0))).window_count);
}

test "nested duplicate up advances operation and cannot reuse releasing receipt" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    const outer = state.up(.primary);
    const duplicate = state.up(.primary);
    try std.testing.expectEqual(@as(u64, 0), duplicate.press.sequence);
    try std.testing.expect(!state.owner.current(outer) and !state.owner.current(duplicate));
    try std.testing.expect(!state.owner.finishUp(outer, .delivered));
    try std.testing.expect(state.owner.history == null and state.owner.latest == null);
}

test "nested up before down final guard retains pair but cannot seed" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    const up = state.up(.primary);
    try std.testing.expectEqual(down.press.sequence, up.press.sequence);
    try std.testing.expect(!up.press.eligible and state.owner.current(up));
    try std.testing.expect(!state.owner.finishDown(down, .delivered));
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expect(state.owner.history == null);
}

test "snapshot checks phase immutable receipt and current operation not old eligible bit" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, down.press, .up));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, .{}, .down));
    var edited = down.press;
    edited.sequence += 1;
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, edited, .down));
    edited = down.press;
    edited.window_count = 3;
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, edited, .down));
    edited = down.press;
    edited.qualified = false;
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, edited, .down));
    edited = down.press;
    edited.eligible = false;
    try std.testing.expect((try state.owner.snapshot(down, edited, .down)).continuation_eligible);
    try std.testing.expect(state.owner.finishDown(down, .delivered));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, down.press, .down));
    const up = state.up(.primary);
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(up, up.press, .down));
    try std.testing.expect(state.owner.finishUp(up, .delivered));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(up, up.press, .up));
}

test "revocation preserves monotonic sequences and close never reopens this owner" {
    var state: Test = .{};
    const first = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.revoke(state.operation.advance()));
    try std.testing.expect(!state.owner.finishDown(first, .delivered));
    const later = state.down(.primary, sample(1, 0, 0));
    try std.testing.expect(later.press.sequence > first.press.sequence);
    try std.testing.expectEqual(@as(u8, 1), later.press.window_count);
    try std.testing.expect(state.owner.finishDown(later, .delivered));
    state.owner.retire();
    try std.testing.expect(state.owner.beginUp(state.operation.advance(), .primary) == null);
    try std.testing.expect(state.owner.beginDown(state.operation.advance(), .primary, sample(2, 0, 0)) == null);
    try std.testing.expect(state.owner.history == null and state.owner.latest == null);
}

test "reused older or zero operation cannot revoke or resurrect a newer press" {
    var state: Test = .{};
    const down = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.beginDown(0, .primary, null) == null);
    try std.testing.expect(state.owner.beginDown(down.operation, .primary, null) == null);
    try std.testing.expect(!state.owner.revoke(down.operation));
    try std.testing.expect(state.owner.current(down));
    const newer = state.down(.secondary, sample(1, 0, 0));
    try std.testing.expect(!state.owner.motion(down.operation, null));
    try std.testing.expect(state.owner.current(newer));
    try std.testing.expect((try state.owner.snapshot(newer, newer.press, .down)).continuation_eligible);
}

test "post-foreign native counter gate precedes any history access" {
    var state: Test = .{};
    _ = try state.complete(.primary, sample(0, 0, 0));
    const before = state.owner.history;
    const captured = state.operation.advance();
    _ = state.operation.advance(); // Foreign work changed actual native authority.
    // captured is newer than Owner.operation, but is not the actual current
    // adapter operation. A monotonic comparison inside Owner is insufficient.
    try std.testing.expect(captured > state.owner.operation);
    try std.testing.expect(state.observedDown(captured, .primary, sample(10, 0, 0)) == null);
    try std.testing.expectEqualDeep(before, state.owner.history);
    try std.testing.expectEqual(@as(u64, 1), state.owner.last_sequence);
    // The native transition's independent revocation now reaches this owner.
    try std.testing.expect(state.owner.revoke(state.operation.value));
    try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(20, 0, 0))).window_count);
}

test "sequence and operation exhaustion clear authority instead of saturating a usable receipt" {
    var state: Test = .{};
    state.owner.last_sequence = exhausted - 2;
    const last = try state.complete(.primary, sample(0, 0, 0));
    try std.testing.expectEqual(exhausted - 1, last.sequence);
    const no_receipt = state.down(.primary, sample(1, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), no_receipt.press.sequence);
    try std.testing.expectEqual(@as(u8, 1), no_receipt.press.window_count);
    try std.testing.expect(state.owner.history == null and state.owner.latest == null);
    try std.testing.expectEqual(@as(u64, 0), state.down(.secondary, null).press.sequence);
    var other: Test = .{};
    const down = other.down(.primary, sample(0, 0, 0));
    other.operation.retire();
    try std.testing.expect(other.owner.beginUp(other.operation.value, .primary) == null);
    try std.testing.expect(!other.owner.current(down));
    try std.testing.expect(other.owner.history == null and other.owner.latest == null);
}

test "owner delegates original-time wrap first-anchor and exact threshold policy" {
    var state: Test = .{};
    _ = try state.complete(.primary, sample(0xfffffff0, 0, 0));
    try std.testing.expectEqual(@as(u8, 2), (try state.complete(.primary, sample(0x10, 2, 0))).window_count);
    try std.testing.expectEqual(@as(u8, 1), (try state.complete(.primary, sample(0x20, 4, 0))).window_count);
    var edge: Test = .{};
    _ = try edge.complete(.primary, sample(0, 0, 0));
    try std.testing.expectEqual(@as(u8, 2), (try edge.complete(.primary, sample(500, -2, -3))).window_count);
    try std.testing.expectEqual(@as(u8, 1), (try edge.complete(.primary, sample(501, 3, 0))).window_count);
    var changed = sample(502, 3, 0);
    changed.position.domain = 8;
    try std.testing.expectEqual(@as(u8, 1), (try edge.complete(.primary, changed)).window_count);
}

// The fallback lets these same behavioral assertions compile against the
// archived owner that did not expose the fact; positive cases must still fail.
fn previousCompletedForTest(snapshot_value: Snapshot) u64 {
    return if (@hasField(Snapshot, "previous_completed_sequence")) snapshot_value.previous_completed_sequence else 0;
}
fn previousForTest(state: *const Test, input: Transition) !u64 {
    return previousCompletedForTest(try state.owner.snapshot(input, input.press, input.phase));
}

test "completed sequence is a down fact independent of timing and sticky motion" {
    var state: Test = .{};
    const first = state.down(.primary, sample(0, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, first));
    try std.testing.expect(state.owner.finishDown(first, .delivered));
    const first_up = state.up(.primary);
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, first_up));
    try std.testing.expect(state.owner.finishUp(first_up, .delivered));
    const next = state.down(.primary, null);
    try std.testing.expectEqual(first.press.sequence, try previousForTest(&state, next));
    try std.testing.expect(!next.press.qualified);
    try std.testing.expect(state.owner.motion(next.operation, null));
    try std.testing.expectEqual(first.press.sequence, try previousForTest(&state, next));
    try std.testing.expect(state.owner.finishDown(next, .delivered));
    const next_up = state.up(.primary);
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, next_up));
    try std.testing.expect(state.owner.finishUp(next_up, .delivered));
    const after_unqualified = state.down(.primary, sample(20, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, after_unqualified));
}

test "unobserved unknown or other down cannot preserve completed sequence" {
    var unknown: Test = .{};
    const completed = try unknown.complete(.primary, sample(0, 0, 0));
    _ = unknown.down(null, null); // Native observation need not reach Content.
    try std.testing.expectEqual(completed.sequence, unknown.owner.last_sequence);
    const later = unknown.down(.primary, sample(20, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&unknown, later));
    for ([_]?Disposition{ null, .consumed, .denied }) |disposition| {
        var state: Test = .{};
        const before = try state.complete(.primary, sample(0, 0, 0));
        const other = state.down(.secondary, sample(10, 0, 0));
        try std.testing.expectEqual(before.sequence, try previousForTest(&state, other));
        if (disposition) |value| try std.testing.expect(state.owner.finishDown(other, value));
        const after = state.down(.primary, sample(20, 0, 0));
        try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, after));
    }
    var different: Test = .{};
    _ = try different.complete(.primary, sample(0, 0, 0));
    const other_completed = try different.complete(.secondary, sample(10, 0, 0));
    const changed_button = different.down(.primary, sample(20, 0, 0));
    try std.testing.expectEqual(other_completed.sequence, try previousForTest(&different, changed_button));
    try std.testing.expectEqual(@as(u8, 1), changed_button.press.window_count);
}

test "raw fourth count one can continue a distinct semantic third" {
    const Semantic = clicks.Classifier(u8);
    var state: Test = .{};
    var history: ?Semantic.History = null;
    var completed_sequence: u64 = 0;
    for ([_]u8{ 1, 2, 2, 2 }, [_]u8{ 1, 2, 3, 1 }, [_]u8{ 1, 1, 2, 3 }, 0..) |key, raw_count, semantic_count, i| {
        const timing = sample(@intCast(i * 10), 0, 0);
        const down = state.down(.primary, timing);
        const snapshot_value = try state.owner.snapshot(down, down.press, .down);
        try std.testing.expectEqual(completed_sequence, previousCompletedForTest(snapshot_value));
        if (previousCompletedForTest(snapshot_value) != completed_sequence) history = null;
        const proposal = Semantic.propose(history, key, snapshot_value.timing);
        try std.testing.expectEqual(raw_count, down.press.window_count);
        try std.testing.expectEqual(semantic_count, proposal.count);
        try std.testing.expect(state.owner.finishDown(down, .delivered));
        const up = state.up(.primary);
        try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, up));
        try std.testing.expect(state.owner.finishUp(up, .delivered));
        history = Semantic.complete(proposal, true, true, true);
        completed_sequence = down.press.sequence;
    }
}

test "unfinished and nonaccepted up expose no completed sequence to nested or next down" {
    var nested: Test = .{};
    const first = nested.down(.primary, sample(0, 0, 0));
    try std.testing.expect(nested.owner.finishDown(first, .delivered));
    const old_up = nested.up(.primary);
    const inner = nested.down(.primary, sample(10, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&nested, inner));
    try std.testing.expect(!nested.owner.finishUp(old_up, .delivered));
    for ([_]Disposition{ .consumed, .denied }) |disposition| {
        var state: Test = .{};
        _ = try state.complete(.primary, sample(0, 0, 0));
        const down = state.down(.primary, sample(10, 0, 0));
        try std.testing.expectEqual(@as(u64, 1), try previousForTest(&state, down));
        try std.testing.expect(state.owner.finishDown(down, .delivered));
        const up = state.up(.primary);
        try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, up));
        try std.testing.expect(state.owner.finishUp(up, disposition));
        const later = state.down(.primary, sample(20, 0, 0));
        try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, later));
    }
    var unfinished: Test = .{};
    const down = unfinished.down(.primary, sample(0, 0, 0));
    const up = unfinished.up(.primary);
    try std.testing.expect(!unfinished.owner.finishDown(down, .delivered));
    try std.testing.expect(unfinished.owner.finishUp(up, .delivered));
    const later = unfinished.down(.primary, sample(10, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&unfinished, later));
}

test "late older button up preserves the newer completed sequence" {
    var state: Test = .{};
    const older = state.down(.primary, sample(0, 0, 0));
    try std.testing.expect(state.owner.finishDown(older, .delivered));
    const newer = try state.complete(.secondary, sample(10, 0, 0));
    const old_up = state.up(.primary);
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, old_up));
    try std.testing.expect(state.owner.finishUp(old_up, .delivered));
    const next = state.down(.secondary, sample(20, 0, 0));
    try std.testing.expectEqual(newer.sequence, try previousForTest(&state, next));
    try std.testing.expectEqual(@as(u8, 2), next.press.window_count);
}

test "completed sequence belongs only to current matching down latest" {
    var state: Test = .{};
    const completed = try state.complete(.primary, sample(0, 0, 0));
    const down = state.down(.primary, sample(10, 0, 0));
    const looked = state.owner.lookup(down.operation, down.press.sequence, .primary, .down).?;
    try std.testing.expectEqual(completed.sequence, try previousForTest(&state, looked));
    const original = state.owner.latest;
    state.owner.latest.?.button = .secondary;
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, down));
    state.owner.latest = original;
    state.owner.latest.?.sequence += 1;
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, down));
    state.owner.latest = null;
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, down));
    state.owner.latest = original;
    try std.testing.expect(state.owner.revoke(state.operation.advance()));
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(down, down.press, .down));
    const later = state.down(.primary, sample(20, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try previousForTest(&state, later));
    state.owner.retire();
    try std.testing.expectError(error.StalePointerInput, state.owner.snapshot(later, later.press, .down));
}

test "completed sequence cannot escape sequence or operation retirement" {
    var sequence: Test = .{};
    sequence.owner.last_sequence = exhausted - 2;
    _ = try sequence.complete(.primary, sample(0, 0, 0));
    const no_receipt = sequence.down(.primary, sample(10, 0, 0));
    try std.testing.expectError(error.StalePointerInput, sequence.owner.snapshot(no_receipt, no_receipt.press, .down));
    try std.testing.expect(sequence.owner.latest == null and sequence.owner.history == null);
    var operation: Test = .{};
    const completed = try operation.complete(.primary, sample(0, 0, 0));
    const down = operation.down(.primary, sample(10, 0, 0));
    try std.testing.expectEqual(completed.sequence, try previousForTest(&operation, down));
    operation.operation.retire();
    try std.testing.expect(operation.owner.beginUp(operation.operation.value, .primary) == null);
    try std.testing.expectError(error.StalePointerInput, operation.owner.snapshot(down, down.press, .down));
    try std.testing.expect(operation.owner.latest == null and operation.owner.history == null);
}
