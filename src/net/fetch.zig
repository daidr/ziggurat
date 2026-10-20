const std = @import("std");
const Cancel = @import("cancel.zig").Cancel;
const guardSends = @import("cancel.zig").guardSends;

pub const Header = std.http.Header;

pub const Redirect = enum {
    /// Follow up to `Limits.redirects` hops.
    follow,
    /// Return the redirect response itself.
    manual,
    /// Fail with `Redirected` on a redirect response.
    reject,
};

pub const Request = struct {
    method: std.http.Method = .GET,
    /// `http` or `https` URL. Credentials in the URL are sent as Basic auth.
    url: []const u8,
    /// Sent on every hop, including redirects to another host. A `Host`,
    /// `User-Agent`, `Authorization` or `Content-Type` here replaces the
    /// client's own. An `Accept-Encoding` here replaces the module's and
    /// the body is returned as the server encoded it, without decoding.
    headers: []const Header = &.{},
    /// Sent only while redirects stay on the same scheme and host, such as
    /// `Authorization` or `Cookie`.
    credentials: []const Header = &.{},
    /// Requires a method that carries a body. Requests with a body do not
    /// follow redirects; the redirect response is returned instead.
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    redirect: Redirect = .follow,
};

pub const Limits = struct {
    /// Response body bytes after decompression.
    response_bytes: usize = 8 * 1024 * 1024,
    /// Copied response header names and values. The response head as a whole
    /// must also fit in the client's `read_buffer_size`.
    header_bytes: usize = 16 * 1024,
    headers: usize = 64,
    redirects: u8 = 5,
    /// Longest request or redirect URL.
    url_bytes: usize = 8 * 1024,
    /// Accept gzip and deflate and decode them; the decoder window is
    /// allocated only for encoded responses.
    decompress: bool = true,
};

/// Status and copied headers of the final response.
pub const Head = struct {
    status: std.http.Status,
    /// The status line's reason phrase, possibly empty.
    reason: []const u8,
    headers: []const Header,
    /// URL of the final response, after redirects.
    url: []const u8,
    /// Number of redirects followed.
    redirects: u8,
    storage: []u8,

    pub fn deinit(self: *Head, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.storage);
        self.* = undefined;
    }

    /// First header with `name`, compared case-insensitively.
    pub fn header(self: *const Head, name: []const u8) ?[]const u8 {
        for (self.headers) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        return null;
    }
};

pub const Response = struct {
    head: Head,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        self.head.deinit(allocator);
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Error = error{
    Cancelled,
    InvalidUrl,
    UrlTooLong,
    UnsupportedScheme,
    InvalidRequest,
    ResponseTooLarge,
    HeadersTooLarge,
    TooManyHeaders,
    TooManyRedirects,
    Redirected,
    RedirectLocationInvalid,
    UnsupportedEncoding,
    ConnectionFailed,
    TlsFailed,
    ProtocolError,
    WriteFailed,
    OutOfMemory,
};

/// Perform `request` and copy the body into memory owned by `allocator`,
/// failing with `ResponseTooLarge` past `limits.response_bytes`. Every status
/// is returned as a response; only transport failures are errors.
/// Blocking: run on an application-managed worker and hand the result to the
/// UI thread with `App.post`.
pub fn fetch(allocator: std.mem.Allocator, client: *std.http.Client, request: Request, limits: Limits, cancel: ?*Cancel) Error!Response {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var head = try stream(allocator, client, request, limits, cancel, &body.writer);
    errdefer head.deinit(allocator);
    return .{ .head = head, .body = try body.toOwnedSlice() };
}

pub fn Json(comptime T: type) type {
    return struct {
        head: Head,
        value: std.json.Parsed(T),

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.head.deinit(allocator);
            self.value.deinit();
            self.* = undefined;
        }
    };
}

