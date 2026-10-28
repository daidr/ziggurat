const std = @import("std");
const d = @import("ziggurat_document");
const r = @import("results.zig");

pub const Limits = struct { pending: usize = 8, results: r.Limits = .{} };
pub const Ticket = struct { broker: *Broker, index: u8, serial: u64, revision: u64, text_version: u64, kind: r.Kind };
const Control = struct { state: std.atomic.Value(u64) = .init(0), cancelled: std.atomic.Value(bool) = .init(false) };
const Slot = struct {
    control: Control = .{},
    serial: u64 = 0,
    snapshot: ?*d.Snapshot = null,
    revision: u64 = 0,
    text_version: u64 = 0,
    kind: r.Kind = .completion,
    position: usize = 0,
    published: bool = false,
};
pub const Display = struct { ticket: Ticket, data: r.Data, position: usize };
const Stored = struct { ticket: Ticket, result: r.OwnedResult, position: usize };

/// Owner-thread scoped result borrow. Mutating Broker operations return Busy
/// until end, including allocator callback reentry. Scope/copies must not be
/// used after end. No allocation; the Broker must outlive the scope.
pub const Borrow = struct {
    broker: *Broker,
    pub fn display(self: Borrow, kind: r.Kind) !?Display {
        return self.broker.displayInner(kind);
    }
    pub fn end(self: Borrow) void {
        self.broker.busy = false;
    }
    pub fn releaseClient(self: Borrow) !void {
        if (self.broker.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.broker.clients == 0) return error.ClientNotAttached;
        self.broker.clients -= 1;
    }
};

/// Linear worker lease. Reader is immutable document input; do not release it
/// separately. No Broker/Adapter/UI method is callable on this worker. release
/// ends Reader use and is the LAST access to job-owned shared memory, but does
/// NOT hand delivery responsibility back or return physical request capacity.
/// Every accepted Job also needs one owner-thread Broker.finish(ticket), after
/// the result task runs, or after failed post + explicit worker join. Job/Ticket
/// copies cannot outlive that responsibility or the Broker itself.
pub const Job = struct {
    ticket: Ticket,
    reader: d.Reader,
    position: usize,
    limits: r.Limits,
    control: *Control,
    pub fn isCancelled(self: Job) !bool {
        if (self.control.state.load(.acquire) != self.ticket.serial * 4 + 1) return error.JobClosed;
        return self.control.cancelled.load(.acquire);
    }
    pub fn release(self: Job) !void {
        const active = self.ticket.serial * 4 + 1;
        if (self.control.state.cmpxchgStrong(active, active + 1, .acq_rel, .acquire) != null) return error.JobClosed;
        const released = self.reader.release();
        self.control.state.store(active + 2, .release);
        try released;
    }
};

