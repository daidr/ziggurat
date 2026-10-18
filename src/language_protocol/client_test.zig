const std = @import("std");
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
    try client.commitInitialize(token);
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = token.id, .result = .{ .capabilities = .{ .positionEncoding = "utf-16", .textDocumentSync = .{ .openClose = true, .change = 2 }, .completionProvider = struct {}{}, .hoverProvider = true } } }, .{});
    defer response.deinit();
    try client.adoptInitialize(try transport.negotiate(allocator, token, body(response)));
    var ready = try transport.initialized(allocator);
    defer ready.deinit();
    try client.commitReady(token);
}
fn cleanup(work: *c.Work) void {
    if (work.live) {
        var delivery = work.abort(error.Cancelled) catch unreachable;
        _ = delivery.finish() catch unreachable;
    }
}
fn lifecycle(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀\r\nxyz", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(allocator, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepare(allocator, null, &.{});
    try std.testing.expectEqual(@as(?i32, null), (try client.stats()).server_version);
    try sync.validateSend();
    _ = try sync.commit();
    try std.testing.expectEqual(@as(?i32, 1), (try client.stats()).server_version);
    var work = try client.begin(.completion, 5, .{ .start = 1, .end = 5 });
    defer cleanup(&work);
    try work.prepare(allocator);
    try client.validateSend(work.token);
    // Full/rejected host queue makes no state transition; same packet retries.
    try client.validateSend(work.token);
    try std.testing.expect(!(try client.commitSend(work.token)).stale);
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{ .isIncomplete = true, .items = .{.{ .label = "choice", .insertText = "done" }} } }, .{});
    defer response.deinit();
    var delivery = try work.receive(&transport, allocator, body(response));
    defer if (delivery.live) {
        _ = delivery.finish() catch unreachable;
    };
    const outcome = try delivery.finish();
    try std.testing.expect(outcome.published and outcome.incomplete);
    try std.testing.expectEqualStrings("done", (try broker.display(.completion)).?.data.completion[0].edits[0].text);
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    var diagnostic = try sync.diagnostics(&transport, allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///fixture.zig\",\"version\":1,\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":3}},\"message\":\"owned warning\",\"severity\":2}]}}");
    defer if (diagnostic.live) {
        diagnostic.discard() catch unreachable;
    };
    try std.testing.expect((try diagnostic.finish()).published);
    try std.testing.expectEqualStrings("owned warning", (try broker.display(.diagnostics)).?.data.diagnostics[0].message);
    try client.restart();
    try std.testing.expect((try broker.display(.completion)) == null and (try broker.display(.diagnostics)) == null);
    var fresh_transport = try client.openTransport();
    defer fresh_transport.close() catch unreachable;
    try initialize(client, &fresh_transport, allocator);
    var next_sync = try client.captureSync(1);
    defer next_sync.close() catch unreachable;
    try next_sync.prepare(allocator, null, &.{});
    _ = try next_sync.commit();
    var fresh = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    defer cleanup(&fresh);
    try fresh.prepare(allocator);
    _ = try client.commitSend(fresh.token);
    var hover = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = fresh.token.id, .result = .{ .contents = "new epoch" } }, .{});
    defer hover.deinit();
    var arrived = try fresh.receive(&fresh_transport, allocator, body(hover));
    defer if (arrived.live) {
        _ = arrived.finish() catch unreachable;
    };
    try std.testing.expect((try arrived.finish()).published);
    try std.testing.expectEqualStrings("new epoch", (try broker.display(.hover)).?.data.hover.text);
}
test "owner adopts worker products without scanning and restart revokes finished displays" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lifecycle, .{});
}
test "accepted send keeps physical pending across document mutation cancellation stop and late delivery" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{ .pending = 1, .diagnostics = 1 });
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepare(a, null, &.{});
    _ = try sync.commit();
    var work = try client.begin(.completion, 0, .{ .start = 0, .end = 0 });
    defer cleanup(&work);
    try work.prepare(a);
    try client.validateSend(work.token);
    // Host accepted the packet, then an allocator/callback modified the Doc.
    try doc.replace(.{ .start = 0, .end = 1 }, "A");
    try std.testing.expect((try client.commitSend(work.token)).stale);
    try std.testing.expectEqual(@as(usize, 1), (try client.stats()).requests);
    try std.testing.expectError(error.RequestsAlive, client.close());
    var cancel = try transport.cancellation(a, work.token);
    defer cancel.deinit();
    const cancel_message = try codec.Message.parse(a, body(cancel), .{});
    defer cancel_message.close() catch unreachable;
    try std.testing.expectEqualStrings("$/cancelRequest", (try cancel_message.value()).notification.method);
    try client.restart();
    try std.testing.expectError(error.NotReady, client.begin(.hover, 0, .{ .start = 0, .end = 0 }));
    var response = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{} }, .{});
    defer response.deinit();
    var delivery = try work.receive(&transport, a, body(response));
    defer if (delivery.live) {
        _ = delivery.finish() catch unreachable;
    };
    try std.testing.expect(!(try delivery.finish()).published);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
    try client.stop();
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    try std.testing.expectError(error.ReadersAlive, client.close());
}

