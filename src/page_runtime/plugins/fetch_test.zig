const std = @import("std");
const zio = @import("ziggurat_io");
const net = @import("ziggurat_net");
const runtime = @import("ziggurat_page_runtime");
const fetch = @import("fetch.zig");
const TestServer = net.fetch_api.TestServer;
const allocator = std.testing.allocator;
const service = "plugin:fetch";

const Fixture = struct {
    page: runtime.testing.Page = undefined,
    plugin: fetch.Plugin = undefined,

    fn init(self: *Fixture, options: struct { allow: ?fetch.Allow = null, workers: u8 = 2 }) !void {
        self.page.init(allocator);
        try self.plugin.init(allocator, .{ .post = self.page.queue.poster(), .workers = options.workers, .allow = options.allow });
        try self.page.host.use(self.plugin.plugin());
        try self.page.connect();
        // The configuration.
        var configuration = try self.page.next(1000);
        configuration.deinit();
    }

    fn deinit(self: *Fixture) void {
        self.page.host.detach();
        self.plugin.deinit();
        self.page.deinit();
    }

    fn request(self: *Fixture, id: u32, target: []const u8, extra: struct { method: []const u8 = "GET", headers: []const fetch.Service.Header = &.{}, body: ?[]const u8 = null, upload: ?u32 = null, redirect: fetch.Service.Redirect = .follow }) !void {
        try self.page.call(service, @intCast(id % 32), id, "fetch", fetch.Service.Request{ .url = target, .method = extra.method, .headers = extra.headers, .body = extra.body, .upload = extra.upload, .redirect = extra.redirect });
    }

    /// Reads one call's stream to its end, acknowledging every chunk as the
    /// page would.
    fn response(self: *Fixture, id: u32, body: *std.ArrayList(u8)) !Outcome {
        var outcome: Outcome = .{};
        errdefer outcome.deinit();
        while (true) {
            var packet = try self.page.next(5000);
            defer packet.deinit();
            const object = packet.value.object;
            if (object.get("id").?.integer != id) return error.UnexpectedCall;
            const kind = object.get("kind").?.string;
            if (std.mem.eql(u8, kind, "chunk")) {
                const value = object.get("value").?.object;
                if (value.get("head").? != .null) {
                    outcome.head = try std.json.parseFromValue(fetch.Service.Head, allocator, value.get("head").?, .{});
                }
                if (value.get("chunk").? == .string) {
                    const text = value.get("chunk").?.string;
                    const start = body.items.len;
                    try body.resize(allocator, start + try std.base64.standard.Decoder.calcSizeForSlice(text));
                    try std.base64.standard.Decoder.decode(body.items[start..], text);
                }
                try self.page.ack(service, @intCast(id % 32), id, @intCast(object.get("sequence").?.integer));
            } else if (std.mem.eql(u8, kind, "result")) {
                return outcome;
            } else if (std.mem.eql(u8, kind, "error")) {
                const failure = object.get("error").?.object;
                outcome.code = std.meta.stringToEnum(fetch.Service.Code, failure.get("code").?.string);
                const message = failure.get("message").?.string;
                @memcpy(outcome.message[0..message.len], message);
                outcome.message_len = message.len;
                return outcome;
            } else return error.UnexpectedKind;
        }
    }

    fn idle(self: *Fixture) !void {
        // Every job comes back once its worker lets go of it.
        var waited: usize = 0;
        while (!self.free()) : (waited += 1) {
            if (waited == 500) return error.JobsLeft;
            self.page.queue.runOne(10) catch {};
        }
    }

    fn free(self: *Fixture) bool {
        for (&self.plugin.jobs) |*job| if (job.phase != .free) return false;
        return true;
    }
};

const Outcome = struct {
    head: ?std.json.Parsed(fetch.Service.Head) = null,
    code: ?fetch.Service.Code = null,
    message: [128]u8 = undefined,
    message_len: usize = 0,

    fn deinit(self: *Outcome) void {
        if (self.head) |*head| head.deinit();
    }
    fn text(self: *const Outcome) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Ends a server thread that may still wait for connections a failed test
/// never made: each extra connection ends one wait.
fn finish(server: *TestServer, thread: std.Thread, count: usize) void {
    server.release.set();
    const address = std.Io.net.IpAddress.parse("127.0.0.1", server.port()) catch unreachable;
    for (0..count) |_| {
        const stream = address.connect(zio.io(), .{ .mode = .stream }) catch break;
        stream.close(zio.io());
    }
    thread.join();
}

fn url(buffer: []u8, server: *const TestServer, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}{s}", .{ server.port(), path });
}