/// Main-thread request/result owner. It retains the same Document and snapshots,
/// never a second editable buffer/history. Its allocator is explicit; pending
/// Snapshot roots/Reader slots remain in the Document allocator's own budget.
/// Keep its stable address through ALL accepted Job/delivery responsibilities.
pub const Broker = struct {
    /// Owner-only, linear reservation across an explicit host send decision.
    /// While live, display borrows and mutations are Busy. No allocator or
    /// callback runs in begin/cancel; commit cannot exhaust a generation.
    pub const Invalidation = struct {
        broker: *Broker,
        display_version: u64,
        invalidation_version: u64,
        live: bool = true,
        committed: bool = false,
        pub fn commit(self: *Invalidation) !void {
            try self.commitRetained();
            self.end();
        }
        /// Publish while retaining the gate for an enclosing owner's remaining
        /// cleanup/state access. The enclosing scope must always call end.
        pub fn commitRetained(self: *Invalidation) !void {
            if (self.broker.owner != std.Thread.getCurrentId()) return error.WrongThread;
            if (!self.live) return error.ScopeClosed;
            if (self.committed) return error.ScopeCommitted;
            self.committed = true;
            const broker = self.broker;
            broker.applyInvalidation(self.display_version, self.invalidation_version);
        }
        pub fn end(self: *Invalidation) void {
            std.debug.assert(self.broker.owner == std.Thread.getCurrentId());
            if (!self.live) return;
            self.live = false;
            self.broker.busy = false;
        }
    };
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    document: *d.Document,
    limits: Limits,
    slots: []Slot,
    next_serial: u64 = 1,
    current: [3]u64 = @splat(0),
    stored: [3]?Stored = @splat(null),
    display_generation: u64 = 0,
    /// Explicit service invalidation; independent of ordinary result updates.
    invalidation_generation: u64 = 0,
    outstanding: usize = 0,
    clients: usize = 0,
    stopping: bool = false,
    busy: bool = false,

    pub fn create(allocator: std.mem.Allocator, document: *d.Document, limits: Limits) !*Broker {
        if (limits.pending == 0 or limits.pending > 32) return error.InvalidLimits;
        try limits.results.validate();
        try document.retainClient();
        errdefer document.releaseClient() catch unreachable;
        const self = try allocator.create(Broker);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, limits.pending);
        for (slots) |*entry| entry.* = .{};
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .document = document, .limits = limits, .slots = slots };
        return self;
    }
    fn check(self: *const Broker) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *Broker) !void {
        try self.check();
        self.busy = true;
    }
    fn nextDisplay(self: *const Broker) !u64 {
        return std.math.add(u64, self.display_generation, 1) catch error.IdExhausted;
    }
    fn slot(self: *Broker, ticket: Ticket) ?*Slot {
        if (ticket.broker != self or ticket.index >= self.slots.len or ticket.serial == 0) return null;
        const value = &self.slots[ticket.index];
        return if (value.serial == ticket.serial and value.revision == ticket.revision and value.text_version == ticket.text_version and value.kind == ticket.kind) value else null;
    }
    fn fresh(self: *const Broker, ticket: Ticket) !bool {
        return if (ticket.kind == .completion) ticket.revision == try self.document.version() else ticket.text_version == try self.document.committedTextVersion();
    }
    fn drop(self: *Broker, kind: r.Kind) void {
        const index = @backingInt(kind);
        const previous = self.stored[index];
        self.stored[index] = null;
        if (previous) |item| {
            var owned = item.result;
            owned.deinit();
        }
    }
    fn revoke(self: *Broker, kind: r.Kind) void {
        const index = @backingInt(kind);
        for (self.slots) |*value| if (value.serial != 0 and value.kind == kind and value.serial == self.current[index]) value.control.cancelled.store(true, .release);
        self.current[index] = 0;
        self.drop(kind);
    }
    /// Only explicit ownership work is done here. A later request cancels the
    /// previous logical request of this kind AFTER its own candidate succeeds.
    /// Full/OOM never steals the previous worker or display's responsibility.
    pub fn begin(self: *Broker, kind: r.Kind, position: usize) !Job {
        try self.enter();
        defer self.busy = false;
        if (self.stopping) return error.Closed;
        const index = for (self.slots, 0..) |value, at| {
            if (value.serial == 0) break at;
        } else return error.Full;
        if (self.next_serial > std.math.maxInt(u64) / 4) return error.IdExhausted;
        const generation = try self.nextDisplay();
        const revision = try self.document.version();
        const text_version = try self.document.committedTextVersion();
        if (kind == .completion and try self.document.composition() != null) return error.CompositionActive;
        _ = try self.document.utf16Offset(position);
        const snapshot = try self.document.snapshot();
        errdefer snapshot.close() catch unreachable;
        const reader = try snapshot.borrowReader();
        errdefer reader.release() catch unreachable;
        if (revision != try snapshot.version() or revision != try self.document.version()) return error.StaleRevision;
        const serial = self.next_serial;
        self.next_serial += 1;
        const value = &self.slots[index];
        value.serial = serial;
        value.snapshot = snapshot;
        value.revision = revision;
        value.text_version = text_version;
        value.kind = kind;
        value.position = position;
        value.published = false;
        value.control.cancelled.store(false, .monotonic);
        value.control.state.store(serial * 4 + 1, .release);
        self.outstanding += 1;
        // Keep the previous still-fresh display until a valid replacement is
        // published. Ingress cancellation and visible result ownership differ.
        for (self.slots) |*entry| if (entry.serial != 0 and entry.kind == kind and entry.serial == self.current[@backingInt(kind)]) entry.control.cancelled.store(true, .release);
        self.current[@backingInt(kind)] = serial;
        self.display_generation = generation;
        return .{ .ticket = .{ .broker = self, .index = @intCast(index), .serial = serial, .revision = revision, .text_version = text_version, .kind = kind }, .reader = reader, .position = position, .limits = self.limits.results, .control = &value.control };
    }
    pub fn cancel(self: *Broker, ticket: Ticket) !bool {
        try self.enter();
        defer self.busy = false;
        const value = self.slot(ticket) orelse return false;
        const generation = try self.nextDisplay();
        value.control.cancelled.store(true, .release);
        if (self.current[@backingInt(ticket.kind)] == ticket.serial) self.revoke(ticket.kind);
        self.display_generation = generation;
        return true;
    }
    /// Move ownership on SUCCESS ONLY. This never finishes the Job/delivery;
    /// the host must call finish even after rejection and deinit its retained
    /// stale/invalid result. Worker Reader must already have been released.
    pub fn publish(self: *Broker, ticket: Ticket, owned: *r.OwnedResult) !void {
        try self.enter();
        defer self.busy = false;
        if (self.stopping) return error.Closed;
        const value = self.slot(ticket) orelse return error.StaleTicket;
        if (self.current[@backingInt(ticket.kind)] != ticket.serial or value.control.cancelled.load(.acquire)) return error.Cancelled;
        if (!try self.fresh(ticket)) return error.StaleRevision;
        if (value.control.state.load(.acquire) != ticket.serial * 4 + 3) return error.WorkerRunning;
        if (value.published) return error.AlreadyPublished;
        if (owned.storage == null) return error.ResultMoved;
        if (std.meta.activeTag(owned.data) != ticket.kind) return error.WrongResultKind;
        try validateResult(owned, self.limits.results, value.snapshot.?);
        const generation = try self.nextDisplay();
        const old = self.stored[@backingInt(ticket.kind)];
        self.stored[@backingInt(ticket.kind)] = .{ .ticket = ticket, .result = owned.*, .position = value.position };
        owned.storage = null;
        owned.data = .{ .completion = &.{} };
        value.published = true;
        self.display_generation = generation;
        if (old) |previous| {
            var result = previous.result;
            result.deinit();
        }
    }
    /// Explicit owner acknowledgement of the SINGLE delivery responsibility.
    /// A done worker alone is insufficient: an accepted App.post may still hold
    /// this ticket. Call only from that task (after publish/error cleanup), or
    /// after failed posting and explicit worker join. Early finish changes
    /// nothing. No automatic reap can release a queued task's target Broker.
    pub fn finish(self: *Broker, ticket: Ticket) !bool {
        try self.enter();
        defer self.busy = false;
        const value = self.slot(ticket) orelse return false;
        if (value.control.state.load(.acquire) != ticket.serial * 4 + 3) return error.WorkerRunning;
        try value.snapshot.?.close();
        value.snapshot = null;
        if (!value.published and self.current[@backingInt(value.kind)] == value.serial) self.current[@backingInt(value.kind)] = 0;
        value.serial = 0;
        value.control.state.store(0, .release);
        self.outstanding -= 1;
        return true;
    }
    /// Refine one already-published completion's metadata after its Job ended.
    /// No allocation, new Job, text edit, or physical slot reuse. All other
    /// values and list order must remain byte-for-byte unchanged.
    pub fn refineCompletion(self: *Broker, ticket: Ticket, expected_generation: u64, index: usize, owned: *r.OwnedResult) !void {
        try self.enter();
        defer self.busy = false;
        if (self.stopping) return error.Closed;
        if (expected_generation != self.display_generation) return error.StaleDisplay;
        const generation = try self.nextDisplay();
        const previous = self.stored[@backingInt(r.Kind.completion)] orelse return error.StaleDisplay;
        if (!std.meta.eql(ticket, previous.ticket) or ticket.kind != .completion) return error.StaleDisplay;
        if (!try self.fresh(ticket) or try self.document.composition() != null) return error.StaleRevision;
        if (owned.storage == null) return error.ResultMoved;
        if (owned.data != .completion) return error.WrongResultKind;
        if (owned.storage.?.ptr == previous.result.storage.?.ptr) return error.InvalidRefinement;
        _ = try r.validate(owned.data, self.limits.results);
        const before = previous.result.data.completion;
        const after = owned.data.completion;
        if (index >= before.len or before.len != after.len) return error.InvalidRefinement;
        for (before, after, 0..) |left, right, at| {
            if (!std.mem.eql(u8, left.label, right.label) or !std.meta.eql(left.insertion, right.insertion) or left.edits.len != right.edits.len) return error.InvalidRefinement;
            for (left.edits, right.edits) |a, b| if (!std.meta.eql(a.range, b.range) or !std.mem.eql(u8, a.text, b.text)) return error.InvalidRefinement;
            if ((left.continuation == null) != (right.continuation == null)) return error.InvalidRefinement;
            if (left.continuation) |a| {
                const b = right.continuation.?;
                if (a.source != b.source or a.generation != b.generation or !std.mem.eql(u8, a.payload, b.payload)) return error.InvalidRefinement;
            }
            if (at != index and (!std.mem.eql(u8, left.detail, right.detail) or !std.mem.eql(u8, left.documentation, right.documentation))) return error.InvalidRefinement;
        }
        self.stored[@backingInt(r.Kind.completion)] = .{ .ticket = ticket, .result = owned.*, .position = previous.position };
        self.display_generation = generation;
        owned.storage = null;
        owned.data = .{ .completion = &.{} };
        var old = previous.result;
        old.deinit(); // Gate and newly published result cover the final free.
    }
    /// Explicit event/update invalidation. Completion tracks full revision;
    /// hover/diagnostics track committed text only. No guessed delta mapping.
    pub fn observe(self: *Broker) !void {
        try self.enter();
        defer self.busy = false;
        const revision = try self.document.version();
        const text_version = try self.document.committedTextVersion();
        var changed = false;
        for (self.stored) |item| if (item) |stored| if (!try self.fresh(stored.ticket)) {
            changed = true;
        };
        const generation = if (changed) try self.nextDisplay() else self.display_generation;
        for (self.slots) |*value| if (value.serial != 0 and (if (value.kind == .completion) value.revision != revision else value.text_version != text_version)) value.control.cancelled.store(true, .release);
        for (self.stored, 0..) |item, index| if (item) |stored| if (!try self.fresh(stored.ticket)) {
            self.drop(@fromBackingInt(@intCast(index)));
        };
        self.display_generation = generation;
    }
    /// Borrow only for the current owner-thread call. No allocation/reclamation.
    pub fn display(self: *const Broker, kind: r.Kind) !?Display {
        try self.check();
        return self.displayInner(kind);
    }
    fn displayInner(self: *const Broker, kind: r.Kind) !?Display {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.stopping) return error.Closed;
        const item = self.stored[@backingInt(kind)] orelse return null;
        if (!try self.fresh(item.ticket) or try self.document.composition() != null) return null;
        return .{ .ticket = item.ticket, .data = item.result.data, .position = item.position };
    }
    pub fn borrow(self: *Broker) !Borrow {
        try self.enter();
        if (self.stopping) {
            self.busy = false;
            return error.Closed;
        }
        return .{ .broker = self };
    }
    /// Lifetime-only borrow for a client's teardown after stop blocked ingress.
    /// display still returns Closed; this grants no new request permission.
    pub fn borrowForTeardown(self: *Broker) !Borrow {
        try self.enter();
        return .{ .broker = self };
    }
    /// Revoke the complete logical service view without stopping this Broker.
    /// Physical Job/Reader/delivery responsibilities remain until finish.
    pub fn invalidateAll(self: *Broker) !void {
        var reservation = try self.beginInvalidation();
        defer reservation.end();
        try reservation.commit();
    }
    pub fn beginInvalidation(self: *Broker) !Invalidation {
        try self.enter();
        errdefer self.busy = false;
        if (self.stopping) return error.Closed;
        const display_version = try self.nextDisplay();
        const invalidation = std.math.add(u64, self.invalidation_generation, 1) catch return error.IdExhausted;
        return .{ .broker = self, .display_version = display_version, .invalidation_version = invalidation };
    }
    fn applyInvalidation(self: *Broker, display_version: u64, invalidation: u64) void {
        // Publish the boundary before foreign result destructors run. enter
        // keeps every reentrant owner method Busy through their final free.
        self.display_generation = display_version;
        self.invalidation_generation = invalidation;
        const previous = self.stored;
        self.stored = @splat(null);
        self.current = @splat(0);
        for (self.slots) |*value| if (value.serial != 0) value.control.cancelled.store(true, .release);
        // Every logical kind is already invisible when the first foreign free
        // runs; the fixed three owning results need no temporary allocation.
        for (previous) |item| if (item) |stored| {
            var owned = stored.result;
            owned.deinit();
        };
    }
    pub fn stop(self: *Broker) !void {
        try self.enter();
        defer self.busy = false;
        self.stopping = true;
        for (self.slots) |*value| if (value.serial != 0) value.control.cancelled.store(true, .release);
        inline for (std.meta.tags(r.Kind)) |kind| self.revoke(kind);
    }
    pub fn retainClient(self: *Broker) !void {
        try self.check();
        if (self.stopping) return error.Closed;
        self.clients = std.math.add(usize, self.clients, 1) catch return error.CapacityExceeded;
    }
    pub fn releaseClient(self: *Broker) !void {
        try self.check();
        if (self.clients == 0) return error.ClientNotAttached;
        self.clients -= 1;
    }
    pub fn close(self: *Broker) !void {
        try self.check();
        if (self.clients != 0) return error.ClientsAlive;
        if (self.outstanding != 0) return error.JobsAlive;
        self.busy = true;
        errdefer self.busy = false;
        inline for (std.meta.tags(r.Kind)) |kind| self.drop(kind);
        try self.document.releaseClient();
        const allocator = self.allocator;
        allocator.free(self.slots);
        allocator.destroy(self);
    }
};

