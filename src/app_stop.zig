//! Private, owner-thread stop registrations. This module owns no resources and
//! allocates nothing. Its caller must stop native ingress, drain accepted work,
//! and reach an application safe point before calling stopAll.
const std = @import("std");

pub const max_capacity: usize = 65_536;

/// Linear, resource-owned storage. Do not move/copy a registered node. A taken
/// node stays alive until its stop callback runs, even if another callback asks
/// to close that resource. A successful callback may release the node as its
/// final action; an error MUST keep the node, context address and stop function
/// alive and preserve the node's cleared registration fields. Business context
/// may record completed stages: retries stay closed to ingress, must be
/// idempotent, and must not repeat logical completion. Do not free or re-register
/// the node on failure, or register it elsewhere before the callback returns.
pub const Node = struct {
    context: *anyopaque,
    stop: *const fn (*anyopaque) anyerror!void,
    manager: ?*Manager = null,
    generation: u64 = 0,
    previous: ?*Node = null,
    next: ?*Node = null,
    state: enum { idle, registered, taken, failed } = .idle,
};

/// A borrowed identity, not an owning or dangling-pointer-safe handle. Manager
/// AND Node must outlive every use, including stale-token queries/cancellation.
/// A new registration of the same live node never revives an old token. Neither
/// the manager nor its sequence may be reinitialized while tokens remain usable.
pub const Token = struct { manager: *Manager, node: *Node, generation: u64 };
pub const Phase = enum { open, sealed, stopped, deinitialized };
pub const Stats = struct {
    phase: Phase,
    capacity: usize,
    outstanding: usize,
    registered: usize,
    taken: usize,
    failed: usize,
    in_callback: bool,
};

