const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
const NativeShellFailure = extern struct { domain: u32 = 0, code: u32 = 0 };
/// GIO on Linux; macOS implements the same entry points with NSWorkspace
/// and NSFileManager (src/system/macos_services.m).
const gio = if (builtin.os.tag == .linux or builtin.os.tag == .macos) struct {
    extern fn zsh_open_uri(uri: [*:0]const u8, failure: *NativeShellFailure) c_int;
    extern fn zsh_open_path(path: [*:0]const u8, failure: *NativeShellFailure) c_int;
    extern fn zsh_reveal(path: [*:0]const u8, timeout_ms: c_int, failure: *NativeShellFailure) c_int;
    extern fn zsh_trash(path: [*:0]const u8, failure: *NativeShellFailure) c_int;
    extern fn zsh_apps(visit: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int, context: ?*anyopaque) c_int;
    extern fn zsh_launch_app(path: [*:0]const u8, failure: *NativeShellFailure) c_int;
    extern fn zsh_default_app(url: ?[*:0]const u8, scheme: ?[*:0]const u8, path: ?[*:0]const u8, visit: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) c_int, context: ?*anyopaque, failure: *NativeShellFailure) c_int;
    extern fn zsh_file_icon(path: [*:0]const u8, size: c_int, background: u32, out: [*]u8, failure: *NativeShellFailure) c_int;
    extern fn zsh_type_icon(extension: [*:0]const u8, size: c_int, background: u32, out: [*]u8) c_int;
} else struct {};
const GioStatus = enum(c_int) { ok = 0, failed = 1, not_supported = 2, not_found = 3, access_denied = 4, unavailable = 5, timed_out = 6, invalid = 7, _ };

pub const max_arguments = 128;
pub const max_argument_bytes = 16 * 1024;
pub const max_command_units = 32767;
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    pub fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const LaunchOptions = struct {
    /// Absolute executable path. Windows requires an explicit .exe extension;
    /// no PATH/PATHEXT search, file association or command interpreter is used.
    executable: []const u8,
    arguments: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    cancellation: ?*const Cancellation = null,
};
pub const Term = union(enum) { Exited: u32, Signal: u32, Stopped: u32, Unknown: u32 };
/// win32: GetLastError. hresult: COM/Shell HRESULT. shell_file_operation:
/// SHFileOperationW's own return code (not a Win32 error). gio/dbus/glib:
/// GError code in G_IO_ERROR, G_DBUS_ERROR or another GLib domain. cocoa:
/// NSError code (NSCocoaErrorDomain or NSPOSIXErrorDomain). osstatus: macOS
/// OSStatus, such as a Launch Services error.
pub const NativeFailure = struct { domain: enum { win32, hresult, shell_file_operation, gio, dbus, glib, cocoa, osstatus }, code: u32 };
pub const max_url_bytes = 8 * 1024;
pub const max_extra_schemes = 32;
pub const max_reveal_timeout_ms = 60_000;
/// Schemes openUrl accepts without UrlOptions.extra_schemes.
pub const default_url_schemes = [_][]const u8{ "https", "http", "mailto" };
pub const UrlOptions = struct {
    /// Further schemes the host deliberately allows, without ':'. Matching is
    /// ASCII case-insensitive. "file" and one-letter (drive-like) schemes are
    /// always rejected; local paths go through openPath.
    extra_schemes: []const []const u8 = &.{},
    cancellation: ?*const Cancellation = null,
};
pub const PathOptions = struct {
    cancellation: ?*const Cancellation = null,
};
pub const RevealOptions = struct {
    /// Linux D-Bus reply bound, 1...max_reveal_timeout_ms. Windows ignores it.
    timeout_ms: u32 = 5000,
    cancellation: ?*const Cancellation = null,
};
pub const IconOptions = struct {
    /// Pixels across. Windows draws its small or large shell icon, 16 or 32;
    /// Linux and macOS draw the icon at any size from 1 to `max_icon_size`.
    /// No thumbnail or image-file decode.
    size: u16 = 32,
    background: u32 = 0xffffff,
    cancellation: ?*const Cancellation = null,
};
pub const max_icon_size = 256;
/// Longest extension `typeIcon` takes, in bytes, without its dot.
pub const max_extension_bytes = 64;
pub const FileIcon = struct {
    width: u16,
    height: u16,
    stride: usize,
    /// Caller-owned destination, top-down RGBA8. Alpha is always 255: native
    /// icon transparency was composited against IconOptions.background.
    pixels: []const u8,
};
const posix_shell = builtin.os.tag == .linux or builtin.os.tag == .macos;

const quick_look = if (builtin.os.tag == .macos) struct {
    extern fn zsh_preview(path: [*:0]const u8) c_int;
} else struct {};
/// Shows the item at the absolute `path` in the Quick Look panel, the
/// preview Finder opens with the space bar. The panel is not modal: it stays
/// open until the user closes it, the app keeps running, and another call
/// replaces the item it shows. Main thread. macOS only; elsewhere
/// `UnsupportedCapability`.
pub fn previewItem(app: *z.App, path: []const u8) !void {
    app.assertOwner();
    if (comptime builtin.os.tag != .macos or builtin.is_test) return error.UnsupportedCapability else {
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        var storage: [max_argument_bytes + 1]u8 = undefined;
        const target = narrowZ(&storage, path);
        const status: GioStatus = @fromBackingInt(@intCast(quick_look.zsh_preview(target.ptr)));
        return switch (status) {
            .ok => {},
            .not_found => error.FileNotFound,
            .not_supported => error.UnsupportedCapability,
            else => error.PreviewFailed,
        };
    }
}
pub const capabilities = .{
    .launch_executable = builtin.os.tag == .windows or posix_shell,
    // Browsers open a tab, through `OpenUrl`.
    .open_url = builtin.os.tag == .windows or posix_shell or builtin.cpu.arch == .wasm32,
    .open_path = builtin.os.tag == .windows or posix_shell,
    .reveal = builtin.os.tag == .windows or posix_shell,
    .trash = builtin.os.tag == .windows or posix_shell,
    .file_icon = builtin.os.tag == .windows or posix_shell,
    .type_icon = builtin.os.tag == .windows or posix_shell,
    .installed_applications = builtin.os.tag == .windows or posix_shell,
    .launch_application = builtin.os.tag == .windows or posix_shell,
    .default_application = builtin.os.tag == .windows or posix_shell,
};

