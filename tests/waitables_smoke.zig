const std = @import("std");
const z = @import("ziggurat");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const State = struct {
    app: *z.App,
    window: z.Window,
    event: c.HANDLE,
    token: z.NativeWaitToken = undefined,
    signals: usize = 0,
    tasks: usize = 0,
    fn noCall(_: *anyopaque) void {
        @panic("unsignaled native wait executed");
    }
    fn task(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.tasks += 1;
        if (self.signals == 0) self.app.post(.{ .context = self, .call = task }) catch unreachable;
    }
    fn signal(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.app.unwatchNative(self.token));
        self.signals += 1;
        if (self.signals == 1) {
            self.token = self.app.watchNative(self.event.?, .{ .context = self, .call = signal }) catch unreachable;
        } else {
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
        }
    }
    fn producer(self: *@This()) void {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        std.debug.assert(c.SetEvent(self.event) != 0);
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{});
    const signal_event = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEventFailed;
    defer _ = c.CloseHandle(signal_event);
    var state: State = .{ .app = app, .window = window, .event = signal_event };
    var handles: [16]c.HANDLE = @splat(null);
    defer for (handles) |handle| if (handle != null) {
        _ = c.CloseHandle(handle);
    };
    var tokens: [16]z.NativeWaitToken = undefined;
    for (&handles, &tokens) |*handle, *token| {
        handle.* = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEventFailed;
        token.* = try app.watchNative(handle.*.?, .{ .context = &state, .call = State.noCall });
    }
    try std.testing.expectError(error.AlreadyWatched, app.watchNative(handles[0].?, .{ .context = &state, .call = State.noCall }));
    try std.testing.expectError(error.TooManyWaitables, app.watchNative(signal_event, .{ .context = &state, .call = State.noCall }));
    for (tokens) |token| try std.testing.expect(app.unwatchNative(token));
    state.token = try app.watchNative(signal_event, .{ .context = &state, .call = State.signal });
    try std.testing.expect(!app.unwatchNative(tokens[state.token.index]));
    const canceled_on_shutdown = try app.watchNative(handles[0].?, .{ .context = &state, .call = State.noCall });
    try app.post(.{ .context = &state, .call = State.task });
    const producer = try std.Thread.spawn(.{}, State.producer, .{&state});
    defer producer.join();
    try app.run();
    try std.testing.expectEqual(2, state.signals);
    try std.testing.expect(state.tasks > 0);
    try std.testing.expect(!app.unwatchNative(canceled_on_shutdown));
    try std.testing.expectError(error.Closed, app.watchNative(signal_event, .{ .context = &state, .call = State.noCall }));
    std.debug.print("native waitables smoke passed: fixed capacity, stale cancellation, one-shot/rearm and fairness under continuous tasks\n", .{});
}
