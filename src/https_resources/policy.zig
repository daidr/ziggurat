const std = @import("std");
const http = @import("ziggurat_http_response");

pub const bearer_bytes = 32;
pub const prefix_capacity = 256;
pub const header_capacity = 64;
pub const header_bytes = 16 * 1024;
/// Canonical absolute URI, including https://, authority, path and optional
/// '?' plus encoded query. Native parsing applies the same combined bound.
pub const uri_capacity = 4096;
pub const path_capacity = uri_capacity;
pub const query_capacity = uri_capacity;
pub const bearer_header_length = "Bearer ".len + bearer_bytes * 2;

pub const Version = enum { http_1_1, other };
pub const Address = struct { ip: [4]u8, port: u16 };
/// Parsed canonical GUri components, not original wire request-target bytes.
/// The SDK may normalize unreserved escapes even with raw-paths enabled.
/// All strings and headers are borrowed only for this pure validation call.
pub const Request = struct {
    version: Version,
    local: Address,
    peer: [4]u8,
    scheme: []const u8,
    host: []const u8,
    port: u16,
    has_userinfo: bool,
    has_fragment: bool,
    path: []const u8,
    query: ?[]const u8 = null,
    headers: []const http.Header,
    method: []const u8,
};

/// Fixed owning capture. No allocation, pointer into caller storage, TLS
/// object, or entropy generation. The host supplies a private random bearer.
pub const Policy = struct {
    port: u16,
    prefix_storage: [prefix_capacity]u8,
    prefix_length: u16,
    bearer: [bearer_bytes]u8,
    /// Admit observed Range independently from browser grants. No automatic
    /// partial response or file authority is created by this opt-in.
    range_requests: bool = false,

    pub fn captureInto(self: *Policy, port: u16, mount_prefix: []const u8, bearer: [bearer_bytes]u8) !void {
        if (port == 0) return error.InvalidPort;
        if (mount_prefix.len == 0 or mount_prefix.len > prefix_capacity or mount_prefix[0] != '/' or mount_prefix[mount_prefix.len - 1] != '/') return error.InvalidPrefix;
        // The mount is literal. No request route is used as a filesystem path;
        // host-side lookup and source authorization remain explicit.
        if (mount_prefix.len > 1) {
            var previous_slash = true;
            var segment_start: usize = 1;
            for (mount_prefix[1..], 1..) |byte, index| {
                if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '/')) return error.InvalidPrefix;
                if (byte == '/') {
                    if (previous_slash) return error.InvalidPrefix;
                    const segment = mount_prefix[segment_start..index];
                    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPrefix;
                    segment_start = index + 1;
                }
                previous_slash = byte == '/';
            }
        }
        self.port = port;
        self.prefix_length = @intCast(mount_prefix.len);
        @memcpy(self.prefix_storage[0..mount_prefix.len], mount_prefix);
        self.bearer = bearer;
        // captureInto also accepts an undefined destination. Never inherit a
        // caller's previous/uninitialized admission flag through this API.
        self.range_requests = false;
    }

    pub fn prefix(self: *const Policy) []const u8 {
        return self.prefix_storage[0..self.prefix_length];
    }

    pub fn authority(self: *const Policy, buffer: *[22]u8) []const u8 {
        if (self.port == 443) return "127.0.0.1";
        return std.fmt.bufPrint(buffer, "127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    pub fn origin(self: *const Policy, buffer: *[30]u8) []const u8 {
        var host: [22]u8 = undefined;
        return std.fmt.bufPrint(buffer, "https://{s}", .{self.authority(&host)}) catch unreachable;
    }

    /// Canonical wire encoding. Never place this credential in a URI, Cookie,
    /// diagnostic, or a grant that merely constrains observed headers.
    pub fn authorization(self: *const Policy, output: *[bearer_header_length]u8) void {
        const hex = "0123456789abcdef";
        @memcpy(output[0..7], "Bearer ");
        for (self.bearer, 0..) |byte, index| {
            output[7 + 2 * index] = hex[byte >> 4];
            output[8 + 2 * index] = hex[byte & 15];
        }
    }

    fn authorized(self: *const Policy, value: []const u8) bool {
        if (value.len != bearer_header_length) return false;
        var expected: [bearer_header_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &expected);
        self.authorization(&expected);
        return std.crypto.timing_safe.eql([bearer_header_length]u8, expected, value[0..bearer_header_length].*);
    }

    /// This is an endpoint admission policy, not a network sandbox or HTTP
    /// parser. Native listener/TLS verification and the host's immutable server
    /// configuration contract are also required before any request is offered.
    pub fn validate(self: *const Policy, request: Request) !http.Method {
        if (request.version != .http_1_1) return error.UnsupportedHttpVersion;
        const loopback = [4]u8{ 127, 0, 0, 1 };
        if (!std.mem.eql(u8, &request.local.ip, &loopback) or request.local.port != self.port or !std.mem.eql(u8, &request.peer, &loopback)) return error.EndpointAddressMismatch;
        if (!std.mem.eql(u8, request.scheme, "https") or !std.mem.eql(u8, request.host, "127.0.0.1") or request.port != self.port or request.has_userinfo or request.has_fragment) return error.EndpointUriMismatch;
        if (request.path.len == 0 or request.path.len > path_capacity or !std.mem.startsWith(u8, request.path, self.prefix()) or !validRoute(request.path)) return error.InvalidRoute;
        if (request.query) |query| if (query.len > query_capacity or !validEncoded(query, false)) return error.InvalidQuery;
        var authority_buffer: [22]u8 = undefined;
        const fixed = "https://".len + self.authority(&authority_buffer).len;
        const tail = if (request.query) |query| 1 + query.len else @as(usize, 0);
        if (request.path.len + tail > uri_capacity - fixed) return error.UriTooLong;
        const method: http.Method = if (std.mem.eql(u8, request.method, "GET")) .get else if (std.mem.eql(u8, request.method, "HEAD")) .head else return error.MethodDenied;
        if (request.headers.len > header_capacity) return error.RequestHeadersExceeded;
        var bytes: usize = 0;
        var host_count: usize = 0;
        var authorization_count: usize = 0;
        var origin_count: usize = 0;
        var length_count: usize = 0;
        var host_buffer: [22]u8 = undefined;
        const host = self.authority(&host_buffer);
        var origin_buffer: [30]u8 = undefined;
        const expected_origin = self.origin(&origin_buffer);
        for (request.headers) |header| {
            if (!http.validName(header.name) or !http.validValue(header.value)) return error.InvalidRequestHeader;
            bytes += header.name.len + header.value.len;
            if (bytes > header_bytes) return error.RequestHeadersExceeded;
            if (std.ascii.eqlIgnoreCase(header.name, "Host")) {
                host_count += 1;
                if (host_count != 1 or !std.mem.eql(u8, header.value, host)) return error.EndpointHostMismatch;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                authorization_count += 1;
                if (authorization_count != 1 or !self.authorized(header.value)) return error.AuthenticationDenied;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Origin")) {
                origin_count += 1;
                if (origin_count != 1 or !std.mem.eql(u8, header.value, expected_origin)) return error.OriginDenied;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
                length_count += 1;
                if (length_count != 1 or !std.mem.eql(u8, header.value, "0")) return error.RequestBodyDenied;
            } else if (std.ascii.eqlIgnoreCase(header.name, "Transfer-Encoding") or std.ascii.eqlIgnoreCase(header.name, "Expect")) {
                return error.RequestBodyDenied;
            } else if (!(self.range_requests and std.ascii.eqlIgnoreCase(header.name, "Range")) and !http.browserManaged(header.name)) return error.RequestHeaderDenied;
        }
        if (host_count != 1) return error.EndpointHostMismatch;
        if (authorization_count != 1) return error.AuthenticationDenied;
        if (self.range_requests and method == .get) try validateRangeFields(request.headers);
        return method;
    }
};

