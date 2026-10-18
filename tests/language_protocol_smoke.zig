const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const protocol = @import("ziggurat_language_protocol");
const session = protocol.session;
const codec = protocol.codec;
const allocator = std.heap.page_allocator;
const Command = enum { initialize, send_initialize, initialized, send_initialized, prepare_sync, send_sync, prepare_request, send_request, send_cancelled, restart, exit };
const Event = enum { initialize_prepared, negotiated, ready_prepared, initialized, sync_prepared, diagnostics, request_prepared, response, exited, failed };
const Stage = enum { completion, changed, hover, cancelled, restarted, queued_stop };
const Host = struct {
    app: *z.App,
    document: *d.Document,
    broker: *code.Broker,
    client: *protocol.Client,
    server: []const u8,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    command: ?Command = .initialize,
    event: Event = .failed,
    stage: Stage = .completion,
    transport: session.Transport,
    handshake: session.Handshake,
    negotiated: ?session.Negotiated = null,
    control_packet: ?codec.Packet = null,
    current_sync: ?session.SyncWork = null,
    candidate_sync: ?session.SyncWork = null,
    request: ?session.Work = null,
    response: ?session.Delivery = null,
    diagnostic: ?session.DiagnosticDelivery = null,
    failure: ?anyerror = null,
    completed: usize = 0,
    posts: usize = 0,
    stop_requested: std.atomic.Value(bool) = .init(false),
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
        while (self.command == null and !self.stop_requested.load(.acquire)) self.condition.wait(&self.mutex);
        if (self.stop_requested.load(.acquire)) return .exit;
        const result = self.command.?;
        self.command = null;
        return result;
    }
    fn stopBeforeDelivery(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.client.stop() catch unreachable;
        std.testing.expectError(error.RequestsAlive, self.client.close()) catch unreachable;
    }
    fn post(self: *Host, event: Event) void {
        self.event = event;
        self.app.post(.{ .context = self, .call = delivered }) catch |err| {
            if (!self.stop_requested.load(.acquire)) std.debug.panic("single protocol delivery was rejected: {s}", .{@errorName(err)});
        };
    }
    fn delivered(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.posts += 1;
        self.accept() catch |err| {
            self.failure = err;
            self.enqueue(.exit);
        };
    }
    fn capture(self: *Host, version: i32) !void {
        self.candidate_sync = try self.client.captureSync(version);
        self.enqueue(.prepare_sync);
    }
    fn beginRequest(self: *Host, kind: code.Kind, position: usize) !void {
        self.request = try self.client.begin(kind, position, .{ .start = 1, .end = if (self.stage == .completion) 5 else 4 });
        self.enqueue(.prepare_request);
    }
    fn accept(self: *Host) !void {
        switch (self.event) {
            .initialize_prepared => {
                try self.client.commitInitialize(self.handshake);
                self.enqueue(.send_initialize);
            },
            .negotiated => {
                try self.client.adoptInitialize(self.negotiated.?);
                self.enqueue(.initialized);
            },
            .ready_prepared => {
                // Packet already exists; the host's reserved fixed queue now
                // accepts its IO responsibility. No encoding on the owner.
                try self.client.commitReady(self.handshake);
                self.enqueue(.send_initialized);
            },
            .initialized => try self.capture(1),
            .sync_prepared => {
                try self.candidate_sync.?.validateSend();
                try std.testing.expect(!(try self.candidate_sync.?.commit()).stale);
                self.enqueue(.send_sync);
            },
            .diagnostics => {
                try std.testing.expect((try self.diagnostic.?.finish()).published);
                self.diagnostic = null;
                const diagnostic = (try self.broker.display(.diagnostics)).?.data.diagnostics[0];
                try std.testing.expectEqualStrings("server versioned", diagnostic.message);
                if (self.current_sync) |*previous| try previous.close();
                self.current_sync = self.candidate_sync;
                self.candidate_sync = null;
                if (self.stage == .completion) {
                    try self.beginRequest(.completion, 5);
                } else try self.beginRequest(.hover, 1);
            },
            .request_prepared => {
                try self.client.validateSend(self.request.?.token);
                try std.testing.expect(!(try self.client.commitSend(self.request.?.token)).stale);
                if (self.stage == .cancelled) {
                    try self.client.cancel(self.request.?.token);
                    self.enqueue(.send_cancelled);
                } else self.enqueue(.send_request);
            },
            .response => {
                const result = try self.response.?.finish();
                self.response = null;
                self.request = null;
                self.completed += 1;
                switch (self.stage) {
                    .completion => {
                        try std.testing.expect(result.published);
                        const completion = (try self.broker.display(.completion)).?.data.completion[0];
                        try std.testing.expectEqual(@as(usize, 0), completion.insertion.snippet);
                        try std.testing.expectEqualStrings("${1:done}$0", completion.edits[0].text);
                        try self.document.replace(.{ .start = 1, .end = 5 }, "中");
                        self.stage = .changed;
                        try self.capture(2);
                    },
                    .changed => {
                        try std.testing.expect(result.published);
                        try std.testing.expectEqualStrings("worker hover", (try self.broker.display(.hover)).?.data.hover.text);
                        self.stage = .cancelled;
                        try self.beginRequest(.completion, 1);
                    },
                    .cancelled => {
                        try std.testing.expect(!result.published and result.rejected.? == error.Cancelled);
                        try std.testing.expectEqual(@as(usize, 0), (try self.client.stats()).requests);
                        try self.client.restart();
                        try std.testing.expect((try self.broker.display(.hover)) == null);
                        try self.current_sync.?.close();
                        self.current_sync = null;
                        try self.transport.close();
                        self.transport = try self.client.openTransport();
                        self.handshake = try self.client.beginInitialize();
                        self.stage = .restarted;
                        self.enqueue(.restart);
                    },
                    .restarted => {
                        try std.testing.expect(result.published);
                        self.stage = .queued_stop;
                        try self.beginRequest(.hover, 1);
                    },
                    .queued_stop => {
                        try std.testing.expect(!result.published and result.rejected.? == error.StaleEpoch);
                        try self.current_sync.?.close();
                        self.current_sync = null;
                        self.enqueue(.exit);
                    },
                    .hover => unreachable,
                }
            },
            .exited => self.app.quit(),
            .failed => self.app.quit(),
        }
    }
    fn run(self: *Host) void {
        self.work() catch |err| {
            self.failure = err;
            self.post(.failed);
        };
    }
    fn work(self: *Host) !void {
        var child = std.process.Child.init(&.{self.server}, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        var child_live = true;
        defer if (child_live) {
            _ = child.kill() catch {};
        };
        var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
        defer decoder.deinit();
        while (true) switch (self.next()) {
            .initialize, .restart => |command| {
                if (command == .restart) {
                    var exit = try protocol.wire.notification(allocator, "exit", struct {}{}, .{});
                    defer exit.deinit();
                    try child.stdin.?.writeAll(exit.bytes.?);
                    try expectExit(try child.wait());
                    child_live = false;
                    child = std.process.Child.init(&.{self.server}, allocator);
                    child.stdin_behavior = .Pipe;
                    child.stdout_behavior = .Pipe;
                    child.stderr_behavior = .Inherit;
                    try child.spawn();
                    child_live = true;
                    try decoder.reset();
                }
                self.control_packet = try self.transport.initialize(allocator, self.handshake, .{ .snippets = true });
                self.post(.initialize_prepared);
            },
            .send_initialize => {
                var packet = self.control_packet.?;
                self.control_packet = null;
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.negotiated = try self.transport.negotiate(allocator, self.handshake, try read(&decoder, child.stdout.?));
                self.post(.negotiated);
            },
            .initialized => {
                self.control_packet = try self.transport.initialized(allocator);
                self.post(.ready_prepared);
            },
            .send_initialized => {
                var packet = self.control_packet.?;
                self.control_packet = null;
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.post(.initialized);
            },
            .prepare_sync => {
                const edits: []const d.Replacement = if (self.stage == .changed) &.{.{ .range = .{ .start = 1, .end = 5 }, .text = "中" }} else &.{};
                try self.candidate_sync.?.prepare(allocator, if (self.current_sync) |*previous| previous else null, edits);
                self.post(.sync_prepared);
            },
            .send_sync => {
                var packet = try self.candidate_sync.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.diagnostic = try self.candidate_sync.?.diagnostics(&self.transport, allocator, try read(&decoder, child.stdout.?));
                self.post(.diagnostics);
            },
            .prepare_request => {
                try self.request.?.prepare(allocator);
                self.post(.request_prepared);
            },
            .send_request, .send_cancelled => |command| {
                var packet = try self.request.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                if (command == .send_cancelled) {
                    var cancel = try self.transport.cancellation(allocator, self.request.?.token);
                    defer cancel.deinit();
                    try child.stdin.?.writeAll(cancel.bytes.?);
                }
                self.response = try self.request.?.receive(&self.transport, allocator, try read(&decoder, child.stdout.?));
                if (self.stage == .queued_stop) try self.app.post(.{ .context = self, .call = stopBeforeDelivery });
                self.post(.response);
            },
            .exit => {
                var packet = try protocol.wire.notification(allocator, "exit", struct {}{}, .{});
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                try expectExit(try child.wait());
                child_live = false;
                if (!self.stop_requested.load(.acquire)) self.post(.exited);
                return;
            },
        };
    }
};
fn read(decoder: *codec.Decoder, file: std.fs.File) ![]const u8 {
    // One byte deliberately exercises every header/body boundary without a
    // private unbounded receive queue. No more than one frame is retained.
    var byte: [1]u8 = undefined;
    while (true) {
        if (try file.read(&byte) == 0) return error.UnexpectedEof;
        if ((try decoder.push(&byte)).body) |body| return body;
    }
}
fn expectExit(term: std.process.Child.Term) !void {
    if (term != .Exited or term.Exited != 0) return error.ServerFailed;
}
fn runProtocol(server: []const u8) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Protocol lifecycle", .width = 160, .height = 100 });
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀\r\nxyz", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{ .conversion = .{ .snippets = true } });
    defer client.close() catch unreachable;
    const transport = try client.openTransport();
    var host: Host = .{ .app = app, .document = document, .broker = broker, .client = client, .server = server, .transport = transport, .handshake = try client.beginInitialize() };
    defer host.transport.close() catch unreachable;
    defer {
        if (host.control_packet) |*packet| packet.deinit();
        if (host.response) |*response| if (response.live) {
            _ = response.finish() catch unreachable;
        };
        if (host.request) |*request| if (request.live) {
            var delivery = request.abort(error.Cancelled) catch unreachable;
            _ = delivery.finish() catch unreachable;
        };
        if (host.diagnostic) |*diagnostic| if (diagnostic.live) diagnostic.discard() catch unreachable;
        if (host.candidate_sync) |*sync| if (sync.live) sync.close() catch unreachable;
        if (host.current_sync) |*sync| if (sync.live) sync.close() catch unreachable;
    }
    const worker = try std.Thread.spawn(.{}, Host.run, .{&host});
    const run_result = app.run();
    if (run_result) |_| {} else |_| {
        host.mutex.lock();
        host.stop_requested.store(true, .release);
        host.condition.signal();
        host.mutex.unlock();
    }
    worker.join();
    try run_result;
    if (host.failure) |err| return err;
    try std.testing.expect(window.isClosed());
    try std.testing.expectEqual(@as(usize, 5), host.completed);
    try std.testing.expect(host.posts >= 18);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("language protocol: 2 real child epochs, 5 requests, UTF16 incremental sync, versioned diagnostics, cancel/late and App.post lifecycle passed\n", .{});
}

