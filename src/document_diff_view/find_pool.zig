const std = @import("std");
const d = @import("ziggurat_document");

pub const Direction = enum { next, previous };
pub const Options = struct { direction: Direction = .next, wrap: bool = true, case: d.search.Case = .exact };
pub const Limits = struct { pending: usize = 2, query_bytes: usize = 4096, bytes: usize = 256 * 1024, work: u64 = 128 * 1024 * 1024 };
pub const Result = union(enum) { match: d.Range, not_found };
pub const Step = enum { yielded, complete };
/// preparation_work is a conservative 3P prefix-comparison charge, not a native
/// timer or exact counter. scan.comparisons is the Iterator's actual counter.
pub const Progress = struct { preparation_work: u64, scan: d.search.Progress };
pub const Stats = struct { owned_bytes: usize, peak_bytes: usize, outstanding: usize, stopping: bool };

pub fn validateLimits(limits: Limits) !void {
    if (limits.pending == 0 or limits.pending > 8 or limits.query_bytes == 0 or limits.query_bytes > 65536 or limits.bytes > 64 * 1024 * 1024 or limits.work == 0 or limits.work > 8 * 1024 * 1024 * 1024) return error.InvalidLimits;
}

/// Private physical worker pool. The facade supplies the source stamp and its
/// final validation; no UI/native object is read by a Work operation.
pub fn Pool(comptime Stamp: type) type {
    return struct {
        const Self = @This();
        const idle = 1;
        const running = 2;
        const done = 3;
        const releasing = 4;
        const released = 5;
        const finishing = 6;
        const Slot = struct {
            phase: std.atomic.Value(u64) = .init(0),
            cancel: d.search.Cancellation = .{},
            serial: u64 = 0,
            stamp: Stamp = undefined,
            snapshot: ?*d.Snapshot = null,
            reader: ?d.Reader = null,
            pattern: []u8 = &.{},
            prefix: []usize = &.{},
            anchor: d.Range = undefined,
            options: Options = .{},
            work_limit: u64 = 0,
            preparation_work: u64 = 0,
            iterator: ?d.search.Iterator = null,
            previous: ?d.Range = null,
            body_end: usize = 0,
            wrapping: bool = false,
            result: Result = .not_found,
            failure: ?anyerror = null,
            accepted: bool = false,
            closing: bool = false,
        };
        pub const Ticket = struct { pool: *Self, index: u8, serial: u64 };
        pub const Validation = struct { context: *anyopaque, validate: *const fn (*anyopaque, Stamp) anyerror!void };
        pub const Source = struct { document: *d.Document, stamp: Stamp, revision: u64, text_version: u64, selection: d.Selection };

        /// A linear worker capability. prepare is a separate O(pattern) phase;
        /// each subsequent step counts at most max_comparisons scan comparisons.
        /// Release follows every query and is the last access to shared storage.
        /// Copies do not create another worker or another release responsibility.
        pub const Work = struct {
            ticket: Ticket,
            slot: *Slot,
            fn acquire(self: Work, complete_allowed: bool) !u64 {
                if (self.ticket.serial == 0 or self.ticket.serial > std.math.maxInt(u64) / 16) return error.WorkClosed;
                const base = self.ticket.serial * 16;
                const previous = self.slot.phase.load(.acquire);
                if (previous != base + idle and !(complete_allowed and previous == base + done)) {
                    if (previous == base + running or previous == base + releasing) return error.Busy;
                    if (previous == base + done) return error.AlreadyComplete;
                    return error.WorkClosed;
                }
                if (self.slot.phase.cmpxchgStrong(previous, base + running, .acq_rel, .acquire) != null) return error.Busy;
                return previous;
            }
            fn fail(self: Work, err: anyerror) anyerror {
                self.slot.failure = err;
                self.slot.phase.store(self.ticket.serial * 16 + done, .release);
                return err;
            }
            fn boundary(reader: d.Reader, position: usize, up: bool) !usize {
                var at = position;
                var attempts: usize = 0;
                while (true) {
                    _ = reader.cursor(.{ .start = at, .end = at }) catch |err| {
                        if (err != error.InvalidBoundary or attempts == 3) return err;
                        attempts += 1;
                        at = if (up) at + 1 else at - 1;
                        continue;
                    };
                    return at;
                }
            }
            fn completeResult(self: Work, value: ?d.Range) Step {
                self.slot.result = if (value) |range| .{ .match = range } else .not_found;
                self.slot.phase.store(self.ticket.serial * 16 + done, .release);
                return .complete;
            }
            pub fn prepare(self: Work) !void {
                _ = try self.acquire(false);
                const slot = self.slot;
                if (slot.iterator != null) {
                    slot.phase.store(self.ticket.serial * 16 + idle, .release);
                    return error.AlreadyPrepared;
                }
                if (slot.cancel.requested.load(.acquire)) return self.fail(error.Cancelled);
                // Each pattern position has at most one successful while
                // comparison and one if comparison. Failed while comparisons
                // decrease matched; their total cannot exceed prior increases.
                // The original Iterator remains the sole prefix authority.
                const preparation = std.math.mul(u64, slot.pattern.len, 3) catch return self.fail(error.WorkLimit);
                if (preparation > slot.work_limit) return self.fail(error.WorkLimit);
                const reader = slot.reader.?;
                const size = reader.byteLength() catch |err| return self.fail(err);
                _ = reader.cursor(slot.anchor) catch |err| return self.fail(err);
                slot.body_end = size;
                const initial_range: d.Range = if (slot.options.direction == .next) .{ .start = slot.anchor.end, .end = size } else .{ .start = 0, .end = slot.anchor.start };
                slot.iterator = d.search.Iterator.init(reader, initial_range, slot.pattern, slot.prefix, .{ .case = slot.options.case, .overlapping = true, .cancellation = &slot.cancel }) catch |err| return self.fail(err);
                slot.preparation_work = preparation;
                if (slot.cancel.requested.load(.acquire)) return self.fail(error.Cancelled);
                slot.phase.store(self.ticket.serial * 16 + idle, .release);
            }
            pub fn step(self: Work, max_comparisons: usize) !Step {
                if (max_comparisons == 0) return error.InvalidBudget;
                _ = try self.acquire(false);
                const slot = self.slot;
                const iterator = if (slot.iterator) |*value| value else {
                    slot.phase.store(self.ticket.serial * 16 + idle, .release);
                    return error.NotPrepared;
                };
                if (slot.cancel.requested.load(.acquire)) return self.fail(error.Cancelled);
                const consumed = slot.preparation_work + iterator.progress().comparisons;
                // EOF publication is zero comparisons, including when the last
                // match used exactly the remaining scan budget.
                const scanned: d.search.Result = if (iterator.progress().next_byte == iterator.end) blk: {
                    _ = iterator.reader.version() catch |err| return self.fail(err);
                    break :blk .done;
                } else blk: {
                    if (consumed >= slot.work_limit) return self.fail(error.WorkLimit);
                    const available: usize = @intCast(@min(slot.work_limit - consumed, std.math.maxInt(usize)));
                    break :blk iterator.step(@min(max_comparisons, available)) catch |err| return self.fail(err);
                };
                switch (scanned) {
                    .yielded => {},
                    .match => |range| {
                        if (slot.options.direction == .next) {
                            if (!slot.wrapping or range.start < slot.anchor.end) return self.completeResult(range);
                        } else if (!slot.wrapping or range.end > slot.anchor.start) slot.previous = range;
                    },
                    .done => {
                        if (slot.previous != null) return self.completeResult(slot.previous);
                        const can_wrap = !slot.wrapping and slot.options.wrap and (if (slot.options.direction == .next) slot.anchor.end != 0 else slot.anchor.start != slot.body_end);
                        if (!can_wrap) return self.completeResult(null);
                        const range: d.Range = if (slot.options.direction == .next) .{
                            .start = 0,
                            .end = boundary(iterator.reader, slot.anchor.end + @min(slot.pattern.len - 1, slot.body_end - slot.anchor.end), true) catch |err| return self.fail(err),
                        } else .{
                            .start = boundary(iterator.reader, slot.anchor.start - @min(slot.anchor.start, slot.pattern.len - 1), false) catch |err| return self.fail(err),
                            .end = slot.body_end,
                        };
                        iterator.restart(range) catch |err| return self.fail(err);
                        slot.wrapping = true;
                    },
                }
                slot.phase.store(self.ticket.serial * 16 + idle, .release);
                return .yielded;
            }
            pub fn progress(self: Work) !Progress {
                const previous = try self.acquire(true);
                const captured: Progress = .{ .preparation_work = self.slot.preparation_work, .scan = if (self.slot.iterator) |*iterator| iterator.progress() else .{ .next_byte = 0, .scanned_bytes = 0, .comparisons = 0 } };
                self.slot.phase.store(previous, .release);
                return captured;
            }
            /// May abandon an unprepared/incomplete request. A failed Reader
            /// release restores the prior phase and keeps responsibility live.
            pub fn release(self: Work) !void {
                const previous = try self.acquire(true);
                self.slot.phase.store(self.ticket.serial * 16 + releasing, .release);
                self.slot.reader.?.release() catch |err| {
                    self.slot.phase.store(previous, .release);
                    return err;
                };
                self.slot.reader = null;
                if (previous != self.ticket.serial * 16 + done) self.slot.failure = error.Incomplete;
                // Owner finish may reclaim both Snapshot and query immediately.
                self.slot.phase.store(self.ticket.serial * 16 + released, .release);
            }
        };

        allocator: std.mem.Allocator,
        owner: std.Thread.Id,
        limits: Limits,
        slots: []Slot,
        next_serial: u64 = 1,
        current: u64 = 0,
        outstanding: usize = 0,
        live: usize,
        peak: usize,
        busy: bool = false,
        stopping: bool = false,
        pub fn minimumBytes(limits: Limits) !usize {
            try validateLimits(limits);
            return std.math.add(usize, @sizeOf(Self), std.math.mul(usize, limits.pending, @sizeOf(Slot)) catch return error.CapacityExceeded) catch return error.CapacityExceeded;
        }
        pub fn create(allocator: std.mem.Allocator, limits: Limits) !*Self {
            const bytes = try minimumBytes(limits);
            if (bytes > limits.bytes) return error.CapacityExceeded;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const slots = try allocator.alloc(Slot, limits.pending);
            for (slots) |*slot| slot.* = .{};
            self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .limits = limits, .slots = slots, .live = bytes, .peak = bytes };
            return self;
        }
        fn enter(self: *Self) !void {
            if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
            if (self.busy) return error.Busy;
            self.busy = true;
        }
        fn entry(self: *Self, ticket: Ticket) ?*Slot {
            if (ticket.pool != self or ticket.index >= self.slots.len or ticket.serial == 0) return null;
            const slot = &self.slots[ticket.index];
            return if (slot.serial == ticket.serial) slot else null;
        }
        /// Success transfers physical query/Reader ownership. Rejection does
        /// not cancel the previous current request. Copy/validation cost is
        /// bounded by query_bytes; prefix construction is worker-only.
        pub fn begin(self: *Self, source: Source, pattern: []const u8, options: Options, validation: Validation) !Work {
            try self.enter();
            defer self.busy = false;
            if (self.stopping) return error.Closed;
            const index = for (self.slots, 0..) |slot, at| {
                if (slot.serial == 0) break at;
            } else return error.Full;
            if (self.next_serial > std.math.maxInt(u64) / 16) return error.IdExhausted;
            if (pattern.len == 0) return error.EmptyPattern;
            if (pattern.len > self.limits.query_bytes) return error.CapacityExceeded;
            const prefix_bytes = std.math.mul(usize, pattern.len, @sizeOf(usize)) catch return error.CapacityExceeded;
            const addition = std.math.add(usize, pattern.len, prefix_bytes) catch return error.CapacityExceeded;
            if (addition > self.limits.bytes - self.live) return error.CapacityExceeded;
            // Allocator callbacks may try to close the source before its
            // Snapshot exists. This no-allocation pin covers all rollback frees.
            try source.document.retainClient();
            defer source.document.releaseClient() catch unreachable;
            const copy = try self.allocator.dupe(u8, pattern);
            self.live += copy.len;
            self.peak = @max(self.peak, self.live);
            errdefer {
                self.allocator.free(copy);
                self.live -= copy.len;
            }
            if (!std.unicode.utf8ValidateSlice(copy)) return error.InvalidUtf8;
            const prefix = try self.allocator.alloc(usize, pattern.len);
            self.live += prefix_bytes;
            self.peak = @max(self.peak, self.live);
            errdefer {
                self.allocator.free(prefix);
                self.live -= prefix_bytes;
            }
            const snapshot = try source.document.snapshot();
            errdefer snapshot.close() catch unreachable;
            if (try snapshot.version() != source.revision or try snapshot.committedTextVersion() != source.text_version) return error.StaleRevision;
            const reader = try snapshot.borrowReader();
            errdefer reader.release() catch unreachable;
            // There are no successful-path temporary foreign frees after this
            // final source validation, and publication itself makes no calls.
            try validation.validate(validation.context, source.stamp);
            const serial = self.next_serial;
            const slot = &self.slots[index];
            slot.serial = serial;
            slot.stamp = source.stamp;
            slot.snapshot = snapshot;
            slot.reader = reader;
            slot.pattern = copy;
            slot.prefix = prefix;
            slot.anchor = source.selection.range();
            slot.options = options;
            slot.work_limit = self.limits.work;
            slot.preparation_work = 0;
            slot.iterator = null;
            slot.previous = null;
            slot.body_end = 0;
            slot.wrapping = false;
            slot.result = .not_found;
            slot.failure = null;
            slot.accepted = false;
            slot.closing = false;
            slot.cancel.requested.store(false, .monotonic);
            for (self.slots) |*old| if (old.serial != 0 and old.serial == self.current) old.cancel.request();
            self.next_serial += 1;
            self.current = serial;
            self.outstanding += 1;
            slot.phase.store(serial * 16 + idle, .release);
            return .{ .ticket = .{ .pool = self, .index = @intCast(index), .serial = serial }, .slot = slot };
        }
        pub fn result(self: *Self, ticket: Ticket) !struct { stamp: Stamp, value: Result } {
            try self.enter();
            defer self.busy = false;
            if (self.stopping) return error.Closed;
            const slot = self.entry(ticket) orelse return error.StaleTicket;
            if (slot.closing) return error.Closing;
            if (slot.serial != self.current or slot.cancel.requested.load(.acquire)) return error.Cancelled;
            if (slot.phase.load(.acquire) != ticket.serial * 16 + released) return error.WorkerRunning;
            if (slot.accepted) return error.AlreadyApplied;
            if (slot.failure) |err| return err;
            return .{ .stamp = slot.stamp, .value = slot.result };
        }
        pub fn accept(self: *Self, ticket: Ticket) !void {
            try self.enter();
            defer self.busy = false;
            const slot = self.entry(ticket) orelse return error.StaleTicket;
            if (slot.closing) return error.Closing;
            if (slot.serial != self.current or slot.cancel.requested.load(.acquire)) return error.Cancelled;
            if (slot.phase.load(.acquire) != ticket.serial * 16 + released) return error.WorkerRunning;
            if (slot.accepted) return error.AlreadyApplied;
            slot.accepted = true;
        }
        pub fn finish(self: *Self, ticket: Ticket) !bool {
            try self.enter();
            defer self.busy = false;
            const slot = self.entry(ticket) orelse return false;
            const previous = ticket.serial * 16 + released;
            if (slot.phase.cmpxchgStrong(previous, ticket.serial * 16 + finishing, .acq_rel, .acquire) != null) return error.WorkerRunning;
            // Once teardown starts it cannot become an applicable result again,
            // even if an additional Reader temporarily prevents Snapshot.close.
            slot.closing = true;
            errdefer slot.phase.store(previous, .release);
            if (slot.snapshot) |snapshot| {
                try snapshot.close();
                slot.snapshot = null;
            }
            self.allocator.free(slot.pattern);
            self.live -= slot.pattern.len;
            self.allocator.free(slot.prefix);
            self.live -= slot.prefix.len * @sizeOf(usize);
            slot.pattern = &.{};
            slot.prefix = &.{};
            slot.serial = 0;
            slot.phase.store(0, .release);
            self.outstanding -= 1;
            return true;
        }
        pub fn cancel(self: *Self, ticket: Ticket) !bool {
            try self.enter();
            defer self.busy = false;
            const slot = self.entry(ticket) orelse return false;
            slot.cancel.request();
            if (self.current == ticket.serial) self.current = 0;
            return true;
        }
        pub fn stop(self: *Self) !void {
            try self.enter();
            defer self.busy = false;
            self.stopping = true;
            self.current = 0;
            for (self.slots) |*slot| if (slot.serial != 0) slot.cancel.request();
        }
        pub fn stats(self: *Self) !Stats {
            try self.enter();
            defer self.busy = false;
            return .{ .owned_bytes = self.live, .peak_bytes = self.peak, .outstanding = self.outstanding, .stopping = self.stopping };
        }
        pub fn close(self: *Self) !void {
            try self.enter();
            errdefer self.busy = false;
            if (self.outstanding != 0) return error.JobsAlive;
            self.allocator.free(self.slots);
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

const TestPool = Pool(u64);
const TestSource = struct {
    document: *d.Document,
    revision: u64,
    fn init(document: *d.Document) !TestSource {
        return .{ .document = document, .revision = try document.version() };
    }
    fn source(self: *const TestSource) !TestPool.Source {
        return .{ .document = self.document, .stamp = self.revision, .revision = self.revision, .text_version = try self.document.committedTextVersion(), .selection = try self.document.selection() };
    }
    fn validate(ptr: *anyopaque, revision: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (revision != self.revision or try self.document.version() != revision) return error.StaleRevision;
    }
    fn validation(self: *TestSource) TestPool.Validation {
        return .{ .context = self, .validate = validate };
    }
};
fn complete(work: TestPool.Work) !void {
    try work.prepare();
    while (try work.step(1) != .complete) {}
    try work.release();
}
test "find pool literal next previous wrap and strict scan steps" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "😀one\r\none X one", .{});
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 4, .caret = 7 });
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "one", .{}, source.validation());
    try std.testing.expectError(error.NotPrepared, work.step(1));
    try work.prepare();
    while (true) {
        const before = try work.progress();
        const step = try work.step(1);
        const after = try work.progress();
        try std.testing.expect(after.scan.comparisons - before.scan.comparisons <= 1);
        if (step == .complete) break;
    }
    try std.testing.expectError(error.WorkerRunning, pool.result(work.ticket));
    try work.release();
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 9, .end = 12 } }, (try pool.result(work.ticket)).value);
    try std.testing.expect(try pool.finish(work.ticket));
    const previous = try pool.begin(try source.source(), "one", .{ .direction = .previous }, source.validation());
    try complete(previous);
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 15, .end = 18 } }, (try pool.result(previous.ticket)).value);
    try std.testing.expect(try pool.finish(previous.ticket));
}
test "find pool release is physical and full does not cancel current" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{ .pending = 1 });
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    try complete(work);
    try std.testing.expectError(error.Full, pool.begin(try source.source(), "b", .{}, source.validation()));
    _ = try pool.result(work.ticket);
    try std.testing.expectError(error.JobsAlive, pool.close());
    try pool.stop();
    try std.testing.expectError(error.Closed, pool.result(work.ticket));
    try std.testing.expect(try pool.finish(work.ticket));
    try std.testing.expect(!try pool.finish(work.ticket));
}
test "find pool snapshot close failure retains retryable finish responsibility" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    const extra = try work.slot.snapshot.?.borrowReader();
    try complete(work);
    try std.testing.expectError(error.ReadersAlive, pool.finish(work.ticket));
    try std.testing.expectError(error.Closing, pool.result(work.ticket));
    try std.testing.expectError(error.Closing, pool.accept(work.ticket));
    try std.testing.expectEqual(@as(usize, 1), (try pool.stats()).outstanding);
    try std.testing.expectError(error.JobsAlive, pool.close());
    try extra.release();
    try std.testing.expect(try pool.finish(work.ticket));
}

