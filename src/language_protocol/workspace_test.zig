const std = @import("std");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const c = @import("client.zig");
const codec = @import("codec.zig");
const w = @import("workspace.zig");
const a = std.testing.allocator;
const first: w.Options = .{ .root_uri = "file:///a", .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///b", .name = "B" } } };
const second: w.Options = .{ .root_uri = "file:///a", .folders = &.{ .{ .uri = "file:///a", .name = "A" }, .{ .uri = "file:///c", .name = "C" } } };
fn body(packet: codec.Packet) []const u8 {
    const bytes = packet.bytes.?;
    return bytes[std.mem.indexOf(u8, bytes, "\r\n\r\n").? + 4 ..];
}
fn commitChange(work: *c.WorkspaceWork) !c.WorkspaceCommit {
    var send = try work.beginSend();
    defer send.end();
    return send.commit();
}
fn initialize(client: *c.Client, transport: *c.Transport, allocator: std.mem.Allocator, changes: bool) !void {
    const token = try client.beginInitialize();
    var work = try client.captureWorkspaceInitialize(token);
    defer work.close() catch unreachable;
    try work.prepare(allocator, .{});
    try work.validateSend();
    var packet = try work.takePacket();
    defer packet.deinit();
    const message = try codec.Message.parse(allocator, body(packet), .{});
    defer message.close() catch unreachable;
    const params = (try message.value()).request.params.?.object;
    try std.testing.expectEqualStrings("file:///a", params.get("rootUri").?.string);
    try std.testing.expectEqual(@as(usize, 2), params.get("workspaceFolders").?.array.items.len);
    try std.testing.expect(!(try work.commit()).stale);
    var response = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = token.id, .result = .{ .capabilities = .{ .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = changes } }, .completionProvider = struct {}{}, .textDocumentSync = .{ .openClose = true, .change = 2 } } } }, .{});
    defer response.deinit();
    try client.adoptInitialize(try transport.negotiate(allocator, token, body(response)));
    var ready = try transport.initialized(allocator);
    defer ready.deinit();
    try client.commitReady(token);
}
fn flow(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///a/doc.zig", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator, true);
    var incoming = try transport.workspaceRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"folders-7\",\"method\":\"workspace/workspaceFolders\"}");
    defer incoming.close() catch unreachable;
    try incoming.capture();
    try incoming.prepare(allocator);
    try incoming.validateSend();
    var change = try client.captureWorkspaceChange(second);
    defer change.close() catch unreachable;
    try change.prepare(allocator, .{});
    try change.validateSend();
    // A rejected host queue has not advanced the accepted workspace revision.
    try change.validateSend();
    try std.testing.expectEqual(@as(?u64, 1), (try client.stats()).workspace_version);
    var notification = try change.takePacket();
    defer notification.deinit();
    const parsed = try codec.Message.parse(allocator, body(notification), .{});
    defer parsed.close() catch unreachable;
    const event = (try parsed.value()).notification.params.?.object.get("event").?.object;
    try std.testing.expectEqualStrings("file:///b", event.get("removed").?.array.items[0].object.get("uri").?.string);
    try std.testing.expectEqualStrings("file:///c", event.get("added").?.array.items[0].object.get("uri").?.string);
    try std.testing.expect(!(try commitChange(&change)).stale);
    try std.testing.expectError(error.StaleWorkspace, incoming.validateSend());
    try incoming.capture();
    try incoming.prepare(allocator);
    var response = try incoming.takePacket();
    defer response.deinit();
    const result = try codec.Message.parse(allocator, body(response), .{});
    defer result.close() catch unreachable;
    const envelope = (try result.value()).response;
    try std.testing.expectEqualStrings("folders-7", envelope.id.text);
    try std.testing.expectEqualStrings("file:///c", envelope.result.array.items[1].object.get("uri").?.string);
    try incoming.validateSend();
    try std.testing.expect(!(try incoming.commit()).stale);
    try std.testing.expectError(error.InvalidPhase, incoming.commit());
    try client.restart();
    try std.testing.expectError(error.StaleEpoch, incoming.capture());
    try std.testing.expectEqual(@as(?u64, null), (try client.stats()).workspace_version);
}
test "workspace initialize/change/request recapture are atomic under every allocation failure" {
    try std.testing.checkAllAllocationFailures(a, flow, .{});
}
test "workspace negotiation false, bounded unknown routing, cancellation and stale accepted responsibility" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{ .incoming = 1 });
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, false);
    try std.testing.expectError(error.WorkspaceRestartRequired, client.captureWorkspaceChange(second));
    var request = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":-9,\"method\":\"workspace/configuration\",\"params\":{\"items\":[]}}");
    defer request.close() catch unreachable;
    try std.testing.expectError(error.Full, transport.workspaceRequest(a, "{}"));
    try request.capture();
    try request.prepare(a);
    var packet = try request.takePacket();
    defer packet.deinit();
    const message = try codec.Message.parse(a, body(packet), .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqual(@as(i32, -32601), (try message.value()).failure.code);
    try client.restart();
    try std.testing.expect((try request.commit()).stale);
    try std.testing.expectError(error.InvalidPhase, request.commit());
}
test "workspace static registration id is owned and exact unregister disables future changes" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    var registration: @import("wire.zig").Registration = .{};
    @memcpy(registration.bytes[0..3], "abc");
    registration.len = 3;
    client.caps.workspace_registration = registration;
    var request = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"client/unregisterCapability\",\"params\":{\"unregisterations\":[{\"id\":\"abc\",\"method\":\"workspace/didChangeWorkspaceFolders\"}]}}");
    defer request.close() catch unreachable;
    try request.capture();
    try request.prepare(a);
    try request.validateSend();
    try std.testing.expect(!(try request.commit()).stale);
    try std.testing.expectError(error.WorkspaceRestartRequired, client.captureWorkspaceChange(second));
}

