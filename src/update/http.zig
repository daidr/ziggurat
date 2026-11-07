const std = @import("std");
const zio = @import("ziggurat_io");
const download = @import("download.zig");
const net = @import("ziggurat_net");

/// The User-Agent of update requests: a fixed ASCII name, never the app's,
/// as some release hosts refuse a User-Agent with bytes outside ASCII.
pub const user_agent = "ziggurat-updater";

/// How requests that failed for a moment are tried again: a network error,
/// or a 429, 500, 502, 503 or 504 answer, is asked again after each delay
/// in turn (three tries in all by default), waiting at least what the
/// server's `Retry-After` says in seconds, up to 30 seconds. Other statuses,
/// as 404, fail at once. Setting `cancel` stops the waiting: the request
/// then fails with the last error.
pub const Retry = struct {
    delays_ns: []const u64 = &.{ std.time.ns_per_s, 3 * std.time.ns_per_s },
    cancel: ?*const std.atomic.Value(bool) = null,

    /// Waits before try `index + 1` (counting the first as 0), polling
    /// `cancel`; false when no try is left or the wait was cancelled.
    fn wait(self: Retry, index: usize, retry_after_ns: u64) bool {
        if (index >= self.delays_ns.len) return false;
        var left = @max(self.delays_ns[index], retry_after_ns);
        while (left > 0) {
            if (self.cancelled()) return false;
            const step = @min(left, 50 * std.time.ns_per_ms);
            zio.sleep(step);
            left -= step;
        }
        return !self.cancelled();
    }

    fn cancelled(self: Retry) bool {
        return if (self.cancel) |flag| flag.load(.acquire) else false;
    }
};

/// Whether an answer of `status` may succeed when asked again: too many
/// requests, or a server or gateway failing for now.
pub fn transientStatus(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

/// The wait a `Retry-After` header asks for in seconds, up to 30 seconds;
/// 0 for none, or for a date.
pub fn retryAfter(value: ?[]const u8) u64 {
    const text = std.mem.trim(u8, value orelse return 0, " \t");
    const seconds = std.fmt.parseInt(u64, text, 10) catch return 0;
    return @as(u64, @min(seconds, 30)) * std.time.ns_per_s;
}

fn retryAfterHeader(head: std.http.Client.Response.Head) u64 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) return retryAfter(header.value);
    return 0;
}

/// Errors that are the request's own, not the network's: no try mends them.
fn permanent(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.InvalidUrl, error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => true,
        else => false,
    };
}

/// `download.Source` over `std.http.Client`, for an application-managed
/// worker thread. Resumes with a `Range` request; a 200 response restarts
/// from zero. The client, its connection pool and CA bundle belong to the
/// caller and must not be shared with another thread while a fetch runs.
/// HTTPS certificate validation uses the client's system CA bundle.
/// Requests go through the system's proxy (`net.proxy`) unless the client
/// sets its own.
pub const Source = struct {
    client: *std.http.Client,
    request: ?std.http.Client.Request = null,
    route: net.tunnel.Route = .{},
    response: std.http.Client.Response = undefined,
    range_buffer: [48]u8 = undefined,
    redirect_buffer: [8 * 1024]u8 = undefined,
    transfer_buffer: [16 * 1024]u8 = undefined,
    status: std.http.Status = .ok,
    latch: Latch = undefined,
    /// How a transfer that failed for a moment is asked again.
    retry: Retry = .{},
    retry_after: u64 = 0,

    /// Body readers must not be read again after reporting end of stream;
    /// the latch keeps repeated reads at EndOfStream.
    const Latch = struct {
        inner: *std.Io.Reader,
        ended: bool = false,
        buffer: [16 * 1024]u8 = undefined,
        interface: std.Io.Reader,
        fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Latch = @alignCast(@fieldParentPtr("interface", reader));
            if (self.ended) return error.EndOfStream;
            return self.inner.stream(writer, limit) catch |err| {
                if (err == error.EndOfStream) self.ended = true;
                return err;
            };
        }
    };

    pub fn init(client: *std.http.Client) Source {
        return .{ .client = client };
    }

    pub fn source(self: *Source) download.Source {
        return .{ .context = self, .open = open, .close = close };
    }

    fn open(context: *anyopaque, url: []const u8, offset: u64) anyerror!download.Body {
        const self: *Source = @ptrCast(@alignCast(context));
        var index: usize = 0;
        while (true) : (index += 1) {
            if (self.openOnce(url, offset)) |body| return body else |err| {
                if (permanent(err)) return err;
                const transient = err != error.HttpStatus or transientStatus(self.status);
                if (!transient or !self.retry.wait(index, if (err == error.HttpStatus) self.retry_after else 0)) return err;
            }
        }
    }

    fn openOnce(self: *Source, url: []const u8, offset: u64) anyerror!download.Body {
        std.debug.assert(self.request == null);
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        self.retry_after = 0;
        const range = try std.fmt.bufPrint(&self.range_buffer, "bytes={d}-", .{offset});
        const headers = [_]std.http.Header{.{ .name = "Range", .value = range }};
        self.request = try self.route.request(self.client.allocator, self.client, &.system, .GET, uri, .{
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" }, .user_agent = .{ .override = user_agent } },
            .extra_headers = if (offset > 0) &headers else &.{},
        }, null);
        errdefer close(self);
        try self.request.?.sendBodiless();
        self.response = try self.request.?.receiveHead(&self.redirect_buffer);
        self.status = self.response.head.status;
        const start: u64 = switch (self.status) {
            .ok => 0,
            .partial_content => offset,
            else => {
                self.retry_after = retryAfterHeader(self.response.head);
                return error.HttpStatus;
            },
        };
        if (self.response.head.content_encoding != .identity) return error.UnsupportedEncoding;
        self.latch = .{ .inner = self.response.reader(&self.transfer_buffer), .interface = undefined };
        self.latch.interface = .{ .buffer = &self.latch.buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = Latch.stream } };
        return .{ .reader = &self.latch.interface, .offset = start };
    }

    fn close(context: *anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(context));
        if (self.request) |*request| request.deinit();
        self.request = null;
        self.route.deinit();
    }
};