/// Opt-in GET work only. Keep counters/parsed-value frame out of ordinary
/// admission and HEAD. The caller has validated every generic header and the
/// independent listener/Host/Bearer/optional-Origin/body contract first.
noinline fn validateRangeFields(headers: []const http.Header) !void {
    var range: ?[]const u8 = null;
    var conditions: usize = 0;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Range")) {
            if (range != null) return error.DuplicateRangeHeader;
            range = header.value;
        } else if (std.ascii.eqlIgnoreCase(header.name, "If-Range")) conditions += 1;
    }
    const value = range orelse return; // If-Range alone preserves old behavior.
    if (conditions > 1) return error.DuplicateIfRangeHeader;
    // Only request grammar is checked here. Total length, validators, other
    // preconditions and response/FileWindow selection remain the host's job.
    _ = http.byte_range.parse(value) catch return error.RequestRangeDenied;
}

fn validRoute(value: []const u8) bool {
    if (!validEncoded(value, true)) return false;
    var segments = std.mem.splitScalar(u8, value, '/');
    _ = segments.next();
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        if (segment.len == 0 and segments.index != null) return false;
    }
    return true;
}
fn validEncoded(value: []const u8, route: bool) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte < 32 or byte == 127 or byte == '\\' or byte == '#') return false;
        if (byte == '%') {
            if (index + 2 >= value.len or !std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return false;
            const decoded = (std.fmt.charToDigit(value[index + 1], 16) catch unreachable) * 16 + (std.fmt.charToDigit(value[index + 2], 16) catch unreachable);
            if (decoded < 32 or decoded == 127 or decoded == '\\' or (route and (decoded == '/' or decoded == '.'))) return false;
            index += 2;
        }
    }
    return true;
}

