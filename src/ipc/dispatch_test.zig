const std = @import("std");
const ipc = @import("root.zig");
const allocator = std.testing.allocator;
const limits: ipc.Limits = .{ .max_pending = 2, .max_in_flight = 1 };
const Service = struct {
    pub const methods = .{
        .echo = ipc.Method(struct { text: []const u8, deny: bool = false }, []const u8, enum { denied }, void),
        .later = ipc.Method(struct { text: []const u8 }, []const u8, enum { unavailable }, void),
        .watch = ipc.Method(void, void, enum { unavailable }, u8),
    };
};
const Later = ipc.Work(Service, limits, "later");
const Watch = ipc.Work(Service, limits, "watch");
const Context = struct { calls: usize = 0, deferred: ?Later = null, stream: ?Watch = null };
const Impl = struct {
    calls: usize = 0,
    pub fn echo(self: *@This(), context: *Context, params: Service.methods.echo.Params) ipc.Reply(Service, "echo") {
        self.calls += 1;
        context.calls += 1;
        if (params.deny) return .{ .failure = .{ .code = .denied, .message = params.text } };
        return .{ .result = params.text };
    }
    pub fn later(self: *@This(), context: *Context, work: Later) void {
        self.calls += 1;
        std.debug.assert(context.deferred == null);
        context.deferred = work;
    }
    pub fn watch(self: *@This(), context: *Context, work: Watch) void {
        self.calls += 1;
        std.debug.assert(context.stream == null);
        context.stream = work;
    }
};
const D = ipc.Dispatcher(Service, Impl, Context, limits);
const session = ipc.Session.init("00000000000000000000000000000001") catch unreachable;
const other = ipc.Session.init("00000000000000000000000000000002") catch unreachable;

fn request(d: *D, implementation: *Impl, context: *Context, id: u32, slot: u16, method: []const u8, params: anytype) !D.Action {
    const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &d.router.session.bytes, .kind = "call", .id = id, .slot = slot, .method = method, .params = params }, 65536);
    defer allocator.free(bytes);
    return d.dispatch(allocator, implementation, context, bytes);
}

fn control(d: *D, implementation: *Impl, context: *Context, token: ipc.Token, kind: []const u8, sequence: ?u32) !D.Action {
    const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &token.session.bytes, .kind = kind, .id = token.id, .slot = token.slot, .sequence = sequence }, 65536);
    defer allocator.free(bytes);
    return d.dispatch(allocator, implementation, context, bytes);
}

test "compile-time dispatch retains borrowed sync result and declared error until encoding" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    var result = try request(&d, &implementation, &context, 1, 0, "echo", .{ .text = "retained" });
    defer result.reply.deinit();
    try std.testing.expectEqual(1, d.router.active);
    try std.testing.expectEqual(1, implementation.calls);
    try std.testing.expectEqual(1, context.calls);
    try std.testing.expectEqualStrings("retained", result.reply.reply.echo.result);
    const bytes = try result.reply.encode(&d.router, allocator);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"value\":\"retained\"") != null);
    try std.testing.expectError(error.AlreadyEncoded, result.reply.encode(&d.router, allocator));
    try std.testing.expectEqual(0, d.router.active);
    var denied = try request(&d, &implementation, &context, 2, 0, "echo", .{ .text = "reason from request", .deny = true });
    defer denied.reply.deinit();
    const failure = try denied.reply.encode(&d.router, allocator);
    defer allocator.free(failure);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"code\":\"denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure, "reason from request") != null);
}

test "sync encoding retry does not execute a side effect twice and moves ownership explicitly" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    var action = try request(&d, &implementation, &context, 1, 0, "echo", .{ .text = "exactly once" });
    var moved = try action.reply.take();
    defer moved.deinit();
    action.reply.deinit();
    action.reply.deinit();
    try std.testing.expectError(error.Released, action.reply.take());
    try std.testing.expectError(error.Released, action.reply.encode(&d.router, allocator));
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, moved.encode(&d.router, failing.allocator()));
    try std.testing.expectEqual(1, implementation.calls);
    try std.testing.expectEqual(1, context.calls);
    try std.testing.expect(!moved.encoded and moved.storage != null);
    try std.testing.expectEqual(1, d.router.active);
    const bytes = try moved.encode(&d.router, allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqual(0, d.router.active);
    try std.testing.expectEqual(1, implementation.calls);
}