/// Stable after the first registration; contains no table or allocation. The
/// capacity bounds resource-owned nodes, rather than reserving their storage.
/// All methods run on the creating thread. This does not itself pin an App or
/// authorize App destruction; the eventual caller supplies that outer lifetime.
pub const Manager = struct {
    owner: std.Thread.Id,
    capacity: usize,
    phase: Phase = .open,
    first: ?*Node = null,
    last: ?*Node = null,
    failed_first: ?*Node = null,
    failed_last: ?*Node = null,
    count: usize = 0,
    registered_count: usize = 0,
    taken_count: usize = 0,
    failed_count: usize = 0,
    next_generation: u64 = 1,
    busy: bool = false,
    in_callback: bool = false,

    pub fn init(capacity: usize) !Manager {
        if (capacity == 0 or capacity > max_capacity) return error.InvalidCapacity;
        return .{ .owner = std.Thread.getCurrentId(), .capacity = capacity };
    }

    fn checked(self: *const Manager) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.phase == .deinitialized) return error.Closed;
    }

    /// Success transfers stop responsibility. Full/Closed and every other error
    /// leave node ownership, its fields and the registration sequence untouched.
    pub fn register(self: *Manager, node: *Node) !Token {
        try self.checked();
        if (self.phase != .open) return error.Closed;
        if (node.manager != null or node.state != .idle) return error.AlreadyRegistered;
        if (self.count == self.capacity) return error.Full;
        const generation = self.next_generation;
        if (generation == 0) return error.GenerationExhausted;
        self.next_generation = if (generation == std.math.maxInt(u64)) 0 else generation + 1;
        node.manager = self;
        node.generation = generation;
        node.state = .registered;
        append(&self.first, &self.last, node);
        self.count += 1;
        self.registered_count += 1;
        return .{ .manager = self, .node = node, .generation = generation };
    }

    fn matches(self: *const Manager, token: Token) bool {
        return token.manager == self and token.generation != 0 and
            token.node.manager == self and token.node.generation == token.generation;
    }

    /// Eligibility for a NEW provider callback. Sealing blocks ingress without
    /// walking nodes or running user code. Existing callbacks need outer pins.
    pub fn accepts(self: *const Manager, token: Token) !bool {
        try self.checked();
        return self.phase == .open and self.matches(token) and token.node.state == .registered;
    }

    /// Cancels an unclaimed registration, without running stop or freeing the
    /// resource. True transfers stop responsibility back to the caller, which
    /// may immediately free its node. Sealed-but-not-taken nodes can be cancelled
    /// by already accepted work. StopInProgress keeps responsibility here: taken
    /// and failed nodes MUST NOT be released. A currently executing stop has
    /// already taken its own registration, so its old token returns false.
    pub fn cancel(self: *Manager, token: Token) !bool {
        try self.checked();
        if (token.manager != self) return error.ForeignManager;
        if (!self.matches(token)) return false;
        switch (token.node.state) {
            .registered => {},
            .taken, .failed => return error.StopInProgress,
            .idle => return false,
        }
        unlink(&self.first, &self.last, token.node);
        clear(token.node);
        self.count -= 1;
        self.registered_count -= 1;
        return true;
    }

    /// Immediate ingress barrier. No callbacks or per-node work. This operation
    /// is idempotent and never reopens, even after all nodes have gone away.
    pub fn seal(self: *Manager) !void {
        try self.checked();
        if (self.phase == .open) self.phase = .sealed;
    }

    /// One reverse-registration-order pass, at most one attempt per node. Take
    /// the ENTIRE old batch before invoking anything, preventing a callback from
    /// cancelling/freeing a later node behind the walk. Continue other stops on
    /// error and return the first error afterwards. Failures retain their nodes
    /// in original order, closed to ingress and cancellation; only a later
    /// explicit stopAll call retries them. There is no retry loop or wake timer.
    /// A recursive stopAll/deinit returns Busy; the Manager itself must survive.
    pub fn stopAll(self: *Manager) anyerror!void {
        try self.checked();
        if (self.busy) return error.Busy;
        try self.seal();
        self.busy = true;
        defer self.busy = false;
        // An open registration batch and a failed stop batch cannot coexist:
        // the first attempt seals ingress permanently.
        std.debug.assert(self.first == null or self.failed_first == null);
        var cursor = self.last orelse self.failed_last;
        var mark = self.first orelse self.failed_first;
        while (mark) |node| : (mark = node.next) node.state = .taken;
        self.first = null;
        self.last = null;
        self.failed_first = null;
        self.failed_last = null;
        self.taken_count = self.count;
        self.registered_count = 0;
        self.failed_count = 0;
        var first_error: ?anyerror = null;
        while (cursor) |node| {
            // Only unprocessed .taken nodes can be in this pointer chain. They
            // cannot be cancelled, and a successful current node may disappear.
            cursor = node.previous;
            const context = node.context;
            const stop_fn = node.stop;
            const generation = node.generation;
            clear(node);
            self.taken_count -= 1;
            self.in_callback = true;
            stop_fn(context) catch |err| {
                // Error keeps node storage, cleared registration fields, the
                // context pointer and stop function intact; context CONTENTS
                // may record partial progress. Success never reads node again.
                std.debug.assert(node.manager == null and node.state == .idle);
                std.debug.assert(node.context == context and node.stop == stop_fn);
                node.manager = self;
                node.generation = generation;
                node.state = .failed;
                prepend(&self.failed_first, &self.failed_last, node);
                self.failed_count += 1;
                if (first_error == null) first_error = err;
                self.in_callback = false;
                continue;
            };
            self.in_callback = false;
            self.count -= 1;
        }
        std.debug.assert(self.taken_count == 0 and self.count == self.failed_count);
        if (self.count == 0) self.phase = .stopped;
        if (first_error) |err| return err;
    }

    pub fn stats(self: *const Manager) !Stats {
        try self.checked();
        return .{ .phase = self.phase, .capacity = self.capacity, .outstanding = self.count, .registered = self.registered_count, .taken = self.taken_count, .failed = self.failed_count, .in_callback = self.in_callback };
    }

    /// No forced release: callbacks/pending failures must be handled first.
    pub fn deinit(self: *Manager) !void {
        try self.checked();
        if (self.busy) return error.Busy;
        if (self.count != 0) return error.ParticipantsAlive;
        std.debug.assert(self.first == null and self.last == null and self.failed_first == null and self.failed_last == null);
        self.phase = .deinitialized;
    }
};

fn append(first: *?*Node, last: *?*Node, node: *Node) void {
    node.previous = last.*;
    node.next = null;
    if (last.*) |tail| tail.next = node else first.* = node;
    last.* = node;
}
fn prepend(first: *?*Node, last: *?*Node, node: *Node) void {
    node.previous = null;
    node.next = first.*;
    if (first.*) |head| head.previous = node else last.* = node;
    first.* = node;
}
fn unlink(first: *?*Node, last: *?*Node, node: *Node) void {
    if (node.previous) |previous| previous.next = node.next else first.* = node.next;
    if (node.next) |next| next.previous = node.previous else last.* = node.previous;
}
fn clear(node: *Node) void {
    node.manager = null;
    node.generation = 0;
    node.previous = null;
    node.next = null;
    node.state = .idle;
}

