const std = @import("std");
const ipc = @import("root.zig");
const allocator = std.testing.allocator;
const Service = struct {
    pub const methods = .{
        .add = ipc.Method(struct { a: i32, b: i32 }, i32, enum { overflow, denied }, void),
        .watch = ipc.Method(struct { topic: []const u8 }, void, enum { unavailable }, []const u8),
    };
};
const session = ipc.Session.init("00000000000000000000000000000001") catch unreachable;
const other_session = ipc.Session.init("00000000000000000000000000000002") catch unreachable;
const R = ipc.Router(Service, .{ .max_pending = 2, .max_in_flight = 2 });

fn call(router: *R, id: u32, slot: u16, method: []const u8, params: anytype) !R.Received {
    const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &router.session.bytes, .kind = "call", .id = id, .slot = slot, .method = method, .params = params }, 65536);
    defer allocator.free(bytes);
    return router.receive(allocator, bytes);
}

fn control(router: *R, token: ipc.Token, kind: []const u8, sequence: ?u32) !R.Received {
    const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &token.session.bytes, .kind = kind, .id = token.id, .slot = token.slot, .sequence = sequence }, 65536);
    defer allocator.free(bytes);
    return router.receive(allocator, bytes);
}

test "typed calls own parsed strings and result/error encoding releases pending slots" {
    var router = R.init(session);
    var request = try call(&router, 1, 0, "add", .{ .a = 2, .b = 3 });
    defer request.deinit();
    const sum = request.action.call.params.add.a + request.action.call.params.add.b;
    const result = try router.complete("add", allocator, request.action.call.token, sum);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"value\":5") != null);
    try std.testing.expectEqual(0, router.active);
    try std.testing.expectError(error.StaleRequest, router.complete("add", allocator, request.action.call.token, 0));
    var watched = try call(&router, 2, 0, "watch", .{ .topic = "stable" });
    defer watched.deinit();
    try std.testing.expectEqualStrings("stable", watched.action.call.params.watch.topic);
    const failure = try router.fail("watch", allocator, watched.action.call.token, .unavailable, "later");
    defer allocator.free(failure);
    try std.testing.expect(std.mem.indexOf(u8, failure, "\"code\":\"unavailable\"") != null);
    try std.testing.expectEqual(0, router.active);
}

test "invalid input and full capacity never take ownership or advance IDs" {
    var router = R.init(session);
    try std.testing.expectError(error.InvalidRequest, router.receive(allocator, "{"));
    try std.testing.expectError(error.UnknownMethod, call(&router, 1, 0, "missing", .{}));
    try std.testing.expectError(error.InvalidParams, call(&router, 1, 0, "add", .{ .a = "wrong", .b = 1 }));
    try std.testing.expectEqual(0, router.last_id);
    var first = try call(&router, 1, 0, "add", .{ .a = 1, .b = 2 });
    defer first.deinit();
    var second = try call(&router, 2, 1, "watch", .{ .topic = "a" });
    defer second.deinit();
    try std.testing.expectError(error.Full, call(&router, 3, 0, "add", .{ .a = 1, .b = 2 }));
    try std.testing.expectEqual(2, router.last_id);
    try std.testing.expectEqual(2, router.active);
    try std.testing.expectError(error.WrongMethod, router.complete("add", allocator, second.action.call.token, 1));
    var canceled = try control(&router, first.action.call.token, "cancel", null);
    defer canceled.deinit();
    try std.testing.expectEqual(1, router.active);
    var replacement = try call(&router, 3, 0, "add", .{ .a = 3, .b = 4 });
    defer replacement.deinit();
    try std.testing.expectError(error.StaleRequest, router.complete("add", allocator, first.action.call.token, 0));
    try std.testing.expectError(error.DuplicateRequest, call(&router, 2, 0, "add", .{ .a = 0, .b = 0 }));
}

test "stream cumulative acknowledgements enforce bounded nonblocking credits" {
    var router = R.init(session);
    var request = try call(&router, 1, 0, "watch", .{ .topic = "a" });
    defer request.deinit();
    const token = request.action.call.token;
    const first = try router.chunk("watch", allocator, token, "one");
    defer allocator.free(first);
    const second = try router.chunk("watch", allocator, token, "two");
    defer allocator.free(second);
    try std.testing.expectError(error.Backpressure, router.chunk("watch", allocator, token, "three"));
    try std.testing.expectError(error.InvalidAck, control(&router, token, "ack", 3));
    var ack = try control(&router, token, "ack", 1);
    defer ack.deinit();
    var duplicate = try control(&router, token, "ack", 1);
    defer duplicate.deinit();
    const third = try router.chunk("watch", allocator, token, "three");
    defer allocator.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\"sequence\":3") != null);
    try std.testing.expectError(error.Backpressure, router.chunk("watch", allocator, token, "four"));
    var cancel = try control(&router, token, "cancel", null);
    defer cancel.deinit();
    try std.testing.expectError(error.StaleRequest, router.chunk("watch", allocator, token, "late"));
}