test "find pool previous keeps overlapping matches and no-wrap stays empty" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "aaa", .{});
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 3, .caret = 3 });
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const previous = try pool.begin(try source.source(), "aa", .{ .direction = .previous, .wrap = false }, source.validation());
    try complete(previous);
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 1, .end = 3 } }, (try pool.result(previous.ticket)).value);
    try std.testing.expect(try pool.finish(previous.ticket));
    const next = try pool.begin(try source.source(), "aa", .{ .wrap = false }, source.validation());
    try complete(next);
    try std.testing.expectEqualDeep(Result.not_found, (try pool.result(next.ticket)).value);
    try std.testing.expect(try pool.finish(next.ticket));
}

test "find pool dense matches consume one global budget and EOF is free" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), &@as([64]u8, @splat('a')), .{});
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 64, .caret = 64 });
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{ .work = 67 });
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{ .direction = .previous }, source.validation());
    try work.prepare();
    var steps: usize = 0;
    while (true) {
        const before = try work.progress();
        const value = try work.step(7);
        const after = try work.progress();
        try std.testing.expect(after.scan.comparisons - before.scan.comparisons <= 7);
        steps += 1;
        if (value == .complete) break;
    }
    try std.testing.expectEqual(@as(usize, 65), steps);
    const progress = try work.progress();
    try std.testing.expectEqual(@as(u64, 64), progress.scan.comparisons);
    try work.release();
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 63, .end = 64 } }, (try pool.result(work.ticket)).value);
    try std.testing.expect(try pool.finish(work.ticket));

    const limited = try TestPool.create(std.testing.allocator, .{ .work = 66 });
    defer limited.close() catch unreachable;
    const short = try limited.begin(try source.source(), "a", .{ .direction = .previous }, source.validation());
    try short.prepare();
    var hit_limit = false;
    while (true) {
        const value = short.step(7) catch |err| {
            try std.testing.expectEqual(error.WorkLimit, err);
            hit_limit = true;
            break;
        };
        if (value == .complete) break;
    }
    try std.testing.expect(hit_limit);
    try std.testing.expectEqual(@as(u64, 63), (try short.progress()).scan.comparisons);
    try short.release();
    try std.testing.expectError(error.WorkLimit, limited.result(short.ticket));
    try std.testing.expect(try limited.finish(short.ticket));
}

