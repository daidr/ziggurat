const std = @import("std");
const d = @import("ziggurat_document");
const code = @import("ziggurat_code_editor");
const c = @import("client.zig");
const codec = @import("codec.zig");
const configuration = @import("configuration.zig");
fn body(packet: codec.Packet) []const u8 {
    const bytes = packet.bytes.?;
    return bytes[std.mem.indexOf(u8, bytes, "\r\n\r\n").? + 4 ..];
}
fn initialize(client: *c.Client, transport: *c.Transport, allocator: std.mem.Allocator) !void {
    const token = try client.beginInitialize();
    var workspace: ?c.WorkspaceWork = null;
    defer if (workspace) |*work| work.close() catch unreachable;
    var packet = if (client.workspace_state != null) blk: {
        workspace = try client.captureWorkspaceInitialize(token);
        try workspace.?.prepare(allocator, .{});
        break :blk try workspace.?.takePacket();
    } else try transport.initialize(allocator, token, .{});
    defer packet.deinit();
    const message = try codec.Message.parse(allocator, body(packet), .{});
    defer message.close() catch unreachable;
    const properties = (try message.value()).request.params.?.object.get("capabilities").?.object.get("textDocument").?.object.get("completion").?.object.get("completionItem").?.object.get("resolveSupport").?.object.get("properties").?.array.items;
    try std.testing.expect(properties.len == 2);
    if (workspace) |*work| {
        _ = try work.commit();
    } else try client.commitInitialize(token);
    try client.adoptInitialize(.{ .token = token, .capabilities = .{ .completion = true, .completion_resolve = true, .sync = .incremental, .open_close = true, .workspace_folders = true, .workspace_changes = true } });
    try client.commitReady(token);
}
const FinishProbe = struct {
    client: ?*c.Client = null,
    delivery: ?*c.ResolveDelivery = null,
    enabled: bool = false,
    hits: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        return std.testing.allocator.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.enabled) {
            const client = self.client.?;
            std.testing.expectError(error.Busy, client.close()) catch unreachable;
            std.testing.expectError(error.Busy, client.stop()) catch unreachable;
            std.testing.expectError(error.Busy, client.stats()) catch unreachable;
            std.testing.expectError(error.Busy, self.delivery.?.finish(null)) catch unreachable;
            std.testing.expectEqual(@as(usize, 1), client.live_requests) catch unreachable;
            self.hits += 1;
        }
        std.testing.allocator.rawFree(bytes, alignment, ra);
    }
};
const Change = enum { stop, cancel, restart, workspace, configuration, discard };
fn flowChange(allocator: std.mem.Allocator, change: Change, probe: ?*FinishProbe) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const broker = try code.Broker.create(allocator, doc, .{});
    defer broker.close() catch unreachable;
    const client = try c.Client.create(allocator, broker, "file:///a", "zig", .{ .pending = 1 });
    defer client.close() catch unreachable;
    try client.enableCompletionResolve(.{});
    if (change == .workspace or change == .configuration) try client.enableWorkspace(.{ .folders = &.{} }, .{});
    if (change == .configuration) {
        var prepared = try configuration.Prepared.create(allocator, .{ .settings_json = "{}" }, .{});
        defer if (prepared.snapshot != null) prepared.close() catch unreachable;
        try client.enableConfiguration(&prepared, .{});
    }
    var transport = try client.openTransport();
    defer transport.close() catch unreachable;
    try initialize(client, &transport, allocator);
    var sync = try client.captureSync(1);
    defer sync.close() catch unreachable;
    try sync.prepareFull(allocator);
    _ = try sync.commit();
    var request = try client.begin(.completion, 0, .{ .start = 0, .end = 0 });
    defer if (request.live) {
        var delivery = request.abort(error.Cancelled) catch unreachable;
        _ = delivery.finish() catch unreachable;
    };
    try request.prepare(allocator);
    _ = try client.commitSend(request.token);
    var packet = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = request.token.id, .result = .{.{ .label = "item", .data = .{ .key = "exact" } }} }, .{});
    defer packet.deinit();
    if (change == .cancel) client.caps.completion_resolve = false;
    var received = try request.receive(&transport, allocator, body(packet));
    if (change == .cancel) {
        // An in-flight worker uses the policy captured with its request, not
        // mutable owner capability fields of a later negotiation/restart.
        try std.testing.expect(received.owned.?.data.completion[0].continuation != null);
        client.caps.completion_resolve = true;
    }
    defer if (received.live) {
        _ = received.finish() catch unreachable;
    };
    try std.testing.expect((try received.finish()).published);
    const display = (try broker.display(.completion)).?;
    const choice: code.CompletionChoice = .{ .presenter_id = 1, .selection = 0, .popup = 0, .ticket = display.ticket, .display_generation = broker.display_generation, .index = 0 };
    var resolve = try client.beginResolve(allocator, choice);
    defer if (resolve.live) {
        var discarded = resolve.abort(error.Cancelled) catch unreachable;
        _ = discarded.finish(null) catch unreachable;
    };
    try std.testing.expectError(error.Full, client.beginResolve(allocator, choice));
    try std.testing.expectEqual(@as(usize, 0), broker.outstanding);
    try std.testing.expectEqualStrings("item", (try broker.display(.completion)).?.data.completion[0].label);
    try resolve.prepare();
    try client.validateSend(resolve.token);
    _ = try client.commitSend(resolve.token);
    var reply = try codec.Packet.json(allocator, .{ .jsonrpc = "2.0", .id = resolve.token.id, .result = .{ .label = "item", .detail = "resolved", .documentation = "docs" } }, .{});
    defer reply.deinit();
    var delivery = try resolve.receive(&transport, body(reply));
    defer if (delivery.live) {
        _ = delivery.finish(null) catch unreachable;
    };
    try std.testing.expectEqualStrings("resolved", delivery.owned.?.data.completion[0].detail);
    switch (change) {
        .stop => try client.stop(),
        .cancel => {
            try client.cancel(resolve.token);
            // Cancelling a continuation must leave its original popup usable.
            try std.testing.expectEqualStrings("item", (try broker.display(.completion)).?.data.completion[0].label);
        },
        .restart => try client.restart(),
        .workspace => {
            var work = try client.captureWorkspaceChange(.{ .folders = &.{.{ .uri = "file:///new", .name = "new" }} });
            defer work.close() catch unreachable;
            try work.prepare(allocator, .{});
            var send = try work.beginSend();
            defer send.end();
            _ = try send.commit();
        },
        .configuration => {
            var next = try configuration.Prepared.create(allocator, .{ .settings_json = "{\"next\":true}" }, .{});
            defer if (next.snapshot != null) next.close() catch unreachable;
            var work = try client.captureConfigurationChange(&next);
            defer work.close() catch unreachable;
            try work.prepare(allocator);
            var send = try work.beginSend();
            defer send.end();
            _ = try send.commit();
        },
        .discard => {},
    }
    if (probe) |value| {
        value.client = client;
        value.delivery = &delivery;
        value.enabled = true;
    }
    const outcome = try delivery.finish(null);
    if (probe) |value| value.enabled = false;
    try std.testing.expect(!outcome.published);
    const expected: anyerror = switch (change) {
        .stop, .restart => error.StaleEpoch,
        .cancel => error.Cancelled,
        .workspace => error.StaleWorkspace,
        .configuration => error.StaleConfiguration,
        .discard => error.Closed,
    };
    try std.testing.expectEqual(expected, outcome.rejected.?);
    try std.testing.expectError(error.DeliveryClosed, delivery.finish(null));
    try std.testing.expectEqual(@as(usize, 0), (try client.stats()).requests);
}
fn flow(allocator: std.mem.Allocator) !void {
    return flowChange(allocator, .stop, null);
}
test "resolve shares physical request capacity owns original item and cleans late delivery under every OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, flow, .{});
}
test "resolve late delivery has exact cancellation epoch workspace and configuration stamps" {
    inline for (.{ Change.cancel, Change.restart, Change.workspace, Change.configuration }) |change| try flowChange(std.testing.allocator, change, null);
}
test "resolve discarded candidate final free keeps owner and physical slot gated" {
    var probe: FinishProbe = .{};
    try flowChange(probe.allocator(), .discard, &probe);
    try std.testing.expect(probe.hits != 0);
}
test "resolve requires explicit opt in server capability and complete checked reservation" {
    const a = std.testing.allocator;
    inline for (.{ false, true }) |enabled| {
        const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
        defer doc.close() catch unreachable;
        const broker = try code.Broker.create(a, doc, .{});
        defer broker.close() catch unreachable;
        const client = try c.Client.create(a, broker, "file:///a", "zig", .{});
        defer client.close() catch unreachable;
        const reservation = client.reservation;
        try std.testing.expectError(error.CapacityExceeded, client.enableCompletionResolve(.{ .bytes = 1 }));
        try std.testing.expect(client.resolve_options == null and client.reservation == reservation);
        if (enabled) try client.enableCompletionResolve(.{});
        var transport = try client.openTransport();
        defer transport.close() catch unreachable;
        const token = try client.beginInitialize();
        var packet = try transport.initialize(a, token, .{});
        defer packet.deinit();
        const message = try codec.Message.parse(a, body(packet), .{});
        defer message.close() catch unreachable;
        const support = (try message.value()).request.params.?.object.get("capabilities").?.object.get("textDocument").?.object.get("completion").?.object.get("completionItem").?.object.get("resolveSupport");
        try std.testing.expect((support != null) == enabled);
        try client.commitInitialize(token);
        try client.adoptInitialize(.{ .token = token, .capabilities = .{ .completion = true } });
        try client.commitReady(token);
        try std.testing.expectError(if (enabled) error.UnsupportedMethod else error.ResolveDisabled, client.beginResolve(a, undefined));
    }
}