test "session reset reports canceled work and rejects stale completions atomically" {
    var router = R.init(session);
    var request = try call(&router, 1, 0, "add", .{ .a = 1, .b = 2 });
    defer request.deinit();
    try std.testing.expectError(error.BufferTooSmall, router.reset(other_session, &.{}));
    try std.testing.expectEqual(1, router.active);
    try std.testing.expect(router.session.eql(session));
    var canceled: [2]ipc.Token = undefined;
    try std.testing.expectEqual(1, try router.reset(other_session, &canceled));
    try std.testing.expect(canceled[0].session.eql(session));
    try std.testing.expectError(error.StaleSession, router.complete("add", allocator, request.action.call.token, 0));
    try std.testing.expectError(error.StaleSession, control(&router, request.action.call.token, "cancel", null));
    var fresh = try call(&router, 1, 0, "add", .{ .a = 2, .b = 3 });
    defer fresh.deinit();
    try std.testing.expectError(error.SessionReused, router.reset(other_session, &canceled));
    try std.testing.expectEqual(1, try router.close(&canceled));
    try std.testing.expectError(error.Closed, call(&router, 2, 0, "add", .{ .a = 2, .b = 3 }));
}

test "encoding allocation failure preserves the pending request and stream credit" {
    var router = R.init(session);
    var request = try call(&router, 1, 0, "watch", .{ .topic = "a" });
    defer request.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, router.chunk("watch", failing.allocator(), request.action.call.token, "a"));
    try std.testing.expectEqual(0, router.slots[0].?.sent);
    try std.testing.expectError(error.OutOfMemory, router.complete("watch", failing.allocator(), request.action.call.token, {}));
    try std.testing.expectEqual(1, router.active);
}

test "strict envelope rejects numeric strings, extra fields and foreign versions" {
    var router = R.init(session);
    const base = "\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"method\":\"add\",\"params\":{\"a\":1,\"b\":2}";
    inline for (.{
        "{\"v\":\"1\",\"slot\":0,\"id\":1," ++ base ++ "}",
        "{\"v\":1,\"slot\":\"0\",\"id\":1," ++ base ++ "}",
        "{\"v\":1,\"slot\":0,\"id\":\"1\"," ++ base ++ "}",
        "{\"v\":1,\"slot\":0,\"id\":1,\"extra\":true," ++ base ++ "}",
        "{\"v\":1,\"v\":1,\"slot\":0,\"id\":1," ++ base ++ "}",
        "{\"v\":1,\"slot\":0,\"id\":0," ++ base ++ "}",
    }) |message| try std.testing.expectError(error.InvalidRequest, router.receive(allocator, message));
    try std.testing.expectError(error.UnsupportedVersion, router.receive(allocator, "{\"v\":2,\"slot\":0,\"id\":1," ++ base ++ "}"));
    try std.testing.expectError(error.InvalidParams, call(&router, 1, 0, "add", .{ .a = "1", .b = 2 }));
    try std.testing.expectError(error.InvalidParams, call(&router, 1, 0, "add", .{ .a = 1, .b = 2, .extra = true }));
    try std.testing.expectEqual(0, router.active);
    try std.testing.expectEqual(0, router.last_id);
}

test "void calls, nullable values and non-finite output preserve wire types" {
    const Types = struct {
        pub const methods = .{
            .ping = ipc.Method(void, struct { flag: ?bool }, enum { unavailable }, void),
            .float = ipc.Method(f32, f32, enum { unavailable }, void),
            .text = ipc.Method([2]u8, []const u8, enum { unavailable }, void),
        };
    };
    var router = ipc.Router(Types, .{}).init(session);
    const raw = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"ping\"}";
    var request = try router.receive(allocator, raw);
    defer request.deinit();
    const packet = try router.complete("ping", allocator, request.action.call.token, .{ .flag = null });
    defer allocator.free(packet);
    try std.testing.expect(std.mem.indexOf(u8, packet, "\"flag\":null") != null);
    const float_call = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":2,\"method\":\"float\",\"params\":1}";
    var number = try router.receive(allocator, float_call);
    defer number.deinit();
    try std.testing.expectError(error.NonFiniteNumber, router.complete("float", allocator, number.action.call.token, std.math.inf(f32)));
    try std.testing.expectEqual(1, router.active);
    const result = try router.complete("float", allocator, number.action.call.token, 1.5);
    defer allocator.free(result);
    const text_call = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":3,\"method\":\"text\",\"params\":\"hi\"}";
    var text = try router.receive(allocator, text_call);
    defer text.deinit();
    const bad: []const u8 = &.{0xff};
    try std.testing.expectError(error.InvalidUtf8, router.complete("text", allocator, text.action.call.token, bad));
    try std.testing.expectEqual(1, router.active);
}

