const std = @import("std");

/// Independent SPSC byte storage. The UI owns delivery and acknowledgement;
/// one linear Writer owns production. No App, View, transport or COM is stored.
pub const Limits = struct {
    slots: u8 = 4,
    chunk_bytes: u16 = 16 * 1024,
    max_chunks: u32 = 1_000_000,
    max_total_bytes: u64 = 256 * 1024 * 1024,
    allow_body: bool = true,

    pub fn validate(self: Limits) !void {
        if (self.slots == 0 or self.slots > 16 or self.chunk_bytes == 0 or self.chunk_bytes > 16 * 1024 or self.max_chunks == 0 or self.max_chunks > std.math.maxInt(u32) - 2 or self.max_total_bytes == 0 or self.max_total_bytes > (1 << 53) - 1) return error.InvalidLimits;
    }
    pub fn allocationBytes(self: Limits) !usize {
        try self.validate();
        return @sizeOf(Control) + @as(usize, self.slots) * (@sizeOf(Slot) + self.chunk_bytes);
    }
};

pub const Reason = enum(u8) { none, cancelled, closed, page_changed, transport_failed, writer_dropped, delivery_dropped };
const State = enum(u8) { free, filling, queued, held, sent };
const Slot = struct {
    state: std.atomic.Value(State) = .init(.free),
    sequence: u32 = 0,
    length: u16 = 0,
};

pub const Control = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    limits: Limits,
    slots: []Slot,
    storage: []u8,
    refs: std.atomic.Value(u32) = .init(1),
    cancelled: std.atomic.Value(Reason) = .init(.none),
    wake_sequence: std.atomic.Value(u32) = .init(0),
    produced: std.atomic.Value(u32) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    writer_taken: bool = false,
    delivery_held: bool = false,
    sent: u32 = 0,
    acknowledged: u32 = 0,

    /// Allocator and its context must support concurrent calls and outlive the
    /// owner, Writer and Delivery. The last release may run on a worker.
    pub fn create(allocator: std.mem.Allocator, limits: Limits) !*Control {
        try limits.validate();
        const self = try allocator.create(Control);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, limits.slots);
        errdefer allocator.free(slots);
        const storage = try allocator.alloc(u8, @as(usize, limits.slots) * limits.chunk_bytes);
        for (slots) |*slot| slot.* = .{};
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .limits = limits, .slots = slots, .storage = storage };
        return self;
    }
    fn assertOwner(self: *const Control) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
    }
    fn retain(self: *Control) void {
        const before = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(before != 0 and before < 4);
    }
    fn release(self: *Control) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        allocator.free(self.storage);
        allocator.free(self.slots);
        allocator.destroy(self);
    }
    /// Releases the UI owner, cancelling ingress without reclaiming storage
    /// still retained by a Writer or Delivery. Call once; do not copy owners.
    pub fn deinit(self: *Control) void {
        self.assertOwner();
        self.cancel(.closed);
        self.release();
    }
    pub fn writer(self: *Control) !Writer {
        self.assertOwner();
        if (self.reason() != .none) return error.Closed;
        if (self.writer_taken) return error.WriterTaken;
        self.writer_taken = true;
        self.retain();
        return .{ .control = self };
    }
    pub fn reason(self: *const Control) Reason {
        return self.cancelled.load(.acquire);
    }
    /// Nonblocking on every thread; the first cancellation reason wins.
    pub fn cancel(self: *Control, reason_value: Reason) void {
        std.debug.assert(reason_value != .none);
        if (self.cancelled.cmpxchgStrong(.none, reason_value, .acq_rel, .acquire) == null) self.wake();
    }
    fn wake(self: *Control) void {
        // There can be at most max_chunks distinct ACK advances and one cancel.
        const previous = self.wake_sequence.fetchAdd(1, .release);
        std.debug.assert(previous < std.math.maxInt(u32));
        std.Thread.Futex.wake(&self.wake_sequence, 1);
    }
    /// At most one held delivery. Encoding/transport rejection retains that
    /// Delivery for retry of the same packet, or explicit stream cancellation.
    pub fn take(self: *Control) !?Delivery {
        self.assertOwner();
        if (self.reason() != .none) return error.Closed;
        if (self.delivery_held) return error.DeliveryHeld;
        const index = self.sent % self.slots.len;
        const slot = &self.slots[index];
        if (slot.state.load(.acquire) != .queued) return null;
        std.debug.assert(slot.sequence == self.sent + 1);
        slot.state.store(.held, .release);
        self.delivery_held = true;
        self.retain();
        return .{ .control = self, .index = index, .sequence = slot.sequence, .bytes = self.storage[index * self.limits.chunk_bytes ..][0..slot.length] };
    }
    /// Call only after the protocol layer validates this body's cumulative
    /// ACK. No transport acceptance, duplicate ACK or EOF returns credit.
    pub fn acknowledge(self: *Control, sequence: u32) !u32 {
        self.assertOwner();
        if (self.reason() != .none) return error.Closed;
        if (sequence < self.acknowledged or sequence > self.sent) return error.InvalidAck;
        if (sequence == self.acknowledged) return 0;
        var cursor = self.acknowledged;
        while (cursor < sequence) : (cursor += 1) {
            const slot = &self.slots[cursor % self.slots.len];
            if (slot.state.load(.acquire) != .sent or slot.sequence != cursor + 1) return error.InvalidAck;
        }
        cursor = self.acknowledged;
        while (cursor < sequence) : (cursor += 1) self.slots[cursor % self.slots.len].state.store(.free, .release);
        const count = sequence - self.acknowledged;
        self.acknowledged = sequence;
        self.wake();
        return count;
    }
    pub fn drained(self: *const Control) bool {
        self.assertOwner();
        return self.reason() == .none and self.finished.load(.acquire) and self.acknowledged == self.produced.load(.acquire);
    }
    /// Closing the UI binding may reclaim it only after the worker endpoint
    /// and every held delivery have surrendered their independent ownership.
    pub fn endpointsReleased(self: *const Control) bool {
        self.assertOwner();
        return self.refs.load(.acquire) == 1;
    }
};