fn fixture() Policy {
    var result: Policy = undefined;
    result.captureInto(32000, "/private/", @splat(0xa7)) catch unreachable;
    return result;
}
fn requestFixture(headers: []const http.Header) Request {
    return .{ .version = .http_1_1, .local = .{ .ip = .{ 127, 0, 0, 1 }, .port = 32000 }, .peer = .{ 127, 0, 0, 1 }, .scheme = "https", .host = "127.0.0.1", .port = 32000, .has_userinfo = false, .has_fragment = false, .path = "/private/body", .headers = headers, .method = "GET" };
}

test "policy owns a canonical prefix and fixed credential without allocation" {
    var prefix = "/private/".*;
    var value: Policy = undefined;
    try value.captureInto(32000, &prefix, @splat(0xa7));
    @memset(&prefix, 'x');
    try std.testing.expectEqualStrings("/private/", value.prefix());
    try std.testing.expectError(error.InvalidPort, value.captureInto(0, "/", @splat(0)));
    for ([_][]const u8{ "", "private/", "/private", "//", "/a//", "/../", "/./", "/%61/", "/a?b/", "/a\\b/" }) |bad| try std.testing.expectError(error.InvalidPrefix, value.captureInto(1, bad, @splat(0)));
}

test "exact endpoint authority, bearer and origin are independently required" {
    const policy = fixture();
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    var headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret }, .{ .name = "Origin", .value = "https://127.0.0.1:32000" } };
    try std.testing.expectEqual(http.Method.get, try policy.validate(requestFixture(&headers)));
    try std.testing.expectEqual(http.Method.get, try policy.validate(requestFixture(headers[0..2])));
    try std.testing.expectError(error.AuthenticationDenied, policy.validate(requestFixture(headers[0..1])));
    for (0..secret.len) |i| {
        secret[i] ^= 1;
        try std.testing.expectError(error.AuthenticationDenied, policy.validate(requestFixture(&headers)));
        secret[i] ^= 1;
    }
    headers[0].value = "127.0.0.1:32001";
    try std.testing.expectError(error.EndpointHostMismatch, policy.validate(requestFixture(&headers)));
    headers[0].value = "127.0.0.1:32000";
    for ([_][]const u8{ "null", "http://127.0.0.1:32000", "https://127.0.0.1:32001", "https://127.0.0.1:32000/", "https://127.0.0.1.example:32000" }) |bad| {
        headers[2].value = bad;
        try std.testing.expectError(error.OriginDenied, policy.validate(requestFixture(&headers)));
    }
}