fn postingBoundary() !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    // This separate fixture uses the already-tested negotiated capabilities;
    // it isolates actual App queue responsibility without a pipe/UI dependency.
    client.phase = .ready;
    client.caps = .{ .completion = true, .hover = true, .sync = .incremental, .open_close = true };
    client.accepted_version = 1;
    client.accepted_text = try document.committedTextVersion();
    var work = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    var delivery = try work.abort(error.TransportFailure);
    const Counter = struct {
        calls: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
        fn forbidden(_: *anyopaque) void {
            unreachable;
        }
    };
    var counter: Counter = .{};
    for (0..256) |_| try app.post(.{ .context = &counter, .call = Counter.call });
    const task: z.Task = .{ .context = &delivery, .call = Counter.forbidden };
    try std.testing.expectError(error.Full, app.post(task));
    try std.testing.expectError(error.RequestsAlive, client.close());
    try client.stop();
    app.quit();
    try std.testing.expectError(error.Closed, app.post(task));
    // Both failed posts retain this exact original Delivery, never duplicate it.
    try std.testing.expect(delivery.live);
    _ = try delivery.finish();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 256), counter.calls);
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
}
pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) return error.ExpectedServerPath;
    try runProtocol(args[1]);
    try postingBoundary();
    try runWorkspace(args[1]);
    try workspacePostingBoundary();
    try runConfiguration(args[1]);
}

