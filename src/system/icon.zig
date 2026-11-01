//! Icons made from PNG bytes, the same on every platform. An Icon owns one
//! native image: an HICON on Windows, a GdkPixbuf on Linux, an NSImage on
//! macOS, where windows show no icon of their own. Its handle is
//! what `TrayOptions.icon` and `TrayItemOptions.icon` borrow, and
//! `setWindowIcon` shows it in a window's title bar and taskbar entry.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const os = builtin.os.tag;
const native_supported = !builtin.is_test and (os == .windows or os == .linux or os == .macos);
const window_icons = native_supported and os != .macos;
pub const capabilities = .{ .png = native_supported, .window_icon = window_icons };
const header = @import("png_header.zig");
/// Larger images are rejected before they are decoded.
pub const max_size = header.max_size;
pub const Size = header.Size;
pub const pngSize = header.pngSize;

const c = @import("ziggurat_c_win32");

extern fn zsx_icon_from_png(data: [*]const u8, length: usize) ?*anyopaque;
extern fn zsx_icon_release(pixbuf: *anyopaque) void;
extern fn zsx_window_set_icon(window: *anyopaque, pixbuf: ?*anyopaque) void;
extern fn zsm_image_png(data: [*]const u8, length: usize, box: f64, template: c_int) ?*anyopaque;
extern fn zsm_image_release(image: ?*anyopaque) void;

pub const Icon = struct {
    native: *anyopaque,
    size: Size,

    /// Decodes a PNG stream, copied before return. Owner thread only.
    pub fn fromPng(app: *z.App, png: []const u8) !Icon {
        app.assertOwner();
        const size = try pngSize(png);
        if (comptime !native_supported) return error.UnsupportedCapability;
        if (os == .windows) {
            // PNG streams are valid icon resources since Windows Vista.
            const icon = c.CreateIconFromResourceEx(@constCast(png.ptr), @intCast(png.len), c.TRUE, 0x00030000, @intCast(size.width), @intCast(size.height), 0) orelse return error.IconDecodeFailed;
            return .{ .native = icon, .size = size };
        }
        if (os == .macos) return .{ .native = zsm_image_png(png.ptr, png.len, 0, 0) orelse return error.IconDecodeFailed, .size = size };
        const pixbuf = zsx_icon_from_png(png.ptr, png.len) orelse return error.IconDecodeFailed;
        return .{ .native = pixbuf, .size = size };
    }
    /// The HICON, GdkPixbuf or NSImage, borrowed for as long as the Icon lives.
    pub fn handle(self: *const Icon) *anyopaque {
        return self.native;
    }
    /// Windows keeps no copy of a window icon: release an Icon only after
    /// every window showing it has another icon or has closed.
    pub fn deinit(self: *Icon) void {
        if (comptime !native_supported) return;
        if (os == .windows) _ = c.DestroyIcon(@ptrCast(self.native)) else if (os == .macos) zsm_image_release(self.native) else zsx_icon_release(self.native);
        self.* = undefined;
    }
};

/// Shows `icon` in the window's title bar and taskbar entry; null restores
/// the application icon. Windows borrows the icon (see Icon.deinit); GTK
/// keeps a reference of its own.
pub fn setWindowIcon(window: z.Window, icon: ?*const Icon) !void {
    window.app.assertOwner();
    if (comptime !window_icons) return error.UnsupportedCapability;
    const handle = window.nativeHandle() orelse return error.Closed;
    if (os == .windows) {
        const value: usize = if (icon) |value| @intFromPtr(value.native) else 0;
        _ = c.SendMessageW(@ptrCast(handle), c.WM_SETICON, c.ICON_BIG, @bitCast(value));
        _ = c.SendMessageW(@ptrCast(handle), c.WM_SETICON, c.ICON_SMALL, @bitCast(value));
        return;
    }
    zsx_window_set_icon(handle, if (icon) |value| value.native else null);
}