test "a streamed body larger than the page's credit arrives whole and in order" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            var agent: []const u8 = "";
            var iterator = request.iterateHeaders();
            while (iterator.next()) |item| if (std.ascii.eqlIgnoreCase(item.name, "x-page")) {
                agent = item.value;
            };
            if (!std.mem.eql(u8, agent, "yes")) return error.MissingHeader;
            var buffer: [4096]u8 = undefined;
            var writer = try request.respondStreaming(&buffer, .{ .respond_options = .{ .status = .created, .reason = "Made", .keep_alive = false, .extra_headers = &.{ .{ .name = "X-Kind", .value = "bytes" }, .{ .name = "Set-Cookie", .value = "a=1" } } } });
            var block: [1000]u8 = undefined;
            for (0..1200) |index| {
                for (&block, 0..) |*byte, offset| byte.* = @truncate(index * 7 + offset);
                try writer.writer.writeAll(&block);
            }
            try writer.end();
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 1 });
    defer finish(&server, thread, 1);
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [64]u8 = undefined;
    try f.request(1, try url(&buffer, &server, "/bytes"), .{ .headers = &.{.{ .name = "X-Page", .value = "yes" }} });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var outcome = try f.response(1, &body);
    defer outcome.deinit();
    try std.testing.expectEqual(null, outcome.code);
    const head = outcome.head.?.value;
    try std.testing.expectEqual(201, head.status);
    try std.testing.expectEqualStrings("Made", head.statusText);
    try std.testing.expect(!head.redirected);
    var kind: ?[]const u8 = null;
    for (head.headers) |header| {
        try std.testing.expect(!std.mem.eql(u8, header.name, "set-cookie"));
        if (std.mem.eql(u8, header.name, "x-kind")) kind = header.value;
    }
    try std.testing.expectEqualStrings("bytes", kind.?);
    try std.testing.expectEqual(1_200_000, body.items.len);
    for (0..1200) |index| for (0..1000) |offset| {
        if (body.items[index * 1000 + offset] != @as(u8, @truncate(index * 7 + offset))) return error.WrongByte;
    };
    try f.idle();
}

test "posts carry their body and redirects follow the requested mode" {
    const handler = struct {
        fn handle(_: *TestServer, request: *std.http.Server.Request) anyerror!void {
            if (std.mem.eql(u8, request.head.target, "/hop")) {
                return request.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = "/landed" }} });
            }
            if (request.head.method == .POST or request.head.method == .PUT) {
                var buffer: [64]u8 = undefined;
                const body = try (try request.readerExpectContinue(&buffer)).allocRemaining(allocator, .limited(1024 * 1024));
                defer allocator.free(body);
                return request.respond(body, .{ .keep_alive = false });
            }
            try request.respond("landed", .{ .keep_alive = false });
        }
    }.handle;
    var server = try TestServer.init(handler);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, TestServer.serve, .{ &server, 7 });
    defer finish(&server, thread, 7);
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [64]u8 = undefined;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try f.request(1, try url(&buffer, &server, "/echo"), .{ .method = "POST", .body = "aGVsbG8gYm9keQ==" });
    var posted = try f.response(1, &body);
    defer posted.deinit();
    try std.testing.expectEqualStrings("hello body", body.items);

    // A body sent in pieces first.
    body.clearRetainingCapacity();
    try f.page.call(service, 9, 9, "upload", fetch.Service.Piece{ .upload = 5, .data = "aGVsbG8g" });
    try f.page.call(service, 10, 10, "upload", fetch.Service.Piece{ .upload = 5, .data = "cGllY2Vz" });
    for (0..2) |_| {
        var reply = try f.page.next(1000);
        defer reply.deinit();
        try std.testing.expectEqualStrings("result", reply.value.object.get("kind").?.string);
    }
    try f.request(11, try url(&buffer, &server, "/echo"), .{ .method = "POST", .upload = 5 });
    var uploaded = try f.response(11, &body);
    defer uploaded.deinit();
    try std.testing.expectEqualStrings("hello pieces", body.items);
    // Pieces as large as the page sends them, 300 KB in all.
    var piece: [36 * 1024]u8 = undefined;
    var encoded: [std.base64.standard.Encoder.calcSize(piece.len)]u8 = undefined;
    var sent: usize = 0;
    var id: u32 = 20;
    while (sent < 300_000) : (id += 1) {
        const n = @min(piece.len, 300_000 - sent);
        for (piece[0..n], sent..) |*byte, index| byte.* = @truncate(index * 7);
        try f.page.call(service, @intCast(id % 32), id, "upload", fetch.Service.Piece{ .upload = 6, .data = std.base64.standard.Encoder.encode(&encoded, piece[0..n]) });
        var reply = try f.page.next(1000);
        defer reply.deinit();
        try std.testing.expectEqualStrings("result", reply.value.object.get("kind").?.string);
        sent += n;
    }
    body.clearRetainingCapacity();
    try f.request(id, try url(&buffer, &server, "/echo"), .{ .method = "PUT", .upload = 6 });
    var large = try f.response(id, &body);
    defer large.deinit();
    try std.testing.expectEqual(null, large.code);
    try std.testing.expectEqual(300_000, body.items.len);
    for (body.items, 0..) |byte, index| if (byte != @as(u8, @truncate(index * 7))) return error.WrongByte;
    try std.testing.expectEqual(0, f.plugin.upload_bytes);

    body.clearRetainingCapacity();
    try f.request(id + 12, try url(&buffer, &server, "/hop"), .{});
    var followed = try f.response(id + 12, &body);
    defer followed.deinit();
    try std.testing.expect(followed.head.?.value.redirected);
    try std.testing.expect(std.mem.endsWith(u8, followed.head.?.value.url, "/landed"));
    try std.testing.expectEqualStrings("landed", body.items);

    body.clearRetainingCapacity();
    try f.request(id + 13, try url(&buffer, &server, "/hop"), .{ .redirect = .manual });
    var manual = try f.response(id + 13, &body);
    defer manual.deinit();
    try std.testing.expectEqual(302, manual.head.?.value.status);

    try f.request(id + 14, try url(&buffer, &server, "/hop"), .{ .redirect = .@"error" });
    var refused = try f.response(id + 14, &body);
    defer refused.deinit();
    try std.testing.expectEqual(.failed, refused.code.?);
    try std.testing.expectEqualStrings("Redirected", refused.text());
    try f.idle();
}

