//! Images shown beside the labels of menu items (`Item.icon`), made once
//! from PNG bytes and given to as many items as show them. An image fits a
//! box of `box` DIPs keeping its aspect, at each menu's display scaling: give
//! it 32 by 32 pixels or more so it stays sharp at 200%. A template image,
//! black and transparent, takes the color of the menu's text on Windows;
//! GTK shows it as it is.
//!
//! Windows draws an icon as the item's bitmap (`hbmpItem`), a 32-bit
//! premultiplied DIB section made once per size and color, in the column of
//! check marks: a checked item shows its icon framed as checked. GTK shows a
//! GtkImage before the label, and a tray's menu gets the PNG over DBusMenu
//! (`icon-data`). AppKit draws an NSImage of the box's size from the
//! representation fit for the display, and tints a template image as the
//! menu's text, white on the highlight. The items of a menu bar itself show
//! no icon.
const std = @import("std");
const builtin = @import("builtin");
const icon = @import("png_header.zig");

const os = builtin.os.tag;
const native_supported = !builtin.is_test and (os == .windows or os == .linux or os == .macos);
pub const capabilities = .{ .png = native_supported };
/// The box an icon fits, in DIPs.
pub const box = 16;
/// Larger images are scaled down to this many pixels when decoded.
const max_source = 256;
/// Sizes and colors a Windows icon keeps bitmaps for; more show no icon.
const max_bitmaps = 8;

const c = @import("ziggurat_c_win32");

extern fn zsx_menu_icon_new(data: [*]const u8, length: usize) ?*anyopaque;
extern fn zsx_menu_icon_free(native: *anyopaque) void;
extern fn zsm_image_png(data: [*]const u8, length: usize, box: f64, template: c_int) ?*anyopaque;
extern fn zsm_image_release(image: ?*anyopaque) void;

pub const Options = struct {
    /// Black and transparent, drawn in the menu's text color on Windows.
    template: bool = false,
};

/// Caller-owned and address-stable while any menu shows it: menus keep
/// pointers to it, and Windows menus its bitmaps.
pub const MenuIcon = struct {
    allocator: std.mem.Allocator,
    size: icon.Size,
    template: bool,
    /// Linux: the decoded image, its scaled copies and the PNG bytes.
    /// macOS: the NSImage.
    native: ?*anyopaque = null,
    /// Windows: premultiplied 0xAARRGGBB pixels, row by row from the top.
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    bitmaps: [max_bitmaps]Bitmap = @splat(.{}),

    const Bitmap = struct { pixels: u32 = 0, tint: ?u32 = null, handle: ?*anyopaque = null };

    /// Decodes a PNG stream, copied before return. Owner thread of `app`,
    /// a `*ziggurat.App`, only.
    pub fn fromPng(app: anytype, png: []const u8, options: Options) !MenuIcon {
        app.assertOwner();
        const size = try icon.pngSize(png);
        if (comptime !native_supported) return error.UnsupportedCapability;
        var result: MenuIcon = .{ .allocator = app.allocator, .size = size, .template = options.template };
        if (os == .linux) {
            result.native = zsx_menu_icon_new(png.ptr, png.len) orelse return error.IconDecodeFailed;
            return result;
        }
        if (os == .macos) {
            result.native = zsm_image_png(png.ptr, png.len, box, @intFromBool(options.template)) orelse return error.IconDecodeFailed;
            return result;
        }
        const fitted = fit(size.width, size.height, max_source);
        result.width = if (size.width > max_source or size.height > max_source) fitted.width else size.width;
        result.height = if (size.width > max_source or size.height > max_source) fitted.height else size.height;
        result.pixels = try app.allocator.alloc(u32, result.width * result.height);
        errdefer app.allocator.free(result.pixels);
        try decodeWindows(png, result.width, result.height, result.pixels);
        return result;
    }
    /// Release only once no menu shows the icon.
    pub fn deinit(self: *MenuIcon) void {
        if (comptime !native_supported) return;
        if (os == .linux) {
            if (self.native) |native| zsx_menu_icon_free(native);
        } else if (os == .macos) {
            zsm_image_release(self.native);
        } else {
            for (self.bitmaps) |entry| if (entry.handle) |handle| {
                _ = c.DeleteObject(@ptrCast(handle));
            };
            self.allocator.free(self.pixels);
        }
        self.* = undefined;
    }
    /// Windows: the item bitmap at `dpi`, in `tint` (0xRRGGBB) for a
    /// template icon; null when it cannot be made.
    pub fn bitmap(self: *MenuIcon, dpi: u32, color: u32) ?*anyopaque {
        if (comptime !(native_supported and os == .windows)) return null;
        const pixels = @max(box * @max(dpi, 96) / 96, 1);
        const key: ?u32 = if (self.template) color else null;
        const slot = for (&self.bitmaps) |*entry| {
            if (entry.handle == null) break entry;
            if (entry.pixels == pixels and std.meta.eql(entry.tint, key)) return entry.handle;
        } else return null;
        const sized = fit(self.width, self.height, pixels);
        const handle = makeBitmap(self.pixels, self.width, self.height, sized, key) orelse return null;
        slot.* = .{ .pixels = pixels, .tint = key, .handle = handle };
        return handle;
    }
};

