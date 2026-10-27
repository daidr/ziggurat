const std = @import("std");
const runtime = @import("ziggurat_page_runtime");
const websocket = @import("websocket.zig");
const Service = websocket.Service;
const allocator = std.testing.allocator;
const service = "plugin:websocket";

/// A local WebSocket server running one script per accepted connection.
const Server = struct {
    server: std.net.Server,
    script: *const fn (*Server, *std.http.Server.WebSocket, *const std.http.Server.Request.Head) anyerror!void,
    failure: ?anyerror = null,
    /// What the script saw, for the test to check.
    seen: std.ArrayList(u8) = .empty,
    mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,

    fn start(self: *Server, script: *const fn (*Server, *std.http.Server.WebSocket, *const std.http.Server.Request.Head) anyerror!void, count: usize) !void {
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        self.* = .{ .server = try address.listen(.{ .reuse_address = true }), .script = script };
        self.thread = try std.Thread.spawn(.{}, serve, .{ self, count });
    }

    fn stop(self: *Server) void {
        if (self.thread) |thread| thread.join();
        self.seen.deinit(allocator);
        self.server.deinit();
    }

    fn url(self: *Server, buffer: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "ws://127.0.0.1:{d}{s}", .{ self.server.listen_address.getPort(), path });
    }

    fn note(self: *Server, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.seen.appendSlice(allocator, text) catch {};
        self.seen.append(allocator, ';') catch {};
    }

    fn saw(self: *Server, buffer: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(buffer.len, self.seen.items.len);
        @memcpy(buffer[0..n], self.seen.items[0..n]);
        return buffer[0..n];
    }

    fn serve(self: *Server, count: usize) void {
        for (0..count) |_| self.one() catch |err| {
            self.failure = err;
        };
    }

    fn one(self: *Server) !void {
        const connection = try self.server.accept();
        defer connection.stream.close();
        var receive_buffer: [256 * 1024]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = connection.stream.reader(&receive_buffer);
        var writer = connection.stream.writer(&send_buffer);
        var http: std.http.Server = .init(reader.interface(), &writer.interface);
        var request = try http.receiveHead();
        const key = switch (request.upgradeRequested()) {
            .websocket => |value| value orelse return error.MissingKey,
            else => return error.NotUpgrade,
        };
        var protocol: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) {
                var offered = std.mem.tokenizeAny(u8, header.value, ", ");
                while (offered.next()) |item| if (std.mem.eql(u8, item, "chat.v2")) {
                    protocol = "chat.v2";
                };
            }
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) self.note(header.value);
        }
        const head = request.head;
        const extra = [_]std.http.Header{.{ .name = "sec-websocket-protocol", .value = protocol orelse "" }};
        var socket = try request.respondWebSocket(.{ .key = key, .extra_headers = if (protocol != null) &extra else &.{} });
        try socket.flush();
        try self.script(self, &socket, &head);
    }
};

/// Reads one masked client frame on the server.
fn readFrame(socket: *std.http.Server.WebSocket) !struct { opcode: u4, data: []u8 } {
    const header = try socket.input.takeArray(2);
    const opcode: u4 = @truncate(header[0]);
    const len: usize = switch (header[1] & 0x7F) {
        126 => try socket.input.takeInt(u16, .big),
        127 => @intCast(try socket.input.takeInt(u64, .big)),
        else => |value| value,
    };
    const mask = (try socket.input.takeArray(4)).*;
    const data = try socket.input.take(len);
    for (data, 0..) |*byte, index| byte.* ^= mask[index % 4];
    return .{ .opcode = opcode, .data = data };
}

fn closeFrame(socket: *std.http.Server.WebSocket, code: u16, reason: []const u8) !void {
    var payload: [125]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], code, .big);
    @memcpy(payload[2..][0..reason.len], reason);
    try socket.writeMessage(payload[0 .. 2 + reason.len], .connection_close);
}

