const std = @import("std");
const classifier = @import("pointer_classifier");

// Private value kernel. The UI attachment owns allocation, callback pins,
// native Snapshot validation and the one event-local entry that may call it.
// No Window/Context pointer is dereferenced here and no geometry is duplicated.
// State stays at a stable address through every borrowed Target/Guard use.
pub const capacity = 128;
pub const Timing = classifier.Timing;
pub const Point = struct { x: f64, y: f64 };
pub const Window = struct { app: usize, index: usize, generation: u64 };
pub const Attachment = struct { owner: usize = 0, index: u64 = 0, generation: u64 = 0 };
pub const Phase = enum { down, up };
const exhausted = std.math.maxInt(u64);
pub const Error = error{ Closed, IdExhausted, Busy, NoFrame, CapacityExceeded, InvalidCheckpoint, InvalidBinding, DuplicateTarget, StaleTarget, StaleIngress, AlreadyClaimed, UnsupportedButton };

pub const Target = struct { owner: *const State, installation: u64, registration: u64, serial: u64, id: u64 };
pub const Guard = struct { owner: *const State, installation: u64, registration: u64, routing: u64, serial: u64, phase: Phase };
pub const Down = struct {
    sequence: u64,
    previous_completed_sequence: u64,
    timing: ?Timing,
    point: Point,
    button: u8 = 0,
};
pub const Up = struct { sequence: u64, point: Point, button: u8 = 0 };
pub const Continuity = struct { history: bool = false, held: bool = false };
pub const Result = struct { accepted: bool, authorized: bool, eligible: bool };
pub const Click = struct { target: Target, count: u8, sequence: u64, button: u8, point: Point };

const Key = struct { window: Window, attachment: Attachment, installation: u64, registration: u64, target: u64, button: u8 };
const C = classifier.Classifier(Key);
const Bank = struct {
    serials: [capacity]u64 = undefined,
    len: usize = 0,
    installation: u64 = 0,
    registration: u64 = 0,
};
const History = struct { value: C.History, sequence: u64, point: Point, front: u64 };
const Held = struct { target: Target, proposal: C.Proposal, sequence: u64, point: Point, button: u8, routing: u64, front: u64 };
const Entered = struct {
    guard: Guard,
    sequence: u64,
    previous_completed_sequence: u64 = 0,
    timing: ?Timing = null,
    point: Point,
    button: u8,
    front: u64,
    claimed: bool = false,
    invoked: bool = false,
    completed: bool = false,
};
pub const Completion = struct { guard: Guard, held: Held, click: Click };

