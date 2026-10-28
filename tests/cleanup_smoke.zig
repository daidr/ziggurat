const std = @import("std");
const z = @import("ziggurat");
const c = @import("ziggurat_c_win32");
const message_id = c.WM_APP + 701;
const State = struct {
    app: *z.App,
    window: z.Window,
    node: z.Cleanup = undefined,
    tasks: usize = 0,
    releases: usize = 0,
    send_result: isize = 0,
    fn task(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.tasks += 1;
    }
    fn release(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        std.debug.assert(c.InSendMessageEx(null) & c.ISMEX_SEND == 0);
        std.debug.assert(self.tasks == 256 and !self.node.queued);
        self.releases += 1;
    }
    fn native(ptr: *anyopaque, _: z.Window, message: u32, _: usize, _: isize) ?isize {
        if (message != message_id) return null;
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.assert(c.InSendMessageEx(null) & c.ISMEX_SEND != 0);
        for (0..256) |_| self.app.post(.{ .context = self, .call = task }) catch unreachable;
        std.testing.expectError(error.Full, self.app.post(.{ .context = self, .call = task })) catch unreachable;
        self.app.quit();
        self.app.deferCleanup(&self.node);
        self.app.dispatch() catch unreachable;
        std.debug.assert(self.releases == 0);
        return 0x55;
    }
    fn destroying(_: *anyopaque) void {}
    fn producer(self: *State, hwnd: c.HWND) void {
        self.send_result = c.SendMessageW(hwnd, message_id, 0, 0);
    }
};
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{});
    var state: State = .{ .app = app, .window = window };
    state.node = .{ .task = .{ .context = &state, .call = State.release } };
    try window.setService(.{ .context = &state, .message = State.native, .native_destroying = State.destroying });
    const producer = try std.Thread.spawn(.{}, State.producer, .{ &state, @as(c.HWND, @ptrCast(window.nativeHandle())) });
    try app.run();
    producer.join();
    try std.testing.expectEqual(0x55, state.send_result);
    try std.testing.expectEqual(256, state.tasks);
    try std.testing.expectEqual(1, state.releases);
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    std.debug.print("cleanup smoke passed: unreplied cross-thread SendMessage, full/closed mailbox, shutdown releases only after native callback returns\n", .{});
}