const Fixture = struct {
    page: runtime.testing.Page = undefined,
    plugin: websocket.Plugin = undefined,

    fn init(self: *Fixture, options: struct { allow: ?websocket.Allow = null, connections: u8 = 2, close_timeout_ms: u32 = 5000 }) !void {
        self.page.init(allocator);
        try self.plugin.init(allocator, .{ .post = self.page.queue.poster(), .connections = options.connections, .allow = options.allow, .close_timeout_ms = options.close_timeout_ms });
        try self.page.host.use(self.plugin.plugin());
        try self.page.connect();
        var configuration = try self.page.next(1000);
        configuration.deinit();
    }

    fn deinit(self: *Fixture) void {
        self.page.host.detach();
        self.plugin.deinit();
        self.page.deinit();
    }

    fn connect(self: *Fixture, call: u32, id: u32, target: []const u8, extra: struct { protocols: []const []const u8 = &.{}, headers: []const Service.Header = &.{} }) !void {
        try self.page.call(service, @intCast(call % 32), call, "connect", Service.Connect{ .id = id, .url = target, .protocols = extra.protocols, .headers = extra.headers });
    }

    fn send(self: *Fixture, call: u32, id: u32, kind: Service.Outgoing, data: []const u8, last: bool) !void {
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, data);
        try self.page.call(service, @intCast(call % 32), call, "send", Service.Message{ .id = id, .kind = kind, .data = encoded, .last = last, .code = 0, .reason = null });
    }

    fn close(self: *Fixture, call: u32, id: u32, code: u16, reason: []const u8) !void {
        try self.page.call(service, @intCast(call % 32), call, "send", Service.Message{ .id = id, .kind = .close, .data = null, .last = true, .code = code, .reason = reason });
    }

    /// The next packet for `call`, acknowledging a chunk as the page would.
    fn next(self: *Fixture, call: u32) !Packet {
        var packet = try self.page.next(5000);
        errdefer packet.deinit();
        const object = packet.value.object;
        if (object.get("id").?.integer != call) return error.UnexpectedCall;
        const kind = object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "chunk")) try self.page.ack(service, @intCast(call % 32), call, @intCast(object.get("sequence").?.integer));
        return .{ .parsed = packet };
    }

    /// Waits for the result of a non-streaming call.
    fn done(self: *Fixture, call: u32) !void {
        var packet = try self.next(call);
        defer packet.deinit();
        if (!std.mem.eql(u8, packet.kind(), "result")) return error.NotResult;
    }

    /// Reads events of connection `call` up to and including the next whole
    /// message or other event.
    fn event(self: *Fixture, call: u32, message: *std.ArrayList(u8)) !Service.Kind {
        message.clearRetainingCapacity();
        while (true) {
            var packet = try self.next(call);
            defer packet.deinit();
            if (!std.mem.eql(u8, packet.kind(), "chunk")) return error.NotChunk;
            const value = packet.parsed.value.object.get("value").?.object;
            const kind = std.meta.stringToEnum(Service.Kind, value.get("kind").?.string).?;
            switch (kind) {
                .open => {
                    try message.appendSlice(allocator, value.get("protocol").?.string);
                    return kind;
                },
                .close => {
                    try message.writer(allocator).print("{d}:{s}:{}:{s}", .{
                        value.get("code").?.integer,
                        value.get("reason").?.string,
                        value.get("clean").?.bool,
                        if (value.get("error").? == .string) value.get("error").?.string else "",
                    });
                    return kind;
                },
                .text, .binary => {
                    const text = value.get("data").?.string;
                    const start = message.items.len;
                    try message.resize(allocator, start + try std.base64.standard.Decoder.calcSizeForSlice(text));
                    try std.base64.standard.Decoder.decode(message.items[start..], text);
                    if (value.get("last").?.bool) return kind;
                },
            }
        }
    }
};

const Packet = struct {
    parsed: std.json.Parsed(std.json.Value),
    fn deinit(self: *Packet) void {
        self.parsed.deinit();
    }
    fn kind(self: *const Packet) []const u8 {
        return self.parsed.value.object.get("kind").?.string;
    }
    fn errorCode(self: *const Packet) []const u8 {
        return self.parsed.value.object.get("error").?.object.get("code").?.string;
    }
};