test "invalid and refused requests fail before any connection" {
    const Gate = struct {
        fn allow(_: *anyopaque, request: fetch.Request) bool {
            return std.mem.indexOf(u8, request.url, "allowed") != null;
        }
    };
    var gate: u8 = 0;
    var f: Fixture = .{};
    try f.init(.{ .allow = .{ .context = &gate, .allow = Gate.allow } });
    defer f.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    const cases = [_]struct { url: []const u8, method: []const u8 = "GET", headers: []const fetch.Service.Header = &.{}, body: ?[]const u8 = null, upload: ?u32 = null, code: fetch.Service.Code }{
        .{ .url = "http://allowed.invalid/", .method = "BREW", .code = .invalid },
        .{ .url = "ftp://allowed.invalid/", .code = .invalid },
        .{ .url = "not a url", .code = .invalid },
        .{ .url = "http://allowed.invalid/", .body = "eA==", .code = .invalid },
        .{ .url = "http://allowed.invalid/", .method = "POST", .body = "%%%", .code = .invalid },
        .{ .url = "http://allowed.invalid/", .headers = &.{.{ .name = "x", .value = "a\r\nb: c" }}, .code = .invalid },
        .{ .url = "http://allowed.invalid/", .headers = &.{.{ .name = "bad name", .value = "v" }}, .code = .invalid },
        .{ .url = "http://elsewhere.invalid/", .code = .denied },
        .{ .url = "http://allowed.invalid/", .method = "POST", .upload = 77, .code = .invalid },
    };
    for (cases, 1..) |case, id| {
        try f.request(@intCast(id), case.url, .{ .method = case.method, .headers = case.headers, .body = case.body, .upload = case.upload });
        var outcome = try f.response(@intCast(id), &body);
        defer outcome.deinit();
        try std.testing.expectEqual(case.code, outcome.code.?);
    }
    try f.idle();
}

fn stall(server: *TestServer, request: *std.http.Server.Request) anyerror!void {
    var buffer: [64]u8 = undefined;
    var writer = try request.respondStreaming(&buffer, .{ .content_length = 100, .respond_options = .{ .keep_alive = false } });
    try writer.writer.writeAll("partial");
    try writer.writer.flush();
    try writer.flush();
    server.release.wait();
}

test "cancel and a departing page stop requests stalled on the network" {
    var servers: [2]TestServer = undefined;
    var threads: [2]std.Thread = undefined;
    for (&servers, &threads) |*server, *thread| {
        server.* = try TestServer.init(stall);
        thread.* = try std.Thread.spawn(.{}, TestServer.serve, .{ server, 1 });
    }
    defer for (&servers, &threads) |*server, thread| {
        finish(server, thread, 1);
        server.deinit();
    };
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [64]u8 = undefined;
    try f.request(1, try url(&buffer, &servers[0], "/stall"), .{});
    // The head arrives, then the page cancels.
    var packet = try f.page.next(5000);
    packet.deinit();
    try f.page.cancel(service, 1, 1);
    try f.idle();

    f.page.seen = f.page.packets.items.len;
    try f.request(2, try url(&buffer, &servers[1], "/stall"), .{});
    packet = try f.page.next(5000);
    try std.testing.expectEqual(2, packet.value.object.get("id").?.integer);
    packet.deinit();
    f.page.host.pageChanged();
    try f.idle();
    // Nothing more reaches the page for either call.
    const packets = f.page.packets.items.len;
    f.page.queue.runOne(50) catch {};
    try std.testing.expectEqual(packets, f.page.packets.items.len);
}

test "an unreachable server fails the call" {
    // A port that was just free refuses the connection.
    var server = try TestServer.init(undefined);
    const port = server.port();
    server.deinit();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [64]u8 = undefined;
    try f.request(1, try std.fmt.bufPrint(&buffer, "http://127.0.0.1:{d}/", .{port}), .{});
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var outcome = try f.response(1, &body);
    defer outcome.deinit();
    try std.testing.expectEqual(.failed, outcome.code.?);
    try std.testing.expectEqualStrings("ConnectionFailed", outcome.text());
    try f.idle();
}
