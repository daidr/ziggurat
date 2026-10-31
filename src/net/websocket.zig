const std = @import("std");
const zio = @import("ziggurat_io");
const Cancel = @import("cancel.zig").Cancel;
const Waker = @import("waker.zig").Waker;
const proxy_api = @import("proxy.zig");
const tunnel = @import("tunnel.zig");

pub const Header = std.http.Header;
pub const Kind = enum { text, binary };

/// A complete inbound message. `bytes` is borrowed for the duration of the
/// handler call; copy what must outlive it.
pub const Message = struct { kind: Kind, bytes: []const u8 };

/// `pause` stops reading the socket after this message until
/// `Socket.resumeReading`, so a consumer that cannot accept more (for
/// example `App.post` returned `Full`) holds the peer back through TCP.
pub const Flow = enum { proceed, pause };

/// Runs on the worker inside `Socket.run`.
pub const Handler = struct {
    context: ?*anyopaque = null,
    on_message: *const fn (context: ?*anyopaque, message: Message) Flow,
    /// Called after queued messages were written, so a producer that got
    /// `Full` from `send` knows when to try again.
    on_flushed: ?*const fn (context: ?*anyopaque) void = null,
};

pub const Limits = struct {
    /// Largest reassembled inbound message; larger ones close with 1009.
    message_bytes: usize = 1024 * 1024,
    /// Preallocated outbound queue. Each queued message also takes 5 bytes
    /// of framing metadata; `send` returns `Full` when it cannot fit.
    send_buffer_bytes: usize = 1024 * 1024,
    url_bytes: usize = 8 * 1024,
    /// After this endpoint sent its close frame, how long `run` waits for the
    /// peer's before returning `CloseTimedOut`; 0 waits as long as the
    /// connection lasts.
    close_timeout_ms: u32 = 0,
};

pub const ConnectOptions = struct {
    /// Extra handshake headers, such as `Origin`.
    headers: []const Header = &.{},
    /// Offered subprotocols; the accepted one is `Socket.protocol`.
    protocols: []const []const u8 = &.{},
    limits: Limits = .{},
    /// The system's proxy by default (`proxy.forUrl`), reached through a
    /// tunnel. A client whose own `http_proxy`/`https_proxy` is set keeps it.
    proxy: proxy_api.Choice = .system,
};

pub const close_code = struct {
    pub const normal: u16 = 1000;
    pub const going_away: u16 = 1001;
    pub const protocol_error: u16 = 1002;
    pub const unsupported_data: u16 = 1003;
    pub const no_status: u16 = 1005;
    pub const invalid_data: u16 = 1007;
    pub const policy_violation: u16 = 1008;
    pub const message_too_big: u16 = 1009;
    pub const internal_error: u16 = 1011;
};

/// The completed close handshake. `reason` is borrowed from the socket
/// until `deinit`.
pub const Closed = struct {
    /// `close_code.no_status` when the peer's close frame carried no code.
    code: u16,
    reason: []const u8,
    /// The peer sent the first close frame.
    remote: bool,
};

pub const ConnectError = error{
    Cancelled,
    InvalidUrl,
    UrlTooLong,
    UnsupportedScheme,
    InvalidRequest,
    UnsupportedProxy,
    ConnectionFailed,
    TlsFailed,
    HeadersTooLarge,
    HandshakeRejected,
    OutOfMemory,
    SystemResources,
};

pub const RunError = error{
    Cancelled,
    /// The connection ended without a close handshake.
    ConnectionLost,
    /// The peer broke the protocol; a 1002 close was attempted.
    ProtocolViolation,
    /// A message exceeded `Limits.message_bytes`; a 1009 close was attempted.
    MessageTooLarge,
    /// A text message or close reason was not UTF-8; a 1007 close was attempted.
    InvalidUtf8,
    /// The peer did not answer the close frame within `Limits.close_timeout_ms`.
    CloseTimedOut,
    OutOfMemory,
};

pub const SendError = error{ Closed, Full, MessageTooLarge, InvalidUtf8 };

const accept_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const ring_header = 5;

const Control = struct {
    len: u8 = 0,
    data: [125]u8 = undefined,
    fn slice(self: *const Control) []const u8 {
        return self.data[0..self.len];
    }
};