test "receive and generator roll back every caller allocator failure" {
    const Scenario = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var router = R.init(session);
            const bytes = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"watch\",\"params\":{\"topic\":\"owned\"}}";
            var parsed = router.receive(alloc, bytes) catch |err| {
                std.debug.assert(router.active == 0 and router.last_id == 0);
                return err;
            };
            defer parsed.deinit();
            const result = try router.complete("watch", alloc, parsed.action.call.token, {});
            defer alloc.free(result);
            const generated = try ipc.generate(Service, alloc);
            defer alloc.free(generated);
            try std.testing.expect(std.mem.indexOf(u8, generated, "\"overflow\" | \"denied\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, generated, "export function createClient") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
}

test "oversized packets and requests fail before allocation or ownership transfer" {
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.MessageTooLarge, ipc.protocol.encode(failing.allocator(), .{ .value = "too large" }, 2));
    try std.testing.expectEqual(0, failing.alloc_index);
    const Small = ipc.Router(Service, .{ .max_pending = 1, .max_message_bytes = 8 });
    var router = Small.init(session);
    try std.testing.expectError(error.MessageTooLarge, router.receive(failing.allocator(), "123456789"));
    try std.testing.expectEqual(0, router.active);
    try std.testing.expectEqual(0, failing.alloc_index);
}

test "valid rejected calls expose a terminal reply without retaining a slot" {
    var router = R.init(session);
    var rejected: ?ipc.protocol.Rejected = null;
    const bytes = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"missing\",\"params\":{}}";
    try std.testing.expectError(error.UnknownMethod, router.receiveWithRejection(allocator, bytes, &rejected));
    try std.testing.expectEqual(ipc.protocol.Rejection.unknown_method, rejected.?.code);
    try std.testing.expectEqual(1, rejected.?.token.id);
    const packet = try ipc.protocol.reject(allocator, rejected.?.token, rejected.?.code, 65536);
    defer allocator.free(packet);
    try std.testing.expect(std.mem.indexOf(u8, packet, "\"kind\":\"reject\"") != null);
    try std.testing.expectEqual(0, router.active);
    try std.testing.expectError(error.InvalidRequest, router.receiveWithRejection(allocator, "{", &rejected));
    try std.testing.expect(rejected == null);
    var accepted = try call(&router, 1, 0, "add", .{ .a = 1, .b = 2 });
    defer accepted.deinit();
    const replay = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"add\",\"params\":{\"a\":1,\"b\":2}}";
    try std.testing.expectError(error.DuplicateRequest, router.receiveWithRejection(allocator, replay, &rejected));
    try std.testing.expect(rejected == null);
    try std.testing.expectEqual(1, router.active);
}

const ReenterAllocator = struct {
    router: *R,
    token: ipc.Token,
    action: enum { replace, close, reset, chunk, ack },
    armed: bool = true,
    after: usize = 0,
    calls: usize = 0,
    failure: ?anyerror = null,
    fn get(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn act(self: *@This()) !void {
        switch (self.action) {
            .replace => {
                const cancelled = try control(self.router, self.token, "cancel", null);
                defer cancelled.deinit();
                const next = try call(self.router, 2, 0, "watch", .{ .topic = "replacement" });
                defer next.deinit();
            },
            .close => {
                var cancelled: [2]ipc.Token = undefined;
                _ = try self.router.close(&cancelled);
            },
            .reset => {
                var cancelled: [2]ipc.Token = undefined;
                _ = try self.router.reset(other_session, &cancelled);
            },
            .chunk => {
                const packet = try self.router.chunk("watch", allocator, self.token, "inner");
                defer allocator.free(packet);
            },
            .ack => {
                const ack = try control(self.router, self.token, "ack", 1);
                defer ack.deinit();
            },
        }
    }
    fn fire(self: *@This()) void {
        if (!self.armed) return;
        const index = self.calls;
        self.calls += 1;
        if (index < self.after) return;
        self.armed = false;
        self.act() catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.fire();
        return allocator.rawAlloc(size, alignment, address);
    }
    // In-place growth depends on the backing allocator's history, which
    // would make the call sequence differ between the counting run and the
    // probes. Refusing it keeps every run on the same allocate-and-copy path.
    fn resize(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.fire();
        return false;
    }
    fn remap(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.fire();
        return null;
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        allocator.rawFree(bytes, alignment, address);
    }
};

test "allocator cancellation cannot let an old encoded reply mutate a replacement slot" {
    inline for (.{ .chunk, .complete, .fail }) |operation| {
        var router = R.init(session);
        const request = try call(&router, 1, 0, "watch", .{ .topic = "old" });
        defer request.deinit();
        var probe: ReenterAllocator = .{ .router = &router, .token = request.action.call.token, .action = .replace };
        const attempt = switch (operation) {
            .chunk => router.chunk("watch", probe.get(), probe.token, "outer"),
            .complete => router.complete("watch", probe.get(), probe.token, {}),
            .fail => router.fail("watch", probe.get(), probe.token, .unavailable, "outer"),
            else => unreachable,
        };
        defer if (attempt) |packet| probe.get().free(packet) else |_| {};
        if (probe.failure) |err| return err;
        try std.testing.expectError(error.StaleRequest, attempt);
        try std.testing.expect(!router.contains(probe.token));
        try std.testing.expect(router.contains(.{ .session = session, .slot = 0, .id = 2 }));
        try std.testing.expectEqual(@as(u32, 0), router.slots[0].?.sent);
        try std.testing.expectEqual(@as(usize, 1), router.active);
    }
}

test "allocator close or reset cannot publish a parsed request into the new router" {
    const raw = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"call\",\"slot\":0,\"id\":1,\"method\":\"watch\",\"params\":{\"topic\":\"owned\"}}";
    var baseline = R.init(session);
    var counter: ReenterAllocator = .{ .router = &baseline, .token = .{ .session = session, .slot = 0, .id = 1 }, .action = .close, .after = std.math.maxInt(usize) };
    const counted = try baseline.receive(counter.get(), raw);
    defer counted.deinit();
    try std.testing.expect(counter.calls > 1);
    inline for (.{ .close, .reset }) |action| {
        for (0..counter.calls) |index| {
            var router = R.init(session);
            var probe: ReenterAllocator = .{ .router = &router, .token = .{ .session = session, .slot = 0, .id = 1 }, .action = action, .after = index };
            const attempt = router.receive(probe.get(), raw);
            defer if (attempt) |received| received.deinit() else |_| {};
            if (probe.failure) |err| return err;
            try std.testing.expect(!probe.armed);
            try std.testing.expectError(if (action == .close) error.Closed else error.StaleSession, attempt);
            try std.testing.expectEqual(@as(usize, 0), router.active);
        }
    }
}

test "contains checks current session slot generation and closure without retaining a request" {
    var router = R.init(session);
    const request = try call(&router, 1, 0, "watch", .{ .topic = "live" });
    defer request.deinit();
    const token = request.action.call.token;
    try std.testing.expect(router.contains(token));
    try std.testing.expect(!router.contains(.{ .session = other_session, .slot = 0, .id = 1 }));
    try std.testing.expect(!router.contains(.{ .session = session, .slot = 2, .id = 1 }));
    try std.testing.expect(!router.contains(.{ .session = session, .slot = 0, .id = 2 }));
    try std.testing.expectEqual(@as(usize, 1), router.active);
    var cancelled: [2]ipc.Token = undefined;
    _ = try router.close(&cancelled);
    try std.testing.expect(!router.contains(token));
}

test "nested stream encoding cannot reuse a sequence but valid ACK remains allowed" {
    inline for (.{ .chunk, .ack }) |action| {
        var router = R.init(session);
        const request = try call(&router, 1, 0, "watch", .{ .topic = "old" });
        defer request.deinit();
        if (action == .ack) {
            const first = try router.chunk("watch", allocator, request.action.call.token, "first");
            allocator.free(first);
        }
        var probe: ReenterAllocator = .{ .router = &router, .token = request.action.call.token, .action = action };
        const attempt = router.chunk("watch", probe.get(), probe.token, "outer");
        defer if (attempt) |packet| probe.get().free(packet) else |_| {};
        if (probe.failure) |err| return err;
        if (action == .chunk) {
            try std.testing.expectError(error.StreamChanged, attempt);
            try std.testing.expectEqual(@as(u32, 1), router.slots[0].?.sent);
        } else {
            _ = try attempt;
            try std.testing.expectEqual(@as(u32, 2), router.slots[0].?.sent);
            try std.testing.expectEqual(@as(u32, 1), router.slots[0].?.acknowledged);
        }
    }
}