pub const State = struct {
    window: ?Window = null,
    attachment: Attachment = .{},
    installation: u64 = 0,
    registration: u64 = 0,
    routing: u64 = 0,
    next_target: u64 = 0,
    next_ingress: u64 = 0,
    next_frame: u64 = 0,
    front_serial: u64 = 0,
    candidate_serial: u64 = 0,
    closed: bool = true,
    retired: bool = false,
    building: bool = false,
    banks: [2]Bank = .{ .{}, .{} },
    front: u1 = 0,
    entered: ?Entered = null,
    held: ?Held = null,
    history: ?History = null,
    // This fence is intentionally independent of registration/installation.
    claimed_window: ?Window = null,
    claimed_sequence: u64 = 0,

    // A fresh allocation must use the stable Context's preserved issuer epoch,
    // including detach/re-attach. Reusing an address with epoch0 is not reset.
    pub fn init(previous_installation: u64) State {
        return .{ .installation = previous_installation };
    }
    pub fn install(self: *State, window: Window, attachment: Attachment) Error!void {
        if (self.building) return error.Busy;
        try self.advance(&self.installation);
        try self.advance(&self.registration);
        self.window = window;
        self.attachment = attachment;
        self.closed = false;
        self.dropAuthority();
    }
    pub fn replaceRegistration(self: *State) Error!void {
        if (self.closed or self.retired) return error.Closed;
        if (self.building) return error.Busy;
        try self.advance(&self.registration);
        self.dropAuthority();
    }
    pub fn close(self: *State) void {
        self.closed = true;
        self.dropAuthority();
        self.cancelFrame();
    }
    pub fn changeRoute(self: *State) Error!void {
        try self.advance(&self.routing);
        self.dropAuthority();
    }
    pub fn mint(self: *State, id: u64) Error!Target {
        if (self.closed or self.retired) return error.Closed;
        if (id == 0) return error.InvalidBinding;
        try self.advance(&self.next_target);
        return .{ .owner = self, .installation = self.installation, .registration = self.registration, .serial = self.next_target, .id = id };
    }
    pub fn beginFrame(self: *State) Error!void {
        if (self.building) return error.Busy;
        if (!self.retired) self.advance(&self.next_frame) catch |err| {
            if (err != error.IdExhausted) return err;
        };
        // Retirement revokes semantic authority, not ordinary visual work.
        // Zero is never an ingress/front authority and consumes no new issuer.
        self.candidate_serial = if (self.retired) 0 else self.next_frame;
        self.banks[self.front ^ 1] = .{ .installation = self.installation, .registration = self.registration };
        self.building = true;
    }
    pub fn append(self: *State) Error!usize {
        if (!self.building) return error.NoFrame;
        const bank = &self.banks[self.front ^ 1];
        if (bank.len == capacity) return error.CapacityExceeded;
        const index = bank.len;
        bank.serials[index] = 0;
        bank.len += 1;
        return index;
    }
    pub fn bind(self: *State, index: usize, id: u64, target: Target) Error!void {
        if (!self.building) return error.NoFrame;
        if (!self.targetCurrent(target) or target.id != id) return error.StaleTarget;
        const bank = &self.banks[self.front ^ 1];
        if (index >= bank.len or bank.serials[index] != 0) return error.InvalidBinding;
        for (bank.serials[0..bank.len]) |serial| if (serial == target.serial) return error.DuplicateTarget;
        bank.serials[index] = target.serial;
    }
    pub fn rollback(self: *State, len: usize) Error!void {
        if (!self.building) return error.NoFrame;
        const bank = &self.banks[self.front ^ 1];
        if (len > bank.len) return error.InvalidCheckpoint;
        bank.len = len;
    }
    pub fn cancelFrame(self: *State) void {
        if (!self.building) return;
        self.banks[self.front ^ 1].len = 0;
        self.building = false;
        self.candidate_serial = 0;
    }
    pub fn validateFrame(self: *const State, hit_len: usize) Error!void {
        if (!self.building) return error.NoFrame;
        const bank = &self.banks[self.front ^ 1];
        if (bank.len != hit_len or bank.len > capacity) return error.InvalidBinding;
        for (bank.serials[0..bank.len], 0..) |serial, i| {
            if (serial == 0) continue;
            if (self.closed or self.retired or bank.installation != self.installation or bank.registration != self.registration) return error.StaleTarget;
            for (bank.serials[0..i]) |prior| if (prior == serial) return error.DuplicateTarget;
        }
    }
    // The caller computes these two decisions using the exact old/new Input
    // views before overwriting either. They are not a second hit resolver.
    pub fn commitFrame(self: *State, hit_len: usize, continuity: Continuity) Error!void {
        try self.validateFrame(hit_len);
        if (!continuity.history) self.history = null;
        if (!continuity.held) self.held = null;
        self.front ^= 1;
        // An issuer may retire after beginFrame. validateFrame has rejected
        // every nonzero mark before this non-authorizing ordinary publication.
        self.front_serial = if (self.retired) 0 else self.candidate_serial;
        if (self.history) |*history| history.front = self.front_serial;
        if (self.held) |*held| {
            held.front = self.front_serial;
            if (self.entered) |*entered| if (entered.guard.phase == .up) {
                entered.front = self.front_serial;
            };
        }
        self.building = false;
        self.candidate_serial = 0;
    }
    // A nonzero stale mark remains visible even after close/re-registration.
    // Callers must deny it; a missing authorized Target is not legacy fallback.
    pub fn mark(self: *const State, index: usize) Error!u64 {
        const bank = &self.banks[self.front];
        if (index >= bank.len) return error.InvalidBinding;
        return bank.serials[index];
    }
    pub fn bound(self: *const State, index: usize, id: u64) ?Target {
        const bank = &self.banks[self.front];
        if (self.closed or self.retired or index >= bank.len or bank.installation != self.installation or bank.registration != self.registration or bank.serials[index] == 0) return null;
        return .{ .owner = self, .installation = self.installation, .registration = self.registration, .serial = bank.serials[index], .id = id };
    }
    pub fn beginDown(self: *State, down: Down) Error!Guard {
        const guard = try self.enter(.down, down.sequence, down.button, down.point);
        self.held = null;
        const entered = &self.entered.?;
        entered.previous_completed_sequence = down.previous_completed_sequence;
        entered.timing = down.timing;
        return guard;
    }
    pub fn beginUp(self: *State, up: Up) Error!Guard {
        const guard = try self.enter(.up, up.sequence, up.button, up.point);
        if (self.held) |held| if (held.sequence != up.sequence or held.button != up.button) {
            self.held = null;
        };
        return guard;
    }
    // Only the UI's captured, pinned event entry may call this private seam.
    // A native Snapshot by itself cannot create that UI entry.
    pub fn claim(self: *State, guard: Guard, target: Target) Error!u8 {
        const entered = self.current(guard) orelse return error.StaleIngress;
        if (guard.phase != .down or entered.front != self.front_serial or !self.targetCurrent(target) or !self.targetDisplayed(target)) return error.StaleTarget;
        if (entered.button != 0) return error.UnsupportedButton;
        if (entered.sequence == 0 or entered.sequence == exhausted) return error.StaleIngress;
        if (entered.claimed) return error.AlreadyClaimed;
        if (self.claimed_window) |window| if (std.meta.eql(window, self.window.?) and entered.sequence <= self.claimed_sequence) return error.AlreadyClaimed;
        const semantic_key = self.key(target, entered.button);
        const previous = if (self.history) |history| (if (history.sequence == entered.previous_completed_sequence) history.value else null) else null;
        const proposal = C.propose(previous, semantic_key, entered.timing);
        // Reserve before a callback or another successful probe can run.
        self.claimed_window = self.window;
        self.claimed_sequence = entered.sequence;
        entered.claimed = true;
        self.held = .{ .target = target, .proposal = proposal, .sequence = entered.sequence, .point = entered.point, .button = entered.button, .routing = self.routing, .front = self.front_serial };
        return proposal.count;
    }
    pub fn takeUp(self: *State, guard: Guard, target: Target) Error!Completion {
        const entered = self.current(guard) orelse return error.StaleIngress;
        if (guard.phase != .up or entered.invoked) return error.StaleIngress;
        const held = self.held orelse return error.StaleIngress;
        if (held.sequence != entered.sequence or held.button != entered.button or held.routing != self.routing or held.front != self.front_serial or !std.meta.eql(held.target, target) or !self.targetCurrent(target) or !self.targetDisplayed(target)) return error.StaleTarget;
        entered.invoked = true;
        self.held = null;
        return .{ .guard = guard, .held = held, .click = .{ .target = target, .count = held.proposal.count, .sequence = held.sequence, .button = held.button, .point = entered.point } };
    }
    pub fn complete(self: *State, completion: Completion, result: Result) bool {
        const entered = self.current(completion.guard) orelse return false;
        if (completion.guard.phase != .up or !entered.invoked or entered.completed or entered.front != self.front_serial) return false;
        entered.completed = true;
        self.history = if (C.complete(completion.held.proposal, true, result.eligible, result.accepted and result.authorized)) |value| .{ .value = value, .sequence = completion.held.sequence, .point = completion.click.point, .front = self.front_serial } else null;
        return true;
    }
    // One defer calls this on every event return. Superseded guards cannot
    // erase a nested entry's held proposal or accepted tentative history.
    pub fn finish(self: *State, guard: Guard) void {
        const entered = self.current(guard) orelse return;
        if ((guard.phase == .down and !entered.claimed) or (guard.phase == .up and !entered.completed)) {
            self.held = null;
            self.history = null;
        }
        self.entered = null;
    }
    pub fn cancel(self: *State, validated_expected_up: ?u64) void {
        if (validated_expected_up) |sequence| if (self.history) |history| {
            if (history.sequence == sequence) return;
        };
        self.dropAuthority();
    }
    pub fn savedHistoryPoint(self: *const State) ?Point {
        return if (self.history) |history| history.point else null;
    }
    pub fn savedHeldPoint(self: *const State) ?Point {
        return if (self.held) |held| held.point else null;
    }
    fn enter(self: *State, phase: Phase, sequence: u64, button: u8, point: Point) Error!Guard {
        if (self.closed or self.retired or self.window == null) return error.Closed;
        try self.advance(&self.next_ingress);
        const guard: Guard = .{ .owner = self, .installation = self.installation, .registration = self.registration, .routing = self.routing, .serial = self.next_ingress, .phase = phase };
        self.entered = .{ .guard = guard, .sequence = sequence, .button = button, .point = point, .front = self.front_serial };
        return guard;
    }
    fn current(self: *State, guard: Guard) ?*Entered {
        if (guard.owner != self or self.closed or self.retired or guard.installation != self.installation or guard.registration != self.registration or guard.routing != self.routing) return null;
        const entered = if (self.entered) |*value| value else return null;
        return if (std.meta.eql(entered.guard, guard)) entered else null;
    }
    fn key(self: *const State, target: Target, button: u8) Key {
        return .{ .window = self.window.?, .attachment = self.attachment, .installation = self.installation, .registration = self.registration, .target = target.serial, .button = button };
    }
    fn targetCurrent(self: *const State, target: Target) bool {
        return !self.closed and !self.retired and target.owner == self and target.installation == self.installation and target.registration == self.registration and target.serial != 0 and target.serial <= self.next_target;
    }
    fn targetDisplayed(self: *const State, target: Target) bool {
        const bank = &self.banks[self.front];
        if (bank.installation != self.installation or bank.registration != self.registration) return false;
        for (bank.serials[0..bank.len]) |serial| if (serial == target.serial) return true;
        return false;
    }
    fn dropAuthority(self: *State) void {
        self.entered = null;
        self.held = null;
        self.history = null;
    }
    fn advance(self: *State, counter: *u64) Error!void {
        if (self.retired or counter.* >= exhausted - 1) {
            counter.* = exhausted;
            self.retired = true;
            self.closed = true;
            self.dropAuthority();
            return error.IdExhausted;
        }
        counter.* += 1;
    }
};

