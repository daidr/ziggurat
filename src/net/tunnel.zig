//! Connections through a proxy for `std.http.Client`: a tunnel through an
//! HTTP proxy (CONNECT) or a SOCKS5 proxy, with TLS on top for `https` and
//! `wss`, and plain `http` requests forwarded by an HTTP proxy with absolute
//! URLs. The connections belong to the client's pool like its own, and are
//! closed after their request instead of being reused.
const std = @import("std");
const builtin = @import("builtin");
const proxy_api = @import("proxy.zig");
const Cancel = @import("cancel.zig").Cancel;

const Client = std.http.Client;
const Connection = Client.Connection;
const Proxy = proxy_api.Proxy;
const Choice = proxy_api.Choice;

pub const ConnectError = Client.ConnectTcpError || error{
    /// The proxy refused the connection or answered outside its protocol.
    ProxyFailed,
    /// The proxy asks for credentials the setting does not hold, or refused them.
    ProxyAuthenticationRequired,
    CertificateBundleLoadFailure,
    Cancelled,
};

pub const RequestError = Client.RequestError || error{ ProxyFailed, ProxyAuthenticationRequired, Cancelled };

/// Opens a connection to `host:port` the way `choice` decides, for a
/// WebSocket or another protocol that needs the connection to reach the
/// host itself: through a proxy, as a tunnel. A client whose own
/// `http_proxy`/`https_proxy` is set keeps its setting for `.system`.
/// `cancel`, when given, is attached while the proxy handshake runs and
/// detached before returning.
pub fn connect(client: *Client, choice: *const Choice, uri: std.Uri, host: []const u8, port: u16, protocol: Client.Protocol, cancel: ?*Cancel) ConnectError!*Connection {
    if (choice.* == .system and ownProxies(client)) return client.connect(host, port, protocol) catch |err| return mapStd(err);
    const proxy = choice.resolve(uri) orelse return client.connectTcp(host, port, protocol);
    return tunnel(client, &proxy, host, port, protocol, cancel);
}

fn ownProxies(client: *const Client) bool {
    return client.http_proxy != null or client.https_proxy != null;
}

fn mapStd(err: Client.ConnectError) ConnectError {
    return switch (err) {
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => error.UnexpectedConnectFailure,
        else => |other| other,
    };
}

/// A request through `choice`'s proxy. Holds the headers a forwarding proxy
/// needs for as long as the request lives; deinit after the request.
pub const Route = struct {
    allocator: ?std.mem.Allocator = null,
    headers: []std.http.Header = &.{},
    authorization: [basic_authorization_max]u8 = undefined,

    pub fn deinit(self: *Route) void {
        if (self.allocator) |allocator| allocator.free(self.headers);
        self.* = .{};
    }

    /// `client.request`, through the proxy `choice` decides for `uri`. A
    /// client whose own `http_proxy`/`https_proxy` is set keeps its setting
    /// for `.system`.
    pub fn request(self: *Route, allocator: std.mem.Allocator, client: *Client, choice: *const Choice, method: std.http.Method, uri: std.Uri, options: Client.RequestOptions, cancel: ?*Cancel) RequestError!Client.Request {
        std.debug.assert(options.connection == null);
        if (choice.* == .system and ownProxies(client)) return client.request(method, uri, options);
        const protocol = Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
        var host_buffer: [std.Uri.host_name_max]u8 = undefined;
        const host = try uri.getHost(&host_buffer);
        const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
        const proxy = choice.resolve(uri) orelse {
            var direct = options;
            direct.connection = try client.connectTcp(host, port, protocol);
            return client.request(method, uri, direct);
        };
        var routed = options;
        if (proxy.kind == .http and protocol == .plain) {
            routed.connection = forward(client, &proxy, host, port, cancel) catch |err| return mapConnect(err);
            if (proxy.credentials()) |credentials| {
                const headers = allocator.alloc(std.http.Header, options.extra_headers.len + 1) catch {
                    client.connection_pool.release(routed.connection.?);
                    return error.OutOfMemory;
                };
                @memcpy(headers[0..options.extra_headers.len], options.extra_headers);
                const value = basicAuthorization(&self.authorization, credentials.user, credentials.password);
                headers[options.extra_headers.len] = .{ .name = "Proxy-Authorization", .value = value };
                self.allocator = allocator;
                self.headers = headers;
                routed.extra_headers = headers;
            }
        } else {
            routed.connection = tunnel(client, &proxy, host, port, protocol, cancel) catch |err| return mapConnect(err);
        }
        return client.request(method, uri, routed) catch |err| {
            client.connection_pool.release(routed.connection.?);
            return err;
        };
    }
};