/// An application as a launcher lists it. `id` is the AppUserModelID (or a
/// known-folder path for a desktop app without one) on Windows, the desktop
/// file ID on Linux and the bundle identifier (or the bundle path without
/// one) on macOS; `path` is `shell:AppsFolder\<id>` on Windows, the desktop
/// entry on Linux and the .app bundle on macOS, which `launchApp` starts.
pub const InstalledApp = struct { name: []const u8, id: []const u8, path: []const u8 };
/// Owns the strings of every listed app.
pub const InstalledApps = struct {
    arena: std.heap.ArenaAllocator,
    items: []InstalledApp,
    pub fn deinit(self: *InstalledApps) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The application `defaultApp` found, owning its strings.
pub const DefaultApp = struct {
    arena: std.heap.ArenaAllocator,
    app: InstalledApp,
    pub fn deinit(self: *DefaultApp) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// What `defaultApp` asks the system about: the handler of a URL scheme,
/// or of a file, by its path (a file URL's, decoded).
pub const DefaultTarget = union(enum) { scheme: []const u8, path: []const u8 };

/// Reads `url` as `defaultApp` does: a file URL (`file:///path`, or
/// `file://localhost/path`) names the file at its percent-decoded path; any
/// other URL with a scheme of two characters or more names its scheme; text
/// without one, as `/home/me/notes.txt` or `C:\notes.txt`, is a path.
/// `storage` holds a decoded path and must be as long as `url`.
pub fn defaultTarget(storage: []u8, url: []const u8) !DefaultTarget {
    if (url.len == 0) return error.InvalidUrl;
    const colon = std.mem.indexOfScalar(u8, url, ':');
    if (colon) |at| if (std.ascii.eqlIgnoreCase(url[0..at], "file")) {
        var rest = url[at + 1 ..];
        if (std.mem.startsWith(u8, rest, "//")) {
            rest = rest[2..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUrl;
            const host = rest[0..slash];
            if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.InvalidUrl;
            rest = rest[slash..];
        }
        var length: usize = 0;
        var index: usize = 0;
        while (index < rest.len) : (index += 1) {
            var byte = rest[index];
            if (byte == '%') {
                if (index + 2 >= rest.len) return error.InvalidUrl;
                byte = std.fmt.parseInt(u8, rest[index + 1 .. index + 3], 16) catch return error.InvalidUrl;
                if (byte == 0) return error.EmbeddedNul;
                index += 2;
            }
            storage[length] = byte;
            length += 1;
        }
        var path = storage[0..length];
        // file:///C:/notes.txt names C:/notes.txt on Windows.
        if (builtin.os.tag == .windows and path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') path = path[1..];
        if (path.len == 0) return error.InvalidUrl;
        if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
        return .{ .path = path };
    };
    if (colon) |at| if (schemeSyntax(url[0..at])) return .{ .scheme = url[0..at] };
    return .{ .path = url };
}

/// Orders by case-folded name, then path, as launchers sort.
pub fn sortApps(items: []InstalledApp) void {
    std.sort.pdq(InstalledApp, items, {}, struct {
        fn less(_: void, a: InstalledApp, b: InstalledApp) bool {
            return switch (std.ascii.orderIgnoreCase(a.name, b.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a.path, b.path) == .lt,
            };
        }
    }.less);
}

/// Standalone blocking system work on a caller-created worker. It never owns a
/// Window/App, starts a thread, posts a task or invokes an application callback.
/// Keep one owner; do not copy it after init. Call deinit on the same worker.
pub const Worker = struct {
    thread: std.Thread.Id,
    closed: bool = false,
    last_failure: ?NativeFailure = null,
    apartment: bool = false,

    pub fn init(main_thread: std.Thread.Id) !Worker {
        const thread = std.Thread.getCurrentId();
        if (thread == main_thread) return error.UiThreadForbidden;
        if (!capabilities.launch_executable) return error.UnsupportedCapability;
        return .{ .thread = thread };
    }
    pub fn deinit(self: *Worker) void {
        std.debug.assert(self.thread == std.Thread.getCurrentId());
        if (self.closed) return;
        if (builtin.os.tag == .windows and self.apartment) win.CoUninitialize();
        self.apartment = false;
        self.closed = true;
    }
    fn require(self: *Worker) !void {
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.closed) return error.Closed;
        self.last_failure = null;
    }
    fn ensureApartment(self: *Worker) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (self.apartment) return;
        const result = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED);
        if (result < 0) {
            self.last_failure = .{ .domain = .hresult, .code = @bitCast(result) };
            return error.ComInitializationFailed;
        }
        self.apartment = true;
    }
    /// Blocking read-only icon lookup on this worker. All HICON/HBITMAP/DC
    /// resources are released before return. Pixels publish only on success.
    pub fn fileIcon(self: *Worker, path: []const u8, options: IconOptions, destination: []u8) !FileIcon {
        try self.require();
        if (!capabilities.file_icon) return error.UnsupportedCapability;
        if (options.cancellation) |cancel| try cancel.check();
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        const bytes = try iconBytes(options, destination);
        if (posix_shell) {
            var storage: [max_argument_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, path);
            try requireExisting(target);
            if (options.cancellation) |cancel| try cancel.check();
            var failure: NativeShellFailure = .{};
            const status: GioStatus = @fromBackingInt(@intCast(gio.zsh_file_icon(target.ptr, options.size, options.background, destination.ptr, &failure)));
            return self.iconResult(status, failure, options, destination[0..bytes]);
        }
        var storage: [max_argument_bytes + 1]u16 = undefined;
        return self.shellIcon(try wideZ(&storage, path), 0, options, destination[0..bytes]);
    }
    /// Blocking read-only lookup of the icon the file manager shows for files
    /// with `extension` ("pdf" or ".pdf"), though no such file needs to
    /// exist: the icon of an attachment not yet downloaded. Windows asks the
    /// shell for the extension's icon (`SHGFI_USEFILEATTRIBUTES`), Linux the
    /// icon theme for that of the content type GIO guesses from such a name,
    /// macOS NSWorkspace for that of its UTType. Pixels and options as
    /// `fileIcon`'s.
    pub fn typeIcon(self: *Worker, extension: []const u8, options: IconOptions, destination: []u8) !FileIcon {
        try self.require();
        if (!capabilities.type_icon) return error.UnsupportedCapability;
        if (options.cancellation) |cancel| try cancel.check();
        const name = if (std.mem.startsWith(u8, extension, ".")) extension[1..] else extension;
        try validateExtension(name);
        const bytes = try iconBytes(options, destination);
        if (posix_shell) {
            var storage: [max_extension_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, name);
            const status: GioStatus = @fromBackingInt(@intCast(gio.zsh_type_icon(target.ptr, options.size, options.background, destination.ptr)));
            return self.iconResult(status, .{}, options, destination[0..bytes]);
        }
        var storage: [max_extension_bytes + 2]u16 = undefined;
        storage[0] = '.';
        const wide = try wideZ(storage[1..], name);
        return self.shellIcon(storage[0 .. wide.len + 1 :0], win.FILE_ATTRIBUTE_NORMAL, options, destination[0..bytes]);
    }
    fn iconBytes(options: IconOptions, destination: []const u8) !usize {
        const sizes = if (builtin.os.tag == .windows) options.size == 16 or options.size == 32 else options.size >= 1 and options.size <= max_icon_size;
        if (!sizes or options.background > 0xffffff) return error.InvalidIconOptions;
        const bytes = @as(usize, options.size) * options.size * 4;
        if (destination.len < bytes) return error.ResultCapacityExceeded;
        return bytes;
    }
    fn iconResult(self: *Worker, status: GioStatus, failure: NativeShellFailure, options: IconOptions, pixels: []u8) !FileIcon {
        if (status != .ok) {
            if (failure.domain != 0) self.recordGio(failure);
            return switch (status) {
                .access_denied => error.AccessDenied,
                .not_found => error.FileNotFound,
                else => error.IconLookupFailed,
            };
        }
        if (options.cancellation) |cancel| try cancel.check();
        return .{ .width = options.size, .height = options.size, .stride = @as(usize, options.size) * 4, .pixels = pixels };
    }
    /// Windows: the shell's small or large icon of `target`, a path, or with
    /// `attributes` an extension that no file needs to have.
    fn shellIcon(self: *Worker, target: [:0]const u16, attributes: u32, options: IconOptions, destination: []u8) !FileIcon {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        const bytes = destination.len;
        try self.ensureApartment();
        var info = std.mem.zeroes(win.SHFILEINFOW);
        var flags: win.UINT = @as(win.UINT, @intCast(win.SHGFI_ICON)) | @as(win.UINT, @intCast(if (options.size == 16) win.SHGFI_SMALLICON else win.SHGFI_LARGEICON));
        if (attributes != 0) flags |= @as(win.UINT, @intCast(win.SHGFI_USEFILEATTRIBUTES));
        if (win.SHGetFileInfoW(target.ptr, attributes, &info, @sizeOf(win.SHFILEINFOW), flags) == 0) {
            return error.IconLookupFailed;
        }
        defer _ = win.DestroyIcon(info.hIcon);
        if (options.cancellation) |cancel| try cancel.check();
        const dc = win.CreateCompatibleDC(null) orelse return error.IconRasterFailed;
        defer _ = win.DeleteDC(dc);
        var bitmap = std.mem.zeroes(win.BITMAPINFO);
        bitmap.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
        bitmap.bmiHeader.biWidth = options.size;
        bitmap.bmiHeader.biHeight = -@as(win.LONG, options.size);
        bitmap.bmiHeader.biPlanes = 1;
        bitmap.bmiHeader.biBitCount = 32;
        bitmap.bmiHeader.biCompression = win.BI_RGB;
        var bits: ?*anyopaque = null;
        const image = win.CreateDIBSection(dc, &bitmap, win.DIB_RGB_COLORS, &bits, null, 0) orelse return error.IconRasterFailed;
        defer _ = win.DeleteObject(image);
        const previous = win.SelectObject(dc, image) orelse return error.IconRasterFailed;
        defer _ = win.SelectObject(dc, previous);
        const pixels: [*]u32 = @ptrCast(@alignCast(bits.?));
        @memset(pixels[0 .. bytes / 4], options.background);
        if (win.DrawIconEx(dc, 0, 0, info.hIcon, options.size, options.size, 0, null, win.DI_NORMAL) == 0) return error.IconRasterFailed;
        // Flush this thread's GDI batch before reading its DIB memory.
        if (win.GdiFlush() == 0) return error.IconRasterFailed;
        if (options.cancellation) |cancel| try cancel.check();
        for (pixels[0 .. bytes / 4], 0..) |pixel, index| {
            destination[index * 4] = @truncate(pixel >> 16);
            destination[index * 4 + 1] = @truncate(pixel >> 8);
            destination[index * 4 + 2] = @truncate(pixel);
            destination[index * 4 + 3] = 255;
        }
        return .{ .width = options.size, .height = options.size, .stride = @as(usize, options.size) * 4, .pixels = destination[0..bytes] };
    }
    /// Blocking hand-off of an absolute URI to its default handler. Success
    /// means the system accepted the request; the handler process is not owned,
    /// returned or awaited. Only https/http/mailto plus UrlOptions.extra_schemes
    /// pass; see validateUrl for the accepted syntax.
    pub fn openUrl(self: *Worker, url: []const u8, options: UrlOptions) !void {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateUrl(url, options.extra_schemes);
        if (builtin.os.tag == .windows) {
            var storage: [max_url_bytes + 1]u16 = undefined;
            const target = try wideZ(&storage, url);
            try self.ensureApartment();
            if (options.cancellation) |cancel| try cancel.check();
            return self.shellExecute(target.ptr);
        } else if (posix_shell) {
            var storage: [max_url_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, url);
            if (options.cancellation) |cancel| try cancel.check();
            var failure: NativeShellFailure = .{};
            return self.openStatus(@fromBackingInt(@intCast(gio.zsh_open_uri(target.ptr, &failure))), failure);
        } else return error.UnsupportedCapability;
    }
    /// Opens an existing absolute file or directory with its association. An
    /// executable, script or shortcut is launched by whatever its association
    /// does, without arguments; the host decides which paths it passes here.
    pub fn openPath(self: *Worker, path: []const u8, options: PathOptions) !void {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        if (builtin.os.tag == .windows) {
            var storage: [max_argument_bytes + 2]u16 = undefined;
            const target = try widePath(&storage, path);
            try requireExisting(target);
            try self.ensureApartment();
            if (options.cancellation) |cancel| try cancel.check();
            return self.shellExecute(target.ptr);
        } else if (posix_shell) {
            var storage: [max_argument_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, path);
            try requireExisting(target);
            if (options.cancellation) |cancel| try cancel.check();
            var failure: NativeShellFailure = .{};
            return self.openStatus(@fromBackingInt(@intCast(gio.zsh_open_path(target.ptr, &failure))), failure);
        } else return error.UnsupportedCapability;
    }
    /// Shows an existing absolute item selected in the system file manager.
    /// Linux asks org.freedesktop.FileManager1.ShowItems on the session bus and
    /// returns FileManagerUnavailable when no bus or provider answers; there is
    /// no fallback to opening the parent directory. macOS asks Finder, which
    /// does not reply, so RevealOptions.timeout_ms is not used there.
    pub fn reveal(self: *Worker, path: []const u8, options: RevealOptions) !void {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        if (options.timeout_ms == 0 or options.timeout_ms > max_reveal_timeout_ms) return error.InvalidTimeout;
        if (builtin.os.tag == .windows) {
            var storage: [max_argument_bytes + 2]u16 = undefined;
            const target = try widePath(&storage, path);
            try requireExisting(target);
            try self.ensureApartment();
            if (options.cancellation) |cancel| try cancel.check();
            var item: win.PIDLIST_ABSOLUTE = null;
            const parsed = win.SHParseDisplayName(target.ptr, null, &item, 0, null);
            if (parsed < 0) {
                self.last_failure = .{ .domain = .hresult, .code = @bitCast(parsed) };
                return error.RevealFailed;
            }
            defer win.ILFree(item);
            const shown = win.SHOpenFolderAndSelectItems(item, 0, null, 0);
            if (shown < 0) {
                self.last_failure = .{ .domain = .hresult, .code = @bitCast(shown) };
                return error.RevealFailed;
            }
        } else if (posix_shell) {
            var storage: [max_argument_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, path);
            try requireExisting(target);
            if (options.cancellation) |cancel| try cancel.check();
            var failure: NativeShellFailure = .{};
            const status: GioStatus = @fromBackingInt(@intCast(gio.zsh_reveal(target.ptr, @intCast(options.timeout_ms), &failure)));
            if (status == .ok) return;
            self.recordGio(failure);
            return switch (status) {
                .unavailable => error.FileManagerUnavailable,
                .timed_out => error.RevealTimedOut,
                .not_found => error.FileNotFound,
                else => error.RevealFailed,
            };
        } else return error.UnsupportedCapability;
    }
    /// Moves one existing absolute item to the user's trash/recycle bin and
    /// never falls back to permanent deletion itself. Filesystem roots and, on
    /// Windows, wildcard characters are rejected. Windows accepts only local
    /// fixed drives; the system recycle-bin policy (disabled bin, size limit)
    /// still decides what the Shell does with an accepted request.
    pub fn trash(self: *Worker, path: []const u8, options: PathOptions) !void {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateText(path);
        if (!absolute(path)) return error.AbsolutePathRequired;
        if (root(path)) return error.InvalidTrashPath;
        if (builtin.os.tag == .windows) {
            if (std.mem.indexOfAny(u8, path, "*?") != null) return error.InvalidTrashPath;
            // Double-NUL list: widePath leaves one spare unit after the NUL.
            var storage: [max_argument_bytes + 2]u16 = undefined;
            const target = try widePath(&storage, path);
            storage[target.len + 1] = 0;
            try requireExisting(target);
            if (target.len < 3 or target[1] != ':') return error.TrashUnsupported;
            const drive = [_:0]u16{ target[0], ':', '\\' };
            if (win.GetDriveTypeW(&drive) != win.DRIVE_FIXED) return error.TrashUnsupported;
            try self.ensureApartment();
            if (options.cancellation) |cancel| try cancel.check();
            var operation = std.mem.zeroes(win.SHFILEOPSTRUCTW);
            operation.wFunc = win.FO_DELETE;
            operation.pFrom = target.ptr;
            operation.fFlags = @intCast(win.FOF_ALLOWUNDO | win.FOF_NOCONFIRMATION | win.FOF_NOERRORUI | win.FOF_SILENT);
            const result = win.SHFileOperationW(&operation);
            if (result != 0) {
                self.last_failure = .{ .domain = .shell_file_operation, .code = @bitCast(result) };
                return error.TrashFailed;
            }
            if (operation.fAnyOperationsAborted != 0) return error.TrashAborted;
        } else if (posix_shell) {
            var storage: [max_argument_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, path);
            if (options.cancellation) |cancel| try cancel.check();
            var failure: NativeShellFailure = .{};
            const status: GioStatus = @fromBackingInt(@intCast(gio.zsh_trash(target.ptr, &failure)));
            if (status == .ok) return;
            self.recordGio(failure);
            return switch (status) {
                .not_supported => error.TrashUnsupported,
                .not_found => error.FileNotFound,
                .access_denied => error.AccessDenied,
                else => error.TrashFailed,
            };
        } else return error.UnsupportedCapability;
    }
    /// Lists installed applications, sorted by name: the Start menu's All
    /// apps (packaged and desktop apps alike) on Windows, the desktop
    /// entries menus show on Linux, and on macOS the .app bundles in
    /// /Applications, /System/Applications, ~/Applications and CoreServices'
    /// Applications (and one folder level below them) plus Finder. Reads the
    /// disk; owned by the caller.
    pub fn installedApps(self: *Worker, allocator: std.mem.Allocator) !InstalledApps {
        try self.require();
        var result: InstalledApps = .{ .arena = .init(allocator), .items = &.{} };
        errdefer result.arena.deinit();
        var list: std.ArrayList(InstalledApp) = .empty;
        const arena = result.arena.allocator();
        if (builtin.os.tag == .windows) {
            try self.ensureApartment();
            try appsFolder(self, arena, &list);
        } else if (posix_shell) {
            var collector: AppCollector = .{ .allocator = arena, .list = &list };
            if (gio.zsh_apps(AppCollector.visit, &collector) != 0) return collector.failure orelse error.OutOfMemory;
        } else return error.UnsupportedCapability;
        result.items = list.items;
        sortApps(result.items);
        return result;
    }
    /// Starts an application from `installedApps` by its path, or brings it
    /// to the front if it runs and the system does so. Windows also accepts
    /// any program path.
    pub fn launchApp(self: *Worker, path: []const u8) !void {
        try self.require();
        try validateText(path);
        if (path.len == 0) return error.FileNotFound;
        if (builtin.os.tag == .windows) {
            var storage: [max_argument_bytes + 1]u16 = undefined;
            const target = try wideZ(&storage, path);
            try self.ensureApartment();
            return self.shellExecute(target.ptr);
        } else if (posix_shell) {
            if (!absolute(path)) return error.AbsolutePathRequired;
            var storage: [max_argument_bytes + 1]u8 = undefined;
            const target = narrowZ(&storage, path);
            var failure: NativeShellFailure = .{};
            const status: GioStatus = @fromBackingInt(@intCast(gio.zsh_launch_app(target.ptr, &failure)));
            if (status == .ok) return;
            self.recordGio(failure);
            return switch (status) {
                .not_found => error.FileNotFound,
                .access_denied => error.AccessDenied,
                else => error.OpenFailed,
            };
        } else return error.UnsupportedCapability;
    }
    /// The application the system opens `url` with, the default handler for
    /// it: the browser for a web URL, the editor for a text file, the file
    /// manager for a folder. `url` is a web URL such as https://example.com,
    /// any URL whose scheme the system knows a handler for, a file URL, or a
    /// path (see `defaultTarget`). The app has the name, id and path that
    /// `installedApps` gives: Launch Services' choice on macOS; on Linux the
    /// default desktop entry for the scheme, or for the type GIO finds the
    /// file to be (a folder, a file by its first bytes, or where there is no
    /// such file, by its whole name); on Windows the association of the
    /// scheme or the file's extension, a packaged app as its
    /// `shell:AppsFolder` item and a desktop app as its Start menu item, or
    /// by its executable where it has none. `NoAssociation` when nothing
    /// opens it. Reads system associations: call it on this worker, off the
    /// main thread. Owned by the caller.
    pub fn defaultApp(self: *Worker, allocator: std.mem.Allocator, url: []const u8) !DefaultApp {
        try self.require();
        if (url.len > max_url_bytes) return error.ArgumentTooLong;
        try validateText(url);
        var decoded: [max_url_bytes]u8 = undefined;
        const target = try defaultTarget(&decoded, url);
        var result: DefaultApp = .{ .arena = .init(allocator), .app = undefined };
        errdefer result.arena.deinit();
        const arena = result.arena.allocator();
        if (builtin.os.tag == .windows) {
            try self.ensureApartment();
            result.app = try windowsDefaultApp(self, arena, target);
        } else if (posix_shell) {
            var url_storage: [max_url_bytes + 1]u8 = undefined;
            var target_storage: [max_url_bytes + 1]u8 = undefined;
            const url_z = narrowZ(&url_storage, url);
            var list: std.ArrayList(InstalledApp) = .empty;
            var collector: AppCollector = .{ .allocator = arena, .list = &list };
            var failure: NativeShellFailure = .{};
            const status: GioStatus = @fromBackingInt(@intCast(switch (target) {
                .scheme => |scheme| gio.zsh_default_app(url_z.ptr, narrowZ(&target_storage, scheme).ptr, null, AppCollector.visit, &collector, &failure),
                // macOS asks Launch Services about a file URL as it is.
                .path => |path| gio.zsh_default_app(if (builtin.os.tag == .macos and path.ptr != url.ptr) url_z.ptr else null, null, narrowZ(&target_storage, path).ptr, AppCollector.visit, &collector, &failure),
            }));
            if (collector.failure) |err| return err;
            switch (status) {
                .ok => {},
                .not_supported, .not_found => {
                    self.recordGio(failure);
                    return error.NoAssociation;
                },
                .invalid => return error.InvalidUrl,
                else => {
                    self.recordGio(failure);
                    return error.OpenFailed;
                },
            }
            if (list.items.len != 1) return error.NoAssociation;
            result.app = list.items[0];
        } else return error.UnsupportedCapability;
        return result;
    }
    fn shellExecute(self: *Worker, target: [*:0]const u16) !void {
        var info = std.mem.zeroes(win.SHELLEXECUTEINFOW);
        info.cbSize = @sizeOf(win.SHELLEXECUTEINFOW);
        // Synchronous hand-off on this worker; no Shell error dialog and no
        // process handle requested or retained.
        info.fMask = @intCast(win.SEE_MASK_NOASYNC | win.SEE_MASK_FLAG_NO_UI);
        info.lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("open");
        info.lpFile = target;
        info.nShow = win.SW_SHOWNORMAL;
        if (win.ShellExecuteExW(&info) != 0) return;
        const code = win.GetLastError();
        self.last_failure = .{ .domain = .win32, .code = code };
        return switch (code) {
            win.ERROR_NO_ASSOCIATION => error.NoAssociation,
            win.ERROR_FILE_NOT_FOUND, win.ERROR_PATH_NOT_FOUND => error.FileNotFound,
            win.ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.OpenFailed,
        };
    }
    fn openStatus(self: *Worker, status: GioStatus, failure: NativeShellFailure) !void {
        if (status == .ok) return;
        self.recordGio(failure);
        return switch (status) {
            .not_supported => error.NoAssociation,
            .not_found => error.FileNotFound,
            .access_denied => error.AccessDenied,
            else => error.OpenFailed,
        };
    }
    fn recordGio(self: *Worker, failure: NativeShellFailure) void {
        self.last_failure = switch (failure.domain) {
            1 => .{ .domain = .gio, .code = failure.code },
            2 => .{ .domain = .dbus, .code = failure.code },
            3 => .{ .domain = .glib, .code = failure.code },
            4 => .{ .domain = .cocoa, .code = failure.code },
            5 => .{ .domain = .osstatus, .code = failure.code },
            else => null,
        };
    }
    /// Returns an owned child. The caller must wait or terminateAndWait on this
    /// worker, even if posting its result to the UI fails or the App has closed.
    /// Arguments/cwd are borrowed only until return. No child stream is piped.
    pub fn launchExecutable(self: *Worker, _: std.mem.Allocator, options: LaunchOptions) !Child {
        try self.require();
        if (options.cancellation) |cancel| try cancel.check();
        try validateLaunch(options);
        if (builtin.os.tag == .windows) {
            var executable: [max_argument_bytes + 1]u16 = undefined;
            const exe = try wideZ(&executable, options.executable);
            var cwd: [max_argument_bytes + 1]u16 = undefined;
            const directory = if (options.cwd) |path| (try wideZ(&cwd, path)).ptr else null;
            var command: [max_command_units + 1]u16 = undefined;
            const line = try commandLine(&command, options);
            if (options.cancellation) |cancel| try cancel.check();
            var startup = std.mem.zeroes(win.STARTUPINFOW);
            startup.cb = @sizeOf(win.STARTUPINFOW);
            var info: win.PROCESS_INFORMATION = undefined;
            if (win.CreateProcessW(exe.ptr, line.ptr, null, null, 0, win.CREATE_NO_WINDOW, null, directory, &startup, &info) == 0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessLaunchFailed;
            }
            _ = win.CloseHandle(info.hThread);
            return .{ .thread = self.thread, .native = info.hProcess };
        } else if (posix_shell) {
            var argv: [max_arguments + 1][]const u8 = undefined;
            argv[0] = options.executable;
            @memcpy(argv[1..][0..options.arguments.len], options.arguments);
            if (options.cancellation) |cancel| try cancel.check();
            const child = try zio.spawn(.{ .argv = argv[0 .. options.arguments.len + 1], .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .cwd = zio.cwd(options.cwd) });
            return .{ .thread = self.thread, .native = child };
        } else return error.UnsupportedCapability;
    }
};

/// One owned process, bound to its creating worker. Do not copy it. wait and
/// terminateAndWait close/reap exactly once; later calls return the saved term.
pub const Child = struct {
    thread: std.Thread.Id,
    native: if (builtin.os.tag == .windows) win.HANDLE else if (posix_shell) std.process.Child else void,
    term: ?Term = null,
    last_failure: ?NativeFailure = null,
    fn require(self: *Child) !void {
        if (self.thread != std.Thread.getCurrentId()) return error.WrongThread;
    }
    pub fn wait(self: *Child) !Term {
        try self.require();
        if (self.term) |term| return term;
        if (builtin.os.tag == .windows) {
            if (win.WaitForSingleObject(self.native, win.INFINITE) != win.WAIT_OBJECT_0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessWaitFailed;
            }
            var code: win.DWORD = 0;
            if (win.GetExitCodeProcess(self.native, &code) == 0) {
                self.last_failure = .{ .domain = .win32, .code = win.GetLastError() };
                return error.ProcessWaitFailed;
            }
            _ = win.CloseHandle(self.native);
            self.native = null;
            self.term = .{ .Exited = code };
        } else if (posix_shell) self.term = switch (try self.native.wait(zio.io())) {
            .exited => |code| .{ .Exited = code },
            .signal => |signal| .{ .Signal = @backingInt(signal) },
            .stopped => |signal| .{ .Stopped = @backingInt(signal) },
            .unknown => |value| .{ .Unknown = value },
        } else return error.UnsupportedCapability;
        return self.term.?;
    }
    pub fn terminateAndWait(self: *Child) !Term {
        try self.require();
        if (self.term) |term| return term;
        if (builtin.os.tag == .windows) {
            if (win.TerminateProcess(self.native, 1) == 0) {
                const code = win.GetLastError();
                if (win.WaitForSingleObject(self.native, 0) != win.WAIT_OBJECT_0) {
                    self.last_failure = .{ .domain = .win32, .code = code };
                    return error.ProcessTerminationFailed;
                }
            }
        } else if (posix_shell) {
            std.posix.kill(self.native.id.?, .KILL) catch |err| switch (err) {
                error.ProcessNotFound => {},
                else => return err,
            };
        } else return error.UnsupportedCapability;
        return self.wait();
    }
};

const AppCollector = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(InstalledApp),
    failure: ?anyerror = null,
    fn visit(ptr: ?*anyopaque, name: [*:0]const u8, id: [*:0]const u8, path: [*:0]const u8) callconv(.c) c_int {
        const self: *AppCollector = @ptrCast(@alignCast(ptr.?));
        self.add(std.mem.span(name), std.mem.span(id), std.mem.span(path)) catch |err| {
            self.failure = err;
            return 1;
        };
        return 0;
    }
    fn add(self: *AppCollector, name: []const u8, id: []const u8, path: []const u8) !void {
        try self.list.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .id = try self.allocator.dupe(u8, id), .path = try self.allocator.dupe(u8, path) });
    }
};