test "capacity cancellation and stale live-node tokens require no historical storage" {
    const Probe = struct {
        calls: usize = 0,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    var manager = try Manager.init(1);
    defer manager.deinit() catch unreachable;
    var probe: Probe = .{};
    var node: Node = .{ .context = &probe, .stop = Probe.stop };
    var other: Node = .{ .context = &probe, .stop = Probe.stop };
    const old = try manager.register(&node);
    try std.testing.expect(try manager.accepts(old));
    try std.testing.expectError(error.AlreadyRegistered, manager.register(&node));
    const before_full = manager.next_generation;
    try std.testing.expectError(error.Full, manager.register(&other));
    try std.testing.expect(other.manager == null and other.state == .idle);
    try std.testing.expectEqual(before_full, manager.next_generation);
    try std.testing.expectError(error.ParticipantsAlive, manager.deinit());
    try std.testing.expect(try manager.cancel(old));
    for (0..100_000) |_| {
        const current = try manager.register(&node);
        try std.testing.expect(!try manager.accepts(old));
        try std.testing.expect(!try manager.cancel(old));
        try std.testing.expect(try manager.accepts(current));
        try std.testing.expect(try manager.cancel(current));
    }
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), (try manager.stats()).outstanding);
    try std.testing.expect(manager.first == null and manager.last == null and manager.failed_first == null);
    try manager.stopAll();
    try manager.stopAll();
    try std.testing.expectError(error.Closed, manager.register(&node));
}

test "sealed ingress still lets accepted work cancel before the reverse stop batch" {
    const Probe = struct {
        const Parent = @This();
        log: [4]u8 = undefined,
        len: usize = 0,
        const Entry = struct {
            probe: *Parent,
            id: u8,
            fn stop(ptr: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.probe.log[self.probe.len] = self.id;
                self.probe.len += 1;
            }
        };
    };
    var manager = try Manager.init(4);
    defer manager.deinit() catch unreachable;
    var probe: Probe = .{};
    var entries: [4]Probe.Entry = undefined;
    var nodes: [4]Node = undefined;
    var tokens: [4]Token = undefined;
    for (&entries, &nodes, &tokens, 0..) |*entry, *node, *token, i| {
        entry.* = .{ .probe = &probe, .id = @intCast(i) };
        node.* = .{ .context = entry, .stop = Probe.Entry.stop };
        token.* = try manager.register(node);
    }
    try manager.seal();
    for (tokens) |token| try std.testing.expect(!try manager.accepts(token));
    try std.testing.expect(try manager.cancel(tokens[1]));
    try std.testing.expect(!try manager.cancel(tokens[1]));
    try manager.stopAll();
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 0 }, probe.log[0..probe.len]);
    for (tokens) |token| try std.testing.expect(!try manager.cancel(token));
}

test "whole batch is taken before callbacks can close each other or recurse" {
    const Probe = struct {
        const Parent = @This();
        manager: *Manager,
        tokens: [3]Token = undefined,
        log: [3]u8 = undefined,
        len: usize = 0,
        extra: Node = undefined,
        const Entry = struct {
            probe: *Parent,
            id: u8,
            fn stop(ptr: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const probe = self.probe;
                probe.log[probe.len] = self.id;
                probe.len += 1;
                try std.testing.expectError(error.Busy, probe.manager.stopAll());
                try std.testing.expectError(error.Busy, probe.manager.deinit());
                try std.testing.expectError(error.Closed, probe.manager.register(&probe.extra));
                try std.testing.expect(!try probe.manager.cancel(probe.tokens[self.id]));
                for (0..self.id) |i| try std.testing.expectError(error.StopInProgress, probe.manager.cancel(probe.tokens[i]));
                const stats = try probe.manager.stats();
                try std.testing.expect(stats.in_callback and stats.registered == 0 and stats.taken == self.id);
            }
        };
    };
    var manager = try Manager.init(4);
    defer manager.deinit() catch unreachable;
    var probe: Probe = .{ .manager = &manager };
    var entries: [3]Probe.Entry = undefined;
    var nodes: [3]Node = undefined;
    probe.extra = .{ .context = &entries[0], .stop = Probe.Entry.stop };
    for (&entries, &nodes, &probe.tokens, 0..) |*entry, *node, *token, i| {
        entry.* = .{ .probe = &probe, .id = @intCast(i) };
        node.* = .{ .context = entry, .stop = Probe.Entry.stop };
        token.* = try manager.register(node);
    }
    try manager.stopAll();
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 0 }, probe.log[0..probe.len]);
}