fn mapConnect(err: ConnectError) RequestError {
    return switch (err) {
        else => |other| other,
    };
}

const basic_authorization_max = "Basic ".len + std.base64.standard.Encoder.calcSize(255 + 1 + 255);

fn basicAuthorization(buffer: *[basic_authorization_max]u8, user: []const u8, password: []const u8) []const u8 {
    var plain: [255 + 1 + 255]u8 = undefined;
    const joined = std.fmt.bufPrint(&plain, "{s}:{s}", .{ user, password }) catch unreachable;
    @memcpy(buffer[0.."Basic ".len], "Basic ");
    const encoded = std.base64.standard.Encoder.encode(buffer["Basic ".len..], joined);
    return buffer[0 .. "Basic ".len + encoded.len];
}

/// A connection to an HTTP proxy that forwards plain `http` requests to
/// `host:port`, which the request writes with absolute URLs.
pub fn forward(client: *Client, proxy: *const Proxy, host: []const u8, port: u16, cancel: ?*Cancel) ConnectError!*Connection {
    std.debug.assert(proxy.kind == .http);
    if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
    const stream = try dial(client, proxy.host(), proxy.port);
    const connection = adoptPlain(client, stream, host, port) catch |err| {
        stream.close();
        return err;
    };
    connection.proxied = true;
    return connection;
}

/// A connection to `host:port` through a tunnel of `proxy`, with TLS on top
/// for `.tls`.
pub fn tunnel(client: *Client, proxy: *const Proxy, host: []const u8, port: u16, protocol: Client.Protocol, cancel: ?*Cancel) ConnectError!*Connection {
    if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
    if (protocol == .tls) try loadCertificates(client);
    const stream = try dial(client, proxy.host(), proxy.port);
    var owned = true;
    defer if (owned) stream.close();
    {
        if (cancel) |token| try token.attach(stream.handle);
        defer if (cancel) |token| token.detach();
        const handshake = switch (proxy.kind) {
            .http => connectHandshake(stream.handle, proxy, host, port),
            .socks5 => socksHandshake(stream.handle, proxy, host, port),
        };
        handshake catch |err| {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            return err;
        };
    }
    const connection = switch (protocol) {
        .plain => try adoptPlain(client, stream, host, port),
        .tls => try adoptTls(client, stream, host, port),
    };
    owned = false;
    return connection;
}

fn dial(client: *Client, host: []const u8, port: u16) ConnectError!std.net.Stream {
    return std.net.tcpConnectToHost(client.allocator, host, port) catch |err| switch (err) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.NetworkUnreachable => error.NetworkUnreachable,
        error.ConnectionTimedOut => error.ConnectionTimedOut,
        error.ConnectionResetByPeer => error.ConnectionResetByPeer,
        error.TemporaryNameServerFailure => error.TemporaryNameServerFailure,
        error.NameServerFailure => error.NameServerFailure,
        error.UnknownHostName => error.UnknownHostName,
        error.HostLacksNetworkAddresses => error.HostLacksNetworkAddresses,
        error.OutOfMemory => error.OutOfMemory,
        else => error.UnexpectedConnectFailure,
    };
}

