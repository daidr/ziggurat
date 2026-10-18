const std = @import("std");
const http = @import("ziggurat_http_response");

pub const Method = http.Method;
pub const MethodSet = http.MethodSet;
pub const Header = http.Header;
pub const HeaderGrant = http.HeaderGrant;
pub const Response = http.Response;
pub const validName = http.validName;
pub const validValue = http.validValue;
pub const browserManaged = http.browserManaged;
pub const validateGrants = http.validateGrants;
pub const allowsHeader = http.allowsHeader;
pub const validateResponse = http.validateResponse;
pub const OwnedResponse = http.OwnedResponse;

pub const Limits = struct {
    max_pending: u8 = capacity,
    max_response_bytes: u32 = 16 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity or self.max_response_bytes == 0 or self.max_response_bytes > 16 * 1024 * 1024) return error.InvalidResourceLimits;
    }
};
pub const capacity = 8;
pub const Result = union(enum) { responded, cancelled, timed_out, page_changed, detached, unavailable, timer_failed, native_failure: i32 };
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const DeferOptions = struct { timeout_ms: u32 = 30_000, completion: ?Completion = null };
pub const Slot = struct { token: u64 = 0, page: u64, deadline: u64, completion: ?Completion };
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, slot: Slot, limit: u8) !u64 {
        if (limit == 0 or limit > capacity) return error.InvalidResourceLimits;
        if (self.next_token == std.math.maxInt(u64)) return error.RequestTokenExhausted;
        for (self.slots[0..limit]) |*entry| if (entry.* == null) {
            var next = slot;
            next.token = self.next_token;
            self.next_token += 1;
            entry.* = next;
            return next.token;
        };
        return error.Full;
    }
    pub fn take(self: *Book, token: u64) ?Slot {
        for (&self.slots) |*entry| if (entry.*) |slot| if (slot.token == token) {
            entry.* = null;
            return slot;
        };
        return null;
    }
    pub fn tokens(self: *const Book, output: *[capacity]u64, expired_at: ?u64) []const u64 {
        var count: usize = 0;
        for (self.slots) |entry| if (entry) |slot| {
            if (expired_at) |now| if (slot.deadline > now) continue;
            output[count] = slot.token;
            count += 1;
        };
        return output[0..count];
    }
    pub fn earliest(self: *const Book) ?u64 {
        var earliest_at: ?u64 = null;
        for (self.slots) |entry| if (entry) |slot| {
            earliest_at = if (earliest_at) |at| @min(at, slot.deadline) else slot.deadline;
        };
        return earliest_at;
    }
};

test "WebView HTTP response names preserve the shared type identity" {
    try std.testing.expect(Method == http.Method);
    try std.testing.expect(MethodSet == http.MethodSet);
    try std.testing.expect(Header == http.Header);
    try std.testing.expect(HeaderGrant == http.HeaderGrant);
    try std.testing.expect(Response == http.Response);
    try std.testing.expect(OwnedResponse == http.OwnedResponse);
}
