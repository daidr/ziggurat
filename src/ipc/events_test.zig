const std = @import("std");
const ipc = @import("root.zig");
const allocator = std.testing.allocator;
const Schema = struct {
    pub const events = .{
        .changed = ipc.Event(struct { path: []const u8, revision: u32 }),
        .reset = ipc.Event(void),
        .number = ipc.Event(f64),
    };
};
const E = ipc.EventSession(Schema, .{ .max_subscriptions = 2, .max_broadcast_targets = 4 });
const session = ipc.Session.init("00000000000000000000000000000001") catch unreachable;
const other = ipc.Session.init("00000000000000000000000000000002") catch unreachable;
const third = ipc.Session.init("00000000000000000000000000000003") catch unreachable;
const fourth = ipc.Session.init("00000000000000000000000000000004") catch unreachable;

const EncodingReentry = struct {
    events: *E,
    action: enum { close, reset, replace },
    armed: bool = true,
    failure: ?anyerror = null,
    fn get(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn change(self: *@This()) !void {
        switch (self.action) {
            .close => self.events.close(),
            .reset => {
                try self.events.reset(other);
                _ = try control(self.events, "subscribe", "changed", 1);
            },
            .replace => {
                _ = try control(self.events, "unsubscribe", "changed", 1);
                _ = try control(self.events, "subscribe", "changed", 2);
            },
        }
    }
    fn alloc(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.armed) {
            self.armed = false;
            self.change() catch |err| {
                self.failure = err;
            };
        }
        return allocator.rawAlloc(size, alignment, address);
    }
    fn resize(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        return allocator.rawResize(bytes, alignment, size, address);
    }
    fn remap(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        return allocator.rawRemap(bytes, alignment, size, address);
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        allocator.rawFree(bytes, alignment, address);
    }
};

test "event encoding cannot retarget old work after allocator reload or subscription replacement" {
    inline for (.{ .close, .reset, .replace }) |action| {
        var events = E.init(session);
        _ = try control(&events, "subscribe", "changed", 1);
        const token = events.token("changed");
        var probe: EncodingReentry = .{ .events = &events, .action = action };
        const attempt = events.emit("changed", probe.get(), token, .{ .path = "old", .revision = 1 });
        defer if (attempt) |packet| probe.get().free(packet) else |_| {};
        if (probe.failure) |err| return err;
        try std.testing.expectError(switch (action) {
            .close => error.Closed,
            .reset => error.StaleSession,
            .replace => error.StaleSubscription,
            else => unreachable,
        }, attempt);
    }
}

fn control(events: *E, kind: []const u8, event: []const u8, subscription: u32) !E.Change {
    const bytes = try ipc.protocol.encode(allocator, .{ .v = 1, .session = &events.session.bytes, .kind = kind, .event = event, .subscription = subscription }, 65536);
    defer allocator.free(bytes);
    return events.receive(allocator, bytes);
}

test "event subscriptions are bounded idempotent and independent of RPC slots" {
    var events = E.init(session);
    try std.testing.expectEqual(E.Change.subscribed, try control(&events, "subscribe", "changed", 1));
    const token = events.token("changed");
    try std.testing.expectEqual(E.Change.unchanged, try control(&events, "subscribe", "changed", 1));
    try std.testing.expectEqual(E.Change.subscribed, try control(&events, "subscribe", "reset", 2));
    try std.testing.expectError(error.Full, control(&events, "subscribe", "number", 3));
    try std.testing.expectEqual(2, events.active);
    try std.testing.expectEqual(2, events.last_subscription);
    const bytes = try events.emit("changed", allocator, token, .{ .path = "文档", .revision = 7 });
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("event", parsed.value.object.get("kind").?.string);
    try std.testing.expect(parsed.value.object.get("slot") == null);
    try std.testing.expect(parsed.value.object.get("id") == null);
    try std.testing.expectEqual(E.Change.unchanged, try control(&events, "unsubscribe", "changed", 99));
    try std.testing.expectEqual(E.Change.unsubscribed, try control(&events, "unsubscribe", "changed", 1));
    try std.testing.expectEqual(E.Change.unchanged, try control(&events, "unsubscribe", "changed", 1));
    try std.testing.expectError(error.StaleSubscription, control(&events, "subscribe", "changed", 1));
    try std.testing.expectError(error.StaleSubscription, events.emit("changed", allocator, token, .{ .path = "old", .revision = 0 }));
    try std.testing.expectEqual(E.Change.subscribed, try control(&events, "subscribe", "changed", 3));
    try std.testing.expectError(error.StaleSubscription, events.emit("changed", allocator, token, .{ .path = "old", .revision = 0 }));
    try std.testing.expectError(error.WrongEvent, events.emit("reset", allocator, events.token("changed"), {}));
}

