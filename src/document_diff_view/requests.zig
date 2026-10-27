const std = @import("std");
const zio = @import("ziggurat_io");
const d = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");
const intraline = @import("intraline.zig");

pub const Limits = struct { pending: usize = 2, result_bytes: usize = 16 * 1024 * 1024, hunks: usize = 8192 };
pub const Pair = struct { a: *d.Document, b: *d.Document };
pub const Ticket = struct { inbox: *Inbox, index: u8, serial: u64, a: diff.Stamp, b: diff.Stamp };
const Slot = struct {
    state: std.atomic.Value(u64) = .init(0),
    cancel: diff.Cancellation = .{},
    serial: u64 = 0,
    a: ?*d.Snapshot = null,
    b: ?*d.Snapshot = null,
    stamp_a: diff.Stamp = undefined,
    stamp_b: diff.Stamp = undefined,
    published: bool = false,
};
/// One worker owns both read leases. Release is the last shared-memory access,
/// not acknowledgement of an accepted delivery. Owner finish is still needed.
pub const Job = struct {
    ticket: Ticket,
    a: d.Reader,
    b: d.Reader,
    cancellation: *const diff.Cancellation,
    slot: *Slot,
    pub fn release(self: Job) !void {
        const active = self.ticket.serial * 4 + 1;
        if (self.slot.state.cmpxchgStrong(active, active + 1, .acq_rel, .acquire) != null) return error.JobClosed;
        const first = self.a.release();
        const second = self.b.release();
        self.slot.state.store(active + 2, .release);
        try first;
        try second;
    }
};
pub const Display = struct {
    serial: u64,
    result: diff.Result,
    details: ?intraline.Result = null,
    a: *d.Snapshot,
    b: *d.Snapshot,
    fn close(self: *Display) void {
        self.result.deinit();
        if (self.details) |*details| details.deinit();
        self.a.close() catch unreachable;
        self.b.close() catch unreachable;
    }
};
pub const Borrow = struct {
    inbox: *Inbox,
    pub fn display(self: Borrow) !?*const Display {
        return self.inbox.displayInner();
    }
    pub fn end(self: Borrow) void {
        self.inbox.busy = false;
    }
    pub fn releaseClient(self: Borrow) !void {
        if (self.inbox.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.inbox.clients == 0) return error.ClientNotAttached;
        self.inbox.clients -= 1;
    }
};
/// Owner of pair identity, snapshots and bounded physical delivery slots. It
/// starts no threads and never infers identity from version/length equality.
/// Stable address covers every accepted Job and its owner finish, even after
/// Reader release or cancellation. No copies can outlive the Inbox itself.
pub const Inbox = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    pair: Pair,
    limits: Limits,
    slots: []Slot,
    next_serial: u64 = 1,
    current: u64 = 0,
    outstanding: usize = 0,
    clients: usize = 0,
    generation: u64 = 0,
    stored: ?Display = null,
    busy: bool = false,
    stopping: bool = false,
    pub fn create(allocator: std.mem.Allocator, pair: Pair, limits: Limits) !*Inbox {
        if (limits.pending == 0 or limits.pending > 8 or limits.hunks == 0 or limits.hunks > 65536 or limits.result_bytes == 0 or limits.result_bytes > 1024 * 1024 * 1024) return error.InvalidLimits;
        try pair.a.retainClient();
        errdefer pair.a.releaseClient() catch unreachable;
        try pair.b.retainClient();
        errdefer pair.b.releaseClient() catch unreachable;
        const self = try allocator.create(Inbox);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, limits.pending);
        for (slots) |*entry| entry.* = .{};
        self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .pair = pair, .limits = limits, .slots = slots };
        return self;
    }
    fn check(self: *const Inbox) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.busy) return error.Busy;
    }
    fn enter(self: *Inbox) !void {
        try self.check();
        self.busy = true;
    }
    fn stamp(snapshot: *const d.Snapshot) !diff.Stamp {
        return .{ .revision = try snapshot.version(), .text_version = try snapshot.committedTextVersion(), .bytes = try snapshot.byteLength() };
    }
    fn find(self: *Inbox, ticket: Ticket) ?*Slot {
        if (ticket.inbox != self or ticket.index >= self.slots.len or ticket.serial == 0) return null;
        const value = &self.slots[ticket.index];
        return if (value.serial == ticket.serial and std.meta.eql(value.stamp_a, ticket.a) and std.meta.eql(value.stamp_b, ticket.b)) value else null;
    }
    pub fn fresh(self: *const Inbox, a: diff.Stamp, b: diff.Stamp) !bool {
        return a.text_version == try self.pair.a.committedTextVersion() and b.text_version == try self.pair.b.committedTextVersion() and a.bytes == try self.pair.a.byteLength() and b.bytes == try self.pair.b.byteLength();
    }
    pub fn begin(self: *Inbox) !Job {
        try self.enter();
        defer self.busy = false;
        if (self.stopping) return error.Closed;
        const index = for (self.slots, 0..) |entry, at| {
            if (entry.serial == 0) break at;
        } else return error.Full;
        if (self.next_serial > std.math.maxInt(u64) / 4) return error.IdExhausted;
        const a = try self.pair.a.snapshot();
        errdefer a.close() catch unreachable;
        const b = try self.pair.b.snapshot();
        errdefer b.close() catch unreachable;
        const stamp_a = try stamp(a);
        const stamp_b = try stamp(b);
        const ra = try a.borrowReader();
        errdefer ra.release() catch unreachable;
        const rb = try b.borrowReader();
        errdefer rb.release() catch unreachable;
        if (!try self.fresh(stamp_a, stamp_b)) return error.StaleRevision;
        const serial = self.next_serial;
        self.next_serial += 1;
        for (self.slots) |*entry| if (entry.serial == self.current and entry.serial != 0) entry.cancel.request();
        const entry = &self.slots[index];
        entry.serial = serial;
        entry.a = a;
        entry.b = b;
        entry.stamp_a = stamp_a;
        entry.stamp_b = stamp_b;
        entry.published = false;
        entry.cancel.requested.store(false, .monotonic);
        entry.state.store(serial * 4 + 1, .release);
        self.current = serial;
        self.outstanding += 1;
        return .{ .ticket = .{ .inbox = self, .index = @intCast(index), .serial = serial, .a = stamp_a, .b = stamp_b }, .a = ra, .b = rb, .cancellation = &entry.cancel, .slot = entry };
    }
    /// Move Result only after all validation and both Snapshot clones succeed.
    /// Full captured stamps match the Job; current selections may have changed.
    pub fn publish(self: *Inbox, ticket: Ticket, result: *diff.Result) !void {
        return self.publishDetailed(ticket, result, null);
    }
    /// Publish line and optional intraline metadata in one ownership transfer.
    /// The receiving byte budget includes the previous and candidate buffers.
    /// Rejection leaves BOTH supplied owners and the previous display intact.
    pub fn publishDetailed(self: *Inbox, ticket: Ticket, result: *diff.Result, details: ?*intraline.Result) !void {
        try self.enter();
        defer self.busy = false;
        if (!result.isOwned()) return error.ResultMoved;
        if (details) |value| if (!value.isOwned()) return error.ResultMoved;
        if (self.stopping) return error.Closed;
        const entry = self.find(ticket) orelse return error.StaleTicket;
        if (ticket.serial != self.current or entry.cancel.requested.load(.acquire)) return error.Cancelled;
        if (entry.state.load(.acquire) != ticket.serial * 4 + 3) return error.WorkerRunning;
        if (entry.published) return error.AlreadyPublished;
        if (!std.meta.eql(result.a, ticket.a) or !std.meta.eql(result.b, ticket.b)) return error.ForeignResult;
        if (!try self.fresh(ticket.a, ticket.b)) return error.StaleRevision;
        if (result.hunks.len > self.limits.hunks) return error.CapacityExceeded;
        var bytes = try resultBytes(result, if (details) |value| value else null);
        if (self.stored) |*old| bytes = std.math.add(usize, bytes, try resultBytes(&old.result, if (old.details) |*value| value else null)) catch return error.CapacityExceeded;
        if (bytes > self.limits.result_bytes) return error.CapacityExceeded;
        try validate(result, entry.a.?, entry.b.?);
        if (details) |value| try validateDetails(value, result, entry.a.?, entry.b.?);
        const generation = std.math.add(u64, self.generation, 1) catch return error.IdExhausted;
        const a = try entry.a.?.clone();
        errdefer a.close() catch unreachable;
        const b = try entry.b.?.clone();
        errdefer b.close() catch unreachable;
        if (!try self.fresh(ticket.a, ticket.b)) return error.StaleRevision;
        var old: ?Display = null;
        std.mem.swap(?Display, &old, &self.stored);
        // Both moves are pure and infallible after the ownership checks. No
        // allocator/native callback runs between them or before the new owner.
        self.stored = .{ .serial = ticket.serial, .result = result.take() catch unreachable, .details = if (details) |value| value.take() catch unreachable else null, .a = a, .b = b };
        entry.published = true;
        self.generation = generation;
        if (old) |value| {
            var previous = value;
            previous.close();
        }
    }
    pub fn finish(self: *Inbox, ticket: Ticket) !bool {
        try self.enter();
        defer self.busy = false;
        const entry = self.find(ticket) orelse return false;
        if (entry.state.load(.acquire) != ticket.serial * 4 + 3) return error.WorkerRunning;
        try entry.a.?.close();
        entry.a = null;
        try entry.b.?.close();
        entry.b = null;
        entry.serial = 0;
        entry.state.store(0, .release);
        self.outstanding -= 1;
        return true;
    }
    pub fn cancel(self: *Inbox, ticket: Ticket) !bool {
        try self.enter();
        defer self.busy = false;
        const entry = self.find(ticket) orelse return false;
        entry.cancel.request();
        if (self.current == ticket.serial) self.current = 0;
        return true;
    }
    fn displayInner(self: *const Inbox) !?*const Display {
        if (self.stopping) return error.Closed;
        const value = if (self.stored) |*item| item else return null;
        if (!try self.fresh(value.result.a, value.result.b)) return null;
        return value;
    }
    pub fn borrow(self: *Inbox) !Borrow {
        try self.enter();
        if (self.stopping) {
            self.busy = false;
            return error.Closed;
        }
        return .{ .inbox = self };
    }
    pub fn borrowForTeardown(self: *Inbox) !Borrow {
        try self.enter();
        return .{ .inbox = self };
    }
    pub fn retainClient(self: *Inbox) !void {
        try self.check();
        if (self.stopping) return error.Closed;
        self.clients = std.math.add(usize, self.clients, 1) catch return error.CapacityExceeded;
    }
    pub fn stop(self: *Inbox) !void {
        try self.enter();
        defer self.busy = false;
        self.stopping = true;
        for (self.slots) |*entry| if (entry.serial != 0) entry.cancel.request();
        var old: ?Display = null;
        std.mem.swap(?Display, &old, &self.stored);
        if (old) |value| {
            var previous = value;
            previous.close();
        }
    }
    pub fn close(self: *Inbox) !void {
        try self.check();
        if (self.clients != 0) return error.ClientsAlive;
        if (self.outstanding != 0) return error.JobsAlive;
        self.busy = true;
        var old: ?Display = null;
        std.mem.swap(?Display, &old, &self.stored);
        if (old) |value| {
            var previous = value;
            previous.close();
        }
        self.pair.a.releaseClient() catch unreachable;
        self.pair.b.releaseClient() catch unreachable;
        const allocator = self.allocator;
        allocator.free(self.slots);
        allocator.destroy(self);
    }
};
fn resultBytes(result: *const diff.Result, details: ?*const intraline.Result) !usize {
    const lines = std.math.mul(usize, result.storage.len, @sizeOf(diff.Hunk)) catch return error.CapacityExceeded;
    const spans = if (details) |value| std.math.mul(usize, value.storage.len, @sizeOf(intraline.Span)) catch return error.CapacityExceeded else 0;
    return std.math.add(usize, lines, spans) catch return error.CapacityExceeded;
}
fn validateDetails(details: *const intraline.Result, result: *const diff.Result, a: *const d.Snapshot, b: *const d.Snapshot) !void {
    if (!std.meta.eql(details.a, result.a) or !std.meta.eql(details.b, result.b)) return error.ForeignResult;
    var previous: ?intraline.Span = null;
    for (details.spans) |span| {
        if (span.hunk >= result.hunks.len) return error.InvalidResult;
        const hunk = result.hunks[span.hunk];
        if (span.line_a < hunk.a.lines.start or span.line_a >= hunk.a.lines.end or span.line_b < hunk.b.lines.start or span.line_b >= hunk.b.lines.end or span.line_a - hunk.a.lines.start != span.line_b - hunk.b.lines.start) return error.InvalidResult;
        if (previous) |old| {
            if (span.hunk < old.hunk or span.line_a < old.line_a or span.line_b < old.line_b or span.a.start < old.a.end or span.b.start < old.b.end) return error.InvalidResult;
        }
        for ([_]*const d.Snapshot{ a, b }, [_]usize{ span.line_a, span.line_b }, [_]d.Range{ span.a, span.b }) |snapshot, line, range| {
            const start = (try snapshot.line(line)).start;
            const end = if (line + 1 < try snapshot.lineCount()) (try snapshot.line(line + 1)).start else try snapshot.byteLength();
            if (range.start < start or range.start > range.end or range.end > end) return error.InvalidResult;
            _ = try snapshot.utf16Offset(range.start);
            _ = try snapshot.utf16Offset(range.end);
        }
        if (span.a.start == span.a.end and span.b.start == span.b.end) return error.InvalidResult;
        previous = span;
    }
}
fn validate(result: *const diff.Result, a: *const d.Snapshot, b: *const d.Snapshot) !void {
    var end_a: usize = 0;
    var end_b: usize = 0;
    for (result.hunks) |hunk| {
        if (hunk.a.bytes.start < end_a or hunk.b.bytes.start < end_b or hunk.a.bytes.start > hunk.a.bytes.end or hunk.b.bytes.start > hunk.b.bytes.end or hunk.a.lines.start > hunk.a.lines.end or hunk.b.lines.start > hunk.b.lines.end or hunk.a.lines.end > result.stats.lines_a or hunk.b.lines.end > result.stats.lines_b) return error.InvalidResult;
        _ = try a.utf16Offset(hunk.a.bytes.start);
        _ = try a.utf16Offset(hunk.a.bytes.end);
        _ = try b.utf16Offset(hunk.b.bytes.start);
        _ = try b.utf16Offset(hunk.b.bytes.end);
        end_a = hunk.a.bytes.end;
        end_b = hunk.b.bytes.end;
    }
}