const Guid = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };
const ShellItem = extern struct {
    vtable: *const extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*ShellItem) callconv(.winapi) u32,
        bind_to_handler: *const fn (*ShellItem, ?*anyopaque, *const Guid, *const Guid, *?*anyopaque) callconv(.winapi) i32,
        get_parent: *const anyopaque,
        get_display_name: *const fn (*ShellItem, u32, *?[*:0]u16) callconv(.winapi) i32,
    },
};
const EnumShellItems = extern struct {
    vtable: *const extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const fn (*EnumShellItems) callconv(.winapi) u32,
        next: *const fn (*EnumShellItems, u32, *?*ShellItem, *u32) callconv(.winapi) i32,
    },
};
const folder_apps: Guid = .{ .data1 = 0x1e87508d, .data2 = 0x89c2, .data3 = 0x42f0, .data4 = .{ 0x8a, 0x7e, 0x64, 0x5a, 0x0f, 0x50, 0xca, 0x58 } };
const handler_enum_items: Guid = .{ .data1 = 0x94f60519, .data2 = 0x2850, .data3 = 0x4924, .data4 = .{ 0xaa, 0x5a, 0xd1, 0x5e, 0x84, 0x86, 0x80, 0x39 } };
const iid_shell_item: Guid = .{ .data1 = 0x43826d1e, .data2 = 0xe718, .data3 = 0x42ee, .data4 = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };
const iid_enum_shell_items: Guid = .{ .data1 = 0x70629033, .data2 = 0xe363, .data3 = 0x4a28, .data4 = .{ 0xa5, 0x67, 0x0d, 0xb7, 0x80, 0x06, 0xe6, 0xd7 } };
const shell_apps = if (builtin.os.tag == .windows) struct {
    extern "shell32" fn SHGetKnownFolderItem(*const Guid, u32, ?*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) i32;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
} else struct {};
const apps_folder_prefix = "shell:AppsFolder\\";

