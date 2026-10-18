const std = @import("std");
const z = @import("ziggurat");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});

const Probe = struct {
    in_resize: bool = false,
    resizes: usize = 0,
    detaches: usize = 0,
    notifications: usize = 0,

    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (value != .resize) return;
        self.in_resize = true;
        defer self.in_resize = false;
        self.resizes += 1;
        std.debug.assert(c.DestroyWindow(window.nativeHandle()) != 0);
        std.debug.assert(window.isClosed() and window.nativeHandle() == null);
        std.debug.assert(self.detaches == 0 and self.notifications == 0);
    }
    fn detach(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.in_resize);
        self.detaches += 1;
    }
    fn closed(ptr: *anyopaque, window: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.in_resize and self.detaches == 1);
        std.debug.assert(window.isClosed() and window.nativeHandle() == null);
        self.notifications += 1;
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    const witness = try app.createWindow(.{ .title = "Invalidation witness" });
    const witness_hwnd: c.HWND = witness.nativeHandle();
    for ([_]bool{ false, true }) |dpi_change| {
        var probe: Probe = .{};
        const window = try app.createWindow(.{ .width = 320, .height = 200, .on_closed = .{ .context = &probe, .notify = Probe.closed } });
        try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        const hwnd: c.HWND = window.nativeHandle();
        // A post-callback InvalidateRect(NULL) would also invalidate this unrelated
        // native window. No message loop or repaint is run between these checks.
        try std.testing.expect(c.ValidateRect(witness_hwnd, null) != 0);
        try std.testing.expect(c.GetUpdateRect(witness_hwnd, null, c.FALSE) == 0);
        if (dpi_change) {
            var rect: c.RECT = undefined;
            try std.testing.expect(c.GetWindowRect(hwnd, &rect) != 0);
            rect.right += 17;
            rect.bottom += 11;
            _ = c.SendMessageW(hwnd, c.WM_DPICHANGED, (144 << 16) | 144, @bitCast(@intFromPtr(&rect)));
        } else {
            _ = c.SendMessageW(hwnd, c.WM_SIZE, c.SIZE_RESTORED, (200 << 16) | 320);
        }
        try std.testing.expectEqual(1, probe.resizes);
        try std.testing.expectEqual(0, probe.detaches);
        try std.testing.expectEqual(0, probe.notifications);
        try std.testing.expect(c.GetUpdateRect(witness_hwnd, null, c.FALSE) == 0);
        try app.dispatch();
        try std.testing.expectEqual(1, probe.detaches);
        try std.testing.expectEqual(1, probe.notifications);
        try std.testing.expect(window.isClosed());
        try std.testing.expect(c.GetUpdateRect(witness_hwnd, null, c.FALSE) == 0);
        try std.testing.expectEqual(1, app.resourceStats().allocated_records);
        try std.testing.expectEqual(0, app.resourceStats().pending_destroys);
    }
    _ = try witness.destroy();
    try std.testing.expectEqual(0, app.resourceStats().allocated_records);
    std.debug.print("native reentry smoke passed: raw destruction during resize and nested DPI resize, one detach/notification, unrelated update region unchanged\n", .{});
}