/// As `std.http.Client.request` does before its first HTTPS request.
pub fn loadCertificates(client: *Client) error{CertificateBundleLoadFailure}!void {
    if (Client.disable_tls) return;
    if (!@atomicLoad(bool, &client.next_https_rescan_certs, .acquire)) return;
    client.ca_bundle_mutex.lock();
    defer client.ca_bundle_mutex.unlock();
    if (client.next_https_rescan_certs) {
        client.ca_bundle.rescan(client.allocator) catch return error.CertificateBundleLoadFailure;
        @atomicStore(bool, &client.next_https_rescan_certs, false, .release);
    }
}

// Proxy handshakes, on the raw socket.

fn sendAll(socket: std.posix.socket_t, bytes: []const u8) error{ProxyFailed}!void {
    var sent: usize = 0;
    while (sent < bytes.len) sent += try sendSome(socket, bytes[sent..]);
}

fn receiveExact(socket: std.posix.socket_t, out: []u8) error{ProxyFailed}!void {
    var received: usize = 0;
    while (received < out.len) {
        const count = try receiveSome(socket, out[received..]);
        if (count == 0) return error.ProxyFailed;
        received += count;
    }
}

fn sendSome(socket: std.posix.socket_t, bytes: []const u8) error{ProxyFailed}!usize {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        const count = ws2_32.send(socket, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(i32))), 0);
        return if (count == ws2_32.SOCKET_ERROR) error.ProxyFailed else @intCast(count);
    }
    return std.posix.send(socket, bytes, 0) catch error.ProxyFailed;
}

fn receiveSome(socket: std.posix.socket_t, out: []u8) error{ProxyFailed}!usize {
    if (builtin.os.tag == .windows) {
        const ws2_32 = std.os.windows.ws2_32;
        const count = ws2_32.recv(socket, out.ptr, @intCast(@min(out.len, std.math.maxInt(i32))), 0);
        return if (count == ws2_32.SOCKET_ERROR) error.ProxyFailed else @intCast(count);
    }
    return std.posix.recv(socket, out, 0) catch error.ProxyFailed;
}

/// `host:port` as a request target, with an IPv6 address in brackets.
fn authority(buffer: []u8, host: []const u8, port: u16) error{ProxyFailed}![]const u8 {
    const bracket = std.mem.indexOfScalar(u8, host, ':') != null;
    return std.fmt.bufPrint(buffer, "{s}{s}{s}:{d}", .{ if (bracket) "[" else "", host, if (bracket) "]" else "", port }) catch error.ProxyFailed;
}

fn connectHandshake(socket: std.posix.socket_t, proxy: *const Proxy, host: []const u8, port: u16) ConnectError!void {
    var target_buffer: [std.Uri.host_name_max + 8]u8 = undefined;
    const target = try authority(&target_buffer, host, port);
    var request_buffer: [1536]u8 = undefined;
    var authorization_buffer: [basic_authorization_max]u8 = undefined;
    const credentials = proxy.credentials();
    const request = std.fmt.bufPrint(&request_buffer, "CONNECT {s} HTTP/1.1\r\nHost: {s}\r\n{s}{s}{s}\r\n", .{
        target,
        target,
        if (credentials != null) "Proxy-Authorization: " else "",
        if (credentials) |value| basicAuthorization(&authorization_buffer, value.user, value.password) else "",
        if (credentials != null) "\r\n" else "",
    }) catch return error.ProxyFailed;
    try sendAll(socket, request);
    // The proxy sends nothing of the tunnel before the head ends; read it a
    // byte at a time so that nothing after it is taken.
    var head: [8192]u8 = undefined;
    var length: usize = 0;
    while (!std.mem.endsWith(u8, head[0..length], "\r\n\r\n")) {
        if (length == head.len) return error.ProxyFailed;
        try receiveExact(socket, head[length..][0..1]);
        length += 1;
    }
    const line_end = std.mem.indexOf(u8, head[0..length], "\r\n").?;
    const line = head[0..line_end];
    if (line.len < 12 or !std.mem.startsWith(u8, line, "HTTP/1.") or line[8] != ' ') return error.ProxyFailed;
    const status = std.fmt.parseInt(u16, line[9..12], 10) catch return error.ProxyFailed;
    if (status == 407) return error.ProxyAuthenticationRequired;
    if (status / 100 != 2) return error.ProxyFailed;
}

