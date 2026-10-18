const std = @import("std");

pub const byte_range = @import("byte_range.zig");

pub const Method = enum(u32) { get, head, post, put, patch, delete, options };
pub const MethodSet = packed struct(u8) {
    get: bool = true,
    head: bool = true,
    post: bool = false,
    put: bool = false,
    patch: bool = false,
    delete: bool = false,
    options: bool = false,
    reserved: u1 = 0,
    pub fn allows(self: MethodSet, method: Method) bool {
        return @as(u8, @bitCast(self)) & (@as(u8, 1) << @intCast(@intFromEnum(method))) != 0;
    }
};
pub const Header = struct { name: []const u8, value: []const u8 };
pub const HeaderGrant = struct { name: []const u8, exact_value: ?[]const u8 = null };
pub const Response = struct {
    status: u16 = 200,
    mime: []const u8 = "application/octet-stream",
    headers: []const Header = &.{},
    /// Complete representation bytes. HEAD uses their length without sending a body.
    bytes: []const u8 = "",
};
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    return true;
}
pub fn validValue(value: []const u8) bool {
    if (value.len > 2048) return false;
    for (value) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}
pub fn browserManaged(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "sec-")) return true;
    const names = [_][]const u8{ "accept", "accept-encoding", "accept-language", "user-agent", "origin", "referer", "cookie", "host", "connection", "content-length", "cache-control", "pragma", "dnt", "priority", "upgrade-insecure-requests", "if-match", "if-none-match", "if-modified-since", "if-unmodified-since", "if-range", "access-control-request-method", "access-control-request-headers" };
    for (names) |managed| if (std.ascii.eqlIgnoreCase(name, managed)) return true;
    return false;
}
pub fn validateGrants(grants: []const HeaderGrant) !void {
    if (grants.len > 16) return error.TooManyHeaderGrants;
    var bytes: usize = 0;
    for (grants, 0..) |grant, i| {
        if (!validName(grant.name) or browserManaged(grant.name) or std.ascii.startsWithIgnoreCase(grant.name, "proxy-") or std.ascii.eqlIgnoreCase(grant.name, "transfer-encoding") or std.ascii.eqlIgnoreCase(grant.name, "upgrade") or std.ascii.eqlIgnoreCase(grant.name, "te") or std.ascii.eqlIgnoreCase(grant.name, "trailer") or std.ascii.eqlIgnoreCase(grant.name, "keep-alive")) return error.InvalidHeaderGrant;
        if (grant.exact_value) |value| if (!validValue(value)) return error.InvalidHeaderGrant;
        bytes += grant.name.len + if (grant.exact_value) |value| value.len else @as(usize, 0);
        if (bytes > 8192) return error.HeaderBudgetExceeded;
        for (grants[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, grant.name)) return error.DuplicateHeaderGrant;
    }
}
pub fn allowsHeader(grants: []const HeaderGrant, header: Header) bool {
    if (!validName(header.name) or !validValue(header.value)) return false;
    if (browserManaged(header.name)) return true;
    for (grants) |grant| if (std.ascii.eqlIgnoreCase(grant.name, header.name)) {
        return if (grant.exact_value) |value| std.mem.eql(u8, value, header.value) else true;
    };
    return false;
}
pub fn validateResponse(response: Response, max_bytes: usize) !void {
    if (response.status < 200 or response.status > 599) return error.InvalidStatus;
    if (response.mime.len == 0 or response.mime.len > 127 or !validValue(response.mime)) return error.InvalidMime;
    if (response.bytes.len > max_bytes) return error.ResourceTooLarge;
    if ((response.status == 204 or response.status == 205 or response.status == 304) and response.bytes.len != 0) return error.UnexpectedResponseBody;
    if (response.headers.len > 16) return error.TooManyResponseHeaders;
    var bytes: usize = 0;
    const reserved = [_][]const u8{ "content-type", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization" };
    for (response.headers, 0..) |header, i| {
        if (!validName(header.name) or !validValue(header.value)) return error.InvalidResponseHeader;
        for (reserved) |name| if (std.ascii.eqlIgnoreCase(header.name, name)) return error.ReservedResponseHeader;
        for (response.headers[0..i]) |earlier| if (std.ascii.eqlIgnoreCase(earlier.name, header.name)) return error.DuplicateResponseHeader;
        bytes += header.name.len + header.value.len + 4;
        if (bytes > 8192) return error.HeaderBudgetExceeded;
    }
}

/// Owns a single allocation. Do not copy after init; move by clearing the source.
/// Preparing on a worker does not remove the bounded native copy at commit.
pub const OwnedResponse = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Header)) u8,
    response: Response,
    pub fn init(allocator: std.mem.Allocator, response: Response, max_bytes: usize) !OwnedResponse {
        if (max_bytes == 0 or max_bytes > 16 * 1024 * 1024) return error.InvalidResourceLimit;
        try validateResponse(response, max_bytes);
        var bytes = try std.math.add(usize, response.headers.len * @sizeOf(Header), response.mime.len);
        bytes = try std.math.add(usize, bytes, response.bytes.len);
        for (response.headers) |header| bytes = try std.math.add(usize, bytes, header.name.len + header.value.len);
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Header)), bytes);
        errdefer allocator.free(storage);
        const headers = @as([*]Header, @ptrCast(storage.ptr))[0..response.headers.len];
        var offset = response.headers.len * @sizeOf(Header);
        const mime = copy(storage, &offset, response.mime);
        const body = copy(storage, &offset, response.bytes);
        for (headers, response.headers) |*output, input| output.* = .{ .name = copy(storage, &offset, input.name), .value = copy(storage, &offset, input.value) };
        return .{ .allocator = allocator, .storage = storage, .response = .{ .status = response.status, .mime = mime, .headers = headers, .bytes = body } };
    }
    fn copy(storage: []u8, offset: *usize, input: []const u8) []const u8 {
        const output = storage[offset.*..][0..input.len];
        @memcpy(output, input);
        offset.* += input.len;
        return output;
    }
    pub fn deinit(self: *OwnedResponse) void {
        const storage = self.storage;
        const allocator = self.allocator;
        self.storage = null;
        self.response = .{};
        if (storage) |bytes| allocator.free(bytes);
    }
};