test "successful stop may poison and free its own resource-owned node" {
    const Probe = struct {
        const Parent = @This();
        allocator: std.mem.Allocator,
        released: usize = 0,
        const Entry = struct {
            node: Node,
            probe: *Parent,
            fn stop(ptr: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const probe = self.probe;
                try std.testing.expect(self.node.manager == null and self.node.next == null and self.node.previous == null);
                probe.released += 1;
                @memset(std.mem.asBytes(self), 0xdd);
                probe.allocator.destroy(self);
            }
        };
    };
    var manager = try Manager.init(1_024);
    defer manager.deinit() catch unreachable;
    var probe: Probe = .{ .allocator = std.testing.allocator };
    for (0..1_024) |_| {
        const entry = try probe.allocator.create(Probe.Entry);
        entry.* = .{ .node = .{ .context = entry, .stop = Probe.Entry.stop }, .probe = &probe };
        _ = try manager.register(&entry.node);
    }
    try manager.stopAll();
    try std.testing.expectEqual(@as(usize, 1_024), probe.released);
    try std.testing.expectEqual(@as(usize, 0), (try manager.stats()).outstanding);
}

test "cancel transfers responsibility and removes every reference before immediate free" {
    const Entry = struct {
        node: Node,
        calls: *usize,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls.* += 1;
        }
    };
    var manager = try Manager.init(3);
    defer manager.deinit() catch unreachable;
    var calls: usize = 0;
    var nodes: [3]*Entry = undefined;
    var tokens: [3]Token = undefined;
    for (&nodes, &tokens) |*entry, *token| {
        entry.* = try std.testing.allocator.create(Entry);
        entry.*.* = .{ .node = .{ .context = entry.*, .stop = Entry.stop }, .calls = &calls };
        token.* = try manager.register(&entry.*.node);
    }
    try std.testing.expect(try manager.cancel(tokens[1]));
    @memset(std.mem.asBytes(nodes[1]), 0xdd);
    std.testing.allocator.destroy(nodes[1]);
    // tokens[1] is no longer usable: its borrowed node has been freed.
    try manager.stopAll();
    try std.testing.expectEqual(@as(usize, 2), calls);
    std.testing.allocator.destroy(nodes[0]);
    std.testing.allocator.destroy(nodes[2]);
}

test "errors keep storage and responsibility for one explicit later retry" {
    const Probe = struct {
        const Parent = @This();
        manager: *Manager,
        log: [8]u8 = undefined,
        len: usize = 0,
        const Entry = struct {
            probe: *Parent,
            id: u8,
            fail: bool,
            calls: usize = 0,
            fn stop(ptr: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.calls += 1;
                self.probe.log[self.probe.len] = self.id;
                self.probe.len += 1;
                if (self.fail) return if (self.id == 2) error.FirstNativeFailure else error.SecondNativeFailure;
            }
        };
    };
    var manager = try Manager.init(3);
    var probe: Probe = .{ .manager = &manager };
    var entries: [3]Probe.Entry = undefined;
    var nodes: [3]Node = undefined;
    var tokens: [3]Token = undefined;
    for (&entries, &nodes, &tokens, 0..) |*entry, *node, *token, i| {
        entry.* = .{ .probe = &probe, .id = @intCast(i), .fail = i != 1 };
        node.* = .{ .context = entry, .stop = Probe.Entry.stop };
        token.* = try manager.register(node);
    }
    try std.testing.expectError(error.FirstNativeFailure, manager.stopAll());
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 0 }, probe.log[0..probe.len]);
    const first = try manager.stats();
    try std.testing.expect(first.phase == .sealed and first.outstanding == 2 and first.failed == 2 and !first.in_callback);
    try std.testing.expectError(error.ParticipantsAlive, manager.deinit());
    for ([_]usize{ 0, 2 }) |i| {
        try std.testing.expect(!try manager.accepts(tokens[i]));
        try std.testing.expectError(error.StopInProgress, manager.cancel(tokens[i]));
        try std.testing.expectEqual(@as(usize, 1), entries[i].calls);
        entries[i].fail = false;
    }
    try std.testing.expect(!try manager.cancel(tokens[1]));
    try manager.stopAll();
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 0, 2, 0 }, probe.log[0..probe.len]);
    try manager.stopAll();
    try std.testing.expectEqual(@as(usize, 5), probe.len);
    try manager.deinit();
}

