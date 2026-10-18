const std = @import("std");
pub const capacity = 16;
pub const Limits = struct {
    max_pending: u8 = capacity,
    max_script_bytes: u32 = 64 * 1024,
    max_result_bytes: u32 = 64 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity or self.max_script_bytes == 0 or self.max_script_bytes > 1024 * 1024 or self.max_result_bytes == 0 or self.max_result_bytes > 1024 * 1024) return error.InvalidScriptLimits;
    }
};
pub const Result = union(enum) {
    /// JSON-encoded result, borrowed only until the completion callback returns.
    json: []const u8,
    native_failure: i32,
    cancelled,
    timed_out,
    page_changed,
    detached,
    unavailable,
    timer_failed,
    result_too_large,
    invalid_result,
    out_of_memory,
};
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const Slot = struct { token: u64, page: u64, deadline: ?u64, completion: Completion };
/// Pure owner-thread bookkeeping. Native completion ownership is separate.
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, page: u64, deadline: ?u64, completion: Completion, limit: u8) !u64 {
        if (limit == 0 or limit > capacity) return error.InvalidScriptLimits;
        if (self.next_token == std.math.maxInt(u64)) return error.ScriptTokenExhausted;
        for (self.slots[0..limit]) |*slot| if (slot.* == null) {
            const token = self.next_token;
            self.next_token += 1;
            slot.* = .{ .token = token, .page = page, .deadline = deadline, .completion = completion };
            return token;
        };
        return error.Full;
    }
    pub fn take(self: *Book, token: u64) ?Slot {
        for (&self.slots) |*slot| if (slot.*) |value| {
            if (value.token == token) {
                slot.* = null;
                return value;
            }
        };
        return null;
    }
    pub fn earliest(self: *const Book) ?u64 {
        var deadline: ?u64 = null;
        for (self.slots) |slot| if (slot) |value| {
            if (value.deadline) |at| if (deadline == null or at < deadline.?) {
                deadline = at;
            };
        };
        return deadline;
    }
    /// Snapshot tokens before invoking business code; callback-created requests
    /// never accidentally become members of an older cancellation batch.
    pub fn tokens(self: *const Book, output: *[capacity]u64, expired_at: ?u64) []const u64 {
        var count: usize = 0;
        for (self.slots) |slot| if (slot) |value| {
            if (expired_at) |now| {
                if (value.deadline == null or value.deadline.? > now) continue;
            }
            output[count] = value.token;
            count += 1;
        };
        return output[0..count];
    }
};
test "bounded script bookkeeping never revives cancelled tokens or sweeps reentrant work" {
    var marker: u8 = 0;
    const completion: Completion = .{ .context = &marker, .complete = struct {
        fn complete(_: *anyopaque, _: Result) void {}
    }.complete };
    var book: Book = .{};
    const first = try book.reserve(1, 100, completion, 2);
    const second = try book.reserve(1, 200, completion, 2);
    try std.testing.expectError(error.Full, book.reserve(1, null, completion, 2));
    var storage: [capacity]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{first}, book.tokens(&storage, 100));
    try std.testing.expectEqual(100, book.earliest().?);
    const old = book.tokens(&storage, null);
    try std.testing.expect(book.take(first) != null);
    const replacement = try book.reserve(2, null, completion, 2);
    try std.testing.expect(replacement != first);
    for (old) |token| _ = book.take(token);
    try std.testing.expect(book.take(first) == null and book.take(second) == null);
    try std.testing.expect(book.take(replacement) != null);
    try std.testing.expect(book.earliest() == null);
    book.next_token = std.math.maxInt(u64);
    try std.testing.expectError(error.ScriptTokenExhausted, book.reserve(1, null, completion, 1));
    try std.testing.expectError(error.InvalidScriptLimits, (Limits{ .max_pending = 17 }).validate());
}