const WorkspaceHost = struct {
    const Cmd = enum { initialize, send_initialize, ready, send_ready, reply, send_reply, change, send_change, restart, exit, configuration_candidate, configuration_encode, send_configuration, prepare_sync, send_sync, read_failure };
    const Ev = enum { prepared, negotiated, ready_prepared, request, reply_prepared, replied, change_prepared, done, failed, configuration_candidate, configuration_prepared, sync_prepared, diagnostic, reply_failed };
    app: *z.App,
    client: *protocol.Client,
    server: []const u8,
    transport: session.Transport,
    handshake: session.Handshake,
    work: ?session.WorkspaceWork,
    incoming: ?session.WorkspaceIncoming = null,
    packet: ?codec.Packet = null,
    negotiated: ?session.Negotiated = null,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    command: ?Cmd = .initialize,
    event: Ev = .failed,
    failure: ?anyerror = null,
    replies: usize = 0,
    restarted: bool = false,
    configuration_mode: bool = false,
    configuration_candidate: ?protocol.configuration.Prepared = null,
    configuration_work: ?session.ConfigurationWork = null,
    candidate_sync: ?session.SyncWork = null,
    current_sync: ?session.SyncWork = null,
    diagnostic: ?session.DiagnosticDelivery = null,
    rejected_replies: usize = 0,
    fn enqueue(self: *WorkspaceHost, command: Cmd) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.command == null);
        self.command = command;
        self.condition.signal();
    }
    fn next(self: *WorkspaceHost) Cmd {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.command == null) self.condition.wait(&self.mutex);
        const command = self.command.?;
        self.command = null;
        return command;
    }
    fn post(self: *WorkspaceHost, event: Ev) !void {
        self.event = event;
        try self.app.post(.{ .context = self, .call = delivered });
    }
    fn delivered(ptr: *anyopaque) void {
        const self: *WorkspaceHost = @ptrCast(@alignCast(ptr));
        self.accept() catch |err| {
            self.failure = err;
            self.enqueue(.exit);
        };
    }
    fn accept(self: *WorkspaceHost) !void {
        switch (self.event) {
            .prepared => {
                try self.work.?.validateSend();
                try std.testing.expect(!(try self.work.?.commit()).stale);
                self.enqueue(.send_initialize);
            },
            .negotiated => {
                try self.work.?.close();
                self.work = null;
                try self.client.adoptInitialize(self.negotiated.?);
                if (!self.configuration_mode) try std.testing.expect(self.negotiated.?.capabilities.workspace_registration != null);
                self.enqueue(.ready);
            },
            .ready_prepared => {
                try self.client.commitReady(self.handshake);
                self.enqueue(.send_ready);
            },
            .request => {
                if (self.work) |*work| {
                    try work.close();
                    self.work = null;
                }
                if (self.configuration_work) |*work| {
                    try work.close();
                    self.configuration_work = null;
                }
                try self.incoming.?.capture();
                self.enqueue(.reply);
            },
            .reply_prepared => {
                try self.incoming.?.validateSend();
                try std.testing.expect(!(try self.incoming.?.commit()).stale);
                self.enqueue(.send_reply);
            },
            .reply_failed => {
                try std.testing.expect(self.configuration_mode and self.incoming.?.packet == null and !self.incoming.?.prepared);
                try self.incoming.?.reject();
                self.enqueue(.reply);
            },
            .replied => {
                const rejected = self.incoming.?.rejected;
                try self.incoming.?.close();
                self.incoming = null;
                if (rejected) {
                    self.rejected_replies += 1;
                    self.candidate_sync = try self.client.captureSync(1);
                    self.enqueue(.prepare_sync);
                    return;
                }
                self.replies += 1;
                if (self.configuration_mode) {
                    if (self.replies == 1 and !self.restarted) {
                        self.enqueue(.read_failure);
                        return;
                    }
                    self.candidate_sync = try self.client.captureSync(if (self.replies == 2) 2 else 1);
                    self.enqueue(.prepare_sync);
                    return;
                }
                if (self.replies == 1) {
                    self.work = try self.client.captureWorkspaceChange(.{ .root_uri = "file:///a", .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///c", .name = "C" } } });
                    self.enqueue(.change);
                } else if (!self.restarted) {
                    try self.client.restart();
                    try self.transport.close();
                    self.transport = try self.client.openTransport();
                    self.handshake = try self.client.beginInitialize();
                    self.work = try self.client.captureWorkspaceInitialize(self.handshake);
                    self.restarted = true;
                    self.enqueue(.restart);
                } else self.enqueue(.exit);
            },
            .change_prepared => {
                var send = try self.work.?.beginSend();
                defer send.end();
                try std.testing.expect(!(try send.commit()).stale);
                self.enqueue(.send_change);
            },
            .configuration_candidate => {
                self.configuration_work = try self.client.captureConfigurationChange(&self.configuration_candidate.?);
                self.configuration_candidate = null;
                self.enqueue(.configuration_encode);
            },
            .configuration_prepared => {
                var send = try self.configuration_work.?.beginSend();
                defer send.end();
                _ = try send.commit();
                try std.testing.expectError(error.ConfigurationSynchronizationRequired, self.client.begin(.hover, 0, .{ .start = 0, .end = 1 }));
                try std.testing.expectError(error.StaleVersion, self.client.captureSync(1));
                self.enqueue(.send_configuration);
            },
            .sync_prepared => {
                try self.candidate_sync.?.validateSend();
                _ = try self.candidate_sync.?.commit();
                self.enqueue(.send_sync);
            },
            .diagnostic => {
                try std.testing.expect((try self.diagnostic.?.finish()).published);
                self.diagnostic = null;
                const text = (try self.client.broker.display(.diagnostics)).?.data.diagnostics[0].message;
                try std.testing.expectEqualStrings(if (self.replies == 1) "configuration 1" else "configuration 2", text);
                if (self.current_sync) |*sync| try sync.close();
                self.current_sync = self.candidate_sync;
                self.candidate_sync = null;
                if (self.restarted) {
                    self.enqueue(.exit);
                } else if (self.replies == 1) {
                    self.enqueue(.configuration_candidate);
                } else {
                    try self.current_sync.?.close();
                    self.current_sync = null;
                    try self.client.restart();
                    try self.transport.close();
                    self.transport = try self.client.openTransport();
                    self.handshake = try self.client.beginInitialize();
                    self.work = try self.client.captureWorkspaceInitialize(self.handshake);
                    self.restarted = true;
                    self.enqueue(.restart);
                }
            },
            .done, .failed => self.app.quit(),
        }
    }
    fn run(self: *WorkspaceHost) void {
        self.worker() catch |err| {
            self.failure = err;
            self.post(.failed) catch unreachable;
        };
    }
    fn worker(self: *WorkspaceHost) !void {
        const mode = if (self.configuration_mode) "--configuration" else "--workspace";
        var child = std.process.Child.init(&.{ self.server, mode }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        var live = true;
        defer if (live) {
            _ = child.kill() catch {};
        };
        var decoder = try codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
        defer decoder.deinit();
        while (true) switch (self.next()) {
            .initialize, .restart => |command| {
                if (command == .restart) {
                    var exit = try protocol.wire.notification(allocator, "exit", struct {}{}, .{});
                    defer exit.deinit();
                    try child.stdin.?.writeAll(exit.bytes.?);
                    try expectExit(try child.wait());
                    live = false;
                    child = std.process.Child.init(&.{ self.server, mode }, allocator);
                    child.stdin_behavior = .Pipe;
                    child.stdout_behavior = .Pipe;
                    child.stderr_behavior = .Inherit;
                    try child.spawn();
                    live = true;
                    try decoder.reset();
                }
                try self.work.?.prepare(allocator, .{});
                try self.post(.prepared);
            },
            .send_initialize => {
                var packet = try self.work.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.negotiated = try self.transport.negotiate(allocator, self.handshake, try read(&decoder, child.stdout.?));
                try self.post(.negotiated);
            },
            .ready => {
                self.packet = try self.transport.initialized(allocator);
                try self.post(.ready_prepared);
            },
            .send_ready => {
                var packet = self.packet.?;
                self.packet = null;
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.incoming = try self.transport.workspaceRequest(allocator, try read(&decoder, child.stdout.?));
                try self.post(.request);
            },
            .reply => {
                self.incoming.?.prepare(allocator) catch |err| {
                    if (err != error.ConfigurationCapacityExceeded or !self.configuration_mode or self.incoming.?.rejected) return err;
                    try self.post(.reply_failed);
                    continue;
                };
                try self.post(.reply_prepared);
            },
            .read_failure => {
                self.incoming = try self.transport.workspaceRequest(allocator, try read(&decoder, child.stdout.?));
                try self.post(.request);
            },
            .send_reply => {
                var packet = try self.incoming.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                try self.post(.replied);
            },
            .change => {
                try self.work.?.prepare(allocator, .{});
                try self.post(.change_prepared);
            },
            .send_change => {
                var packet = try self.work.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.incoming = try self.transport.workspaceRequest(allocator, try read(&decoder, child.stdout.?));
                try self.post(.request);
            },
            .configuration_candidate => {
                self.configuration_candidate = try protocol.configuration.Prepared.create(allocator, .{ .settings_json = "{\"version\":2}", .entries = &.{ .{ .section = "language", .value_json = "2" }, .{ .scope_uri = "file:///a/doc", .section = "language", .value_json = "[3,4]" }, .{ .section = "", .value_json = "false" } } }, .{});
                try self.post(.configuration_candidate);
            },
            .configuration_encode => {
                try self.configuration_work.?.prepare(allocator);
                try self.post(.configuration_prepared);
            },
            .send_configuration => {
                var packet = try self.configuration_work.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                const stale_diagnostic = try read(&decoder, child.stdout.?);
                try std.testing.expectError(error.Cancelled, self.current_sync.?.diagnostics(&self.transport, allocator, stale_diagnostic));
                self.incoming = try self.transport.workspaceRequest(allocator, try read(&decoder, child.stdout.?));
                try self.post(.request);
            },
            .prepare_sync => {
                try self.candidate_sync.?.prepareFull(allocator);
                try self.post(.sync_prepared);
            },
            .send_sync => {
                var packet = try self.candidate_sync.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                self.diagnostic = try self.candidate_sync.?.diagnostics(&self.transport, allocator, try read(&decoder, child.stdout.?));
                try self.post(.diagnostic);
            },
            .exit => {
                var packet = try protocol.wire.notification(allocator, "exit", struct {}{}, .{});
                defer packet.deinit();
                try child.stdin.?.writeAll(packet.bytes.?);
                try expectExit(try child.wait());
                live = false;
                try self.post(.done);
                return;
            },
        };
    }
};
fn runWorkspace(server: []const u8) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Workspace protocol lifecycle", .width = 160, .height = 100 });
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{ .root_uri = "file:///a", .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///b", .name = "B" } } }, .{});
    const handshake = try client.beginInitialize();
    var host: WorkspaceHost = .{ .app = app, .client = client, .server = server, .transport = try client.openTransport(), .handshake = handshake, .work = try client.captureWorkspaceInitialize(handshake) };
    defer host.transport.close() catch unreachable;
    defer {
        if (host.incoming) |*incoming| incoming.close() catch unreachable;
        if (host.work) |*work| work.close() catch unreachable;
        if (host.packet) |*packet| packet.deinit();
    }
    const worker = try std.Thread.spawn(.{}, WorkspaceHost.run, .{&host});
    try app.run();
    worker.join();
    if (host.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 3), host.replies);
    try std.testing.expectEqual(@as(?u64, 2), (try client.stats()).workspace_version);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).workspace_incoming);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).workspace_products);
    try std.testing.expect(window.isClosed());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("workspace: real initialize/folders/change/server-request/restart, immutable snapshots and 3 reverse replies passed\n", .{});
}