test "find pool prefix fallback has a strict scan comparison bound" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), &@as([100]u8, @splat('a')) ++ "b", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "aaaaab", .{}, source.validation());
    try work.prepare();
    while (true) {
        const before = try work.progress();
        const value = try work.step(3);
        const after = try work.progress();
        try std.testing.expect(after.scan.comparisons - before.scan.comparisons <= 3);
        if (value == .complete) break;
    }
    try std.testing.expect((try work.progress()).scan.comparisons > 101);
    try work.release();
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 95, .end = 101 } }, (try pool.result(work.ticket)).value);
    try std.testing.expect(try pool.finish(work.ticket));
}

test "find pool old work cannot authorize a reused slot and stop does not wait" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{ .pending = 1 });
    defer pool.close() catch unreachable;
    const old = try pool.begin(try source.source(), "a", .{}, source.validation());
    try complete(old);
    try std.testing.expect(try pool.finish(old.ticket));
    const work = try pool.begin(try source.source(), "b", .{}, source.validation());
    try std.testing.expectEqual(old.ticket.index, work.ticket.index);
    try std.testing.expect(old.ticket.serial != work.ticket.serial);
    try std.testing.expectError(error.WorkClosed, old.prepare());
    try std.testing.expectError(error.WorkClosed, old.step(1));
    try std.testing.expectError(error.WorkClosed, old.release());
    try std.testing.expectError(error.StaleTicket, pool.result(old.ticket));
    try pool.stop();
    try std.testing.expectError(error.Cancelled, work.prepare());
    try work.release();
    try std.testing.expect(try pool.finish(work.ticket));
    try std.testing.expectError(error.Closed, pool.begin(try source.source(), "a", .{}, source.validation()));
}

