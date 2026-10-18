//! Private bounded HTTP/1.1 framing for the explicit Windows reactor.
//! Parsing grants no endpoint, source, credential, Origin or browser authority.
const std = @import("std");
const http = @import("ziggurat_http_response");

pub const wire_capacity = 24 * 1024;
pub const target_capacity = 4096;
pub const header_capacity = 64;
pub const header_byte_capacity = 16 * 1024;

/// A complete HTTP/1.1 response head for this connection-close transport.
/// GET/HEAD share representation length; this emits no body. Caller has already
/// authorized the source, and still owns all response data. The entire output
/// remains unchanged on any validation/capacity error.
pub const ResponseMetadata = struct { status: u16 = 200, mime: []const u8 = "application/octet-stream", headers: []const http.Header = &.{} };
pub fn responseHead(output: []u8, response: ResponseMetadata, representation_length: u64) ![]const u8 {
    try http.validateResponse(.{ .status = response.status, .mime = response.mime, .headers = response.headers }, 0);
    if ((response.status == 204 or response.status == 205 or response.status == 304) and representation_length != 0) return error.UnexpectedResponseBody;
    var status_buffer: [3]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buffer, "{d}", .{response.status});
    var length_buffer: [20]u8 = undefined;
    const length = try std.fmt.bufPrint(&length_buffer, "{d}", .{representation_length});
    const initial = "HTTP/1.1 ";
    const after_status = " Response\r\nContent-Type: ";
    const length_name = "\r\nContent-Length: ";
    const closing = "\r\nConnection: close\r\n";
    var required = initial.len + status.len + after_status.len + response.mime.len + closing.len + 2;
    if (response.status != 204) required += length_name.len + length.len;
    for (response.headers) |header| required += header.name.len + header.value.len + 4;
    if (output.len < required) return error.NoSpaceLeft;
    var cursor: usize = 0;
    append(output, &cursor, initial);
    append(output, &cursor, status);
    append(output, &cursor, after_status);
    append(output, &cursor, response.mime);
    if (response.status != 204) {
        append(output, &cursor, length_name);
        append(output, &cursor, length);
    }
    append(output, &cursor, closing);
    for (response.headers) |header| {
        append(output, &cursor, header.name);
        append(output, &cursor, ": ");
        append(output, &cursor, header.value);
        append(output, &cursor, "\r\n");
    }
    append(output, &cursor, "\r\n");
    std.debug.assert(cursor == required);
    return output[0..cursor];
}
fn append(output: []u8, cursor: *usize, bytes: []const u8) void {
    @memcpy(output[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

/// All slices borrow the exact immutable C envelope through the main-thread
/// offer callback. No allocator, body read, normalization or backing copy.
pub const Parsed = struct {
    method: []const u8,
    target: []const u8,
    path: []const u8,
    query: ?[]const u8,
    rows: [header_capacity]http.Header = undefined,
    count: usize = 0,

    pub fn headers(self: *const Parsed) []const http.Header {
        return self.rows[0..self.count];
    }
};

/// One complete request head and no following bytes. The reactor must stop
/// receiving at its fixed capacity and reject body/pipelined bytes; this helper
/// never treats a trailing request as another dispatch or reads a request body.
/// Partial input returns Incomplete without publishing any parsed descriptors.
pub fn parse(bytes: []const u8) !Parsed {
    if (bytes.len > wire_capacity) return error.RequestHeadCapacityExceeded;
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return if (bytes.len == wire_capacity) error.RequestHeadCapacityExceeded else error.Incomplete;
    if (end + 4 != bytes.len) return error.UnexpectedRequestBytes;
    const first_end = std.mem.indexOf(u8, bytes, "\r\n") orelse unreachable;
    const line = bytes[0..first_end];
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidRequestLine;
    const method = line[0..first_space];
    if (method.len == 0 or method.len > 32 or !http.validName(method)) return error.InvalidRequestLine;
    const rest = line[first_space + 1 ..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidRequestLine;
    const target = rest[0..second_space];
    if (!std.mem.eql(u8, rest[second_space + 1 ..], "HTTP/1.1")) return error.UnsupportedHttpVersion;
    if (target.len == 0 or target[0] != '/' or target.len > target_capacity) return error.InvalidRequestTarget;
    for (target) |byte| if (byte <= 32 or byte == 127 or byte == '#' or byte == '\\') return error.InvalidRequestTarget;
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    var result: Parsed = .{ .method = method, .target = target, .path = if (query_start) |i| target[0..i] else target, .query = if (query_start) |i| target[i + 1 ..] else null };
    var cursor = first_end + 2;
    var header_bytes: usize = 0;
    while (cursor < end + 2) {
        const count = std.mem.indexOf(u8, bytes[cursor..], "\r\n") orelse unreachable;
        const row = bytes[cursor..][0..count];
        cursor += count + 2;
        if (row.len == 0 or row[0] == ' ' or row[0] == '\t') return error.InvalidRequestHeader;
        const colon = std.mem.indexOfScalar(u8, row, ':') orelse return error.InvalidRequestHeader;
        const name = row[0..colon];
        const value = std.mem.trim(u8, row[colon + 1 ..], " \t");
        if (!http.validName(name) or !http.validValue(value)) return error.InvalidRequestHeader;
        if (result.count == result.rows.len) return error.RequestHeadersExceeded;
        header_bytes += name.len + value.len;
        if (header_bytes > header_byte_capacity) return error.RequestHeadersExceeded;
        result.rows[result.count] = .{ .name = name, .value = value };
        result.count += 1;
    }
    return result;
}

test "bounded head preserves actual duplicate headers and origin bytes" {
    const bytes = "GET /private/body?a=b HTTP/1.1\r\nHost: 127.0.0.1:32100\r\nRange: bytes=1-2\r\nRange:\tbytes=3-4 \t\r\nOrigin: null\r\n\r\n";
    const parsed = try parse(bytes);
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/private/body", parsed.path);
    try std.testing.expectEqualStrings("a=b", parsed.query.?);
    try std.testing.expectEqual(@as(usize, 4), parsed.headers().len);
    try std.testing.expectEqualStrings("Range", parsed.headers()[1].name);
    try std.testing.expectEqualStrings("Range", parsed.headers()[2].name);
    try std.testing.expectEqualStrings("bytes=3-4", parsed.headers()[2].value);
    try std.testing.expectEqualStrings("null", parsed.headers()[3].value);
    try std.testing.expect(@intFromPtr(parsed.headers()[3].value.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(parsed.headers()[3].value.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
}

test "every proper incomplete prefix is distinct from complete trailing bytes" {
    const bytes = "HEAD / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    for (0..bytes.len) |i| try std.testing.expectError(error.Incomplete, parse(bytes[0..i]));
    const parsed = try parse(bytes);
    try std.testing.expectEqualStrings("HEAD", parsed.method);
    try std.testing.expect(parsed.query == null);
    try std.testing.expectError(error.UnexpectedRequestBytes, parse(bytes ++ "x"));
    try std.testing.expectError(error.UnexpectedRequestBytes, parse(bytes ++ bytes));
}

test "framing rejects smuggling syntax without assigning admission authority" {
    inline for (.{
        "GET / HTTP/1.0\r\n\r\n",
        "GET  / HTTP/1.1\r\n\r\n",
        "GET https://127.0.0.1/ HTTP/1.1\r\n\r\n",
        "GET /#x HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : x\r\n\r\n",
        "GET / HTTP/1.1\r\n Host: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\nBad: yes\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\x00y\r\n\r\n",
    }) |invalid| try std.testing.expect(std.meta.isError(parse(invalid)));
    // Method/Host/body/Origin/Range policy is still the existing independent
    // gate; a syntactically valid head is not an authorized Offer.
    const parsed = try parse("POST / HTTP/1.1\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n");
    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqual(@as(usize, 2), parsed.headers().len);
}

test "head wire target header row and header byte limits are bounded" {
    const excessive = [_]u8{'x'} ** wire_capacity;
    try std.testing.expectError(error.RequestHeadCapacityExceeded, parse(&excessive));
    const too_long_target = "GET /" ++ "x" ** target_capacity ++ " HTTP/1.1\r\n\r\n";
    try std.testing.expectError(error.InvalidRequestTarget, parse(too_long_target));
    const many = "GET / HTTP/1.1\r\n" ++ "X: y\r\n" ** (header_capacity + 1) ++ "\r\n";
    try std.testing.expectError(error.RequestHeadersExceeded, parse(many));
    const value = "GET / HTTP/1.1\r\n" ++ ("X: " ++ "y" ** 2048 ++ "\r\n") ** 9 ++ "\r\n";
    try std.testing.expectError(error.RequestHeadersExceeded, parse(value));
}

test "response framing owns length connection and all header boundaries" {
    var output: [512]u8 = undefined;
    const bytes = try responseHead(&output, .{ .status = 206, .mime = "text/plain", .headers = &.{.{ .name = "Content-Range", .value = "bytes 1-2/4" }} }, 2);
    try std.testing.expectEqualStrings("HTTP/1.1 206 Response\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\nContent-Range: bytes 1-2/4\r\n\r\n", bytes);
    const maximum = try responseHead(&output, .{}, std.math.maxInt(u64));
    try std.testing.expect(std.mem.indexOf(u8, maximum, "Content-Length: 18446744073709551615\r\n") != null);
    const empty = try responseHead(&output, .{ .status = 204 }, 0);
    try std.testing.expect(std.mem.indexOf(u8, empty, "Content-Length") == null);
}
test "response formatting validates and sizes before changing caller storage" {
    var output = [_]u8{0xa5} ** 512;
    const response: ResponseMetadata = .{ .mime = "text/plain" };
    var temporary: [512]u8 = undefined;
    const required = (try responseHead(&temporary, response, 4)).len;
    for (0..required) |capacity| {
        try std.testing.expectError(error.NoSpaceLeft, responseHead(output[0..capacity], response, 4));
        try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 512), &output);
    }
    try std.testing.expectError(error.InvalidResponseHeader, responseHead(&output, .{ .headers = &.{.{ .name = "X", .value = "a\r\nb" }} }, 0));
    try std.testing.expectError(error.ReservedResponseHeader, responseHead(&output, .{ .headers = &.{.{ .name = "content-length", .value = "4" }} }, 4));
    try std.testing.expectError(error.UnexpectedResponseBody, responseHead(&output, .{ .status = 204 }, 1));
    try std.testing.expectError(error.UnexpectedResponseBody, responseHead(&output, .{ .status = 205 }, 1));
    try std.testing.expectError(error.UnexpectedResponseBody, responseHead(&output, .{ .status = 304 }, 1));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 512), &output);
}
