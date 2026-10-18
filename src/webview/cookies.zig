const std = @import("std");

pub const capacity = 8;
pub const row_capacity = 128;
pub const input_byte_capacity = 32 * 1024;
pub const SameSite = enum(u32) { none, lax, strict };
pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    /// Unix seconds; null denotes a session cookie.
    expires: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: SameSite = .lax,
};
pub const Key = struct { name: []const u8, domain: []const u8, path: []const u8 = "/" };
pub const Filter = struct {
    /// The engine performs URL eligibility matching. Cookies are not isolated
    /// by port. Optional fields are exact native identity byte comparisons.
    url: []const u8,
    name: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
};
pub const ClearScope = enum { entire_profile_cookies };
pub const Limits = struct {
    max_pending: u8 = capacity,
    max_rows: u16 = row_capacity,
    /// A transferred Batch owns at most this many requested bytes, including
    /// its row metadata. Retaining multiple Batches is the caller's budget.
    result_bytes: usize = 64 * 1024,
    /// Requested project malloc/caller-allocator bytes: Zig owner, C adapter
    /// owner/Op/raw input copies and the in-flight Batch candidate. GLib/libsoup
    /// objects (including SoupCookie's duplicate strings, GCancellable/GTask)
    /// and engine GList storage are outside this counter. Fixed pending and
    /// input limits bound their counts/sizes, not their native allocation cost.
    bytes: usize = 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity or self.max_rows == 0 or self.max_rows > row_capacity or self.result_bytes == 0 or self.result_bytes > 256 * 1024 or self.bytes == 0 or self.bytes > 4 * 1024 * 1024) return error.InvalidCookieLimits;
    }
};

fn validText(value: []const u8, maximum: usize) bool {
    return value.len <= maximum and std.mem.indexOfScalar(u8, value, 0) == null and std.unicode.utf8ValidateSlice(value);
}
pub fn validateKey(key: Key) !void {
    if (!validText(key.name, 512) or key.name.len == 0 or !validText(key.domain, 1024) or key.domain.len == 0 or !validText(key.path, 4096) or key.path.len == 0 or key.path[0] != '/') return error.InvalidCookie;
    for (key.name) |c| if (c <= 32 or c >= 127 or c == 34 or c == 92 or std.mem.indexOfScalar(u8, "()<>@,;:/[]?={}", c) != null) return error.InvalidCookie;
    for (key.domain) |c| if (c <= 32 or c >= 127 or c == '/' or c == '\\' or c == ':' or c == ';') return error.InvalidCookie;
    for (key.path) |c| if (c < 32 or c == 127 or c == ';') return error.InvalidCookie;
}
pub fn validateCookie(cookie: Cookie) !void {
    try validateKey(.{ .name = cookie.name, .domain = cookie.domain, .path = cookie.path });
    if (!validText(cookie.value, 16384)) return error.InvalidCookie;
    for (cookie.value) |c| if (c < 32 or c == 127 or c == ';') return error.InvalidCookie;
    // GDateTime's documented Unix range, checked before native conversion.
    if (cookie.expires) |expires| if (expires < -62135596800 or expires > 253402300799) return error.InvalidCookie;
    if (cookie.same_site == .none and !cookie.secure) return error.InvalidCookie;
}
/// Native deletion uses the observed value as well as name/domain/path. It
/// does not require that a legacy cookie satisfy current write policy.
pub fn validateDelete(cookie: Cookie) !void {
    try validateKey(.{ .name = cookie.name, .domain = cookie.domain, .path = cookie.path });
    if (!validText(cookie.value, 16384)) return error.InvalidCookie;
}
pub fn validateFilter(filter: Filter) !void {
    if (!validText(filter.url, 8192) or filter.url.len == 0) return error.InvalidCookieURL;
    for (filter.url) |c| if (c <= 32 or c == 127) return error.InvalidCookieURL;
    const uri = std.Uri.parse(filter.url) catch return error.InvalidCookieURL;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) or uri.host == null or uri.user != null or uri.password != null) return error.InvalidCookieURL;
    if (filter.name) |value| if (!validText(value, 512)) return error.InvalidCookieFilter;
    if (filter.domain) |value| if (!validText(value, 1024)) return error.InvalidCookieFilter;
    if (filter.path) |value| if (!validText(value, 4096)) return error.InvalidCookieFilter;
}
/// Nonempty native replacement, not a clear followed by individual writes.
/// Exact duplicate identities are rejected; native domain canonicalization is
/// still the engine's policy and is not inferred from these source bytes.
pub fn validateReplacement(rows: []const Cookie, maximum: usize) !void {
    if (rows.len == 0) return error.EmptyCookieReplacement;
    if (maximum == 0 or maximum > row_capacity or rows.len > maximum) return error.CapacityExceeded;
    for (rows, 0..) |row, at| {
        try validateCookie(row);
        for (rows[0..at]) |previous| if (std.mem.eql(u8, previous.name, row.name) and std.mem.eql(u8, previous.domain, row.domain) and std.mem.eql(u8, previous.path, row.path)) return error.DuplicateCookieIdentity;
    }
}
/// Descriptor-only preflight before scanning strings or comparing identities.
/// The native adapter supplies its explicit per-row metadata overhead; every
/// string has a NUL terminator in the later owning raw input block.
pub fn measureReplacement(rows: []const Cookie, maximum: usize, row_metadata_bytes: usize) !usize {
    if (rows.len == 0) return error.EmptyCookieReplacement;
    if (maximum == 0 or maximum > row_capacity or rows.len > maximum) return error.CapacityExceeded;
    var bytes = std.math.mul(usize, rows.len, row_metadata_bytes) catch return error.CapacityExceeded;
    if (bytes > input_byte_capacity) return error.CapacityExceeded;
    for (rows) |row| for ([_][]const u8{ row.name, row.value, row.domain, row.path }) |field| {
        bytes = std.math.add(usize, bytes, field.len) catch return error.CapacityExceeded;
        bytes = std.math.add(usize, bytes, 1) catch return error.CapacityExceeded;
        if (bytes > input_byte_capacity) return error.CapacityExceeded;
    };
    if (bytes > input_byte_capacity) return error.CapacityExceeded;
    return bytes;
}
pub fn matches(filter: Filter, cookie: Cookie) bool {
    if (filter.name) |v| if (!std.mem.eql(u8, v, cookie.name)) return false;
    if (filter.domain) |v| if (!std.mem.eql(u8, v, cookie.domain)) return false;
    if (filter.path) |v| if (!std.mem.eql(u8, v, cookie.path)) return false;
    return true;
}