fn echo(server: *Server, socket: *std.http.Server.WebSocket, head: *const std.http.Server.Request.Head) anyerror!void {
    server.note(head.target);
    while (true) {
        const frame = try readFrame(socket);
        switch (frame.opcode) {
            0x1 => try socket.writeMessage(frame.data, .text),
            0x2 => try socket.writeMessage(frame.data, .binary),
            0x8 => {
                const code = std.mem.readInt(u16, frame.data[0..2], .big);
                var buffer: [32]u8 = undefined;
                server.note(try std.fmt.bufPrint(&buffer, "close {d} {s}", .{ code, frame.data[2..] }));
                try closeFrame(socket, code, "bye");
                return;
            },
            else => {},
        }
    }
}

test "a connection opens with the chosen subprotocol, echoes messages in pieces and closes cleanly" {
    var server: Server = undefined;
    try server.start(echo, 1);
    defer server.stop();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [128]u8 = undefined;
    try f.connect(1, 7, try server.url(&buffer, "/live?room=1"), .{ .protocols = &.{ "chat.v1", "chat.v2" }, .headers = &.{ .{ .name = "Authorization", .value = "Bearer token" }, .{ .name = "Sec-WebSocket-Key", .value = "page" } } });
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try std.testing.expectEqual(Service.Kind.open, try f.event(1, &message));
    try std.testing.expectEqualStrings("chat.v2", message.items);

    try f.send(2, 7, .text, "héllo", true);
    try f.done(2);
    try std.testing.expectEqual(Service.Kind.text, try f.event(1, &message));
    try std.testing.expectEqualStrings("héllo", message.items);

    // A binary message larger than a piece goes and comes back in pieces.
    const big = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(big);
    for (big, 0..) |*byte, index| byte.* = @truncate(index * 31);
    var call: u32 = 3;
    var offset: usize = 0;
    while (offset < big.len) : (call += 1) {
        const end = @min(big.len, offset + websocket.piece_bytes);
        try f.send(call, 7, .binary, big[offset..end], end == big.len);
        try f.done(call);
        offset = end;
    }
    try std.testing.expectEqual(Service.Kind.binary, try f.event(1, &message));
    try std.testing.expectEqualSlices(u8, big, message.items);

    try f.close(call, 7, 4000, "done");
    try f.done(call);
    try std.testing.expectEqual(Service.Kind.close, try f.event(1, &message));
    try std.testing.expectEqualStrings("4000:bye:true:", message.items);
    try f.done(1);
    // Sending after the close fails.
    try f.send(call + 1, 7, .text, "late", true);
    var late = try f.next(call + 1);
    defer late.deinit();
    try std.testing.expectEqualStrings("closed", late.errorCode());
    var seen: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Bearer token;/live?room=1;close 4000 done;", server.saw(&seen));
}

test "the server closing and a refused connection end with their codes" {
    const script = struct {
        fn run(_: *Server, socket: *std.http.Server.WebSocket, _: *const std.http.Server.Request.Head) anyerror!void {
            try socket.writeMessage("welcome", .text);
            try closeFrame(socket, 4001, "go away");
            const frame = try readFrame(socket);
            if (frame.opcode != 0x8) return error.NoCloseEcho;
        }
    }.run;
    var server: Server = undefined;
    try server.start(script, 1);
    defer server.stop();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [128]u8 = undefined;
    try f.connect(1, 1, try server.url(&buffer, "/"), .{});
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try std.testing.expectEqual(Service.Kind.open, try f.event(1, &message));
    try std.testing.expectEqualStrings("", message.items);
    try std.testing.expectEqual(Service.Kind.text, try f.event(1, &message));
    try std.testing.expectEqualStrings("welcome", message.items);
    try std.testing.expectEqual(Service.Kind.close, try f.event(1, &message));
    try std.testing.expectEqualStrings("4001:go away:true:", message.items);
    try f.done(1);

    // Nothing listens on a port the server gave back.
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var closed = try address.listen(.{});
    const port = closed.listen_address.getPort();
    closed.deinit();
    const refused = try std.fmt.bufPrint(&buffer, "ws://127.0.0.1:{d}/", .{port});
    try f.connect(2, 2, refused, .{});
    try std.testing.expectEqual(Service.Kind.close, try f.event(2, &message));
    try std.testing.expectEqualStrings("1006::false:ConnectionFailed", message.items);
    try f.done(2);
}

