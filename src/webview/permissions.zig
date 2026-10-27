const std = @import("std");
const schemes = @import("schemes.zig");

pub const capacity = 8;
pub const origin_capacity = 8;
pub const Kind = enum(u32) {
    microphone = 1,
    camera,
    geolocation,
    notifications,
    other_sensors,
    clipboard_read,
    multiple_automatic_downloads,
    file_read_write,
    autoplay,
    local_fonts,
    midi_system_exclusive,
    window_management,
    persistent_storage,
    pub fn fromNative(value: u32) ?Kind {
        if (value < 1 or value > 13) return null;
        return @fromBackingInt(@intCast(value));
    }
};
pub const Kinds = packed struct(u16) {
    microphone: bool = false,
    camera: bool = false,
    geolocation: bool = false,
    notifications: bool = false,
    other_sensors: bool = false,
    clipboard_read: bool = false,
    multiple_automatic_downloads: bool = false,
    file_read_write: bool = false,
    autoplay: bool = false,
    local_fonts: bool = false,
    midi_system_exclusive: bool = false,
    window_management: bool = false,
    persistent_storage: bool = false,
    reserved: u3 = 0,
    pub fn allows(self: Kinds, kind: Kind) bool {
        return @as(u16, @bitCast(self)) & (@as(u16, 1) << @intCast(@backingInt(kind) - 1)) != 0;
    }
    pub fn validate(self: Kinds) !void {
        if (self.reserved != 0 or @as(u16, @bitCast(self)) == 0) return error.InvalidPermissionKinds;
    }
};
pub const Grant = struct { origin: []const u8, kinds: Kinds };
pub const Owned = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Grant)) u8,
    grants: []const Grant,
    pub fn init(allocator: std.mem.Allocator, input: []const Grant, registrations: []const schemes.Registration) !Owned {
        if (input.len == 0 or input.len > origin_capacity) return error.InvalidPermissionOrigins;
        var text: [origin_capacity][schemes.origin_limit + 1]u8 = undefined;
        var origins: [origin_capacity][]const u8 = undefined;
        var bytes: usize = input.len * @sizeOf(Grant);
        for (input, 0..) |grant, i| {
            try grant.kinds.validate();
            origins[i] = try schemes.canonicalOrigin(&text[i], grant.origin, registrations);
            for (origins[0..i]) |earlier| if (std.mem.eql(u8, earlier, origins[i])) return error.DuplicatePermissionOrigin;
            bytes += origins[i].len;
        }
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Grant)), bytes);
        const grants = @as([*]Grant, @ptrCast(storage.ptr))[0..input.len];
        var offset = input.len * @sizeOf(Grant);
        for (grants, input, origins[0..input.len]) |*target, source, origin| {
            const owned = storage[offset..][0..origin.len];
            @memcpy(owned, origin);
            offset += origin.len;
            target.* = .{ .origin = owned, .kinds = source.kinds };
        }
        return .{ .allocator = allocator, .storage = storage, .grants = grants };
    }
    pub fn deinit(self: *Owned) void {
        if (self.storage) |storage| self.allocator.free(storage);
        self.storage = null;
        self.grants = &.{};
    }
};
pub const Limits = struct {
    max_pending: u8 = capacity,
    pub fn validate(self: Limits) !void {
        if (self.max_pending == 0 or self.max_pending > capacity) return error.InvalidPermissionLimits;
    }
};
/// Does not persist the native decision in the profile. The system Runtime may
/// still cache decisions in memory; this is not a promise of one host query per
/// page API call. It grants neither OS permissions nor successful device access.
pub const Decision = enum { allow_ephemeral, deny_ephemeral };
pub const Result = union(enum) {
    /// Native accepted this decision and the deferral completed successfully.
    decided: Decision,
    cancelled,
    timed_out,
    page_changed,
    detached,
    unavailable,
    timer_failed,
    native_failure: i32,
};
pub const Completion = struct { context: *anyopaque, complete: *const fn (*anyopaque, Result) void };
pub const DeferOptions = struct { timeout_ms: u32 = 30_000, completion: Completion };
pub const Slot = struct { token: u64 = 0, page: u64, deadline: u64, completion: ?Completion = null };
/// Owner-thread bookkeeping only. A separate native owner retains each deferral.
pub const Book = struct {
    slots: [capacity]?Slot = @splat(null),
    next_token: u64 = 1,
    pub fn reserve(self: *Book, slot: Slot, limit: u8) !u64 {
        try (Limits{ .max_pending = limit }).validate();
        if (self.next_token == std.math.maxInt(u64)) return error.PermissionTokenExhausted;
        for (self.slots[0..limit]) |*entry| if (entry.* == null) {
            var value = slot;
            value.token = self.next_token;
            self.next_token += 1;
            entry.* = value;
            return value.token;
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
    pub fn earliest(self: *const Book) ?u64 {
        var at: ?u64 = null;
        for (self.slots) |entry| if (entry) |slot| {
            at = if (at) |current| @min(current, slot.deadline) else slot.deadline;
        };
        return at;
    }
    pub fn tokens(self: *const Book, output: *[capacity]u64, page: ?u64, expired_at: ?u64) []const u64 {
        var count: usize = 0;
        for (self.slots) |entry| if (entry) |slot| {
            if (page) |selected| if (slot.page != selected) continue;
            if (expired_at) |now| if (slot.deadline > now) continue;
            output[count] = slot.token;
            count += 1;
        };
        return output[0..count];
    }
};

test "permission kinds are explicit and future native values never broaden access" {
    const kinds: Kinds = .{ .notifications = true, .persistent_storage = true };
    try kinds.validate();
    try std.testing.expect(kinds.allows(.notifications) and kinds.allows(.persistent_storage) and !kinds.allows(.camera));
    for (1..14) |native| try std.testing.expectEqual(@as(u32, @intCast(native)), @backingInt(Kind.fromNative(@intCast(native)).?));
    for ([_]u32{ 0, 14, std.math.maxInt(u32) }) |native| try std.testing.expect(Kind.fromNative(native) == null);
    try std.testing.expectError(error.InvalidPermissionKinds, (Kinds{}).validate());
    try std.testing.expectError(error.InvalidPermissionKinds, (Kinds{ .notifications = true, .reserved = 1 }).validate());
}
test "permission snapshots preserve replacement requests and capacity identity" {
    var marker: u8 = 0;
    const completion: Completion = .{ .context = &marker, .complete = struct {
        fn complete(_: *anyopaque, _: Result) void {}
    }.complete };
    var book: Book = .{};
    const first = try book.reserve(.{ .page = 7, .deadline = 100, .completion = completion }, 2);
    const second = try book.reserve(.{ .page = 8, .deadline = 200, .completion = completion }, 2);
    try std.testing.expectError(error.Full, book.reserve(.{ .page = 7, .deadline = 300, .completion = completion }, 2));
    try std.testing.expectEqual(@as(u64, 100), book.earliest().?);
    var storage: [capacity]u64 = undefined;
    try std.testing.expectEqualSlices(u64, &.{first}, book.tokens(&storage, 7, 200));
    const old = book.tokens(&storage, null, null);
    _ = book.take(first);
    const replacement = try book.reserve(.{ .page = 9, .deadline = 1, .completion = completion }, 2);
    for (old) |token| _ = book.take(token);
    try std.testing.expect(book.take(replacement) != null and book.take(second) == null and book.earliest() == null);
    book.next_token = std.math.maxInt(u64);
    try std.testing.expectError(error.PermissionTokenExhausted, book.reserve(.{ .page = 9, .deadline = 1, .completion = completion }, 1));
    try std.testing.expectError(error.InvalidPermissionLimits, (Limits{ .max_pending = 9 }).validate());
}
fn permissionPolicyFixture(allocator: std.mem.Allocator) !void {
    var origin = "HTTPS://EXAMPLE.TEST:443/".*;
    var owned = try Owned.init(allocator, &.{.{ .origin = &origin, .kinds = .{ .notifications = true } }}, &.{});
    defer owned.deinit();
    origin[0] = 'x';
    try std.testing.expectEqualStrings("https://example.test", owned.grants[0].origin);
}
test "permission grant metadata is owned canonical and transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, permissionPolicyFixture, .{});
    try std.testing.expectError(error.DuplicatePermissionOrigin, Owned.init(std.testing.allocator, &.{ .{ .origin = "https://example.test", .kinds = .{ .camera = true } }, .{ .origin = "HTTPS://EXAMPLE.TEST:443", .kinds = .{ .microphone = true } } }, &.{}));
    try std.testing.expectError(error.InvalidPermissionOrigins, Owned.init(std.testing.failing_allocator, &.{}, &.{}));
}
