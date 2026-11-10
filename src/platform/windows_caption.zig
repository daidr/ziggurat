//! The window controls of a `.custom` window with a hidden title bar
//! (`WindowOptions.title_bar`) on Windows. The window has no caption: its
//! content fills it, and minimize, maximize or restore, and close sit over
//! the content's top-right corner, drawn as Windows 11 draws its own, in a
//! child window above the content:
//!
//!   - a layered window whose pixels carry their alpha
//!     (UpdateLayeredWindow), so the content shows around the glyphs; in a
//!     window without a redirection bitmap (a material or transparency
//!     behind the frames) the pixels show through DirectComposition
//!     instead;
//!   - it answers WM_NCHITTEST with the buttons' hit-test codes, which
//!     brings Windows 11's snap layouts over the maximize button, and runs
//!     the buttons from the non-client mouse messages that follow.
//!
//! `Window.titleBar` says where they are.
const std = @import("std");
const core = @import("../root.zig");
const c = @import("ziggurat_c_win32");

extern fn zwc_create(?*anyopaque) ?*anyopaque;
extern fn zwc_present(*anyopaque, [*]const u32, u32, u32) c_long;
extern fn zwc_destroy(?*anyopaque) void;
extern "dwmapi" fn DwmGetWindowAttribute(c.HWND, u32, *anyopaque, u32) callconv(.winapi) c.HRESULT;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Caption.0");
/// Windows 11's caption buttons are 46 DIP wide, as tall as the title bar
/// (32 by default), with glyphs of 10.
pub const button_width = 46;
pub const default_height = 32;
const glyph_size = 10;

pub const Button = enum {
    minimize,
    maximize,
    close,

    /// The glyph in Segoe Fluent Icons and Segoe MDL2 Assets, which have
    /// them at the same code points.
    fn glyph(self: Button, maximized: bool) u16 {
        return switch (self) {
            .minimize => 0xE921, // ChromeMinimize
            .maximize => if (maximized) 0xE923 else 0xE922, // ChromeRestore, ChromeMaximize
            .close => 0xE8BB, // ChromeClose
        };
    }
    fn hitTest(self: Button) c.LRESULT {
        return switch (self) {
            .minimize => c.HTMINBUTTON,
            .maximize => c.HTMAXBUTTON,
            .close => c.HTCLOSE,
        };
    }
};

/// The bar of one window; `buttons` null when it has none.
pub const Caption = struct {
    buttons: c.HWND = null,
    /// Shows the pixels in a window without a redirection bitmap.
    composed: ?*anyopaque = null,
    /// The index of the button under the pointer and of the one pressed,
    /// or -1.
    hot: i8 = -1,
    pressed: i8 = -1,
    tracking: bool = false,
    active: bool = false,
    font: c.HFONT = null,
    font_dpi: u32 = 0,
    /// The font is Segoe Fluent Icons, Windows 11's; Windows 10 has Segoe
    /// MDL2 Assets.
    fluent: bool = false,
    /// A window over the maximize button the content draws itself
    /// (`setMaximizeButton`), null until it says where; `snap_rect` is
    /// where, in DIPs.
    snap: c.HWND = null,
    snap_rect: ?core.Rect = null,
    snap_tracking: bool = false,
};

var class_registered = false;

