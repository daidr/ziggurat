const std = @import("std");
const z = @import("ziggurat");
const web = @import("ziggurat_webview");
const ipc = @import("ziggurat_ipc");
const Service = @import("counter_service").Service;
const limits: ipc.Limits = .{ .max_pending = 2, .max_in_flight = 2 };
const StreamWork = ipc.Work(Service, limits, "watch");
const Implementation = struct {
    pub fn add(_: *@This(), _: *State, params: Service.methods.add.Params) ipc.Reply(Service, "add") {
        if (params.a < 0) return .{ .failure = .{ .code = .denied, .message = "Negative input" } };
        const result = @addWithOverflow(params.a, params.b);
        if (result[1] != 0) return .{ .failure = .{ .code = .overflow, .message = "Integer overflow" } };
        return .{ .result = result[0] };
    }
    pub fn ping(_: *@This(), _: *State, _: void) ipc.Reply(Service, "ping") {
        return .{ .result = .{ .ok = true } };
    }
    pub fn watch(_: *@This(), state: *State, work: StreamWork) void {
        if (std.mem.eql(u8, work.params.topic, "news")) {
            std.debug.assert(state.stream_work == null);
            state.stream_work = work;
            state.stream = work.token;
        } else {
            // This request keeps only its protocol token until page cancellation.
            var owned = work;
            owned.deinit();
        }
    }
};
const Dispatcher = ipc.Dispatcher(Service, Implementation, State, limits);
const Events = ipc.EventSession(Service, .{});
const Watchdog = @import("watchdog.zig").Watchdog;
const html = "<!doctype html><meta charset=utf-8><script>" ++ @embedFile("ipc_page") ++ "</script>";
const State = struct {
    allocator: std.mem.Allocator,
    dispatcher: Dispatcher,
    implementation: Implementation = .{},
    events: Events,
    event_token: ?Events.Token = null,
    subscriptions: usize = 0,
    unsubscriptions: usize = 0,
    stream: ?ipc.Token = null,
    stream_work: ?StreamWork = null,
    sent: usize = 0,
    acknowledged: usize = 0,
    backpressure: usize = 0,
    cancellations: usize = 0,
    complete: bool = false,
    failure: ?anyerror = null,
    fn send(self: *@This(), view: *web.View, bytes: []u8) !void {
        defer self.allocator.free(bytes);
        view.post(bytes) catch |err| {
            var canceled: [2]ipc.Token = undefined;
            _ = self.dispatcher.router.close(&canceled) catch unreachable;
            self.events.close();
            return err;
        };
    }
    fn streamAvailable(self: *@This(), view: *web.View) !void {
        const token = self.stream orelse return;
        const values = [_][]const u8{ "one", "two", "three" };
        while (self.sent < values.len) {
            const packet = self.dispatcher.router.chunk("watch", self.allocator, token, values[self.sent]) catch |err| {
                if (err == error.Backpressure) {
                    self.backpressure += 1;
                    return;
                }
                return err;
            };
            self.sent += 1;
            try self.send(view, packet);
        }
        if (self.acknowledged == values.len) {
            try self.send(view, try self.dispatcher.router.complete("watch", self.allocator, token, {}));
            self.stream = null;
            self.stream_work.?.deinit();
            self.stream_work = null;
        }
    }
    fn message(self: *@This(), view: *web.View, text: []const u8) !void {
        if (std.mem.eql(u8, text, "ipc-boot")) {
            try self.send(view, try std.json.Stringify.valueAlloc(self.allocator, .{ .kind = "hello", .session = self.dispatcher.router.session.bytes[0..] }, .{}));
            return;
        }
        if (std.mem.eql(u8, text, "ipc-done")) {
            try std.testing.expectEqual(0, self.dispatcher.router.active);
            try std.testing.expect(self.stream_work == null);
            try std.testing.expectEqual(1, self.cancellations);
            try std.testing.expect(self.backpressure > 0);
            try std.testing.expectEqual(1, self.subscriptions);
            try std.testing.expectEqual(1, self.unsubscriptions);
            try std.testing.expectEqual(0, self.events.active);
            const old_token = self.event_token.?;
            try std.testing.expectError(error.StaleSubscription, self.events.emit("changed", self.allocator, old_token, .{ .path = "late", .revision = 8 }));
            var nonce: [16]u8 = undefined;
            std.crypto.random.bytes(&nonce);
            const replacement = std.fmt.bytesToHex(nonce, .lower);
            try self.events.reset(try ipc.Session.init(&replacement));
            try std.testing.expectEqual(0, self.events.active);
            try std.testing.expectError(error.StaleSession, self.events.emit("changed", self.allocator, old_token, .{ .path = "late", .revision = 8 }));
            self.events.close();
            try std.testing.expectError(error.Closed, self.events.emit("changed", self.allocator, self.events.token("changed"), .{ .path = "closed", .revision = 9 }));
            self.complete = true;
            _ = try view.window.?.destroy();
            return;
        }
        if (std.mem.startsWith(u8, text, "ipc-failed:")) {
            std.debug.print("{s}\n", .{text});
            return error.PageFailed;
        }
        if (std.mem.eql(u8, text, "ipc-events-ready")) {
            try std.testing.expectEqual(1, self.events.active);
            const captured = self.events.token("changed");
            self.event_token = captured;
            try self.send(view, try self.events.emit("changed", self.allocator, captured, .{ .path = "文档.txt", .revision = 7 }));
            // This packet is already queued when the first callback removes its
            // subscription; the page must ignore the retired subscription ID.
            try self.send(view, try self.events.emit("changed", self.allocator, captured, .{ .path = "late", .revision = 8 }));
            return;
        }
        if (text.len > 65536) return error.MessageTooLarge;
        const routed = try std.json.parseFromSlice(std.json.Value, self.allocator, text, .{});
        defer routed.deinit();
        if (routed.value == .object) if (routed.value.object.get("kind")) |kind| {
            if (kind == .string and (std.mem.eql(u8, kind.string, "subscribe") or std.mem.eql(u8, kind.string, "unsubscribe"))) {
                switch (try self.events.receiveValue(routed.value)) {
                    .subscribed => self.subscriptions += 1,
                    .unsubscribed => self.unsubscriptions += 1,
                    .unchanged => {},
                }
                return;
            }
        };
        var action = try self.dispatcher.dispatch(self.allocator, &self.implementation, self, text);
        switch (action) {
            .reply => |*pending| {
                defer pending.deinit();
                try self.send(view, try pending.encode(&self.dispatcher.router, self.allocator));
            },
            .taken => try self.streamAvailable(view),
            .ack => |ack| {
                self.acknowledged = ack.sequence;
                try self.streamAvailable(view);
            },
            .cancel => self.cancellations += 1,
            .rejected => |rejected| try self.send(view, try ipc.protocol.reject(self.allocator, rejected.token, rejected.code, 65536)),
        }
    }
    fn event(ptr: *anyopaque, view: *web.View, ev: web.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (ev) {
            .message => |text| self.message(view, text) catch |err| {
                self.failure = err;
                self.events.close();
                var canceled: [2]ipc.Token = undefined;
                _ = self.dispatcher.router.close(&canceled) catch unreachable;
                view.window.?.app.quit();
            },
            .failed => {
                self.failure = error.WebViewFailed;
                self.events.close();
                view.window.?.app.quit();
            },
            else => {},
        }
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const session = std.fmt.bytesToHex(nonce, .lower);
    const identity = try ipc.Session.init(&session);
    var state: State = .{ .allocator = allocator, .dispatcher = Dispatcher.init(identity), .events = Events.init(identity) };
    defer {
        state.events.close();
        if (state.stream_work) |*work| work.deinit();
    }
    const app = try z.App.init(allocator);
    defer app.deinit();
    var view = web.View.init(allocator, &state, State.event);
    const window = try app.createWindow(.{});
    const local = try std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
    defer allocator.free(local);
    const profile = try std.fs.path.join(allocator, &.{ local, "Ziggurat", "IpcSmoke" });
    defer allocator.free(profile);
    try view.attach(window, .{ .html = html, .user_data_folder = profile });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |err| return err;
    try std.testing.expect(state.complete);
    try std.testing.expectEqual(0, web.resourceCounts().states);
    try std.testing.expectEqual(0, state.events.active);
    std.debug.print("typed IPC WebView smoke passed: generated JS/TS client, compile-time dispatcher, owned replies/stream work, typed events/unsubscribe/late suppression/reset, typed errors, stream/ACK backpressure, cancellation, pending=0 subscriptions=0\n", .{});
}
