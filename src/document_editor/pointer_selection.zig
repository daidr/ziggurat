const std = @import("std");
const classifier = @import("pointer_classifier");

// Private semantic value state. Adapter authenticates every raw fact under its
// existing native-input/client pin. Nothing here issues native identity, reads
// a Window, shapes text, stores text, or owns a second Document selection.
pub const Window = struct { app: usize, index: usize, generation: u64 };
pub const Route = struct {
    text_version: u64,
    layout_generation: u64,
    scale: f32,
    bounds: [4]f64,
    scroll_x: f64,
    anchor_id: u64,
    anchor_intra: f64,
    space_owner: usize = 0,
    space_epoch: u64 = 0,
    space_id: u64 = 0,
    space_geometry: u64 = 0,
};
pub const Range = struct { start: usize, end: usize };
pub const Selection = struct { anchor: usize, caret: usize };
pub const Phase = enum { down, move, up };
pub const Guard = struct { installation: u64, serial: u64, operation: u64, sequence: u64, phase: Phase };
pub const Down = struct {
    window: Window,
    operation: u64,
    sequence: u64,
    previous_completed_sequence: u64,
    timing: ?classifier.Timing,
};
const Key = struct { window: Window, installation: u64, route: Route };
const C = classifier.Classifier(Key);
const History = struct { value: C.History, sequence: u64 };
pub const Held = struct {
    window: Window,
    sequence: u64,
    operation: u64,
    route: Route,
    proposal: C.Proposal,
    unit: Range,
    anchor: usize,
};
const Entry = struct {
    guard: Guard,
    down: ?Down = null,
    proposal: ?C.Proposal = null,
    route: ?Route = null,
    released: ?Held = null,
    accepted: bool = false,
};
const max = std.math.maxInt(u64);
pub const Error = error{ Busy, Closed, IdExhausted, StalePointerInput, AlreadyClaimed, InvalidRange };

pub const State = struct {
    window: ?Window = null,
    enabled: bool = false,
    retired: bool = false,
    installation: u64 = 0,
    serial: u64 = 0,
    floor: u64 = 0,
    claimed_window: ?Window = null,
    claimed_sequence: u64 = 0,
    entered: ?Entry = null,
    held: ?Held = null,
    history: ?History = null,

    pub fn install(self: *State, window: Window, floor: u64) Error!void {
        if (self.entered != null) return error.Busy;
        if (self.retired or floor == max or self.installation >= max - 1) return error.IdExhausted;
        self.installation += 1;
        self.floor = if (self.window != null and std.meta.eql(self.window.?, window)) @max(self.floor, floor) else floor;
        self.window = window;
        self.enabled = true;
        self.revoke();
    }
    // Logical clear retains the old-input fence until owner destruction. It
    // does not mint an identity and still works after semantic exhaustion.
    pub fn clear(self: *State, floor: u64) void {
        self.floor = @max(self.floor, floor);
        self.enabled = false;
        self.revoke();
    }
    pub fn revoke(self: *State) void {
        self.entered = null;
        self.held = null;
        self.history = null;
    }
    pub fn ordinaryAllowed(self: *const State, window: Window, sequence: u64) bool {
        if (self.enabled) return false;
        if (sequence == 0) return true;
        return self.window == null or !std.meta.eql(self.window.?, window) or sequence > self.floor;
    }
    pub fn beginDown(self: *State, input: Down) Error!Guard {
        if (!self.enabled or self.retired) return error.Closed;
        if (!std.meta.eql(self.window, @as(?Window, input.window)) or input.sequence == 0 or input.sequence == max or input.sequence <= self.floor) return error.StalePointerInput;
        if (self.claimed_window) |old| if (std.meta.eql(old, input.window) and input.sequence <= self.claimed_sequence) return error.AlreadyClaimed;
        const guard = try self.enter(input.operation, input.sequence, .down);
        // Claim before any caller allocation/composition/selection operation.
        self.claimed_window = input.window;
        self.claimed_sequence = input.sequence;
        self.held = null;
        self.entered.?.down = input;
        return guard;
    }
    pub fn propose(self: *State, guard: Guard, route: Route, continue_history: bool) Error!u8 {
        const entry = try self.current(guard);
        if (guard.phase != .down or entry.proposal != null) return error.StalePointerInput;
        const input = entry.down.?;
        const prior = if (self.history) |old| (if (continue_history and old.sequence == input.previous_completed_sequence) old.value else null) else null;
        const proposal = C.propose(prior, .{ .window = input.window, .installation = self.installation, .route = route }, if (continue_history) input.timing else null);
        self.history = null;
        entry.proposal = proposal;
        entry.route = route;
        return proposal.count;
    }
    pub fn acceptDown(self: *State, guard: Guard, unit: Range, anchor: usize) Error!void {
        if (unit.start > unit.end) return error.InvalidRange;
        const entry = try self.current(guard);
        if (guard.phase != .down or entry.proposal == null) return error.StalePointerInput;
        self.held = .{ .window = self.window.?, .sequence = guard.sequence, .operation = guard.operation, .route = entry.route.?, .proposal = entry.proposal.?, .unit = unit, .anchor = anchor };
        entry.accepted = true;
    }
    pub fn beginMove(self: *State, window: Window, operation: u64) Error!Guard {
        const held = self.held orelse return error.StalePointerInput;
        if (!std.meta.eql(window, held.window) or held.operation != operation) return error.StalePointerInput;
        return self.enter(operation, held.sequence, .move);
    }
    pub fn beginUp(self: *State, window: Window, operation: u64, sequence: u64) Error!Guard {
        const held = self.held orelse return error.StalePointerInput;
        if (!std.meta.eql(window, held.window) or sequence != held.sequence or sequence <= self.floor) return error.StalePointerInput;
        const guard = try self.enter(operation, sequence, .up);
        // Old/duplicate up cannot retry after fallible layout or foreign work.
        self.held = null;
        self.entered.?.released = held;
        return guard;
    }
    pub fn heldFor(self: *State, guard: Guard) Error!Held {
        const entry = try self.current(guard);
        return if (guard.phase == .up) entry.released orelse error.StalePointerInput else self.held orelse error.StalePointerInput;
    }
    pub fn acceptDrag(self: *State, guard: Guard) Error!void {
        const entry = try self.current(guard);
        if (guard.phase == .down) return error.StalePointerInput;
        entry.accepted = true;
    }
    pub fn valid(self: *const State, guard: Guard) bool {
        const entry = self.entered orelse return false;
        return self.enabled and !self.retired and std.meta.eql(entry.guard, guard) and self.installation == guard.installation;
    }
    // Adapter supplies the final fresh native eligibility/currentness after
    // all foreign frees. An up is only tentative; the next down's predecessor
    // must prove that the raw up tail actually completed.
    pub fn finish(self: *State, guard: Guard, current_native: bool, eligible: bool) void {
        if (!self.valid(guard)) return;
        const entry = self.entered.?;
        self.entered = null;
        if (!current_native or !entry.accepted) {
            self.held = null;
            self.history = null;
            return;
        }
        if (guard.phase == .up) {
            const held = entry.released.?;
            self.history = if (C.complete(held.proposal, true, eligible, true)) |history| .{ .value = history, .sequence = held.sequence } else null;
        }
    }
    fn enter(self: *State, operation: u64, sequence: u64, phase: Phase) Error!Guard {
        if (!self.enabled or self.retired) return error.Closed;
        if (self.entered != null) return error.Busy;
        if (operation == 0 or operation == max) return error.StalePointerInput;
        if (self.serial >= max - 1) {
            self.retired = true;
            self.revoke();
            return error.IdExhausted;
        }
        self.serial += 1;
        const guard: Guard = .{ .installation = self.installation, .serial = self.serial, .operation = operation, .sequence = sequence, .phase = phase };
        self.entered = .{ .guard = guard };
        return guard;
    }
    fn current(self: *State, guard: Guard) Error!*Entry {
        if (!self.valid(guard)) return error.StalePointerInput;
        return &self.entered.?;
    }
};