/// Linear, caller-owned result. It contains no Store, Profile, App or GLib
/// pointer and may outlive them. The supplied allocator must still be alive.
/// Move with take; copying does not create another owner.
pub const Batch = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Cookie)) u8,
    rows: []const Cookie,

    pub fn measure(rows: []const Cookie, limits: Limits) !usize {
        try limits.validate();
        if (rows.len > limits.max_rows) return error.CookieResultTooLarge;
        var bytes = rows.len * @sizeOf(Cookie);
        for (rows) |row| {
            // Returned native values are copied as data, not reinterpreted as
            // a writable Cookie. For example SameSite=None may predate policy.
            for ([_][]const u8{ row.name, row.value, row.domain, row.path }) |field| {
                if (!validText(field, 16384)) return error.InvalidCookieResult;
                bytes = std.math.add(usize, bytes, field.len) catch return error.CookieResultTooLarge;
            }
        }
        // Even the empty result has an explicit move state and allocation.
        bytes = @max(bytes, 1);
        if (bytes > limits.result_bytes) return error.CookieResultTooLarge;
        return bytes;
    }
    pub fn init(allocator: std.mem.Allocator, rows: []const Cookie, limits: Limits) !Batch {
        const bytes = try measure(rows, limits);
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Cookie)), bytes);
        const copied = @as([*]Cookie, @ptrCast(storage.ptr))[0..rows.len];
        var offset = rows.len * @sizeOf(Cookie);
        for (copied, rows) |*out, row| {
            out.* = row;
            out.name = copy(storage, &offset, row.name);
            out.value = copy(storage, &offset, row.value);
            out.domain = copy(storage, &offset, row.domain);
            out.path = copy(storage, &offset, row.path);
        }
        return .{ .allocator = allocator, .storage = storage, .rows = copied };
    }
    pub fn isOwned(self: *const Batch) bool {
        return self.storage != null;
    }
    pub fn take(self: *Batch) !Batch {
        if (!self.isOwned()) return error.BatchMoved;
        const result = self.*;
        self.storage = null;
        self.rows = &.{};
        return result;
    }
    pub fn deinit(self: *Batch) void {
        const allocator = self.allocator;
        const storage = self.storage;
        self.storage = null;
        self.rows = &.{};
        if (storage) |bytes| allocator.free(bytes);
    }
    fn copy(storage: []u8, at: *usize, input: []const u8) []const u8 {
        const output = storage[at.*..][0..input.len];
        @memcpy(output, input);
        at.* += input.len;
        return output;
    }
};
pub const Result = union(enum) {
    /// Ownership transfers to the completion callback, including an empty Batch.
    cookies: Batch,
    /// The SDK reported success. Deleting an old expected value may be a no-op;
    /// this is not an atomic compare-delete or persistence acknowledgement.
    completed,
    cancelled,
    stopped,
    closed,
    out_of_memory,
    result_too_large,
    invalid_result,
    /// null is a failed SDK boolean without a supplied GError. Code zero is
    /// retained when a real nonzero GQuark domain accompanies it.
    native_failure: ?struct { domain: u32, code: i32 },
};
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const Slot = struct { token: u64, completion: Completion, query: bool };
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, completion: Completion, limit: u8, query: bool) !u64 {
        if (limit == 0 or limit > capacity) return error.InvalidCookieLimits;
        if (self.next_token == std.math.maxInt(u64)) return error.CookieTokenExhausted;
        for (self.slots[0..limit]) |*slot| if (slot.* == null) {
            const token = self.next_token;
            self.next_token += 1;
            slot.* = .{ .token = token, .completion = completion, .query = query };
            return token;
        };
        return error.Full;
    }
    pub fn take(self: *Book, token: u64) ?Slot {
        for (&self.slots) |*slot| if (slot.*) |value| if (value.token == token) {
            slot.* = null;
            return value;
        };
        return null;
    }
    pub fn takeAll(self: *Book) [capacity]?Slot {
        const result = self.slots;
        self.slots = @splat(null);
        return result;
    }
    pub fn contains(self: *const Book, token: u64) bool {
        for (self.slots) |slot| if (slot) |value| if (value.token == token) return true;
        return false;
    }
};