/// A noncopyable producer endpoint. Before first production it may move to a
/// worker. Subsequent production/wait/finish stays on that one thread.
pub const Writer = struct {
    control: ?*Control,
    producer: ?std.Thread.Id = null,
    sequence: u32 = 0,
    total_bytes: u64 = 0,
    finished: bool = false,

    pub fn take(self: *Writer) !Writer {
        const control = self.control orelse return error.Released;
        self.control = null;
        return .{ .control = control, .producer = self.producer, .sequence = self.sequence, .total_bytes = self.total_bytes, .finished = self.finished };
    }

    fn current(self: *Writer) !*Control {
        const control = self.control orelse return error.Released;
        if (control.reason() != .none) return error.Closed;
        if (self.finished) return error.Finished;
        const current_thread = std.Thread.getCurrentId();
        if (self.producer) |producer| {
            if (producer != current_thread) return error.WrongProducerThread;
        } else self.producer = current_thread;
        return control;
    }
    /// Copies one bounded, nonempty chunk. Any failure consumes no bytes and
    /// leaves sequence/total unchanged; caller still owns its entire input.
    pub fn tryWrite(self: *Writer, bytes: []const u8) !u32 {
        const control = try self.current();
        if (!control.limits.allow_body) return error.UnexpectedBody;
        if (bytes.len == 0 or bytes.len > control.limits.chunk_bytes) return error.InvalidChunk;
        if (self.sequence == control.limits.max_chunks) return error.ChunkLimit;
        if (bytes.len > control.limits.max_total_bytes - self.total_bytes) return error.ByteLimit;
        const index = self.sequence % control.slots.len;
        const slot = &control.slots[index];
        if (slot.state.load(.acquire) != .free) return error.Full;
        slot.state.store(.filling, .release);
        @memcpy(control.storage[index * control.limits.chunk_bytes ..][0..bytes.len], bytes);
        if (control.reason() != .none) {
            slot.state.store(.free, .release);
            return error.Closed;
        }
        const sequence = self.sequence + 1;
        slot.sequence = sequence;
        slot.length = @intCast(bytes.len);
        self.total_bytes += bytes.len;
        self.sequence = sequence;
        control.total_bytes.store(self.total_bytes, .monotonic);
        control.produced.store(sequence, .release);
        slot.state.store(.queued, .release);
        return sequence;
    }
    /// Explicit worker wait, never a UI wait. Sequence-before-recheck prevents
    /// a returned ACK/cancel from being lost between the predicate and futex.
    pub fn waitWritable(self: *Writer) !void {
        const raw = self.control orelse return error.Released;
        if (std.Thread.getCurrentId() == raw.owner) return error.MainThreadForbidden;
        const control = try self.current();
        while (true) {
            const observed = control.wake_sequence.load(.acquire);
            if (control.reason() != .none) return error.Closed;
            if (self.sequence == control.limits.max_chunks) return error.ChunkLimit;
            if (self.total_bytes == control.limits.max_total_bytes) return error.ByteLimit;
            if (control.slots[self.sequence % control.slots.len].state.load(.acquire) == .free) return;
            std.Thread.Futex.wait(&control.wake_sequence, observed);
        }
    }
    /// EOF does not release slots. The UI can send its terminal result only
    /// after drained() confirms every accepted chunk has been acknowledged.
    pub fn finish(self: *Writer) !void {
        const control = try self.current();
        self.finished = true;
        control.finished.store(true, .release);
    }
    pub fn deinit(self: *Writer) void {
        const control = self.control orelse return;
        self.control = null;
        if (!self.finished) control.cancel(.writer_dropped);
        control.release();
    }
};

