//! The app's light or dark appearance: the desktop's, or one the app forces.
//! A Follower applies it to the native parts the system draws (window title
//! bars and popup menus on Windows, GTK's theme variant on Linux, the
//! application's NSAppearance on macOS) and tells
//! the app whenever the appearance or the desktop's preferences change, so
//! drawn content can switch its own theme then.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const desktop = @import("desktop.zig");

const os = builtin.os.tag;
const browser = builtin.cpu.arch == .wasm32;
const native_supported = !builtin.is_test and (os == .windows or os == .linux or os == .macos or browser);
pub const capabilities = .{ .follow = native_supported, .window_frame = native_supported and os == .windows and !browser };
pub const max_windows = 64;

pub const Source = enum(u8) { system, light, dark };

const c = @import("ziggurat_c_win32");

extern fn zsx_theme_set_source(source: c_int) void;

/// Gives the window's title bar and frame the dark or light appearance.
/// Windows only: GTK draws every window in the theme variant `apply` picks.
pub fn setWindowDark(window: z.Window, dark: bool) !void {
    window.app.assertOwner();
    if (comptime !(native_supported and os == .windows)) return error.UnsupportedCapability;
    const hwnd = window.nativeHandle() orelse return error.Closed;
    const value: c.BOOL = @intFromBool(dark);
    if (DwmSetWindowAttribute(@ptrCast(hwnd), dwm_use_immersive_dark_mode, &value, @sizeOf(c.BOOL)) < 0) return error.WindowUpdateFailed;
}
extern "dwmapi" fn DwmSetWindowAttribute(c.HWND, u32, *const anyopaque, u32) callconv(.winapi) c.HRESULT;
const dwm_use_immersive_dark_mode = 20;

/// Applies a source process-wide, for what the system draws itself: GTK's
/// theme variant on Linux, popup menus on Windows, every window and menu
/// through the application's appearance on macOS. `dark` is the appearance
/// `.system` resolves to.
pub fn apply(app: *z.App, source: Source, dark: bool) void {
    app.assertOwner();
    if (comptime !native_supported) return;
    // A page draws nothing of its own for the app: its content follows.
    if (comptime browser) return;
    if (os == .linux or os == .macos) return zsx_theme_set_source(@backingInt(source));
    @import("windows_menu.zig").dark_menus = dark;
    menuMode(dark);
}

extern fn zsx_theme_set_gtk_css(css: [*]const u8, len: usize, message: [*]u8, capacity: usize) c_int;

/// The longest message `setGtkCss` keeps of GTK's first parse error.
pub const max_css_error = 256;

/// Restyles what GTK draws itself on Linux, with a GTK 3 style sheet of the
/// app's: the title bar and decorations of a window the desktop leaves to
/// decorate itself, the shadow and border around a frameless window, title
/// buttons, menus and dialogs, as the flat header bars and round buttons of
/// newer GTK apps. GTK takes it at the user's priority, over the theme's
/// rules and the user's gtk.css. Another call replaces the sheet, as a
/// switch of the app's theme does, and "" removes it; a sheet that does not
/// parse fails with `InvalidStyleSheet` and keeps the one before, with
/// GTK's first error and where it is in `message` when given. Content the
/// app draws and pages never see it. Nothing elsewhere.
pub fn setGtkCss(app: *z.App, css: []const u8, message: ?*[max_css_error]u8) !void {
    app.assertOwner();
    if (comptime !(native_supported and os == .linux)) return;
    var scratch: [max_css_error]u8 = undefined;
    const buffer = message orelse &scratch;
    switch (zsx_theme_set_gtk_css(css.ptr, css.len, buffer, buffer.len)) {
        0 => {},
        1 => return error.InvalidStyleSheet,
        else => return error.UnsupportedCapability,
    }
}

pub const WindowButton = enum { minimize, maximize, close };