fn validateRange(snapshot: *const d.Snapshot, range: d.Range) !void {
    if (range.start > range.end) return error.InvalidRange;
    _ = try snapshot.utf16Offset(range.start);
    _ = try snapshot.utf16Offset(range.end);
}
fn validateResult(owned: *const r.OwnedResult, limits: r.Limits, snapshot: *const d.Snapshot) !void {
    if (try owned.byteLength() > limits.bytes) return error.CapacityExceeded;
    _ = try r.validate(owned.data, limits);
    switch (owned.data) {
        .completion => |items| {
            if (items.len > limits.completions) return error.CapacityExceeded;
            for (items) |item| {
                if (item.edits.len > limits.edits_per_completion) return error.CapacityExceeded;
                try r.validateEdits(item.edits);
                for (item.edits) |edit| {
                    try validateRange(snapshot, edit.range);
                    if (edit.text.len > limits.text_bytes) return error.CapacityExceeded;
                }
            }
        },
        .hover => |hover| {
            try validateRange(snapshot, hover.range);
            if (hover.text.len > limits.text_bytes) return error.CapacityExceeded;
        },
        .diagnostics => |items| {
            if (items.len > limits.diagnostics) return error.CapacityExceeded;
            for (items) |item| {
                try validateRange(snapshot, item.range);
                if (item.message.len > limits.text_bytes or item.source.len > limits.text_bytes) return error.CapacityExceeded;
            }
        },
    }
}