/// A client WebSocket. `connect` and `run` block on one application-managed
/// worker that owns the connection; `send`, `ping`, `close`, `cancel` and
/// `resumeReading` may be called from any thread, including the UI thread,
/// and never block on the network. The worker serializes both directions, so
/// one TLS session is never read and written concurrently.
pub const Socket = struct {
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    connection: *std.http.Client.Connection,
    limits: Limits,
    /// Accepted subprotocol, or empty.
    protocol: []const u8,
    abort: Cancel = .{},
    waker: Waker,

    mutex: zio.Mutex = .{},
    ring: []u8,
    ring_head: usize = 0,
    ring_len: usize = 0,
    queued_messages: usize = 0,
    send_closed: bool = false,
    pong: ?Control = null,
    ping_request: ?Control = null,
    close_request: ?struct { code: u16, reason: Control } = null,

    resume_epoch: std.atomic.Value(u64) = .init(0),

    // Worker-owned state.
    running: bool = false,
    paused: bool = false,
    paused_epoch: u64 = 0,
    close_sent: bool = false,
    close_deadline: ?i64 = null,
    message: std.ArrayListUnmanaged(u8) = .empty,
    fragment: ?Kind = null,
    closed_reason: Control = .{},
    scratch: [4096]u8 = undefined,

    /// Open `url` (`ws` or `wss`) and complete the opening handshake.
    /// Blocking: run on the worker that will call `run`. `cancel`
    /// interrupts every step, from name resolution to the handshake.
    pub fn connect(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, options: ConnectOptions, handshake_cancel: ?*Cancel) ConnectError!*Socket {
        for (options.protocols) |protocol| if (!validToken(protocol)) return error.InvalidRequest;
        for (options.headers) |item| if (!validToken(item.name) or std.mem.indexOfAny(u8, item.value, "\r\n") != null) return error.InvalidRequest;
        if (options.limits.send_buffer_bytes <= ring_header) return error.InvalidRequest;
        if (url.len > options.limits.url_bytes) return error.UrlTooLong;
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const tls = if (std.ascii.eqlIgnoreCase(uri.scheme, "wss")) true else if (std.ascii.eqlIgnoreCase(uri.scheme, "ws")) false else return error.UnsupportedScheme;
        if (uri.fragment != null) return error.InvalidUrl;
        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buffer) catch return error.InvalidUrl;
        const port = uri.port orelse @as(u16, if (tls) 443 else 80);
        const target: Target = .{ .uri = uri, .host = host, .port = port, .tls = tls };
        const token = handshake_cancel orelse return open(allocator, client, target, options, null);
        if (token.isCancelled()) return error.Cancelled;
        return token.run(open, .{ allocator, client, target, options, token });
    }

    const Target = struct { uri: std.Uri, host: std.Io.net.HostName, port: u16, tls: bool };

    fn open(allocator: std.mem.Allocator, client: *std.http.Client, target: Target, options: ConnectOptions, handshake_cancel: ?*Cancel) ConnectError!*Socket {
        const failed = struct {
            fn map(token: ?*Cancel, err: ConnectError) ConnectError {
                if (token) |value| if (value.isCancelled()) return error.Cancelled;
                return err;
            }
        }.map;
        if (target.tls) tunnel.loadCertificates(client) catch return failed(handshake_cancel, error.TlsFailed);
        const ring = try allocator.alloc(u8, options.limits.send_buffer_bytes);
        errdefer allocator.free(ring);
        var waker = Waker.init() catch return error.SystemResources;
        errdefer waker.deinit();
        const connection = tunnel.connect(client, &options.proxy, target.uri, target.host, target.port, if (target.tls) .tls else .plain, handshake_cancel) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => error.Cancelled,
            error.TlsInitializationFailed => failed(handshake_cancel, error.TlsFailed),
            else => failed(handshake_cancel, error.ConnectionFailed),
        };
        connection.closing = true;
        errdefer client.connection_pool.release(connection, client.io);
        if (connection.proxied) return error.UnsupportedProxy;

        var key_bytes: [16]u8 = undefined;
        zio.random.bytes(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);
        writeHandshake(connection, target.uri, target.host.bytes, target.port, target.tls, &key, options) catch return failed(handshake_cancel, error.ConnectionFailed);
        const protocol = try readHandshake(allocator, connection, &key, options.protocols, handshake_cancel);
        errdefer allocator.free(protocol);

        const self = try allocator.create(Socket);
        self.* = .{ .allocator = allocator, .client = client, .connection = connection, .limits = options.limits, .protocol = protocol, .waker = waker, .ring = ring };
        self.abort.attach(connection.stream_reader.stream.socket.handle) catch unreachable;
        return self;
    }

    /// Worker, after `run` returned or instead of it. Other threads must have
    /// stopped using the socket.
    pub fn deinit(self: *Socket) void {
        self.abort.detach();
        self.client.connection_pool.release(self.connection, self.client.io);
        self.waker.deinit();
        self.message.deinit(self.allocator);
        self.allocator.free(self.ring);
        self.allocator.free(self.protocol);
        self.allocator.destroy(self);
    }

    /// Queue a message without blocking. The bytes are copied. Returns
    /// `Full` while the queue lacks space and `Closed` after `close`,
    /// `cancel` or the end of the connection.
    pub fn send(self: *Socket, kind: Kind, bytes: []const u8) SendError!void {
        if (kind == .text and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const need = ring_header + bytes.len;
        if (need > self.ring.len or bytes.len > std.math.maxInt(u32)) return error.MessageTooLarge;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.send_closed) return error.Closed;
            if (self.ring.len - self.ring_len < need) return error.Full;
            var header: [ring_header]u8 = undefined;
            header[0] = @backingInt(kind);
            std.mem.writeInt(u32, header[1..5], @intCast(bytes.len), .little);
            const tail = (self.ring_head + self.ring_len) % self.ring.len;
            self.copyIn(tail, &header);
            self.copyIn((tail + ring_header) % self.ring.len, bytes);
            self.ring_len += need;
            self.queued_messages += 1;
        }
        self.waker.wake();
    }

    /// Bytes currently free in the outbound queue.
    pub fn sendCapacity(self: *Socket) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.ring.len - self.ring_len;
    }

    /// Queue a ping. Payloads above 125 bytes are rejected. Keepalive timing
    /// belongs to the application; the socket sends no pings by itself.
    pub fn ping(self: *Socket, payload: []const u8) SendError!void {
        if (payload.len > 125) return error.MessageTooLarge;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.send_closed) return error.Closed;
            var control: Control = .{ .len = @intCast(payload.len) };
            @memcpy(control.data[0..payload.len], payload);
            self.ping_request = control;
        }
        self.waker.wake();
    }

    /// Start the closing handshake after already queued messages. `code` is
    /// 1000, 1001 (going away) or 3000-4999 and `reason` is at most 123 UTF-8
    /// bytes. Later
    /// `send` calls return `Closed`; `run` returns once the peer answers.
    pub fn close(self: *Socket, code: u16, reason: []const u8) error{ Closed, InvalidClose }!void {
        if (!(code == close_code.normal or code == close_code.going_away or (code >= 3000 and code <= 4999))) return error.InvalidClose;
        if (reason.len > 123 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidClose;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.send_closed) return error.Closed;
            self.send_closed = true;
            var control: Control = .{ .len = @intCast(reason.len) };
            @memcpy(control.data[0..reason.len], reason);
            self.close_request = .{ .code = code, .reason = control };
        }
        self.waker.wake();
    }

    /// Abort without a closing handshake. `run` returns `Cancelled`.
    pub fn cancel(self: *Socket) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.send_closed = true;
        }
        self.abort.cancel();
        self.waker.wake();
    }

    /// Continue reading after a handler returned `pause`. A call made while
    /// that handler was still running also counts.
    pub fn resumeReading(self: *Socket) void {
        _ = self.resume_epoch.fetchAdd(1, .acq_rel);
        self.waker.wake();
    }

    /// Deliver inbound messages to `handler` and write queued output until the
    /// close handshake completes or the connection fails. Call once, on the
    /// worker that called `connect`.
    pub fn run(self: *Socket, handler: Handler) RunError!Closed {
        std.debug.assert(!self.running);
        self.running = true;
        defer {
            self.mutex.lock();
            self.send_closed = true;
            self.mutex.unlock();
        }
        while (true) {
            if (try self.flushOutgoing()) if (handler.on_flushed) |flushed| flushed(handler.context);
            if (self.paused and self.resume_epoch.load(.acquire) != self.paused_epoch) self.paused = false;
            const reader = self.connection.reader();
            const buffered = reader.bufferedLen() > 0 or self.connection.stream_reader.interface.bufferedLen() > 0;
            if (self.paused or !buffered) {
                var fds = [_]zio.net.PollFd{
                    .{ .handle = self.waker.handle() },
                    .{ .handle = self.connection.stream_reader.stream.socket.handle },
                };
                const count: usize = if (self.paused) 1 else 2;
                var timeout: ?u32 = null;
                if (self.close_deadline) |deadline| {
                    const left = deadline - zio.milliTimestamp();
                    if (left <= 0) return error.CloseTimedOut;
                    timeout = @intCast(zio.asUnsigned(@min(left, std.math.maxInt(i32))));
                }
                const ready = zio.net.pollReadable(fds[0..count], timeout) catch return self.lost();
                if (ready == 0 and self.close_deadline != null) return error.CloseTimedOut;
                if (fds[0].ready) self.waker.drain();
                if (self.abort.isCancelled()) return error.Cancelled;
                if (count == 1 or !fds[1].ready) continue;
            }
            if (try self.readFrame(handler)) |closed| return closed;
        }
    }

    fn lost(self: *Socket) RunError {
        return if (self.abort.isCancelled()) error.Cancelled else error.ConnectionLost;
    }

    fn copyIn(self: *Socket, offset: usize, bytes: []const u8) void {
        const first = @min(bytes.len, self.ring.len - offset);
        @memcpy(self.ring[offset..][0..first], bytes[0..first]);
        @memcpy(self.ring[0 .. bytes.len - first], bytes[first..]);
    }

    fn copyOut(self: *Socket, offset: usize, out: []u8) void {
        const first = @min(out.len, self.ring.len - offset);
        @memcpy(out[0..first], self.ring[offset..][0..first]);
        @memcpy(out[first..], self.ring[0 .. out.len - first]);
    }

    /// Returns whether queued messages were written.
    fn flushOutgoing(self: *Socket) RunError!bool {
        var wrote = false;
        var messages = false;
        while (true) {
            self.mutex.lock();
            if (self.pong) |control| {
                self.pong = null;
                self.mutex.unlock();
                try self.writeFrame(0xA, control.slice());
            } else if (self.ping_request) |control| {
                self.ping_request = null;
                self.mutex.unlock();
                if (!self.close_sent) try self.writeFrame(0x9, control.slice());
            } else if (!self.close_sent and self.ring_len > 0) {
                var header: [ring_header]u8 = undefined;
                self.copyOut(self.ring_head, &header);
                const head = self.ring_head;
                self.mutex.unlock();
                // Producers only append after the occupied region, so the
                // message bytes stay put while the worker writes them.
                const len = std.mem.readInt(u32, header[1..5], .little);
                try self.writeQueued(@fromBackingInt(@intCast(header[0])), (head + ring_header) % self.ring.len, len);
                self.mutex.lock();
                self.ring_head = (head + ring_header + len) % self.ring.len;
                self.ring_len -= ring_header + len;
                self.queued_messages -= 1;
                self.mutex.unlock();
                messages = true;
            } else if (!self.close_sent and self.close_request != null) {
                const request = self.close_request.?;
                self.mutex.unlock();
                try self.writeClose(request.code, request.reason.slice());
            } else {
                self.mutex.unlock();
                break;
            }
            wrote = true;
        }
        if (wrote) self.connection.flush() catch return self.lost();
        return messages;
    }

    fn writeClose(self: *Socket, code: u16, reason: []const u8) RunError!void {
        var payload: [125]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        @memcpy(payload[2..][0..reason.len], reason);
        self.close_sent = true;
        if (self.limits.close_timeout_ms > 0) self.close_deadline = zio.milliTimestamp() + self.limits.close_timeout_ms;
        try self.writeFrame(0x8, payload[0 .. 2 + reason.len]);
    }

    fn writeHeader(self: *Socket, opcode: u4, len: usize) RunError![4]u8 {
        const writer = self.connection.writer();
        var header: [14]u8 = undefined;
        header[0] = 0x80 | @as(u8, opcode);
        var size: usize = 2;
        if (len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(len));
        } else if (len <= 0xFFFF) {
            header[1] = 0x80 | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(len), .big);
            size = 4;
        } else {
            header[1] = 0x80 | 127;
            std.mem.writeInt(u64, header[2..10], len, .big);
            size = 10;
        }
        var mask: [4]u8 = undefined;
        zio.random.bytes(&mask);
        @memcpy(header[size..][0..4], &mask);
        writer.writeAll(header[0 .. size + 4]) catch return self.lost();
        return mask;
    }

    fn writeMasked(self: *Socket, mask: [4]u8, bytes: []const u8, offset: *usize) RunError!void {
        const writer = self.connection.writer();
        var index: usize = 0;
        while (index < bytes.len) {
            const part = @min(self.scratch.len, bytes.len - index);
            for (self.scratch[0..part], bytes[index..][0..part], 0..) |*out, byte, i| out.* = byte ^ mask[(offset.* + i) % 4];
            writer.writeAll(self.scratch[0..part]) catch return self.lost();
            offset.* += part;
            index += part;
        }
    }

    fn writeFrame(self: *Socket, opcode: u4, payload: []const u8) RunError!void {
        const mask = try self.writeHeader(opcode, payload.len);
        var offset: usize = 0;
        try self.writeMasked(mask, payload, &offset);
    }

    fn writeQueued(self: *Socket, kind: Kind, start: usize, len: usize) RunError!void {
        const mask = try self.writeHeader(if (kind == .text) 0x1 else 0x2, len);
        var offset: usize = 0;
        const first = @min(len, self.ring.len - start);
        try self.writeMasked(mask, self.ring[start..][0..first], &offset);
        try self.writeMasked(mask, self.ring[0 .. len - first], &offset);
    }

    /// Best-effort close after a protocol failure; the run ends with `err`.
    fn fail(self: *Socket, code: u16, err: RunError) RunError {
        if (!self.close_sent) {
            self.writeClose(code, "") catch return err;
            self.connection.flush() catch {};
        }
        return err;
    }

    fn readExact(self: *Socket, out: []u8) RunError!void {
        self.connection.reader().readSliceAll(out) catch return self.lost();
    }

    fn readFrame(self: *Socket, handler: Handler) RunError!?Closed {
        var header: [2]u8 = undefined;
        try self.readExact(&header);
        const fin = header[0] & 0x80 != 0;
        const opcode: u4 = @truncate(header[0]);
        if (header[0] & 0x70 != 0) return self.fail(close_code.protocol_error, error.ProtocolViolation);
        if (header[1] & 0x80 != 0) return self.fail(close_code.protocol_error, error.ProtocolViolation);
        var len: u64 = header[1] & 0x7F;
        if (len == 126) {
            var extended: [2]u8 = undefined;
            try self.readExact(&extended);
            len = std.mem.readInt(u16, &extended, .big);
            if (len < 126) return self.fail(close_code.protocol_error, error.ProtocolViolation);
        } else if (len == 127) {
            var extended: [8]u8 = undefined;
            try self.readExact(&extended);
            len = std.mem.readInt(u64, &extended, .big);
            if (len >> 63 != 0 or len <= 0xFFFF) return self.fail(close_code.protocol_error, error.ProtocolViolation);
        }
        if (opcode >= 0x8) {
            if (!fin or len > 125) return self.fail(close_code.protocol_error, error.ProtocolViolation);
            var control: Control = .{ .len = @intCast(len) };
            try self.readExact(control.data[0..control.len]);
            switch (opcode) {
                0x8 => return try self.receivedClose(control.slice()),
                0x9 => {
                    self.mutex.lock();
                    self.pong = control;
                    self.mutex.unlock();
                },
                0xA => {},
                else => return self.fail(close_code.protocol_error, error.ProtocolViolation),
            }
            return null;
        }
        const kind: Kind = switch (opcode) {
            0x0 => self.fragment orelse return self.fail(close_code.protocol_error, error.ProtocolViolation),
            0x1, 0x2 => kind: {
                if (self.fragment != null) return self.fail(close_code.protocol_error, error.ProtocolViolation);
                self.message.clearRetainingCapacity();
                break :kind if (opcode == 0x1) .text else .binary;
            },
            else => return self.fail(close_code.protocol_error, error.ProtocolViolation),
        };
        if (len > self.limits.message_bytes - self.message.items.len) return self.fail(close_code.message_too_big, error.MessageTooLarge);
        const start = self.message.items.len;
        self.message.ensureTotalCapacity(self.allocator, start + @as(usize, @intCast(len))) catch return self.fail(close_code.internal_error, error.OutOfMemory);
        self.message.items.len = start + @as(usize, @intCast(len));
        try self.readExact(self.message.items[start..]);
        if (!fin) {
            self.fragment = kind;
            return null;
        }
        self.fragment = null;
        if (kind == .text and !std.unicode.utf8ValidateSlice(self.message.items)) return self.fail(close_code.invalid_data, error.InvalidUtf8);
        const epoch = self.resume_epoch.load(.acquire);
        if (handler.on_message(handler.context, .{ .kind = kind, .bytes = self.message.items }) == .pause) {
            self.paused = true;
            self.paused_epoch = epoch;
        }
        return null;
    }

    fn receivedClose(self: *Socket, payload: []const u8) RunError!?Closed {
        if (payload.len == 1) return self.fail(close_code.protocol_error, error.ProtocolViolation);
        var code: u16 = close_code.no_status;
        if (payload.len >= 2) {
            code = std.mem.readInt(u16, payload[0..2], .big);
            if (!validReceivedCode(code)) return self.fail(close_code.protocol_error, error.ProtocolViolation);
            if (!std.unicode.utf8ValidateSlice(payload[2..])) return self.fail(close_code.invalid_data, error.InvalidUtf8);
        }
        const reason = if (payload.len >= 2) payload[2..] else payload[0..0];
        self.closed_reason = .{ .len = @intCast(reason.len) };
        @memcpy(self.closed_reason.data[0..reason.len], reason);
        const remote = !self.close_sent;
        if (remote) {
            self.mutex.lock();
            self.send_closed = true;
            self.mutex.unlock();
            try self.writeClose(if (code == close_code.no_status) close_code.normal else code, "");
            self.connection.flush() catch return self.lost();
        }
        return .{ .code = code, .reason = self.closed_reason.slice(), .remote = remote };
    }
};

