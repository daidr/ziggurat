const std = @import("std");

/// Owner-thread authority only; no text, selection, geometry or lifetime owner.
/// Storage stays stable until the sole publisher has released its borrow and
/// every input reader using it has returned. The owner may withdraw at any time.
pub const Lease = struct {
    pub const Stamp = struct {
        publication: u64,
        source: u64,
        candidate: u64,
        space_epoch: u64,
        space_generation: u64,
    };
    pub const Snapshot = struct { generation: u64, stamp: Stamp };

    generation: u64 = 0,
    publisher: u64 = 0,
    accepted: ?Stamp = null,
    pending: ?Stamp = null,

    /// A single explicit publisher borrows this stable address. Failed acquire
    /// never replaces an existing publisher or restores withdrawn authority.
    pub fn acquire(self: *Lease) !u64 {
        if (self.publisher != 0) return error.PublisherAttached;
        // Borrowing and the first usable publication each consume a generation.
        if (self.generation >= std.math.maxInt(u64) - 2) {
            self.accepted = null;
            self.pending = null;
            self.generation = std.math.maxInt(u64);
            return error.IdExhausted;
        }
        const next = try self.withdraw();
        self.publisher = next;
        return next;
    }
    pub fn hasPublisher(self: *const Lease) bool {
        return self.publisher != 0;
    }
    /// Invalidate before any outbound publication or teardown. Exhaustion is
    /// permanent and fail closed: even the last previously valid stamp is gone.
    pub fn withdraw(self: *Lease) !u64 {
        self.accepted = null;
        self.pending = null;
        self.generation = std.math.add(u64, self.generation, 1) catch return error.IdExhausted;
        return self.generation;
    }
    pub fn begin(self: *Lease, publisher: u64) !u64 {
        try self.checkPublisher(publisher);
        const next = try self.withdraw();
        if (next == std.math.maxInt(u64)) return error.IdExhausted;
        return next;
    }
    /// The coordinate owner offers only POD association, without withdrawing a
    /// successful front. The publisher must match this BEFORE native publish.
    pub fn offer(self: *Lease, stamp: Stamp) void {
        self.pending = stamp;
    }
    pub fn discardCandidate(self: *Lease) void {
        self.pending = null;
    }
    pub fn candidateMatches(self: *const Lease, stamp: Stamp) bool {
        return if (self.pending) |candidate| std.meta.eql(candidate, stamp) else false;
    }
    /// No foreign call or allocation. A withdrawal during the outbound native
    /// publication wins over its old continuation, even with equal geometry.
    pub fn commit(self: *Lease, publisher: u64, generation: u64, stamp: Stamp) !void {
        try self.checkPublisher(publisher);
        if (generation != self.generation or self.accepted != null or self.pending != null) return error.Superseded;
        if (self.generation == std.math.maxInt(u64)) return error.IdExhausted;
        if (stamp.publication == 0 or stamp.source == 0 or stamp.candidate == 0) return error.InvalidPublication;
        self.accepted = stamp;
    }
    /// Withdraw the entrance before retiring the borrow. A failed last counter
    /// increment still retires the publisher and leaves this lease invalid.
    pub fn release(self: *Lease, publisher: u64) !void {
        try self.checkPublisher(publisher);
        self.publisher = 0;
        _ = try self.withdraw();
    }
    pub fn snapshot(self: *const Lease) !Snapshot {
        if (self.generation == std.math.maxInt(u64)) return error.IdExhausted;
        const stamp = self.accepted orelse return error.GeometryRequired;
        return .{ .generation = self.generation, .stamp = stamp };
    }
    fn checkPublisher(self: *const Lease, publisher: u64) !void {
        if (publisher == 0 or self.publisher != publisher) return error.StalePublisher;
    }
};

const sample: Lease.Stamp = .{ .publication = 3, .source = 5, .candidate = 7, .space_epoch = 11, .space_generation = 13 };
test "single publisher and generation distinguish equal successful publications" {
    var lease: Lease = .{};
    const owner = try lease.acquire();
    try std.testing.expectError(error.PublisherAttached, lease.acquire());
    const first = try lease.begin(owner);
    try lease.commit(owner, first, sample);
    try std.testing.expectEqual(first, (try lease.snapshot()).generation);
    const second = try lease.begin(owner);
    try std.testing.expectError(error.GeometryRequired, lease.snapshot());
    try std.testing.expectError(error.Superseded, lease.commit(owner, first, sample));
    try lease.commit(owner, second, sample);
    try std.testing.expect(second != first);
    try lease.release(owner);
    try std.testing.expect(!lease.hasPublisher());
    try std.testing.expectError(error.GeometryRequired, lease.snapshot());
    const next = try lease.acquire();
    try std.testing.expectError(error.StalePublisher, lease.release(owner));
    try std.testing.expectEqual(next, lease.publisher);
}
test "owner withdrawal wins over native publication and exhaustion never wraps" {
    var lease: Lease = .{};
    const owner = try lease.acquire();
    const pending = try lease.begin(owner);
    _ = try lease.withdraw();
    try std.testing.expectError(error.Superseded, lease.commit(owner, pending, sample));
    try std.testing.expectError(error.GeometryRequired, lease.snapshot());
    lease.generation = std.math.maxInt(u64) - 1;
    try std.testing.expectError(error.IdExhausted, lease.begin(owner));
    try std.testing.expectError(error.IdExhausted, lease.commit(owner, lease.generation, sample));
    try std.testing.expectError(error.IdExhausted, lease.begin(owner));
    try std.testing.expectError(error.IdExhausted, lease.release(owner));
    try std.testing.expect(!lease.hasPublisher() and lease.accepted == null);
    try std.testing.expectEqual(std.math.maxInt(u64), lease.generation);
}
test "last unusable publisher generation is rejected and pending association is exact" {
    var lease: Lease = .{};
    lease.offer(sample);
    try std.testing.expect(lease.candidateMatches(sample));
    var changed = sample;
    changed.candidate += 1;
    try std.testing.expect(!lease.candidateMatches(changed));
    lease.discardCandidate();
    try std.testing.expect(!lease.candidateMatches(sample));
    lease.generation = std.math.maxInt(u64) - 2;
    try std.testing.expectError(error.IdExhausted, lease.acquire());
    try std.testing.expect(!lease.hasPublisher() and lease.accepted == null and lease.pending == null);
    try std.testing.expectError(error.IdExhausted, lease.snapshot());
}