/// Fetch a small document such as a feed into caller-owned memory, failing
/// once it exceeds `limit` bytes, through the system's proxy unless the
/// client sets its own.
pub fn get(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, limit: usize) ![]u8 {
    return getRetrying(allocator, client, url, limit, .{});
}

/// `get`, asking again as `retry` says when a try fails for a moment.
pub fn getRetrying(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, limit: usize, retry: Retry) ![]u8 {
    var index: usize = 0;
    while (true) : (index += 1) {
        var answer: Answer = .{};
        if (getOnce(allocator, client, url, limit, &answer)) |bytes| return bytes else |err| {
            if (permanent(err) or err == error.DocumentTooLarge or err == error.UnsupportedEncoding) return err;
            const transient = err != error.HttpStatus or transientStatus(answer.status);
            if (!transient or !retry.wait(index, answer.retry_after)) return err;
        }
    }
}

const Answer = struct { status: std.http.Status = .ok, retry_after: u64 = 0 };

fn getOnce(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, limit: usize, answer: *Answer) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var route: net.tunnel.Route = .{};
    defer route.deinit();
    var request = try route.request(allocator, client, &.system, .GET, uri, .{ .keep_alive = false, .headers = .{ .accept_encoding = .{ .override = "identity" }, .user_agent = .{ .override = user_agent } } }, null);
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) {
        answer.* = .{ .status = response.head.status, .retry_after = retryAfterHeader(response.head) };
        return error.HttpStatus;
    }
    if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    // The limit is exclusive in allocRemaining; allow exactly `limit` bytes.
    return reader.allocRemaining(allocator, .limited(limit + 1)) catch |err| switch (err) {
        error.StreamTooLong => error.DocumentTooLarge,
        else => |other| other,
    };
}

const TestServer = struct {
    server: std.Io.net.Server,
    body: []const u8,
    honor_range: bool,
    requests: usize = 0,

    fn serve(self: *TestServer, count: usize) void {
        for (0..count) |_| self.one() catch return;
    }
    fn one(self: *TestServer) !void {
        const connection = try self.server.accept(zio.io());
        defer connection.close(zio.io());
        var receive_buffer: [4096]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = connection.reader(zio.io(), &receive_buffer);
        var writer = connection.writer(zio.io(), &send_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        self.requests += 1;
        var start: usize = 0;
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "range") and self.honor_range) {
            const value = header.value["bytes=".len .. header.value.len - 1];
            start = try std.fmt.parseInt(usize, value, 10);
        };
        try request.respond(self.body[start..], .{ .status = if (start > 0) .partial_content else .ok, .keep_alive = false });
    }
};