const test_window: Window = .{ .app = 1, .index = 2, .generation = 3 };
fn sample(tick: u32) Timing {
    return .{ .tick_ms = tick, .position = .{ .x = 5, .y = 5, .domain = 7 }, .policy = .{ .interval_ms = 500, .min_x = -3, .max_x = 3, .min_y = -3, .max_y = 3 } };
}
fn display(state: *State, targets: []const Target, continuity: Continuity) !void {
    try state.beginFrame();
    for (targets) |target| try state.bind(try state.append(), target.id, target);
    try state.commitFrame(targets.len, continuity);
}
fn pair(state: *State, target: Target, sequence: u64, previous: u64, tick: u32) !u8 {
    const down = try state.beginDown(.{ .sequence = sequence, .previous_completed_sequence = previous, .timing = sample(tick), .point = .{ .x = 5, .y = 5 } });
    const proposed = try state.claim(down, target);
    state.finish(down);
    const up = try state.beginUp(.{ .sequence = sequence, .point = .{ .x = 5, .y = 5 } });
    const completion = try state.takeUp(up, target);
    try std.testing.expectEqual(proposed, completion.click.count);
    try std.testing.expect(state.complete(completion, .{ .accepted = true, .authorized = true, .eligible = true }));
    state.finish(up);
    return proposed;
}