fn testDocument() !*d.Document {
    return d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc 😀\nxyz", .{});
}
test "done workers cannot free a Broker while an accepted result task still owns delivery" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{ .pending = 1 });
    var job = try broker.begin(.hover, 1);
    try std.testing.expectError(error.ClientAttached, doc.close());
    try std.testing.expectError(error.WorkerRunning, broker.finish(job.ticket));
    try job.release();
    try std.testing.expectError(error.JobClosed, job.release());
    try std.testing.expectError(error.JobsAlive, broker.close());
    var result = try r.OwnedResult.init(std.testing.allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 3 }, .text = "symbol" } }, job.limits);
    defer result.deinit();
    try broker.publish(job.ticket, &result);
    try std.testing.expect(result.storage == null);
    try std.testing.expectError(error.JobsAlive, broker.close());
    try std.testing.expect(try broker.finish(job.ticket));
    try std.testing.expect(!try broker.finish(job.ticket));
    try std.testing.expectEqualStrings("symbol", (try broker.display(.hover)).?.data.hover.text);
    try broker.close();
}
test "cancellation does not return worker or queued delivery capacity and old jobs cannot revive" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{ .pending = 1 });
    defer broker.close() catch unreachable;
    const old = try broker.begin(.completion, 2);
    try std.testing.expect(try broker.cancel(old.ticket));
    try std.testing.expect(try old.isCancelled());
    try std.testing.expectError(error.Full, broker.begin(.hover, 0));
    try old.release();
    try std.testing.expectError(error.Full, broker.begin(.hover, 0));
    try std.testing.expect(try broker.finish(old.ticket));
    const next = try broker.begin(.completion, 2);
    try std.testing.expectError(error.JobClosed, old.release());
    try std.testing.expect(!try broker.cancel(old.ticket));
    try std.testing.expect(!try next.isCancelled());
    try next.release();
    _ = try broker.finish(next.ticket);
}
test "selection preedit and text revisions reject stale owned results without consuming them" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.completion, 0);
    try job.release();
    _ = try doc.setSelection(.{ .anchor = 1, .caret = 1 });
    var result = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{.{ .label = "old", .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "old" }} }} }, .{});
    defer result.deinit();
    try std.testing.expectError(error.StaleRevision, broker.publish(job.ticket, &result));
    try std.testing.expect(result.storage != null);
    _ = try broker.finish(job.ticket);
    try doc.setComposition("preedit", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.CompositionActive, broker.begin(.completion, 1));
    _ = try doc.cancelComposition();
    const fresh = try broker.begin(.completion, 0);
    try fresh.release();
    try doc.replace(.{ .start = 0, .end = 0 }, "prefix");
    try std.testing.expectError(error.StaleRevision, broker.publish(fresh.ticket, &result));
    _ = try broker.finish(fresh.ticket);
}
test "result ranges validate UTF8 boundaries and failure keeps delivery responsibility" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.diagnostics, 0);
    try job.release();
    var result = try r.OwnedResult.init(std.testing.allocator, .{ .diagnostics = &.{.{ .range = .{ .start = 5, .end = 8 }, .message = "inside UTF8" }} }, .{});
    defer result.deinit();
    try std.testing.expectError(error.InvalidBoundary, broker.publish(job.ticket, &result));
    try std.testing.expect(result.storage != null);
    try std.testing.expectError(error.JobsAlive, broker.close());
    try broker.stop();
    try std.testing.expectError(error.Closed, broker.publish(job.ticket, &result));
    _ = try broker.finish(job.ticket);
}
test "worker reads immutable input concurrently with owner editing and releases before owner reclaims" {
    const Worker = struct {
        job: Job,
        ready: std.atomic.Value(bool) = .init(false),
        proceed: std.atomic.Value(bool) = .init(false),
        bytes: [32]u8 = undefined,
        length: usize = 0,
        fn run(self: *@This()) void {
            self.ready.store(true, .release);
            while (!self.proceed.load(.acquire)) std.Thread.yield() catch {};
            self.length = self.job.reader.read(.{ .start = 0, .end = self.job.reader.byteLength() catch unreachable }, &self.bytes) catch unreachable;
            std.debug.assert(self.job.isCancelled() catch unreachable);
            self.job.release() catch unreachable;
        }
    };
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    var worker: Worker = .{ .job = try broker.begin(.hover, 0) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.ready.load(.acquire)) std.Thread.yield() catch {};
    try doc.replace(.{ .start = 0, .end = 3 }, "changed");
    try broker.observe();
    try std.testing.expectError(error.JobsAlive, broker.close());
    worker.proceed.store(true, .release);
    thread.join();
    try std.testing.expectEqualStrings("abc 😀\nxyz", worker.bytes[0..worker.length]);
    try std.testing.expectError(error.JobsAlive, broker.close());
    _ = try broker.finish(worker.job.ticket);
}