test "workspace revisions cancel old physical requests and revoke queued and stored results" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepare(a, null, &.{});
    _ = try sync.commit();
    var work = try client.begin(.completion, 0, .{ .start = 0, .end = 0 });
    try work.prepare(a);
    _ = try client.commitSend(work.token);
    var response = try codec.Packet.json(a, .{ .jsonrpc = "2.0", .id = work.token.id, .result = .{.{ .label = "old", .insertText = "old" }} }, .{});
    defer response.deinit();
    var delivery = try work.receive(&transport, a, body(response));
    defer if (delivery.live) {
        _ = delivery.finish() catch unreachable;
    };
    var change = try client.captureWorkspaceChange(second);
    defer change.close() catch unreachable;
    try change.prepare(a, .{});
    try change.validateSend();
    try std.testing.expect(!(try commitChange(&change)).stale);
    const outcome = try delivery.finish();
    try std.testing.expect(!outcome.published and outcome.rejected.? == error.StaleWorkspace);
    try std.testing.expect((try broker.display(.completion)) == null);
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
}

const Probe = struct {
    client: ?*c.Client = null,
    armed: bool = false,
    restart: bool = false,
    frees: usize = 0,
    boundary: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const memory = a.rawAlloc(len, alignment, ra);
        if (memory != null and self.restart) {
            self.restart = false;
            self.client.?.restart() catch unreachable;
        }
        return memory;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            std.testing.expectError(error.Busy, self.client.?.close()) catch unreachable;
            std.testing.expectError(error.Busy, self.client.?.stats()) catch unreachable;
            std.testing.expectError(error.Busy, self.client.?.stop()) catch unreachable;
            if (self.boundary) {
                const client = self.client.?;
                std.testing.expectEqual(@as(?u64, 2), client.workspace_state.?.accepted) catch unreachable;
                std.testing.expectError(error.Busy, client.broker.borrow()) catch unreachable;
                for (client.broker.current) |serial| std.testing.expectEqual(@as(u64, 0), serial) catch unreachable;
                for (client.broker.stored) |stored| std.testing.expect(stored == null) catch unreachable;
            }
            self.frees += 1;
        }
        a.rawFree(bytes, alignment, ra);
    }
};
test "workspace worker cancellation and all cleanup foreign callbacks retain the owner" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    var probe: Probe = .{};
    const client = try c.Client.create(probe.allocator(), broker, "file:///a/doc", "zig", .{});
    probe.client = client;
    try client.enableWorkspace(first, .{ .products = 1, .incoming = 1 });
    var transport = try client.openTransport();
    try initialize(client, &transport, a, true);
    var request = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"workspace/workspaceFolders\"}");
    var change = try client.captureWorkspaceChange(second);
    probe.restart = true;
    try std.testing.expectError(error.Cancelled, change.prepare(probe.allocator(), .{}));
    try std.testing.expect(!change.prepared and change.packet == null);
    probe.armed = true;
    try change.close();
    probe.armed = false;
    try std.testing.expect(probe.frees != 0);
    try std.testing.expectError(error.StaleEpoch, request.capture());
    try transport.close();
    try std.testing.expectError(error.WorkspacesAlive, client.close());
    probe.armed = true;
    try request.close();
    try client.close();
    probe.armed = false;
}
test "reverse request cancellation re-encodes exactly once and keeps its original identifier" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    var request = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":\"cancel-42\",\"method\":\"workspace/workspaceFolders\"}");
    defer request.close() catch unreachable;
    try request.capture();
    try request.prepare(a);
    try request.cancel();
    try std.testing.expectError(error.Cancelled, request.validateSend());
    try request.capture();
    try request.prepare(a);
    try request.validateSend();
    const message = try codec.Message.parse(a, body(request.packet.?), .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqual(@as(i32, -32800), (try message.value()).failure.code);
    try std.testing.expectEqualStrings("cancel-42", (try message.value()).failure.id.text);
    _ = try request.commit();
    try std.testing.expectError(error.InvalidPhase, request.commit());
}