/// `fetch` that decodes a 2xx JSON body into `T`, under the same limits. A
/// non-2xx status returns `HttpStatus` and an undecodable body `InvalidJson`.
/// Unknown fields are ignored.
pub fn fetchJson(comptime T: type, allocator: std.mem.Allocator, client: *std.http.Client, request: Request, limits: Limits, cancel: ?*Cancel) (Error || error{ HttpStatus, InvalidJson })!Json(T) {
    var response = try fetch(allocator, client, request, limits, cancel);
    defer allocator.free(response.body);
    errdefer response.head.deinit(allocator);
    if (response.head.status.class() != .success) return error.HttpStatus;
    const value = std.json.parseFromSlice(T, allocator, response.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return .{ .head = response.head, .value = value };
}

/// Perform `request` and write the body to `sink` as it arrives; the sink is
/// flushed after every read. A sink that blocks holds the transfer back, so a
/// slow consumer applies TCP backpressure instead of buffering the body.
/// Bytes written before an error stay in `sink`. Blocking: run on an
/// application-managed worker.
pub fn stream(allocator: std.mem.Allocator, client: *std.http.Client, request: Request, limits: Limits, cancel: ?*Cancel, sink: *std.Io.Writer) Error!Head {
    return (try perform(allocator, client, request, limits, cancel, sink, null)).?;
}

/// Receives a response's head before its body.
pub const Receiver = struct {
    context: *anyopaque,
    /// Takes ownership of `head`, which it frees with the transfer's
    /// allocator, before the first body byte is read. An error ends the
    /// transfer with that error.
    head: *const fn (*anyopaque, Head) Error!void,
    body: *std.Io.Writer,
};

/// `stream` that hands the head to `receiver` as soon as it arrives, so a
/// consumer can act on the status and headers while the body streams.
pub fn receive(allocator: std.mem.Allocator, client: *std.http.Client, request: Request, limits: Limits, cancel: ?*Cancel, receiver: Receiver) Error!void {
    _ = try perform(allocator, client, request, limits, cancel, receiver.body, receiver);
}

/// The head is returned unless `receiver` took it.
fn perform(allocator: std.mem.Allocator, client: *std.http.Client, request: Request, limits: Limits, cancel: ?*Cancel, sink: *std.Io.Writer, receiver: ?Receiver) Error!?Head {
    if (request.body != null and !request.method.requestHasBody()) return error.InvalidRequest;
    if (request.url.len > limits.url_bytes) return error.UrlTooLong;
    const urls = try allocator.alloc(u8, 3 * limits.url_bytes);
    defer allocator.free(urls);
    var current = urls[0..limits.url_bytes];
    var next = urls[limits.url_bytes..][0..limits.url_bytes];
    const aux = urls[2 * limits.url_bytes ..];
    @memcpy(current[0..request.url.len], request.url);
    var url_len = request.url.len;
    var method = request.method;
    var credentials = request.credentials;
    var redirects: u8 = 0;
    while (true) {
        if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
        const uri = std.Uri.parse(current[0..url_len]) catch return error.InvalidUrl;
        if (std.http.Client.Protocol.fromUri(uri) == null) return error.UnsupportedScheme;
        var exchange: Exchange = .{ .client = client, .cancel = cancel };
        defer exchange.deinit();
        var response = try exchange.send(uri, method, request, credentials, limits);
        if (response.head.status.class() == .redirect and response.head.location != null and response.head.status != .not_modified and request.redirect == .reject) return error.Redirected;
        if (response.head.status.class() == .redirect and response.head.location != null and request.body == null and response.head.status != .not_modified and request.redirect == .follow) {
            if (redirects == limits.redirects) return error.TooManyRedirects;
            const location = response.head.location.?;
            if (location.len > aux.len) return error.UrlTooLong;
            @memcpy(aux[0..location.len], location);
            var aux_slice = aux;
            const target = uri.resolveInPlace(location.len, &aux_slice) catch |err| switch (err) {
                error.NoSpaceLeft => return error.UrlTooLong,
                else => return error.RedirectLocationInvalid,
            };
            if (std.http.Client.Protocol.fromUri(target) == null) return error.UnsupportedScheme;
            var writer: std.Io.Writer = .fixed(next);
            target.writeToStream(&writer, .{ .scheme = true, .authentication = true, .authority = true, .path = true, .query = true }) catch return error.UrlTooLong;
            if (!sameOrigin(uri, target)) credentials = &.{};
            if (response.head.status == .see_other or ((response.head.status == .moved_permanently or response.head.status == .found) and method == .POST)) method = .GET;
            url_len = writer.end;
            std.mem.swap([]u8, &current, &next);
            redirects += 1;
            continue;
        }
        var head = try copyHead(allocator, &response.head, current[0..url_len], limits, redirects);
        if (receiver) |target| {
            try target.head(target.context, head);
            try exchange.readBody(allocator, &response, limits, decoding(request, limits), sink);
            return null;
        }
        errdefer head.deinit(allocator);
        try exchange.readBody(allocator, &response, limits, decoding(request, limits), sink);
        return head;
    }
}

const Exchange = struct {
    client: *std.http.Client,
    cancel: ?*Cancel,
    request: ?std.http.Client.Request = null,
    attached: bool = false,
    decompress_buffer: []u8 = &.{},
    allocator: ?std.mem.Allocator = null,

    fn deinit(self: *Exchange) void {
        if (self.attached) self.cancel.?.detach();
        if (self.request) |*request| request.deinit();
        if (self.allocator) |allocator| allocator.free(self.decompress_buffer);
    }

    fn send(self: *Exchange, uri: std.Uri, method: std.http.Method, request: Request, credentials: []const Header, limits: Limits) Error!std.http.Client.Response {
        const decode = decoding(request, limits);
        self.request = self.client.request(method, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .host = if (has(request.headers, "host")) .omit else .default,
                .authorization = if (has(request.headers, "authorization") or has(credentials, "authorization")) .omit else .default,
                .user_agent = if (has(request.headers, "user-agent")) .omit else .default,
                .accept_encoding = if (has(request.headers, "accept-encoding")) .omit else if (decode) .{ .override = "gzip, deflate" } else .{ .override = "identity" },
                .content_type = if (has(request.headers, "content-type")) .omit else if (request.content_type) |value| .{ .override = value } else .default,
            },
            .extra_headers = request.headers,
            .privileged_headers = credentials,
        }) catch |err| return mapConnect(err);
        const http_request = &self.request.?;
        guardSends(http_request.connection.?);
        if (self.cancel) |token| {
            try token.attach(http_request.connection.?.stream_reader.getStream().handle);
            self.attached = true;
        }
        // A caller's own Accept-Encoding takes any encoding back undecoded.
        http_request.accept_encoding = @splat(has(request.headers, "accept-encoding"));
        http_request.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        if (decode) {
            http_request.accept_encoding[@intFromEnum(std.http.ContentEncoding.gzip)] = true;
            http_request.accept_encoding[@intFromEnum(std.http.ContentEncoding.deflate)] = true;
        }
        if (method.requestHasBody() and method != .GET) {
            const body = request.body orelse "";
            http_request.transfer_encoding = .{ .content_length = body.len };
            var writer = http_request.sendBodyUnflushed(&.{}) catch return self.failure(error.ConnectionFailed);
            writer.writer.writeAll(body) catch return self.failure(error.ConnectionFailed);
            writer.end() catch return self.failure(error.ConnectionFailed);
            http_request.connection.?.flush() catch return self.failure(error.ConnectionFailed);
        } else {
            http_request.sendBodiless() catch return self.failure(error.ConnectionFailed);
        }
        return http_request.receiveHead(&.{}) catch |err| switch (err) {
            error.HttpContentEncodingUnsupported => error.UnsupportedEncoding,
            error.HttpHeadersOversize => error.HeadersTooLarge,
            error.HttpHeadersInvalid, error.HttpChunkInvalid, error.HttpChunkTruncated, error.HttpRequestTruncated => self.failure(error.ProtocolError),
            else => self.failure(error.ConnectionFailed),
        };
    }

    fn readBody(self: *Exchange, allocator: std.mem.Allocator, response: *std.http.Client.Response, limits: Limits, decode: bool, sink: *std.Io.Writer) Error!void {
        // Responses to HEAD, and 1xx, 204 and 304 responses, end with their head.
        const status = response.head.status;
        if (response.request.method == .HEAD or status.class() == .informational or status == .no_content or status == .not_modified) return;
        const encoded = decode and response.head.content_encoding != .identity;
        if (!encoded) if (response.head.content_length) |length| if (length > limits.response_bytes) return error.ResponseTooLarge;
        var transfer: [16 * 1024]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = if (encoded) reader: {
            if (response.head.content_encoding != .gzip and response.head.content_encoding != .deflate) return error.UnsupportedEncoding;
            self.decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
            self.allocator = allocator;
            break :reader response.readerDecompressing(&transfer, &decompress, self.decompress_buffer);
        } else identity: {
            // The client's own reader drops the body of a PUT or TRACE response.
            break :identity response.request.reader.bodyReader(&transfer, response.head.transfer_encoding, response.head.content_length);
        };
        var total: usize = 0;
        while (true) {
            const n = reader.stream(sink, .limited(limits.response_bytes - total + 1)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.WriteFailed => return error.WriteFailed,
                error.ReadFailed => return self.failure(if (response.bodyErr() != null) error.ProtocolError else error.ConnectionFailed),
            };
            total += n;
            if (total > limits.response_bytes) return error.ResponseTooLarge;
            sink.flush() catch return error.WriteFailed;
        }
        // A shutdown can surface as end of stream; a cancelled transfer never
        // reports success, and a short identity body is never complete.
        if (self.cancel) |token| if (token.isCancelled()) return error.Cancelled;
        if (!encoded) if (response.head.content_length) |length| if (total != length) return error.ConnectionFailed;
    }

    /// Socket failures after `cancel` report cancellation, not the shutdown they caused.
    fn failure(self: *Exchange, err: Error) Error {
        if (self.cancel) |token| if (token.isCancelled()) return error.Cancelled;
        return err;
    }
};

