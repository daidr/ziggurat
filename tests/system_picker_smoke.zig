const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

const State = struct {
    app: *z.App,
    owner: system.Owner = undefined,
    result: ?system.picker.Result = null,
    destination: [4096]u8 = undefined,
    fn action(_: *anyopaque, _: z.Window, _: system.Action) void {}
    fn completed(ptr: *anyopaque, window: z.Window, result: system.picker.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        self.result = result;
        std.debug.assert(self.owner.picker.native == null);
        _ = window.destroy() catch unreachable;
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    for ([_]system.picker.Kind{ .open_file, .save_file, .open_files, .folder }) |kind| {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var state: State = .{ .app = app };
        state.owner = system.Owner.init(&state, State.action);
        const window = try app.createWindow(.{ .title = "Async picker smoke" });
        try state.owner.attach(window);
        const launch = switch (kind) {
            .open_file => state.owner.openFile(.{}, &state.destination, &state, State.completed),
            .save_file => state.owner.saveFile(.{}, &state.destination, &state, State.completed),
            .open_files => state.owner.openFiles(.{}, &state.destination, &state, State.completed),
            .folder => state.owner.pickFolder(.{}, &state.destination, &state, State.completed),
        };
        launch catch |err| {
            std.debug.print("WinRT {s} picker failed before launch: {s}, HRESULT=0x{x}\n", .{ @tagName(kind), @errorName(err), @as(u32, @bitCast(state.owner.picker.last_hresult)) });
            return err;
        };
        try std.testing.expect(state.result == null);
        try std.testing.expectError(error.DialogAlreadyPending, state.owner.openFile(.{}, &state.destination, &state, State.completed));
        try state.owner.cancelFileDialog();
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        try std.testing.expect(!watchdog.expired);
        if (state.result) |result| if (result == .failed) std.debug.print("WinRT {s} picker completion failed: {any}\n", .{ @tagName(kind), result.failed });
        try std.testing.expect(state.result != null and state.result.? == .cancelled);
        try std.testing.expect(state.owner.window == null);
        std.debug.print("WinRT {s}: async cancel completed, native states={d}\n", .{ @tagName(kind), system.picker.resourceCount() });
    }
    // Closing the sole native window immediately after launch removes the
    // one-shot wait and disconnects Zig without running an extra message loop.
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var state: State = .{ .app = app };
        state.owner = system.Owner.init(&state, State.action);
        const window = try app.createWindow(.{});
        try state.owner.attach(window);
        try state.owner.openFile(.{}, &state.destination, &state, State.completed);
        _ = try window.destroy();
        try std.testing.expect(state.owner.window == null and state.owner.picker.native == null and state.owner.picker.wait == null);
        try std.testing.expect(state.result == null);
    }
    const native = system.picker.resourceCount();
    std.debug.print("WinRT picker smoke passed: open/save/multiple/folder native async cancellation, sole-window immediate closure disconnects callbacks, remaining native states={d}\n", .{native});
}