test "workspace send reservation refuses borrowed display, rolls back rejection and commits before foreign cleanup" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    var probe: Probe = .{ .client = client };
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    // Finished storage and an independent live job both survive a rejected send.
    const job = try broker.begin(.hover, 0);
    try job.release();
    var owned = try code.OwnedResult.init(probe.allocator(), .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "old display" } }, .{});
    defer owned.deinit();
    try broker.publish(job.ticket, &owned);
    _ = try broker.finish(job.ticket);
    const pending = try broker.begin(.completion, 0);
    defer {
        pending.release() catch unreachable;
        _ = broker.finish(pending.ticket) catch unreachable;
    }
    var change = try client.captureWorkspaceChange(second);
    defer change.close() catch unreachable;
    try change.prepare(a, .{});
    const borrow = try broker.borrow();
    try std.testing.expectError(error.Busy, change.beginSend());
    try std.testing.expect(!try pending.isCancelled());
    try std.testing.expect((try borrow.display(.hover)) != null);
    borrow.end();
    const generation = broker.invalidation_generation;
    var rejected = try change.beginSend();
    try std.testing.expectError(error.Busy, client.close());
    try std.testing.expectError(error.Busy, client.stop());
    try std.testing.expectError(error.Busy, client.captureWorkspaceChange(second));
    try std.testing.expectError(error.Busy, broker.borrow());
    rejected.end();
    rejected.end();
    try std.testing.expectEqual(generation, broker.invalidation_generation);
    try std.testing.expectEqual(@as(?u64, 1), (try client.stats()).workspace_version);
    try std.testing.expect(change.packet != null and !change.committed);
    try std.testing.expect((try broker.display(.hover)) != null and !try pending.isCancelled());
    // A later accepted retry owns the original Packet and one final commit.
    var accepted = try change.beginSend();
    defer accepted.end();
    var packet = try accepted.takePacket();
    defer packet.deinit();
    probe.armed = true;
    probe.boundary = true;
    try std.testing.expect(!(try accepted.commit()).stale);
    probe.armed = false;
    probe.boundary = false;
    try std.testing.expectEqual(@as(usize, 1), probe.frees);
    try std.testing.expectError(error.ScopeClosed, accepted.commit());
    try std.testing.expect((try broker.display(.hover)) == null and try pending.isCancelled());
    try std.testing.expectEqual(@as(usize, 1), broker.outstanding);
}