fn has(headers: []const Header, name: []const u8) bool {
    for (headers) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return true;
    return false;
}

fn decoding(request: Request, limits: Limits) bool {
    return limits.decompress and !has(request.headers, "accept-encoding");
}

fn mapConnect(err: std.http.Client.RequestError) Error {
    return switch (err) {
        error.UnsupportedUriScheme => error.UnsupportedScheme,
        error.UriMissingHost, error.UriHostTooLong => error.InvalidUrl,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.TlsFailed,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ConnectionFailed,
    };
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    var first: [std.Uri.host_name_max]u8 = undefined;
    var second: [std.Uri.host_name_max]u8 = undefined;
    const host_a = a.getHost(&first) catch return false;
    const host_b = b.getHost(&second) catch return false;
    const default: u16 = if (std.http.Client.Protocol.fromUri(a) == .tls) 443 else 80;
    return std.ascii.eqlIgnoreCase(host_a, host_b) and (a.port orelse default) == (b.port orelse default);
}

fn copyHead(allocator: std.mem.Allocator, head: *const std.http.Client.Response.Head, url: []const u8, limits: Limits, redirects: u8) Error!Head {
    var count: usize = 0;
    var bytes: usize = 0;
    const reason = std.mem.trim(u8, head.reason, " \t\r");
    if (reason.len > limits.header_bytes) return error.HeadersTooLarge;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |item| {
        count += 1;
        bytes += item.name.len + item.value.len;
        if (count > limits.headers) return error.TooManyHeaders;
        if (bytes > limits.header_bytes) return error.HeadersTooLarge;
    }
    const headers = try allocator.alloc(Header, count);
    errdefer allocator.free(headers);
    const storage = try allocator.alloc(u8, bytes + reason.len + url.len);
    @memcpy(storage[bytes..][0..reason.len], reason);
    @memcpy(storage[bytes + reason.len ..], url);
    var offset: usize = 0;
    iterator = head.iterateHeaders();
    for (headers) |*item| {
        const source = iterator.next().?;
        const name = storage[offset..][0..source.name.len];
        @memcpy(name, source.name);
        offset += name.len;
        const value = storage[offset..][0..source.value.len];
        @memcpy(value, source.value);
        offset += value.len;
        item.* = .{ .name = name, .value = value };
    }
    return .{ .status = head.status, .reason = storage[bytes..][0..reason.len], .headers = headers, .url = storage[bytes + reason.len ..], .redirects = redirects, .storage = storage };
}