fn validReceivedCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1011, 3000...4999 => true,
        else => false,
    };
}

fn validToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'...'9', 'a'...'z', 'A'...'Z' => {},
        else => return false,
    };
    return true;
}

fn writeHandshake(connection: *std.http.Client.Connection, uri: std.Uri, host: []const u8, port: u16, tls: bool, key: *const [24]u8, options: ConnectOptions) std.Io.Writer.Error!void {
    const w = connection.writer();
    try w.writeAll("GET ");
    if (uri.path.isEmpty()) try w.writeByte('/') else try uri.path.formatPath(w);
    if (uri.query) |query| {
        try w.writeByte('?');
        try query.formatQuery(w);
    }
    try w.writeAll(" HTTP/1.1\r\nhost: ");
    const bracket = std.mem.indexOfScalar(u8, host, ':') != null;
    if (bracket) try w.writeByte('[');
    try w.writeAll(host);
    if (bracket) try w.writeByte(']');
    if (port != @as(u16, if (tls) 443 else 80)) try w.print(":{d}", .{port});
    try w.print("\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-version: 13\r\nsec-websocket-key: {s}\r\n", .{key});
    if (options.protocols.len > 0) {
        try w.writeAll("sec-websocket-protocol: ");
        for (options.protocols, 0..) |protocol, index| {
            if (index > 0) try w.writeAll(", ");
            try w.writeAll(protocol);
        }
        try w.writeAll("\r\n");
    }
    for (options.headers) |item| try w.print("{s}: {s}\r\n", .{ item.name, item.value });
    try w.writeAll("\r\n");
    try connection.flush();
}

