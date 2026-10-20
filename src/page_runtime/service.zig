const ipc = @import("ziggurat_ipc");

pub const Direction = enum { ltr, rtl };
pub const ColorScheme = enum { light, dark, unknown };

/// Desktop appearance and accessibility settings as pages receive them.
pub const Preferences = struct {
    /// "#rrggbb", or null where the desktop has no accent color.
    accent: ?[]const u8,
    colorScheme: ColorScheme,
    reduceMotion: bool,
    /// False where the desktop exposes no transparency preference.
    reduceTransparency: bool,
    highContrast: bool,
    /// Text scaling relative to the platform default of 1.
    textScale: f64,
};

pub const LocaleChange = struct { locale: []const u8, dir: Direction };

/// Files dropped on the window; x/y are CSS pixels relative to the page.
pub const FileDrop = struct { paths: []const []const u8, x: f64, y: f64 };

/// The document a window shows, for pages of document windows.
pub const DocumentState = struct {
    name: []const u8,
    /// Empty while the document is untitled.
    path: []const u8,
    edited: bool,
    readOnly: bool,
    conflict: bool,
    deleted: bool,
};

pub const WindowError = enum { unavailable, invalid_state };

/// The built-in service every connected page receives. Method names are the
/// page-facing names; `closeWindow` avoids the client's reserved `close`.
pub const Service = struct {
    pub const methods = .{
        .minimize = ipc.Method(void, void, WindowError, void),
        .maximize = ipc.Method(void, void, WindowError, void),
        .unmaximize = ipc.Method(void, void, WindowError, void),
        .toggleMaximize = ipc.Method(void, void, WindowError, void),
        .isMaximized = ipc.Method(void, bool, WindowError, void),
        .toggleFullScreen = ipc.Method(void, void, WindowError, void),
        .closeWindow = ipc.Method(void, void, WindowError, void),
        .setTitle = ipc.Method(struct { title: []const u8 }, void, WindowError, void),
    };
    pub const events = .{
        .locale = ipc.Event(LocaleChange),
        .preferences = ipc.Event(Preferences),
        .fileDrop = ipc.Event(FileDrop),
        .documentState = ipc.Event(DocumentState),
        .documentReload = ipc.Event(void),
    };
};

/// The service name pages use for the built-in runtime.
pub const name = "runtime";