// Logical unit union, independent of visual/bidi order. The Document remains
// the only selection owner; these are just the original gesture's endpoints.
pub fn drag(held: Held, target: Range) Selection {
    if (held.proposal.count == 1) return .{ .anchor = held.anchor, .caret = target.start };
    if (target.start < held.unit.start) return .{ .anchor = held.unit.end, .caret = target.start };
    return .{ .anchor = held.unit.start, .caret = @max(held.unit.end, target.end) };
}

const test_window: Window = .{ .app = 1, .index = 2, .generation = 3 };
const test_route: Route = .{ .text_version = 1, .layout_generation = 1, .scale = 1, .bounds = .{ 8, 8, 160, 80 }, .scroll_x = 0, .anchor_id = 1, .anchor_intra = 0 };
fn testDown(sequence: u64, previous: u64) Down {
    return .{ .window = test_window, .operation = sequence * 2, .sequence = sequence, .previous_completed_sequence = previous, .timing = .{ .tick_ms = @intCast(sequence * 20), .position = .{ .x = 20, .y = 20, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -4, .max_x = 4, .min_y = -4, .max_y = 4 } } };
}
fn testPair(state: *State, sequence: u64, previous: u64) !u8 {
    const down = try state.beginDown(testDown(sequence, previous));
    const count = try state.propose(down, test_route, true);
    try state.acceptDown(down, .{ .start = 2, .end = 4 }, 2);
    state.finish(down, true, true);
    const up = try state.beginUp(test_window, sequence * 2 + 1, sequence);
    try state.acceptDrag(up);
    state.finish(up, true, true);
    return count;
}
test "semantic 1 2 3 1 ignores the raw window count and requires final predecessor" {
    var state: State = .{};
    try state.install(test_window, 0);
    for (1..5, [_]u8{ 1, 2, 3, 1 }) |sequence, expected| try std.testing.expectEqual(expected, try testPair(&state, sequence, sequence - 1));
    try std.testing.expectEqual(@as(u8, 1), try testPair(&state, 6, 0));
    try std.testing.expectEqual(@as(u8, 1), try testPair(&state, 8, 7));
}
test "install and clear reject already issued down and the old held up" {
    var state: State = .{};
    try state.install(test_window, 5);
    try std.testing.expectError(error.StalePointerInput, state.beginDown(testDown(5, 4)));
    const down = try state.beginDown(testDown(6, 5));
    _ = try state.propose(down, test_route, true);
    try state.acceptDown(down, .{ .start = 2, .end = 4 }, 2);
    state.finish(down, true, true);
    state.clear(6);
    try std.testing.expect(!state.ordinaryAllowed(test_window, 6));
    try std.testing.expect(state.ordinaryAllowed(test_window, 7));
    try std.testing.expect(state.ordinaryAllowed(test_window, 0));
    try std.testing.expectError(error.StalePointerInput, state.beginUp(test_window, 13, 6));
    try state.install(test_window, 7);
    try std.testing.expectError(error.StalePointerInput, state.beginDown(testDown(7, 6)));
}
test "failed down is claimed once and failed or ineligible up cannot seed history" {
    var state: State = .{};
    try state.install(test_window, 0);
    const down = try state.beginDown(testDown(1, 0));
    _ = try state.propose(down, test_route, true);
    state.finish(down, true, true);
    try std.testing.expectError(error.AlreadyClaimed, state.beginDown(testDown(1, 0)));
    try std.testing.expectEqual(@as(u8, 1), try testPair(&state, 2, 1));
    const next = try state.beginDown(testDown(3, 2));
    try std.testing.expectEqual(@as(u8, 2), try state.propose(next, test_route, true));
    try state.acceptDown(next, .{ .start = 2, .end = 4 }, 2);
    state.finish(next, true, true);
    const up = try state.beginUp(test_window, 7, 3);
    try state.acceptDrag(up);
    state.finish(up, true, false);
    try std.testing.expectEqual(@as(u8, 1), try testPair(&state, 4, 3));
}
test "shift and null timing are single gestures without history" {
    var state: State = .{};
    try state.install(test_window, 0);
    _ = try testPair(&state, 1, 0);
    const shift = try state.beginDown(testDown(2, 1));
    try std.testing.expectEqual(@as(u8, 1), try state.propose(shift, test_route, false));
    try state.acceptDown(shift, .{ .start = 4, .end = 4 }, 1);
    state.finish(shift, true, true);
    const up = try state.beginUp(test_window, 5, 2);
    try state.acceptDrag(up);
    state.finish(up, true, true);
    var input = testDown(3, 2);
    input.timing = null;
    const unqualified = try state.beginDown(input);
    try std.testing.expectEqual(@as(u8, 1), try state.propose(unqualified, test_route, true));
    state.finish(unqualified, false, false);
    try std.testing.expect(state.history == null);
}
test "unit drag reverses around the whole original word or logical row" {
    var state: State = .{};
    try state.install(test_window, 0);
    _ = try testPair(&state, 1, 0);
    const down = try state.beginDown(testDown(2, 1));
    _ = try state.propose(down, test_route, true);
    try state.acceptDown(down, .{ .start = 4, .end = 8 }, 4);
    const held = state.held.?;
    try std.testing.expectEqualDeep(Selection{ .anchor = 8, .caret = 1 }, drag(held, .{ .start = 1, .end = 3 }));
    try std.testing.expectEqualDeep(Selection{ .anchor = 4, .caret = 11 }, drag(held, .{ .start = 9, .end = 11 }));
    try std.testing.expectEqualDeep(Selection{ .anchor = 4, .caret = 8 }, drag(held, .{ .start = 4, .end = 8 }));
    state.finish(down, true, true);
    const motion = try state.beginMove(test_window, down.operation);
    state.clear(2);
    try std.testing.expect(!state.valid(motion));
}
test "semantic counters never wrap and clear remains ordinary after retirement" {
    var state: State = .{};
    try state.install(test_window, 0);
    state.serial = max - 1;
    try std.testing.expectError(error.IdExhausted, state.beginDown(testDown(1, 0)));
    try std.testing.expect(state.enabled and state.retired);
    state.clear(1);
    try std.testing.expect(state.ordinaryAllowed(test_window, 2));
    try std.testing.expectError(error.IdExhausted, state.install(test_window, 1));
    var fresh: State = .{};
    try std.testing.expectError(error.IdExhausted, fresh.install(test_window, max));
    try std.testing.expectEqual(@as(u64, 0), fresh.installation);
}
test "semantic exhaustion denies until explicit clear rather than becoming ordinary" {
    var state: State = .{};
    try state.install(test_window, 0);
    state.serial = max - 1;
    try std.testing.expectError(error.IdExhausted, state.beginDown(testDown(1, 0)));
    try std.testing.expect(!state.ordinaryAllowed(test_window, 2));
    state.clear(1);
    try std.testing.expect(state.ordinaryAllowed(test_window, 2));
}
test "same-window reinstall never lowers an already established admission floor" {
    var state: State = .{};
    try state.install(test_window, 5);
    try state.install(test_window, 0);
    try std.testing.expectError(error.StalePointerInput, state.beginDown(testDown(4, 0)));
}