fn readHandshake(allocator: std.mem.Allocator, connection: *std.http.Client.Connection, key: *const [24]u8, offered: []const []const u8, cancel: ?*Cancel) ConnectError![]u8 {
    const reader = connection.reader();
    var parser: std.http.HeadParser = .{};
    var head_len: usize = 0;
    while (parser.state != .finished) {
        if (head_len + 1 > reader.buffer.len) return error.HeadersTooLarge;
        const available = reader.peekGreedy(head_len + 1) catch {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            return error.ConnectionFailed;
        };
        head_len += parser.feed(available[head_len..]);
    }
    const head = reader.take(head_len) catch unreachable;
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.HandshakeRejected;
    var expected: [28]u8 = undefined;
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(accept_guid);
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(&expected, &digest);
    var upgrade = false;
    var connection_upgrade = false;
    var accepted = false;
    var protocol: ?[]const u8 = null;
    var headers = std.http.HeaderIterator.init(head);
    while (headers.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item.name, "upgrade")) {
            upgrade = std.ascii.eqlIgnoreCase(std.mem.trim(u8, item.value, " \t"), "websocket");
        } else if (std.ascii.eqlIgnoreCase(item.name, "connection")) {
            var tokens = std.mem.tokenizeAny(u8, item.value, ", \t");
            while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(token, "upgrade")) {
                connection_upgrade = true;
            };
        } else if (std.ascii.eqlIgnoreCase(item.name, "sec-websocket-accept")) {
            accepted = std.mem.eql(u8, std.mem.trim(u8, item.value, " \t"), &expected);
        } else if (std.ascii.eqlIgnoreCase(item.name, "sec-websocket-protocol")) {
            if (protocol != null) return error.HandshakeRejected;
            protocol = std.mem.trim(u8, item.value, " \t");
        } else if (std.ascii.eqlIgnoreCase(item.name, "sec-websocket-extensions")) {
            return error.HandshakeRejected;
        }
    }
    if (!upgrade or !connection_upgrade or !accepted) return error.HandshakeRejected;
    if (protocol) |chosen| {
        for (offered) |candidate| {
            if (std.mem.eql(u8, candidate, chosen)) return try allocator.dupe(u8, chosen);
        }
        return error.HandshakeRejected;
    }
    return try allocator.dupe(u8, "");
}

