const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const protocol = @import("ziggurat_language_protocol");
const codec = protocol.codec;
const allocator = std.heap.page_allocator;
const Mode = enum { normal, remote_error, silent, late_stop };
const Command = enum { configuration, initialize, send_initialize, ready, send_ready, prepare_shutdown, send_shutdown, read_reply, prepare_incoming, send_incoming, prepare_exit, send_exit, terminate };
const Event = enum { configuration, initialize_prepared, negotiated, ready_prepared, ready, shutdown_prepared, shutdown_seen, incoming, incoming_prepared, reply, exit_prepared, exited, failed };

const Host = struct {
    app: *z.App,
    client: *protocol.Client,
    server: []const u8,
    mode: Mode,
    transport: ?protocol.Transport = null,
    handshake: protocol.session.Handshake = undefined,
    initialization: ?protocol.WorkspaceWork = null,
    configuration: ?protocol.configuration.Prepared = null,
    negotiated: protocol.session.Negotiated = undefined,
    work: ?protocol.ShutdownWork = null,
    reply: ?protocol.ShutdownReply = null,
    incoming: ?protocol.WorkspaceIncoming = null,
    packet: ?codec.Packet = null,
    mutex: zio.Mutex = .{},
    condition: zio.Condition = .{},
    command: ?Command = .configuration,
    event: Event = .failed,
    failure: ?anyerror = null,
    replies: usize = 0,
    pulls: usize = 0,
    exited: bool = false,
    forced: bool = false,

    fn enqueue(self: *Host, command: Command) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.command == null);
        self.command = command;
        self.condition.signal();
    }
    fn next(self: *Host) Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.command == null) self.condition.wait(&self.mutex);
        const command = self.command.?;
        self.command = null;
        return command;
    }
    fn post(self: *Host, event: Event) !void {
        self.event = event;
        try self.app.post(.{ .context = self, .call = delivered });
    }
    fn delivered(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.accept() catch |err| {
            self.failure = err;
            self.client.stop() catch {};
            self.enqueue(.terminate);
        };
    }
    fn stopBeforeReply(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.client.stop() catch unreachable;
    }
    fn accept(self: *Host) !void {
        switch (self.event) {
            .configuration => {
                try self.client.enableConfiguration(&self.configuration.?, .{});
                self.configuration = null;
                self.transport = try self.client.openTransport();
                self.handshake = try self.client.beginInitialize();
                self.initialization = try self.client.captureWorkspaceInitialize(self.handshake);
                self.enqueue(.initialize);
            },
            .initialize_prepared => {
                try self.initialization.?.validateSend();
                self.packet = try self.initialization.?.takePacket();
                _ = try self.initialization.?.commit();
                self.enqueue(.send_initialize);
            },
            .negotiated => {
                try self.initialization.?.close();
                self.initialization = null;
                try self.client.adoptInitialize(self.negotiated);
                self.enqueue(.ready);
            },
            .ready_prepared => {
                var send = try self.client.beginControlSend(.{ .initialized = self.handshake });
                defer send.end();
                try send.commit();
                self.enqueue(.send_ready);
            },
            .ready => {
                self.work = try self.client.captureShutdown(.{ .deadline_ns = 100 });
                self.enqueue(.prepare_shutdown);
            },
            .shutdown_prepared => {
                var send = try self.work.?.beginSend(.request, 1);
                defer send.end();
                self.packet = try send.takePacket();
                try send.commit();
                try std.testing.expectEqual(protocol.Phase.awaiting_shutdown, (try self.client.stats()).phase);
                self.enqueue(.send_shutdown);
            },
            .shutdown_seen => {
                try std.testing.expectError(error.InvalidPhase, self.work.?.beginSend(.exit, 1));
                if (self.mode == .silent) {
                    try std.testing.expect(!try self.work.?.expire(99));
                    try std.testing.expect(try self.work.?.expire(100));
                    self.forced = true;
                    self.enqueue(.terminate);
                } else self.enqueue(.read_reply);
            },
            .incoming => {
                try self.incoming.?.capture();
                self.enqueue(.prepare_incoming);
            },
            .incoming_prepared => {
                try self.incoming.?.validateSend();
                self.packet = try self.incoming.?.takePacket();
                try std.testing.expect(!(try self.incoming.?.commit()).stale);
                try self.incoming.?.close();
                self.incoming = null;
                self.pulls += 1;
                self.enqueue(.send_incoming);
            },
            .reply => {
                self.replies += 1;
                const adopted = try self.reply.?.finish();
                self.reply = null;
                if (self.mode == .late_stop) {
                    try std.testing.expect(!adopted.acknowledged and adopted.rejected.? == error.Closed);
                    self.forced = true;
                    self.enqueue(.terminate);
                } else {
                    try std.testing.expect(adopted.acknowledged);
                    try std.testing.expectEqual(if (self.mode == .remote_error) @as(?i32, -32001) else null, adopted.remote_code);
                    self.enqueue(.prepare_exit);
                }
            },
            .exit_prepared => {
                var send = try self.work.?.beginSend(.exit, 1);
                defer send.end();
                self.packet = try send.takePacket();
                try send.commit();
                self.enqueue(.send_exit);
            },
            .exited => self.app.quit(),
            .failed => self.app.quit(),
        }
    }
    fn writePacket(self: *Host, output: std.Io.File) !void {
        var packet = self.packet orelse return error.MissingPacket;
        self.packet = null;
        defer packet.deinit();
        try output.writeStreamingAll(zio.io(), packet.bytes.?);
    }
    fn receiveReply(self: *Host, input: std.Io.File, decoder: *codec.Decoder) !void {
        const bytes = try readBody(input, decoder);
        const message = try codec.Message.parse(allocator, bytes, .{});
        const request = (try message.value()) == .request;
        try message.close();
        if (request) {
            self.incoming = try self.transport.?.workspaceRequest(allocator, bytes);
            try self.post(.incoming);
        } else {
            self.reply = try self.work.?.receive(&self.transport.?, allocator, bytes);
            if (self.mode == .late_stop) try self.app.post(.{ .context = self, .call = stopBeforeReply });
            try self.post(.reply);
        }
    }
    fn run(self: *Host) void {
        self.workLoop() catch |err| {
            self.failure = err;
            self.post(.failed) catch {};
        };
    }
    fn workLoop(self: *Host) !void {
        const mode = if (self.mode == .late_stop) "normal" else @tagName(self.mode);
        var child = try zio.spawn(.{ .argv = &.{ self.server, mode }, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
        var child_live = true;
        defer if (child_live) {
            child.kill(zio.io());
        };
        var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
        defer decoder.deinit();
        while (true) switch (self.next()) {
            .configuration => {
                self.configuration = try protocol.configuration.Prepared.create(allocator, .{ .settings_json = "{}", .entries = &.{.{ .section = "close", .value_json = "7" }} }, .{});
                try self.post(.configuration);
            },
            .initialize => {
                try self.initialization.?.prepare(allocator, .{});
                try self.post(.initialize_prepared);
            },
            .send_initialize => {
                try self.writePacket(child.stdin.?);
                self.negotiated = try self.transport.?.negotiate(allocator, self.handshake, try readBody(child.stdout.?, &decoder));
                try self.post(.negotiated);
            },
            .ready => {
                self.packet = try self.transport.?.initialized(allocator);
                try self.post(.ready_prepared);
            },
            .send_ready => {
                try self.writePacket(child.stdin.?);
                try self.post(.ready);
            },
            .prepare_shutdown => {
                try self.work.?.prepare(allocator);
                try self.post(.shutdown_prepared);
            },
            .send_shutdown => {
                try self.writePacket(child.stdin.?);
                const message = try codec.Message.parse(allocator, try readBody(child.stdout.?, &decoder), .{});
                defer message.close() catch unreachable;
                const value = try message.value();
                if (value != .notification or !std.mem.eql(u8, value.notification.method, "fixture/shutdownSeen")) return error.MissingShutdownMarker;
                try self.post(.shutdown_seen);
            },
            .read_reply => try self.receiveReply(child.stdout.?, &decoder),
            .prepare_incoming => {
                try self.incoming.?.prepare(allocator);
                try self.post(.incoming_prepared);
            },
            .send_incoming => {
                try self.writePacket(child.stdin.?);
                try self.receiveReply(child.stdout.?, &decoder);
            },
            .prepare_exit => {
                try self.work.?.prepareExit(allocator);
                try self.post(.exit_prepared);
            },
            .send_exit => {
                try self.writePacket(child.stdin.?);
                const term = try child.wait(zio.io());
                child_live = false;
                if (term != .exited or term.exited != 0) return error.ServerFailed;
                self.exited = true;
                try self.post(.exited);
                return;
            },
            .terminate => {
                const term = try zio.terminate(&child);
                child_live = false;
                if (term == .exited and term.exited == 0) return error.ServerExitedBeforeForce;
                self.exited = true;
                try self.post(.exited);
                return;
            },
        };
    }
};
fn readBody(input: std.Io.File, decoder: *codec.Decoder) ![]const u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        if (try zio.read(input, &byte) == 0) return error.UnexpectedEof;
        if ((try decoder.push(&byte)).body) |value| return value;
    }
}
fn run(server: []const u8, mode: Mode) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Protocol shutdown", .width = 160, .height = 100 });
    const document = try d.Document.create(allocator, app.owner, "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{ .pending = 2, .diagnostics = 1 });
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{ .folders = &.{} }, .{});
    var host: Host = .{ .app = app, .client = client, .server = server, .mode = mode };
    defer {
        if (host.reply) |*reply| if (reply.live) {
            _ = reply.finish() catch unreachable;
        };
        if (host.incoming) |*incoming| incoming.close() catch unreachable;
        if (host.initialization) |*work| work.close() catch unreachable;
        if (host.configuration) |*prepared| if (prepared.snapshot != null) prepared.close() catch unreachable;
        client.stop() catch unreachable;
        if (host.work) |*work| work.close() catch unreachable;
        if (host.packet) |*packet| packet.deinit();
        if (host.transport) |*transport| transport.close() catch unreachable;
    }
    const worker = try std.Thread.spawn(.{}, Host.run, .{&host});
    try app.run();
    worker.join();
    if (host.failure) |err| return err;
    try std.testing.expect(host.exited and window.isClosed());
    try std.testing.expectEqual(if (mode == .silent) @as(usize, 0) else 1, host.replies);
    try std.testing.expectEqual(if (mode == .silent) @as(usize, 0) else 1, host.pulls);
    try std.testing.expectEqual(mode == .silent or mode == .late_stop, host.forced);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn queueOwnership() !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const document = try d.Document.create(allocator, app.owner, "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///queue", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    const token = try client.beginInitialize();
    var start = try client.beginControlSend(.{ .initialize = token });
    try start.commit();
    try client.adoptInitialize(.{ .token = token, .capabilities = .{} });
    var ready = try client.beginControlSend(.{ .initialized = token });
    try ready.commit();
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer work.close() catch unreachable;
    try work.prepare(allocator);
    var send = try work.beginSend(.request, 1);
    try send.commit();
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.id, .result = @as(?u8, null) }, .{});
    defer response.deinit();
    var reply = try work.receive(&transport, allocator, response.bytes.?[std.mem.indexOf(u8, response.bytes.?, "\r\n\r\n").? + 4 ..]);
    defer if (reply.live) {
        client.stop() catch unreachable;
        _ = reply.finish() catch unreachable;
    };
    const Probe = struct {
        reply: *protocol.ShutdownReply,
        tasks: usize = 0,
        replies: usize = 0,
        fn task(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.tasks += 1;
        }
        fn finish(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.replies += 1;
            const outcome = self.reply.finish() catch unreachable;
            std.debug.assert(!outcome.acknowledged and outcome.rejected.? == error.Closed);
        }
    };
    var probe: Probe = .{ .reply = &reply };
    for (0..256) |_| try app.post(.{ .context = &probe, .call = Probe.task });
    try std.testing.expectError(error.Full, app.post(.{ .context = &probe, .call = Probe.finish }));
    try std.testing.expect(reply.live);
    try std.testing.expectError(error.ShutdownReplyPending, work.close());
    try std.testing.expectError(error.ShutdownAlive, client.close());
    try std.testing.expectError(error.NotReady, client.captureShutdown(.{ .deadline_ns = 100 }));
    app.quit();
    try std.testing.expectError(error.Closed, app.post(.{ .context = &probe, .call = Probe.finish }));
    try std.testing.expect(reply.live);
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 256), probe.tasks);
    try std.testing.expectEqual(@as(usize, 0), probe.replies);
    try client.stop();
    Probe.finish(&probe);
    try std.testing.expectEqual(@as(usize, 1), probe.replies);
    try std.testing.expectError(error.DeliveryClosed, reply.finish());
}
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedServerPath;
    for (std.enums.values(Mode)) |mode| try run(args[1], mode);
    try queueOwnership();
    std.debug.print("protocol shutdown: 4 real child lifecycles, null/error ack, response-only configuration, deadline force, queued late stop and reply Full/Closed responsibility, resources=0\n", .{});
}