test "owned response revokes storage before allocator release reenters deinit" {
    const Reentry = struct {
        owned: ?*OwnedResponse = null,
        frees: usize = 0,
        revoked: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(_: *anyopaque, count: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(count, alignment, ra);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.frees += 1;
            // Retain the real allocation during reentry and suppress a second
            // free, so the regression diagnoses ownership without invoking UB.
            if (self.frees == 1) {
                const owned = self.owned.?;
                self.revoked = owned.storage == null and owned.response.bytes.len == 0 and owned.response.headers.len == 0;
                owned.deinit();
                std.testing.allocator.rawFree(bytes, alignment, ra);
            }
        }
    };
    var reentry: Reentry = .{};
    var owned = try OwnedResponse.init(reentry.allocator(), .{ .bytes = "body", .headers = &.{.{ .name = "X-Owner", .value = "once" }} }, 16);
    reentry.owned = &owned;
    owned.deinit();
    try std.testing.expect(reentry.revoked);
    try std.testing.expectEqual(@as(usize, 1), reentry.frees);
    owned.deinit();
    try std.testing.expectEqual(@as(usize, 1), reentry.frees);
}

fn ownedFixture(allocator: std.mem.Allocator) !void {
    var owned = try OwnedResponse.init(allocator, .{ .status = 201, .mime = "text/plain", .headers = &.{.{ .name = "X-Fixture", .value = "value" }}, .bytes = "owned body" }, 1024);
    defer owned.deinit();
    try std.testing.expectEqualStrings("owned body", owned.response.bytes);
    try std.testing.expectEqualStrings("value", owned.response.headers[0].value);
}
test "response validates before allocation and owns a bounded immutable snapshot" {
    try std.testing.expectError(error.InvalidResourceLimit, OwnedResponse.init(std.testing.failing_allocator, .{}, std.math.maxInt(usize)));
    try std.testing.expectError(error.InvalidResourceLimit, OwnedResponse.init(std.testing.failing_allocator, .{}, 0));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedFixture, .{});
    try std.testing.expectError(error.ResourceTooLarge, validateResponse(.{ .bytes = "12" }, 1));
    try std.testing.expectError(error.UnexpectedResponseBody, validateResponse(.{ .status = 204, .bytes = "x" }, 100));
    try std.testing.expectError(error.ReservedResponseHeader, validateResponse(.{ .headers = &.{.{ .name = "Content-Length", .value = "999" }} }, 100));
    try std.testing.expectError(error.InvalidResponseHeader, validateResponse(.{ .headers = &.{.{ .name = "X-Test", .value = "ok\r\nInjected: true" }} }, 100));
    try std.testing.expectError(error.DuplicateResponseHeader, validateResponse(.{ .headers = &.{ .{ .name = "x-test", .value = "a" }, .{ .name = "X-TEST", .value = "b" } } }, 100));
}
test "method and header grants fail closed beyond the documented browser set" {
    const methods: MethodSet = .{};
    try std.testing.expect(methods.allows(.get) and methods.allows(.head) and !methods.allows(.post));
    const grants = [_]HeaderGrant{ .{ .name = "Content-Type", .exact_value = "text/plain" }, .{ .name = "Authorization", .exact_value = "Bearer fixture" } };
    try validateGrants(&grants);
    try std.testing.expect(allowsHeader(&grants, .{ .name = "ACCEPT", .value = "*/*" }));
    try std.testing.expect(allowsHeader(&grants, .{ .name = "content-type", .value = "text/plain" }));
    try std.testing.expect(!allowsHeader(&grants, .{ .name = "Content-Type", .value = "Text/Plain" }));
    try std.testing.expect(!allowsHeader(&grants, .{ .name = "Range", .value = "bytes=0-2" }));
    try std.testing.expect(!allowsHeader(&grants, .{ .name = "X-Unknown", .value = "true" }));
    try std.testing.expectError(error.InvalidHeaderGrant, validateGrants(&.{.{ .name = "Cookie" }}));
    try std.testing.expectError(error.DuplicateHeaderGrant, validateGrants(&.{ .{ .name = "X-Custom" }, .{ .name = "x-custom" } }));
}

test {
    _ = @import("byte_range_test.zig");
}