fn registerClass() bool {
    if (class_registered) return true;
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.hInstance = c.GetModuleHandleW(null);
    wc.lpfnWndProc = captionProc;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    wc.lpszClassName = class_name;
    if (c.RegisterClassExW(&wc) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return false;
    class_registered = true;
    return true;
}

/// Makes the bar of a window that was just created.
pub fn create(window: *core.WindowRecord) void {
    if (!registerClass()) return;
    const parent = window.native.hwnd;
    const caption = &window.native.caption;
    const instance = c.GetModuleHandleW(null);
    if (window.native.no_redirect) {
        // Layered, so that it blends over the content instead of cutting its
        // rectangle out of it, and shown through DirectComposition.
        caption.buttons = c.CreateWindowExW(c.WS_EX_LAYERED | ws_ex_no_redirection_bitmap, class_name, null, c.WS_CHILD | c.WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, null, instance, window);
        if (caption.buttons) |hwnd| {
            _ = c.SetLayeredWindowAttributes(hwnd, 0, 255, c.LWA_ALPHA);
            caption.composed = zwc_create(hwnd);
        }
    } else {
        caption.buttons = c.CreateWindowExW(c.WS_EX_LAYERED, class_name, null, c.WS_CHILD | c.WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, null, instance, window);
    }
    if (caption.buttons == null) {
        window.window.report(.{ .severity = .warning, .domain = .win32, .operation = .window_update, .code = c.GetLastError(), .err = error.WindowUpdateFailed });
        return;
    }
    layout(window);
}
const ws_ex_no_redirection_bitmap = 0x00200000;

/// Frees what the bar holds; Windows destroys its window with the window's.
pub fn destroy(window: *core.WindowRecord) void {
    const caption = &window.native.caption;
    zwc_destroy(caption.composed);
    if (caption.font) |handle| _ = c.DeleteObject(handle);
    caption.* = .{};
}

/// The buttons, left to right: close alone when the window can be neither
/// minimized nor maximized, as Windows does.
fn shown(window: *core.WindowRecord, out: *[3]Button) []const Button {
    const bits = styleBits(window);
    if (bits & (c.WS_MINIMIZEBOX | c.WS_MAXIMIZEBOX) == 0) {
        out[0] = .close;
        return out[0..1];
    }
    out.* = .{ .minimize, .maximize, .close };
    return out;
}
/// The style the window has out of full screen, where its buttons come
/// back.
fn styleBits(window: *core.WindowRecord) u32 {
    if (window.native.saved) |saved| return @truncate(@as(usize, @bitCast(saved.style)));
    return @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.native.hwnd, c.GWL_STYLE))));
}
fn enabled(window: *core.WindowRecord, button: Button) bool {
    const bits = styleBits(window);
    return switch (button) {
        .minimize => bits & c.WS_MINIMIZEBOX != 0,
        .maximize => bits & c.WS_MAXIMIZEBOX != 0,
        .close => window.options.closable,
    };
}

pub fn height(window: *const core.WindowRecord) u32 {
    return if (window.options.title_bar_height > 0) window.options.title_bar_height else default_height;
}

/// The room the buttons take, all zero in full screen.
pub fn titleBar(window: *core.WindowRecord) core.TitleBar {
    if (window.native.caption.buttons == null or window.native.fullscreen) return .{};
    var buffer: [3]Button = undefined;
    const count = shown(window, &buffer).len;
    const h: f32 = @floatFromInt(height(window));
    return .{ .height = h, .right = @floatFromInt(button_width * count), .bottom = h };
}

fn px(value: u32, dpi: u32) c_int {
    return c.MulDiv(@intCast(value), @intCast(dpi), 96);
}

/// Puts the buttons at the top-right corner, above the content and the
/// child windows it holds, and paints them. It runs when the window changes
/// size, state, style or DPI, and when a child window appears.
pub fn layout(window: *core.WindowRecord) void {
    const caption = &window.native.caption;
    layoutSnap(window);
    const buttons = caption.buttons orelse return;
    const parent = window.native.hwnd;
    if (c.IsIconic(parent) != 0) return; // no room to lay out in
    var buffer: [3]Button = undefined;
    const count = shown(window, &buffer).len;
    if (caption.hot >= count or caption.pressed >= count) {
        caption.hot = -1;
        caption.pressed = -1;
    }
    const dpi = c.GetDpiForWindow(parent);
    var client: c.RECT = undefined;
    if (c.GetClientRect(parent, &client) == 0) return;
    const width = px(button_width, dpi) * @as(c_int, @intCast(count));
    const show: c.UINT = if (window.native.fullscreen) c.SWP_HIDEWINDOW else c.SWP_SHOWWINDOW;
    // HWND_TOP: above the content's child windows, created after it.
    _ = c.SetWindowPos(buttons, null, client.right - width, 0, width, px(height(window), dpi), @as(c.UINT, c.SWP_NOACTIVATE) | show);
    paint(window);
}

