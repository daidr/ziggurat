//! WebSocket plugin: pages open WebSocket connections from the host through
//! `@ziggurat/plugin-websocket`, whose `WebSocket` has the browser's API.
//! Unlike the browser's, it may send any header with the opening handshake,
//! such as Authorization, Cookie or Origin, and the page's Content Security
//! Policy does not apply. The plugin starts one worker per connection it
//! allows at once; each opens and runs a `ziggurat_net` WebSocket, and its
//! events reach the main thread through `App.post`.
const std = @import("std");
const ipc = @import("ziggurat_ipc");
const net = @import("ziggurat_net");
const runtime = @import("ziggurat_page_runtime");

pub const Service = @import("websocket_service.zig").Service;
const limits = Service.limits;
const Dispatcher = ipc.Dispatcher(Service, Implementation, Plugin, limits);
const ConnectWork = ipc.Work(Service, limits, "connect");
const SendWork = ipc.Work(Service, limits, "send");
const ws = net.websocket;

/// Message bytes in one piece sent to the page; its Base64 fits in a message.
pub const piece_bytes = 32 * 1024;
/// Connections open at once, each holding a worker.
pub const max_connections = limits.max_pending / 2;
const unset = ipc.Session.init("00000000000000000000000000000000") catch unreachable;
/// The code of a connection that ended without a closing handshake.
const close_abnormal: u16 = 1006;

/// What `Allow` sees of an opening handshake before it is made.
pub const Request = struct {
    url: []const u8,
    protocols: []const []const u8,
    headers: []const ws.Header,
};

/// Decides on the main thread whether pages may open a connection; one it
/// refuses fails.
pub const Allow = struct {
    context: *anyopaque,
    allow: *const fn (*anyopaque, Request) bool,
};

pub const Options = struct {
    post: runtime.Post,
    /// Workers the plugin starts in `init` and joins in `deinit`: the
    /// connections open at once, at most `max_connections`. A page opening
    /// more gets connections that fail.
    connections: u8 = 8,
    allow: ?Allow = null,
    /// The most bytes a received message may have; a bigger one fails the
    /// connection (1009).
    max_message_bytes: usize = 64 * 1024 * 1024,
    /// Bytes of sent messages a connection holds while the network is
    /// behind; the page's `bufferedAmount` counts them. A message larger
    /// than this fails to send.
    send_buffer_bytes: usize = 4 * 1024 * 1024,
    /// How long a connection the page closed waits for the server to finish
    /// the closing handshake.
    close_timeout_ms: u32 = 5000,
    /// Received bytes a connection holds for a page that is behind before it
    /// stops reading from the server.
    receive_buffer_bytes: usize = 1024 * 1024,
};

const Inbound = struct { kind: ws.Kind, bytes: []u8 };

/// How a connection ended.
const Outcome = struct {
    code: u16 = close_abnormal,
    reason: [123]u8 = undefined,
    reason_len: u8 = 0,
    clean: bool = false,
    failure: ?[]const u8 = null,
};

