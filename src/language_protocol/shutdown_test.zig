const std = @import("std");
const zio = @import("ziggurat_io");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const c = @import("client.zig");
const codec = @import("codec.zig");

fn body(packet: codec.Packet) []const u8 {
    const bytes = packet.bytes.?;
    return bytes[std.mem.indexOf(u8, bytes, "\r\n\r\n").? + 4 ..];
}
fn initialize(client: *c.Client, transport: *c.Transport, allocator: std.mem.Allocator) !void {
    const token = try client.beginInitialize();
    var packet = try transport.initialize(allocator, token, .{});
    defer packet.deinit();
    var admitted = try client.beginControlSend(.{ .initialize = token });
    defer admitted.end();
    try admitted.commit();
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = token.id, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .completionProvider = struct {}{}, .hoverProvider = true } } }, .{});
    defer response.deinit();
    try client.adoptInitialize(try transport.negotiate(allocator, token, body(response)));
    var ready = try transport.initialized(allocator);
    defer ready.deinit();
    var ready_send = try client.beginControlSend(.{ .initialized = token });
    defer ready_send.end();
    try ready_send.commit();
}
fn cleanup(work: *c.ShutdownWork) void {
    _ = work.status(0) catch return;
    work.forceStop() catch |err| {
        if (err != error.StaleEpoch) unreachable;
    };
    work.close() catch unreachable;
}
fn accept(work: *c.ShutdownWork, kind: c.ShutdownKind) !codec.Packet {
    var send = try work.beginSend(kind, 1);
    defer send.end();
    const packet = try send.takePacket();
    try send.commit();
    return packet;
}
fn rejectedResponse(expected: anyerror, attempted: anyerror!c.ShutdownReply) !void {
    if (attempted) |value| {
        var reply = value;
        _ = try reply.finish();
        return error.TestExpectedError;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(expected, err);
    }
}
fn flow(allocator: std.mem.Allocator, remote_error: bool) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    try std.testing.expectError(error.NotReady, client.captureShutdown(.{ .deadline_ns = 100 }));
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    const job = try broker.begin(.hover, 0);
    try job.release();
    defer _ = broker.finish(job.ticket) catch unreachable;
    var owned = try code.OwnedResult.init(allocator, .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "old display" } }, .{});
    defer owned.deinit();
    try broker.publish(job.ticket, &owned);
    const reservation = (try client.stats()).reservation_bytes;
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&work);
    try std.testing.expectError(error.Full, client.captureShutdown(.{ .deadline_ns = 100 }));
    try work.prepare(allocator);
    {
        const message = try codec.Message.parse(allocator, body(work.packet.?), .{});
        defer message.close() catch unreachable;
        const envelope = try message.value();
        try std.testing.expect(envelope == .request and envelope.request.params == null);
        try std.testing.expectEqualStrings("shutdown", envelope.request.method);
    }
    {
        const borrowed = try broker.borrow();
        defer borrowed.end();
        try std.testing.expectError(error.Busy, work.beginSend(.request, 1));
    }
    {
        var rejected = try work.beginSend(.request, 1);
        defer rejected.end();
        try std.testing.expectError(error.Busy, client.stop());
        try std.testing.expectError(error.Busy, broker.borrow());
    }
    try std.testing.expectEqual(c.Phase.ready, (try client.stats()).phase);
    try std.testing.expect((try broker.display(.hover)) != null and work.packet != null);
    var request = try accept(&work, .request);
    defer request.deinit();
    try std.testing.expectEqual(c.Phase.awaiting_shutdown, (try client.stats()).phase);
    try std.testing.expect((try broker.display(.hover)) == null);
    try std.testing.expectError(error.NotReady, client.begin(.hover, 0, .{ .start = 0, .end = 0 }));
    try std.testing.expectError(error.InvalidPhase, work.prepareExit(allocator));
    try std.testing.expectError(error.ShutdownInProgress, work.close());
    var wrong = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.id + 1, .result = null }, .{});
    defer wrong.deinit();
    try rejectedResponse(error.UnexpectedResponse, work.receive(&transport, allocator, body(wrong)));
    var invalid = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.id, .result = 1 }, .{});
    defer invalid.deinit();
    try rejectedResponse(error.InvalidShutdownResult, work.receive(&transport, allocator, body(invalid)));
    var response = if (remote_error) try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.id, .@"error" = .{ .code = -32603, .message = "cleanup failed" } }, .{}) else try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.id, .result = null }, .{});
    defer response.deinit();
    var reply = try work.receive(&transport, allocator, body(response));
    defer if (reply.live) {
        _ = reply.finish() catch unreachable;
    };
    try std.testing.expectError(error.ShutdownReplyPending, work.close());
    try std.testing.expectError(error.ShutdownAlive, client.close());
    const adopted = try reply.finish();
    try std.testing.expect(adopted.acknowledged and adopted.rejected == null);
    try std.testing.expectEqual(if (remote_error) @as(?i32, -32603) else null, adopted.remote_code);
    try std.testing.expectError(error.DeliveryClosed, reply.finish());
    try work.prepareExit(allocator);
    {
        var rejected = try work.beginSend(.exit, 1);
        rejected.end();
        try std.testing.expectEqual(c.Phase.shutdown_replied, (try client.stats()).phase);
    }
    var exit = try accept(&work, .exit);
    defer exit.deinit();
    const message = try codec.Message.parse(allocator, body(exit), .{});
    defer message.close() catch unreachable;
    const notification = (try message.value()).notification;
    try std.testing.expectEqualStrings("exit", notification.method);
    try std.testing.expect(notification.params == null);
    try std.testing.expectEqual(c.Phase.stopped, (try client.stats()).phase);
    try std.testing.expect(!try work.expire(100));
    try work.close();
    try std.testing.expectEqual(reservation, (try client.stats()).reservation_bytes);
    try std.testing.expectError(error.WorkClosed, work.prepare(allocator));
}