test "early gate rejects method, bodies, ambiguous credentials and unknown headers" {
    const policy = fixture();
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    var headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret }, .{ .name = "Content-Length", .value = "0" } };
    var req = requestFixture(&headers);
    try std.testing.expectEqual(http.Method.get, try policy.validate(req));
    req.method = "HEAD";
    try std.testing.expectEqual(http.Method.head, try policy.validate(req));
    for ([_][]const u8{ "POST", "GET ", "get", "CONNECT", "OPTIONS" }) |bad| {
        req.method = bad;
        try std.testing.expectError(error.MethodDenied, policy.validate(req));
    }
    req.method = "GET";
    for ([_][]const u8{ "1", "00", "-1", "", "0, 0", " 0" }) |bad| {
        headers[2].value = bad;
        try std.testing.expectError(error.RequestBodyDenied, policy.validate(req));
    }
    for ([_][]const u8{ "Transfer-Encoding", "Expect" }) |name| {
        headers[2] = .{ .name = name, .value = "" };
        try std.testing.expectError(error.RequestBodyDenied, policy.validate(req));
    }
    headers[2] = headers[1];
    try std.testing.expectError(error.AuthenticationDenied, policy.validate(req));
    headers[2] = headers[0];
    try std.testing.expectError(error.EndpointHostMismatch, policy.validate(req));
    headers[2] = .{ .name = "X-Unknown", .value = "value" };
    try std.testing.expectError(error.RequestHeaderDenied, policy.validate(req));
}

test "physical address and canonical URI retain the explicit route boundaries" {
    const policy = fixture();
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    const headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret } };
    const base = requestFixture(&headers);
    var req = base;
    req.local.port += 1;
    try std.testing.expectError(error.EndpointAddressMismatch, policy.validate(req));
    req = base;
    req.local.ip = .{ 0, 0, 0, 0 };
    try std.testing.expectError(error.EndpointAddressMismatch, policy.validate(req));
    req = base;
    req.peer = .{ 127, 0, 0, 2 };
    try std.testing.expectError(error.EndpointAddressMismatch, policy.validate(req));
    for ([_][]const u8{ "http", "HTTPS", "https:" }) |bad| {
        req = base;
        req.scheme = bad;
        try std.testing.expectError(error.EndpointUriMismatch, policy.validate(req));
    }
    for ([_][]const u8{ "localhost", "127.000.0.1", "127.0.0.1.example", "[::1]" }) |bad| {
        req = base;
        req.host = bad;
        try std.testing.expectError(error.EndpointUriMismatch, policy.validate(req));
    }
    for ([_][]const u8{ "/private", "/%70rivate/body", "/private/body%0a", "/private/body%zz", "/private/\\body", "/private/body#fragment", "/private/../other", "/private/./body", "/private/%2e%2e/other", "/private/one%2ftwo", "/private//body" }) |bad| {
        req = base;
        req.path = bad;
        try std.testing.expectError(error.InvalidRoute, policy.validate(req));
    }
    req = base;
    req.path = "/private/one.txt";
    req.query = "x=%20%2f";
    try std.testing.expectEqual(http.Method.get, try policy.validate(req));
}

test "combined absolute URI budget includes authority and optional query marker" {
    const policy = fixture();
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    const headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret } };
    var req = requestFixture(&headers);
    var query: [uri_capacity]u8 = @splat('q');
    const fixed = "https://127.0.0.1:32000".len + req.path.len + 1;
    req.query = query[0 .. uri_capacity - fixed];
    try std.testing.expectEqual(http.Method.get, try policy.validate(req));
    req.query = query[0 .. uri_capacity - fixed + 1];
    try std.testing.expectError(error.UriTooLong, policy.validate(req));
}

test "range opt-in capture is false on undefined and reused destinations" {
    var policy: Policy = undefined;
    try policy.captureInto(32000, "/private/", @splat(0xa7));
    try std.testing.expect(!policy.range_requests);
    policy.range_requests = true;
    try policy.captureInto(32000, "/private/", @splat(0xa7));
    try std.testing.expect(!policy.range_requests);
}