fn batchFixture(allocator: std.mem.Allocator) !void {
    var batch = try Batch.init(allocator, &.{.{ .name = "name", .value = "value", .domain = ".example.test", .path = "/" }}, .{});
    defer batch.deinit();
    try std.testing.expectEqualStrings("value", batch.rows[0].value);
    var moved = try batch.take();
    defer moved.deinit();
    try std.testing.expectError(error.BatchMoved, batch.take());
}
test "cookie batch owns bounded storage and empty move state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, batchFixture, .{});
    var empty = try Batch.init(std.testing.allocator, &.{}, .{});
    var moved = try empty.take();
    defer moved.deinit();
    empty.deinit();
    try std.testing.expect(!empty.isOwned() and moved.isOwned() and moved.rows.len == 0);
    try std.testing.expectError(error.CookieResultTooLarge, Batch.init(std.testing.failing_allocator, &.{.{ .name = "n", .value = "v", .domain = "d", .path = "/" }}, .{ .result_bytes = 1 }));
}
test "cookie identities are exact and URL eligibility is delegated" {
    const cookie: Cookie = .{ .name = "n", .value = "v", .domain = ".example.test", .path = "/", .secure = true, .same_site = .none };
    try validateCookie(cookie);
    try validateFilter(.{ .url = "https://example.test:9443/path" });
    try std.testing.expect(matches(.{ .url = "https://example.test/", .domain = ".example.test" }, cookie));
    try std.testing.expect(!matches(.{ .url = "https://example.test/", .domain = "example.test" }, cookie));
    try std.testing.expectError(error.InvalidCookieURL, validateFilter(.{ .url = "file:///tmp/private" }));
    try std.testing.expectError(error.InvalidCookieURL, validateFilter(.{ .url = "http://user:secret@example.test/" }));
    try std.testing.expectError(error.InvalidCookie, validateCookie(.{ .name = "n", .value = "v", .domain = "example.test", .path = "/", .same_site = .none }));
    try validateDelete(.{ .name = "legacy", .value = "value", .domain = "example.test", .path = "/", .same_site = .none, .secure = false, .expires = std.math.maxInt(i64) });
}
test "cookie logical slots take a whole batch before callback reentry" {
    var marker: u8 = 0;
    const completion: Completion = .{ .context = &marker, .complete = struct {
        fn call(_: *anyopaque, _: Result) void {}
    }.call };
    var book: Book = .{};
    const a = try book.reserve(completion, 1, true);
    try std.testing.expectError(error.Full, book.reserve(completion, 1, true));
    const old = book.takeAll();
    const b = try book.reserve(completion, 1, false);
    try std.testing.expect(a != b and old[0].?.token == a and book.take(a) == null and book.contains(b));
    book.next_token = std.math.maxInt(u64);
    try std.testing.expectError(error.CookieTokenExhausted, book.reserve(completion, 1, true));
}