test "close and reload invalidate captured event work and old controls" {
    var events = E.init(session);
    _ = try control(&events, "subscribe", "changed", 1);
    const old = events.token("changed");
    events.close();
    events.close();
    try std.testing.expectEqual(0, events.active);
    try std.testing.expectError(error.Closed, events.emit("changed", allocator, old, .{ .path = "late", .revision = 0 }));
    try std.testing.expectError(error.Closed, control(&events, "subscribe", "changed", 2));
    try std.testing.expectError(error.SessionReused, events.reset(session));
    try events.reset(other);
    _ = try control(&events, "subscribe", "changed", 1);
    try std.testing.expectError(error.StaleSession, events.emit("changed", allocator, old, .{ .path = "late", .revision = 0 }));
    const stale = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"unsubscribe\",\"event\":\"changed\",\"subscription\":1}";
    try std.testing.expectError(error.StaleSession, events.receive(allocator, stale));
    try std.testing.expectEqual(1, events.active);
}

test "event envelopes reject malformed duplicate foreign and unknown fields atomically" {
    var events = E.init(session);
    const base = "\"session\":\"00000000000000000000000000000001\",\"kind\":\"subscribe\",\"event\":\"changed\"";
    inline for (.{
        "{\"v\":1,\"subscription\":\"1\"," ++ base ++ "}",
        "{\"v\":1,\"subscription\":0," ++ base ++ "}",
        "{\"v\":1,\"subscription\":4294967296," ++ base ++ "}",
        "{\"v\":1,\"subscription\":1,\"extra\":true," ++ base ++ "}",
        "{\"v\":1,\"v\":1,\"subscription\":1," ++ base ++ "}",
        "{\"v\":\"1\",\"subscription\":1," ++ base ++ "}",
    }) |message| try std.testing.expectError(error.InvalidRequest, events.receive(allocator, message));
    try std.testing.expectError(error.UnsupportedVersion, events.receive(allocator, "{\"v\":2,\"subscription\":1," ++ base ++ "}"));
    try std.testing.expectError(error.UnknownEvent, control(&events, "subscribe", "missing", 1));
    try std.testing.expectError(error.InvalidRequest, control(&events, "call", "changed", 1));
    try std.testing.expectEqual(0, events.active);
    try std.testing.expectEqual(0, events.last_subscription);
}

test "event receive and encoding preserve subscriptions at allocator and size failures" {
    const Scenario = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var events = E.init(session);
            const message = "{\"v\":1,\"session\":\"00000000000000000000000000000001\",\"kind\":\"subscribe\",\"event\":\"changed\",\"subscription\":1}";
            _ = events.receive(alloc, message) catch |err| {
                std.debug.assert(events.active == 0 and events.last_subscription == 0);
                return err;
            };
            const bytes = try events.emit("changed", alloc, events.token("changed"), .{ .path = "owned", .revision = 1 });
            defer alloc.free(bytes);
            const generated = try ipc.generate(Schema, alloc);
            defer alloc.free(generated);
            try std.testing.expect(std.mem.indexOf(u8, generated, "export type Events") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
    var events = E.init(session);
    _ = try control(&events, "subscribe", "changed", 1);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, events.emit("changed", failing.allocator(), events.token("changed"), .{ .path = "x", .revision = 1 }));
    try std.testing.expectEqual(1, events.active);
    _ = try control(&events, "subscribe", "number", 2);
    try std.testing.expectError(error.NonFiniteNumber, events.emit("number", allocator, events.token("number"), std.math.inf(f64)));
    const Small = ipc.EventSession(Schema, .{ .max_message_bytes = 2 });
    var small = Small.init(session);
    try std.testing.expectError(error.MessageTooLarge, small.receive(failing.allocator(), "123"));
    try std.testing.expectEqual(0, failing.alloc_index);
}

