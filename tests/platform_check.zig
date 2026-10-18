const std = @import("std");
const z = @import("ziggurat");
pub fn main() !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var windows: [1]z.Window = undefined;
    _ = try app.listWindows(&windows);
    _ = app.findWindow(window.diagnosticId());
    const caps = try window.capabilities();
    window.pointerPressHeld(.{}, .primary) catch {};
    const bounds = try window.clientBounds();
    try window.setClientBounds(.{ .position = if (caps.client_position) bounds.position else null, .width = 600, .height = 400 });
    try window.resize(640, 420);
    if (caps.always_on_top) {
        try window.setAlwaysOnTop(true);
        try window.setAlwaysOnTop(false);
    }
    if (caps.fullscreen) {
        try window.setFullscreen(true);
        try window.setFullscreen(false);
    }
    _ = try window.state();
    const chrome = try app.createWindow(.{ .decoration = if (caps.custom_decoration) .custom else .system, .resizable = false });
    _ = try chrome.hitTest(.{ .x = 20, .y = 20 });
    chrome.startMove() catch {};
    chrome.startResize(.south_east) catch {};
    chrome.showSystemMenu() catch {};
    _ = try chrome.destroy();
    const hosted: ?z.Window = app.createWindow(.{ .accessibility_host = .children }) catch |err| switch (err) {
        error.UnsupportedCapability => null,
        else => return err,
    };
    if (hosted) |value| _ = try value.destroy();
    if (caps.owned_windows and caps.modal_windows) {
        const child = try app.createWindow(.{ .owner = window, .modal = true });
        _ = try child.relationship();
        _ = try window.focusTarget();
        try child.perform(.show);
        try child.perform(.hide);
        _ = try child.destroy();
    }
    _ = try window.destroy();
}