test "generation exhaustion and foreign managers never mutate borrowed nodes" {
    const stop = struct {
        fn call(_: *anyopaque) !void {}
    }.call;
    var manager = try Manager.init(1);
    defer manager.deinit() catch unreachable;
    var other = try Manager.init(1);
    defer other.deinit() catch unreachable;
    var context: u8 = 0;
    var node: Node = .{ .context = &context, .stop = stop };
    manager.next_generation = std.math.maxInt(u64);
    const token = try manager.register(&node);
    try std.testing.expectError(error.ForeignManager, other.cancel(token));
    try std.testing.expect(!try other.accepts(token));
    try std.testing.expect(try manager.cancel(token));
    try std.testing.expectError(error.GenerationExhausted, manager.register(&node));
    try std.testing.expect(node.manager == null and node.state == .idle);
    // It is a different manager/lifetime, but node reuse does not revive token.
    const fresh = try other.register(&node);
    try std.testing.expect(!try manager.cancel(token));
    try std.testing.expect(try other.cancel(fresh));
}

test "partial stop failure retries native release without repeating logical completion and may self-free" {
    const Probe = struct {
        const Parent = @This();
        logical_completions: usize = 0,
        native_attempts: usize = 0,
        released: usize = 0,
        const Resource = struct {
            node: Node,
            probe: *Parent,
            completed: bool = false,
            fn stop(ptr: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const probe = self.probe;
                if (!self.completed) {
                    self.completed = true;
                    probe.logical_completions += 1;
                }
                probe.native_attempts += 1;
                if (probe.native_attempts == 1) return error.NativeReleaseFailed;
                probe.released += 1;
                @memset(std.mem.asBytes(self), 0xdd);
                std.testing.allocator.destroy(self);
            }
        };
    };
    var manager = try Manager.init(1);
    defer manager.deinit() catch unreachable;
    var probe: Probe = .{};
    const resource = try std.testing.allocator.create(Probe.Resource);
    resource.* = .{ .node = .{ .context = resource, .stop = Probe.Resource.stop }, .probe = &probe };
    const token = try manager.register(&resource.node);
    try std.testing.expectError(error.NativeReleaseFailed, manager.stopAll());
    try std.testing.expectError(error.StopInProgress, manager.cancel(token));
    try std.testing.expect(resource.completed and (try manager.stats()).outstanding == 1);
    try manager.stopAll();
    // token's resource was freed by the successful callback; do not use it.
    try std.testing.expectEqual(@as(usize, 1), probe.logical_completions);
    try std.testing.expectEqual(@as(usize, 2), probe.native_attempts);
    try std.testing.expectEqual(@as(usize, 1), probe.released);
    try std.testing.expectEqual(@as(usize, 0), (try manager.stats()).outstanding);
}

test "all entry points reject a different actual thread before reading node state" {
    const Probe = struct {
        manager: *Manager,
        node: *Node,
        token: Token,
        rejected: usize = 0,
        fn worker(self: *@This()) void {
            _ = self.manager.register(self.node) catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            _ = self.manager.cancel(self.token) catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            _ = self.manager.accepts(self.token) catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            self.manager.seal() catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            self.manager.stopAll() catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            _ = self.manager.stats() catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
            self.manager.deinit() catch |err| {
                if (err == error.WrongThread) self.rejected += 1;
            };
        }
        fn stop(_: *anyopaque) !void {}
    };
    var manager = try Manager.init(1);
    defer manager.deinit() catch unreachable;
    var context: u8 = 0;
    var node: Node = .{ .context = &context, .stop = Probe.stop };
    const token = try manager.register(&node);
    var probe: Probe = .{ .manager = &manager, .node = &node, .token = token };
    const thread = try std.Thread.spawn(.{}, Probe.worker, .{&probe});
    thread.join();
    try std.testing.expectEqual(@as(usize, 7), probe.rejected);
    try std.testing.expect(try manager.accepts(token));
    try std.testing.expect(try manager.cancel(token));
}

test "capacity validation empty stop and deinit are explicit" {
    try std.testing.expectError(error.InvalidCapacity, Manager.init(0));
    try std.testing.expectError(error.InvalidCapacity, Manager.init(max_capacity + 1));
    var manager = try Manager.init(1);
    try manager.seal();
    try manager.seal();
    try manager.stopAll();
    try std.testing.expect((try manager.stats()).phase == .stopped);
    try manager.deinit();
    try std.testing.expectError(error.Closed, manager.stopAll());
    try std.testing.expectError(error.Closed, manager.stats());
}