test "shutdown null and error replies authorize exit only after owner adoption" {
    try flow(std.testing.allocator, false);
    try flow(std.testing.allocator, true);
}
test "shutdown flow recovers every allocation failure without losing its physical responsibility" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, flow, .{false});
}
test "deadline force stop and restart preserve queued reply and nonwrapping physical slot" {
    const allocator = std.testing.allocator;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    var old = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&old);
    try old.prepare(allocator);
    var packet = try accept(&old, .request);
    defer packet.deinit();
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = old.id, .result = null }, .{});
    defer response.deinit();
    var reply = try old.receive(&transport, allocator, body(response));
    defer if (reply.live) {
        _ = reply.finish() catch unreachable;
    };
    try client.restart();
    var current = try client.openTransport();
    defer current.close() catch unreachable;
    try initialize(client, &current, allocator);
    try std.testing.expectError(error.StaleEpoch, old.forceStop());
    try std.testing.expectError(error.StaleEpoch, old.expire(100));
    try std.testing.expectEqual(c.Phase.ready, (try client.stats()).phase);
    try std.testing.expectError(error.Full, client.captureShutdown(.{ .deadline_ns = 100 }));
    try std.testing.expectError(error.ShutdownReplyPending, old.close());
    const stale = try reply.finish();
    try std.testing.expect(!stale.acknowledged and stale.rejected.? == error.StaleEpoch);
    const copy = old;
    try old.close();
    var next = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&next);
    var obsolete = copy;
    try std.testing.expectError(error.StaleShutdown, obsolete.prepare(allocator));
    try next.prepare(allocator);
    try std.testing.expectError(error.ShutdownDeadlineExpired, next.beginSend(.request, 100));
    try std.testing.expectEqual(c.Phase.ready, (try client.stats()).phase);
    try std.testing.expect(!try next.expire(99));
    try std.testing.expect(try next.expire(100));
    try std.testing.expectEqual(c.Phase.stopped, (try client.stats()).phase);
    try next.close();
}

test "an abort is one physical reply and never fabricates a shutdown acknowledgement" {
    const allocator = std.testing.allocator;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&work);
    try work.prepare(allocator);
    var packet = try accept(&work, .request);
    defer packet.deinit();
    var reply = try work.abort(error.TransportFailure);
    defer if (reply.live) {
        _ = reply.finish() catch unreachable;
    };
    try std.testing.expectError(error.ShutdownReplyPending, work.close());
    const rejected = try reply.finish();
    try std.testing.expect(!rejected.acknowledged and rejected.rejected.? == error.TransportFailure);
    try std.testing.expectError(error.InvalidPhase, work.prepareExit(allocator));
    try std.testing.expectError(error.ShutdownInProgress, work.close());
    try work.forceStop();
    try work.close();
}

