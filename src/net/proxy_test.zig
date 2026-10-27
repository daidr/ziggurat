const std = @import("std");
const builtin = @import("builtin");
const fetch_api = @import("fetch.zig");
const websocket = @import("websocket.zig");
const proxy_api = @import("proxy.zig");

/// A proxy on loopback that answers requests itself: forwarded requests
/// with the target it was asked for, and over a CONNECT or SOCKS5 tunnel as
/// the server, with the address the tunnel was asked for.
const FakeProxy = struct {
    const Mode = enum { http, socks5 };

    server: std.net.Server,
    mode: Mode,
    /// The user and password the proxy requires, as `user:password`.
    credentials: ?[]const u8 = null,
    seen_buffer: [512]u8 = undefined,
    seen_len: usize = 0,
    authorization_buffer: [256]u8 = undefined,
    authorization_len: usize = 0,

    fn init(mode: Mode) !FakeProxy {
        const address = try std.net.Address.parseIp("127.0.0.1", 0);
        return .{ .server = try address.listen(.{ .reuse_address = true }), .mode = mode };
    }

    fn port(self: *FakeProxy) u16 {
        return self.server.listen_address.getPort();
    }

    fn seen(self: *FakeProxy) []const u8 {
        return self.seen_buffer[0..self.seen_len];
    }

    fn record(self: *FakeProxy, text: []const u8) void {
        @memcpy(self.seen_buffer[0..text.len], text);
        self.seen_len = text.len;
    }

    fn serve(self: *FakeProxy) void {
        self.one() catch {};
    }

    fn one(self: *FakeProxy) !void {
        const connection = try self.server.accept();
        defer connection.stream.close();
        switch (self.mode) {
            .http => {
                var head: [4096]u8 = undefined;
                const length = try readHead(connection.stream, &head);
                const line = head[0..std.mem.indexOf(u8, head[0..length], "\r\n").?];
                var parts = std.mem.splitScalar(u8, line, ' ');
                const method = parts.next().?;
                const target = parts.next().?;
                self.record(target);
                var lines = std.mem.splitSequence(u8, head[0..length], "\r\n");
                while (lines.next()) |header| if (std.ascii.startsWithIgnoreCase(header, "proxy-authorization: ")) {
                    const value = header["proxy-authorization: ".len..];
                    @memcpy(self.authorization_buffer[0..value.len], value);
                    self.authorization_len = value.len;
                };
                if (self.credentials != null and self.authorization_len == 0) {
                    try writeAll(connection.stream, "HTTP/1.1 407 Proxy Authentication Required\r\ncontent-length: 0\r\n\r\n");
                    return;
                }
                if (std.mem.eql(u8, method, "CONNECT")) {
                    try writeAll(connection.stream, "HTTP/1.1 200 Connection established\r\n\r\n");
                    return answer(connection.stream, "tunneled");
                }
                try respond(connection.stream, "forwarded");
            },
            .socks5 => {
                var greeting: [2]u8 = undefined;
                try readExact(connection.stream, &greeting);
                var methods: [255]u8 = undefined;
                try readExact(connection.stream, methods[0..greeting[1]]);
                if (self.credentials) |expected| {
                    try writeAll(connection.stream, &.{ 5, 2 });
                    var buffer: [600]u8 = undefined;
                    try readExact(connection.stream, buffer[0..2]);
                    const user_len = buffer[1];
                    try readExact(connection.stream, buffer[2..][0 .. @as(usize, user_len) + 1]);
                    const password_len = buffer[2 + user_len];
                    try readExact(connection.stream, buffer[3 + @as(usize, user_len) ..][0..password_len]);
                    var joined: [600]u8 = undefined;
                    const got = try std.fmt.bufPrint(&joined, "{s}:{s}", .{ buffer[2..][0..user_len], buffer[3 + @as(usize, user_len) ..][0..password_len] });
                    const ok = std.mem.eql(u8, got, expected);
                    try writeAll(connection.stream, &.{ 1, if (ok) 0 else 1 });
                    if (!ok) return;
                } else try writeAll(connection.stream, &.{ 5, 0 });
                var request: [4]u8 = undefined;
                try readExact(connection.stream, &request);
                var name: [256]u8 = undefined;
                var text: [300]u8 = undefined;
                switch (request[3]) {
                    3 => {
                        try readExact(connection.stream, name[0..1]);
                        const length = name[0];
                        try readExact(connection.stream, name[0 .. @as(usize, length) + 2]);
                        self.record(try std.fmt.bufPrint(&text, "{s}:{d}", .{ name[0..length], std.mem.readInt(u16, name[length..][0..2], .big) }));
                    },
                    1 => {
                        try readExact(connection.stream, name[0..6]);
                        self.record(try std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}:{d}", .{ name[0], name[1], name[2], name[3], std.mem.readInt(u16, name[4..6], .big) }));
                    },
                    else => return error.Unsupported,
                }
                try writeAll(connection.stream, &.{ 5, 0, 0, 1, 127, 0, 0, 1, 0, 0 });
                try answer(connection.stream, "socks");
            },
        }
    }

    fn answer(stream: std.net.Stream, body: []const u8) !void {
        var head: [4096]u8 = undefined;
        _ = try readHead(stream, &head);
        try respond(stream, body);
    }

    fn respond(stream: std.net.Stream, body: []const u8) !void {
        var buffer: [256]u8 = undefined;
        try writeAll(stream, try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body }));
    }

    fn readHead(stream: std.net.Stream, out: []u8) !usize {
        var length: usize = 0;
        while (!std.mem.endsWith(u8, out[0..length], "\r\n\r\n")) {
            if (length == out.len) return error.HeadTooLarge;
            try readExact(stream, out[length..][0..1]);
            length += 1;
        }
        return length;
    }

    fn readExact(stream: std.net.Stream, out: []u8) !void {
        var done: usize = 0;
        while (done < out.len) {
            const count = try receive(stream, out[done..]);
            if (count == 0) return error.EndOfStream;
            done += count;
        }
    }
};