test "HTTP source resumes with ranges and restarts on full responses" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const update = @import("root.zig");
    var body: [50_000]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    for ([_]bool{ true, false }) |honor| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server: TestServer = .{ .server = try address.listen(zio.io(), .{ .reuse_address = true }), .body = &body, .honor_range = honor };
        defer server.server.deinit(zio.io());
        const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 2 });
        defer thread.join();
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/a.zip", .{server.server.socket.address.getPort()});
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
        defer client.deinit();
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        var file = try temp.dir.createFile(zio.io(), "partial", .{ .read = true });
        defer file.close(zio.io());
        try file.writeStreamingAll(zio.io(), body[0..12_345]);
        var manifest: update.Manifest = .{ .identity = "org.ziggurat.Http", .target = "linux-x86_64", .version = .{ .major = 1, .minor = 0, .patch = 0 }, .url = url, .bytes = body.len, .sha256 = undefined, .signature = @splat(0) };
        std.crypto.hash.sha2.Sha256.hash(&body, &manifest.sha256, .{});
        var http_source: Source = .init(&client);
        var control: download.Control = .{};
        const receipt = try download.fetch(manifest, http_source.source(), file, &control);
        try std.testing.expectEqual(manifest.sha256, receipt.sha256);
        try std.testing.expectEqual(if (honor) std.http.Status.partial_content else .ok, http_source.status);
        const document = try get(std.testing.allocator, &client, url, body.len);
        defer std.testing.allocator.free(document);
        try std.testing.expectEqualSlices(u8, &body, document);
    }
}

/// Answers each request with the next status of `statuses`, then 200.
const FlakyServer = struct {
    server: std.Io.net.Server,
    statuses: []const std.http.Status,
    retry_after: ?[]const u8 = null,
    requests: usize = 0,

    fn serve(self: *FlakyServer, count: usize) void {
        for (0..count) |_| self.one() catch return;
    }
    fn one(self: *FlakyServer) !void {
        const connection = try self.server.accept(zio.io());
        defer connection.close(zio.io());
        var receive_buffer: [4096]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = connection.reader(zio.io(), &receive_buffer);
        var writer = connection.writer(zio.io(), &send_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        const index = self.requests;
        self.requests += 1;
        const status: std.http.Status = if (index < self.statuses.len) self.statuses[index] else .ok;
        const headers = [_]std.http.Header{.{ .name = "Retry-After", .value = self.retry_after orelse "" }};
        try request.respond(if (status == .ok) "feed" else "", .{ .status = status, .keep_alive = false, .extra_headers = if (self.retry_after != null and status != .ok) &headers else &.{} });
    }
};

test "requests that fail for a moment are asked again, others fail at once" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;
    const fast: Retry = .{ .delays_ns = &.{ std.time.ns_per_ms, std.time.ns_per_ms } };
    const Case = struct { statuses: []const std.http.Status, requests: usize, ok: bool };
    const cases = [_]Case{
        .{ .statuses = &.{ .service_unavailable, .gateway_timeout }, .requests = 3, .ok = true },
        .{ .statuses = &.{ .too_many_requests, .bad_gateway, .internal_server_error }, .requests = 3, .ok = false },
        .{ .statuses = &.{.not_found}, .requests = 1, .ok = false },
    };
    for (cases) |case| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server: FlakyServer = .{ .server = try address.listen(zio.io(), .{ .reuse_address = true }), .statuses = case.statuses, .retry_after = "0" };
        defer server.server.deinit(zio.io());
        const thread = try std.Thread.spawn(.{}, FlakyServer.serve, .{ &server, case.requests });
        defer thread.join();
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/feed.json", .{server.server.socket.address.getPort()});
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
        defer client.deinit();
        if (getRetrying(std.testing.allocator, &client, url, 1024, fast)) |document| {
            defer std.testing.allocator.free(document);
            try std.testing.expect(case.ok);
            try std.testing.expectEqualStrings("feed", document);
        } else |err| {
            try std.testing.expect(!case.ok);
            try std.testing.expectEqual(error.HttpStatus, err);
        }
        try std.testing.expectEqual(case.requests, server.requests);
    }
}

test "Retry-After is honored up to 30 seconds and cancelling stops the wait" {
    try std.testing.expectEqual(@as(u64, 0), retryAfter(null));
    try std.testing.expectEqual(@as(u64, 0), retryAfter("Wed, 21 Oct 2015 07:28:00 GMT"));
    try std.testing.expectEqual(2 * std.time.ns_per_s, retryAfter(" 2 "));
    try std.testing.expectEqual(30 * std.time.ns_per_s, retryAfter("120"));
    var cancelled: std.atomic.Value(bool) = .init(true);
    const retry: Retry = .{ .cancel = &cancelled };
    try std.testing.expect(!retry.wait(0, 0));
    try std.testing.expect(!(Retry{ .delays_ns = &.{} }).wait(0, 0));
}