const ForeignProbe = struct {
    client: *c.Client,
    broker: *code.Broker,
    work: ?*c.ShutdownWork = null,
    action: enum { none, invalidate, closing, cancel_alloc, cancel_free } = .none,
    calls: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.action == .cancel_alloc) {
            self.calls += 1;
            self.action = .none;
            self.client.stop() catch unreachable;
        }
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (self.action) {
            .none, .cancel_alloc => {},
            .cancel_free => {
                self.calls += 1;
                self.action = .none;
                self.client.stop() catch unreachable;
            },
            .invalidate, .closing => {
                self.calls += 1;
                std.testing.expectError(error.Busy, self.client.close()) catch unreachable;
                std.testing.expectError(error.Busy, self.client.restart()) catch unreachable;
                std.testing.expectError(error.Busy, self.client.stats()) catch unreachable;
                std.testing.expectError(error.Busy, self.work.?.close()) catch unreachable;
                if (self.action == .invalidate) {
                    std.testing.expectEqual(c.Phase.awaiting_shutdown, self.client.phase) catch unreachable;
                    std.testing.expectError(error.Busy, self.broker.borrow()) catch unreachable;
                    for (self.broker.stored) |item| std.testing.expect(item == null) catch unreachable;
                    for (self.broker.current) |serial| std.testing.expectEqual(@as(u64, 0), serial) catch unreachable;
                    std.testing.expect(self.client.shutdown_control.active()) catch unreachable;
                }
            },
        }
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
test "accepted shutdown invalidates all displays before foreign free and retains both gates" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var probe: ForeignProbe = .{ .client = client, .broker = broker };
    const job = try broker.begin(.hover, 0);
    try job.release();
    defer _ = broker.finish(job.ticket) catch unreachable;
    var result = try code.OwnedResult.init(probe.allocator(), .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "retained hover" } }, .{});
    defer result.deinit();
    try broker.publish(job.ticket, &result);
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&work);
    probe.work = &work;
    try work.prepare(probe.allocator());
    var send = try work.beginSend(.request, 1);
    defer send.end();
    probe.action = .invalidate;
    try send.commit();
    probe.action = .none;
    try std.testing.expect(probe.calls > 0);
    try client.stop();
    probe.calls = 0;
    probe.action = .closing;
    try work.close();
    probe.action = .none;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "worker encoding and final JSON free observe force cancellation without publishing a reply" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |on_free| {
        const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
        defer document.close() catch unreachable;
        const broker = try code.Broker.create(a, document, .{});
        defer broker.close() catch unreachable;
        const client = try c.Client.create(a, broker, "file:///a", "zig", .{});
        defer client.close() catch unreachable;
        var transport = try client.openTransport();
        defer transport.close() catch unreachable;
        try initialize(client, &transport, a);
        var work = try client.captureShutdown(.{ .deadline_ns = 100 });
        defer cleanup(&work);
        var probe: ForeignProbe = .{ .client = client, .broker = broker, .work = &work };
        if (on_free) {
            try work.prepare(a);
            var packet = try accept(&work, .request);
            defer packet.deinit();
            var response = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.id, .result = @as(?u8, null) }, .{});
            defer response.deinit();
            probe.action = .cancel_free;
            try std.testing.expectError(error.Cancelled, work.receive(&transport, probe.allocator(), body(response)));
            try std.testing.expectEqual(@import("shutdown.zig").Stage.sent, (try work.status(1)).stage);
        } else {
            probe.action = .cancel_alloc;
            try std.testing.expectError(error.Cancelled, work.prepare(probe.allocator()));
            try std.testing.expect(work.packet == null);
        }
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        try work.close();
    }
}

