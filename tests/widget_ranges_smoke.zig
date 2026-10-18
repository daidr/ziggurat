const std = @import("std");
const z = @import("ziggurat");
const shared = @import("widget_ranges_shared.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const Native = struct {
    pub fn paint(window: z.Window) void {
        const hwnd: c.HWND = window.nativeHandle();
        _ = c.InvalidateRect(hwnd, null, 0);
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    }
    pub fn pointer(window: z.Window, phase: enum { down, move, up }, x: f32, y: f32) !void {
        const hwnd: c.HWND = window.nativeHandle();
        const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
        const px: u16 = @bitCast(@as(i16, @intFromFloat(x * scale)));
        const py: u16 = @bitCast(@as(i16, @intFromFloat(y * scale)));
        const point: c.LPARAM = @intCast(@as(u32, px) | (@as(u32, py) << 16));
        _ = c.SendMessageW(hwnd, switch (phase) {
            .down => c.WM_LBUTTONDOWN,
            .move => c.WM_MOUSEMOVE,
            .up => c.WM_LBUTTONUP,
        }, if (phase == .move) c.MK_LBUTTON else 0, point);
        if (phase == .down and !window.isClosed()) try std.testing.expect(c.GetCapture() == hwnd);
    }
    pub fn click(window: z.Window, x: f32, y: f32) !void {
        try pointer(window, .down, x, y);
        try pointer(window, .up, x, y);
    }
    pub fn cancel(window: z.Window) void {
        _ = c.ReleaseCapture();
        _ = c.SendMessageW(window.nativeHandle(), c.WM_CANCELMODE, 0, 0);
    }
    pub fn key(window: z.Window, input: z.KeyInput) !void {
        const code: c.WPARAM = switch (input.key) {
            .left => c.VK_LEFT,
            .right => c.VK_RIGHT,
            .up => c.VK_UP,
            .down => c.VK_DOWN,
            .home => c.VK_HOME,
            .end => c.VK_END,
            .page_up => c.VK_PRIOR,
            .page_down => c.VK_NEXT,
            .tab => c.VK_TAB,
            .space => c.VK_SPACE,
            .enter => c.VK_RETURN,
            .s => 'S',
            .q => 'Q',
            .c => 'C',
            .f2 => c.VK_F2,
            .f3 => c.VK_F3,
            else => return error.UnsupportedTestKey,
        };
        var previous: [256]u8 = undefined;
        if (c.GetKeyboardState(&previous) == 0) return error.KeyboardStateUnavailable;
        defer _ = c.SetKeyboardState(&previous);
        var current = previous;
        current[c.VK_SHIFT] = if (input.modifiers.shift) 0x80 else 0;
        current[c.VK_CONTROL] = if (input.modifiers.control) 0x80 else 0;
        current[c.VK_MENU] = if (input.modifiers.alt) 0x80 else 0;
        if (c.SetKeyboardState(&current) == 0) return error.KeyboardStateUnavailable;
        const hwnd: c.HWND = window.nativeHandle();
        const message: c.UINT = if (input.modifiers.alt) c.WM_SYSKEYDOWN else c.WM_KEYDOWN;
        const flags: c.LPARAM = if (input.repeat) 1 << 30 else 0;
        _ = c.SendMessageW(hwnd, message, code, flags);
        if (!window.isClosed()) _ = c.SendMessageW(hwnd, if (input.modifiers.alt) c.WM_SYSKEYUP else c.WM_KEYUP, code, flags | 1 << 31);
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var args = try std.process.argsWithAllocator(allocator.allocator());
    defer args.deinit();
    _ = args.next();
    const uia_only = if (args.next()) |arg| std.mem.eql(u8, arg, "--uia-only") else false;
    if (!uia_only) {
        try shared.run(Native, allocator.allocator());
        try @import("widget_keyboard_queue.zig").run(allocator.allocator());
        std.debug.print("range widgets native smoke passed: drag capture, paired bounds, step buttons, keyboard, shortcuts/editor routing, disabled/removal/frame failure/close\n", .{});
    }
    try @import("widget_ranges_uia.zig").run(allocator.allocator());
}