/// The size of a width by height image fit to a square of `side`, keeping
/// its aspect, at least one pixel each way.
pub fn fit(width: u32, height: u32, side: u32) icon.Size {
    if (width >= height) return .{ .width = side, .height = @max(@as(u32, @intCast((@as(u64, height) * side + width / 2) / width)), 1) };
    return .{ .width = @max(@as(u32, @intCast((@as(u64, width) * side + height / 2) / height)), 1), .height = side };
}

/// Scales premultiplied pixels, each one out the average of the part of the
/// image it covers: fine lines of a large image stay as they shrink.
pub fn scale(source: []const u32, width: u32, height: u32, out: []u32, out_width: u32, out_height: u32) void {
    const sx: f64 = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(out_width));
    const sy: f64 = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(out_height));
    for (0..out_height) |dy| for (0..out_width) |dx| {
        var sum: [4]f64 = @splat(0);
        var total: f64 = 0;
        const y0 = @as(f64, @floatFromInt(dy)) * sy;
        const y1 = y0 + sy;
        var y: usize = @intFromFloat(y0);
        while (y < height and @as(f64, @floatFromInt(y)) < y1) : (y += 1) {
            const wy = @min(y1, @as(f64, @floatFromInt(y + 1))) - @max(y0, @as(f64, @floatFromInt(y)));
            const x0 = @as(f64, @floatFromInt(dx)) * sx;
            const x1 = x0 + sx;
            var x: usize = @intFromFloat(x0);
            while (x < width and @as(f64, @floatFromInt(x)) < x1) : (x += 1) {
                const weight = wy * (@min(x1, @as(f64, @floatFromInt(x + 1))) - @max(x0, @as(f64, @floatFromInt(x))));
                if (weight <= 1e-9) continue;
                const pixel = source[y * width + x];
                inline for (0..4) |channel| sum[channel] += weight * @as(f64, @floatFromInt(pixel >> (24 - 8 * channel) & 0xff));
                total += weight;
            }
        }
        var pixel: u32 = 0;
        inline for (0..4) |channel| pixel |= @as(u32, @intFromFloat(@round(@min(@max(sum[channel] / @max(total, 1e-9), 0), 255)))) << (24 - 8 * channel);
        out[dy * out_width + dx] = pixel;
    };
}

/// One premultiplied pixel in `rgb`, keeping its alpha.
pub fn tint(pixel: u32, rgb: u32) u32 {
    const alpha = pixel >> 24;
    var out = alpha << 24;
    inline for (.{ 16, 8, 0 }) |shift| out |= ((rgb >> shift & 0xff) * alpha + 127) / 255 << shift;
    return out;
}

/// Straight 8-bit BGRA, as GetDIBits reads it, to premultiplied 0xAARRGGBB.
pub fn premultiply(bgra: [4]u8) u32 {
    const alpha: u32 = bgra[3];
    const r = (@as(u32, bgra[2]) * alpha + 127) / 255;
    const g = (@as(u32, bgra[1]) * alpha + 127) / 255;
    const b = (@as(u32, bgra[0]) * alpha + 127) / 255;
    return alpha << 24 | r << 16 | g << 8 | b;
}