// The loopback peer's socket I/O: the standard stream's read and write go
// through file I/O on Windows, which sockets refuse.
fn receive(stream: std.net.Stream, out: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        const count = ws2_32.recv(stream.handle, out.ptr, @intCast(out.len), 0);
        return if (count == ws2_32.SOCKET_ERROR) error.ReceiveFailed else @intCast(count);
    }
    return std.posix.recv(stream.handle, out, 0);
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        if (builtin.os.tag == .windows) {
            const ws2_32 = std.os.windows.ws2_32;
            const count = ws2_32.send(stream.handle, bytes[sent..].ptr, @intCast(bytes.len - sent), 0);
            if (count == ws2_32.SOCKET_ERROR) return error.SendFailed;
            sent += @intCast(count);
        } else sent += try std.posix.send(stream.handle, bytes[sent..], 0);
    }
}

fn fetchThrough(proxy: *FakeProxy, url: []const u8, comptime setting: []const u8) !fetch_api.Response {
    const thread = try std.Thread.spawn(.{}, FakeProxy.serve, .{proxy});
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var text: [128]u8 = undefined;
    const choice: proxy_api.Choice = .{ .proxy = proxy_api.Proxy.parse(try std.fmt.bufPrint(&text, setting, .{proxy.port()})).? };
    return fetch_api.fetch(std.testing.allocator, &client, .{ .url = url, .proxy = choice }, .{}, null);
}

test "plain requests are forwarded by an HTTP proxy with absolute URLs and its credentials" {
    var proxy = try FakeProxy.init(.http);
    defer proxy.server.deinit();
    var response = try fetchThrough(&proxy, "http://origin.test:8080/path?q=1", "http://user:secret@127.0.0.1:{d}");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("forwarded", response.body);
    try std.testing.expectEqualStrings("http://origin.test:8080/path?q=1", proxy.seen());
    try std.testing.expectEqualStrings("Basic dXNlcjpzZWNyZXQ=", proxy.authorization_buffer[0..proxy.authorization_len]);
}

test "an HTTP proxy that asks for credentials fails the request" {
    var proxy = try FakeProxy.init(.http);
    defer proxy.server.deinit();
    proxy.credentials = "user:secret";
    var response = try fetchThrough(&proxy, "http://origin.test/", "http://127.0.0.1:{d}");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.proxy_auth_required, response.head.status);
}

test "a SOCKS5 proxy tunnels to the host by name, with its credentials" {
    var proxy = try FakeProxy.init(.socks5);
    defer proxy.server.deinit();
    proxy.credentials = "user:secret";
    var response = try fetchThrough(&proxy, "http://origin.test:81/", "socks5://user:secret@127.0.0.1:{d}");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("socks", response.body);
    try std.testing.expectEqualStrings("origin.test:81", proxy.seen());
}

test "a SOCKS proxy that refuses the credentials fails the connection" {
    var proxy = try FakeProxy.init(.socks5);
    defer proxy.server.deinit();
    proxy.credentials = "user:secret";
    try std.testing.expectError(error.ConnectionFailed, fetchThrough(&proxy, "http://10.1.2.3/", "socks5://user:wrong@127.0.0.1:{d}"));
}

test "a SOCKS5 proxy tunnels to an address" {
    var proxy = try FakeProxy.init(.socks5);
    defer proxy.server.deinit();
    var response = try fetchThrough(&proxy, "http://10.1.2.3/", "socks://127.0.0.1:{d}");
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("socks", response.body);
    try std.testing.expectEqualStrings("10.1.2.3:80", proxy.seen());
}

test "WebSockets reach their host through a CONNECT tunnel" {
    var proxy = try FakeProxy.init(.http);
    defer proxy.server.deinit();
    const thread = try std.Thread.spawn(.{}, FakeProxy.serve, .{&proxy});
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    var text: [64]u8 = undefined;
    const choice: proxy_api.Choice = .{ .proxy = proxy_api.Proxy.parse(try std.fmt.bufPrint(&text, "http://127.0.0.1:{d}", .{proxy.port()})).? };
    // The fake answers the upgrade with a plain response, which fails the
    // handshake after the tunnel was made.
    try std.testing.expectError(error.HandshakeRejected, websocket.Socket.connect(std.testing.allocator, &client, "ws://chat.test:9000/socket", .{ .proxy = choice }, null));
    try std.testing.expectEqualStrings("chat.test:9000", proxy.seen());
}

test "direct choices ignore a client's own proxy" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator };
    defer client.deinit();
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const Peer = struct {
        fn serve(listener: *std.net.Server) void {
            const connection = listener.accept() catch return;
            defer connection.stream.close();
            FakeProxy.answer(connection.stream, "direct") catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Peer.serve, .{&server});
    defer thread.join();
    var unreachable_proxy: std.http.Client.Proxy = .{ .protocol = .plain, .host = "127.0.0.1", .port = 9, .authorization = null, .supports_connect = true };
    client.http_proxy = &unreachable_proxy;
    var url: [64]u8 = undefined;
    var response = try fetch_api.fetch(std.testing.allocator, &client, .{ .url = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/", .{server.listen_address.getPort()}), .proxy = .direct }, .{}, null);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("direct", response.body);
}