test "pair identity and physical delivery outlive Readers and retain revert Snapshot roots" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a\nb", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a\nc", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const job = try inbox.begin();
    var result = try diff.compare(std.testing.allocator, job.a, job.b, .{});
    defer result.deinit();
    try std.testing.expectError(error.WorkerRunning, inbox.publish(job.ticket, &result));
    try job.release();
    try std.testing.expectError(error.JobsAlive, inbox.close());
    _ = try a.setSelection(.{ .anchor = 0, .caret = 0 });
    try inbox.publish(job.ticket, &result);
    try std.testing.expectEqual(0, result.hunks.len);
    _ = try inbox.finish(job.ticket);
    const next = try inbox.begin();
    try next.release();
    try std.testing.expectError(error.ResultMoved, inbox.publish(next.ticket, &result));
    _ = try inbox.finish(next.ticket);
    const borrow = try inbox.borrow();
    const display = (try borrow.display()).?;
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a\nc", bytes[0..try display.b.read(.{ .start = 0, .end = 3 }, &bytes)]);
    try std.testing.expectError(error.Busy, inbox.begin());
    borrow.end();
}

test "cancelled and stale deliveries retain physical slots and caller result ownership" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a\nb", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a\nc", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{ .pending = 2 });
    defer inbox.close() catch unreachable;
    const first = try inbox.begin();
    var old = try diff.compare(std.testing.allocator, first.a, first.b, .{});
    defer old.deinit();
    const second = try inbox.begin();
    try std.testing.expect(first.cancellation.requested.load(.acquire));
    try std.testing.expectError(error.Full, inbox.begin());
    try first.release();
    try std.testing.expectError(error.Cancelled, inbox.publish(first.ticket, &old));
    try std.testing.expect(old.isOwned());
    _ = try inbox.finish(first.ticket);
    try std.testing.expect(!try inbox.finish(first.ticket));
    var latest = try diff.compare(std.testing.allocator, second.a, second.b, .{});
    defer latest.deinit();
    try second.release();
    var foreign = second.ticket;
    foreign.serial += 1;
    try std.testing.expectError(error.StaleTicket, inbox.publish(foreign, &latest));
    _ = try b.replace(.{ .start = 2, .end = 3 }, "new");
    try std.testing.expectError(error.StaleRevision, inbox.publish(second.ticket, &latest));
    try std.testing.expect(latest.isOwned());
    _ = try inbox.finish(second.ticket);
    const third = try inbox.begin();
    try std.testing.expectEqual(first.ticket.index, third.ticket.index);
    try std.testing.expectError(error.JobClosed, first.release());
    try std.testing.expect(!try inbox.cancel(first.ticket));
    try inbox.stop();
    try std.testing.expectError(error.Closed, inbox.begin());
    try std.testing.expectError(error.JobsAlive, inbox.close());
    try third.release();
    _ = try inbox.finish(third.ticket);
}