test "pure RPC schemas retain previously valid names while event schemas remain independent" {
    const Legacy = struct {
        pub const methods = .{
            .on = ipc.Method(void, bool, enum { denied }, void),
            .listenerCount = ipc.Method(void, u8, enum { denied }, void),
            .subscriptionCount = ipc.Method(void, u8, enum { denied }, void),
        };
    };
    try std.testing.expectEqual(3, ipc.schema.methods(Legacy).len);
    const generated = try ipc.generate(Legacy, allocator);
    defer allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "export type Events = {\n};") != null);
}

test "explicit broadcast reports ordered partial failure and preflights before sending" {
    const Sink = struct {
        count: usize = 0,
        fail: bool = false,
        fn send(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.fail) return error.TransportFull;
            try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"event\"") != null);
            self.count += 1;
        }
    };
    var states = [_]E{ E.init(session), E.init(other), E.init(third), E.init(fourth) };
    for (states[0..3]) |*events| _ = try control(events, "subscribe", "changed", 1);
    var sinks = [_]Sink{ .{}, .{ .fail = true }, .{}, .{} };
    var targets: [4]E.Target = undefined;
    for (&targets, &states, &sinks) |*target, *events, *sink| target.* = .{ .events = events, .token = events.token("changed"), .context = sink, .send = Sink.send };
    var outcomes: [4]E.Delivery = undefined;
    try std.testing.expectError(error.BufferTooSmall, E.broadcast("changed", allocator, &targets, .{ .path = "x", .revision = 1 }, outcomes[0..3]));
    try std.testing.expectEqual(0, sinks[0].count);
    const duplicate = [_]E.Target{ targets[0], targets[0] };
    try std.testing.expectError(error.DuplicateSession, E.broadcast("changed", allocator, &duplicate, .{ .path = "x", .revision = 1 }, &outcomes));
    var stale_duplicate = duplicate;
    stale_duplicate[1].token.session = other;
    try std.testing.expectError(error.DuplicateSession, E.broadcast("changed", allocator, &stale_duplicate, .{ .path = "x", .revision = 1 }, &outcomes));
    try std.testing.expectEqual(0, sinks[0].count);
    const report = try E.broadcast("changed", allocator, &targets, .{ .path = "x", .revision = 1 }, &outcomes);
    try std.testing.expectEqual(2, report.sent);
    try std.testing.expectEqual(1, report.failed);
    try std.testing.expectEqual(1, report.not_subscribed);
    try std.testing.expectEqual(error.TransportFull, outcomes[1].failed);
    try std.testing.expectEqual(1, sinks[0].count);
    try std.testing.expectEqual(1, sinks[2].count);
    sinks[1].fail = false;
    const retry = try E.broadcast("changed", allocator, targets[1..2], .{ .path = "x", .revision = 1 }, &outcomes);
    try std.testing.expectEqual(1, retry.sent);
    try std.testing.expectEqual(1, sinks[1].count);
    try states[2].reset(session);
    const stale = try E.broadcast("changed", allocator, targets[2..3], .{ .path = "x", .revision = 1 }, &outcomes);
    try std.testing.expectEqual(1, stale.failed);
    try std.testing.expectEqual(error.StaleSession, outcomes[0].failed);
}