test "find pool reader release failure retains worker responsibility" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    try work.prepare();
    // Test-only corruption of this lease generation models a rejected release;
    // restoring the original generation permits the same responsibility retry.
    const reader = work.slot.reader.?;
    reader.slot.state.store(reader.generation + 2, .release);
    try std.testing.expectError(error.ReaderClosed, work.release());
    try std.testing.expectError(error.WorkerRunning, pool.finish(work.ticket));
    reader.slot.state.store(reader.generation, .release);
    try work.release();
    try std.testing.expectError(error.Incomplete, pool.result(work.ticket));
    try std.testing.expect(try pool.finish(work.ticket));
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    defer _ = pool.finish(work.ticket) catch unreachable;
    try complete(work);
    const before = try pool.stats();
    const candidate = pool.begin(try source.source(), "ab", .{}, source.validation()) catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(before.owned_bytes, (try pool.stats()).owned_bytes);
        _ = try pool.result(work.ticket);
        return err;
    };
    try complete(candidate);
    try std.testing.expectError(error.Cancelled, pool.result(work.ticket));
    try std.testing.expect(try pool.finish(candidate.ticket));
}
test "find pool allocation failure preserves current request and owns every candidate byte" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "find pool source validation failure does not cancel current request" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    try complete(work);
    const before = try pool.stats();
    const Reject = struct {
        fn validate(_: *anyopaque, _: u64) !void {
            return error.StaleSource;
        }
    };
    try std.testing.expectError(error.StaleSource, pool.begin(try source.source(), "b", .{}, .{ .context = &source, .validate = Reject.validate }));
    try std.testing.expectEqual(before.owned_bytes, (try pool.stats()).owned_bytes);
    _ = try pool.result(work.ticket);
    try std.testing.expect(try pool.finish(work.ticket));
}