const Connection = struct {
    // Main thread.
    live: bool = false,
    work: ConnectWork = undefined,
    id: u32 = 0,
    open_sent: bool = false,
    /// Bytes of the first received message already sent to the page.
    offset: usize = 0,
    /// The message the page is sending, piece by piece.
    assembly: std.ArrayList(u8) = .empty,
    assembly_kind: ?ws.Kind = null,
    /// The last piece of a message that waits for room in the socket.
    waiting: ?SendWork = null,
    // Written by the main thread before the connection is queued; read by
    // its worker.
    url: []const u8 = "",
    protocols: [][]const u8 = &.{},
    headers: []ws.Header = &.{},
    text: []u8 = &.{},
    cancel: net.Cancel = .{},
    // Under the plugin mutex.
    phase: enum { free, queued, running, finished } = .free,
    abandoned: bool = false,
    changed: bool = false,
    socket: ?*net.WebSocket = null,
    protocol: ?[]u8 = null,
    opened: bool = false,
    inbox: std.ArrayList(Inbound) = .empty,
    inbox_head: usize = 0,
    inbox_bytes: usize = 0,
    paused: bool = false,
    want_flush: bool = false,
    flushed: bool = false,
    outcome: Outcome = .{},
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    options: Options,
    dispatcher: Dispatcher = .init(unset),
    implementation: Implementation = .{},
    host: ?*runtime.Host = null,
    connections: [max_connections]Connection = @splat(.{}),
    threads: []std.Thread = &.{},
    mutex: std.Thread.Mutex = .{},
    queued: std.Thread.Condition = .{},
    queue: [max_connections]u8 = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    stopping: bool = false,
    outbox: runtime.Outbox,
    /// Base64 of one piece; main thread.
    encoded: []u8 = &.{},

    /// Starts the workers. The plugin stays at this address until `deinit`.
    /// `allocator` must be thread-safe: workers allocate with it.
    pub fn init(self: *Plugin, allocator: std.mem.Allocator, options: Options) !void {
        std.debug.assert(options.connections > 0 and options.connections <= max_connections);
        std.debug.assert(options.send_buffer_bytes > 5 and options.max_message_bytes > 0);
        self.* = .{ .allocator = allocator, .options = options, .outbox = .{ .post = options.post, .drain = .{ .context = self, .call = drain } } };
        self.encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(piece_bytes));
        errdefer allocator.free(self.encoded);
        self.threads = try allocator.alloc(std.Thread, options.connections);
        var started: usize = 0;
        errdefer {
            self.stop();
            for (self.threads[0..started]) |thread| thread.join();
            allocator.free(self.threads);
        }
        while (started < self.threads.len) : (started += 1) self.threads[started] = try std.Thread.spawn(.{}, worker, .{self});
    }

    /// Main thread, after `App.run` returned and before `App.deinit`, with the
    /// Host detached: drops the connections and joins the workers.
    pub fn deinit(self: *Plugin) void {
        self.stop();
        for (self.threads) |thread| thread.join();
        for (&self.connections) |*connection| {
            if (connection.live) connection.work.deinit();
            connection.live = false;
            if (connection.phase != .free) self.release(connection);
        }
        self.allocator.free(self.threads);
        self.allocator.free(self.encoded);
        self.* = undefined;
    }

    pub fn plugin(self: *Plugin) runtime.Plugin {
        return .{ .name = Service.name, .endpoint = .{ .context = self, .vtable = &vtable } };
    }

    const vtable: runtime.Endpoint.VTable = .{ .open = open, .receive = receive, .close = close };

    fn stop(self: *Plugin) void {
        self.outbox.stop();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        for (&self.connections) |*connection| if (connection.phase == .queued or connection.phase == .running) {
            connection.abandoned = true;
            connection.cancel.cancel();
            if (connection.socket) |socket| socket.cancel();
        };
        self.queued.broadcast();
    }

    fn open(context: *anyopaque, host: *runtime.Host, session: ipc.Session) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.reset(session, &canceled) catch {};
        self.abandonAll();
        self.host = host;
    }

    fn close(context: *anyopaque, _: *runtime.Host) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var canceled: [limits.max_pending]ipc.Token = undefined;
        _ = self.dispatcher.router.close(&canceled) catch unreachable;
        self.abandonAll();
        self.host = null;
    }

    fn receive(context: *anyopaque, host: *runtime.Host, bytes: []const u8) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        var action = self.dispatcher.dispatch(self.allocator, &self.implementation, self, bytes) catch return;
        switch (action) {
            .reply => |*pending| {
                defer pending.deinit();
                const packet = pending.encode(&self.dispatcher.router, self.allocator) catch return;
                _ = self.send(packet);
            },
            .taken => {},
            .cancel => |token| {
                for (&self.connections) |*connection| {
                    if (connection.live and sameToken(connection.work.token, token)) self.abandon(connection);
                    if (connection.waiting) |*waiting| if (sameToken(waiting.token, token)) {
                        waiting.deinit();
                        connection.waiting = null;
                    };
                }
            },
            .ack => |ack| for (&self.connections) |*connection| {
                if (connection.live and sameToken(connection.work.token, ack.token)) self.deliver(connection);
            },
            .rejected => |rejected| {
                const packet = ipc.protocol.reject(self.allocator, rejected.token, rejected.code, limits.max_message_bytes) catch return;
                defer self.allocator.free(packet);
                host.send(packet) catch {};
            },
        }
    }

    fn abandonAll(self: *Plugin) void {
        for (&self.connections) |*connection| if (connection.live) self.abandon(connection);
    }

    /// The page went away or stopped listening: close the connection as
    /// going away and forget the call. The connection is released once its
    /// worker lets go of it.
    fn abandon(self: *Plugin, connection: *Connection) void {
        connection.live = false;
        connection.work.deinit();
        if (connection.waiting) |*waiting| waiting.deinit();
        connection.waiting = null;
        connection.cancel.cancel();
        self.mutex.lock();
        connection.abandoned = true;
        if (connection.socket) |socket| socket.close(ws.close_code.going_away, "") catch {};
        const finished = connection.phase == .finished;
        self.mutex.unlock();
        if (finished) self.release(connection);
    }

    fn release(self: *Plugin, connection: *Connection) void {
        std.debug.assert(!connection.live);
        for (connection.inbox.items[connection.inbox_head..]) |item| self.allocator.free(item.bytes);
        connection.inbox.deinit(self.allocator);
        if (connection.protocol) |protocol| self.allocator.free(protocol);
        connection.assembly.deinit(self.allocator);
        self.allocator.free(connection.protocols);
        self.allocator.free(connection.headers);
        self.allocator.free(connection.text);
        connection.* = .{};
    }

    fn send(self: *Plugin, packet: []u8) bool {
        defer self.allocator.free(packet);
        const host = self.host orelse return false;
        // A failed send closes this endpoint before it returns.
        host.send(packet) catch return false;
        return true;
    }

    fn fail(self: *Plugin, comptime method: []const u8, token: ipc.Token, code: Service.Code, message: []const u8) void {
        const packet = self.dispatcher.router.fail(method, self.allocator, token, code, message) catch return;
        _ = self.send(packet);
    }

    fn sent(self: *Plugin, work: *SendWork) void {
        const token = work.token;
        work.deinit();
        const packet = self.dispatcher.router.complete("send", self.allocator, token, {}) catch return;
        _ = self.send(packet);
    }

    fn sendFailed(self: *Plugin, work: *SendWork, code: Service.Code, message: []const u8) void {
        const token = work.token;
        work.deinit();
        self.fail("send", token, code, message);
    }

    fn find(self: *Plugin, id: u32) ?*Connection {
        for (&self.connections) |*connection| if (connection.live and connection.id == id) return connection;
        return null;
    }

    /// Main thread: starts a validated connection on a free slot.
    fn start(self: *Plugin, work: ConnectWork) void {
        var owned = work;
        const token = owned.token;
        const params = owned.params;
        if (self.find(params.id) != null) {
            owned.deinit();
            return self.fail("connect", token, .invalid, "The connection id is in use");
        }
        const connection = for (self.connections[0..self.options.connections]) |*connection| {
            if (connection.phase == .free) break connection;
        } else {
            owned.deinit();
            return self.fail("connect", token, .busy, "Too many connections");
        };
        const uri = std.Uri.parse(params.url) catch {
            owned.deinit();
            return self.fail("connect", token, .invalid, "Invalid URL");
        };
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "ws") and !std.ascii.eqlIgnoreCase(uri.scheme, "wss")) {
            owned.deinit();
            return self.fail("connect", token, .invalid, "Unsupported URL scheme");
        }
        self.prepare(connection, params) catch |err| {
            self.release(connection);
            owned.deinit();
            return self.fail("connect", token, .invalid, switch (err) {
                error.InvalidHeader => "Invalid header",
                error.InvalidProtocol => "Invalid subprotocol",
                error.OutOfMemory => "Out of memory",
            });
        };
        if (self.options.allow) |allow| if (!allow.allow(allow.context, .{ .url = connection.url, .protocols = connection.protocols, .headers = connection.headers })) {
            self.release(connection);
            owned.deinit();
            return self.fail("connect", token, .denied, "The app does not allow this connection");
        };
        connection.work = owned;
        connection.id = params.id;
        connection.live = true;
        self.mutex.lock();
        defer self.mutex.unlock();
        connection.phase = .queued;
        self.queue[(self.queue_head + self.queue_len) % self.queue.len] = @intCast(connection - &self.connections[0]);
        self.queue_len += 1;
        self.queued.signal();
    }

    fn prepare(self: *Plugin, connection: *Connection, params: Service.Connect) !void {
        var bytes: usize = params.url.len;
        var count: usize = 0;
        for (params.headers) |header| {
            if (!validHeader(header)) return error.InvalidHeader;
            if (handshakeHeader(header.name)) continue;
            count += 1;
            bytes += header.name.len + header.value.len;
        }
        for (params.protocols, 0..) |protocol, index| {
            if (!validToken(protocol)) return error.InvalidProtocol;
            for (params.protocols[0..index]) |earlier| if (std.mem.eql(u8, earlier, protocol)) return error.InvalidProtocol;
            bytes += protocol.len;
        }
        connection.text = try self.allocator.alloc(u8, bytes);
        connection.headers = try self.allocator.alloc(ws.Header, count);
        connection.protocols = try self.allocator.alloc([]const u8, params.protocols.len);
        var copied: usize = 0;
        connection.url = copy(connection.text, &copied, params.url);
        count = 0;
        for (params.headers) |header| if (!handshakeHeader(header.name)) {
            connection.headers[count] = .{ .name = copy(connection.text, &copied, header.name), .value = copy(connection.text, &copied, header.value) };
            count += 1;
        };
        for (params.protocols, 0..) |protocol, index| connection.protocols[index] = copy(connection.text, &copied, protocol);
    }

    /// Main thread: takes a piece of a message the page sends.
    fn take(self: *Plugin, work: SendWork) void {
        var owned = work;
        const message = owned.params;
        const connection = self.find(message.id) orelse return self.sendFailed(&owned, .closed, "The connection is closed");
        if (connection.waiting != null) return self.sendFailed(&owned, .busy, "A message is still waiting to be sent");
        switch (message.kind) {
            .close => {
                const code: u16 = if (message.code == 0) ws.close_code.normal else message.code;
                const reason = message.reason orelse "";
                if (!(code == ws.close_code.normal or (code >= 3000 and code <= 4999))) return self.sendFailed(&owned, .invalid, "Invalid close code");
                if (reason.len > 123 or !std.unicode.utf8ValidateSlice(reason)) return self.sendFailed(&owned, .invalid, "Invalid close reason");
                self.mutex.lock();
                if (connection.socket) |socket| {
                    socket.close(code, reason) catch {};
                } else if (!connection.opened) connection.cancel.cancel();
                self.mutex.unlock();
                return self.sent(&owned);
            },
            .text, .binary => {
                const kind: ws.Kind = if (message.kind == .text) .text else .binary;
                if (connection.assembly_kind) |current| if (current != kind) {
                    self.dropAssembly(connection);
                    return self.sendFailed(&owned, .invalid, "A message changed its kind");
                };
                const data = message.data orelse "";
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(data) catch return self.sendFailed(&owned, .invalid, "Invalid message encoding");
                const start_len = connection.assembly.items.len;
                if (size > self.options.send_buffer_bytes - 5 - start_len) {
                    self.dropAssembly(connection);
                    return self.sendFailed(&owned, .invalid, "Message too large");
                }
                connection.assembly.resize(self.allocator, start_len + size) catch {
                    self.dropAssembly(connection);
                    return self.sendFailed(&owned, .failed, "Out of memory");
                };
                decoder.decode(connection.assembly.items[start_len..], data) catch {
                    self.dropAssembly(connection);
                    return self.sendFailed(&owned, .invalid, "Invalid message encoding");
                };
                connection.assembly_kind = kind;
                if (!message.last) return self.sent(&owned);
                connection.waiting = owned;
                self.push(connection);
            },
        }
    }

    fn dropAssembly(self: *Plugin, connection: *Connection) void {
        connection.assembly.clearAndFree(self.allocator);
        connection.assembly_kind = null;
    }

    /// Main thread: hands the assembled message to the socket, or keeps it
    /// waiting until the socket has written enough.
    fn push(self: *Plugin, connection: *Connection) void {
        var work = connection.waiting orelse return;
        self.mutex.lock();
        const socket = connection.socket orelse {
            self.mutex.unlock();
            connection.waiting = null;
            self.dropAssembly(connection);
            return self.sendFailed(&work, if (connection.opened) .closed else .invalid, if (connection.opened) "The connection is closed" else "The connection is not open yet");
        };
        connection.flushed = false;
        socket.send(connection.assembly_kind.?, connection.assembly.items) catch |err| switch (err) {
            error.Full => {
                connection.want_flush = true;
                self.mutex.unlock();
                return;
            },
            else => {
                self.mutex.unlock();
                connection.waiting = null;
                self.dropAssembly(connection);
                return self.sendFailed(&work, switch (err) {
                    error.Closed => .closed,
                    else => .invalid,
                }, switch (err) {
                    error.Closed => "The connection is closed",
                    error.InvalidUtf8 => "Text is not UTF-8",
                    else => "Message too large",
                });
            },
        };
        connection.want_flush = false;
        self.mutex.unlock();
        connection.waiting = null;
        self.dropAssembly(connection);
        self.sent(&work);
    }

    /// Main thread, in the posted drain: hands what workers produced to the
    /// pages.
    fn drain(context: *anyopaque) void {
        const self: *Plugin = @ptrCast(@alignCast(context));
        self.outbox.begin();
        var touched: [max_connections]*Connection = undefined;
        var count: usize = 0;
        self.mutex.lock();
        for (&self.connections) |*connection| if (connection.changed) {
            connection.changed = false;
            touched[count] = connection;
            count += 1;
        };
        self.mutex.unlock();
        for (touched[0..count]) |connection| {
            if (!connection.live) {
                self.reap(connection);
                continue;
            }
            self.mutex.lock();
            const flushed = connection.flushed;
            connection.flushed = false;
            self.mutex.unlock();
            if (flushed and connection.waiting != null) self.push(connection);
            if (connection.live) self.deliver(connection);
        }
    }

    fn reap(self: *Plugin, connection: *Connection) void {
        self.mutex.lock();
        const finished = connection.phase == .finished;
        self.mutex.unlock();
        if (finished) self.release(connection);
    }

    /// Main thread: sends the opening, then received messages in pieces while
    /// the page has credit, then the close once the worker is through.
    fn deliver(self: *Plugin, connection: *Connection) void {
        const token = connection.work.token;
        if (!connection.open_sent) {
            self.mutex.lock();
            const opened = connection.opened;
            const protocol = connection.protocol;
            self.mutex.unlock();
            if (opened) {
                const packet = self.dispatcher.router.chunk("connect", self.allocator, token, event(.open, .{ .protocol = protocol orelse "" })) catch |err| switch (err) {
                    error.Backpressure => return,
                    else => return self.abandonWith(connection, "Could not encode the opening"),
                };
                connection.open_sent = true;
                if (!self.send(packet)) return;
            }
        }
        while (connection.live and connection.open_sent) {
            self.mutex.lock();
            const pending = connection.inbox_head < connection.inbox.items.len;
            const item = if (pending) connection.inbox.items[connection.inbox_head] else undefined;
            self.mutex.unlock();
            if (!pending) break;
            const end = @min(item.bytes.len, connection.offset + piece_bytes);
            const text = std.base64.standard.Encoder.encode(self.encoded, item.bytes[connection.offset..end]);
            const last = end == item.bytes.len;
            const packet = self.dispatcher.router.chunk("connect", self.allocator, token, event(if (item.kind == .text) .text else .binary, .{ .data = text, .last = last })) catch |err| switch (err) {
                // The page has not read enough yet; its acknowledgement resumes.
                error.Backpressure => return,
                else => return self.abandonWith(connection, "Could not encode a message"),
            };
            connection.offset = end;
            if (last) {
                connection.offset = 0;
                self.mutex.lock();
                connection.inbox_head += 1;
                connection.inbox_bytes -= item.bytes.len;
                if (connection.inbox_head == connection.inbox.items.len) {
                    connection.inbox.clearRetainingCapacity();
                    connection.inbox_head = 0;
                }
                if (connection.paused and connection.inbox_bytes < self.options.receive_buffer_bytes) {
                    connection.paused = false;
                    if (connection.socket) |socket| socket.resumeReading();
                }
                self.mutex.unlock();
                self.allocator.free(item.bytes);
            }
            if (!self.send(packet)) return;
        }
        if (!connection.live) return;
        self.mutex.lock();
        const finished = connection.phase == .finished and connection.inbox_head == connection.inbox.items.len;
        const outcome = connection.outcome;
        self.mutex.unlock();
        if (!finished) return;
        const packet = self.dispatcher.router.chunk("connect", self.allocator, token, event(.close, .{
            .code = outcome.code,
            .reason = outcome.reason[0..outcome.reason_len],
            .clean = outcome.clean,
            .failure = outcome.failure,
        })) catch |err| switch (err) {
            error.Backpressure => return,
            else => return self.abandonWith(connection, "Could not encode the close"),
        };
        connection.live = false;
        connection.work.deinit();
        if (connection.waiting) |*waiting| self.sendFailed(waiting, .closed, "The connection is closed");
        connection.waiting = null;
        if (self.send(packet)) {
            if (self.dispatcher.router.complete("connect", self.allocator, token, {})) |done| {
                _ = self.send(done);
            } else |_| {}
        }
        self.release(connection);
    }

    fn abandonWith(self: *Plugin, connection: *Connection, message: []const u8) void {
        const token = connection.work.token;
        self.abandon(connection);
        self.fail("connect", token, .failed, message);
    }

    // Workers.

    fn worker(self: *Plugin) void {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();
        while (true) {
            self.mutex.lock();
            while (!self.stopping and self.queue_len == 0) self.queued.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const connection = &self.connections[self.queue[self.queue_head]];
            self.queue_head = (self.queue_head + 1) % self.queue.len;
            self.queue_len -= 1;
            connection.phase = .running;
            const abandoned = connection.abandoned;
            self.mutex.unlock();
            var outcome: Outcome = .{};
            if (abandoned) outcome.failure = "Cancelled" else self.serve(&client, connection, &outcome);
            self.mutex.lock();
            connection.outcome = outcome;
            connection.phase = .finished;
            self.changed(connection);
        }
    }

    fn serve(self: *Plugin, client: *std.http.Client, connection: *Connection, outcome: *Outcome) void {
        const socket = net.WebSocket.connect(self.allocator, client, connection.url, .{
            .headers = connection.headers,
            .protocols = connection.protocols,
            .limits = .{
                .message_bytes = self.options.max_message_bytes,
                .send_buffer_bytes = self.options.send_buffer_bytes,
                .url_bytes = @max(connection.url.len, 8 * 1024),
                .close_timeout_ms = self.options.close_timeout_ms,
            },
        }, &connection.cancel) catch |err| {
            outcome.failure = @errorName(err);
            return;
        };
        defer socket.deinit();
        const protocol = self.allocator.dupe(u8, socket.protocol) catch null;
        self.mutex.lock();
        if (connection.abandoned) {
            self.mutex.unlock();
            if (protocol) |owned| self.allocator.free(owned);
            outcome.failure = "Cancelled";
            return;
        }
        connection.socket = socket;
        connection.protocol = protocol;
        connection.opened = true;
        self.changed(connection);
        var sink: Sink = .{ .plugin = self, .connection = connection };
        const result = socket.run(.{ .context = &sink, .on_message = Sink.message, .on_flushed = Sink.flushed });
        self.mutex.lock();
        connection.socket = null;
        self.mutex.unlock();
        if (result) |closed| {
            outcome.code = closed.code;
            outcome.reason_len = @intCast(closed.reason.len);
            @memcpy(outcome.reason[0..closed.reason.len], closed.reason);
            outcome.clean = true;
        } else |err| switch (err) {
            // The server missed the closing handshake the page started.
            error.CloseTimedOut => {},
            else => outcome.failure = @errorName(err),
        }
    }

    /// Worker, with the mutex held: marks the connection changed, unlocks and
    /// wakes the main thread.
    fn changed(self: *Plugin, connection: *Connection) void {
        connection.changed = true;
        self.mutex.unlock();
        self.outbox.notify();
    }
};