test "producer cannot bypass narrower owner text policy and failure preserves old display" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{ .results = .{ .text_bytes = 4 } });
    defer broker.close() catch unreachable;
    const job = try broker.begin(.completion, 0);
    try job.release();
    const fields = [_]r.Completion{
        .{ .label = "large label", .edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "x" }} },
        .{ .label = "x", .detail = "large detail", .edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "x" }} },
        .{ .label = "x", .documentation = "large docs", .edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "x" }} },
    };
    for (fields) |item| {
        var result = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{item} }, .{});
        defer result.deinit();
        try std.testing.expectError(error.CapacityExceeded, broker.publish(job.ticket, &result));
        try std.testing.expect(result.storage != null);
        try std.testing.expect((try broker.display(.completion)) == null);
    }
    var good = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{.{ .label = "ok", .edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "ok" }} }} }, .{});
    defer good.deinit();
    try broker.publish(job.ticket, &good);
    _ = try broker.finish(job.ticket);
    const replacement = try broker.begin(.completion, 0);
    try replacement.release();
    var too_wide = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{fields[2]} }, .{});
    defer too_wide.deinit();
    try std.testing.expectError(error.CapacityExceeded, broker.publish(replacement.ticket, &too_wide));
    try std.testing.expect(too_wide.storage != null);
    try std.testing.expectEqualStrings("ok", (try broker.display(.completion)).?.data.completion[0].label);
    _ = try broker.finish(replacement.ticket);
    const scope = try broker.borrow();
    try std.testing.expectError(error.Busy, broker.begin(.completion, 1));
    try std.testing.expectError(error.Busy, broker.close());
    try std.testing.expectEqualStrings("ok", (try scope.display(.completion)).?.data.completion[0].label);
    scope.end();
}

