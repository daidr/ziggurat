const std = @import("std");

/// Resource head occupies IPC sequence 1; body sequence N is wire N+1.
/// This supplements, and does not replace, Router session/token validation.
pub const Sequence = struct {
    closed: bool = false,
    sent: u32 = 0,
    acknowledged: u32 = 0,
    candidate: ?u32 = null,
    sending: bool = false,
    deferred_ack: ?u32 = null,

    pub fn nextWire(self: *const Sequence, body_sequence: ?u32) !u32 {
        if (self.closed) return error.Closed;
        if (self.candidate != null or self.sending) return error.PacketHeld;
        if (body_sequence) |body| {
            if (self.sent == 0 or body != self.sent or body > std.math.maxInt(u32) - 2) return error.InvalidSequence;
            return body + 1;
        }
        if (self.sent != 0) return error.HeadAlreadySent;
        return 1;
    }
    /// Call after a packet was encoded successfully, before any transport call.
    /// Allocation failure must never call this or advance Router credit.
    pub fn encoded(self: *Sequence, body_sequence: ?u32) !u32 {
        const wire = try self.nextWire(body_sequence);
        self.candidate = wire;
        return wire;
    }
    pub fn beginSend(self: *Sequence) !u32 {
        if (self.closed) return error.Closed;
        if (self.sending) return error.ReentrantSend;
        const wire = self.candidate orelse return error.NoPacket;
        self.sending = true;
        return wire;
    }
    /// A validated reentrant ACK for the in-progress send is held until native
    /// acceptance and Delivery.commit. The UI never exposes that credit early.
    /// Returns the cumulative BODY acknowledgement to apply, including zero
    /// for a head-only ACK. null means duplicate or still deferred.
    pub fn acknowledge(self: *Sequence, wire: u32) !?u32 {
        if (self.closed) return error.Closed;
        if (wire < self.acknowledged) return error.InvalidAck;
        if (wire == self.acknowledged) return null;
        if (wire > self.sent) {
            if (!self.sending or self.candidate != wire) return error.InvalidAck;
            self.deferred_ack = wire;
            return null;
        }
        self.acknowledged = wire;
        return wire - 1;
    }
    /// On accepted body delivery, commit its Control.Delivery BEFORE this call.
    /// Rejection retains the same encoded candidate. Rejection after an ACK is
    /// a transport contract violation: close this protocol instead of retrying.
    pub fn endSend(self: *Sequence, accepted: bool) !?u32 {
        if (self.closed) return error.Closed;
        if (!self.sending) return error.NotSending;
        self.sending = false;
        const wire = self.candidate.?;
        if (!accepted) {
            if (self.deferred_ack != null) {
                self.close();
                return error.TransportContractViolation;
            }
            return null;
        }
        self.sent = wire;
        self.candidate = null;
        if (self.deferred_ack) |ack| {
            self.deferred_ack = null;
            return self.acknowledge(ack);
        }
        return null;
    }
    pub fn terminalAllowed(self: *const Sequence, body_drained: bool) bool {
        return !self.closed and self.acknowledged != 0 and self.acknowledged == self.sent and self.candidate == null and !self.sending and body_drained;
    }
    pub fn close(self: *Sequence) void {
        self.closed = true;
        self.sending = false;
        self.candidate = null;
        self.deferred_ack = null;
    }
};

test "metadata-only and empty body terminal wait for the head ACK" {
    var flow: Sequence = .{};
    try std.testing.expect(!flow.terminalAllowed(true));
    try std.testing.expectEqual(1, try flow.encoded(null));
    _ = try flow.beginSend();
    try std.testing.expect((try flow.endSend(true)) == null);
    try std.testing.expect(!flow.terminalAllowed(true));
    try std.testing.expectEqual(@as(?u32, 0), try flow.acknowledge(1));
    try std.testing.expect(flow.terminalAllowed(true));
    try std.testing.expect((try flow.acknowledge(1)) == null);
}

test "body ACK maps wire N+1 and reentrant send ACK cannot release a held slab" {
    var flow: Sequence = .{};
    _ = try flow.encoded(null);
    _ = try flow.beginSend();
    try std.testing.expect((try flow.acknowledge(1)) == null);
    try std.testing.expectEqual(0, flow.acknowledged);
    try std.testing.expectEqual(@as(?u32, 0), try flow.endSend(true));
    _ = try flow.encoded(1);
    _ = try flow.beginSend();
    try std.testing.expect((try flow.acknowledge(2)) == null);
    try std.testing.expectEqual(1, flow.acknowledged);
    try std.testing.expect(!flow.terminalAllowed(true));
    try std.testing.expectEqual(@as(?u32, 1), try flow.endSend(true));
    try std.testing.expect(flow.terminalAllowed(true));
    try std.testing.expectError(error.InvalidAck, flow.acknowledge(1));
}

test "transport rejection retains one candidate and future ACK cannot invent credit" {
    var flow: Sequence = .{};
    _ = try flow.encoded(null);
    try std.testing.expectError(error.InvalidAck, flow.acknowledge(1));
    _ = try flow.beginSend();
    try std.testing.expect((try flow.endSend(false)) == null);
    try std.testing.expectEqual(@as(?u32, 1), flow.candidate);
    try std.testing.expectError(error.PacketHeld, flow.encoded(null));
    try std.testing.expectEqual(1, try flow.beginSend());
    _ = try flow.acknowledge(1);
    try std.testing.expectError(error.TransportContractViolation, flow.endSend(false));
    try std.testing.expect(flow.closed and !flow.terminalAllowed(true));
}

test "close during transport keeps old credit closed and cannot revive a candidate" {
    var flow: Sequence = .{};
    _ = try flow.encoded(null);
    _ = try flow.beginSend();
    _ = try flow.acknowledge(1);
    flow.close();
    try std.testing.expectError(error.Closed, flow.endSend(true));
    try std.testing.expectError(error.Closed, flow.acknowledge(1));
    try std.testing.expectEqual(0, flow.acknowledged);
    try std.testing.expectEqual(0, flow.sent);
}

test "head and reentrant body ACK do not free actual producer slabs before commit" {
    const bytes = @import("control.zig");
    const control = try bytes.Control.create(std.testing.allocator, .{ .slots = 1, .chunk_bytes = 1 });
    defer control.deinit();
    var source = try control.writer();
    var writer = try source.take();
    defer writer.deinit();
    try std.testing.expectError(error.Released, source.take());
    try std.testing.expect(!control.endpointsReleased());
    _ = try writer.tryWrite("a");
    var flow: Sequence = .{};
    _ = try flow.encoded(null);
    _ = try flow.beginSend();
    _ = try flow.endSend(true);
    try std.testing.expectEqual(@as(?u32, 0), try flow.acknowledge(1));
    try std.testing.expectError(error.Full, writer.tryWrite("b"));
    var original = (try control.take()).?;
    var delivery = try original.take();
    defer delivery.deinit();
    try std.testing.expectError(error.Released, original.take());
    _ = try flow.encoded(delivery.sequence);
    _ = try flow.beginSend();
    try std.testing.expect((try flow.acknowledge(2)) == null);
    try std.testing.expectError(error.Full, writer.tryWrite("b"));
    try delivery.commit();
    const body_ack = (try flow.endSend(true)).?;
    try std.testing.expectEqual(1, try control.acknowledge(body_ack));
    _ = try writer.tryWrite("b");
    writer.deinit();
    try std.testing.expect(control.endpointsReleased());
}