/// The worker's end of a running connection.
const Sink = struct {
    plugin: *Plugin,
    connection: *Connection,

    fn message(context: ?*anyopaque, value: ws.Message) ws.Flow {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        const plugin = self.plugin;
        const connection = self.connection;
        const bytes = plugin.allocator.dupe(u8, value.bytes) catch {
            connection.cancel.cancel();
            if (connection.socket) |socket| socket.cancel();
            return .proceed;
        };
        plugin.mutex.lock();
        if (connection.abandoned) {
            plugin.mutex.unlock();
            plugin.allocator.free(bytes);
            return .proceed;
        }
        connection.inbox.append(plugin.allocator, .{ .kind = value.kind, .bytes = bytes }) catch {
            plugin.mutex.unlock();
            plugin.allocator.free(bytes);
            if (connection.socket) |socket| socket.cancel();
            return .proceed;
        };
        connection.inbox_bytes += bytes.len;
        const pause = connection.inbox_bytes >= plugin.options.receive_buffer_bytes;
        if (pause) connection.paused = true;
        plugin.changed(connection);
        return if (pause) .pause else .proceed;
    }

    fn flushed(context: ?*anyopaque) void {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        const plugin = self.plugin;
        plugin.mutex.lock();
        if (!self.connection.want_flush) {
            plugin.mutex.unlock();
            return;
        }
        self.connection.want_flush = false;
        self.connection.flushed = true;
        plugin.changed(self.connection);
    }
};