test "find pool zero-comparison EOF still validates cancellation and Reader" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "a", .{});
    defer document.close() catch unreachable;
    _ = try document.setSelection(.{ .anchor = 1, .caret = 1 });
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{ .work = 4 });
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{ .direction = .previous }, source.validation());
    try work.prepare();
    try std.testing.expectEqual(Step.yielded, try work.step(1));
    try std.testing.expect(try pool.cancel(work.ticket));
    try std.testing.expectError(error.Cancelled, work.step(1));
    try work.release();
    try std.testing.expect(try pool.finish(work.ticket));

    const next = try pool.begin(try source.source(), "a", .{ .direction = .previous }, source.validation());
    try next.prepare();
    try std.testing.expectEqual(Step.yielded, try next.step(1));
    const reader = next.slot.reader.?;
    reader.slot.state.store(reader.generation + 2, .release);
    try std.testing.expectError(error.ReaderClosed, next.step(1));
    reader.slot.state.store(reader.generation, .release);
    try next.release();
    try std.testing.expectError(error.ReaderClosed, pool.result(next.ticket));
    try std.testing.expect(try pool.finish(next.ticket));
}

test "find pool allocator callbacks cannot revoke owner or close unretained source" {
    const Probe = struct {
        pool: ?*TestPool = null,
        document: *d.Document,
        armed: bool = false,
        calls: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn enter(self: *@This()) void {
            if (!self.armed) return;
            self.calls += 1;
            std.testing.expectError(error.Busy, self.pool.?.stop()) catch unreachable;
            std.testing.expectError(error.Busy, self.pool.?.stats()) catch unreachable;
            std.testing.expectError(error.Busy, self.pool.?.close()) catch unreachable;
            std.testing.expectError(error.ClientAttached, self.document.close()) catch unreachable;
        }
        fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.enter();
            return std.testing.allocator.rawAlloc(size, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.enter();
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    var probe: Probe = .{ .document = document };
    const pool = try TestPool.create(probe.allocator(), .{});
    defer pool.close() catch unreachable;
    probe.pool = pool;
    probe.armed = true;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    probe.armed = false;
    try complete(work);
    // A retained facade is required through finish; this test mirrors that
    // source ownership so callbacks cannot destroy its Document during frees.
    try document.retainClient();
    probe.armed = true;
    try std.testing.expect(try pool.finish(work.ticket));
    probe.armed = false;
    try document.releaseClient();
    try std.testing.expect(probe.calls >= 4);
}

test "find pool worker uses only immutable Reader after owner edits" {
    const Worker = struct {
        work: TestPool.Work,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            complete(self.work) catch |err| {
                self.failure = err;
            };
        }
    };
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "one two", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "two", .{}, source.validation());
    try document.replace(.{ .start = 0, .end = 7 }, "other");
    var worker: Worker = .{ .work = work };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    try std.testing.expectEqualDeep(Result{ .match = .{ .start = 4, .end = 7 } }, (try pool.result(work.ticket)).value);
    try std.testing.expect(try pool.finish(work.ticket));
}

