//! Hidden-window check that runtime window policy reaches the native window:
//! traits, opacity, pointer pass-through, capture protection, attention,
//! taskbar presence and the edited-document title mark.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_window_get_resizable(*anyopaque) c_int;
extern fn gtk_window_get_deletable(*anyopaque) c_int;
extern fn gtk_window_get_urgency_hint(*anyopaque) c_int;
extern fn gtk_window_get_skip_taskbar_hint(*anyopaque) c_int;
extern fn gtk_window_get_title(*anyopaque) ?[*:0]const u8;
extern fn gtk_widget_get_opacity(*anyopaque) f64;

const expect = std.testing.expect;

fn nativeTitle(window: z.Window, buffer: []u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var wide: [64]u16 = undefined;
        const length = c.GetWindowTextW(window.nativeHandle(), &wide, wide.len);
        const count = try std.unicode.utf16LeToUtf8(buffer, wide[0..@intCast(length)]);
        return buffer[0..count];
    }
    const title = gtk_window_get_title(window.nativeHandle().?) orelse return "";
    const text = std.mem.span(title);
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

fn checkTraits(window: z.Window, expected: z.WindowTraits) !void {
    const traits = try window.traits();
    try expect(std.meta.eql(traits, expected));
    if (builtin.os.tag == .windows) {
        const style: u32 = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.nativeHandle(), c.GWL_STYLE))));
        try expect((style & c.WS_THICKFRAME != 0) == expected.resizable);
        try expect((style & c.WS_MINIMIZEBOX != 0) == expected.minimizable);
        try expect((style & c.WS_MAXIMIZEBOX != 0) == (expected.maximizable and expected.resizable));
        const menu = c.GetSystemMenu(window.nativeHandle(), c.FALSE);
        try expect(menu != null);
        const grayed = c.GetMenuState(menu, c.SC_CLOSE, c.MF_BYCOMMAND) & c.MF_GRAYED != 0;
        try expect(grayed == !expected.closable);
    } else {
        try expect((gtk_window_get_resizable(window.nativeHandle().?) != 0) == expected.resizable);
        try expect((gtk_window_get_deletable(window.nativeHandle().?) != 0) == expected.closable);
    }
}

fn exercise(app: *z.App) !void {
    const window = try app.createWindow(.{ .title = "Policy", .width = 320, .height = 240, .closable = false, .movable = false });
    defer _ = window.destroy() catch {};
    const caps = try window.capabilities();
    try expect(caps.attention);
    try checkTraits(window, .{ .closable = false, .movable = false });
    try expect((try window.requestCloseFrom(.user)) == .cancelled);
    try window.setResizable(false);
    try checkTraits(window, .{ .resizable = false, .closable = false, .movable = false });
    try window.setTraits(.{});
    try checkTraits(window, .{});
    if (caps.window_buttons) {
        try window.setTraits(.{ .minimizable = false, .maximizable = false });
        try checkTraits(window, .{ .minimizable = false, .maximizable = false });
        try window.setTraits(.{});
    } else try std.testing.expectError(error.UnsupportedCapability, window.setMinimizable(false));

    var buffer: [64]u8 = undefined;
    try window.setDocumentEdited(true);
    try std.testing.expectEqualStrings("*Policy", try nativeTitle(window, &buffer));
    try window.setTitle("Draft");
    try std.testing.expectEqualStrings("*Draft", try nativeTitle(window, &buffer));
    try window.setDocumentEdited(false);
    try std.testing.expectEqualStrings("Draft", try nativeTitle(window, &buffer));

    if (caps.opacity) {
        try window.setOpacity(0.5);
        if (builtin.os.tag == .windows) {
            var alpha: u8 = 0;
            var flags: c.DWORD = 0;
            try expect(c.GetLayeredWindowAttributes(window.nativeHandle(), null, &alpha, &flags) != 0);
            try expect(alpha == 128 and flags & c.LWA_ALPHA != 0);
        } else try expect(@abs(gtk_widget_get_opacity(window.nativeHandle().?) - 0.5) < 0.01);
        try window.setOpacity(1);
    } else try std.testing.expectError(error.UnsupportedCapability, window.setOpacity(0.5));

    if (caps.ignore_pointer) {
        try window.setIgnorePointer(true);
        if (builtin.os.tag == .windows) {
            const ex = c.GetWindowLongPtrW(window.nativeHandle(), c.GWL_EXSTYLE);
            try expect(ex & c.WS_EX_TRANSPARENT != 0 and ex & c.WS_EX_LAYERED != 0);
        }
        try window.setIgnorePointer(false);
        if (builtin.os.tag == .windows) try expect(c.GetWindowLongPtrW(window.nativeHandle(), c.GWL_EXSTYLE) & (c.WS_EX_TRANSPARENT | c.WS_EX_LAYERED) == 0);
    }

    if (caps.content_protection) {
        try window.setContentProtection(true);
        if (builtin.os.tag == .windows) {
            var affinity: c.DWORD = 0;
            try expect(c.GetWindowDisplayAffinity(window.nativeHandle(), &affinity) != 0 and affinity != c.WDA_NONE);
        }
        try window.setContentProtection(false);
    } else try std.testing.expectError(error.UnsupportedCapability, window.setContentProtection(true));

    try window.flashFrame(true);
    if (builtin.os.tag == .linux) try expect(gtk_window_get_urgency_hint(window.nativeHandle().?) != 0);
    try window.flashFrame(false);
    if (builtin.os.tag == .linux) try expect(gtk_window_get_urgency_hint(window.nativeHandle().?) == 0);

    if (caps.skip_taskbar) {
        try window.setSkipTaskbar(true);
        if (builtin.os.tag == .linux) try expect(gtk_window_get_skip_taskbar_hint(window.nativeHandle().?) != 0);
        try window.setSkipTaskbar(false);
    }
}

const Quit = struct {
    fn call(ptr: *anyopaque) void {
        const app: *z.App = @ptrCast(@alignCast(ptr));
        app.quit();
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try exercise(app);
    // Keep one hidden window so the loop runs once and drains native work.
    _ = try app.createWindow(.{ .title = "Policy idle" });
    try app.post(.{ .context = app, .call = Quit.call });
    try app.run();
}
