const std = @import("std");

pub const Header = struct { name: []const u8, value: []const u8 };
/// Application metadata, not an HTTP response or cookie mutation.
pub const Head = struct {
    status: u16 = 200,
    mime: []const u8 = "application/octet-stream",
    headers: []const Header = &.{},
    length: ?u53 = null,
};
pub const Body = struct { base64: []const u8, bytes: u32 };
/// Exactly one field is nonnull. Head is always the first wire chunk.
pub const Frame = struct { head: ?Head = null, body: ?Body = null };
pub const Summary = struct { bytes: u53, chunks: u32 };
pub const Failure = enum { denied, unavailable, cancelled, full, budget_exceeded, failed };

fn asciiValue(value: []const u8, maximum: usize) bool {
    if (value.len > maximum) return false;
    for (value) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}
fn headerName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    return true;
}
pub fn validateHead(head: Head, max_total_bytes: u64, max_header_bytes: usize) !void {
    if (max_header_bytes == 0 or max_header_bytes > 8192) return error.InvalidLimits;
    if (head.status < 200 or head.status > 599 or head.mime.len == 0 or !asciiValue(head.mime, 127)) return error.InvalidHead;
    if (head.length) |length| {
        if (length > max_total_bytes) return error.BodyBudgetExceeded;
        if ((head.status == 204 or head.status == 205 or head.status == 304) and length != 0) return error.UnexpectedBody;
    }
    if (head.headers.len > 16) return error.InvalidHeader;
    const reserved = [_][]const u8{ "content-type", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization" };
    var bytes: usize = 0;
    for (head.headers, 0..) |header, index| {
        if (!headerName(header.name) or !asciiValue(header.value, 2048)) return error.InvalidHeader;
        for (reserved) |name| if (std.ascii.eqlIgnoreCase(header.name, name)) return error.InvalidHeader;
        for (head.headers[0..index]) |earlier| if (std.ascii.eqlIgnoreCase(header.name, earlier.name)) return error.InvalidHeader;
        bytes += header.name.len + header.value.len + 4;
        if (bytes > max_header_bytes) return error.HeaderBudgetExceeded;
    }
}

/// Explicit single-allocation owner. Move with take; no copied owner may be
/// deinitialized twice. Used only on the bridge's owner thread.
pub const OwnedHead = struct {
    allocator: std.mem.Allocator,
    storage: ?[]align(@alignOf(Header)) u8,
    value: Head,

    pub fn requiredBytes(head: Head, max_total_bytes: u64, max_header_bytes: usize) !usize {
        try validateHead(head, max_total_bytes, max_header_bytes);
        var bytes = head.headers.len * @sizeOf(Header) + head.mime.len;
        for (head.headers) |header| bytes += header.name.len + header.value.len;
        return bytes;
    }
    pub fn init(allocator: std.mem.Allocator, head: Head, max_total_bytes: u64, max_header_bytes: usize) !OwnedHead {
        const required = try requiredBytes(head, max_total_bytes, max_header_bytes);
        const storage = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(Header)), required);
        const headers = @as([*]Header, @ptrCast(storage.ptr))[0..head.headers.len];
        var cursor = headers.len * @sizeOf(Header);
        const mime = copy(storage, &cursor, head.mime);
        for (headers, head.headers) |*out, input| out.* = .{ .name = copy(storage, &cursor, input.name), .value = copy(storage, &cursor, input.value) };
        return .{ .allocator = allocator, .storage = storage, .value = .{ .status = head.status, .mime = mime, .headers = headers, .length = head.length } };
    }
    fn copy(storage: []u8, cursor: *usize, source: []const u8) []const u8 {
        const output = storage[cursor.*..][0..source.len];
        @memcpy(output, source);
        cursor.* += source.len;
        return output;
    }
    pub fn take(self: *OwnedHead) !OwnedHead {
        const storage = self.storage orelse return error.Released;
        self.storage = null;
        return .{ .allocator = self.allocator, .storage = storage, .value = self.value };
    }
    pub fn deinit(self: *OwnedHead) void {
        const storage = self.storage orelse return;
        const allocator = self.allocator;
        self.storage = null;
        self.value = .{};
        allocator.free(storage);
    }
};

pub fn base64Bytes(byte_count: usize) !usize {
    if (byte_count == 0 or byte_count > 16 * 1024) return error.InvalidChunk;
    return std.base64.standard.Encoder.calcSize(byte_count);
}
pub fn encodeBody(scratch: []u8, bytes: []const u8) !Body {
    const size = try base64Bytes(bytes.len);
    if (scratch.len < size) return error.BufferTooSmall;
    return .{ .base64 = std.base64.standard.Encoder.encode(scratch[0..size], bytes), .bytes = @intCast(bytes.len) };
}

fn headAllocationFailure(allocator: std.mem.Allocator) !void {
    var owned = try OwnedHead.init(allocator, .{ .headers = &.{.{ .name = "x-owned", .value = "value" }}, .length = 10 }, 100, 8192);
    defer owned.deinit();
    var moved = try owned.take();
    defer moved.deinit();
    try std.testing.expectError(error.Released, owned.take());
    try std.testing.expectEqualStrings("value", moved.value.headers[0].value);
    try std.testing.expectEqualStrings("application/octet-stream", moved.value.mime);
}
test "metadata owns its bounded strings and all failed allocations leave no owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, headAllocationFailure, .{});
    try std.testing.expectError(error.InvalidHeader, validateHead(.{ .headers = &.{ .{ .name = "x-a", .value = "a" }, .{ .name = "X-A", .value = "b" } } }, 100, 8192));
    try std.testing.expectError(error.InvalidHeader, validateHead(.{ .headers = &.{.{ .name = "x-a", .value = "a\r\nb" }} }, 100, 8192));
    try std.testing.expectError(error.InvalidHeader, validateHead(.{ .headers = &.{.{ .name = "Content-Length", .value = "100" }} }, 100, 8192));
    try std.testing.expectError(error.UnexpectedBody, validateHead(.{ .status = 204, .length = 1 }, 100, 8192));
    try std.testing.expectError(error.BodyBudgetExceeded, validateHead(.{ .length = 101 }, 100, 8192));
}
test "base64 output is caller storage and bounded before encoding" {
    var scratch: [8]u8 = undefined;
    const encoded = try encodeBody(&scratch, "hello");
    try std.testing.expectEqualStrings("aGVsbG8=", encoded.base64);
    try std.testing.expectEqual(5, encoded.bytes);
    try std.testing.expectEqual(scratch[0..].ptr, encoded.base64.ptr);
    try std.testing.expectError(error.BufferTooSmall, encodeBody(scratch[0..4], "hello"));
    try std.testing.expectError(error.InvalidChunk, base64Bytes(16 * 1024 + 1));
}