fn linearOracle(body: []const u8, pattern: []const u8, anchor: d.Range, options: Options) Result {
    var first: ?d.Range = null;
    var last: ?d.Range = null;
    var prior: ?d.Range = null;
    var following: ?d.Range = null;
    for (0..body.len + 1) |at| {
        if (pattern.len > body.len - at) break;
        var equal = true;
        for (body[at..][0..pattern.len], pattern) |left, right| {
            const a = if (options.case == .ascii_insensitive) std.ascii.toLower(left) else left;
            const b = if (options.case == .ascii_insensitive) std.ascii.toLower(right) else right;
            if (a != b) {
                equal = false;
                break;
            }
        }
        if (!equal) continue;
        const range: d.Range = .{ .start = at, .end = at + pattern.len };
        first = first orelse range;
        last = range;
        if (range.end <= anchor.start) prior = range;
        if (following == null and range.start >= anchor.end) following = range;
    }
    const selected = if (options.direction == .next) following orelse (if (options.wrap) first else null) else prior orelse (if (options.wrap) last else null);
    return if (selected) |range| .{ .match = range } else .not_found;
}

test "find pool 512 literal direction cases match an independent overlapping linear oracle" {
    var random_source: std.Random.DefaultPrng = .init(0xd172d39a);
    const random = random_source.random();
    const tokens = [_][]const u8{ "a", "A", "b", "\r\n", "😀" };
    const patterns = [_][]const u8{ "a", "aa", "A", "😀", "\r\n", "baba", "absent" };
    const pool = try TestPool.create(std.testing.allocator, .{});
    defer pool.close() catch unreachable;
    const baseline = (try pool.stats()).owned_bytes;
    for (0..512) |case_index| {
        var body: [256]u8 = undefined;
        var boundaries: [34]usize = undefined;
        boundaries[0] = 0;
        var length: usize = 0;
        const count = random.uintLessThan(usize, 33);
        for (0..count) |at| {
            const token = tokens[random.uintLessThan(usize, tokens.len)];
            @memcpy(body[length..][0..token.len], token);
            length += token.len;
            boundaries[at + 1] = length;
        }
        const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), body[0..length], .{});
        defer document.close() catch unreachable;
        const selected: d.Selection = .{ .anchor = boundaries[random.uintLessThan(usize, count + 1)], .caret = boundaries[random.uintLessThan(usize, count + 1)] };
        _ = try document.setSelection(selected);
        var source = try TestSource.init(document);
        const pattern = patterns[random.uintLessThan(usize, patterns.len)];
        const options: Options = .{ .direction = if (case_index & 1 == 0) .next else .previous, .wrap = case_index & 2 == 0, .case = if (case_index & 4 == 0) .exact else .ascii_insensitive };
        const work = try pool.begin(try source.source(), pattern, options, source.validation());
        try work.prepare();
        while (try work.step(1 + case_index % 9) != .complete) {}
        try work.release();
        try std.testing.expectEqualDeep(linearOracle(body[0..length], pattern, selected.range(), options), (try pool.result(work.ticket)).value);
        try std.testing.expect(try pool.finish(work.ticket));
        try std.testing.expectEqual(baseline, (try pool.stats()).owned_bytes);
    }
}