test "diagnostics survive caret and IME preview changes but committed edits invalidate them" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.diagnostics, 0);
    _ = try doc.setSelection(.{ .anchor = 1, .caret = 1 });
    try doc.setComposition("x", .{ .anchor = 1, .caret = 1 });
    try job.release();
    var result = try r.OwnedResult.init(std.testing.allocator, .{ .diagnostics = &.{.{ .range = .{ .start = 0, .end = 3 }, .message = "diagnostic" }} }, .{});
    defer result.deinit();
    try broker.publish(job.ticket, &result);
    _ = try broker.finish(job.ticket);
    try std.testing.expect((try broker.display(.diagnostics)) == null);
    const generation = broker.display_generation;
    try broker.observe();
    _ = try doc.cancelComposition();
    try broker.observe();
    try std.testing.expectEqual(generation, broker.display_generation);
    try std.testing.expectEqualStrings("diagnostic", (try broker.display(.diagnostics)).?.data.diagnostics[0].message);
    try doc.replace(.{ .start = 0, .end = 0 }, "!");
    try std.testing.expect((try broker.display(.diagnostics)) == null);
    try broker.observe();
    try std.testing.expect(broker.display_generation > generation);
}

fn allocationFixture(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "input", .{});
    defer doc.close() catch unreachable;
    const broker = try Broker.create(allocator, doc, .{ .pending = 2 });
    defer broker.close() catch unreachable;
    const old = try broker.begin(.hover, 0);
    defer _ = broker.finish(old.ticket) catch unreachable;
    try old.release();
    var result = try r.OwnedResult.init(allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 5 }, .text = "input" } }, .{});
    defer result.deinit();
    try broker.publish(old.ticket, &result);
    const next = try broker.begin(.completion, 1);
    try next.release();
    _ = try broker.finish(next.ticket);
}
test "all request snapshot result and owner allocations roll back without reader or client leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}

test "serial and display exhaustion reject before changing the previous request" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.hover, 0);
    broker.next_serial = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.begin(.hover, 1));
    try std.testing.expect(!try job.isCancelled());
    broker.display_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.cancel(job.ticket));
    try std.testing.expect(!try job.isCancelled());
    try job.release();
    _ = try broker.finish(job.ticket);
}