const EventFields = struct {
    protocol: ?[]const u8 = null,
    data: ?[]const u8 = null,
    last: bool = false,
    code: u16 = 0,
    reason: ?[]const u8 = null,
    clean: bool = false,
    failure: ?[]const u8 = null,
};

fn event(kind: Service.Kind, fields: EventFields) Service.Event {
    return .{ .kind = kind, .protocol = fields.protocol, .data = fields.data, .last = fields.last, .code = fields.code, .reason = fields.reason, .clean = fields.clean, .@"error" = fields.failure };
}

const Implementation = struct {
    pub fn connect(_: *Implementation, plugin: *Plugin, work: ConnectWork) void {
        plugin.start(work);
    }
    pub fn send(_: *Implementation, plugin: *Plugin, work: SendWork) void {
        plugin.take(work);
    }
};

fn copy(storage: []u8, offset: *usize, text: []const u8) []const u8 {
    const target = storage[offset.*..][0..text.len];
    @memcpy(target, text);
    offset.* += text.len;
    return target;
}

fn sameToken(a: ipc.Token, b: ipc.Token) bool {
    return a.session.eql(b.session) and a.slot == b.slot and a.id == b.id;
}

/// Headers of the opening handshake that the socket writes itself; a page's
/// values are dropped.
const handshake_headers = [_][]const u8{ "host", "upgrade", "connection", "content-length", "transfer-encoding", "sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions", "sec-websocket-accept" };

fn handshakeHeader(name: []const u8) bool {
    for (handshake_headers) |item| if (std.ascii.eqlIgnoreCase(item, name)) return true;
    return false;
}

fn validToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    return true;
}

fn validHeader(header: Service.Header) bool {
    if (!validToken(header.name)) return false;
    for (header.value) |c| if (c == '\r' or c == '\n' or c == 0) return false;
    return true;
}

test {
    _ = @import("websocket_test.zig");
}