/// Runs for the window's own messages, before it handles them.
pub fn parentMessage(window: *core.WindowRecord, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) void {
    const caption = &window.native.caption;
    if (caption.buttons == null and caption.snap == null) return;
    switch (message) {
        c.WM_SIZE => if (wp != c.SIZE_MINIMIZED) layout(window),
        c.WM_DPICHANGED, c.WM_STYLECHANGED => layout(window),
        // A child window the content made, a page, goes under the buttons.
        c.WM_PARENTNOTIFY => if (wp & 0xffff == c.WM_CREATE and @as(c.HWND, @ptrFromInt(@as(usize, @bitCast(lp)))) != caption.buttons and @as(c.HWND, @ptrFromInt(@as(usize, @bitCast(lp)))) != caption.snap) layout(window),
        c.WM_NCACTIVATE => {
            const active = wp != 0;
            if (caption.active != active) {
                caption.active = active;
                paint(window);
            }
        },
        // The appearance changed.
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED, c.WM_DWMCOLORIZATIONCOLORCHANGED => paint(window),
        else => {},
    }
}

fn setHot(window: *core.WindowRecord, index: i8) void {
    const caption = &window.native.caption;
    var buffer: [3]Button = undefined;
    const buttons = shown(window, &buffer);
    const next: i8 = if (index >= 0 and !enabled(window, buttons[@intCast(index)])) -1 else index;
    if (next != caption.hot) {
        caption.hot = next;
        paint(window);
    }
}

/// The index of the button at the screen position of a non-client mouse
/// message, or -1.
fn indexAt(window: *core.WindowRecord, lp: c.LPARAM) i8 {
    const caption = &window.native.caption;
    const bits: usize = @bitCast(lp);
    var at: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
    if (c.ScreenToClient(caption.buttons, &at) == 0) return -1;
    const dpi = c.GetDpiForWindow(window.native.hwnd);
    const width = px(button_width, dpi);
    if (at.x < 0 or at.y < 0 or at.y >= px(height(window), dpi) or width <= 0) return -1;
    var buffer: [3]Button = undefined;
    const index = @divTrunc(at.x, width);
    return if (index < shown(window, &buffer).len) @intCast(index) else -1;
}

fn click(window: *core.WindowRecord, button: Button) void {
    if (!enabled(window, button)) return;
    const parent = window.native.hwnd;
    const command: c.WPARAM = switch (button) {
        .minimize => c.SC_MINIMIZE,
        .maximize => if (c.IsZoomed(parent) != 0) c.SC_RESTORE else c.SC_MAXIMIZE,
        .close => c.SC_CLOSE,
    };
    // Sent, as the system's buttons do: one posted right after a maximize
    // never reached the window. The window may close during the call.
    _ = c.SendMessageW(parent, c.WM_SYSCOMMAND, command, 0);
}

fn captionProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const created: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(created.lpCreateParams)));
        return c.DefWindowProcW(hwnd, message, wp, lp);
    }
    const stored: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    if (stored == 0) return c.DefWindowProcW(hwnd, message, wp, lp);
    const window: *core.WindowRecord = @ptrFromInt(stored);
    if (hwnd != null and window.native.caption.snap == hwnd) return snapMessage(window, hwnd, message, wp, lp);
    if (window.native.caption.buttons != hwnd) return c.DefWindowProcW(hwnd, message, wp, lp);
    const caption = &window.native.caption;
    var buffer: [3]Button = undefined;
    switch (message) {
        c.WM_NCHITTEST => {
            const index = indexAt(window, lp);
            if (index >= 0) {
                const button = shown(window, &buffer)[@intCast(index)];
                if (enabled(window, button)) return button.hitTest();
            }
            return c.HTCLIENT;
        },
        c.WM_NCMOUSEMOVE => {
            setHot(window, indexAt(window, lp));
            if (!caption.tracking) {
                var track: c.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(c.TRACKMOUSEEVENT), .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT, .hwndTrack = hwnd, .dwHoverTime = 0 };
                _ = c.TrackMouseEvent(&track);
                caption.tracking = true;
            }
            // The default procedure brings the snap layouts over
            // HTMAXBUTTON.
            return c.DefWindowProcW(hwnd, message, wp, lp);
        },
        c.WM_NCMOUSELEAVE, c.WM_MOUSELEAVE => {
            caption.tracking = false;
            caption.pressed = -1;
            caption.hot = -1;
            paint(window);
            return 0;
        },
        c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK => {
            // Not the default procedure: it would run the system's buttons
            // on this child window.
            const index = indexAt(window, lp);
            if (index >= 0 and enabled(window, shown(window, &buffer)[@intCast(index)])) {
                caption.pressed = index;
                paint(window);
            }
            return 0;
        },
        c.WM_NCLBUTTONUP => {
            const index = indexAt(window, lp);
            const pressed = caption.pressed;
            caption.pressed = -1;
            paint(window);
            if (index >= 0 and index == pressed) click(window, shown(window, &buffer)[@intCast(index)]);
            return 0;
        },
        c.WM_NCRBUTTONDOWN, c.WM_NCRBUTTONUP, c.WM_NCRBUTTONDBLCLK => return 0,
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