test "semantic next down requires the raw predecessor completion fact" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, target, 1, 0, 10));
    // An unknown native button was not delivered to UI and issued no receipt.
    // Native cleared its history, so the next valid down explicitly reports0.
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, target, 2, 0, 20));
}

test "semantic counts belong to target rather than raw fourth-click count" {
    var state: State = .{};
    try state.install(test_window, .{});
    const a = try state.mint(10);
    const b = try state.mint(20);
    try display(&state, &.{ a, b }, .{});
    for ([_]Target{ a, b, b, b }, [_]u8{ 1, 1, 2, 3 }, 1..) |target, expected, sequence| {
        try std.testing.expectEqual(expected, try pair(&state, target, sequence, sequence - 1, @intCast(sequence * 10)));
    }
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, b, 5, 4, 50));
    try std.testing.expectEqual(@as(u8, 2), try pair(&state, b, 6, 5, 60));
}

test "semantic whole unclaimed ingress resets but an observational miss does not" {
    var state: State = .{};
    var foreign: State = .{};
    try state.install(test_window, .{});
    try foreign.install(test_window, .{});
    const target = try state.mint(10);
    const wrong = try foreign.mint(10);
    try display(&state, &.{target}, .{});
    _ = try pair(&state, target, 1, 0, 10);
    const probe = try state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 1, .timing = sample(20), .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectError(error.StaleTarget, state.claim(probe, wrong));
    try std.testing.expectEqual(@as(u8, 2), try state.claim(probe, target));
    state.finish(probe);
    const up = try state.beginUp(.{ .sequence = 2, .point = .{ .x = 5, .y = 5 } });
    const completion = try state.takeUp(up, target);
    try std.testing.expect(state.complete(completion, .{ .accepted = true, .authorized = true, .eligible = true }));
    state.finish(up);
    // This represents preprocessing consumption, no hit, disabled, or an
    // ordinary unregistered control: the event has no registered claim.
    const unclaimed = try state.beginDown(.{ .sequence = 3, .previous_completed_sequence = 2, .timing = sample(30), .point = .{ .x = 9, .y = 5 } });
    state.finish(unclaimed);
    try std.testing.expect(state.savedHistoryPoint() == null and state.savedHeldPoint() == null);
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, target, 4, 3, 40));
}