fn workspacePostingBoundary() !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{});
    var transport = try client.openTransport();
    const handshake = try client.beginInitialize();
    var work = try client.captureWorkspaceInitialize(handshake);
    try work.prepare(allocator, .{});
    _ = try work.commit();
    try work.close();
    try client.adoptInitialize(.{ .token = handshake, .capabilities = .{ .workspace_folders = true, .workspace_changes = true } });
    try client.commitReady(handshake);
    var incoming = try transport.workspaceRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"queued-folders\",\"method\":\"workspace/workspaceFolders\"}");
    try incoming.capture();
    try incoming.prepare(allocator);
    const Counter = struct {
        count: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
        fn forbidden(_: *anyopaque) void {
            unreachable;
        }
    };
    var counter: Counter = .{};
    for (0..256) |_| try app.post(.{ .context = &counter, .call = Counter.call });
    const task: z.Task = .{ .context = &incoming, .call = Counter.forbidden };
    try std.testing.expectError(error.Full, app.post(task));
    try std.testing.expect(incoming.live and incoming.packet != null);
    try client.stop();
    app.quit();
    try std.testing.expectError(error.Closed, app.post(task));
    try transport.close();
    try std.testing.expectError(error.WorkspacesAlive, client.close());
    try incoming.close();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 256), counter.count);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).workspace_incoming);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