// The maximize button that the content draws, in a window without the
// system's buttons (`hide_window_buttons`), gets Windows 11's snap layouts
// as the system's does: a window over it, layered without pixels, answers
// HTMAXBUTTON, and the default procedure shows them as the pointer rests
// there. The pointer's moves and presses over it, which come as non-client
// messages, go on to the window as client ones, so the content hovers and
// clicks its button as any other.

/// Puts the window that brings the snap layouts over the content's
/// maximize button, or hides it for null.
pub fn setMaximizeButton(window: *core.WindowRecord, rect: ?core.Rect) void {
    const caption = &window.native.caption;
    if (window.options.title_bar == .default) return;
    if (std.meta.eql(caption.snap_rect, rect)) return;
    caption.snap_rect = rect;
    if (caption.snap == null and rect != null) {
        if (!registerClass()) return;
        caption.snap = c.CreateWindowExW(c.WS_EX_LAYERED | ws_ex_no_redirection_bitmap, class_name, null, c.WS_CHILD | c.WS_CLIPSIBLINGS, 0, 0, 0, 0, window.native.hwnd, null, c.GetModuleHandleW(null), window);
        const snap = caption.snap orelse return;
        _ = c.SetLayeredWindowAttributes(snap, 0, 255, c.LWA_ALPHA);
    }
    layoutSnap(window);
}

fn layoutSnap(window: *core.WindowRecord) void {
    const caption = &window.native.caption;
    const snap = caption.snap orelse return;
    const parent = window.native.hwnd;
    const dpi: f32 = @floatFromInt(c.GetDpiForWindow(parent));
    const r = caption.snap_rect orelse core.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const scale = dpi / 96;
    const x0: c_int = @intFromFloat(@round(r.x * scale));
    const y0: c_int = @intFromFloat(@round(r.y * scale));
    const x1: c_int = @intFromFloat(@round((r.x + r.width) * scale));
    const y1: c_int = @intFromFloat(@round((r.y + r.height) * scale));
    const hidden = window.native.fullscreen or x1 <= x0 or y1 <= y0 or styleBits(window) & c.WS_MAXIMIZEBOX == 0;
    const show: c.UINT = if (hidden) c.SWP_HIDEWINDOW else c.SWP_SHOWWINDOW;
    // HWND_TOP: above the content's child windows.
    _ = c.SetWindowPos(snap, null, x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0), @as(c.UINT, c.SWP_NOACTIVATE) | show);
}