fn setup(client: *c.Client, transport: *c.Transport, allocator: std.mem.Allocator) !c.SyncWork {
    try initialize(client, transport, allocator);
    var sync = try client.captureSync(1);
    errdefer sync.close() catch unreachable;
    try sync.prepare(allocator, null, &.{});
    _ = try sync.commit();
    return sync;
}
test "queued old epoch result owns its slot and cannot publish into a restarted service" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{ .pending = 1 });
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    var sync = try setup(client, &transport, a);
    defer sync.close() catch unreachable;
    var work = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    defer cleanup(&work);
    try work.prepare(a);
    _ = try client.commitSend(work.token);
    try std.testing.expectError(error.UnexpectedResponse, work.receive(&transport, a, "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":null}"));
    try std.testing.expect(work.live and broker.outstanding == 1);
    var packet = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{ .contents = "old" } }, .{});
    defer packet.deinit();
    var delivery = try work.receive(&transport, a, body(packet));
    defer if (delivery.live) {
        _ = delivery.finish() catch unreachable;
    };
    try client.restart();
    var replacement = try client.openTransport();
    defer replacement.close() catch unreachable;
    var new_sync = try setup(client, &replacement, a);
    defer new_sync.close() catch unreachable;
    try std.testing.expectError(error.Full, client.begin(.hover, 0, .{ .start = 0, .end = 1 }));
    const outcome = try delivery.finish();
    try std.testing.expect(!outcome.published and outcome.rejected.? == error.StaleEpoch);
    var fresh = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    defer cleanup(&fresh);
    try fresh.prepare(a);
    _ = try doc.setSelection(.{ .anchor = 1, .caret = 1 });
    // Selection-only changes still preserve hover's committed-text authority.
    try client.validateSend(fresh.token);
    try std.testing.expect(!(try client.commitSend(fresh.token)).stale);
    var reply = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = fresh.token.id, .result = .{ .contents = "fresh" } }, .{});
    defer reply.deinit();
    var arrived = try fresh.receive(&replacement, a, body(reply));
    try std.testing.expect((try arrived.finish()).published);
}
test "diagnostic queue count is bounded and owned result survives source Reader close" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{ .diagnostics = 1 });
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    var sync = try setup(client, &transport, a);
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///fixture.zig\",\"version\":1,\"diagnostics\":[]}}";
    var delivery = try sync.diagnostics(&transport, a, json);
    try std.testing.expectError(error.Full, sync.diagnostics(&transport, a, json));
    try std.testing.expectError(error.ReadersAlive, client.close());
    try sync.close();
    try transport.close();
    try std.testing.expectError(error.DeliveriesAlive, client.close());
    try client.stop();
    const outcome = try delivery.finish();
    try std.testing.expect(outcome.rejected.? == error.StaleEpoch);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).diagnostics);
}
const FreeProbe = struct {
    client: ?*c.Client = null,
    broker: *code.Broker,
    calls: usize = 0,
    armed: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            const client = self.client.?;
            std.testing.expectError(error.Busy, client.close()) catch unreachable;
            std.testing.expectError(error.Busy, client.stop()) catch unreachable;
            std.testing.expectError(error.Busy, client.stats()) catch unreachable;
            self.calls += 1;
        }
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
test "Client cleanup holds owner gate through every foreign free and last release" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    var probe: FreeProbe = .{ .broker = broker };
    const client = try c.Client.create(probe.allocator(), broker, "file:///fixture.zig", "zig", .{});
    probe.client = client;
    var transport = try client.openTransport();
    var sync = try setup(client, &transport, a);
    var work = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    try work.prepare(a);
    _ = try client.commitSend(work.token);
    var packet = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{ .contents = "owned" } }, .{});
    defer packet.deinit();
    var delivery = try work.receive(&transport, probe.allocator(), body(packet));
    try client.restart();
    probe.armed = true;
    _ = try delivery.finish();
    probe.armed = false;
    try std.testing.expect(probe.calls != 0);
    try sync.close();
    try transport.close();
    const before = probe.calls;
    probe.armed = true;
    try client.close();
    probe.armed = false;
    try std.testing.expectEqual(before + 4, probe.calls);
}
test "owner phase methods reject worker use and reservations reject before attachment" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    try std.testing.expectError(error.CapacityExceeded, c.Client.create(a, broker, "file:///fixture.zig", "zig", .{ .bytes = 1 }));
    try std.testing.expectEqual(@as(usize, 0), broker.clients);
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    const Worker = struct {
        client: *c.Client,
        passed: bool = false,
        fn run(self: *@This()) void {
            std.testing.expectError(error.WrongThread, self.client.stats()) catch return;
            std.testing.expectError(error.WrongThread, self.client.restart()) catch return;
            std.testing.expectError(error.WrongThread, self.client.close()) catch return;
            self.passed = true;
        }
    };
    var worker: Worker = .{ .client = client };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    try std.testing.expect(worker.passed);
    var transports: [32]c.Transport = undefined;
    for (&transports) |*transport| transport.* = try client.openTransport();
    try std.testing.expectError(error.Full, client.openTransport());
    try std.testing.expectError(error.TransportsAlive, client.close());
    for (&transports) |*transport| try transport.close();
}

