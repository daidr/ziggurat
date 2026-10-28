//! The app's light or dark appearance: the desktop's, or one the app forces.
//! A Follower applies it to the native parts the system draws (window title
//! bars and popup menus on Windows, GTK's theme variant on Linux) and tells
//! the app whenever the appearance or the desktop's preferences change, so
//! drawn content can switch its own theme then.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const desktop = @import("desktop.zig");

const os = builtin.os.tag;
const native_supported = !builtin.is_test and (os == .windows or os == .linux);
pub const capabilities = .{ .follow = native_supported, .window_frame = native_supported and os == .windows };
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
/// theme variant on Linux, popup menus on Windows. `dark` is the appearance
/// `.system` resolves to.
pub fn apply(app: *z.App, source: Source, dark: bool) void {
    app.assertOwner();
    if (comptime !native_supported) return;
    if (os == .linux) return zsx_theme_set_source(@backingInt(source));
    menuMode(dark);
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
        // Following the desktop, GTK's own variant must be the desktop's
        // before it is read again.
        if (os == .linux and self.source == .system) apply(app, .system, false);
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