test "cookie batch withdraws its whole entry before recursive allocator free" {
    const Reentry = struct {
        value: ?*Batch = null,
        frees: usize = 0,
        withdrawn: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(_: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(n, alignment, ra);
        }
        fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frees += 1;
            if (self.frees != 1) return;
            self.withdrawn = !self.value.?.isOwned() and self.value.?.rows.len == 0;
            self.value.?.deinit();
            std.testing.allocator.rawFree(memory, alignment, ra);
        }
    };
    var reentry: Reentry = .{};
    var batch = try Batch.init(reentry.allocator(), &.{.{ .name = "n", .value = "v", .domain = "host.test", .path = "/" }}, .{});
    reentry.value = &batch;
    batch.deinit();
    try std.testing.expect(reentry.withdrawn and reentry.frees == 1);
}

test "cookie output limits reject rows and UTF8 before any allocation" {
    var rows: [row_capacity + 1]Cookie = @splat(.{ .name = "n", .value = "", .domain = "host.test", .path = "/" });
    try std.testing.expectError(error.CookieResultTooLarge, Batch.init(std.testing.failing_allocator, &rows, .{}));
    rows[0].value = "\xff";
    try std.testing.expectError(error.InvalidCookieResult, Batch.init(std.testing.failing_allocator, rows[0..1], .{}));
    try std.testing.expectError(error.InvalidCookieLimits, (Limits{ .max_pending = 9 }).validate());
    try std.testing.expectError(error.InvalidCookieLimits, (Limits{ .max_rows = 129 }).validate());
    try std.testing.expectError(error.InvalidCookieLimits, (Limits{ .result_bytes = 256 * 1024 + 1 }).validate());
}

test "replacement validates a nonempty bounded set and exact source identity" {
    const first: Cookie = .{ .name = "same", .value = "value", .domain = "host.test", .path = "/" };
    try std.testing.expectError(error.EmptyCookieReplacement, validateReplacement(&.{}, row_capacity));
    try std.testing.expectError(error.CapacityExceeded, validateReplacement(&.{ first, first }, 1));
    try std.testing.expectError(error.DuplicateCookieIdentity, validateReplacement(&.{ first, first }, row_capacity));
    var other = first;
    other.path = "/nested";
    try validateReplacement(&.{ first, other }, row_capacity);
    other = first;
    other.domain = ".host.test";
    try validateReplacement(&.{ first, other }, row_capacity);
    other = first;
    other.domain = "HOST.test";
    try validateReplacement(&.{ first, other }, row_capacity);
    other.value = "\xff";
    try std.testing.expectError(error.InvalidCookie, validateReplacement(&.{other}, row_capacity));
    const unreadable: [*]const u8 = @ptrFromInt(4096);
    const oversized: Cookie = .{ .name = unreadable[0..input_byte_capacity], .value = "", .domain = "h", .path = "/" };
    try std.testing.expectError(error.CapacityExceeded, measureReplacement(&.{oversized}, row_capacity, 104));
    try std.testing.expectError(error.CapacityExceeded, measureReplacement(&.{first}, row_capacity, std.math.maxInt(usize)));
}
