const std = @import("std");
const core = @import("../root.zig");
pub fn contentSize(_: *core.WindowRecord) !core.Size {
    return error.UnsupportedPlatform;
}
pub const AppData = struct {};
pub const WindowData = struct {};
pub fn init(_: *core.App) !void {
    return error.UnsupportedPlatform;
}
pub fn deinit(_: *core.App) void {}
pub fn create(_: *core.WindowRecord, _: core.WindowOptions) !void {
    return error.UnsupportedPlatform;
}
pub fn run(_: *core.App) !void {
    return error.UnsupportedPlatform;
}
pub fn wake(_: *core.App) void {}
pub fn quit(_: *core.App) void {}
pub fn show(_: *core.WindowRecord) void {}
pub fn startMove(_: *core.WindowRecord) !void {
    return error.UnsupportedCapability;
}
pub fn startResize(_: *core.WindowRecord, _: core.ResizeEdge) !void {
    return error.UnsupportedCapability;
}
pub fn showSystemMenu(_: *core.WindowRecord) !void {
    return error.UnsupportedCapability;
}
pub fn perform(_: *core.WindowRecord, _: core.WindowAction) !void {
    return error.UnsupportedPlatform;
}
pub fn state(_: *core.WindowRecord) core.WindowState {
    unreachable;
}
pub fn isActive(_: *core.WindowRecord) bool {
    return false;
}
pub fn capabilities(_: *core.WindowRecord) core.WindowCapabilities {
    return .{ .client_position = false, .fullscreen = false, .always_on_top = false };
}
pub fn clientBounds(_: *core.WindowRecord) !core.ClientBounds {
    return error.UnsupportedPlatform;
}
pub fn setClientBounds(_: *core.WindowRecord, _: core.ClientBounds) !void {
    return error.UnsupportedPlatform;
}
pub fn setFullscreen(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn setAlwaysOnTop(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn setBackdrop(_: *core.WindowRecord, _: core.WindowBackdrop) !void {
    return error.UnsupportedPlatform;
}
pub fn setVibrancy(_: *core.WindowRecord, _: core.Vibrancy) void {}
pub fn setTitle(_: *core.WindowRecord, _: []const u8) !void {
    return error.UnsupportedPlatform;
}
pub fn setTraits(_: *core.WindowRecord, _: core.WindowTraits) !void {
    return error.UnsupportedPlatform;
}
pub fn setOpacity(_: *core.WindowRecord, _: f32) !void {
    return error.UnsupportedPlatform;
}
pub fn setIgnorePointer(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn setContentProtection(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn flashFrame(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn setSkipTaskbar(_: *core.WindowRecord, _: bool) !void {
    return error.UnsupportedPlatform;
}
pub fn setTextCaret(_: *core.WindowRecord, _: core.Rect) !void {
    return error.UnsupportedPlatform;
}
pub fn cancelTextComposition(_: *core.WindowRecord) !void {
    return error.UnsupportedPlatform;
}
pub fn cancelTextForMode(_: *core.WindowRecord) !bool {
    return error.UnsupportedPlatform;
}
pub fn setTextInputMode(_: *core.WindowRecord, _: core.TextInputMode) !core.TextInputModeResult {
    return error.UnsupportedPlatform;
}
pub fn resize(_: *core.WindowRecord, _: u32, _: u32) !void {
    return error.UnsupportedPlatform;
}
pub fn capture(_: *core.WindowRecord, _: std.mem.Allocator) !core.Capture {
    return error.UnsupportedCapability;
}
pub fn activateMenuItem(_: *core.WindowRecord, _: []const []const u8) !void {
    return error.UnsupportedCapability;
}
pub fn invalidate(_: *core.WindowRecord) void {}
pub fn invalidateRect(_: *core.WindowRecord, _: core.Rect) !void {
    return error.UnsupportedPlatform;
}
pub fn destroy(_: *core.WindowRecord) !void {
    return error.UnsupportedPlatform;
}
pub fn handle(_: *core.WindowRecord) ?*anyopaque {
    return null;
}
pub fn setCursor(_: *core.WindowRecord, _: core.Cursor) void {}