/// Local plain HTTP server for the module's tests. Serves scripted responses
/// one connection at a time.
pub const TestServer = struct {
    server: std.net.Server,
    handler: *const fn (*TestServer, *std.http.Server.Request) anyerror!void,
    context: ?*anyopaque = null,
    requests: usize = 0,
    release: std.Thread.ResetEvent = .{},

    pub fn init(handler: *const fn (*TestServer, *std.http.Server.Request) anyerror!void) !TestServer {
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{ .server = try address.listen(.{ .reuse_address = true }), .handler = handler };
    }
    pub fn deinit(self: *TestServer) void {
        self.server.deinit();
    }
    pub fn port(self: *const TestServer) u16 {
        return self.server.listen_address.getPort();
    }
    pub fn serve(self: *TestServer, count: usize) void {
        for (0..count) |_| self.one() catch {};
    }
    fn one(self: *TestServer) !void {
        const connection = try self.server.accept();
        defer connection.stream.close();
        var receive_buffer: [8192]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var reader = connection.stream.reader(&receive_buffer);
        var writer = connection.stream.writer(&send_buffer);
        var http: std.http.Server = .init(reader.interface(), &writer.interface);
        var request = try http.receiveHead();
        self.requests += 1;
        try self.handler(self, &request);
    }
};