test "wide producer result cannot bypass a narrower Inbox budget or replace its display" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "one\nkeep\ntwo", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "ONE\nkeep\nTWO", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{ .hunks = 1 });
    defer inbox.close() catch unreachable;
    const job = try inbox.begin();
    var result = try diff.compare(std.testing.allocator, job.a, job.b, .{});
    defer result.deinit();
    try job.release();
    try std.testing.expectEqual(@as(usize, 2), result.hunks.len);
    try std.testing.expectError(error.CapacityExceeded, inbox.publish(job.ticket, &result));
    try std.testing.expect(result.isOwned());
    _ = try inbox.finish(job.ticket);
    const borrow = try inbox.borrow();
    try std.testing.expect(try borrow.display() == null);
    borrow.end();
}

test "detailed publication moves both owners once and enforces old plus candidate receiving budget" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "prefix left suffix", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "prefix right suffix", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const first = try inbox.begin();
    var lines = try diff.compare(std.testing.allocator, first.a, first.b, .{});
    defer lines.deinit();
    var details = try intraline.compare(std.testing.allocator, first.a, first.b, &lines, .{});
    defer details.deinit();
    try first.release();
    try inbox.publishDetailed(first.ticket, &lines, &details);
    try std.testing.expect(!lines.isOwned() and !details.isOwned());
    _ = try inbox.finish(first.ticket);
    const second = try inbox.begin();
    var next = try diff.compare(std.testing.allocator, second.a, second.b, .{});
    defer next.deinit();
    var detail_next = try intraline.compare(std.testing.allocator, second.a, second.b, &next, .{});
    defer detail_next.deinit();
    try second.release();
    try std.testing.expectError(error.ResultMoved, inbox.publishDetailed(second.ticket, &next, &details));
    const bytes = try resultBytes(&next, &detail_next);
    inbox.limits.result_bytes = bytes * 2 - 1;
    try std.testing.expectError(error.CapacityExceeded, inbox.publishDetailed(second.ticket, &next, &detail_next));
    try std.testing.expect(next.isOwned() and detail_next.isOwned());
    const old_borrow = try inbox.borrow();
    try std.testing.expectEqual(first.ticket.serial, (try old_borrow.display()).?.serial);
    old_borrow.end();
    inbox.limits.result_bytes += 1;
    try inbox.publishDetailed(second.ticket, &next, &detail_next);
    try std.testing.expect(!next.isOwned() and !detail_next.isOwned());
    _ = try inbox.finish(second.ticket);
}