test "find pool limits and nonwrap serial are checked before allocation or cancellation" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    var source = try TestSource.init(document);
    const pool = try TestPool.create(std.testing.allocator, .{ .query_bytes = 1 });
    defer pool.close() catch unreachable;
    const work = try pool.begin(try source.source(), "a", .{}, source.validation());
    try complete(work);
    const baseline = (try pool.stats()).owned_bytes;
    try std.testing.expectError(error.EmptyPattern, pool.begin(try source.source(), "", .{}, source.validation()));
    try std.testing.expectError(error.CapacityExceeded, pool.begin(try source.source(), "aa", .{}, source.validation()));
    try std.testing.expectError(error.InvalidUtf8, pool.begin(try source.source(), "\xff", .{}, source.validation()));
    pool.next_serial = std.math.maxInt(u64) / 16 + 1;
    try std.testing.expectError(error.IdExhausted, pool.begin(try source.source(), "b", .{}, source.validation()));
    try std.testing.expectEqual(baseline, (try pool.stats()).owned_bytes);
    _ = try pool.result(work.ticket);
    try std.testing.expect(try pool.finish(work.ticket));
    const malformed: TestPool.Work = .{ .ticket = .{ .pool = pool, .index = 0, .serial = std.math.maxInt(u64) }, .slot = &pool.slots[0] };
    try std.testing.expectError(error.WorkClosed, malformed.release());
}