/// The shell's Applications folder (FOLDERID_AppsFolder), which the Start
/// menu's All apps list shows.
fn appsFolder(worker: *Worker, allocator: std.mem.Allocator, list: *std.ArrayList(InstalledApp)) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    var folder_object: ?*anyopaque = null;
    var result = shell_apps.SHGetKnownFolderItem(&folder_apps, 0, null, &iid_shell_item, &folder_object);
    if (result < 0 or folder_object == null) {
        worker.last_failure = .{ .domain = .hresult, .code = @bitCast(result) };
        return error.ApplicationsUnavailable;
    }
    const folder: *ShellItem = @ptrCast(@alignCast(folder_object.?));
    defer _ = folder.vtable.release(folder);
    var enum_object: ?*anyopaque = null;
    result = folder.vtable.bind_to_handler(folder, null, &handler_enum_items, &iid_enum_shell_items, &enum_object);
    if (result < 0 or enum_object == null) {
        worker.last_failure = .{ .domain = .hresult, .code = @bitCast(result) };
        return error.ApplicationsUnavailable;
    }
    const items: *EnumShellItems = @ptrCast(@alignCast(enum_object.?));
    defer _ = items.vtable.release(items);
    const normal_display = 0;
    const parent_relative_parsing = 0x80018001;
    while (true) {
        var item: ?*ShellItem = null;
        var fetched: u32 = 0;
        // S_FALSE (1) ends the enumeration.
        if (items.vtable.next(items, 1, &item, &fetched) != 0 or fetched == 0) break;
        const shell_item = item orelse break;
        defer _ = shell_item.vtable.release(shell_item);
        var name_wide: ?[*:0]u16 = null;
        var id_wide: ?[*:0]u16 = null;
        _ = shell_item.vtable.get_display_name(shell_item, normal_display, &name_wide);
        defer shell_apps.CoTaskMemFree(name_wide);
        _ = shell_item.vtable.get_display_name(shell_item, parent_relative_parsing, &id_wide);
        defer shell_apps.CoTaskMemFree(id_wide);
        const name_units = std.mem.span(name_wide orelse continue);
        const id_units = std.mem.span(id_wide orelse continue);
        if (name_units.len == 0 or id_units.len == 0) continue;
        const name = std.unicode.wtf16LeToWtf8Alloc(allocator, name_units) catch |err| return err;
        const id = try std.unicode.wtf16LeToWtf8Alloc(allocator, id_units);
        const path = try std.mem.concat(allocator, u8, &.{ apps_folder_prefix, id });
        try list.append(allocator, .{ .name = name, .id = id, .path = path });
    }
}