test "range admission stays independent from default headers and identity" {
    var policy = fixture();
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    var headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret }, .{ .name = "Range", .value = "bytes=0-1" }, .{ .name = "Origin", .value = "https://127.0.0.1:32000" } };
    var request = requestFixture(&headers);
    try std.testing.expectError(error.RequestHeaderDenied, policy.validate(request));
    policy.range_requests = true;
    try std.testing.expectEqual(http.Method.get, try policy.validate(request));
    headers[3].value = "https://127.0.0.1:32001";
    try std.testing.expectError(error.OriginDenied, policy.validate(request));
    headers[3].value = "https://127.0.0.1:32000";
    secret[7] ^= 1;
    try std.testing.expectError(error.AuthenticationDenied, policy.validate(request));
    secret[7] ^= 1;
    request.method = "POST";
    try std.testing.expectError(error.MethodDenied, policy.validate(request));
}

test "opted GET checks whole bounded range grammar and observed duplicates" {
    var policy = fixture();
    policy.range_requests = true;
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    var headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret }, .{ .name = "Range", .value = "bytes=0-1" }, .{ .name = "If-Range", .value = "\"a\"" }, .{ .name = "If-Range", .value = "\"b\"" } };
    var request = requestFixture(headers[0..4]);
    for ([_][]const u8{ "bytes=0-1", "bytes=,0-1,", "bytes=0-1,3-4", "bytes=18446744073709551616-", "widgets=other" }) |value| {
        headers[2].value = value;
        try std.testing.expectEqual(http.Method.get, try policy.validate(request));
    }
    for ([_][]const u8{ "", "bytes=1-0", "bytes=0-1,x", "bytes=18446744073709551616-,x", "bytes=,,,,,0-1,,,," }) |value| {
        headers[2].value = value;
        try std.testing.expectError(error.RequestRangeDenied, policy.validate(request));
    }
    var large: [257]u8 = @splat('0');
    @memcpy(large[0..6], "bytes=");
    large[large.len - 1] = '-';
    headers[2].value = &large;
    try std.testing.expectError(error.RequestRangeDenied, policy.validate(request));
    headers[2].value = "bytes=0-1";
    request.headers = &headers;
    try std.testing.expectError(error.DuplicateIfRangeHeader, policy.validate(request));
    headers[4] = .{ .name = "rAnGe", .value = "bytes=0-1" };
    try std.testing.expectError(error.DuplicateRangeHeader, policy.validate(request));
    headers[4].value = "bytes=2-3";
    try std.testing.expectError(error.DuplicateRangeHeader, policy.validate(request));
    // An overlong/weak/date If-Range is not a range syntax refusal. The host
    // must evaluate its validator and choose the conservative full response.
    request.headers = headers[0..4];
    headers[3].value = &large;
    try std.testing.expectEqual(http.Method.get, try policy.validate(request));
}

test "HEAD ignores range semantics within generic limits and If-Range alone stays ignored" {
    var policy = fixture();
    policy.range_requests = true;
    var secret: [bearer_header_length]u8 = undefined;
    policy.authorization(&secret);
    var headers = [_]http.Header{ .{ .name = "Host", .value = "127.0.0.1:32000" }, .{ .name = "Authorization", .value = &secret }, .{ .name = "Range", .value = "bytes=bad" }, .{ .name = "Range", .value = "different" }, .{ .name = "If-Range", .value = "bad" } };
    var request = requestFixture(&headers);
    request.method = "HEAD";
    try std.testing.expectEqual(http.Method.head, try policy.validate(request));
    var large: [2048]u8 = @splat('x');
    headers[2].value = &large;
    try std.testing.expectEqual(http.Method.head, try policy.validate(request));
    var exceeded: [2049]u8 = @splat('x');
    headers[2].value = &exceeded;
    try std.testing.expectError(error.InvalidRequestHeader, policy.validate(request));
    headers[2] = .{ .name = "If-Range", .value = "\"a\"" };
    headers[3] = .{ .name = "If-Range", .value = "\"b\"" };
    request.method = "GET";
    try std.testing.expectEqual(http.Method.get, try policy.validate(request));
    policy.range_requests = false;
    try std.testing.expectEqual(http.Method.get, try policy.validate(request));
}
