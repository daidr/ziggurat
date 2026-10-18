const std = @import("std");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const c = @import("client.zig");
const configuration = @import("configuration.zig");
const codec = @import("codec.zig");
fn body(packet: codec.Packet) []const u8 {
    const bytes = packet.bytes.?;
    return bytes[std.mem.indexOf(u8, bytes, "\r\n\r\n").? + 4 ..];
}
fn prepare(allocator: std.mem.Allocator, changed: bool) !configuration.Prepared {
    return configuration.Prepared.create(allocator, .{ .settings_json = if (changed) "{\"version\":2}" else "{\"version\":1}", .entries = &.{ .{ .section = "language", .value_json = if (changed) "2" else "1" }, .{ .section = "", .value_json = "false" }, .{ .scope_uri = "file:///a/doc", .section = "language", .value_json = "[3,4]" } } }, .{});
}
fn initialize(client: *c.Client, transport: *c.Transport, allocator: std.mem.Allocator) !void {
    const token = try client.beginInitialize();
    var work = try client.captureWorkspaceInitialize(token);
    defer work.close() catch unreachable;
    try work.prepare(allocator, .{});
    const message = try codec.Message.parse(allocator, body(work.packet.?), .{});
    defer message.close() catch unreachable;
    const workspace = (try message.value()).request.params.?.object.get("capabilities").?.object.get("workspace").?.object;
    try std.testing.expect(workspace.get("configuration").?.bool);
    try std.testing.expect(!workspace.get("didChangeConfiguration").?.object.get("dynamicRegistration").?.bool);
    _ = try work.commit();
    _ = transport;
    try client.adoptInitialize(.{ .token = token, .capabilities = .{ .workspace_folders = true, .workspace_changes = true, .hover = true, .completion = true, .sync = .incremental, .open_close = true } });
    try client.commitReady(token);
}
const query_body = "{\"jsonrpc\":\"2.0\",\"id\":\"config-7\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":\"language\"},{\"scopeUri\":\"file:///a/doc\",\"section\":\"language\"},{\"scopeUri\":\"file:///a/other\",\"section\":\"language\"},{\"section\":\"\"},{}]}}";
fn flow(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(allocator, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{});
    var first = try prepare(allocator, false);
    defer if (first.snapshot != null) first.close() catch unreachable;
    try client.enableConfiguration(&first, .{});
    try std.testing.expect(first.snapshot == null);
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepare(allocator, null, &.{});
    _ = try sync.commit();
    var old_diagnostic = try sync.diagnostics(&transport, allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a/doc\",\"version\":1,\"diagnostics\":[]}}");
    defer if (old_diagnostic.live) old_diagnostic.discard() catch unreachable;
    var incoming = try transport.workspaceRequest(allocator, query_body);
    defer incoming.close() catch unreachable;
    try incoming.capture();
    try incoming.prepare(allocator);
    var completion = try client.begin(.completion, 0, .{ .start = 0, .end = 0 });
    defer if (completion.live) {
        var ended = completion.abort(error.Cancelled) catch unreachable;
        _ = ended.finish() catch unreachable;
    };
    try completion.prepare(allocator);
    _ = try client.commitSend(completion.token);
    var reply = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = completion.token.id, .result = .{.{ .label = "old", .insertText = "old" }} }, .{});
    defer reply.deinit();
    var delivery = try completion.receive(&transport, allocator, body(reply));
    defer if (delivery.live) {
        _ = delivery.finish() catch unreachable;
    };
    var next = try prepare(allocator, true);
    defer if (next.snapshot != null) next.close() catch unreachable;
    var change = try client.captureConfigurationChange(&next);
    defer change.close() catch unreachable;
    try change.prepare(allocator);
    try doc.replace(.{ .start = 0, .end = 1 }, "A"); // Configuration is independent of this edit.
    var rejected = try change.beginSend();
    rejected.end();
    try std.testing.expectEqual(@as(?u64, 1), (try client.stats()).configuration_version);
    var accepted = try change.beginSend();
    defer accepted.end();
    try std.testing.expect(!(try accepted.commit()).stale);
    const old = try delivery.finish();
    try std.testing.expect(!old.published and old.rejected.? == error.StaleConfiguration);
    try std.testing.expect((try old_diagnostic.finish()).rejected.? == error.StaleConfiguration);
    try std.testing.expectError(error.ConfigurationSynchronizationRequired, client.begin(.hover, 0, .{ .start = 0, .end = 1 }));
    try std.testing.expectError(error.StaleVersion, client.captureSync(1));
    try std.testing.expectError(error.StaleConfiguration, incoming.validateSend());
    try std.testing.expectEqualStrings("1", incoming.config_snapshot.?.entries[0].value_json);
    try incoming.capture();
    try incoming.prepare(allocator);
    try incoming.validateSend();
    const decoded = try codec.Message.parse(allocator, body(incoming.packet.?), .{});
    defer decoded.close() catch unreachable;
    const values = (try decoded.value()).response.result.array.items;
    try std.testing.expectEqual(@as(i64, 2), values[0].integer);
    try std.testing.expectEqual(@as(usize, 2), values[1].array.items.len);
    try std.testing.expect(values[2] == .null and !values[3].bool and values[4] == .null);
    _ = try incoming.commit();
    try std.testing.expectError(error.Cancelled, sync.diagnostics(&transport, allocator, "{}"));
    var newer = try client.captureSync(2);
    defer newer.close() catch unreachable;
    try newer.prepareFull(allocator);
    _ = try newer.commit();
    var hover = try client.begin(.hover, 0, .{ .start = 0, .end = 1 });
    var discarded = try hover.abort(error.Cancelled);
    _ = try discarded.finish();
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
}
test "configuration send snapshots resync and exact ordered query survive all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, flow, .{});
}