const iid_shell_item2: Guid = .{ .data1 = 0x7e9fb0d3, .data2 = 0x919f, .data3 = 0x4307, .data4 = .{ 0xab, 0x2e, 0x9b, 0x18, 0x60, 0x31, 0x0c, 0x93 } };
const iid_persist_file: Guid = .{ .data1 = 0x0000010b, .data2 = 0, .data3 = 0, .data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_shell_link: Guid = .{ .data1 = 0x000214f9, .data2 = 0, .data3 = 0, .data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const clsid_shell_link: Guid = .{ .data1 = 0x00021401, .data2 = 0, .data3 = 0, .data4 = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const PropertyKey = extern struct { format: Guid, id: u32 };
const link_target_parsing_path: PropertyKey = .{ .format = .{ .data1 = 0xb9b4b3fc, .data2 = 0x2b51, .data3 = 0x4a42, .data4 = .{ 0xb5, 0xd8, 0x32, 0x41, 0x46, 0xaf, 0xcf, 0x25 } }, .id = 2 };
/// A COM object called by the index of its vtable entry.
const ComObject = extern struct {
    vtable: [*]const *const anyopaque,
    fn method(self: *ComObject, comptime T: type, index: usize) T {
        return @ptrCast(self.vtable[index]);
    }
    fn release(self: *ComObject) void {
        _ = self.method(*const fn (*ComObject) callconv(.winapi) u32, 2)(self);
    }
    fn query(self: *ComObject, iid: *const Guid) ?*ComObject {
        var out: ?*anyopaque = null;
        if (self.method(*const fn (*ComObject, *const Guid, *?*anyopaque) callconv(.winapi) i32, 0)(self, iid, &out) < 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }
};
const assoc_str_executable = 2;
const assoc_str_friendly_app_name = 4;
const assoc_str_app_id = 21;
const shell_assoc = if (builtin.os.tag == .windows) struct {
    extern "shlwapi" fn AssocQueryStringW(flags: u32, string: u32, assoc: [*:0]const u16, extra: ?[*:0]const u16, out: ?[*]u16, length: *u32) callconv(.winapi) i32;
    extern "ole32" fn CoCreateInstance(class: *const Guid, outer: ?*anyopaque, context: u32, iid: *const Guid, out: *?*anyopaque) callconv(.winapi) i32;
} else struct {};

/// Whether `path` is the system's Open With dialog, which an association
/// without an application names.
pub fn isOpenWithExecutable(path: []const u8) bool {
    const start = if (std.mem.lastIndexOfAny(u8, path, "\\/")) |slash| slash + 1 else 0;
    return std.ascii.eqlIgnoreCase(path[start..], "OpenWith.exe");
}

/// The installed app whose executable is `executable`, compared without
/// case as Windows paths are, from `targets` (one per app).
pub fn appByExecutable(apps: []const InstalledApp, targets: []const []const u8, executable: []const u8) ?InstalledApp {
    for (apps, targets) |app, target| if (target.len != 0 and std.ascii.eqlIgnoreCase(target, executable)) return app;
    return null;
}

/// What a Windows association string names, `buffer`-backed UTF-8, or null.
fn assocQuery(arena: std.mem.Allocator, kind: u32, assoc: [:0]const u16) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var buffer: [4096]u16 = undefined;
    var length: u32 = buffer.len;
    if (shell_assoc.AssocQueryStringW(0, kind, assoc.ptr, null, &buffer, &length) != 0) return null;
    const units = std.mem.sliceTo(buffer[0..@min(length, buffer.len)], 0);
    if (units.len == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, units) catch null;
}

/// AssocQueryStringW for the scheme or the extension: a packaged app by its
/// AppUserModelID as the Applications folder lists it, else the
/// executable, matched to the Start menu item that runs it.
fn windowsDefaultApp(worker: *Worker, arena: std.mem.Allocator, target: DefaultTarget) !InstalledApp {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    const text = switch (target) {
        .scheme => |scheme| scheme,
        .path => |path| std.fs.path.extension(path),
    };
    if (text.len == 0 or std.mem.eql(u8, text, ".")) return error.InvalidUrl;
    var storage: [max_url_bytes + 1]u16 = undefined;
    const assoc = try wideZ(&storage, text);
    if (assocQuery(arena, assoc_str_app_id, assoc)) |id| {
        const name = assocQuery(arena, assoc_str_friendly_app_name, assoc) orelse id;
        return .{ .name = name, .id = id, .path = try std.mem.concat(arena, u8, &.{ apps_folder_prefix, id }) };
    }
    const executable = assocQuery(arena, assoc_str_executable, assoc) orelse return error.NoAssociation;
    if (isOpenWithExecutable(executable)) return error.NoAssociation;
    var list: std.ArrayList(InstalledApp) = .empty;
    var targets: std.ArrayList([]const u8) = .empty;
    if (appsFolderTargets(worker, arena, &list, &targets)) |_| {
        if (appByExecutable(list.items, targets.items, executable)) |app| return app;
    } else |_| {}
    const name = assocQuery(arena, assoc_str_friendly_app_name, assoc) orelse executable;
    return .{ .name = name, .id = executable, .path = executable };
}

/// The Applications folder's apps with the executable each runs: a
/// shortcut's target, else the item's own file path.
fn appsFolderTargets(worker: *Worker, arena: std.mem.Allocator, list: *std.ArrayList(InstalledApp), targets: *std.ArrayList([]const u8)) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    var folder_object: ?*anyopaque = null;
    var result = shell_apps.SHGetKnownFolderItem(&folder_apps, 0, null, &iid_shell_item, &folder_object);
    if (result < 0 or folder_object == null) {
        worker.last_failure = .{ .domain = .hresult, .code = @bitCast(result) };
        return error.ApplicationsUnavailable;
    }
    const folder: *ShellItem = @ptrCast(@alignCast(folder_object.?));
    defer _ = folder.vtable.release(folder);
    var enum_object: ?*anyopaque = null;
    result = folder.vtable.bind_to_handler(folder, null, &handler_enum_items, &iid_enum_shell_items, &enum_object);
    if (result < 0 or enum_object == null) return error.ApplicationsUnavailable;
    const items: *EnumShellItems = @ptrCast(@alignCast(enum_object.?));
    defer _ = items.vtable.release(items);
    while (true) {
        var item: ?*ShellItem = null;
        var fetched: u32 = 0;
        if (items.vtable.next(items, 1, &item, &fetched) != 0 or fetched == 0) break;
        const shell_item = item orelse break;
        defer _ = shell_item.vtable.release(shell_item);
        var name_wide: ?[*:0]u16 = null;
        var id_wide: ?[*:0]u16 = null;
        _ = shell_item.vtable.get_display_name(shell_item, 0, &name_wide);
        defer shell_apps.CoTaskMemFree(name_wide);
        _ = shell_item.vtable.get_display_name(shell_item, 0x80018001, &id_wide);
        defer shell_apps.CoTaskMemFree(id_wide);
        const name_units = std.mem.span(name_wide orelse continue);
        const id_units = std.mem.span(id_wide orelse continue);
        if (name_units.len == 0 or id_units.len == 0) continue;
        const id = try std.unicode.wtf16LeToWtf8Alloc(arena, id_units);
        try list.append(arena, .{ .name = try std.unicode.wtf16LeToWtf8Alloc(arena, name_units), .id = id, .path = try std.mem.concat(arena, u8, &.{ apps_folder_prefix, id }) });
        try targets.append(arena, itemExecutable(arena, @ptrCast(shell_item)) orelse "");
    }
}

fn itemExecutable(arena: std.mem.Allocator, item: *ComObject) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    if (item.query(&iid_shell_item2)) |item2| {
        defer item2.release();
        var value: ?[*:0]u16 = null;
        // IShellItem2::GetString
        if (item2.method(*const fn (*ComObject, *const PropertyKey, *?[*:0]u16) callconv(.winapi) i32, 17)(item2, &link_target_parsing_path, &value) >= 0) if (value) |units| {
            defer shell_apps.CoTaskMemFree(units);
            if (std.mem.span(units).len != 0) return std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(units)) catch null;
        };
    }
    var path_wide: ?[*:0]u16 = null;
    const file_system_path = 0x80058000;
    if (item.method(*const fn (*ComObject, u32, *?[*:0]u16) callconv(.winapi) i32, 5)(item, file_system_path, &path_wide) < 0) return null;
    const units = path_wide orelse return null;
    defer shell_apps.CoTaskMemFree(units);
    const path = std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(units)) catch return null;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".lnk")) return path;
    return shortcutTarget(arena, std.mem.span(units));
}

