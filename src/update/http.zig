const std = @import("std");
const zio = @import("ziggurat_io");
const download = @import("download.zig");

/// `download.Source` over `std.http.Client`, for an application-managed
/// worker thread. Resumes with a `Range` request; a 200 response restarts
/// from zero. The client, its connection pool and CA bundle belong to the
/// caller and must not be shared with another thread while a fetch runs.
/// HTTPS certificate validation uses the client's system CA bundle.
pub const Source = struct {
    client: *std.http.Client,
    request: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
    range_buffer: [48]u8 = undefined,
    redirect_buffer: [8 * 1024]u8 = undefined,
    transfer_buffer: [16 * 1024]u8 = undefined,
    status: std.http.Status = .ok,
    latch: Latch = undefined,

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
        std.debug.assert(self.request == null);
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const range = try std.fmt.bufPrint(&self.range_buffer, "bytes={d}-", .{offset});
        const headers = [_]std.http.Header{.{ .name = "Range", .value = range }};
        self.request = try self.client.request(.GET, uri, .{
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = if (offset > 0) &headers else &.{},
        });
        errdefer close(self);
        try self.request.?.sendBodiless();
        self.response = try self.request.?.receiveHead(&self.redirect_buffer);
        self.status = self.response.head.status;
        const start: u64 = switch (self.status) {
            .ok => 0,
            .partial_content => offset,
            else => return error.HttpStatus,
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
    }
};

/// Fetch a small document such as a feed into caller-owned memory, failing
/// once it exceeds `limit` bytes.
pub fn get(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, limit: usize) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var request = try client.request(.GET, uri, .{ .keep_alive = false, .headers = .{ .accept_encoding = .{ .override = "identity" } } });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpStatus;
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