test "configuration malformed null query uses the shared incoming capacity and disabled mode is unadvertised" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{ .incoming = 1 });
    var prepared = try prepare(a, false);
    defer if (prepared.snapshot != null) prepared.close() catch unreachable;
    try client.enableConfiguration(&prepared, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var incoming = try transport.workspaceRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"workspace/configuration\",\"params\":{\"items\":[{\"section\":null}]}}");
    defer incoming.close() catch unreachable;
    try std.testing.expectError(error.Full, transport.workspaceRequest(a, query_body));
    try incoming.capture();
    try incoming.prepare(a);
    const message = try codec.Message.parse(a, body(incoming.packet.?), .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqual(@as(i32, -32602), (try message.value()).failure.code);
}

const Probe = struct {
    flag: ?*configurationCancellation = null,
    client: ?*c.Client = null,
    prepared: ?*configuration.Prepared = null,
    cancel_alloc: bool = false,
    cancel_free: bool = false,
    check_busy: bool = false,
    publication: bool = false,
    incoming: ?*c.WorkspaceIncoming = null,
    frees: usize = 0,
    const configurationCancellation = @import("positions.zig").Cancellation;
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.incoming) |incoming| {
            std.testing.expectError(error.Busy, incoming.reject()) catch unreachable;
            std.testing.expectError(error.Busy, incoming.close()) catch unreachable;
        }
        const memory = std.testing.allocator.rawAlloc(len, alignment, ra);
        if (memory != null and self.cancel_alloc) {
            self.cancel_alloc = false;
            self.flag.?.request();
        }
        return memory;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.incoming) |incoming| {
            std.testing.expectError(error.Busy, incoming.reject()) catch unreachable;
            std.testing.expectError(error.Busy, incoming.close()) catch unreachable;
        }
        if (self.check_busy) {
            std.testing.expectError(error.Busy, self.client.?.close()) catch unreachable;
            std.testing.expectError(error.Busy, self.client.?.stop()) catch unreachable;
            std.testing.expectError(error.Busy, self.client.?.stats()) catch unreachable;
            if (self.prepared) |prepared| std.testing.expectError(error.Busy, prepared.close()) catch unreachable;
            if (self.publication) {
                const client = self.client.?;
                std.testing.expectEqual(@as(?u64, 2), client.workspace_state.?.configuration.?.accepted) catch unreachable;
                std.testing.expectError(error.Busy, client.broker.borrow()) catch unreachable;
                for (client.broker.stored) |stored| std.testing.expect(stored == null) catch unreachable;
                for (client.broker.current) |serial| std.testing.expectEqual(@as(u64, 0), serial) catch unreachable;
            }
            self.frees += 1;
        }
        std.testing.allocator.rawFree(bytes, alignment, ra);
        if (self.cancel_free) {
            self.cancel_free = false;
            self.flag.?.request();
        }
    }
};
test "configuration final temporary JSON free can cancel before candidate publication" {
    var flag: Probe.configurationCancellation = .{};
    var probe: Probe = .{ .flag = &flag, .cancel_free = true };
    try std.testing.expectError(error.Cancelled, configuration.Prepared.create(probe.allocator(), .{ .settings_json = "{\"x\":[1,2,3]}", .entries = &.{.{ .section = "x", .value_json = "null" }} }, .{ .cancellation = &flag }));
    try std.testing.expect(flag.requested.load(.acquire));
}
test "configuration owner adoption cancellation retains source and gates its final cleanup" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    var flag: Probe.configurationCancellation = .{};
    var probe: Probe = .{ .flag = &flag };
    const client = try c.Client.create(probe.allocator(), broker, "file:///a/doc", "zig", .{});
    probe.client = client;
    try client.enableWorkspace(.{}, .{});
    var prepared = try configuration.Prepared.create(a, .{ .settings_json = "{}" }, .{ .cancellation = &flag });
    probe.prepared = &prepared;
    probe.cancel_alloc = true;
    probe.check_busy = true;
    try std.testing.expectError(error.Cancelled, client.enableConfiguration(&prepared, .{}));
    probe.prepared = null;
    probe.check_busy = false;
    try std.testing.expect(prepared.snapshot != null and probe.frees == 1);
    try std.testing.expect(client.workspace_state.?.configuration == null);
    try prepared.close();
    var next = try prepare(a, false);
    try client.enableConfiguration(&next, .{});
    probe.check_busy = true;
    try client.close();
    probe.check_busy = false;
}
test "configuration query limits never partially publish output or consume rejected source" {
    const a = std.testing.allocator;
    var prepared = try prepare(a, false);
    defer prepared.close() catch unreachable;
    const message = try codec.Message.parse(a, query_body, .{});
    defer message.close() catch unreachable;
    const params = (try message.value()).request.params;
    try std.testing.expectError(error.InvalidParams, configuration.Query.create(a, params, .{ .items = 1 }));
    const query = try configuration.Query.create(a, params, .{});
    defer query.close();
    var output: [64]configuration.Raw = @splat(.{ .bytes = "sentinel" });
    try std.testing.expectError(error.ConfigurationCapacityExceeded, query.results(prepared.snapshot.?, .{ .response_bytes = 2048 }, &output));
    try std.testing.expectEqualStrings("sentinel", output[0].bytes);
    try std.testing.expectError(error.ConfigurationCapacityExceeded, query.results(prepared.snapshot.?, .{ .work_bytes = 1 }, &output));
    try std.testing.expectEqualStrings("sentinel", output[0].bytes);
}

