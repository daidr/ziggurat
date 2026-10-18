const std = @import("std");

pub const Result = union(enum) { installed: u64, cancelled, detached, native_failure: i32 };
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
/// A taken delivery has no Book/View/App pointer. Invoke it only after owner
/// pointers and charges have been withdrawn; it may destroy its former owner.
pub const Delivery = struct {
    completion: Completion,
    result: Result,
    pub fn invoke(self: Delivery) void {
        self.completion.complete(self.completion.context, self.result);
    }
};
const Pending = struct {
    token: u64,
    revision: u64,
    accepted: bool = false,
    cancelled: bool = false,
    completion: ?Completion = null,
};
/// This describes completed native mutation/rollback, not just Add's logical
/// cancellation. A cancelled successful Add must remove its new native ID before
/// retiring. Any uncertain Remove poisons future navigation, even after cancel.
pub const Retirement = union(enum) { installed, discarded, failed: i32, removal_uncertain: i32 };
pub const Retired = struct { delivery: ?Delivery = null, publish: bool = false, unavailable: bool = false };

/// Pure one-transaction owner-thread book. Allocate it only in the optional
/// initializer owner. Native objects/strings and their physical budgets have
/// separate ownership; cancellation does not return their credit or free a slot.
pub const Book = struct {
    revision: u64 = 0,
    next_token: u64 = 1,
    pending: ?Pending = null,
    sealed: bool = false,
    unavailable: bool = false,

    pub fn busy(self: *const Book) bool {
        return self.pending != null;
    }
    pub fn allowsNavigation(self: *const Book) bool {
        return !self.sealed and !self.unavailable and self.pending == null;
    }
    /// Reserve before foreign allocation/submission. No completion ownership is
    /// accepted yet, so synchronous failures and reentrant close can return the
    /// caller's context untouched. Native submission must be gated while here.
    pub fn reserve(self: *Book, navigation_in_flight: bool) !u64 {
        if (self.sealed) return error.Closed;
        if (self.unavailable) return error.InitializerUnavailable;
        if (self.pending != null or navigation_in_flight) return error.Busy;
        if (self.next_token == std.math.maxInt(u64) or self.revision == std.math.maxInt(u64)) return error.InitializerTokenExhausted;
        const token = self.next_token;
        self.next_token += 1;
        self.pending = .{ .token = token, .revision = self.revision + 1 };
        return token;
    }
    pub fn accept(self: *Book, token: u64, completion: Completion) !void {
        if (self.sealed) return error.Closed;
        const pending = if (self.pending) |*pending| pending else return error.StaleInitializerReplacement;
        if (pending.token != token or pending.accepted) return error.StaleInitializerReplacement;
        pending.accepted = true;
        pending.completion = completion;
    }
    /// Only a submission that did not transfer native responsibility can abort.
    pub fn abort(self: *Book, token: u64) bool {
        const pending = self.pending orelse return false;
        if (pending.token != token or pending.accepted) return false;
        self.pending = null;
        return true;
    }
    pub fn cancel(self: *Book, token: u64) ?Delivery {
        const pending = if (self.pending) |*pending| pending else return null;
        if (pending.token != token or !pending.accepted or pending.cancelled) return null;
        pending.cancelled = true;
        const completion = pending.completion orelse return null;
        pending.completion = null;
        return .{ .completion = completion, .result = .cancelled };
    }
    pub fn detach(self: *Book) ?Delivery {
        self.sealed = true;
        const pending = if (self.pending) |*pending| pending else return null;
        pending.cancelled = true;
        const completion = pending.completion orelse return null;
        pending.completion = null;
        return .{ .completion = completion, .result = .detached };
    }
    /// Explicit controller recovery may restore the last owned logical batch.
    /// It cannot reuse a closed owner or bypass an unretired physical operation.
    pub fn recover(self: *Book) !void {
        if (self.sealed) return error.Closed;
        if (self.pending != null) return error.Busy;
        self.unavailable = false;
    }
    /// Called only after the native Add and required cleanup have retired. Every
    /// field is settled before returning a possible foreign delivery. SDK-owned
    /// handler references may still keep C-only storage/charges alive afterward.
    pub fn retire(self: *Book, token: u64, retirement: Retirement) !Retired {
        const pending = self.pending orelse return error.StaleInitializerReplacement;
        if (pending.token != token or !pending.accepted) return error.StaleInitializerReplacement;
        if (retirement == .installed and (pending.cancelled or self.sealed)) {
            self.unavailable = true;
            return error.UnremovedCancelledInitializer;
        }
        var result: Retired = .{};
        switch (retirement) {
            .installed => {
                self.revision = pending.revision;
                result.publish = true;
                if (pending.completion) |completion| result.delivery = .{ .completion = completion, .result = .{ .installed = self.revision } };
            },
            .discarded => {
                if (pending.completion != null) return error.UnfinishedInitializerCompletion;
            },
            .failed, .removal_uncertain => |code| {
                if (retirement == .removal_uncertain) self.unavailable = true;
                if (pending.completion) |completion| result.delivery = .{ .completion = completion, .result = .{ .native_failure = code } };
            },
        }
        self.pending = null;
        result.unavailable = self.unavailable;
        return result;
    }
};

const Probe = struct {
    calls: usize = 0,
    result: ?Result = null,
    book: ?*Book = null,
    reentrant_token: ?u64 = null,
    fn completion(self: *Probe) Completion {
        return .{ .context = self, .complete = complete };
    }
    fn complete(ptr: *anyopaque, result: Result) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.result = result;
        if (self.book) |book| self.reentrant_token = book.reserve(false) catch null;
    }
};