fn runConfiguration(server: []const u8) !void {
    // Initial immutable preparation is explicit setup before the App exists;
    // the next candidate is prepared by the real transport worker below.
    var initial = try protocol.configuration.Prepared.create(allocator, .{ .settings_json = "{\"version\":1}", .entries = &.{ .{ .section = "language", .value_json = "1" }, .{ .scope_uri = "file:///a/doc", .section = "language", .value_json = "[3,4]" }, .{ .section = "", .value_json = "false" }, .{ .section = "large", .value_json = "\"" ++ "x" ** 3000 ++ "\"" } } }, .{});
    defer if (initial.snapshot != null) initial.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "Configuration lifecycle", .width = 160, .height = 100 });
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try protocol.Client.create(allocator, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{});
    try client.enableConfiguration(&initial, .{ .response_bytes = 4096 });
    const handshake = try client.beginInitialize();
    var host: WorkspaceHost = .{ .app = app, .client = client, .server = server, .transport = try client.openTransport(), .handshake = handshake, .work = try client.captureWorkspaceInitialize(handshake), .configuration_mode = true };
    defer host.transport.close() catch unreachable;
    defer {
        if (host.incoming) |*incoming| incoming.close() catch unreachable;
        if (host.work) |*work| work.close() catch unreachable;
        if (host.configuration_work) |*work| work.close() catch unreachable;
        if (host.configuration_candidate) |*candidate| candidate.close() catch unreachable;
        if (host.current_sync) |*sync| sync.close() catch unreachable;
        if (host.candidate_sync) |*sync| sync.close() catch unreachable;
        if (host.diagnostic) |*diagnostic| diagnostic.discard() catch unreachable;
        if (host.packet) |*packet| packet.deinit();
    }
    const worker = try std.Thread.spawn(.{}, WorkspaceHost.run, .{&host});
    try app.run();
    worker.join();
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 3), host.replies);
    try std.testing.expectEqual(@as(usize, 1), host.rejected_replies);
    try std.testing.expectEqual(@as(?u64, 2), (try client.stats()).configuration_version);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).workspace_incoming);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).workspace_products);
    try std.testing.expect(window.isClosed() and app.resourceStats().allocated_records == 0);
    std.debug.print("configuration: 2 real epochs, ordered pull/push/re-pull, bounded failure replied once, old same-version diagnostics rejected, higher-version resync passed\n", .{});
}