test "workspace cold reconfiguration owns a new root and preserves null versus empty mode" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    try std.testing.expectError(error.WorkspaceRestartRequired, client.captureWorkspaceChange(.{}));
    try client.restart();
    try client.reconfigureWorkspace(.{});
    var fresh = try client.openTransport();
    defer fresh.close() catch unreachable;
    const handshake = try client.beginInitialize();
    var work = try client.captureWorkspaceInitialize(handshake);
    defer work.close() catch unreachable;
    try work.prepare(a, .{});
    const message = try codec.Message.parse(a, body(work.packet.?), .{});
    defer message.close() catch unreachable;
    const params = (try message.value()).request.params.?.object;
    try std.testing.expect(params.get("rootUri").? == .null and params.get("workspaceFolders").? == .null);
    _ = try work.commit();
    try client.adoptInitialize(.{ .token = handshake, .capabilities = .{ .workspace_folders = true, .workspace_changes = true } });
    try client.commitReady(handshake);
    var incoming = try fresh.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/workspaceFolders\"}");
    defer incoming.close() catch unreachable;
    try incoming.capture();
    try incoming.prepare(a);
    const response = try codec.Message.parse(a, body(incoming.packet.?), .{});
    defer response.close() catch unreachable;
    try std.testing.expect((try response.value()).response.result == .null);
    try client.restart();
    try client.reconfigureWorkspace(.{ .folders = &.{} });
    try std.testing.expect(client.workspace_state.?.current.folders != null);
    try std.testing.expect(incoming.snapshot.?.folders == null); // older immutable query.
}
test "workspace snapshot work and aggregate reservation fail before publication" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    const initial = client.reservation;
    try std.testing.expectError(error.WorkspaceCapacityExceeded, client.enableWorkspace(first, .{ .work_bytes = 1 }));
    try std.testing.expectEqual(initial, client.reservation);
    try std.testing.expect(client.workspace_state == null);
    try std.testing.expectError(error.CapacityExceeded, client.enableWorkspace(first, .{ .incoming = 16, .products = 8 }));
    try std.testing.expect(client.workspace_state == null);
}

fn coldCandidate(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    client.reconfigureWorkspace(second) catch |err| {
        try std.testing.expectEqual(@as(u64, 1), client.workspace_state.?.version);
        try std.testing.expectEqualStrings("file:///b", client.workspace_state.?.current.folders.?[1].uri);
        return err;
    };
    try std.testing.expectEqual(@as(u64, 2), client.workspace_state.?.version);
    try std.testing.expectEqualStrings("file:///c", client.workspace_state.?.current.folders.?[1].uri);
}
test "cold workspace candidate OOM never publishes or retires old configuration" {
    try std.testing.checkAllAllocationFailures(a, coldCandidate, .{});
}

test "stop during reverse encoding cancels candidate and retains physical lease until close" {
    const document = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const broker = try code.Broker.create(a, document, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(first, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a, true);
    var incoming = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"workspace/workspaceFolders\"}");
    defer incoming.close() catch unreachable;
    try incoming.capture();
    var probe: Probe = .{ .client = client, .restart = true };
    try std.testing.expectError(error.Cancelled, incoming.prepare(probe.allocator()));
    try std.testing.expect(!incoming.prepared and incoming.packet == null);
    try std.testing.expectEqual(@as(usize, 1), (try client.stats()).workspace_incoming);
    try std.testing.expectError(error.StaleEpoch, transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"workspace/workspaceFolders\"}"));
    try client.stop();
    try std.testing.expectError(error.Closed, incoming.validateSend());
}