test "invalid or foreign byte spans do not move either result" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "e\u{301}", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "e\u{308}", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const job = try inbox.begin();
    var lines = try diff.compare(std.testing.allocator, job.a, job.b, .{});
    defer lines.deinit();
    var details = try intraline.compare(std.testing.allocator, job.a, job.b, &lines, .{});
    defer details.deinit();
    try job.release();
    details.a.revision += 1;
    try std.testing.expectError(error.ForeignResult, inbox.publishDetailed(job.ticket, &lines, &details));
    details.a.revision -= 1;
    const original = details.storage[0];
    details.storage[0].a.start = 2;
    try std.testing.expectError(error.InvalidBoundary, inbox.publishDetailed(job.ticket, &lines, &details));
    details.storage[0] = original;
    details.storage[0].line_b += 1;
    try std.testing.expectError(error.InvalidResult, inbox.publishDetailed(job.ticket, &lines, &details));
    details.storage[0] = original;
    try std.testing.expect(lines.isOwned() and details.isOwned());
    try inbox.stop();
    try std.testing.expectError(error.Closed, inbox.publishDetailed(job.ticket, &lines, &details));
    _ = try inbox.finish(job.ticket);
}

test "zero-span detailed results keep move identity across subsequent Jobs" {
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "one sided", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const first = try inbox.begin();
    var lines = try diff.compare(std.testing.allocator, first.a, first.b, .{});
    defer lines.deinit();
    var details = try intraline.compare(std.testing.allocator, first.a, first.b, &lines, .{});
    defer details.deinit();
    try std.testing.expectEqual(@as(usize, 0), details.spans.len);
    try first.release();
    try inbox.publishDetailed(first.ticket, &lines, &details);
    _ = try inbox.finish(first.ticket);
    const second = try inbox.begin();
    var next = try diff.compare(std.testing.allocator, second.a, second.b, .{});
    defer next.deinit();
    try second.release();
    try std.testing.expectError(error.ResultMoved, inbox.publishDetailed(second.ticket, &next, &details));
    try std.testing.expect(next.isOwned());
    const borrow = try inbox.borrow();
    try std.testing.expectEqual(first.ticket.serial, (try borrow.display()).?.serial);
    borrow.end();
    _ = try inbox.finish(second.ticket);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), "before\nkeep", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), "after\nkeep", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const job = try inbox.begin();
    var released = false;
    defer {
        if (!released) job.release() catch unreachable;
        _ = inbox.finish(job.ticket) catch unreachable;
    }
    var result = try diff.compare(allocator, job.a, job.b, .{});
    defer result.deinit();
    var details = try intraline.compare(allocator, job.a, job.b, &result, .{});
    defer details.deinit();
    try job.release();
    released = true;
    inbox.publishDetailed(job.ticket, &result, &details) catch |err| {
        try std.testing.expect(result.isOwned() and details.isOwned());
        const borrow = try inbox.borrow();
        try std.testing.expect(try borrow.display() == null);
        borrow.end();
        return err;
    };
    try std.testing.expect(!result.isOwned() and !details.isOwned());
}
test "all candidate allocations unwind without moving a rejected result or leaking clients" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "explicit worker sees immutable pair snapshots while the owner edits and stopping waits for delivery" {
    const Worker = struct {
        job: Job,
        started: zio.Semaphore = .{},
        proceed: zio.Semaphore = .{},
        result: ?diff.Result = null,
        details: ?intraline.Result = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.started.post();
            self.proceed.wait();
            self.result = diff.compare(std.testing.allocator, self.job.a, self.job.b, .{}) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            if (self.result) |*value| self.details = intraline.compare(std.testing.allocator, self.job.a, self.job.b, value, .{ .cancellation = self.job.cancellation }) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.job.release() catch |err| {
                self.failure = err;
            };
        }
    };
    const a = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "old\nleft", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "old\nright", .{});
    defer b.close() catch unreachable;
    const inbox = try Inbox.create(std.testing.allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var worker: Worker = .{ .job = try inbox.begin() };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    worker.started.wait();
    _ = try a.replace(.{ .start = 0, .end = 3 }, "new");
    worker.proceed.post();
    thread.join();
    if (worker.failure) |err| return err;
    var result = worker.result.?;
    defer result.deinit();
    var details = worker.details.?;
    defer details.deinit();
    try std.testing.expectEqual(@as(usize, 8), result.a.bytes);
    try std.testing.expectError(error.JobsAlive, inbox.close());
    try std.testing.expectError(error.StaleRevision, inbox.publishDetailed(worker.job.ticket, &result, &details));
    try inbox.stop();
    try std.testing.expectError(error.Closed, inbox.publishDetailed(worker.job.ticket, &result, &details));
    try std.testing.expect(result.isOwned() and details.isOwned());
    _ = try inbox.finish(worker.job.ticket);
}