const TestPeer = struct {
    server: std.Io.net.Server,
    script: *const fn (*TestPeer, *std.http.Server.WebSocket, std.Io.net.Stream) anyerror!void,
    protocol: ?[]const u8 = null,
    done: zio.ResetEvent = .{},
    release: zio.ResetEvent = .{},
    failure: ?anyerror = null,
    received: std.ArrayListUnmanaged(u8) = .empty,

    fn init(script: *const fn (*TestPeer, *std.http.Server.WebSocket, std.Io.net.Stream) anyerror!void) !TestPeer {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .server = try address.listen(zio.io(), .{ .reuse_address = true }), .script = script };
    }
    fn deinit(self: *TestPeer) void {
        self.received.deinit(std.testing.allocator);
        self.server.deinit(zio.io());
    }
    fn url(self: *TestPeer, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "ws://127.0.0.1:{d}/chat?room=1", .{self.server.socket.address.getPort()});
    }
    fn serve(self: *TestPeer) void {
        self.one() catch |err| {
            self.failure = err;
        };
        self.done.set();
    }
    fn one(self: *TestPeer) !void {
        const connection = try self.server.accept(zio.io());
        defer connection.close(zio.io());
        var receive_buffer: [64 * 1024]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var reader = connection.reader(zio.io(), &receive_buffer);
        var writer = connection.writer(zio.io(), &send_buffer);
        var http: std.http.Server = .init(&reader.interface, &writer.interface);
        var request = try http.receiveHead();
        if (!std.mem.eql(u8, request.head.target, "/chat?room=1")) return error.WrongTarget;
        const key = switch (request.upgradeRequested()) {
            .websocket => |value| value orelse return error.MissingKey,
            else => return error.NotUpgrade,
        };
        const extra = [_]Header{.{ .name = "sec-websocket-protocol", .value = self.protocol orelse "" }};
        var ws = try request.respondWebSocket(.{ .key = key, .extra_headers = if (self.protocol != null) &extra else &.{} });
        try ws.flush();
        try self.script(self, &ws, connection);
    }
};