fn shortcutTarget(arena: std.mem.Allocator, path: [:0]const u16) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    var link_object: ?*anyopaque = null;
    if (shell_assoc.CoCreateInstance(&clsid_shell_link, null, 1, &iid_shell_link, &link_object) < 0) return null;
    const link: *ComObject = @ptrCast(@alignCast(link_object orelse return null));
    defer link.release();
    const persist = link.query(&iid_persist_file) orelse return null;
    defer persist.release();
    // IPersistFile::Load, read-only.
    if (persist.method(*const fn (*ComObject, [*:0]const u16, u32) callconv(.winapi) i32, 5)(persist, path.ptr, 0) < 0) return null;
    var target: [260]u16 = undefined;
    // IShellLinkW::GetPath
    if (link.method(*const fn (*ComObject, [*]u16, c_int, ?*anyopaque, u32) callconv(.winapi) i32, 3)(link, &target, target.len, null, 0) < 0) return null;
    const units = std.mem.sliceTo(&target, 0);
    if (units.len == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, units) catch null;
}

/// An extension without its dot: one name of 1 to `max_extension_bytes`
/// bytes, with no separator or control character.
fn validateExtension(value: []const u8) !void {
    if (value.len == 0) return error.InvalidExtension;
    if (value.len > max_extension_bytes) return error.ArgumentTooLong;
    for (value) |c| if (c < 0x20 or c == 0x7f or c == '/' or c == '\\' or c == ':') return error.InvalidExtension;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
}
fn validateText(value: []const u8) !void {
    if (value.len > max_argument_bytes) return error.ArgumentTooLong;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
}
fn absolute(path: []const u8) bool {
    if (builtin.os.tag != .windows) return path.len != 0 and path[0] == '/';
    const slash = struct {
        fn is(value: u8) bool {
            return value == '\\' or value == '/';
        }
    }.is;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and slash(path[2])) return true;
    // UNC paths require both server and share; device namespaces are not shell
    // executable paths. A single root slash remains drive-relative on Windows.
    if (path.len < 5 or !slash(path[0]) or !slash(path[1]) or path[2] == '?' or path[2] == '.') return false;
    var index: usize = 2;
    while (index < path.len and !slash(path[index])) : (index += 1) {}
    return index > 2 and index + 1 < path.len and !slash(path[index + 1]);
}
/// Absolute URI: scheme ":" rest. The scheme is RFC 3986 syntax with at least
/// two characters. http/https need a non-empty "//authority" host. Bytes below
/// 0x21, DEL and " < > \ ^ ` { | } are rejected; '%' needs two hex digits.
/// Non-ASCII UTF-8 (IRI text) is passed to the system unchanged.
pub fn validateUrl(url: []const u8, extra_schemes: []const []const u8) !void {
    if (url.len > max_url_bytes) return error.ArgumentTooLong;
    try validateText(url);
    if (extra_schemes.len > max_extra_schemes) return error.TooManySchemes;
    for (extra_schemes) |extra| {
        if (!schemeSyntax(extra)) return error.InvalidScheme;
    }
    for (url, 0..) |byte, index| {
        if (byte < 0x21 or byte == 0x7f or std.mem.indexOfScalar(u8, "\"<>\\^`{|}", byte) != null) return error.InvalidUrl;
        if (byte == '%' and (index + 2 >= url.len or !std.ascii.isHex(url[index + 1]) or !std.ascii.isHex(url[index + 2]))) return error.InvalidUrl;
    }
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidUrl;
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return error.SchemeNotAllowed;
    if (!schemeSyntax(scheme) or rest.len == 0) return error.InvalidUrl;
    var allowed = false;
    for (default_url_schemes) |name| allowed = allowed or std.ascii.eqlIgnoreCase(scheme, name);
    for (extra_schemes) |name| allowed = allowed or std.ascii.eqlIgnoreCase(scheme, name);
    if (!allowed) return error.SchemeNotAllowed;
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (!std.mem.startsWith(u8, rest, "//")) return error.InvalidUrl;
        const authority = rest[2..];
        const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
        const start = if (std.mem.lastIndexOfScalar(u8, authority[0..end], '@')) |at| at + 1 else 0;
        const host = authority[start..end];
        if (host.len == 0 or host[0] == ':') return error.InvalidUrl;
    }
}
fn schemeSyntax(scheme: []const u8) bool {
    if (scheme.len < 2 or scheme.len > 64 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    }
    return !std.ascii.eqlIgnoreCase(scheme, "file");
}
/// A filesystem root has nothing after its root separator(s).
fn root(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, if (builtin.os.tag == .windows) "\\/" else "/");
    if (builtin.os.tag != .windows) return trimmed.len == 0;
    if (trimmed.len == 2 and trimmed[1] == ':') return true;
    // \\server\share with no further component.
    if (trimmed.len > 2 and (trimmed[0] == '\\' or trimmed[0] == '/')) {
        var separators: usize = 0;
        for (trimmed[2..]) |byte| separators += @intFromBool(byte == '\\' or byte == '/');
        return separators < 2;
    }
    return false;
}
fn narrowZ(storage: []u8, text: []const u8) [:0]u8 {
    @memcpy(storage[0..text.len], text);
    storage[text.len] = 0;
    return storage[0..text.len :0];
}
/// UTF-16 path with '/' normalized to '\'. Keeps one spare unit after the NUL.
fn widePath(storage: []u16, path: []const u8) ![:0]u16 {
    const terminated = try wideZ(storage[0 .. storage.len - 1], path);
    for (terminated) |*value| {
        if (value.* == '/') value.* = '\\';
    }
    return terminated;
}
/// Existence check without following a final symbolic link.
fn requireExisting(path: anytype) !void {
    if (builtin.os.tag == .windows) {
        if (win.GetFileAttributesW(path.ptr) != win.INVALID_FILE_ATTRIBUTES) return;
        return switch (win.GetLastError()) {
            win.ERROR_ACCESS_DENIED => error.AccessDenied,
            else => error.FileNotFound,
        };
    }
    _ = std.Io.Dir.cwd().statFile(zio.io(), path, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        else => err,
    };
}
fn validateLaunch(options: LaunchOptions) !void {
    try validateText(options.executable);
    if (!absolute(options.executable)) return error.AbsolutePathRequired;
    if (builtin.os.tag == .windows and (!std.ascii.endsWithIgnoreCase(options.executable, ".exe") or std.mem.indexOfScalar(u8, options.executable, '"') != null)) return error.ExecutableRequired;
    if (options.arguments.len > max_arguments) return error.TooManyArguments;
    var bytes: usize = options.executable.len;
    for (options.arguments) |arg| {
        try validateText(arg);
        bytes += arg.len + 1;
        if (bytes > 64 * 1024) return error.CommandTooLong;
    }
    if (options.cwd) |cwd| {
        try validateText(cwd);
        if (!absolute(cwd)) return error.AbsolutePathRequired;
    }
}
fn wideZ(storage: []u16, text: []const u8) ![:0]u16 {
    const length = std.unicode.utf8ToUtf16Le(storage[0 .. storage.len - 1], text) catch return error.ArgumentTooLong;
    storage[length] = 0;
    return storage[0..length :0];
}
fn commandLine(storage: []u16, options: LaunchOptions) ![:0]u16 {
    var used: usize = 0;
    for (0..options.arguments.len + 1) |index| {
        if (index > 0) try unit(storage, &used, ' ');
        try appendQuoted(storage, &used, if (index == 0) options.executable else options.arguments[index - 1]);
    }
    storage[used] = 0;
    return storage[0..used :0];
}
/// Arguments alone, quoted so that CommandLineToArgvW splits them back.
pub fn argumentLine(storage: []u16, arguments: []const []const u8) ![:0]u16 {
    var used: usize = 0;
    for (arguments, 0..) |text, index| {
        try validateText(text);
        if (index > 0) try unit(storage, &used, ' ');
        try appendQuoted(storage, &used, text);
    }
    storage[used] = 0;
    return storage[0..used :0];
}
fn appendQuoted(storage: []u16, used: *usize, text: []const u8) !void {
    var argument: [max_argument_bytes]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&argument, text) catch return error.ArgumentTooLong;
    try unit(storage, used, '"');
    var at: usize = 0;
    while (at < length) {
        var slashes: usize = 0;
        while (at < length and argument[at] == '\\') : (at += 1) slashes += 1;
        const quote = at < length and argument[at] == '"';
        const count = if (at == length or quote) slashes * 2 else slashes;
        for (0..count) |_| try unit(storage, used, '\\');
        if (at == length) break;
        if (quote) try unit(storage, used, '\\');
        try unit(storage, used, argument[at]);
        at += 1;
    }
    try unit(storage, used, '"');
}
fn unit(storage: []u16, used: *usize, value: u16) !void {
    if (used.* >= @min(max_command_units - 1, storage.len - 1)) return error.CommandTooLong;
    storage[used.*] = value;
    used.* += 1;
}