fn socksHandshake(socket: std.posix.socket_t, proxy: *const Proxy, host: []const u8, port: u16) ConnectError!void {
    const credentials = proxy.credentials();
    // Greeting: no authentication, and user and password when the setting has them.
    if (credentials != null) try sendAll(socket, &.{ 5, 2, 0, 2 }) else try sendAll(socket, &.{ 5, 1, 0 });
    var choice: [2]u8 = undefined;
    try receiveExact(socket, &choice);
    if (choice[0] != 5) return error.ProxyFailed;
    switch (choice[1]) {
        0 => {},
        2 => {
            const value = credentials orelse return error.ProxyAuthenticationRequired;
            var message: [3 + 255 + 255]u8 = undefined;
            message[0] = 1;
            message[1] = @intCast(value.user.len);
            @memcpy(message[2..][0..value.user.len], value.user);
            message[2 + value.user.len] = @intCast(value.password.len);
            @memcpy(message[3 + value.user.len ..][0..value.password.len], value.password);
            try sendAll(socket, message[0 .. 3 + value.user.len + value.password.len]);
            var status: [2]u8 = undefined;
            try receiveExact(socket, &status);
            if (status[1] != 0) return error.ProxyAuthenticationRequired;
        },
        0xff => return if (credentials == null) error.ProxyAuthenticationRequired else error.ProxyFailed,
        else => return error.ProxyFailed,
    }
    // CONNECT to an address, or to a name the proxy resolves.
    var request: [4 + 1 + 255 + 2]u8 = undefined;
    request[0..4].* = .{ 5, 1, 0, 0 };
    var length: usize = 4;
    if (std.net.Ip4Address.parse(host, 0)) |address| {
        request[3] = 1;
        @memcpy(request[4..8], std.mem.asBytes(&address.sa.addr));
        length = 8;
    } else |_| if (std.net.Ip6Address.parse(host, 0)) |address| {
        request[3] = 4;
        @memcpy(request[4..20], &address.sa.addr);
        length = 20;
    } else |_| {
        if (host.len > 255) return error.ProxyFailed;
        request[3] = 3;
        request[4] = @intCast(host.len);
        @memcpy(request[5..][0..host.len], host);
        length = 5 + host.len;
    }
    std.mem.writeInt(u16, request[length..][0..2], port, .big);
    try sendAll(socket, request[0 .. length + 2]);
    var reply: [4]u8 = undefined;
    try receiveExact(socket, &reply);
    if (reply[0] != 5 or reply[1] != 0) return error.ProxyFailed;
    // The bound address and port, which the tunnel does not need.
    var skip: [255 + 2]u8 = undefined;
    switch (reply[3]) {
        1 => try receiveExact(socket, skip[0 .. 4 + 2]),
        4 => try receiveExact(socket, skip[0 .. 16 + 2]),
        3 => {
            try receiveExact(socket, skip[0..1]);
            try receiveExact(socket, skip[0 .. @as(usize, skip[0]) + 2]);
        },
        else => return error.ProxyFailed,
    }
}

// Connections of the client over a stream this module opened. They are laid
// out as the client lays out its own, which it frees by the same rules.

const PlainConnection = struct {
    connection: Connection,
};

const TlsConnection = struct {
    client: std.crypto.tls.Client,
    connection: Connection,
};