/// Reads one masked client frame on the test peer, including pongs.
fn readClientFrame(ws: *std.http.Server.WebSocket) !struct { opcode: u4, data: []u8 } {
    const header = try ws.input.takeArray(2);
    if (header[0] & 0x80 == 0 or header[1] & 0x80 == 0) return error.UnexpectedFrame;
    const opcode: u4 = @truncate(header[0]);
    const len: usize = switch (header[1] & 0x7F) {
        126 => try ws.input.takeInt(u16, .big),
        127 => @intCast(try ws.input.takeInt(u64, .big)),
        else => |value| value,
    };
    const mask = (try ws.input.takeArray(4)).*;
    const data = try ws.input.take(len);
    for (data, 0..) |*byte, index| byte.* ^= mask[index % 4];
    return .{ .opcode = opcode, .data = data };
}

fn rawFrame(ws: *std.http.Server.WebSocket, first: u8, payload: []const u8) !void {
    try ws.output.writeByte(first);
    try ws.output.writeByte(@intCast(payload.len));
    try ws.output.writeAll(payload);
    try ws.flush();
}

const Collector = struct {
    socket: ?*Socket = null,
    messages: std.ArrayListUnmanaged(u8) = .empty,
    count: usize = 0,
    pause_after: ?usize = null,
    fn on(context: ?*anyopaque, message: Message) Flow {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        _ = @atomicRmw(usize, &self.count, .Add, 1, .acq_rel);
        self.messages.appendSlice(std.testing.allocator, message.bytes) catch {};
        self.messages.append(std.testing.allocator, if (message.kind == .text) '|' else '#') catch {};
        if (self.pause_after) |limit| if (@atomicLoad(usize, &self.count, .acquire) == limit) return .pause;
        return .proceed;
    }
    fn handler(self: *Collector) Handler {
        return .{ .context = self, .on_message = on };
    }
};