test "find pool bounded next and previous scans skip unrelated source ranges" {
    const bodies = [_][]const u8{ &@as([32768]u8, @splat('x')) ++ "needle", "needle" ++ &@as([32768]u8, @splat('x')) };
    const pool = try TestPool.create(std.testing.allocator, .{ .work = 24 });
    defer pool.close() catch unreachable;
    for (bodies, 0..) |body, at| {
        const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), body, .{});
        defer document.close() catch unreachable;
        const position: usize = if (at == 0) 32768 else 6;
        _ = try document.setSelection(.{ .anchor = position, .caret = position });
        var source = try TestSource.init(document);
        const work = try pool.begin(try source.source(), "needle", .{ .direction = if (at == 0) .next else .previous }, source.validation());
        try work.prepare();
        while (try work.step(1) != .complete) {}
        const progress = try work.progress();
        try work.release();
        const expected_start: usize = if (at == 0) 32768 else 0;
        try std.testing.expectEqualDeep(Result{ .match = .{ .start = expected_start, .end = expected_start + 6 } }, (try pool.result(work.ticket)).value);
        try std.testing.expectEqual(@as(u64, 6), progress.scan.comparisons);
        try std.testing.expectEqual(@as(usize, 6), progress.scan.scanned_bytes);
        try std.testing.expect(try pool.finish(work.ticket));
    }
}