/// The window controls the desktop puts in title bars, at their start and
/// at their end, in the desktop's order. An app that hides the system's
/// buttons and draws its own can draw these, where the desktop wants them.
pub const WindowButtons = struct {
    start_buttons: [3]WindowButton = undefined,
    start_len: u8 = 0,
    end_buttons: [3]WindowButton = undefined,
    end_len: u8 = 0,

    pub fn start(self: *const WindowButtons) []const WindowButton {
        return self.start_buttons[0..self.start_len];
    }
    pub fn end(self: *const WindowButtons) []const WindowButton {
        return self.end_buttons[0..self.end_len];
    }
    /// Whether the desktop puts `button` in title bars.
    pub fn has(self: *const WindowButtons, button: WindowButton) bool {
        return std.mem.indexOfScalar(WindowButton, self.start(), button) != null or std.mem.indexOfScalar(WindowButton, self.end(), button) != null;
    }
    /// Whether the desktop puts no buttons in title bars.
    pub fn empty(self: *const WindowButtons) bool {
        return self.start_len == 0 and self.end_len == 0;
    }
    /// A layout as gtk-decoration-layout writes it, "close:" or
    /// "menu:minimize,maximize,close": names other than the three buttons,
    /// and a button named twice, are left out.
    pub fn parse(layout: []const u8) WindowButtons {
        var result: WindowButtons = .{};
        const colon = std.mem.indexOfScalar(u8, layout, ':');
        const sides = [2][]const u8{ layout[0 .. colon orelse layout.len], if (colon) |at| layout[at + 1 ..] else "" };
        for (sides, 0..) |side, index| {
            var names = std.mem.splitScalar(u8, side, ',');
            while (names.next()) |raw| {
                const button = std.meta.stringToEnum(WindowButton, std.mem.trim(u8, raw, " \t")) orelse continue;
                if (result.has(button)) continue;
                if (index == 0) {
                    result.start_buttons[result.start_len] = button;
                    result.start_len += 1;
                } else {
                    result.end_buttons[result.end_len] = button;
                    result.end_len += 1;
                }
            }
        }
        return result;
    }
};

extern fn zsx_theme_window_buttons(out: [*]u8, capacity: usize) c_int;

/// The window controls the desktop's title bars have. macOS puts close,
/// minimize and maximize at the start, Windows minimize, maximize and
/// close at the end. On Linux the desktop's button layout
/// (gtk-decoration-layout) decides: none under a Wayland compositor that
/// decorates windows itself, as tiling ones such as Sway and Hyprland,
/// which draw no buttons, and none where the user emptied the layout. A
/// Follower tells when it changes, as the desktop's preferences do.
pub fn windowButtons(app: *z.App) WindowButtons {
    app.assertOwner();
    if (comptime native_supported and os == .linux and !browser) {
        var text: [128]u8 = undefined;
        const length = zsx_theme_window_buttons(&text, text.len);
        if (length >= 0) return .parse(text[0..@intCast(length)]);
    }
    return defaultWindowButtons(if (browser) .linux else os);
}
fn defaultWindowButtons(tag: std.Target.Os.Tag) WindowButtons {
    return if (tag == .macos) .parse("close,minimize,maximize:") else .parse(":minimize,maximize,close");
}

test "window buttons of a layout" {
    const gnome = WindowButtons.parse("appmenu:close");
    try std.testing.expectEqual(@as(usize, 0), gnome.start().len);
    try std.testing.expectEqualSlices(WindowButton, &.{.close}, gnome.end());
    try std.testing.expect(gnome.has(.close) and !gnome.has(.minimize));
    const left = WindowButtons.parse("close, minimize ,maximize:icon");
    try std.testing.expectEqualSlices(WindowButton, &.{ .close, .minimize, .maximize }, left.start());
    try std.testing.expect(WindowButtons.parse(":").empty());
    try std.testing.expect(WindowButtons.parse("").empty());
    try std.testing.expectEqual(@as(usize, 1), WindowButtons.parse("close,close:close").start().len);
    try std.testing.expectEqualSlices(WindowButton, &.{ .close, .minimize, .maximize }, defaultWindowButtons(.macos).start());
    try std.testing.expectEqualSlices(WindowButton, &.{ .minimize, .maximize, .close }, defaultWindowButtons(.windows).end());
}

/// uxtheme's preferred app mode (ordinal 135, from Windows 10 build 18362)
/// gives popup menus the appearance; ordinal 136 rebuilds their themes.
fn menuMode(dark: bool) void {
    const Cache = struct {
        var loaded = false;
        var set: ?*const fn (c_int) callconv(.winapi) c_int = null;
        var flush: ?*const fn () callconv(.winapi) void = null;
    };
    if (!Cache.loaded) {
        Cache.loaded = true;
        var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        if (std.os.windows.ntdll.RtlGetVersion(&info) != .SUCCESS or info.dwMajorVersion < 10 or (info.dwMajorVersion == 10 and info.dwBuildNumber < 18362)) return;
        const module = c.LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("uxtheme.dll"), null, 0x00000800) orelse return;
        Cache.set = @ptrCast(c.GetProcAddress(module, @ptrFromInt(135)));
        Cache.flush = @ptrCast(c.GetProcAddress(module, @ptrFromInt(136)));
    }
    const set = Cache.set orelse return;
    _ = set(if (dark) 2 else 3); // ForceDark, ForceLight
    if (Cache.flush) |flush| flush();
}

pub const Handler = struct {
    context: *anyopaque,
    /// Runs on the owner thread after the appearance was applied. It may
    /// stop the Follower.
    changed: *const fn (*anyopaque, *Follower) void,
};
pub const Options = struct { source: Source = .system, on_change: ?Handler = null };