fn testUrl(buffer: []u8, server: *const TestServer, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ server.port(), path });
}

test "fetch returns status, headers and body; posts and puts carry their body" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            if (request.head.method == .POST or request.head.method == .PUT) {
                var buffer: [64]u8 = undefined;
                const body = try (try request.readerExpectContinue(&buffer)).allocRemaining(std.testing.allocator, .limited(64));
                defer std.testing.allocator.free(body);
                try request.respond(body, .{ .status = .created, .keep_alive = false, .extra_headers = &.{.{ .name = "x-echo", .value = "post" }} });
            } else try request.respond("hello", .{ .status = .not_found, .keep_alive = false, .extra_headers = &.{.{ .name = "x-test", .value = "1" }} });
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 4 });
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try testUrl(&url_buffer, &server, "/missing");
    var response = try fetch(std.testing.allocator, &client, .{ .url = url }, .{}, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, response.head.status);
    try std.testing.expectEqualStrings("hello", response.body);
    try std.testing.expectEqualStrings("1", response.head.header("X-Test").?);
    var posted = try fetch(std.testing.allocator, &client, .{ .method = .POST, .url = url, .body = "payload", .content_type = "text/plain" }, .{}, null);
    defer posted.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.created, posted.head.status);
    try std.testing.expectEqualStrings("payload", posted.body);
    // A PUT response has its body; a HEAD response ends with its head.
    var put = try fetch(std.testing.allocator, &client, .{ .method = .PUT, .url = url, .body = "replaced" }, .{}, null);
    defer put.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("replaced", put.body);
    var head = try fetch(std.testing.allocator, &client, .{ .method = .HEAD, .url = url }, .{}, null);
    defer head.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, head.head.status);
    try std.testing.expectEqualStrings("", head.body);
}