test "shell arguments are bounded UTF-8 paths and Windows quoting round trips" {
    const path = if (builtin.os.tag == .windows) "C:\\tools\\app.exe" else "/usr/bin/app";
    try validateLaunch(.{ .executable = path, .arguments = &.{ "", "a b", "中文🦎", "quote\"end", "slash\\", "\\\"", "$(literal);&" } });
    try std.testing.expectError(error.AbsolutePathRequired, validateLaunch(.{ .executable = "app.exe" }));
    try std.testing.expectError(error.EmbeddedNul, validateLaunch(.{ .executable = path, .arguments = &.{"a\x00b"} }));
    try std.testing.expectError(error.InvalidUtf8, validateLaunch(.{ .executable = path, .arguments = &.{"\xff"} }));
    const options: LaunchOptions = .{ .executable = path, .arguments = &.{ "", "a b", "中文🦎", "quote\"end", "slash\\", "\\\"", "$(literal);&" } };
    var buffer: [2048]u16 = undefined;
    const line = try commandLine(&buffer, options);
    var args = try std.process.Args.Iterator.Windows.init(std.testing.allocator, line);
    defer args.deinit();
    try std.testing.expectEqualStrings(path, args.next().?);
    for (options.arguments) |arg| try std.testing.expectEqualStrings(arg, args.next().?);
    try std.testing.expect(args.next() == null);
    var cancellation: Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, cancellation.check());
    try std.testing.expectError(error.UiThreadForbidden, Worker.init(std.Thread.getCurrentId()));
}