test "sync acceptance preserves the sent stamp after raced edits and explicit full resync recovers" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var old = try client.captureSync(1);
    defer if (old.live) old.close() catch unreachable;
    try old.prepare(a, null, &.{});
    try old.validateSend();
    var accepted_packet = try old.takePacket();
    defer accepted_packet.deinit();
    // The host owns a real didOpen packet before this independent edit.
    const sent_text = old.text_version;
    try doc.replace(.{ .start = 0, .end = 1 }, "A");
    const outcome = try old.commit();
    try std.testing.expect(outcome.accepted and outcome.stale);
    try std.testing.expectEqual(@as(?u64, sent_text), (try client.stats()).text_version);
    try std.testing.expectError(error.SynchronizationRequired, client.begin(.hover, 0, .{ .start = 0, .end = 1 }));
    var replacement = try client.captureSync(2);
    defer replacement.close() catch unreachable;
    try std.testing.expectError(error.SyncPending, client.captureSync(3));
    // Unknown delta / explicit host policy chooses full preparation on worker.
    try replacement.prepareFull(a);
    try replacement.validateSend();
    try std.testing.expect(!(try replacement.commit()).stale);
    try old.close();
    var request = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    defer cleanup(&request);
    try request.prepare(a);
    try client.validateSend(request.token);
    var moved = try request.takePacket();
    defer moved.deinit();
    try std.testing.expectError(error.PacketMoved, request.takePacket());
    _ = try client.commitSend(request.token);
    try std.testing.expectError(error.InvalidPhase, client.commitSend(request.token));
}
test "restart cancels unprepared sync and handshake encoding negotiation remain explicit" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    const token = try client.beginInitialize();
    try std.testing.expectError(error.ConflictingCapabilities, transport.initialize(a, token, .{ .snippets = true }));
    try client.commitInitialize(token);
    var wrong = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = token.id, .result = .{ .capabilities = .{ .positionEncoding = "utf-8" } } }, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.UnsupportedPositionEncoding, transport.negotiate(a, token, body(wrong)));
    try std.testing.expectEqual(c.Phase.awaiting_initialize, (try client.stats()).phase);
    try client.restart();
    try std.testing.expectError(error.StaleEpoch, client.commitInitialize(token));
    var next = try client.openTransport();
    defer next.close() catch unreachable;
    try initialize(client, &next, a);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try client.restart();
    try std.testing.expectError(error.Cancelled, sync.prepare(a, null, &.{}));
}