fn adoptPlain(client: *Client, stream: std.net.Stream, host: []const u8, port: u16) ConnectError!*Connection {
    if (host.len > std.math.maxInt(u8)) return error.UnexpectedConnectFailure;
    const gpa = client.allocator;
    const alloc_len = @sizeOf(PlainConnection) + host.len + client.read_buffer_size + client.write_buffer_size;
    const base = try gpa.alignedAlloc(u8, .of(PlainConnection), alloc_len);
    const host_buffer = base[@sizeOf(PlainConnection)..][0..host.len];
    const socket_read_buffer = host_buffer.ptr[host_buffer.len..][0..client.read_buffer_size];
    const socket_write_buffer = socket_read_buffer.ptr[socket_read_buffer.len..][0..client.write_buffer_size];
    @memcpy(host_buffer, host);
    const plain: *PlainConnection = @ptrCast(base);
    plain.* = .{ .connection = .{
        .client = client,
        .stream_writer = stream.writer(socket_write_buffer),
        .stream_reader = stream.reader(socket_read_buffer),
        .pool_node = .{},
        .port = port,
        .host_len = @intCast(host.len),
        .proxied = false,
        .closing = true,
        .protocol = .plain,
    } };
    client.connection_pool.addUsed(&plain.connection);
    return &plain.connection;
}

fn adoptTls(client: *Client, stream: std.net.Stream, host: []const u8, port: u16) ConnectError!*Connection {
    if (Client.disable_tls) return error.TlsInitializationFailed;
    if (host.len > std.math.maxInt(u8)) return error.UnexpectedConnectFailure;
    const gpa = client.allocator;
    const tls_read_buffer_len = client.tls_buffer_size + client.read_buffer_size;
    const alloc_len = @sizeOf(TlsConnection) + host.len + tls_read_buffer_len + client.tls_buffer_size + client.write_buffer_size + client.tls_buffer_size;
    const base = try gpa.alignedAlloc(u8, .of(TlsConnection), alloc_len);
    errdefer gpa.free(base);
    const host_buffer = base[@sizeOf(TlsConnection)..][0..host.len];
    // As the client's own: the TLS reader holds an encrypted frame and a
    // whole HTTP head.
    const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
    const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..client.tls_buffer_size];
    const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..client.write_buffer_size];
    const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..client.tls_buffer_size];
    std.debug.assert(base.ptr + alloc_len == socket_read_buffer.ptr + socket_read_buffer.len);
    @memcpy(host_buffer, host);
    const tls: *TlsConnection = @ptrCast(base);
    tls.connection = .{
        .client = client,
        .stream_writer = stream.writer(tls_write_buffer),
        .stream_reader = stream.reader(socket_read_buffer),
        .pool_node = .{},
        .port = port,
        .host_len = @intCast(host.len),
        .proxied = false,
        .closing = true,
        .protocol = .tls,
    };
    tls.client = std.crypto.tls.Client.init(tls.connection.stream_reader.interface(), &tls.connection.stream_writer.interface, .{
        .host = .{ .explicit = host_buffer },
        .ca = .{ .bundle = client.ca_bundle },
        .ssl_key_log = client.ssl_key_log,
        .read_buffer = tls_read_buffer,
        .write_buffer = socket_write_buffer,
        // HTTP's content length detects truncation, as for the client's own.
        .allow_truncation_attacks = true,
    }) catch return error.TlsInitializationFailed;
    client.connection_pool.addUsed(&tls.connection);
    return &tls.connection;
}

test "adopted TLS connections are laid out as the client reads its own" {
    if (Client.disable_tls) return error.SkipZigTest;
    var tls: TlsConnection = undefined;
    tls.connection.protocol = .tls;
    try std.testing.expectEqual(@intFromPtr(&tls.client.writer), @intFromPtr(tls.connection.writer()));
    try std.testing.expectEqual(@intFromPtr(&tls.client.reader), @intFromPtr(tls.connection.reader()));
    var plain: PlainConnection = undefined;
    try std.testing.expectEqual(@intFromPtr(&plain), @intFromPtr(&plain.connection));
}

test "basic proxy authorization encodes user and password" {
    var buffer: [basic_authorization_max]u8 = undefined;
    try std.testing.expectEqualStrings("Basic dXNlcjpwQHNz", basicAuthorization(&buffer, "user", "p@ss"));
}