test "semantic stale finalizers cannot retire a nested held or accepted press" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    const old = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    _ = try state.claim(old, target);
    const newer = try state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 0, .timing = sample(20), .point = .{ .x = 7, .y = 5 } });
    try std.testing.expectEqual(@as(u8, 1), try state.claim(newer, target));
    state.finish(old);
    try std.testing.expectEqualDeep(Point{ .x = 7, .y = 5 }, state.savedHeldPoint().?);
    state.finish(newer);
    const up = try state.beginUp(.{ .sequence = 2, .point = .{ .x = 7, .y = 5 } });
    const completed = try state.takeUp(up, target);
    try std.testing.expectError(error.StaleIngress, state.takeUp(up, target));
    try std.testing.expect(state.complete(completed, .{ .accepted = true, .authorized = true, .eligible = true }));
    try std.testing.expect(!state.complete(completed, .{ .accepted = false, .authorized = true, .eligible = true }));
    state.finish(old);
    state.finish(up);
    state.finish(newer);
    try std.testing.expectEqualDeep(Point{ .x = 7, .y = 5 }, state.savedHistoryPoint().?);
    try std.testing.expectEqual(@as(u8, 2), try pair(&state, target, 3, 2, 30));
}

test "semantic same raw sequence cannot be claimed after close and reinstall" {
    var state: State = .{};
    try state.install(test_window, .{});
    const old_target = try state.mint(10);
    try display(&state, &.{old_target}, .{});
    const old = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    _ = try state.claim(old, old_target);
    try std.testing.expectError(error.AlreadyClaimed, state.claim(old, old_target));
    state.close();
    try std.testing.expectEqual(old_target.serial, try state.mark(0));
    try std.testing.expect(state.bound(0, old_target.id) == null);
    try state.install(test_window, .{});
    const current_target = try state.mint(10);
    try display(&state, &.{current_target}, .{});
    const newer = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectError(error.StaleIngress, state.claim(old, current_target));
    try std.testing.expectError(error.AlreadyClaimed, state.claim(newer, current_target));
    state.finish(old);
    state.finish(newer);
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, current_target, 2, 1, 20));
    try state.replaceRegistration();
    try std.testing.expectEqual(current_target.serial, try state.mark(0));
    try std.testing.expect(state.bound(0, current_target.id) == null);
}

test "semantic null timing and sticky ineligibility preserve one current action" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    const down = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = null, .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectEqual(@as(u8, 1), try state.claim(down, target));
    state.finish(down);
    const up = try state.beginUp(.{ .sequence = 1, .point = .{ .x = 5, .y = 5 } });
    const completion = try state.takeUp(up, target);
    try std.testing.expectEqual(@as(u8, 1), completion.click.count);
    try std.testing.expect(state.complete(completion, .{ .accepted = true, .authorized = true, .eligible = false }));
    state.finish(up);
    try std.testing.expect(state.savedHistoryPoint() == null);
    _ = try pair(&state, target, 2, 0, 20);
    const next = try state.beginDown(.{ .sequence = 3, .previous_completed_sequence = 2, .timing = sample(30), .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectEqual(@as(u8, 2), try state.claim(next, target));
    state.finish(next);
    const next_up = try state.beginUp(.{ .sequence = 3, .point = .{ .x = 5, .y = 5 } });
    const disqualified = try state.takeUp(next_up, target);
    try std.testing.expectEqual(@as(u8, 2), disqualified.click.count);
    try std.testing.expect(state.complete(disqualified, .{ .accepted = true, .authorized = true, .eligible = false }));
    state.finish(next_up);
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, target, 4, 0, 40));
}

