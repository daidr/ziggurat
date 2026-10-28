const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const code = @import("ziggurat_code_editor");
const p = @import("ziggurat_language_protocol");
const allocator = std.heap.page_allocator;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 300, .height = 150 };
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const Host = struct {
    const Cmd = enum { initialize, send_initialize, ready, send_ready, sync, completion, resolve, exit };
    const Ev = enum { initialize_prepared, initialized, ready_prepared, ready, sync_prepared, sync_sent, completion_prepared, completion_received, resolve_prepared, resolve_received, done, failed };
    app: *z.App,
    window: z.Window,
    document: *d.Document,
    adapter: *editing.Adapter,
    broker: *code.Broker,
    client: *p.Client,
    presenter: ?*code.Presenter,
    context: ui.Context = undefined,
    parameters: editing.Parameters,
    server: []const u8,
    transport: p.Transport,
    handshake: p.session.Handshake,
    negotiated: ?p.session.Negotiated = null,
    sync: ?p.SyncWork = null,
    request: ?p.Work = null,
    delivery: ?p.Delivery = null,
    resolve: ?p.ResolveWork = null,
    resolved: ?p.ResolveDelivery = null,
    packet: ?p.codec.Packet = null,
    mutex: zio.Mutex = .{},
    condition: zio.Condition = .{},
    command: ?Cmd = .initialize,
    event: Ev = .failed,
    accepted: bool = false,
    case: usize = 0,
    version: i32 = 1,
    failure: ?anyerror = null,
    probe_armed: bool = false,
    probe_hits: usize = 0,
    fn resultAllocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.probe_armed) {
            std.debug.assert(std.Thread.getCurrentId() == self.app.owner);
            self.probe_armed = false;
            std.testing.expectError(error.Busy, self.client.close()) catch unreachable;
            std.testing.expectError(error.Busy, self.broker.borrow()) catch unreachable;
            std.testing.expectError(error.Busy, self.presenter.?.close()) catch unreachable;
            const published = self.broker.stored[@backingInt(code.Kind.completion)].?.result.data.completion[0];
            std.testing.expectEqualStrings("resolved type", published.detail) catch unreachable;
            // A genuine subsequent edit during old-result disposal cannot turn
            // a published refinement into a retryable precommit error.
            self.document.replace(.{ .start = 0, .end = 0 }, "!") catch unreachable;
            self.probe_hits += 1;
        }
        allocator.rawFree(bytes, alignment, ra);
    }
    fn noop(_: *anyopaque) void {}
    fn unexpectedDelivery(_: *anyopaque) void {
        @panic("rejected delivery task executed");
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        if (self.presenter) |presenter| presenter.draw(frame, bounds, .{}) catch |err| {
            self.failure = err;
        };
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn cleanup(self: *@This()) void {
        if (self.request) |*work| if (work.live) {
            var value = work.abort(error.Cancelled) catch unreachable;
            _ = value.finish() catch unreachable;
        };
        if (self.delivery) |*value| if (value.live) {
            _ = value.finish() catch unreachable;
        };
        if (self.resolve) |*work| if (work.live) {
            var value = work.abort(error.Cancelled) catch unreachable;
            _ = value.finish(null) catch unreachable;
        };
        if (self.resolved) |*value| if (value.live) {
            _ = value.finish(null) catch unreachable;
        };
        if (self.sync) |*value| value.close() catch unreachable;
        if (self.packet) |*value| value.deinit();
    }
    fn enqueue(self: *@This(), command: Cmd) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.command == null);
        self.command = command;
        self.condition.signal();
    }
    fn next(self: *@This()) Cmd {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.command == null) self.condition.wait(&self.mutex);
        const value = self.command.?;
        self.command = null;
        return value;
    }
    fn post(self: *@This(), event: Ev) !void {
        self.event = event;
        // Case 4 deliberately leaves the owner queue full of no-op tasks when
        // it hands the next command to this worker. Full transfers nothing, so
        // the worker backs off until the owner drains them; Closed still ends.
        while (true) {
            self.app.post(.{ .context = self, .call = delivered }) catch |err| {
                if (err != error.Full) return err;
                zio.sleep(std.time.ns_per_ms);
                continue;
            };
            return;
        }
    }
    fn delivered(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.accept() catch |err| {
            self.failure = err;
            self.enqueue(.exit);
        };
    }
    fn source(self: *@This()) !void {
        self.request = try self.client.begin(.completion, 0, .{ .start = 0, .end = 0 });
        self.accepted = false;
        self.enqueue(.completion);
    }
    fn accept(self: *@This()) !void {
        switch (self.event) {
            .initialize_prepared => {
                try self.client.commitInitialize(self.handshake);
                self.enqueue(.send_initialize);
            },
            .initialized => {
                try self.client.adoptInitialize(self.negotiated.?);
                self.enqueue(.ready);
            },
            .ready_prepared => {
                try self.client.commitReady(self.handshake);
                self.enqueue(.send_ready);
            },
            .ready => {
                self.sync = try self.client.captureSync(self.version);
                self.accepted = false;
                self.enqueue(.sync);
            },
            .sync_prepared => {
                try self.sync.?.validateSend();
                _ = try self.sync.?.commit();
                self.accepted = true;
                self.enqueue(.sync);
            },
            .sync_sent => {
                try self.sync.?.close();
                self.sync = null;
                try self.source();
            },
            .completion_prepared => {
                try self.client.validateSend(self.request.?.token);
                _ = try self.client.commitSend(self.request.?.token);
                self.accepted = true;
                self.enqueue(.completion);
            },
            .completion_received => {
                try std.testing.expect((try self.delivery.?.finish()).published);
                self.delivery = null;
                self.request = null;
                try self.presenter.?.prepare(bounds, self.parameters);
                const choice = try self.presenter.?.completionChoice();
                self.resolve = try self.client.beginResolve(allocator, choice);
                self.accepted = false;
                self.enqueue(.resolve);
            },
            .resolve_prepared => {
                try self.client.validateSend(self.resolve.?.token);
                _ = try self.client.commitSend(self.resolve.?.token);
                self.accepted = true;
                self.enqueue(.resolve);
            },
            .resolve_received => {
                self.resolve = null;
                const revision = try self.document.version();
                if (self.case == 4) {
                    var gate = try self.presenter.?.beginCompletionRefinement(self.resolved.?.choice);
                    try std.testing.expectError(error.Busy, self.resolved.?.finish(self.presenter));
                    try std.testing.expect(self.resolved.?.live);
                    gate.end();
                    var full = false;
                    for (0..1024) |_| self.app.post(.{ .context = self, .call = noop }) catch |err| {
                        if (err != error.Full) return err;
                        full = true;
                        break;
                    };
                    try std.testing.expect(full);
                    try std.testing.expectError(error.Full, self.app.post(.{ .context = &self.resolved.?, .call = unexpectedDelivery }));
                    try std.testing.expect(self.resolved.?.live);
                    self.probe_armed = true;
                }
                switch (self.case) {
                    0 => {
                        _ = try self.presenter.?.handleEvent(.{ .key_input = .{ .key = .down } }, bounds, self.parameters);
                        _ = try self.presenter.?.handleEvent(.{ .key_input = .{ .key = .up } }, bounds, self.parameters);
                    },
                    1 => {
                        _ = try self.presenter.?.handleEvent(.{ .focus = false }, bounds, self.parameters);
                    },
                    2 => {
                        try self.document.setComposition("x", .{ .anchor = 1, .caret = 1 });
                    },
                    3 => {
                        try self.document.replace(.{ .start = 0, .end = 0 }, "x");
                    },
                    7 => {
                        _ = try self.window.destroy();
                        try self.presenter.?.close();
                        self.presenter = null;
                        self.case += 1;
                        self.enqueue(.exit);
                        return; // Owner consumes the retained delivery after shutdown.
                    },
                    else => {},
                }
                const outcome = try self.resolved.?.finish(self.presenter);
                self.resolved = null;
                if (self.case == 4) {
                    try std.testing.expect(outcome.published and outcome.stale_after_commit);
                    try std.testing.expectEqual(@as(usize, 1), self.probe_hits);
                    try std.testing.expectEqual(revision + 1, try self.document.version());
                } else if (self.case == 6) {
                    try std.testing.expect(outcome.published and !outcome.stale_after_commit);
                    try std.testing.expectEqual(revision, try self.document.version());
                    const item = (try self.broker.display(.completion)).?.data.completion[0];
                    try std.testing.expectEqualStrings("resolved type", item.detail);
                    try std.testing.expectEqualStrings("owned documentation", item.documentation);
                    try self.presenter.?.prepare(bounds, self.parameters);
                    if (self.case == 6) {
                        const accepted = try self.presenter.?.acceptCompletionOutcome(0);
                        try std.testing.expect(accepted.snippet_active and !accepted.stale_after_commit);
                        try std.testing.expectEqual(revision + 1, try self.document.version());
                        try self.presenter.?.cancelSnippet();
                        try std.testing.expect((try self.adapter.undo()).changed);
                    }
                } else try std.testing.expect(!outcome.published);
                if (self.case == 2) _ = try self.document.cancelComposition();
                self.case += 1;
                if (self.case == 8) {
                    self.enqueue(.exit);
                    return;
                }
                if (self.case == 4 or self.case == 5 or self.case == 7) {
                    self.version += 1;
                    self.sync = try self.client.captureSync(self.version);
                    self.accepted = false;
                    self.enqueue(.sync);
                } else try self.source();
            },
            .done, .failed => self.app.quit(),
        }
    }
    fn worker(self: *@This()) void {
        self.runWorker() catch |err| {
            self.failure = err;
            self.post(.failed) catch |post_error| {
                std.debug.assert(post_error == error.Closed);
            };
        };
    }
    fn runWorker(self: *@This()) !void {
        var child = try zio.spawn(.{ .argv = &.{ self.server, "--resolve" }, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
        var live = true;
        defer if (live) {
            child.kill(zio.io());
        };
        var decoder = try p.codec.Decoder.init(allocator, .{ .body_bytes = 16384 });
        defer decoder.deinit();
        while (true) switch (self.next()) {
            .initialize => {
                self.packet = try self.transport.initialize(allocator, self.handshake, .{ .snippets = true });
                try self.post(.initialize_prepared);
            },
            .send_initialize => {
                var packet = self.packet.?;
                self.packet = null;
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                self.negotiated = try self.transport.negotiate(allocator, self.handshake, try read(&decoder, child.stdout.?));
                try self.post(.initialized);
            },
            .ready => {
                self.packet = try self.transport.initialized(allocator);
                try self.post(.ready_prepared);
            },
            .send_ready => {
                var packet = self.packet.?;
                self.packet = null;
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                try self.post(.ready);
            },
            .sync => if (!self.accepted) {
                try self.sync.?.prepareFull(allocator);
                try self.post(.sync_prepared);
            } else {
                var packet = try self.sync.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                try self.post(.sync_sent);
            },
            .completion => if (!self.accepted) {
                try self.request.?.prepare(allocator);
                try self.post(.completion_prepared);
            } else {
                var packet = try self.request.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                self.delivery = try self.request.?.receive(&self.transport, self.resultAllocator(), try read(&decoder, child.stdout.?));
                try self.post(.completion_received);
            },
            .resolve => if (!self.accepted) {
                try self.resolve.?.prepare();
                try self.post(.resolve_prepared);
            } else {
                var packet = try self.resolve.?.takePacket();
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                const response = try read(&decoder, child.stdout.?);
                self.resolved = self.resolve.?.receive(&self.transport, response) catch |err| blk: {
                    if (err != error.UnsupportedResolvedProperty or self.case != 5) return err;
                    break :blk try self.resolve.?.abort(err);
                };
                try self.post(.resolve_received);
            },
            .exit => {
                var packet = try p.wire.notification(allocator, "exit", struct {}{}, .{});
                defer packet.deinit();
                try child.stdin.?.writeStreamingAll(zio.io(), packet.bytes.?);
                const status = try child.wait(zio.io());
                live = false;
                if (self.failure == null and (status != .exited or status.exited != 0)) return error.ServerFailed;
                // Closing the last window can complete App shutdown before the
                // child exits. The owner joins this worker before reading state.
                self.post(.done) catch |err| if (err != error.Closed) return err;
                return;
            },
        };
    }
};
fn read(decoder: *p.codec.Decoder, file: std.Io.File) ![]const u8 {
    var byte: [1]u8 = undefined;
    while (true) {
        if (try zio.read(file, &byte) == 0) return error.UnexpectedEof;
        const progress = try decoder.push(&byte);
        if (progress.body) |body| return body;
    }
}
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len != 2) return error.MissingServer;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 170 });
    defer _ = window.destroy() catch unreachable;
    const document = try d.Document.create(allocator, app.owner, "abc", .{});
    defer document.close() catch unreachable;
    const engine = try text.Engine.create(allocator, app.owner, .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try p.Client.create(allocator, broker, "file:///resolve", "zig", .{ .conversion = .{ .snippets = true } });
    defer client.close() catch unreachable;
    try client.enableCompletionResolve(.{});
    const presenter = try code.Presenter.create(allocator, broker, adapter, engine, window, .{});
    var host: Host = .{ .app = app, .window = window, .document = document, .adapter = adapter, .broker = broker, .client = client, .presenter = presenter, .server = args[1], .transport = try client.openTransport(), .handshake = try client.beginInitialize(), .parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = bounds.width }, .scale = if (builtin.os.tag == .linux) @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?)) else 1 } };
    defer host.transport.close() catch unreachable;
    defer if (host.presenter) |current| current.close() catch unreachable;
    try presenter.enableCompletionRefinement();
    try presenter.enableSnippets(.{});
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    try host.context.attach(window);
    try presenter.prepare(bounds, host.parameters);
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    const thread = try std.Thread.spawn(.{}, Host.worker, .{&host});
    try app.run();
    thread.join();
    defer host.cleanup();
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), (try client.stats()).requests);
    try std.testing.expectError(error.Closed, app.post(.{ .context = &host.resolved.?, .call = Host.unexpectedDelivery }));
    try std.testing.expect(host.resolved.?.live);
    try std.testing.expect(!(try host.resolved.?.finish(null)).published);
    host.resolved = null;
    try std.testing.expectEqual(@as(usize, 8), host.case);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
    try std.testing.expect(window.isClosed() and app.resourceStats().allocated_records == 0);
    std.debug.print("completion resolve: real child, lossless data, selection/focus/IME/Doc/readonly/close gates, metadata-only adoption and original snippet undo passed\n", .{});
}