test "fetch enforces body, header and redirect limits" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            if (std.mem.eql(u8, request.head.target, "/loop")) {
                try request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/loop" }} });
            } else if (std.mem.eql(u8, request.head.target, "/hop")) {
                try request.respond("", .{ .status = .moved_permanently, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "big" }} });
            } else {
                var body: [4096]u8 = undefined;
                @memset(&body, 'x');
                var buffer: [512]u8 = undefined;
                var writer = try request.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = false, .extra_headers = &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "2" } } } });
                try writer.writer.writeAll(&body);
                try writer.end();
            }
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 1 + 3 + 1 + 1 + 2 });
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLarge, fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/big") }, .{ .response_bytes = 4095 }, null));
    try std.testing.expectError(error.TooManyRedirects, fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/loop") }, .{ .redirects = 2 }, null));
    try std.testing.expectError(error.TooManyHeaders, fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/big") }, .{ .headers = 1 }, null));
    try std.testing.expectError(error.HeadersTooLarge, fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/big") }, .{ .header_bytes = 3 }, null));
    var response = try fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/hop") }, .{ .response_bytes = 4096 }, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), response.head.redirects);
    try std.testing.expectEqual(@as(usize, 4096), response.body.len);
}

test "cancel interrupts a worker blocked on a stalled response" {
    const handler = struct {
        fn handle(server: *TestServer, request: *std.http.Server.Request) anyerror!void {
            var buffer: [64]u8 = undefined;
            var writer = try request.respondStreaming(&buffer, .{ .content_length = 100, .respond_options = .{ .keep_alive = false } });
            try writer.writer.writeAll("partial");
            try writer.flush();
            server.release.wait();
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 1 });
    defer thread.join();
    defer server.release.set();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try testUrl(&url_buffer, &server, "/stall");
    var cancel: Cancel = .{};
    const Worker = struct {
        result: Error!Response = error.ConnectionFailed,
        fn run(self: *@This(), http: *std.http.Client, target: []const u8, token: *Cancel) void {
            self.result = fetch(std.testing.allocator, http, .{ .url = target }, .{}, token);
        }
    };
    var worker: Worker = .{};
    const fetching = try std.Thread.spawn(.{}, Worker.run, .{ &worker, &client, url, &cancel });
    while (true) {
        cancel.mutex.lock();
        const attached = cancel.socket != null;
        cancel.mutex.unlock();
        if (attached) break;
        std.Thread.yield() catch {};
    }
    cancel.cancel();
    fetching.join();
    try std.testing.expectError(error.Cancelled, worker.result);
    try std.testing.expectError(error.Cancelled, fetch(std.testing.allocator, &client, .{ .url = url }, .{}, &cancel));
}

test "fetch rejects malformed requests before connecting" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    try std.testing.expectError(error.InvalidRequest, fetch(std.testing.allocator, &client, .{ .url = "http://127.0.0.1/", .body = "x" }, .{}, null));
    try std.testing.expectError(error.UnsupportedScheme, fetch(std.testing.allocator, &client, .{ .url = "ftp://127.0.0.1/" }, .{}, null));
    try std.testing.expectError(error.InvalidUrl, fetch(std.testing.allocator, &client, .{ .url = "not a url" }, .{}, null));
    try std.testing.expectError(error.UrlTooLong, fetch(std.testing.allocator, &client, .{ .url = "http://127.0.0.1/abcdef" }, .{ .url_bytes = 8 }, null));
}

test "fetchJson decodes typed bodies and rejects errors" {
    const handler = struct {
        fn handle(server: *TestServer, request: *std.http.Server.Request) anyerror!void {
            const body: []const u8 = switch (server.requests) {
                1 => "{\"name\":\"ziggurat\",\"count\":3,\"extra\":true}",
                2 => "{\"name\":",
                else => "{}",
            };
            try request.respond(body, .{ .status = if (server.requests == 3) .bad_request else .ok, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 3 });
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try testUrl(&url_buffer, &server, "/item");
    const Item = struct { name: []const u8, count: u32 };
    var item = try fetchJson(Item, std.testing.allocator, &client, .{ .url = url }, .{}, null);
    defer item.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ziggurat", item.value.value.name);
    try std.testing.expectEqual(@as(u32, 3), item.value.value.count);
    try std.testing.expectError(error.InvalidJson, fetchJson(Item, std.testing.allocator, &client, .{ .url = url }, .{}, null));
    try std.testing.expectError(error.HttpStatus, fetchJson(Item, std.testing.allocator, &client, .{ .url = url }, .{}, null));
}

test "fetch decodes gzip and applies the limit to decoded bytes" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\xc8\x18\x25\x47\xc9\x51\x72\x94\x1c\xf4\x24\x00\x45\x44\x9f\x68\xb0\x04\x00\x00";
            try request.respond(gzip, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-encoding", .value = "gzip" }} });
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 2 });
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    const url = try testUrl(&url_buffer, &server, "/gzip");
    var response = try fetch(std.testing.allocator, &client, .{ .url = url }, .{}, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1200), response.body.len);
    try std.testing.expect(std.mem.startsWith(u8, response.body, "hello hello "));
    try std.testing.expectError(error.ResponseTooLarge, fetch(std.testing.allocator, &client, .{ .url = url }, .{ .response_bytes = 1199 }, null));
}