test "semantic candidate rollback failure and closed marks stay transactional" {
    var state: State = .{};
    try state.install(test_window, .{});
    const a = try state.mint(10);
    const b = try state.mint(20);
    try display(&state, &.{a}, .{});
    const old_front = state.front_serial;
    try std.testing.expectError(error.NoFrame, state.append());
    try std.testing.expectError(error.NoFrame, state.rollback(0));
    try state.beginFrame();
    try state.bind(try state.append(), a.id, a);
    const rolled_back = try state.append();
    try state.bind(rolled_back, b.id, b);
    try state.rollback(1);
    try std.testing.expectEqual(rolled_back, try state.append());
    try std.testing.expectEqual(@as(u64, 0), state.banks[state.front ^ 1].serials[rolled_back]);
    try std.testing.expectError(error.DuplicateTarget, state.bind(rolled_back, a.id, a));
    try std.testing.expectError(error.InvalidBinding, state.commitFrame(1, .{}));
    try std.testing.expectEqual(old_front, state.front_serial);
    try std.testing.expectEqual(a.serial, try state.mark(0));
    state.cancelFrame();
    try std.testing.expectEqual(a.serial, try state.mark(0));
    state.close();
    try std.testing.expectEqual(a.serial, try state.mark(0));
    try state.beginFrame();
    _ = try state.append();
    try state.commitFrame(1, .{});
    try std.testing.expectEqual(@as(u64, 0), try state.mark(0));
    try state.beginFrame();
    for (0..capacity) |_| _ = try state.append();
    try std.testing.expectError(error.CapacityExceeded, state.append());
    try state.commitFrame(capacity, .{});
}

test "semantic held down and previous accepted points validate independently" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    // First-ever held down has no previously accepted history point.
    const first = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 7, .y = 5 } });
    _ = try state.claim(first, target);
    state.finish(first);
    try std.testing.expect(state.savedHistoryPoint() == null);
    try std.testing.expectEqualDeep(Point{ .x = 7, .y = 5 }, state.savedHeldPoint().?);
    try display(&state, &.{target}, .{ .held = false });
    const denied = try state.beginUp(.{ .sequence = 1, .point = .{ .x = 7, .y = 5 } });
    try std.testing.expectError(error.StaleIngress, state.takeUp(denied, target));
    state.finish(denied);
    _ = try pair(&state, target, 2, 1, 20);
    const down = try state.beginDown(.{ .sequence = 3, .previous_completed_sequence = 2, .timing = sample(30), .point = .{ .x = 7, .y = 5 } });
    _ = try state.claim(down, target);
    state.finish(down);
    try std.testing.expectEqualDeep(Point{ .x = 5, .y = 5 }, state.savedHistoryPoint().?);
    try std.testing.expectEqualDeep(Point{ .x = 7, .y = 5 }, state.savedHeldPoint().?);
    try display(&state, &.{target}, .{ .history = true, .held = true });
    const up = try state.beginUp(.{ .sequence = 3, .point = .{ .x = 7, .y = 5 } });
    const completion = try state.takeUp(up, target);
    try std.testing.expect(state.complete(completion, .{ .accepted = true, .authorized = true, .eligible = true }));
    state.finish(up);
    state.cancel(3); // caller independently proved this exact active own up.
    try std.testing.expect(state.savedHistoryPoint() != null);
    state.cancel(null);
    try std.testing.expect(state.savedHistoryPoint() == null);
}

test "semantic stale callback completion and wrong phases never replay an action" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    const down = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    _ = try state.claim(down, target);
    state.finish(down);
    const up = try state.beginUp(.{ .sequence = 1, .point = .{ .x = 5, .y = 5 } });
    const old = try state.takeUp(up, target);
    try state.replaceRegistration();
    const newer = try state.mint(10);
    try display(&state, &.{newer}, .{});
    _ = try pair(&state, newer, 2, 1, 20);
    try std.testing.expect(!state.complete(old, .{ .accepted = true, .authorized = true, .eligible = true }));
    state.finish(up);
    try std.testing.expectEqual(@as(u8, 2), try pair(&state, newer, 3, 2, 30));
    for ([_]u64{ 0, exhausted }) |sequence| {
        const invalid = try state.beginDown(.{ .sequence = sequence, .previous_completed_sequence = 3, .timing = sample(40), .point = .{ .x = 5, .y = 5 } });
        try std.testing.expectError(error.StaleIngress, state.claim(invalid, newer));
        state.finish(invalid);
    }
    const other = try state.beginDown(.{ .sequence = 4, .previous_completed_sequence = 3, .timing = sample(40), .point = .{ .x = 5, .y = 5 }, .button = 1 });
    try std.testing.expectError(error.UnsupportedButton, state.claim(other, newer));
    state.finish(other);
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, newer, 5, 4, 50));
}