/// Noncopyable UI owner of a held slab. Keep it through encoding and transport
/// rejection. Successful commit releases only this handle, not ACK credit.
pub const Delivery = struct {
    control: ?*Control,
    index: usize,
    sequence: u32,
    bytes: []const u8,

    pub fn take(self: *Delivery) !Delivery {
        const control = self.control orelse return error.Released;
        const pointer = self.bytes.ptr;
        const length = self.bytes.len;
        self.control = null;
        self.bytes = &.{};
        return .{ .control = control, .index = self.index, .sequence = self.sequence, .bytes = pointer[0..length] };
    }

    pub fn commit(self: *Delivery) !void {
        const control = self.control orelse return error.Released;
        control.assertOwner();
        if (control.reason() != .none) return error.Closed;
        std.debug.assert(control.delivery_held and control.sent + 1 == self.sequence);
        control.slots[self.index].state.store(.sent, .release);
        control.sent = self.sequence;
        control.delivery_held = false;
        self.control = null;
        self.bytes = &.{};
        control.release();
    }
    pub fn deinit(self: *Delivery) void {
        const control = self.control orelse return;
        control.assertOwner();
        self.control = null;
        self.bytes = &.{};
        control.cancel(.delivery_dropped);
        control.delivery_held = false;
        control.release();
    }
};

test "bounded slabs require ACK and preserve bytes through encoding retry and EOF" {
    const control = try Control.create(std.testing.allocator, .{ .slots = 2, .chunk_bytes = 4 });
    defer control.deinit();
    var writer = try control.writer();
    defer writer.deinit();
    try std.testing.expectError(error.WriterTaken, control.writer());
    try std.testing.expectEqual(1, try writer.tryWrite("abcd"));
    try std.testing.expectEqual(2, try writer.tryWrite("ef"));
    try std.testing.expectError(error.Full, writer.tryWrite("x"));
    var first = (try control.take()).?;
    defer first.deinit();
    try std.testing.expectEqualStrings("abcd", first.bytes);
    try std.testing.expectError(error.DeliveryHeld, control.take());
    try std.testing.expectError(error.InvalidAck, control.acknowledge(1));
    try std.testing.expectEqualStrings("abcd", first.bytes);
    try first.commit();
    var second = (try control.take()).?;
    defer second.deinit();
    try second.commit();
    try std.testing.expectError(error.Full, writer.tryWrite("x"));
    try std.testing.expectError(error.InvalidAck, control.acknowledge(3));
    try std.testing.expectEqual(1, try control.acknowledge(1));
    try std.testing.expectEqual(0, try control.acknowledge(1));
    try std.testing.expectEqual(3, try writer.tryWrite("gh"));
    var third = (try control.take()).?;
    defer third.deinit();
    try std.testing.expectEqualStrings("gh", third.bytes);
    try third.commit();
    try writer.finish();
    try std.testing.expect(!control.drained());
    try std.testing.expectEqual(2, try control.acknowledge(3));
    try std.testing.expect(control.drained());
    try std.testing.expectError(error.InvalidAck, control.acknowledge(2));
}