test "explicit InternalError keeps request id after exact response quota failure" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{});
    var prepared = try prepare(a, false);
    defer if (prepared.snapshot != null) prepared.close() catch unreachable;
    try client.enableConfiguration(&prepared, .{ .response_bytes = 2048 });
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var incoming = try transport.workspaceRequest(a, query_body);
    defer incoming.close() catch unreachable;
    try incoming.capture();
    try std.testing.expectError(error.ConfigurationCapacityExceeded, incoming.prepare(a));
    try std.testing.expect(incoming.packet == null and !incoming.prepared);
    try incoming.reject();
    try incoming.prepare(a);
    try incoming.validateSend();
    const message = try codec.Message.parse(a, body(incoming.packet.?), .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqual(@as(i32, -32603), (try message.value()).failure.code);
    try std.testing.expectEqualStrings("config-7", (try message.value()).failure.id.text);
    var accepted = try incoming.takePacket();
    defer accepted.deinit();
    try std.testing.expectError(error.PacketMoved, incoming.reject());
    _ = try incoming.commit();
    try std.testing.expectError(error.InvalidPhase, incoming.reject());
    try std.testing.expectError(error.InvalidPhase, incoming.commit());
}

test "configuration accepted publication precedes all foreign cleanup and rejected send retains display" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    var probe: Probe = .{ .client = client };
    try client.enableWorkspace(.{}, .{});
    var initial = try prepare(a, false);
    defer if (initial.snapshot != null) initial.close() catch unreachable;
    try client.enableConfiguration(&initial, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    const job = try broker.begin(.hover, 0);
    try job.release();
    var owned = try code.OwnedResult.init(probe.allocator(), .{ .hover = .{ .range = .{ .start = 0, .end = 1 }, .text = "old configuration display" } }, .{});
    defer owned.deinit();
    try broker.publish(job.ticket, &owned);
    _ = try broker.finish(job.ticket);
    var next = try prepare(a, true);
    defer if (next.snapshot != null) next.close() catch unreachable;
    var work = try client.captureConfigurationChange(&next);
    defer work.close() catch unreachable;
    try work.prepare(a);
    const borrowed = try broker.borrow();
    try std.testing.expectError(error.Busy, work.beginSend());
    try std.testing.expect((try borrowed.display(.hover)) != null);
    borrowed.end();
    var rejected = try work.beginSend();
    try std.testing.expectError(error.Busy, broker.borrow());
    try std.testing.expectError(error.Busy, client.stop());
    try std.testing.expectError(error.Busy, client.captureConfigurationChange(&next));
    rejected.end();
    try std.testing.expect((try broker.display(.hover)) != null and work.packet != null);
    try std.testing.expectEqual(@as(?u64, 1), (try client.stats()).configuration_version);
    var send = try work.beginSend();
    defer send.end();
    probe.check_busy = true;
    probe.publication = true;
    _ = try send.commit();
    probe.check_busy = false;
    probe.publication = false;
    try std.testing.expect(probe.frees > 0 and (try broker.display(.hover)) == null);
}