test "semantic finite counters retire authority and private state is bounded" {
    std.debug.print("semantic layouts state={d} bank={d} guard={d} target={d} down={d} up={d} held={d} history={d} completion={d} key={d}\n", .{ @sizeOf(State), @sizeOf(Bank), @sizeOf(Guard), @sizeOf(Target), @sizeOf(Down), @sizeOf(Up), @sizeOf(Held), @sizeOf(History), @sizeOf(Completion), @sizeOf(Key) });
    comptime std.debug.assert(@sizeOf(State) <= 4096);
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    state.next_target = exhausted - 1;
    try std.testing.expectError(error.IdExhausted, state.mint(20));
    try std.testing.expect(state.retired and state.closed);
    try std.testing.expectEqual(target.serial, try state.mark(0));
    try std.testing.expect(state.bound(0, target.id) == null);
    try std.testing.expectError(error.IdExhausted, state.install(test_window, .{}));
    var next: State = .{};
    next.installation = exhausted - 2;
    try next.install(test_window, .{});
    const next_target = try next.mint(10);
    try display(&next, &.{next_target}, .{});
    const old = try next.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    _ = try next.claim(old, next_target);
    next.next_ingress = exhausted - 1;
    try std.testing.expectError(error.IdExhausted, next.beginUp(.{ .sequence = 1, .point = .{ .x = 5, .y = 5 } }));
    next.finish(old);
    try std.testing.expect(next.savedHistoryPoint() == null and next.savedHeldPoint() == null);
}

test "semantic retirement keeps ordinary frames transactional for every finite issuer" {
    inline for (.{ "installation", "registration", "routing", "next_target", "next_ingress", "next_frame" }) |name| {
        var state: State = .{};
        try state.install(test_window, .{});
        const target = try state.mint(10);
        try display(&state, &.{target}, .{});
        _ = try pair(&state, target, 1, 0, 10);
        const old = try state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 1, .timing = sample(20), .point = .{ .x = 5, .y = 5 } });
        _ = try state.claim(old, target);
        const old_front = state.front_serial;
        @field(state, name) = exhausted - 1;
        if (comptime std.mem.eql(u8, name, "installation")) {
            try std.testing.expectError(error.IdExhausted, state.install(test_window, .{}));
        } else if (comptime std.mem.eql(u8, name, "registration")) {
            try std.testing.expectError(error.IdExhausted, state.replaceRegistration());
        } else if (comptime std.mem.eql(u8, name, "routing")) {
            try std.testing.expectError(error.IdExhausted, state.changeRoute());
        } else if (comptime std.mem.eql(u8, name, "next_target")) {
            try std.testing.expectError(error.IdExhausted, state.mint(20));
        } else if (comptime std.mem.eql(u8, name, "next_ingress")) {
            try std.testing.expectError(error.IdExhausted, state.beginDown(.{ .sequence = 3, .previous_completed_sequence = 1, .timing = sample(30), .point = .{ .x = 5, .y = 5 } }));
        } else {
            // Exhausting semantic frame metadata must not fail this visual
            // attempt. It starts a non-authorizing all-zero candidate instead.
            try state.beginFrame();
            try std.testing.expect(state.building and state.candidate_serial == 0);
        }
        try std.testing.expect(state.retired and state.closed);
        try std.testing.expectEqual(exhausted, @field(state, name));
        try std.testing.expectEqual(old_front, state.front_serial);
        try std.testing.expectEqual(target.serial, try state.mark(0));
        try std.testing.expect(state.bound(0, target.id) == null);
        try std.testing.expect(state.savedHeldPoint() == null and state.savedHistoryPoint() == null);
        try std.testing.expectError(error.StaleIngress, state.claim(old, target));
        state.finish(old);
        state.cancelFrame();
        const issued_frame = state.next_frame;

        // A failed or cancelled ordinary attempt keeps the displayed mark,
        // whose absence of authority must still mean deny, not legacy input.
        try state.beginFrame();
        try std.testing.expectEqual(@as(u64, 0), state.candidate_serial);
        _ = try state.append();
        const checkpoint = try state.append();
        try state.rollback(checkpoint);
        try std.testing.expectEqual(checkpoint, try state.append());
        try std.testing.expectError(error.InvalidBinding, state.commitFrame(1, .{}));
        try std.testing.expectEqual(old_front, state.front_serial);
        try std.testing.expectEqual(target.serial, try state.mark(0));
        state.cancelFrame();
        try std.testing.expectEqual(target.serial, try state.mark(0));

        // Only a successful matching visual commit clears stale marks. No
        // semantic counter is issued, even across repeated bank reuse.
        try state.beginFrame();
        const index = try state.append();
        try std.testing.expectError(error.StaleTarget, state.bind(index, target.id, target));
        try state.commitFrame(1, .{ .held = true, .history = true });
        try std.testing.expectEqual(@as(u64, 0), state.front_serial);
        try std.testing.expectEqual(@as(u64, 0), try state.mark(0));
        try std.testing.expectEqual(issued_frame, state.next_frame);
        try std.testing.expect(state.bound(0, target.id) == null);
        try state.beginFrame();
        for (0..capacity) |_| _ = try state.append();
        try std.testing.expectError(error.CapacityExceeded, state.append());
        try state.rollback(2);
        try state.commitFrame(2, .{});
        try std.testing.expectEqual(@as(u64, 0), try state.mark(0));
        try std.testing.expectEqual(@as(u64, 0), try state.mark(1));
        try std.testing.expectEqual(@as(u64, 0), state.front_serial);
        try std.testing.expectEqual(issued_frame, state.next_frame);
        try std.testing.expectError(error.Closed, state.mint(20));
        try std.testing.expectError(error.Closed, state.replaceRegistration());
        try std.testing.expectError(error.Closed, state.beginDown(.{ .sequence = 4, .previous_completed_sequence = 2, .timing = sample(40), .point = .{ .x = 5, .y = 5 } }));
        try std.testing.expectError(error.IdExhausted, state.changeRoute());
        try std.testing.expectError(error.IdExhausted, state.install(test_window, .{}));
        try std.testing.expect(state.retired and state.closed and state.savedHeldPoint() == null and state.savedHistoryPoint() == null);
    }
}