test "deferred work owns request strings across cancellation and slot reuse" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    const taken = try request(&d, &implementation, &context, 1, 0, "later", .{ .text = "stable async params" });
    var work = try context.deferred.?.take();
    defer work.deinit();
    context.deferred.?.deinit();
    context.deferred = null;
    try std.testing.expectEqualStrings("stable async params", work.params.text);
    const canceled = try control(&d, &implementation, &context, taken.taken, "cancel", null);
    try std.testing.expectEqual(taken.taken, canceled.cancel);
    try std.testing.expectEqualStrings("stable async params", work.params.text);
    var fresh = try request(&d, &implementation, &context, 2, 0, "echo", .{ .text = "replacement" });
    defer fresh.reply.deinit();
    try std.testing.expectError(error.StaleRequest, d.router.complete("later", allocator, work.token, work.params.text));
    const bytes = try fresh.reply.encode(&d.router, allocator);
    defer allocator.free(bytes);
}

test "takeover streams keep explicit ACK credit and require no application dependency" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    _ = try request(&d, &implementation, &context, 1, 0, "watch", null);
    defer context.stream.?.deinit();
    const token = context.stream.?.token;
    const bytes = try d.router.chunk("watch", allocator, token, 7);
    defer allocator.free(bytes);
    try std.testing.expectError(error.Backpressure, d.router.chunk("watch", allocator, token, 8));
    const ack = try control(&d, &implementation, &context, token, "ack", 1);
    try std.testing.expectEqual(token, ack.ack.token);
    try std.testing.expectEqual(1, ack.ack.sequence);
    const second = try d.router.chunk("watch", allocator, token, 8);
    defer allocator.free(second);
    const end = try d.router.complete("watch", allocator, token, {});
    defer allocator.free(end);
    try std.testing.expectEqual(0, d.router.active);
}

test "close and reset invalidate both deferred work and unencoded synchronous replies" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    _ = try request(&d, &implementation, &context, 1, 0, "later", .{ .text = "old document" });
    defer context.deferred.?.deinit();
    var reply = try request(&d, &implementation, &context, 2, 1, "echo", .{ .text = "old sync" });
    defer reply.reply.deinit();
    var canceled: [2]ipc.Token = undefined;
    try std.testing.expectEqual(2, try d.router.reset(other, &canceled));
    try std.testing.expectError(error.StaleSession, reply.reply.encode(&d.router, allocator));
    try std.testing.expectError(error.StaleSession, d.router.complete("later", allocator, context.deferred.?.token, "late"));
    try std.testing.expectEqualStrings("old document", context.deferred.?.params.text);
    var current = try request(&d, &implementation, &context, 1, 0, "echo", .{ .text = "closing" });
    defer current.reply.deinit();
    try std.testing.expectEqual(1, try d.router.close(&canceled));
    try std.testing.expectError(error.Closed, current.reply.encode(&d.router, allocator));
}

test "dispatcher returns addressed rejection metadata without executing implementation" {
    var d = D.init(session);
    var implementation: Impl = .{};
    var context: Context = .{};
    const unknown = try request(&d, &implementation, &context, 1, 0, "missing", .{});
    try std.testing.expectEqual(ipc.protocol.Rejection.unknown_method, unknown.rejected.code);
    const invalid = try request(&d, &implementation, &context, 1, 0, "echo", .{ .text = 12 });
    try std.testing.expectEqual(ipc.protocol.Rejection.invalid_params, invalid.rejected.code);
    try std.testing.expectEqual(0, implementation.calls);
    try std.testing.expectEqual(0, d.router.active);
    try std.testing.expectError(error.InvalidRequest, d.dispatch(allocator, &implementation, &context, "{"));
}

test "dispatcher and pending replies roll back every allocation failure without repeating handlers" {
    const Scenario = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var d = D.init(session);
            var implementation: Impl = .{};
            var context: Context = .{};
            const message = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"echo\",\"params\":{\"text\":\"owned\"}}";
            var action = d.dispatch(alloc, &implementation, &context, message) catch |err| {
                std.debug.assert(d.router.active == 0 and implementation.calls == 0);
                return err;
            };
            defer action.reply.deinit();
            const bytes = action.reply.encode(&d.router, alloc) catch |err| {
                std.debug.assert(d.router.active == 1 and implementation.calls == 1);
                var canceled: [2]ipc.Token = undefined;
                _ = try d.router.close(&canceled);
                return err;
            };
            defer alloc.free(bytes);
            try std.testing.expectEqual(1, implementation.calls);
            try std.testing.expectEqual(0, d.router.active);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
}