test "incoming rejection gates packet cleanup and rechecks cancellation after final foreign free" {
    const a = std.testing.allocator;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(a, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(a, broker, "file:///a/doc", "zig", .{});
    defer client.close() catch unreachable;
    try client.enableWorkspace(.{}, .{});
    var initial = try prepare(a, false);
    defer if (initial.snapshot != null) initial.close() catch unreachable;
    try client.enableConfiguration(&initial, .{});
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, a);
    var incoming = try transport.workspaceRequest(a, query_body);
    defer incoming.close() catch unreachable;
    try incoming.capture();
    var probe: Probe = .{ .client = client, .incoming = &incoming, .flag = &incoming.cancellation };
    try incoming.prepare(probe.allocator());
    probe.check_busy = true;
    probe.cancel_free = true;
    try std.testing.expectError(error.Cancelled, incoming.reject());
    probe.check_busy = false;
    probe.incoming = null;
    try std.testing.expect(probe.frees == 1 and incoming.packet == null and !incoming.prepared);
    try incoming.prepare(a);
    try incoming.validateSend();
    const message = try codec.Message.parse(a, body(incoming.packet.?), .{});
    defer message.close() catch unreachable;
    try std.testing.expectEqual(@as(i32, -32800), (try message.value()).failure.code);
    try std.testing.expectEqualStrings("config-7", (try message.value()).failure.id.text);
    _ = try incoming.commit();
}