/// PNG streams are valid icon resources since Windows Vista; the system
/// decodes and scales them to the size asked for.
fn decodeWindows(png: []const u8, width: u32, height: u32, out: []u32) !void {
    const handle = c.CreateIconFromResourceEx(@constCast(png.ptr), @intCast(png.len), c.TRUE, 0x00030000, @intCast(width), @intCast(height), 0) orelse return error.IconDecodeFailed;
    defer _ = c.DestroyIcon(handle);
    var info: c.ICONINFO = undefined;
    if (c.GetIconInfo(handle, &info) == 0) return error.IconDecodeFailed;
    defer {
        if (info.hbmColor) |color| _ = c.DeleteObject(@ptrCast(color));
        if (info.hbmMask) |mask| _ = c.DeleteObject(@ptrCast(mask));
    }
    const color = info.hbmColor orelse return error.IconDecodeFailed;
    var header = std.mem.zeroes(c.BITMAPINFO);
    header.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    header.bmiHeader.biWidth = @intCast(width);
    header.bmiHeader.biHeight = -@as(c_long, @intCast(height));
    header.bmiHeader.biPlanes = 1;
    header.bmiHeader.biBitCount = 32;
    const screen = c.GetDC(null);
    defer _ = c.ReleaseDC(null, screen);
    if (c.GetDIBits(screen, color, 0, height, out.ptr, &header, c.DIB_RGB_COLORS) != @as(c_int, @intCast(height))) return error.IconDecodeFailed;
    for (out) |*pixel| pixel.* = premultiply(@bitCast(pixel.*));
}

fn makeBitmap(source: []const u32, width: u32, height: u32, size: icon.Size, key: ?u32) ?*anyopaque {
    var header = std.mem.zeroes(c.BITMAPINFO);
    header.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    header.bmiHeader.biWidth = @intCast(size.width);
    header.bmiHeader.biHeight = -@as(c_long, @intCast(size.height));
    header.bmiHeader.biPlanes = 1;
    header.bmiHeader.biBitCount = 32;
    var bits: ?*anyopaque = null;
    const handle = c.CreateDIBSection(null, &header, c.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    const out: [*]u32 = @ptrCast(@alignCast(bits orelse {
        _ = c.DeleteObject(@ptrCast(handle));
        return null;
    }));
    const pixels = out[0 .. size.width * size.height];
    scale(source, width, height, pixels, size.width, size.height);
    if (key) |rgb| for (pixels) |*pixel| {
        pixel.* = tint(pixel.*, rgb);
    };
    return handle;
}

test "icons fit their box keeping the aspect" {
    try std.testing.expectEqual(icon.Size{ .width = 16, .height = 16 }, fit(48, 48, 16));
    try std.testing.expectEqual(icon.Size{ .width = 16, .height = 8 }, fit(64, 32, 16));
    try std.testing.expectEqual(icon.Size{ .width = 6, .height = 20 }, fit(30, 100, 20));
    try std.testing.expectEqual(icon.Size{ .width = 16, .height = 1 }, fit(1000, 1, 16));
}

test "scaling averages what each pixel covers" {
    // A 4x2 image, its left half opaque red and its right half clear, to 2x1.
    const red: u32 = 0xffff0000;
    const source = [_]u32{ red, red, 0, 0, red, red, 0, 0 };
    var out: [2]u32 = undefined;
    scale(&source, 4, 2, &out, 2, 1);
    try std.testing.expectEqual(red, out[0]);
    try std.testing.expectEqual(0, out[1]);
    // A one pixel line of a 3x3 image stays as a third of a pixel.
    const line = [_]u32{ 0, 0xff000000, 0, 0, 0xff000000, 0, 0, 0xff000000, 0 };
    var one: [1]u32 = undefined;
    scale(&line, 3, 3, &one, 1, 1);
    try std.testing.expectEqual(0x55000000, one[0]);
    // Growing repeats pixels.
    var grown: [4]u32 = undefined;
    scale(&.{red}, 1, 1, &grown, 2, 2);
    try std.testing.expectEqualSlices(u32, &.{ red, red, red, red }, &grown);
}

test "templates take the text color and pixels premultiply" {
    try std.testing.expectEqual(0x80808080, tint(0x80000000, 0xffffff));
    try std.testing.expectEqual(0xff102030, tint(0xff000000, 0x102030));
    try std.testing.expectEqual(0, tint(0, 0xffffff));
    try std.testing.expectEqual(0x80800000, premultiply(.{ 0, 0, 0xff, 0x80 }));
    try std.testing.expectEqual(0xff0000ff, premultiply(.{ 0xff, 0, 0, 0xff }));
}