test "echoes text and binary, answers pings and completes a local close" {
    const script = struct {
        fn run(peer: *TestPeer, ws: *std.http.Server.WebSocket, _: std.Io.net.Stream) anyerror!void {
            try rawFrame(ws, 0x89, "hi");
            while (true) {
                const frame = try readClientFrame(ws);
                if (frame.opcode == 0x8) {
                    try rawFrame(ws, 0x88, &.{ 0x03, 0xE8 });
                    return;
                }
                if (frame.opcode == 0xA) try peer.received.appendSlice(std.testing.allocator, "pong:");
                try peer.received.appendSlice(std.testing.allocator, frame.data);
                try peer.received.append(std.testing.allocator, '/');
                if (frame.opcode == 0x1) try ws.writeMessage(frame.data, .text);
                if (frame.opcode == 0x2) try ws.writeMessage(frame.data, .binary);
            }
        }
    }.run;
    var peer = try TestPeer.init(script);
    defer peer.deinit();
    peer.protocol = "chat.v2";
    const thread = try std.Thread.spawn(.{}, TestPeer.serve, .{&peer});
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
    defer client.deinit();
    var buffer: [64]u8 = undefined;
    const socket = try Socket.connect(std.testing.allocator, &client, try peer.url(&buffer), .{ .protocols = &.{ "chat.v1", "chat.v2" }, .headers = &.{.{ .name = "origin", .value = "app://local" }} }, null);
    defer socket.deinit();
    try std.testing.expectEqualStrings("chat.v2", socket.protocol);
    try socket.send(.text, "héllo");
    try std.testing.expectError(error.InvalidUtf8, socket.send(.text, "\xff"));
    var collector: Collector = .{ .pause_after = null };
    defer collector.messages.deinit(std.testing.allocator);
    const Closer = struct {
        fn on(context: ?*anyopaque, message: Message) Flow {
            const c: *Collector = @ptrCast(@alignCast(context.?));
            _ = Collector.on(context, message);
            if (c.count == 1) c.socket.?.send(.binary, "\x00\x01") catch unreachable;
            if (c.count == 2) c.socket.?.close(close_code.normal, "bye") catch unreachable;
            return .proceed;
        }
    };
    collector.socket = socket;
    const closed = try socket.run(.{ .context = &collector, .on_message = Closer.on });
    try std.testing.expect(!closed.remote);
    try std.testing.expectEqual(@as(u16, 1000), closed.code);
    try std.testing.expectEqualStrings("héllo|\x00\x01#", collector.messages.items);
    try std.testing.expectError(error.Closed, socket.send(.text, "late"));
    peer.done.wait();
    try std.testing.expect(peer.failure == null);
    try std.testing.expectEqualStrings("héllo/pong:hi/\x00\x01/", peer.received.items);
}

test "reassembles fragments, pauses reading and reports a remote close" {
    const script = struct {
        fn run(peer: *TestPeer, ws: *std.http.Server.WebSocket, _: std.Io.net.Stream) anyerror!void {
            try rawFrame(ws, 0x01, "frag");
            try rawFrame(ws, 0x89, "p");
            try rawFrame(ws, 0x80, "ment");
            try rawFrame(ws, 0x82, "two");
            peer.release.wait();
            try rawFrame(ws, 0x88, &.{ 0x0F, 0xA0, 'o', 'k' });
            const message = try ws.readSmallMessage();
            try peer.received.appendSlice(std.testing.allocator, message.data);
            _ = ws.readSmallMessage() catch |err| if (err != error.ConnectionClose) return err;
        }
    }.run;
    var peer = try TestPeer.init(script);
    defer peer.deinit();
    const thread = try std.Thread.spawn(.{}, TestPeer.serve, .{&peer});
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
    defer client.deinit();
    var buffer: [64]u8 = undefined;
    const socket = try Socket.connect(std.testing.allocator, &client, try peer.url(&buffer), .{}, null);
    defer socket.deinit();
    try std.testing.expectEqualStrings("", socket.protocol);
    var collector: Collector = .{ .pause_after = 1 };
    defer collector.messages.deinit(std.testing.allocator);
    const Runner = struct {
        result: RunError!Closed = error.ConnectionLost,
        fn go(self: *@This(), s: *Socket, c: *Collector) void {
            self.result = s.run(c.handler());
        }
    };
    var runner: Runner = .{};
    const worker = try std.Thread.spawn(.{}, Runner.go, .{ &runner, socket, &collector });
    while (@atomicLoad(usize, &collector.count, .acquire) == 0) std.Thread.yield() catch {};
    // Paused: the second message stays unread until reading resumes.
    zio.sleep(20 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), @atomicLoad(usize, &collector.count, .acquire));
    try socket.send(.text, "while paused");
    socket.resumeReading();
    peer.release.set();
    worker.join();
    const closed = try runner.result;
    try std.testing.expect(closed.remote);
    try std.testing.expectEqual(@as(u16, 4000), closed.code);
    try std.testing.expectEqualStrings("ok", closed.reason);
    try std.testing.expectEqualStrings("fragment|two#", collector.messages.items);
    peer.done.wait();
    try std.testing.expect(peer.failure == null);
    try std.testing.expectEqualStrings("while paused", peer.received.items);
}