test "only linear job input and result construction cross the owner thread boundary" {
    const Worker = struct {
        broker: *Broker,
        passed: bool = false,
        fn run(self: *@This()) void {
            std.testing.expectError(error.WrongThread, self.broker.begin(.hover, 0)) catch return;
            std.testing.expectError(error.WrongThread, self.broker.display(.diagnostics)) catch return;
            std.testing.expectError(error.WrongThread, self.broker.stop()) catch return;
            std.testing.expectError(error.WrongThread, self.broker.close()) catch return;
            self.passed = true;
        }
    };
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    var worker: Worker = .{ .broker = broker };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expect(worker.passed and !broker.stopping);
}

test "snippet delivery retains explicit raw format under the same revision and cancellation gates" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const Worker = struct {
        job: Job,
        result: ?r.OwnedResult = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = r.OwnedResult.init(std.heap.page_allocator, .{ .completion = &.{.{ .label = "explicit format", .insertion = .{ .snippet = 0 }, .edits = &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "${NAME}" }} }} }, self.job.limits) catch |err| {
                self.failure = err;
                self.job.release() catch unreachable;
                return;
            };
            self.job.release() catch unreachable;
        }
    };
    var worker: Worker = .{ .job = try broker.begin(.completion, 0) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    defer worker.result.?.deinit();
    try broker.publish(worker.job.ticket, &worker.result.?);
    _ = try broker.finish(worker.job.ticket);
    try std.testing.expect(worker.result.?.storage == null);
    const display = (try broker.display(.completion)).?;
    try std.testing.expectEqual(@as(usize, 0), display.data.completion[0].insertion.snippet);
    // Broker delivers text, not parser policy. Rejection belongs to acceptance.
    try std.testing.expectEqualStrings("${NAME}", display.data.completion[0].edits[0].text);
    _ = try doc.setSelection(.{});
    try std.testing.expect((try broker.display(.completion)) == null);
    try broker.observe();
    try std.testing.expect(broker.stored[@backingInt(r.Kind.completion)] == null);
    const cancelled = try broker.begin(.completion, 0);
    _ = try broker.cancel(cancelled.ticket);
    try cancelled.release();
    var owned = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{.{ .label = "late", .insertion = .{ .snippet = 0 }, .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "$1" }} }} }, .{});
    defer owned.deinit();
    try std.testing.expectError(error.Cancelled, broker.publish(cancelled.ticket, &owned));
    try std.testing.expect(owned.storage != null);
    _ = try broker.finish(cancelled.ticket);
}

const InvalidationFree = struct {
    broker: *Broker,
    calls: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.broker.busy);
        std.testing.expectError(error.Busy, self.broker.close()) catch unreachable;
        std.testing.expectError(error.Busy, self.broker.invalidateAll()) catch unreachable;
        std.testing.expectError(error.Busy, self.broker.stop()) catch unreachable;
        std.testing.expectError(error.Busy, self.broker.display(.hover)) catch unreachable;
        self.calls += 1;
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
test "service invalidation revokes finished stored results and late jobs atomically with destructor reentry" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    var hook: InvalidationFree = .{ .broker = broker };
    const old = try broker.begin(.hover, 0);
    try old.release();
    var result = try r.OwnedResult.init(hook.allocator(), .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "finished" } }, .{});
    defer result.deinit();
    try broker.publish(old.ticket, &result);
    _ = try broker.finish(old.ticket);
    try std.testing.expect(!try broker.cancel(old.ticket));
    const pending = try broker.begin(.completion, 0);
    const generation = broker.display_generation;
    broker.invalidation_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.invalidateAll());
    try std.testing.expectEqual(generation, broker.display_generation);
    try std.testing.expect(!try pending.isCancelled());
    try std.testing.expect((try broker.display(.hover)) != null);
    broker.invalidation_generation = 0;
    broker.display_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.invalidateAll());
    try std.testing.expect(!try pending.isCancelled());
    broker.display_generation = generation;
    const borrow = try broker.borrow();
    try std.testing.expectError(error.Busy, broker.invalidateAll());
    borrow.end();
    try broker.invalidateAll();
    try std.testing.expectEqual(@as(u64, 1), broker.invalidation_generation);
    try std.testing.expectEqual(@as(usize, 1), hook.calls);
    try std.testing.expect((try broker.display(.hover)) == null and try pending.isCancelled());
    try pending.release();
    var late = try r.OwnedResult.init(std.testing.allocator, .{ .completion = &.{} }, .{});
    defer late.deinit();
    try std.testing.expectError(error.Cancelled, broker.publish(pending.ticket, &late));
    _ = try broker.finish(pending.ticket);
    const fresh = try broker.begin(.hover, 0);
    try fresh.release();
    var next = try r.OwnedResult.init(std.testing.allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "fresh" } }, .{});
    defer next.deinit();
    try broker.publish(fresh.ticket, &next);
    _ = try broker.finish(fresh.ticket);
    try std.testing.expectEqualStrings("fresh", (try broker.display(.hover)).?.data.hover.text);
}

