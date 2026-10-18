const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

const State = struct {
    clicks: usize = 0,
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
        frame.pushClip(.{ .x = 0, .y = 0, .width = 80, .height = 60 }) catch unreachable;
        frame.button(7, .{ .x = 0, .y = 0, .width = 120, .height = 60 }, "Test") catch unreachable;
        frame.popClip() catch unreachable;
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (id == 7) self.clicks += 1;
    }
    fn close(ptr: *anyopaque) void {
        const window: *z.Window = @ptrCast(@alignCast(ptr));
        _ = window.destroy() catch unreachable;
        _ = window.destroy() catch unreachable;
    }
    fn post(window: *z.Window) void {
        window.app.post(.{ .context = window, .call = close }) catch unreachable;
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    // Repeated App lifetimes also catch stale WM_QUIT and singleton state.
    for (0..3) |_| {
        var state: State = .{};
        var content = ui.Context.init(&state, State.draw, State.action);
        content.render_mode = .gdi;
        const app = try z.App.init(gpa.allocator());
        defer app.deinit();
        try std.testing.expectError(error.AppAlreadyExists, z.App.init(gpa.allocator()));
        var window = try app.createWindow(.{ .width = 320, .height = 200 });
        try content.attach(window);
        const hwnd: c.HWND = @ptrCast(@alignCast(window.nativeHandle()));
        // Exercise the real GDI paint path without showing a window.
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        try std.testing.expect(content.frames > 0);
        const outside_x: c_int = @intFromFloat(110 * content.renderer.scale);
        const outside_y: c_int = @intFromFloat(10 * content.renderer.scale);
        try std.testing.expectEqual(@as(c.COLORREF, 0xffffff), c.GetPixel(content.renderer.dc, outside_x, outside_y));
        const frames = content.frames;
        for (0..2) |_| {
            _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, (10 << 16) | 10);
            _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, (10 << 16) | 10);
        }
        try std.testing.expectEqual(2, state.clicks);
        try std.testing.expectEqual(frames, content.frames);
        const outside: c.LPARAM = (@as(c.LPARAM, outside_y) << 16) | @as(c.LPARAM, outside_x);
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, outside);
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, outside);
        try std.testing.expectEqual(2, state.clicks);
        const producer = try std.Thread.spawn(.{}, State.post, .{&window});
        producer.join();
        try app.run();
        try std.testing.expect(window.isClosed());
        try std.testing.expect(content.window == null);
        try std.testing.expectError(error.Closed, app.post(.{ .context = &window, .call = State.close }));
    }
    std.debug.print("native smoke passed: paint, consecutive clicks, dispatch, repeated shutdown\n", .{});
}