/// Caller-owned and address-stable from start until stop or App shutdown.
pub const Follower = struct {
    app: ?*z.App = null,
    source: Source = .system,
    on_change: ?Handler = null,
    dark: bool = false,
    prefs: desktop.Preferences = .{},
    watch: desktop.Watch = undefined,
    windows: [max_windows]?z.Window = @splat(null),
    /// Per tracked window: the appearance its frame and caption buttons
    /// keep whatever the app's (`.system` follows the app).
    buttons: [max_windows]Source = @splat(.system),

    /// Reads the desktop's preferences, applies the source and starts
    /// following the desktop's changes.
    pub fn start(self: *Follower, app: *z.App, options: Options) !void {
        app.assertOwner();
        if (self.app != null) return error.AlreadyStarted;
        if (comptime !native_supported) return error.UnsupportedCapability;
        self.* = .{ .app = app, .source = options.source, .on_change = options.on_change };
        self.watch = desktop.Watch.init(self, changed);
        errdefer self.app = null;
        try self.watch.start(app, .{ .preferences = true });
        self.refresh(false);
    }
    /// Idempotent. Windows already tracked keep their frames.
    pub fn stop(self: *Follower) void {
        if (self.app == null) return;
        self.watch.stop();
        self.app = null;
    }
    pub fn running(self: *const Follower) bool {
        return self.app != null and self.watch.running();
    }
    /// Forces light or dark, or follows the desktop again. on_change runs
    /// when the effective appearance changes.
    pub fn setSource(self: *Follower, source: Source) void {
        const app = self.app orelse return;
        app.assertOwner();
        self.source = source;
        self.refresh(true);
    }
    /// The effective appearance.
    pub fn isDark(self: *const Follower) bool {
        return self.dark;
    }
    /// The desktop's preferences read at the last change.
    pub fn preferences(self: *const Follower) desktop.Preferences {
        return self.prefs;
    }
    /// Gives the window's frame the appearance now and on every change
    /// (Windows; a no-op on Linux, where GTK follows `apply`). Closed
    /// windows leave the list by themselves.
    pub fn track(self: *Follower, window: z.Window) !void {
        _ = try self.slotOf(window);
    }
    /// Draws the window's frame and caption buttons for a dark or a light
    /// background whatever the app's appearance, for content with a dark
    /// title area in a light app, or follows the app again with `.system`.
    /// Menus and the app's own content keep the app's appearance, which
    /// `setSource` would change. Tracks the window. Windows only; GTK
    /// draws every window in the app's variant.
    pub fn setWindowButtons(self: *Follower, window: z.Window, source: Source) !void {
        const index = try self.slotOf(window);
        self.buttons[index] = source;
        if (comptime os == .windows) try setWindowDark(window, self.frameDark(index));
    }
    fn frameDark(self: *const Follower, index: usize) bool {
        return switch (self.buttons[index]) {
            .system => self.dark,
            .light => false,
            .dark => true,
        };
    }
    fn slotOf(self: *Follower, window: z.Window) !usize {
        _ = self.app orelse return error.Closed;
        window.app.assertOwner();
        var free: ?usize = null;
        for (&self.windows, 0..) |*entry, index| {
            if (entry.*) |existing| {
                if (existing.isClosed()) entry.* = null else if (std.meta.eql(existing.key, window.key)) return index;
            }
            if (entry.* == null and free == null) free = index;
        }
        const index = free orelse return error.CapacityExceeded;
        self.buttons[index] = .system;
        if (comptime os == .windows) try setWindowDark(window, self.dark);
        self.windows[index] = window;
        return index;
    }
    pub fn untrack(self: *Follower, window: z.Window) void {
        for (&self.windows) |*slot| if (slot.*) |existing| if (std.meta.eql(existing.key, window.key)) {
            slot.* = null;
        };
    }

    fn changed(ptr: *anyopaque, _: desktop.Change) void {
        const self: *Follower = @ptrCast(@alignCast(ptr));
        self.refresh(true);
    }
    fn refresh(self: *Follower, notify: bool) void {
        const app = self.app orelse return;
        const was = self.dark;
        const old_prefs = self.prefs;
        // Following the desktop, GTK's own variant (the app's appearance on
        // macOS) must be the desktop's before it is read again.
        if ((os == .linux or os == .macos) and self.source == .system) apply(app, .system, false);
        self.prefs = desktop.preferences(app) catch self.prefs;
        self.dark = switch (self.source) {
            .light => false,
            .dark => true,
            .system => self.prefs.color_scheme == .dark,
        };
        apply(app, self.source, self.dark);
        if (comptime os == .windows) for (&self.windows, 0..) |*entry, index| if (entry.*) |window| {
            setWindowDark(window, self.frameDark(index)) catch {
                entry.* = null;
            };
        };
        if (!notify or (was == self.dark and std.meta.eql(old_prefs, self.prefs))) return;
        if (self.on_change) |handler| handler.changed(handler.context, self);
    }
};