test "invalid chunks limits and cancellation retain producer position without wrap" {
    const control = try Control.create(std.testing.allocator, .{ .slots = 1, .chunk_bytes = 4, .max_chunks = 2, .max_total_bytes = 5 });
    defer control.deinit();
    var writer = try control.writer();
    defer writer.deinit();
    try std.testing.expectError(error.MainThreadForbidden, writer.waitWritable());
    try std.testing.expectError(error.InvalidChunk, writer.tryWrite(""));
    try std.testing.expectError(error.InvalidChunk, writer.tryWrite("abcde"));
    _ = try writer.tryWrite("abcd");
    try std.testing.expectError(error.ByteLimit, writer.tryWrite("ef"));
    var first = (try control.take()).?;
    defer first.deinit();
    try first.commit();
    _ = try control.acknowledge(1);
    _ = try writer.tryWrite("e");
    try std.testing.expectError(error.ChunkLimit, writer.tryWrite("f"));
    try std.testing.expectEqual(2, writer.sequence);
    try std.testing.expectEqual(5, writer.total_bytes);
    control.cancel(.page_changed);
    control.cancel(.closed);
    try std.testing.expectEqual(Reason.page_changed, control.reason());
    try std.testing.expectError(error.Closed, writer.finish());
    try std.testing.expectError(error.Closed, control.take());
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    const control = try Control.create(allocator, .{});
    var writer = try control.writer();
    var delivery: ?Delivery = null;
    _ = try writer.tryWrite("owned");
    delivery = (try control.take()).?;
    // Release owner first: neither held bytes nor writer storage may be freed.
    control.deinit();
    try std.testing.expectEqualStrings("owned", delivery.?.bytes);
    try std.testing.expectError(error.Closed, delivery.?.commit());
    delivery.?.deinit();
    writer.deinit();
}
test "all allocation failures and owners released before held delivery are safe" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
    try std.testing.expectError(error.InvalidLimits, (Limits{ .max_chunks = std.math.maxInt(u32) }).validate());
    try std.testing.expectError(error.InvalidLimits, (Limits{ .slots = 17 }).validate());
}

const WaitProbe = struct {
    writer: Writer,
    ready: std.Thread.ResetEvent = .{},
    outcome: ?anyerror = null,
    wrote: bool = false,
    fn run(self: *WaitProbe) void {
        defer self.writer.deinit();
        _ = self.writer.tryWrite("a") catch |err| {
            self.outcome = err;
            self.ready.set();
            return;
        };
        self.ready.set();
        self.writer.waitWritable() catch |err| {
            self.outcome = err;
            return;
        };
        _ = self.writer.tryWrite("b") catch |err| {
            self.outcome = err;
            return;
        };
        self.wrote = true;
        self.writer.finish() catch |err| {
            self.outcome = err;
        };
    }
};
test "ACK and cancellation wake an explicit worker even before it enters futex wait" {
    for (0..2) |index| {
        const control = try Control.create(std.testing.allocator, .{ .slots = 1, .chunk_bytes = 1 });
        var probe: WaitProbe = .{ .writer = try control.writer() };
        const thread = try std.Thread.spawn(.{}, WaitProbe.run, .{&probe});
        probe.ready.wait(); // Test harness synchronization, no App/native loop.
        if (index == 0) {
            var delivery = (try control.take()).?;
            try delivery.commit();
            _ = try control.acknowledge(1);
            thread.join();
            try std.testing.expect(probe.outcome == null and probe.wrote);
            var second = (try control.take()).?;
            try std.testing.expectEqualStrings("b", second.bytes);
            try second.commit();
            _ = try control.acknowledge(2);
            try std.testing.expect(control.drained());
            control.deinit();
        } else {
            control.deinit(); // Worker retains Control and its own wait address.
            thread.join();
            try std.testing.expectEqual(error.Closed, probe.outcome.?);
            try std.testing.expect(!probe.wrote);
        }
    }
}