test "redirect modes, final URL, reason and replaced default headers" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            if (std.mem.eql(u8, request.head.target, "/hop")) {
                try request.respond("", .{ .status = .found, .reason = "Found It", .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/headers" }} });
                return;
            }
            // Echo the agent and encoding headers, counting repeats.
            var agents: usize = 0;
            var agent: []const u8 = "";
            var encoding: []const u8 = "";
            var iterator = request.iterateHeaders();
            while (iterator.next()) |item| {
                if (std.ascii.eqlIgnoreCase(item.name, "user-agent")) {
                    agents += 1;
                    agent = item.value;
                }
                if (std.ascii.eqlIgnoreCase(item.name, "accept-encoding")) encoding = item.value;
            }
            var body: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&body, "{d} {s} {s}", .{ agents, agent, encoding });
            try request.respond(text, .{ .keep_alive = false, .extra_headers = &.{.{ .name = "content-encoding", .value = "zstd" }} });
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 5 });
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    var final_buffer: [64]u8 = undefined;
    const final = try testUrl(&final_buffer, &server, "/headers");
    const custom: []const Header = &.{ .{ .name = "User-Agent", .value = "page/1" }, .{ .name = "Accept-Encoding", .value = "zstd" } };

    var manual = try fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/hop"), .redirect = .manual }, .{}, null);
    defer manual.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.found, manual.head.status);
    try std.testing.expectEqualStrings("Found It", manual.head.reason);
    try std.testing.expectEqualStrings("/headers", manual.head.header("location").?);
    try std.testing.expectEqual(@as(u8, 0), manual.head.redirects);

    try std.testing.expectError(error.Redirected, fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/hop"), .redirect = .reject }, .{}, null));

    var followed = try fetch(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/hop"), .headers = custom }, .{}, null);
    defer followed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), followed.head.redirects);
    try std.testing.expectEqualStrings(final, followed.head.url);
    try std.testing.expectEqualStrings("OK", followed.head.reason);
    // One agent, the caller's; the body comes back as the server encoded it.
    try std.testing.expectEqualStrings("1 page/1 zstd", followed.body);

    // Without the caller's header an encoding the module cannot decode fails.
    try std.testing.expectError(error.UnsupportedEncoding, fetch(std.testing.allocator, &client, .{ .url = final }, .{}, null));
}

test "receive hands over the head first and flushes each read as it arrives" {
    const handler = struct {
        fn handle(server: *TestServer, request: *std.http.Server.Request) anyerror!void {
            var buffer: [64]u8 = undefined;
            var writer = try request.respondStreaming(&buffer, .{ .respond_options = .{ .status = .accepted, .keep_alive = false } });
            try writer.writer.writeAll("first");
            try writer.writer.flush();
            try writer.flush();
            // The rest waits until the client saw the first bytes.
            server.release.wait();
            try writer.writer.writeAll(" second");
            try writer.end();
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 1 });
    defer thread.join();
    defer server.release.set();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var url_buffer: [64]u8 = undefined;
    const Consumer = struct {
        server: *TestServer,
        status: ?std.http.Status = null,
        body: [64]u8 = undefined,
        len: usize = 0,
        writer: std.Io.Writer,

        fn head(context: *anyopaque, value: Head) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var owned = value;
            defer owned.deinit(std.testing.allocator);
            self.status = owned.status;
        }
        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", w);
            std.debug.assert(self.status != null);
            const bytes = w.buffered();
            @memcpy(self.body[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
            w.end = 0;
            _ = splat;
            const first = data[0];
            @memcpy(self.body[self.len..][0..first.len], first);
            self.len += first.len;
            if (std.mem.eql(u8, self.body[0..self.len], "first")) self.server.release.set();
            return first.len;
        }
    };
    var storage: [4]u8 = undefined;
    var consumer: Consumer = .{ .server = &server, .writer = .{ .vtable = &.{ .drain = Consumer.drain }, .buffer = &storage } };
    try receive(std.testing.allocator, &client, .{ .url = try testUrl(&url_buffer, &server, "/stream") }, .{}, null, .{ .context = &consumer, .head = Consumer.head, .body = &consumer.writer });
    try std.testing.expectEqual(std.http.Status.accepted, consumer.status.?);
    try std.testing.expectEqualStrings("first second", consumer.body[0..consumer.len]);
}