test "oversized messages, masked server frames and full queues fail explicitly" {
    const script = struct {
        fn run(peer: *TestPeer, ws: *std.http.Server.WebSocket, _: std.Io.net.Stream) anyerror!void {
            try rawFrame(ws, 0x82, "0123456789");
            while (true) {
                const message = ws.readSmallMessage() catch |err| {
                    if (err == error.ConnectionClose) return;
                    return err;
                };
                try peer.received.appendSlice(std.testing.allocator, message.data);
            }
        }
    }.run;
    var peer = try TestPeer.init(script);
    defer peer.deinit();
    const thread = try std.Thread.spawn(.{}, TestPeer.serve, .{&peer});
    defer thread.join();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
    defer client.deinit();
    var buffer: [64]u8 = undefined;
    const socket = try Socket.connect(std.testing.allocator, &client, try peer.url(&buffer), .{ .limits = .{ .message_bytes = 9, .send_buffer_bytes = 16 } }, null);
    defer socket.deinit();
    try std.testing.expectError(error.MessageTooLarge, socket.send(.binary, "0123456789AB"));
    try socket.send(.binary, "abcdefgh");
    try std.testing.expectError(error.Full, socket.send(.binary, "x"));
    var collector: Collector = .{};
    defer collector.messages.deinit(std.testing.allocator);
    try std.testing.expectError(error.MessageTooLarge, socket.run(collector.handler()));
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    peer.done.wait();
    try std.testing.expect(peer.failure == null);
    try std.testing.expectEqualStrings("abcdefgh", peer.received.items);
}

test "cancel aborts a running socket and a rejected handshake fails" {
    const script = struct {
        fn run(peer: *TestPeer, _: *std.http.Server.WebSocket, _: std.Io.net.Stream) anyerror!void {
            peer.release.wait();
        }
    }.run;
    var peer = try TestPeer.init(script);
    defer peer.deinit();
    const thread = try std.Thread.spawn(.{}, TestPeer.serve, .{&peer});
    defer thread.join();
    defer peer.release.set();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
    defer client.deinit();
    var buffer: [64]u8 = undefined;
    const socket = try Socket.connect(std.testing.allocator, &client, try peer.url(&buffer), .{ .protocols = &.{"x"} }, null);
    defer socket.deinit();
    const Runner = struct {
        result: RunError!Closed = error.ConnectionLost,
        fn go(self: *@This(), s: *Socket) void {
            self.result = s.run(.{ .on_message = struct {
                fn on(_: ?*anyopaque, _: Message) Flow {
                    return .proceed;
                }
            }.on });
        }
    };
    var runner: Runner = .{};
    const worker = try std.Thread.spawn(.{}, Runner.go, .{ &runner, socket });
    socket.cancel();
    worker.join();
    try std.testing.expectError(error.Cancelled, runner.result);
    try std.testing.expectError(error.Closed, socket.send(.text, "x"));

    try std.testing.expectError(error.UnsupportedScheme, Socket.connect(std.testing.allocator, &client, "http://127.0.0.1/", .{}, null));
    try std.testing.expectError(error.InvalidRequest, Socket.connect(std.testing.allocator, &client, "ws://127.0.0.1/", .{ .protocols = &.{"bad protocol"} }, null));
    const rejecting = struct {
        fn handle(_: *@import("fetch.zig").TestServer, request: *std.http.Server.Request) anyerror!void {
            try request.respond("no", .{ .status = .forbidden, .keep_alive = false });
        }
    }.handle;
    var http_server = try @import("fetch.zig").TestServer.init(rejecting);
    defer http_server.deinit();
    const http_thread = try std.Thread.spawn(.{}, @import("fetch.zig").TestServer.serve, .{ &http_server, 1 });
    defer http_thread.join();
    const url = try std.fmt.bufPrint(&buffer, "ws://127.0.0.1:{d}/", .{http_server.port()});
    try std.testing.expectError(error.HandshakeRejected, Socket.connect(std.testing.allocator, &client, url, .{}, null));
}

test "output queued before cancel fails as a write error" {
    const script = struct {
        fn run(peer: *TestPeer, _: *std.http.Server.WebSocket, _: std.Io.net.Stream) anyerror!void {
            peer.release.wait();
        }
    }.run;
    var peer = try TestPeer.init(script);
    defer peer.deinit();
    const thread = try std.Thread.spawn(.{}, TestPeer.serve, .{&peer});
    defer thread.join();
    defer peer.release.set();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = zio.io() };
    defer client.deinit();
    var buffer: [64]u8 = undefined;
    const socket = try Socket.connect(std.testing.allocator, &client, try peer.url(&buffer), .{}, null);
    defer socket.deinit();
    // The worker writes this to a socket that cancel already shut down.
    try socket.send(.binary, "queued before cancel");
    socket.cancel();
    try std.testing.expectError(error.Cancelled, socket.run(.{ .on_message = struct {
        fn on(_: ?*anyopaque, _: Message) Flow {
            return .proceed;
        }
    }.on }));
}
