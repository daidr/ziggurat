//! Icons made from PNG bytes, the same on every platform. An Icon owns one
//! native image: an HICON on Windows, a GdkPixbuf on Linux. Its handle is
//! what `TrayOptions.icon` and `TrayItemOptions.icon` borrow, and
//! `setWindowIcon` shows it in a window's title bar and taskbar entry.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");

const os = builtin.os.tag;
const native_supported = !builtin.is_test and (os == .windows or os == .linux);
pub const capabilities = .{ .png = native_supported, .window_icon = native_supported };
/// Larger images are rejected before they are decoded.
pub const max_size = 1024;

const c = @import("ziggurat_c_win32");

extern fn zsx_icon_from_png(data: [*]const u8, length: usize) ?*anyopaque;
extern fn zsx_icon_release(pixbuf: *anyopaque) void;
extern fn zsx_window_set_icon(window: *anyopaque, pixbuf: ?*anyopaque) void;

pub const Size = struct { width: u32, height: u32 };

/// Reads the size of a PNG stream from its header, without decoding it.
pub fn pngSize(png: []const u8) !Size {
    if (png.len < 33 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, png[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, png[16..20], .big);
    const height = std.mem.readInt(u32, png[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPng;
    if (width > max_size or height > max_size) return error.IconTooLarge;
    return .{ .width = width, .height = height };
}

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
        const pixbuf = zsx_icon_from_png(png.ptr, png.len) orelse return error.IconDecodeFailed;
        return .{ .native = pixbuf, .size = size };
    }
    /// The HICON or GdkPixbuf, borrowed for as long as the Icon lives.
    pub fn handle(self: *const Icon) *anyopaque {
        return self.native;
    }
    /// Windows keeps no copy of a window icon: release an Icon only after
    /// every window showing it has another icon or has closed.
    pub fn deinit(self: *Icon) void {
        if (comptime !native_supported) return;
        if (os == .windows) _ = c.DestroyIcon(@ptrCast(self.native)) else zsx_icon_release(self.native);
        self.* = undefined;
    }
};

/// Shows `icon` in the window's title bar and taskbar entry; null restores
/// the application icon. Windows borrows the icon (see Icon.deinit); GTK
/// keeps a reference of its own.
pub fn setWindowIcon(window: z.Window, icon: ?*const Icon) !void {
    window.app.assertOwner();
    if (comptime !native_supported) return error.UnsupportedCapability;
    const handle = window.nativeHandle() orelse return error.Closed;
    if (os == .windows) {
        const value: usize = if (icon) |value| @intFromPtr(value.native) else 0;
        _ = c.SendMessageW(@ptrCast(handle), c.WM_SETICON, c.ICON_BIG, @bitCast(value));
        _ = c.SendMessageW(@ptrCast(handle), c.WM_SETICON, c.ICON_SMALL, @bitCast(value));
        return;
    }
    zsx_window_set_icon(handle, if (icon) |value| value.native else null);
}

test "png sizes come from the header and are bounded" {
    var png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x20\x00\x00\x00\x10\x08\x06\x00\x00\x00\x00\x00\x00\x00".*;
    try std.testing.expectEqual(Size{ .width = 32, .height = 16 }, try pngSize(&png));
    png[18] = 0x10;
    try std.testing.expectError(error.IconTooLarge, pngSize(&png));
    png[18] = 0;
    png[19] = 0;
    try std.testing.expectError(error.InvalidPng, pngSize(&png));
    try std.testing.expectError(error.InvalidPng, pngSize("GIF89a"));
}
