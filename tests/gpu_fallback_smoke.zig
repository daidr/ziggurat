const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
const State = struct {
    draws: usize = 0,
    context: ?*ui.Context = null,
    window: ?z.Window = null,
    close_after: usize = 0,
    closed_after_present: bool = false,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0xffffff);
        frame.rect(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 0x123456);
        if (self.close_after != 0 and self.draws == self.close_after) self.window.?.app.post(.{ .context = self, .call = close }) catch unreachable;
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn close(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const context = self.context.?;
        self.closed_after_present = context.gpu_frames >= 2 and context.gpu_wait == null and context.gdi_frames == 0;
        _ = self.window.?.destroy() catch unreachable;
    }
};
fn fallback(allocator: std.mem.Allocator) !void {
    var recorder: z.diagnostics.Recorder(8) = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = recorder.sink() });
    defer app.deinit();
    var state: State = .{};
    var context = ui.Context.init(&state, State.draw, State.action);
    const window = try app.createWindow(.{});
    try context.attach(window);
    try std.testing.expect(!context.gpu_unavailable);
    const hwnd = window.nativeHandle();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(1, context.gpu_frames);
    context.gpu_renderer.injectDeviceLoss();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(1, context.gdi_frames);
    try std.testing.expectEqual(1, context.fallbacks);
    try std.testing.expectEqual(@as(c.COLORREF, 0x563412), c.GetPixel(context.renderer.dc, 5, 5));
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(2, context.gpu_frames);
    try std.testing.expectEqual(3, context.frames);
    try std.testing.expectEqual(3, state.draws);
    var entries: [8]z.diagnostics.Diagnostic = undefined;
    try std.testing.expectEqual(1, recorder.snapshot(&entries).count);
    try std.testing.expectEqual(error.DeviceLost, entries[0].err.?);
    try std.testing.expectEqual(@as(?u32, 0x887a0005), entries[0].code);
    _ = try window.destroy();
    try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
    try std.testing.expect(!context.hasSurface());
}
fn ready(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var context = ui.Context.init(&state, State.draw, State.action);
    const window = try app.createWindow(.{});
    try context.attach(window);
    state.context = &context;
    state.window = window;
    const hwnd = window.nativeHandle();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    const surface = context.gpu_renderer.surfaceForTest().?;
    context.gpu_renderer.injectPresentationBusy();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expect(context.gpu_wait != null);
    const token = context.gpu_wait.?;
    const draws = state.draws;
    for (0..8) |_| _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(draws, state.draws);
    try std.testing.expectEqualDeep(token, context.gpu_wait.?);
    try std.testing.expect((@as(u32, @bitCast(c.GetWindowLongW(surface, c.GWL_STYLE))) & c.WS_VISIBLE) != 0);
    try std.testing.expectEqual(@as(usize, 0), context.gdi_frames);
    try std.testing.expectEqual(@as(usize, 0), context.fallbacks);
    state.close_after = draws + 1;
    // WM_PAINT is suppressed for hidden windows. An offscreen nonactivating
    // tool window exercises native invalidation without displaying test content.
    const extended = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    _ = c.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, extended | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE);
    try std.testing.expect(c.SetWindowPos(hwnd, null, -32000, -32000, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW) != 0);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    watchdog.stop();
    if (watchdog.expired) std.debug.print("ready fixture timed out: draws={d}, gpu={d}, gdi={d}, wait={any}, deferred={d}\n", .{ state.draws, context.gpu_frames, context.gdi_frames, context.gpu_wait != null, context.deferred_frames });
    try std.testing.expect(!watchdog.expired);
    try std.testing.expect(state.closed_after_present);
    try std.testing.expect(context.gpu_wait == null and context.window == null);
    try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
}
fn cancelAndResize(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var context = ui.Context.init(&state, State.draw, State.action);
    const window = try app.createWindow(.{});
    try context.attach(window);
    const hwnd = window.nativeHandle();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    context.gpu_renderer.injectPresentationBusy();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    const previous = context.gpu_wait.?;
    try window.resize(800, 540);
    context.gpu_renderer.injectPresentationBusy();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    const replacement = context.gpu_wait.?;
    try std.testing.expect(!app.unwatchNative(previous));
    try std.testing.expect(previous.index != replacement.index or previous.generation != replacement.generation);
    _ = try window.destroy();
    try std.testing.expect(context.gpu_wait == null);
    for (app.native.waits) |wait| try std.testing.expect(wait.handle == null);
    try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    // Entering the actual pump after resource release catches stale borrowed handles.
    try app.run();
}
pub fn main() !void {
    var allocator_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator_state.deinit() == .ok);
    try fallback(allocator_state.allocator());
    try ready(allocator_state.allocator());
    try cancelAndResize(allocator_state.allocator());
    std.debug.print("GPU fallback smoke passed: single draw per frame, same commands replayed on GDI, next frame recovers, resources=0\n", .{});
    std.debug.print("GPU backpressure smoke passed: one-shot ready repaint, same-size merge, resize cancellation, pending-watch close\n", .{});
}