test "shutdown budget and generation failures precede publication and reserve no physical control" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    const before = client.reservation;
    const identifier = client.next_id;
    const maximum = client.limits.bytes;
    client.limits.bytes = before;
    try std.testing.expectError(error.CapacityExceeded, client.captureShutdown(.{ .deadline_ns = 100 }));
    try std.testing.expectEqual(identifier, client.next_id);
    try std.testing.expect(!client.shutdown_control.active());
    client.limits.bytes = maximum;
    client.shutdown_control.serial = @import("shutdown.zig").max_serial;
    try std.testing.expectError(error.IdExhausted, client.captureShutdown(.{ .deadline_ns = 100 }));
    client.shutdown_control.serial = 0;
    client.next_id = std.math.maxInt(i32);
    try std.testing.expectError(error.IdExhausted, client.captureShutdown(.{ .deadline_ns = 100 }));
    client.next_id = identifier;
    var work = try client.captureShutdown(.{ .deadline_ns = 100, .limits = .{ .work_bytes = 511 } });
    defer cleanup(&work);
    try std.testing.expectError(error.ShutdownWorkExceeded, work.prepare(a));
    try std.testing.expect(work.packet == null);
    try std.testing.expectEqual(@as(usize, 0), work.work_spent);
    try work.close();
    try std.testing.expectEqual(before, client.reservation);
}

test "force stop does not wait for a worker or release its control before exclusive retirement" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&work);
    const Worker = struct {
        work: *c.ShutdownWork,
        mutex: zio.Mutex = .{},
        condition: zio.Condition = .{},
        entered: bool = false,
        resumed: bool = false,
        result: ?anyerror = null,
        owner_rejected: bool = false,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.mutex.lock();
            self.entered = true;
            self.condition.signal();
            while (!self.resumed) self.condition.wait(&self.mutex);
            self.mutex.unlock();
            return std.heap.page_allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.heap.page_allocator.rawFree(bytes, alignment, ra);
        }
        fn run(self: *@This()) void {
            if (self.work.forceStop()) |_| return else |err| self.owner_rejected = err == error.WrongThread;
            self.work.prepare(self.allocator()) catch |err| {
                self.result = err;
            };
        }
    };
    var worker: Worker = .{ .work = &work };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    worker.mutex.lock();
    while (!worker.entered) worker.condition.wait(&worker.mutex);
    worker.mutex.unlock();
    // The worker cannot exit until this owner operation has returned.
    const close_result = work.close();
    const client_result = client.close();
    const force_result = work.forceStop();
    worker.mutex.lock();
    worker.resumed = true;
    worker.condition.signal();
    worker.mutex.unlock();
    thread.join();
    try std.testing.expectError(error.WorkerRunning, close_result);
    try std.testing.expectError(error.ShutdownAlive, client_result);
    try force_result;
    try std.testing.expect(worker.owner_rejected);
    try std.testing.expectEqual(error.Cancelled, worker.result.?);
    try std.testing.expect(work.packet == null);
    try work.close();
}

test "full ordinary request slots do not block shutdown and late delivery retains physical responsibility" {
    const a = std.testing.allocator;
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a", "zig", .{ .pending = 1 });
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepare(a, null, &.{});
    _ = try sync.commit();
    var ordinary = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    defer if (ordinary.live) {
        var retired = ordinary.abort(error.Cancelled) catch unreachable;
        _ = retired.finish() catch unreachable;
    };
    try ordinary.prepare(a);
    _ = try client.commitSend(ordinary.token);
    try std.testing.expectError(error.Full, client.begin(.hover, 0, .{ .start = 0, .end = 1 }));
    var work = try client.captureShutdown(.{ .deadline_ns = 100 });
    defer cleanup(&work);
    try work.prepare(a);
    var send = try work.beginSend(.request, 1);
    try send.commit();
    try std.testing.expect(try ordinary.isCancelled());
    try std.testing.expectError(error.NotReady, client.beginControlSend(.{ .cancellation = ordinary.token }));
    var response = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = ordinary.token.id, .result = .{ .contents = "late hover" } }, .{});
    defer response.deinit();
    var late = try ordinary.receive(&transport, a, body(response));
    defer if (late.live) {
        _ = late.finish() catch unreachable;
    };
    try std.testing.expectEqual(@as(usize, 1), (try client.stats()).requests);
    const rejected = try late.finish();
    try std.testing.expect(!rejected.published and rejected.rejected.? == error.Cancelled);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
    const borrow = try broker.borrow();
    defer borrow.end();
    try std.testing.expect(try borrow.display(.hover) == null);
}