test "invalidation reservation preflights all gates and rejection has no effects" {
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(std.testing.allocator, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.hover, 0);
    defer {
        job.release() catch unreachable;
        _ = broker.finish(job.ticket) catch unreachable;
    }
    const display = broker.display_generation;
    var cancelled = try broker.beginInvalidation();
    try std.testing.expectError(error.Busy, broker.beginInvalidation());
    try std.testing.expectError(error.Busy, broker.borrow());
    try std.testing.expectError(error.Busy, broker.stop());
    cancelled.end();
    cancelled.end();
    try std.testing.expectEqual(display, broker.display_generation);
    try std.testing.expectEqual(@as(u64, 0), broker.invalidation_generation);
    try std.testing.expect(!try job.isCancelled());
    broker.display_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.beginInvalidation());
    try std.testing.expect(!broker.busy and !try job.isCancelled());
    broker.display_generation = display;
    var accepted = try broker.beginInvalidation();
    try accepted.commitRetained();
    try std.testing.expect(broker.busy and try job.isCancelled());
    try std.testing.expectError(error.ScopeCommitted, accepted.commitRetained());
    accepted.end();
    try std.testing.expectError(error.ScopeClosed, accepted.commit());
}

test "completion refinement after job finish changes metadata only and preserves failed candidates" {
    const a = std.testing.allocator;
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const job = try broker.begin(.completion, 0);
    try job.release();
    var original = try r.OwnedResult.init(a, .{ .completion = &.{.{ .label = "item", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "item" }} }} }, .{});
    defer original.deinit();
    try broker.publish(job.ticket, &original);
    _ = try broker.finish(job.ticket);
    const generation = broker.display_generation;
    var changed = try r.OwnedResult.init(a, .{ .completion = &.{.{ .label = "item", .detail = "resolved", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "different" }} }} }, .{});
    defer changed.deinit();
    try std.testing.expectError(error.InvalidRefinement, broker.refineCompletion(job.ticket, generation, 0, &changed));
    try std.testing.expect(changed.storage != null and broker.display_generation == generation);
    var candidate = try r.OwnedResult.init(a, .{ .completion = &.{.{ .label = "item", .detail = "resolved", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "item" }} }} }, .{});
    defer candidate.deinit();
    broker.display_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, broker.refineCompletion(job.ticket, std.math.maxInt(u64), 0, &candidate));
    try std.testing.expect(candidate.storage != null);
    broker.display_generation = generation;
    try broker.refineCompletion(job.ticket, generation, 0, &candidate);
    try std.testing.expect(candidate.storage == null);
    try std.testing.expectEqualStrings("resolved", (try broker.display(.completion)).?.data.completion[0].detail);
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    try std.testing.expectError(error.StaleDisplay, broker.refineCompletion(job.ticket, generation, 0, &changed));
}

test "completion refinement rejects every nonmetadata identity edit and list mutation before publication" {
    const a = std.testing.allocator;
    const doc = try testDocument();
    defer doc.close() catch unreachable;
    const broker = try Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const items = [_]r.Completion{
        .{ .label = "a", .edits = &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "$1" }}, .insertion = .{ .snippet = 0 }, .continuation = .{ .source = 3, .generation = 7, .payload = "{\"data\":1}" } },
        .{ .label = "b", .detail = "other", .documentation = "original", .edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "b" }} },
    };
    const job = try broker.begin(.completion, 0);
    try job.release();
    var original = try r.OwnedResult.init(a, .{ .completion = &items }, .{});
    defer original.deinit();
    try broker.publish(job.ticket, &original);
    _ = try broker.finish(job.ticket);
    const generation = broker.display_generation;
    for (0..10) |change| {
        var changed = items;
        changed[0].detail = "resolved";
        switch (change) {
            0 => changed[0].label = "changed",
            1 => changed[0].insertion = .plain,
            2 => changed[0].edits = &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "$1" }},
            3 => changed[0].continuation = null,
            4 => changed[0].continuation.?.source += 1,
            5 => changed[0].continuation.?.generation += 1,
            6 => changed[0].continuation.?.payload = "{\"data\":2}",
            7 => changed[1].detail = "wrong item",
            8 => changed[1].documentation = "wrong item",
            9 => std.mem.swap(r.Completion, &changed[0], &changed[1]),
            else => unreachable,
        }
        var candidate = try r.OwnedResult.init(a, .{ .completion = &changed }, .{});
        defer candidate.deinit();
        try std.testing.expectError(error.InvalidRefinement, broker.refineCompletion(job.ticket, generation, 0, &candidate));
        try std.testing.expect(candidate.storage != null);
        try std.testing.expectEqual(generation, broker.display_generation);
        try std.testing.expectEqualStrings("", (try broker.display(.completion)).?.data.completion[0].detail);
    }
}
