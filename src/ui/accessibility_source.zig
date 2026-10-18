const std = @import("std");
const z = @import("ziggurat");

pub const Phase = enum { frame_begin, committed };
/// Owner-thread callbacks. The source context remains borrowed through unbound
/// and the return of every query/phase/position callback already using it.
pub const Source = struct {
    context: *anyopaque,
    query: *const fn (*anyopaque, z.Window, usize, isize) ?isize,
    position_changed: ?*const fn (*anyopaque, z.Window) void = null,
    phase: ?*const fn (*anyopaque, z.Window, Phase) void = null,
    unbound: ?*const fn (*anyopaque) void = null,
};
const Entry = struct { source: ?Source = null, generation: u64 = 0, active: usize = 0, retired: bool = false };
pub const Pin = struct { index: u1, generation: u64, source: Source };

/// Two fixed slots permit one replacement while the old source is on stack.
/// A second nested replacement is Busy until one old callback retires. No
/// allocation, native operation, or borrowed caller storage is hidden here.
pub const State = struct {
    entries: [2]Entry = .{ .{}, .{} },
    current: ?u1 = null,
    generation: u64 = 0,
    notifying: bool = false,
    frame_candidate: u64 = 0,
    frame_committed: u64 = 0,

    pub fn beginFrame(self: *State) !void {
        if (self.current == null) return;
        if (self.frame_candidate == std.math.maxInt(u64)) return error.GenerationExhausted;
        self.frame_candidate += 1;
    }
    pub fn commitFrame(self: *State, source: ?u64) void {
        if (source != null and source == self.currentGeneration()) self.frame_committed = self.frame_candidate;
    }
    pub fn isCommittedFrame(self: *const State, source: u64, candidate: u64) bool {
        return self.currentGeneration() == source and candidate != 0 and candidate == self.frame_candidate and candidate == self.frame_committed;
    }

    pub fn currentGeneration(self: *const State) ?u64 {
        const index = self.current orelse return null;
        return self.entries[index].generation;
    }

    pub fn install(self: *State, source: Source) !u64 {
        if (self.notifying) return error.Busy;
        if (self.generation == std.math.maxInt(u64)) return error.IdExhausted;
        var free_index: ?u1 = null;
        for (&self.entries, 0..) |*entry, index| if (entry.source == null) {
            free_index = @intCast(index);
            break;
        };
        if (free_index == null) if (self.current) |index| if (self.entries[index].active == 0) {
            free_index = index;
        };
        const target = free_index orelse return error.Busy;
        var previous: ?Source = null;
        if (self.current) |index| {
            const entry = &self.entries[index];
            entry.retired = true;
            if (entry.active == 0) {
                previous = entry.source;
                entry.source = null;
            }
        }
        self.generation += 1;
        const generation = self.generation;
        self.entries[target] = .{ .source = source, .generation = generation };
        self.current = target;
        // Publication precedes foreign disposal. An unbound callback may close
        // the owner; the returned token can therefore already have retired.
        self.notify(previous);
        return generation;
    }
    pub fn clear(self: *State, generation: u64) !bool {
        if (self.notifying) return error.Busy;
        const index = self.current orelse return false;
        if (self.entries[index].generation != generation) return false;
        self.current = null;
        self.retire(index);
        return true;
    }
    /// Teardown cannot fail because both current and retired callbacks may be
    /// on stack. Revoke both entrances before invoking any unbound notification.
    pub fn close(self: *State) void {
        self.current = null;
        for (&self.entries) |*entry| if (entry.source != null) {
            entry.retired = true;
        };
        for (0..self.entries.len) |index| self.retire(@intCast(index));
    }
    pub fn pin(self: *State) ?Pin {
        const index = self.current orelse return null;
        const entry = &self.entries[index];
        if (entry.active == 64) return null;
        entry.active += 1;
        return .{ .index = index, .generation = entry.generation, .source = entry.source.? };
    }
    pub fn isCurrent(self: *const State, pin_value: Pin) bool {
        return self.current == pin_value.index and self.entries[pin_value.index].generation == pin_value.generation;
    }
    pub fn end(self: *State, pin_value: Pin) void {
        const entry = &self.entries[pin_value.index];
        std.debug.assert(entry.generation == pin_value.generation and entry.active > 0 and entry.source != null);
        entry.active -= 1;
        if (entry.retired) self.retire(pin_value.index);
    }
    fn retire(self: *State, index: u1) void {
        const entry = &self.entries[index];
        entry.retired = true;
        if (entry.active != 0) return;
        const previous = entry.source;
        entry.source = null;
        self.notify(previous);
    }
    fn notify(self: *State, source: ?Source) void {
        const value = source orelse return;
        const callback = value.unbound orelse return;
        const previous = self.notifying;
        self.notifying = true;
        defer self.notifying = previous;
        callback(value.context);
    }
};

const Probe = struct {
    unbound: usize = 0,
    source_state: ?*State = null,
    fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    fn release(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.unbound += 1;
        if (self.source_state) |state| state.close();
    }
    fn source(self: *Probe) Source {
        return .{ .context = self, .query = query, .unbound = release };
    }
};
test "source replacement and teardown preserve active callback storage" {
    var state: State = .{};
    var first: Probe = .{};
    var second: Probe = .{};
    const first_id = try state.install(first.source());
    const first_pin = state.pin().?;
    const second_id = try state.install(second.source());
    const second_pin = state.pin().?;
    try std.testing.expect(!state.isCurrent(first_pin) and state.isCurrent(second_pin));
    try std.testing.expectError(error.Busy, state.install(first.source()));
    try std.testing.expect(!(try state.clear(first_id)));
    state.close();
    try std.testing.expect(state.pin() == null);
    try std.testing.expectEqual(@as(usize, 0), first.unbound + second.unbound);
    state.end(second_pin);
    try std.testing.expectEqual(@as(usize, 1), second.unbound);
    state.end(first_pin);
    try std.testing.expectEqual(@as(usize, 1), first.unbound);
    try std.testing.expect(!(try state.clear(second_id)));
}
test "unbound teardown cannot revive a published replacement" {
    var state: State = .{};
    var first: Probe = .{ .source_state = &state };
    var second: Probe = .{};
    _ = try state.install(first.source());
    const id = try state.install(second.source());
    try std.testing.expect(state.pin() == null);
    try std.testing.expectEqual(@as(usize, 1), first.unbound);
    try std.testing.expectEqual(@as(usize, 1), second.unbound);
    try std.testing.expect(!(try state.clear(id)));
    state.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, state.install(second.source()));
}

test "geometry candidates consume nonwrapping identity separately from successful fronts" {
    var state: State = .{};
    try state.beginFrame();
    try std.testing.expectEqual(@as(u64, 0), state.frame_candidate);
    var host: Probe = .{};
    const source = try state.install(host.source());
    try state.beginFrame();
    try std.testing.expect(!state.isCommittedFrame(source, 1));
    state.commitFrame(source);
    try std.testing.expect(state.isCommittedFrame(source, 1));
    try state.beginFrame();
    try std.testing.expect(!state.isCommittedFrame(source, 1));
    try std.testing.expect(!state.isCommittedFrame(source, 2));
    try state.beginFrame();
    state.commitFrame(source);
    try std.testing.expect(state.isCommittedFrame(source, 3));
    _ = try state.install(host.source());
    try std.testing.expect(!state.isCommittedFrame(source, 3));
    state.frame_candidate = std.math.maxInt(u64);
    try std.testing.expectError(error.GenerationExhausted, state.beginFrame());
    try std.testing.expectEqual(std.math.maxInt(u64), state.frame_candidate);
    state.close();
}
