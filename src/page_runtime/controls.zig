const std = @import("std");
const z = @import("ziggurat");

/// Window operations a page may request. Every call runs on the main thread
/// from inside Host.receive; implementations must not block or nest a loop.
pub const Controls = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        minimize: *const fn (*anyopaque) anyerror!void,
        maximize: *const fn (*anyopaque) anyerror!void,
        unmaximize: *const fn (*anyopaque) anyerror!void,
        toggleMaximize: *const fn (*anyopaque) anyerror!void,
        isMaximized: *const fn (*anyopaque) anyerror!bool,
        toggleFullScreen: *const fn (*anyopaque) anyerror!void,
        /// Called after the page's reply was sent. Honors close cancellation.
        close: *const fn (*anyopaque) anyerror!void,
        /// The title is borrowed for the duration of the call.
        setTitle: *const fn (*anyopaque, []const u8) anyerror!void,
    };
};

/// Controls for a core Window handle. Keep the adapter at a stable address
/// while the Host uses it; App must outlive it like every Window use.
pub const WindowControls = struct {
    window: z.Window,

    pub fn controls(self: *WindowControls) Controls {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Controls.VTable = .{
        .minimize = minimize,
        .maximize = maximize,
        .unmaximize = unmaximize,
        .toggleMaximize = toggleMaximize,
        .isMaximized = isMaximized,
        .toggleFullScreen = toggleFullScreen,
        .close = close,
        .setTitle = setTitle,
    };

    fn of(context: *anyopaque) z.Window {
        const self: *WindowControls = @ptrCast(@alignCast(context));
        return self.window;
    }
    fn minimize(context: *anyopaque) !void {
        try of(context).perform(.minimize);
    }
    fn maximize(context: *anyopaque) !void {
        try of(context).perform(.maximize);
    }
    fn unmaximize(context: *anyopaque) !void {
        const window = of(context);
        if ((try window.state()).maximized) try window.perform(.restore);
    }
    fn toggleMaximize(context: *anyopaque) !void {
        const window = of(context);
        try window.perform(if ((try window.state()).maximized) .restore else .maximize);
    }
    fn isMaximized(context: *anyopaque) !bool {
        return (try of(context).state()).maximized;
    }
    fn toggleFullScreen(context: *anyopaque) !void {
        const window = of(context);
        const state = try window.state();
        try window.setFullscreen(!(state.fullscreen or state.fullscreen_requested));
    }
    fn close(context: *anyopaque) !void {
        _ = try of(context).requestClose();
    }
    fn setTitle(context: *anyopaque, title: []const u8) !void {
        try of(context).setTitle(title);
    }
};

test "window controls follow the window's own state" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var adapter: WindowControls = .{ .window = try app.createWindow(.{ .title = "Page" }) };
    const controls = adapter.controls();
    try controls.vtable.toggleMaximize(controls.context);
    try std.testing.expect(try controls.vtable.isMaximized(controls.context));
    try controls.vtable.unmaximize(controls.context);
    try std.testing.expect(!try controls.vtable.isMaximized(controls.context));
    try controls.vtable.unmaximize(controls.context);
    try controls.vtable.minimize(controls.context);
    try std.testing.expect((try adapter.window.state()).minimized);
    try controls.vtable.setTitle(controls.context, "Renamed");
    try controls.vtable.close(controls.context);
    try std.testing.expect(adapter.window.isClosed());
    try std.testing.expectError(error.Closed, controls.vtable.isMaximized(controls.context));
}