test "initializer cancellation delivers once but physical Add retains the slot" {
    var book: Book = .{};
    var probe: Probe = .{ .book = &book };
    const token = try book.reserve(false);
    try book.accept(token, probe.completion());
    book.cancel(token).?.invoke();
    try std.testing.expect(probe.calls == 1 and probe.result.? == .cancelled and probe.reentrant_token == null);
    try std.testing.expect(book.busy() and !book.allowsNavigation());
    try std.testing.expect(book.cancel(token) == null and book.detach() == null);
    const retired = try book.retire(token, .discarded);
    try std.testing.expect(retired.delivery == null and !retired.publish and book.revision == 0 and !book.busy());
    try std.testing.expectError(error.Closed, book.reserve(false));
}

test "late cleanup uncertainty after cancellation is fail closed without a second delivery" {
    var book: Book = .{};
    var probe: Probe = .{};
    const token = try book.reserve(false);
    try book.accept(token, probe.completion());
    book.cancel(token).?.invoke();
    const retired = try book.retire(token, .{ .removal_uncertain = -1 });
    try std.testing.expect(retired.unavailable and retired.delivery == null and probe.calls == 1 and book.revision == 0);
    try std.testing.expectError(error.InitializerUnavailable, book.reserve(false));
    try std.testing.expect(!book.allowsNavigation());
    try book.recover();
    try std.testing.expect(book.allowsNavigation() and book.revision == 0);
}

test "successful commit withdraws old transaction before completion creates a replacement" {
    var book: Book = .{};
    var probe: Probe = .{ .book = &book };
    const first = try book.reserve(false);
    try book.accept(first, probe.completion());
    const retired = try book.retire(first, .installed);
    try std.testing.expect(retired.publish and book.revision == 1 and !book.busy());
    retired.delivery.?.invoke();
    try std.testing.expect(probe.calls == 1 and probe.reentrant_token.? != first and book.busy());
    try std.testing.expectError(error.StaleInitializerReplacement, book.retire(first, .{ .failed = -1 }));
    try std.testing.expect(book.abort(probe.reentrant_token.?));
}

test "failure preserves revision and detach drains accepted completion exactly once" {
    var book: Book = .{ .revision = 8 };
    var probe: Probe = .{};
    try std.testing.expectError(error.Busy, book.reserve(true));
    const first = try book.reserve(false);
    try book.accept(first, probe.completion());
    const failed = try book.retire(first, .{ .failed = -77 });
    try std.testing.expect(!failed.publish and book.revision == 8 and book.allowsNavigation());
    failed.delivery.?.invoke();
    try std.testing.expectEqual(@as(i32, -77), probe.result.?.native_failure);
    const second = try book.reserve(false);
    try book.accept(second, probe.completion());
    book.detach().?.invoke();
    try std.testing.expect(book.detach() == null and book.cancel(second) == null and probe.calls == 2);
    try std.testing.expect((try book.retire(second, .discarded)).delivery == null and book.revision == 8);
}

test "unaccepted ownership and exhausted identities cannot revive a stale replacement" {
    var book: Book = .{};
    var probe: Probe = .{};
    const first = try book.reserve(false);
    try std.testing.expect(book.cancel(first) == null and book.abort(first) and probe.calls == 0);
    const second = try book.reserve(false);
    try std.testing.expect(second != first);
    try std.testing.expectError(error.StaleInitializerReplacement, book.accept(first, probe.completion()));
    try std.testing.expect(book.detach() == null);
    try std.testing.expectError(error.Closed, book.accept(second, probe.completion()));
    try std.testing.expect(book.abort(second) and probe.calls == 0);
    book = .{ .next_token = std.math.maxInt(u64) };
    try std.testing.expectError(error.InitializerTokenExhausted, book.reserve(false));
    book = .{ .revision = std.math.maxInt(u64) };
    try std.testing.expectError(error.InitializerTokenExhausted, book.reserve(false));
}

test "cancelled Add cannot publish or let recovery bypass native retirement" {
    var book: Book = .{ .revision = 4 };
    var probe: Probe = .{};
    const token = try book.reserve(false);
    try book.accept(token, probe.completion());
    book.cancel(token).?.invoke();
    try std.testing.expectError(error.Busy, book.recover());
    try std.testing.expectError(error.UnremovedCancelledInitializer, book.retire(token, .installed));
    try std.testing.expect(book.busy() and !book.allowsNavigation() and probe.calls == 1 and book.revision == 4);
    const retired = try book.retire(token, .discarded);
    try std.testing.expect(retired.delivery == null and retired.unavailable and probe.calls == 1 and book.revision == 4);
    try std.testing.expectError(error.InitializerUnavailable, book.reserve(false));
}

test "a cancelled Add failure returns its physical slot only at retirement" {
    var book: Book = .{};
    var probe: Probe = .{};
    const token = try book.reserve(false);
    try book.accept(token, probe.completion());
    book.cancel(token).?.invoke();
    try std.testing.expectError(error.Busy, book.reserve(false));
    const retired = try book.retire(token, .{ .failed = -1 });
    try std.testing.expect(retired.delivery == null and book.allowsNavigation());
    const next = try book.reserve(false);
    try std.testing.expect(next != token and book.abort(next) and probe.calls == 1);
}
