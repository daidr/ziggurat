//! A notification-area icon drawn by the application: straight RGBA pixels
//! become the native image `TrayItemOptions.icon` borrows, a GdkPixbuf on
//! Linux and an HICON on Windows. `Tray.show` copies it, so the icon may be
//! released once the tray shows it.
const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux and !builtin.is_test;

const c = if (windows) @import("ziggurat_c_win32") else struct {};

const gdk = struct {
    extern fn gdk_pixbuf_new(colorspace: c_int, has_alpha: c_int, bits_per_sample: c_int, width: c_int, height: c_int) ?*anyopaque;
    extern fn gdk_pixbuf_get_pixels(pixbuf: *anyopaque) [*]u8;
    extern fn gdk_pixbuf_get_rowstride(pixbuf: *anyopaque) c_int;
    extern fn g_object_unref(object: *anyopaque) void;
};

pub const Error = error{ InvalidIcon, IconCreateFailed, Unsupported };

pub const TrayIcon = struct {
    handle: *anyopaque,

    /// `pixels` holds `width * height` straight-alpha RGBA pixels, row by
    /// row from the top.
    pub fn init(width: u32, height: u32, pixels: []const u8) Error!TrayIcon {
        if (width == 0 or height == 0 or width > 256 or height > 256 or pixels.len != @as(usize, width) * height * 4) return error.InvalidIcon;
        if (windows) return .{ .handle = try createWindows(width, height, pixels) };
        if (linux) return .{ .handle = try createLinux(width, height, pixels) };
        return error.Unsupported;
    }

    pub fn deinit(self: TrayIcon) void {
        if (windows) {
            _ = c.DestroyIcon(@ptrCast(self.handle));
        } else if (linux) gdk.g_object_unref(self.handle);
    }

    fn createLinux(width: u32, height: u32, pixels: []const u8) Error!*anyopaque {
        const pixbuf = gdk.gdk_pixbuf_new(0, 1, 8, @intCast(width), @intCast(height)) orelse return error.IconCreateFailed;
        const stride: usize = @intCast(gdk.gdk_pixbuf_get_rowstride(pixbuf));
        const destination = gdk.gdk_pixbuf_get_pixels(pixbuf);
        const row = @as(usize, width) * 4;
        for (0..height) |y| @memcpy(destination[y * stride ..][0..row], pixels[y * row ..][0..row]);
        return pixbuf;
    }

    fn createWindows(width: u32, height: u32, pixels: []const u8) Error!*anyopaque {
        var header = std.mem.zeroes(c.BITMAPV5HEADER);
        header.bV5Size = @sizeOf(c.BITMAPV5HEADER);
        header.bV5Width = @intCast(width);
        header.bV5Height = -@as(c_long, @intCast(height));
        header.bV5Planes = 1;
        header.bV5BitCount = 32;
        header.bV5Compression = c.BI_BITFIELDS;
        header.bV5RedMask = 0x00ff0000;
        header.bV5GreenMask = 0x0000ff00;
        header.bV5BlueMask = 0x000000ff;
        header.bV5AlphaMask = 0xff000000;
        const screen = c.GetDC(null);
        defer _ = c.ReleaseDC(null, screen);
        var bits: ?*anyopaque = null;
        const color = c.CreateDIBSection(screen, @ptrCast(&header), c.DIB_RGB_COLORS, &bits, null, 0) orelse return error.IconCreateFailed;
        defer _ = c.DeleteObject(color);
        const destination: [*]u8 = @ptrCast(bits orelse return error.IconCreateFailed);
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            destination[i] = pixels[i + 2];
            destination[i + 1] = pixels[i + 1];
            destination[i + 2] = pixels[i];
            destination[i + 3] = pixels[i + 3];
        }
        // The alpha channel decides; the mask only has to exist.
        const mask = c.CreateBitmap(@intCast(width), @intCast(height), 1, 1, null) orelse return error.IconCreateFailed;
        defer _ = c.DeleteObject(mask);
        var info = std.mem.zeroes(c.ICONINFO);
        info.fIcon = c.TRUE;
        info.hbmMask = mask;
        info.hbmColor = color;
        const icon = c.CreateIconIndirect(&info) orelse return error.IconCreateFailed;
        return @ptrCast(icon);
    }
};

test "icons check their pixels" {
    var pixels: [4 * 4 * 4]u8 = @splat(0);
    try std.testing.expectError(error.InvalidIcon, TrayIcon.init(4, 4, pixels[1..]));
    try std.testing.expectError(error.InvalidIcon, TrayIcon.init(0, 4, &pixels));
    if (!windows and !linux) try std.testing.expectError(error.Unsupported, TrayIcon.init(4, 4, &pixels));
}