test "invalid, refused and excess connections fail before dialing" {
    const Deny = struct {
        fn allow(_: *anyopaque, request: websocket.Request) bool {
            return std.mem.indexOf(u8, request.url, "denied") == null;
        }
    };
    var context: u8 = 0;
    var f: Fixture = .{};
    try f.init(.{ .allow = .{ .context = &context, .allow = Deny.allow }, .connections = 1 });
    defer f.deinit();
    const cases = [_]struct { url: []const u8, protocols: []const []const u8 = &.{}, code: []const u8 }{
        .{ .url = "http://example.com/", .code = "invalid" },
        .{ .url = "not a url", .code = "invalid" },
        .{ .url = "ws://example.com/", .protocols = &.{"bad protocol"}, .code = "invalid" },
        .{ .url = "ws://example.com/", .protocols = &.{ "a", "a" }, .code = "invalid" },
        .{ .url = "ws://example.com/denied", .code = "denied" },
    };
    for (cases, 1..) |case, call| {
        try f.connect(@intCast(call), @intCast(call), case.url, .{ .protocols = case.protocols });
        var packet = try f.next(@intCast(call));
        defer packet.deinit();
        try std.testing.expectEqualStrings(case.code, packet.errorCode());
    }
    // An unknown connection cannot send.
    try f.send(10, 99, .text, "x", true);
    var unknown = try f.next(10);
    defer unknown.deinit();
    try std.testing.expectEqualStrings("closed", unknown.errorCode());
}

test "a page going away closes its connections as going away" {
    const script = struct {
        fn run(server: *Server, socket: *std.http.Server.WebSocket, _: *const std.http.Server.Request.Head) anyerror!void {
            try socket.writeMessage("ready", .text);
            const frame = try readFrame(socket);
            if (frame.opcode != 0x8) return error.NoClose;
            var buffer: [32]u8 = undefined;
            server.note(try std.fmt.bufPrint(&buffer, "close {d}", .{std.mem.readInt(u16, frame.data[0..2], .big)}));
            try closeFrame(socket, 1001, "");
        }
    }.run;
    var server: Server = undefined;
    try server.start(script, 1);
    defer server.stop();
    var f: Fixture = .{};
    try f.init(.{});
    defer f.deinit();
    var buffer: [128]u8 = undefined;
    try f.connect(1, 1, try server.url(&buffer, "/"), .{});
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try std.testing.expectEqual(Service.Kind.open, try f.event(1, &message));
    try std.testing.expectEqual(Service.Kind.text, try f.event(1, &message));
    // A new document replaces the page.
    try f.page.connect();
    var waited: usize = 0;
    while (!free(&f.plugin)) : (waited += 1) {
        if (waited == 500) return error.ConnectionsLeft;
        f.page.queue.runOne(10) catch {};
    }
    var seen: [64]u8 = undefined;
    try std.testing.expectEqualStrings("close 1001;", server.saw(&seen));
}

test "a server that misses the closing handshake times out" {
    const script = struct {
        fn run(_: *Server, socket: *std.http.Server.WebSocket, _: *const std.http.Server.Request.Head) anyerror!void {
            const frame = try readFrame(socket);
            if (frame.opcode != 0x8) return error.NoClose;
            // Holds the connection open without answering.
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }.run;
    var server: Server = undefined;
    try server.start(script, 1);
    defer server.stop();
    var f: Fixture = .{};
    try f.init(.{ .close_timeout_ms = 100 });
    defer f.deinit();
    var buffer: [128]u8 = undefined;
    try f.connect(1, 1, try server.url(&buffer, "/"), .{});
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(allocator);
    try std.testing.expectEqual(Service.Kind.open, try f.event(1, &message));
    try f.close(2, 1, 1000, "");
    try f.done(2);
    try std.testing.expectEqual(Service.Kind.close, try f.event(1, &message));
    try std.testing.expectEqualStrings("1006::false:", message.items);
    try f.done(1);
}

fn free(plugin: *websocket.Plugin) bool {
    for (&plugin.connections) |*connection| if (connection.phase != .free) return false;
    return true;
}