/// Gives the window a client mouse message at the screen position of a
/// non-client one.
fn toContent(window: *core.WindowRecord, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) void {
    const bits: usize = @bitCast(lp);
    var at: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
    const parent = window.native.hwnd;
    if (c.ScreenToClient(parent, &at) == 0) return;
    const x: u16 = @bitCast(@as(i16, @truncate(at.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(at.y)));
    _ = c.SendMessageW(parent, message, wp, @bitCast(@as(usize, x) | (@as(usize, y) << 16)));
}

fn snapMessage(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) c.LRESULT {
    const caption = &window.native.caption;
    switch (message) {
        c.WM_NCHITTEST => return c.HTMAXBUTTON,
        c.WM_NCMOUSEMOVE => {
            if (!caption.snap_tracking) {
                var track: c.TRACKMOUSEEVENT = .{ .cbSize = @sizeOf(c.TRACKMOUSEEVENT), .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT, .hwndTrack = hwnd, .dwHoverTime = 0 };
                _ = c.TrackMouseEvent(&track);
                caption.snap_tracking = true;
            }
            toContent(window, c.WM_MOUSEMOVE, 0, lp);
            // The default procedure brings the snap layouts over
            // HTMAXBUTTON.
            return c.DefWindowProcW(hwnd, message, wp, lp);
        },
        c.WM_NCMOUSELEAVE, c.WM_MOUSELEAVE => {
            caption.snap_tracking = false;
            return 0;
        },
        // Not the default procedure, which would maximize the window
        // itself: the content takes the press, and with it the capture
        // that brings it the release.
        c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK => {
            toContent(window, c.WM_LBUTTONDOWN, c.MK_LBUTTON, lp);
            return 0;
        },
        c.WM_NCLBUTTONUP => {
            toContent(window, c.WM_LBUTTONUP, 0, lp);
            return 0;
        },
        c.WM_NCRBUTTONDOWN, c.WM_NCRBUTTONUP, c.WM_NCRBUTTONDBLCLK => return 0,
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

/// A color with straight alpha.
pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// Windows 11's close button is red on hover, and Windows 10's a brighter
/// red.
const close_red_11: Rgba = .{ .r = 0xC4, .g = 0x2B, .b = 0x1C, .a = 0xFF };
const close_red_10: Rgba = .{ .r = 0xE8, .g = 0x11, .b = 0x23, .a = 0xFF };

pub const Look = struct { hot: bool, pressed: bool, enabled: bool, active: bool, close: bool, dark: bool, fluent: bool };

/// The backplate and glyph colors of a button, after Windows' own: the glyph
/// in the appearance's text color, fainter while the window is inactive or
/// the button disabled; on hover and press a backplate of the glyph's color
/// at 10% and 20%, or red behind a white glyph for close. At rest the
/// backplate is all but transparent, which keeps the buttons' window taking
/// the mouse there.
pub fn colors(look: Look) struct { back: Rgba, fore: Rgba } {
    var fore: Rgba = if (look.dark) .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF } else .{ .r = 0, .g = 0, .b = 0, .a = 0xE4 };
    var back: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const red = if (look.fluent) close_red_11 else close_red_10;
    const white: Rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF };
    if (!look.enabled) {
        fore.a = 0x5C;
    } else if (look.hot and look.pressed and look.close) {
        back = .{ .r = red.r, .g = red.g, .b = red.b, .a = 0xCC };
        fore = white;
    } else if (look.hot and look.close) {
        back = red;
        fore = white;
    } else if (look.hot and look.pressed) {
        back = .{ .r = fore.r, .g = fore.g, .b = fore.b, .a = 0x33 };
    } else if (look.hot) {
        back = .{ .r = fore.r, .g = fore.g, .b = fore.b, .a = 0x1A };
    } else if (!look.active) {
        fore.a = 0x72;
    }
    return .{ .back = back, .fore = fore };
}

/// Lays a glyph color of coverage `coverage` (0 to 255) over a backplate:
/// the premultiplied BGRA pixel that UpdateLayeredWindow takes.
pub fn over(fore: Rgba, coverage: u32, back: Rgba) u32 {
    const fa = @as(u32, fore.a) * coverage / 255;
    const ba = @as(u32, back.a) * (255 - fa) / 255;
    const channel = struct {
        fn mix(f: u8, b: u8, fa_: u32, ba_: u32) u32 {
            return (@as(u32, f) * fa_ + @as(u32, b) * ba_) / 255;
        }
    }.mix;
    return (fa + ba) << 24 | channel(fore.r, back.r, fa, ba) << 16 | channel(fore.g, back.g, fa, ba) << 8 | channel(fore.b, back.b, fa, ba);
}

/// The buttons draw dark in a dark window: one given the dark frame
/// (`theme.setWindowDark`), or with apps in dark mode.
fn dark(window: *core.WindowRecord) bool {
    var value: c.BOOL = 0;
    if (DwmGetWindowAttribute(window.native.hwnd, 20, &value, @sizeOf(c.BOOL)) >= 0 and value != 0) return true;
    var light: u32 = 1;
    var size: u32 = @sizeOf(u32);
    const key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    if (c.RegGetValueW(c.HKEY_CURRENT_USER, key, name, c.RRF_RT_REG_DWORD, null, &light, &size) != 0) return false;
    return light == 0;
}

fn font(caption: *Caption, dpi: u32) c.HFONT {
    if (caption.font != null and caption.font_dpi == dpi) return caption.font;
    if (caption.font) |old| _ = c.DeleteObject(old);
    const size = -px(glyph_size, dpi); // the em height
    caption.fluent = true;
    caption.font = createFont(size, std.unicode.utf8ToUtf16LeStringLiteral("Segoe Fluent Icons"));
    if (!isFace(caption.font, "Segoe Fluent Icons")) {
        if (caption.font) |substitute| _ = c.DeleteObject(substitute);
        caption.fluent = false;
        caption.font = createFont(size, std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"));
    }
    caption.font_dpi = dpi;
    return caption.font;
}
fn createFont(size: c_int, face: [*:0]const u16) c.HFONT {
    return c.CreateFontW(size, 0, 0, 0, c.FW_NORMAL, 0, 0, 0, c.DEFAULT_CHARSET, 0, 0, c.ANTIALIASED_QUALITY, 0, face);
}
/// Whether the font is the named face, not one Windows substituted for a
/// missing one.
fn isFace(handle: c.HFONT, name: []const u8) bool {
    const dc = c.CreateCompatibleDC(null) orelse return false;
    defer _ = c.DeleteDC(dc);
    const old = c.SelectObject(dc, handle);
    defer _ = c.SelectObject(dc, old);
    var buffer: [64]u16 = undefined;
    const length = c.GetTextFaceW(dc, buffer.len, &buffer);
    if (length <= 0) return false;
    var utf8: [192]u8 = undefined;
    const end = std.mem.indexOfScalar(u16, buffer[0..@intCast(length)], 0) orelse @as(usize, @intCast(length));
    const written = std.unicode.utf16LeToUtf8(&utf8, buffer[0..end]) catch return false;
    return std.ascii.eqlIgnoreCase(utf8[0..written], name);
}

/// A 32-bit top-down DIB section selected into a memory DC.
const Bitmap = struct {
    dc: c.HDC,
    bitmap: c.HBITMAP,
    old: c.HGDIOBJ,
    pixels: []u32,

    fn init(screen: c.HDC, width: c_int, height_: c_int) ?Bitmap {
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height_;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        var bits: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(screen, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
        const pointer = bits orelse {
            _ = c.DeleteObject(bitmap);
            return null;
        };
        const dc = c.CreateCompatibleDC(screen) orelse {
            _ = c.DeleteObject(bitmap);
            return null;
        };
        const old = c.SelectObject(dc, bitmap);
        const many: [*]u32 = @ptrCast(@alignCast(pointer));
        return .{ .dc = dc, .bitmap = bitmap, .old = old, .pixels = many[0..@intCast(width * height_)] };
    }
    fn deinit(self: Bitmap) void {
        _ = c.SelectObject(self.dc, self.old);
        _ = c.DeleteDC(self.dc);
        _ = c.DeleteObject(self.bitmap);
    }
};

/// Draws the buttons for the window's state and appearance into their
/// window.
pub fn paint(window: *core.WindowRecord) void {
    const caption = &window.native.caption;
    const hwnd = caption.buttons orelse return;
    const parent = window.native.hwnd;
    const dpi = c.GetDpiForWindow(parent);
    var buffer: [3]Button = undefined;
    const buttons = shown(window, &buffer);
    const bw = px(button_width, dpi);
    const h = px(height(window), dpi);
    const width = bw * @as(c_int, @intCast(buttons.len));
    if (width <= 0 or h <= 0) return;
    const screen = c.GetDC(null);
    defer _ = c.ReleaseDC(null, screen);
    const image = Bitmap.init(screen, width, h) orelse return;
    defer image.deinit();
    const mask = Bitmap.init(screen, width, h) orelse return;
    defer mask.deinit();
    @memset(mask.pixels, 0);

    // The glyphs white on black: their coverage.
    const old = c.SelectObject(mask.dc, font(caption, dpi));
    _ = c.SetBkMode(mask.dc, c.TRANSPARENT);
    _ = c.SetTextColor(mask.dc, 0xFFFFFF);
    const maximized = c.IsZoomed(parent) != 0;
    for (buttons, 0..) |button, i| {
        var glyph = button.glyph(maximized);
        const left = @as(c_int, @intCast(i)) * bw;
        var rect: c.RECT = .{ .left = left, .top = 0, .right = left + bw, .bottom = h };
        _ = c.DrawTextW(mask.dc, @ptrCast(&glyph), 1, &rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
    }
    _ = c.SelectObject(mask.dc, old);
    _ = c.GdiFlush();

    const is_dark = dark(window);
    const row: usize = @intCast(width);
    for (buttons, 0..) |button, i| {
        const index: i8 = @intCast(i);
        const hot = index == caption.hot and (caption.pressed < 0 or caption.pressed == index);
        const look = colors(.{ .hot = hot, .pressed = caption.pressed == index, .enabled = enabled(window, button), .active = caption.active, .close = button == .close, .dark = is_dark, .fluent = caption.fluent });
        for (0..@intCast(h)) |y| {
            const start = i * @as(usize, @intCast(bw));
            for (start..start + @as(usize, @intCast(bw))) |x| image.pixels[y * row + x] = over(look.fore, mask.pixels[y * row + x] & 0xFF, look.back);
        }
    }
    if (caption.composed) |composed| {
        _ = zwc_present(composed, image.pixels.ptr, @intCast(width), @intCast(h));
        return;
    }
    var extent: c.SIZE = .{ .cx = width, .cy = h };
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    var blend: c.BLENDFUNCTION = .{ .BlendOp = c.AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = c.AC_SRC_ALPHA };
    _ = c.UpdateLayeredWindow(hwnd, screen, null, &extent, image.dc, &origin, 0, &blend, c.ULW_ALPHA);
}

test "caption colors follow Windows 11" {
    const rest = colors(.{ .hot = false, .pressed = false, .enabled = true, .active = true, .close = false, .dark = false, .fluent = true });
    try std.testing.expectEqual(@as(u8, 1), rest.back.a);
    try std.testing.expectEqual(@as(u8, 0xE4), rest.fore.a);
    const close = colors(.{ .hot = true, .pressed = false, .enabled = true, .active = true, .close = true, .dark = false, .fluent = true });
    try std.testing.expectEqual(close_red_11, close.back);
    try std.testing.expectEqual(@as(u8, 0xFF), close.fore.r);
    const old_close = colors(.{ .hot = true, .pressed = true, .enabled = true, .active = true, .close = true, .dark = true, .fluent = false });
    try std.testing.expectEqual(@as(u8, 0xCC), old_close.back.a);
    try std.testing.expectEqual(close_red_10.r, old_close.back.r);
    const pressed = colors(.{ .hot = true, .pressed = true, .enabled = true, .active = true, .close = false, .dark = true, .fluent = true });
    try std.testing.expectEqual(@as(u8, 0x33), pressed.back.a);
    try std.testing.expectEqual(@as(u8, 0x72), colors(.{ .hot = false, .pressed = false, .enabled = true, .active = false, .close = false, .dark = false, .fluent = true }).fore.a);
    try std.testing.expectEqual(@as(u8, 0x5C), colors(.{ .hot = true, .pressed = false, .enabled = false, .active = true, .close = true, .dark = false, .fluent = true }).fore.a);
}

test "caption pixels are premultiplied" {
    const white: Rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF };
    const clear: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), over(white, 255, clear));
    try std.testing.expectEqual(@as(u32, 0), over(white, 0, clear));
    const half = over(white, 128, clear);
    try std.testing.expectEqual(half >> 24, half & 0xFF);
    // Over red, the full glyph leaves no red.
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), over(white, 255, close_red_11));
}