test "remote error codes remain real and per-client conversion quotas constrain Broker results" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{ .conversion = .{ .result = .{ .completions = 1 } } });
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    var sync = try setup(client, &transport, a);
    defer sync.close() catch unreachable;
    var work = try client.begin(.completion, 0, .{ .start = 0, .end = 1 });
    defer cleanup(&work);
    try work.prepare(a);
    _ = try client.commitSend(work.token);
    var too_many = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{ .{ .label = "one" }, .{ .label = "two" } } }, .{});
    defer too_many.deinit();
    try std.testing.expectError(error.CapacityExceeded, work.receive(&transport, a, body(too_many)));
    try std.testing.expect(work.live);
    var failure = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .@"error" = .{ .code = -32801, .message = "ContentModified" } }, .{});
    defer failure.deinit();
    var delivery = try work.receive(&transport, a, body(failure));
    const outcome = try delivery.finish();
    try std.testing.expect(!outcome.published and outcome.rejected.? == error.RemoteFailure);
    try std.testing.expectEqual(@as(?i32, -32801), outcome.remote_code);
    try std.testing.expectError(error.WorkClosed, work.receive(&transport, a, body(failure)));
    try std.testing.expectError(error.DeliveryClosed, delivery.finish());
}

test "sync close preserves a retryable closing shell until every extra Snapshot Reader releases" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///fixture.zig", "zig", .{});
    defer client.close() catch unreachable;
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    var sync = try setup(client, &transport, a);
    const extra = try sync.snapshot.borrowReader();
    try std.testing.expectError(error.ReadersAlive, sync.close());
    try std.testing.expect(sync.live and sync.closing and !sync.reader_live and sync.prepared == null);
    try std.testing.expectEqual(@as(usize, 1), (try client.stats()).syncs);
    try std.testing.expectError(error.ReadersAlive, client.close());
    try std.testing.expectError(error.WorkClosed, sync.prepareFull(a));
    try std.testing.expectError(error.WorkClosed, sync.validateSend());
    try std.testing.expectError(error.WorkClosed, sync.commit());
    try std.testing.expectError(error.WorkClosed, sync.takePacket());
    try std.testing.expectError(error.WorkClosed, sync.diagnostics(&transport, a, "{}"));
    try std.testing.expectEqual(@as(usize, 3), try extra.byteLength());
    try std.testing.expectError(error.ReadersAlive, sync.close());
    try extra.release();
    try sync.close();
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).syncs);
    try std.testing.expectError(error.WorkClosed, sync.close());
}

test "maximal legal sub-budgets reject aggregate reservation before arithmetic overflow or allocation" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    var rejecting = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.CapacityExceeded, c.Client.create(rejecting.allocator(), broker, "file:///fixture.zig", "zig", .{
        .pending = 32,
        .syncs = 8,
        .diagnostics = 32,
        .bytes = 1024 * 1024 * 1024,
        .framing = .{ .header_bytes = 65536, .body_bytes = 16 * 1024 * 1024, .json_bytes = 128 * 1024 * 1024, .tokens = 1024 * 1024, .depth = 128 },
        .map = .{ .text_bytes = 64 * 1024 * 1024, .lines = 1024 * 1024, .bytes = 32 * 1024 * 1024, .work_bytes = 128 * 1024 * 1024 },
        .sync = .{ .bytes = 256 * 1024 * 1024, .work_bytes = 512 * 1024 * 1024, .edits = 65536 },
        .conversion = .{ .bytes = 64 * 1024 * 1024, .markup_parts = 1024 },
    }));
    try std.testing.expectEqual(@as(usize, 0), rejecting.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), broker.clients);
}