test "shell URLs pass only absolute allowlisted schemes" {
    for ([_][]const u8{ "https://example.com/a?b=c#d", "HTTP://user@host:80/", "mailto:someone@example.com", "https://例子.测试/路径", "https://h/%41" }) |url| try validateUrl(url, &.{});
    try validateUrl("Ziggurat-Test+x.y:anything", &.{"ziggurat-test+x.y"});
    const rejected = [_]struct { []const u8, anyerror }{
        .{ "file:///etc/passwd", error.SchemeNotAllowed },
        .{ "FILE:///C:/x", error.SchemeNotAllowed },
        .{ "javascript:alert(1)", error.SchemeNotAllowed },
        .{ "ftp://example.com", error.SchemeNotAllowed },
        .{ "C:\\Windows", error.InvalidUrl },
        .{ "c:/x", error.InvalidUrl },
        .{ "relative/path", error.InvalidUrl },
        .{ "://host", error.InvalidUrl },
        .{ "1http://host", error.InvalidUrl },
        .{ "https:", error.InvalidUrl },
        .{ "https:host", error.InvalidUrl },
        .{ "https://", error.InvalidUrl },
        .{ "https://user@/x", error.InvalidUrl },
        .{ "https://exa mple.com", error.InvalidUrl },
        .{ "https://host/\"quote", error.InvalidUrl },
        .{ "https://host/%4", error.InvalidUrl },
        .{ "https://host/\n", error.InvalidUrl },
        .{ "https://host/\x00", error.EmbeddedNul },
        .{ "https://host/\xff", error.InvalidUtf8 },
        .{ "", error.InvalidUrl },
    };
    for (rejected) |case| try std.testing.expectError(case[1], validateUrl(case[0], &.{}));
    try std.testing.expectError(error.InvalidScheme, validateUrl("file:///x", &.{"file"}));
    try std.testing.expectError(error.InvalidScheme, validateUrl("https://h", &.{"c"}));
    const long = @as([max_url_bytes + 1]u8, @splat('a'));
    try std.testing.expectError(error.ArgumentTooLong, validateUrl(&long, &.{}));
    try std.testing.expect(root(if (builtin.os.tag == .windows) "C:\\" else "/"));
    try std.testing.expect(!root(if (builtin.os.tag == .windows) "C:\\x" else "/x"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(root("\\\\server\\share\\"));
        try std.testing.expect(!root("\\\\server\\share\\x"));
    }
}

test "defaultApp reads a scheme, a file URL or a path" {
    var storage: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https", (try defaultTarget(&storage, "https://example.com/")).scheme);
    try std.testing.expectEqualStrings("x-custom+app", (try defaultTarget(&storage, "x-custom+app:open")).scheme);
    try std.testing.expectEqualStrings("mailto", (try defaultTarget(&storage, "mailto:someone@example.com")).scheme);
    const decoded = (try defaultTarget(&storage, "file:///home/me/my%20notes/Makefile")).path;
    try std.testing.expectEqualStrings("/home/me/my notes/Makefile", decoded);
    try std.testing.expectEqualStrings("/srv/a.txt", (try defaultTarget(&storage, "file://localhost/srv/a.txt")).path);
    try std.testing.expectEqualStrings("/folder", (try defaultTarget(&storage, "file:/folder")).path);
    try std.testing.expectEqualStrings("/home/me/notes.txt", (try defaultTarget(&storage, "/home/me/notes.txt")).path);
    // A drive letter is not a scheme.
    try std.testing.expectEqualStrings("C:\\notes.txt", (try defaultTarget(&storage, "C:\\notes.txt")).path);
    try std.testing.expectError(error.InvalidUrl, defaultTarget(&storage, ""));
    try std.testing.expectError(error.InvalidUrl, defaultTarget(&storage, "file://server/share/a.txt"));
    try std.testing.expectError(error.InvalidUrl, defaultTarget(&storage, "file://"));
    try std.testing.expectError(error.InvalidUrl, defaultTarget(&storage, "file:///a%2"));
    try std.testing.expectError(error.EmbeddedNul, defaultTarget(&storage, "file:///a%00b"));
    if (builtin.os.tag == .windows) try std.testing.expectEqualStrings("C:/a.txt", (try defaultTarget(&storage, "file:///C:/a.txt")).path);
}

test "a Windows default handler maps to the Start menu item that runs it" {
    const apps = [_]InstalledApp{
        .{ .name = "Other", .id = "C:\\Start Menu\\Other.lnk", .path = "shell:AppsFolder\\Other" },
        .{ .name = "Editor", .id = "C:\\Start Menu\\Editor.lnk", .path = "shell:AppsFolder\\Editor" },
    };
    const targets = [_][]const u8{ "C:\\Apps\\Other.exe", "C:\\Apps\\Editor.exe" };
    try std.testing.expectEqualStrings("Editor", appByExecutable(&apps, &targets, "c:\\apps\\EDITOR.EXE").?.name);
    try std.testing.expect(appByExecutable(&apps, &targets, "C:\\Apps\\Missing.exe") == null);
    try std.testing.expect(appByExecutable(&apps, &.{ "", "" }, "") == null);
    try std.testing.expect(isOpenWithExecutable("C:\\Windows\\System32\\OpenWith.exe"));
    try std.testing.expect(isOpenWithExecutable("openwith.EXE"));
    try std.testing.expect(!isOpenWithExecutable("C:\\Apps\\Excel.exe"));
    try std.testing.expectEqual(21, assoc_str_app_id);
}