test "semantic retirement during a candidate never publishes its earlier nonzero marks" {
    var state: State = .{};
    try state.install(test_window, .{});
    const a = try state.mint(10);
    const b = try state.mint(20);
    try display(&state, &.{a}, .{});
    const old_front = state.front_serial;
    try state.beginFrame();
    try state.bind(try state.append(), a.id, a);
    try state.bind(try state.append(), b.id, b);
    const issued_frame = state.next_frame;
    try std.testing.expect(state.candidate_serial != 0);
    state.next_target = exhausted - 1;
    try std.testing.expectError(error.IdExhausted, state.mint(30));
    try std.testing.expectError(error.StaleTarget, state.commitFrame(2, .{ .held = true, .history = true }));
    try std.testing.expectEqual(old_front, state.front_serial);
    try std.testing.expectEqual(a.serial, try state.mark(0));
    try std.testing.expect(state.bound(0, a.id) == null);
    try state.rollback(1);
    try std.testing.expectError(error.StaleTarget, state.commitFrame(1, .{}));
    // Rollback removes all pre-retirement marks. Append initializes the reused
    // slot to zero; the already-issued candidate stamp cannot become authority.
    try state.rollback(0);
    const index = try state.append();
    try std.testing.expectError(error.StaleTarget, state.bind(index, a.id, a));
    try state.commitFrame(1, .{});
    try std.testing.expectEqual(@as(u64, 0), state.front_serial);
    try std.testing.expectEqual(@as(u64, 0), try state.mark(0));
    try std.testing.expectEqual(issued_frame, state.next_frame);
    try std.testing.expect(state.retired and state.closed);
}

test "semantic another delivered button supersedes the single held proposal" {
    var state: State = .{};
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    const down = try state.beginDown(.{ .sequence = 1, .previous_completed_sequence = 0, .timing = sample(10), .point = .{ .x = 5, .y = 5 } });
    _ = try state.claim(down, target);
    state.finish(down);
    const other = try state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 0, .timing = sample(20), .point = .{ .x = 5, .y = 5 }, .button = 1 });
    state.finish(other);
    // Raw still permits the old primary's up. UI no longer owns that proposal.
    const old_up = try state.beginUp(.{ .sequence = 1, .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectError(error.StaleIngress, state.takeUp(old_up, target));
    state.finish(old_up);
    try std.testing.expectEqual(@as(u8, 1), try pair(&state, target, 3, 2, 30));
}

test "semantic fresh allocation inherits the Context epoch despite address reuse" {
    var state = State.init(0);
    try state.install(test_window, .{});
    const old_target = try state.mint(10);
    try display(&state, &.{old_target}, .{});
    const epoch = state.installation;
    state.close();
    // Model actual same-address allocation reuse, within the same live Context.
    state = State.init(epoch);
    try state.install(test_window, .{});
    const target = try state.mint(10);
    try display(&state, &.{target}, .{});
    try std.testing.expect(old_target.owner == target.owner);
    try std.testing.expect(old_target.installation != target.installation);
    const down = try state.beginDown(.{ .sequence = 2, .previous_completed_sequence = 1, .timing = sample(20), .point = .{ .x = 5, .y = 5 } });
    try std.testing.expectError(error.StaleTarget, state.claim(down, old_target));
    try std.testing.expectEqual(@as(u8, 1), try state.claim(down, target));
    state.finish(down);
}
