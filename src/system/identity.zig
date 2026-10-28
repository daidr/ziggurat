const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern "glib-2.0" fn g_set_prgname(name: [*:0]const u8) callconv(.c) void;
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: [*:0]const u16) callconv(.winapi) i32;

pub const max_id_bytes = 64;
pub const capabilities = .{
    .process_identity = builtin.os.tag == .windows or builtin.os.tag == .linux,
    .directories = builtin.os.tag == .windows or builtin.os.tag == .linux,
};

/// Application identity shared by the single-instance lock, the desktop entry
/// (`<id>.desktop`), the Windows AppUserModelID and registered handlers.
/// Allowed bytes are ASCII letters, digits, '.', '_' and '-'; 1..64 bytes, no
/// leading/trailing dot and no empty dot-separated element.
pub fn validate(id: []const u8) !void {
    if (id.len == 0 or id.len > max_id_bytes) return error.InvalidIdentity;
    if (id[0] == '.' or id[id.len - 1] == '.' or std.mem.indexOf(u8, id, "..") != null) return error.InvalidIdentity;
    for (id) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return error.InvalidIdentity;
}

/// Sets the identity the desktop uses to group windows with the application.
/// Call on the process main thread before App.init and before any window
/// exists: Windows applies it as the explicit AppUserModelID; GTK derives the
/// X11 WM_CLASS and the Wayland app ID from the GLib program name at startup.
pub fn setProcessIdentity(id: []const u8) !void {
    try validate(id);
    var storage: [max_id_bytes + 1]u8 = undefined;
    @memcpy(storage[0..id.len], id);
    storage[id.len] = 0;
    switch (builtin.os.tag) {
        .windows => {
            var wide: [max_id_bytes + 1]u16 = undefined;
            for (id, 0..) |byte, index| wide[index] = byte;
            wide[id.len] = 0;
            if (SetCurrentProcessExplicitAppUserModelID(wide[0..id.len :0]) < 0) return error.IdentityRejected;
        },
        // GLib copies the name.
        .linux => g_set_prgname(storage[0..id.len :0]),
        else => return error.UnsupportedCapability,
    }
}

pub const Directory = enum {
    home,
    /// Per-user settings. Windows roaming AppData; Linux XDG_CONFIG_HOME.
    config,
    /// Per-user application data. Windows roaming AppData; Linux XDG_DATA_HOME.
    data,
    /// Disposable data. Windows local AppData; Linux XDG_CACHE_HOME.
    cache,
    /// Machine-local state such as logs and history. Windows local AppData;
    /// Linux XDG_STATE_HOME.
    state,
    temp,
    desktop,
    documents,
    downloads,
    pictures,
    music,
    videos,
};

/// Writes the absolute directory path (UTF-8 on Windows, native bytes on
/// Linux, no trailing separator) into caller storage. Nothing is created.
/// Linux reads the environment and, for user folders, `user-dirs.dirs`;
/// a folder that is not configured returns DirectoryUnavailable instead of a
/// guessed location, except the desktop which the specification defaults.
pub fn directory(kind: Directory, destination: []u8) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => windowsDirectory(kind, destination),
        .linux => linuxDirectory(LinuxEnvironment.current(), kind, destination),
        else => error.UnsupportedCapability,
    };
}
/// `directory(kind)` joined with the identity for config, data, cache and state.
pub fn applicationDirectory(kind: Directory, id: []const u8, destination: []u8) ![]u8 {
    try validate(id);
    switch (kind) {
        .config, .data, .cache, .state => {},
        else => return error.InvalidDirectory,
    }
    const base = try directory(kind, destination);
    const separator: u8 = if (builtin.os.tag == .windows) '\\' else '/';
    if (destination.len < base.len + 1 + id.len) return error.ResultCapacityExceeded;
    destination[base.len] = separator;
    @memcpy(destination[base.len + 1 ..][0..id.len], id);
    return destination[0 .. base.len + 1 + id.len];
}

/// Inputs for the Linux resolver. Values are used only when absolute, as the
/// base directory specification requires.
pub const LinuxEnvironment = struct {
    home: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
    state_home: ?[]const u8 = null,
    temp: ?[]const u8 = null,
    /// Contents of `$XDG_CONFIG_HOME/user-dirs.dirs`, when the caller already
    /// read it. Null reads the file from disk.
    user_dirs: ?[]const u8 = null,

    pub fn current() LinuxEnvironment {
        if (builtin.os.tag != .linux) return .{};
        const env = zio.getenv;
        return .{ .home = env("HOME"), .config_home = env("XDG_CONFIG_HOME"), .data_home = env("XDG_DATA_HOME"), .cache_home = env("XDG_CACHE_HOME"), .state_home = env("XDG_STATE_HOME"), .temp = env("TMPDIR") };
    }
};

fn absoluteValue(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0 or text[0] != '/' or std.mem.indexOfScalar(u8, text, 0) != null) return null;
    return trimSlash(text);
}
fn trimSlash(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 1 and text[end - 1] == '/') end -= 1;
    return text[0..end];
}
fn write(destination: []u8, parts: []const []const u8) ![]u8 {
    var used: usize = 0;
    for (parts) |part| {
        if (destination.len - used < part.len) return error.ResultCapacityExceeded;
        @memcpy(destination[used..][0..part.len], part);
        used += part.len;
    }
    return destination[0..used];
}

pub const LinuxDirectoryError = error{ DirectoryUnavailable, ResultCapacityExceeded, UserDirectoriesTooLarge } || std.Io.File.OpenError || std.Io.File.Reader.Error;
pub fn linuxDirectory(environment: LinuxEnvironment, kind: Directory, destination: []u8) LinuxDirectoryError![]u8 {
    const home = absoluteValue(environment.home);
    const base: struct { value: ?[]const u8, fallback: []const u8 } = switch (kind) {
        .home => return write(destination, &.{home orelse return error.DirectoryUnavailable}),
        .temp => return write(destination, &.{absoluteValue(environment.temp) orelse "/tmp"}),
        .config => .{ .value = environment.config_home, .fallback = "/.config" },
        .data => .{ .value = environment.data_home, .fallback = "/.local/share" },
        .cache => .{ .value = environment.cache_home, .fallback = "/.cache" },
        .state => .{ .value = environment.state_home, .fallback = "/.local/state" },
        else => return linuxUserDirectory(environment, kind, destination),
    };
    if (absoluteValue(base.value)) |value| return write(destination, &.{value});
    return write(destination, &.{ home orelse return error.DirectoryUnavailable, base.fallback });
}
fn linuxUserDirectory(environment: LinuxEnvironment, kind: Directory, destination: []u8) LinuxDirectoryError![]u8 {
    const key = switch (kind) {
        .desktop => "XDG_DESKTOP_DIR",
        .documents => "XDG_DOCUMENTS_DIR",
        .downloads => "XDG_DOWNLOAD_DIR",
        .pictures => "XDG_PICTURES_DIR",
        .music => "XDG_MUSIC_DIR",
        .videos => "XDG_VIDEOS_DIR",
        else => unreachable,
    };
    const home = absoluteValue(environment.home) orelse return error.DirectoryUnavailable;
    var storage: [16 * 1024]u8 = undefined;
    const contents = environment.user_dirs orelse read: {
        var config: [std.fs.max_path_bytes]u8 = undefined;
        const root = try linuxDirectory(environment, .config, &config);
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try write(&path, &.{ root, "/user-dirs.dirs" });
        const file = std.Io.Dir.openFileAbsolute(zio.io(), file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :read "",
            else => return err,
        };
        defer file.close(zio.io());
        const count = try zio.readAll(file, &storage);
        if (count == storage.len) return error.UserDirectoriesTooLarge;
        break :read storage[0..count];
    };
    if (try userDirectoryValue(contents, key, home, destination)) |value| return value;
    if (kind == .desktop) return write(destination, &.{ home, "/Desktop" });
    return error.DirectoryUnavailable;
}
/// Parses one `KEY="$HOME/..."` or `KEY="/abs"` line as written by
/// xdg-user-dirs. Other forms are ignored; later lines override earlier ones.
fn userDirectoryValue(contents: []const u8, key: []const u8, home: []const u8, destination: []u8) !?[]u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len < key.len + 3 or line[key.len] != '=') continue;
        const value = line[key.len + 1 ..];
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') continue;
        found = value[1 .. value.len - 1];
    }
    const value = found orelse return null;
    var used: usize = 0;
    var rest = value;
    if (std.mem.startsWith(u8, rest, "$HOME")) {
        if (rest.len != 5 and rest[5] != '/') return null;
        used = (try write(destination, &.{home})).len;
        rest = rest[5..];
    } else if (rest.len == 0 or rest[0] != '/') return null;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        var byte = rest[index];
        if (byte == '\\' and index + 1 < rest.len) {
            index += 1;
            byte = rest[index];
        }
        if (used == destination.len) return error.ResultCapacityExceeded;
        destination[used] = byte;
        used += 1;
    }
    const trimmed = trimSlash(destination[0..used]);
    // xdg-user-dirs disables a folder by pointing it at $HOME itself.
    if (std.mem.eql(u8, trimmed, home)) return null;
    return destination[0..trimmed.len];
}

const Guid = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };
fn guid(comptime data1: u32, comptime data2: u16, comptime data3: u16, comptime data4: [8]u8) Guid {
    return .{ .data1 = data1, .data2 = data2, .data3 = data3, .data4 = data4 };
}
extern "shell32" fn SHGetKnownFolderPath(id: *const Guid, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.winapi) i32;
fn windowsDirectory(kind: Directory, destination: []u8) ![]u8 {
    if (comptime builtin.os.tag != .windows) unreachable;
    if (kind == .temp) {
        var wide: [win.MAX_PATH + 2]u16 = undefined;
        const length = win.GetTempPathW(wide.len, &wide);
        if (length == 0 or length >= wide.len) return error.DirectoryUnavailable;
        var end: usize = length;
        while (end > 3 and wide[end - 1] == '\\') end -= 1;
        return utf16(wide[0..end], destination);
    }
    const id = switch (kind) {
        .home => guid(0x5E6C858F, 0x0E22, 0x4760, .{ 0x9A, 0xFE, 0xEA, 0x33, 0x17, 0xB6, 0x71, 0x73 }),
        .config, .data => guid(0x3EB685DB, 0x65F9, 0x4CF6, .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D }),
        .cache, .state => guid(0xF1B32785, 0x6FBA, 0x4FCF, .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 }),
        .desktop => guid(0xB4BFCC3A, 0xDB2C, 0x424C, .{ 0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41 }),
        .documents => guid(0xFDD39AD0, 0x238F, 0x46AF, .{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 }),
        .downloads => guid(0x374DE290, 0x123F, 0x4565, .{ 0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B }),
        .pictures => guid(0x33E28130, 0x4E1E, 0x4676, .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB }),
        .music => guid(0x4BD8D571, 0x6D19, 0x48D3, .{ 0xBE, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43 }),
        .videos => guid(0x18989B1D, 0x99B5, 0x455B, .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC }),
        .temp => unreachable,
    };
    var path: ?[*:0]u16 = null;
    // KF_FLAG_DONT_VERIFY: report the configured location without creating it.
    const result = SHGetKnownFolderPath(&id, 0x00004000, null, &path);
    defer if (path) |value| win.CoTaskMemFree(value);
    if (result < 0 or path == null) return error.DirectoryUnavailable;
    return utf16(std.mem.sliceTo(path.?, 0), destination);
}
fn utf16(units: []const u16, destination: []u8) ![]u8 {
    var used: usize = 0;
    var iterator = std.unicode.Utf16LeIterator.init(units);
    while (iterator.nextCodepoint() catch return error.InvalidPath) |codepoint| {
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &bytes) catch return error.InvalidPath;
        if (destination.len - used < length) return error.ResultCapacityExceeded;
        @memcpy(destination[used..][0..length], bytes[0..length]);
        used += length;
    }
    return destination[0..used];
}

test "identity rules match desktop entry and instance names" {
    try validate("org.example.App");
    try validate("tool_1-beta");
    for ([_][]const u8{ "", ".hidden", "trailing.", "a..b", "with space", "slash/name", "back\\slash", "中文", &@as([65]u8, @splat('x')) }) |id| {
        try std.testing.expectError(error.InvalidIdentity, validate(id));
    }
}

test "linux directories follow the base and user directory specifications" {
    var buffer: [256]u8 = undefined;
    const environment: LinuxEnvironment = .{ .home = "/home/me/", .config_home = "relative/ignored", .data_home = "/data/", .user_dirs =
        \\# comment
        \\XDG_DOCUMENTS_DIR="$HOME/Docs"
        \\XDG_DOWNLOAD_DIR="/mnt/down\"load"
        \\XDG_MUSIC_DIR="$HOME/"
        \\XDG_PICTURES_DIR=relative
        \\XDG_VIDEOS_DIR="$HOMEVideos"
        \\XDG_DOCUMENTS_DIR="$HOME/Documents"
    };
    try std.testing.expectEqualStrings("/home/me", try linuxDirectory(environment, .home, &buffer));
    try std.testing.expectEqualStrings("/home/me/.config", try linuxDirectory(environment, .config, &buffer));
    try std.testing.expectEqualStrings("/data", try linuxDirectory(environment, .data, &buffer));
    try std.testing.expectEqualStrings("/home/me/.cache", try linuxDirectory(environment, .cache, &buffer));
    try std.testing.expectEqualStrings("/home/me/.local/state", try linuxDirectory(environment, .state, &buffer));
    try std.testing.expectEqualStrings("/tmp", try linuxDirectory(environment, .temp, &buffer));
    try std.testing.expectEqualStrings("/home/me/Documents", try linuxDirectory(environment, .documents, &buffer));
    try std.testing.expectEqualStrings("/mnt/down\"load", try linuxDirectory(environment, .downloads, &buffer));
    try std.testing.expectEqualStrings("/home/me/Desktop", try linuxDirectory(environment, .desktop, &buffer));
    try std.testing.expectError(error.DirectoryUnavailable, linuxDirectory(environment, .music, &buffer));
    try std.testing.expectError(error.DirectoryUnavailable, linuxDirectory(environment, .pictures, &buffer));
    try std.testing.expectError(error.DirectoryUnavailable, linuxDirectory(environment, .videos, &buffer));
    try std.testing.expectError(error.DirectoryUnavailable, linuxDirectory(.{ .user_dirs = "" }, .config, &buffer));
    try std.testing.expectEqualStrings("/var/tmp", try linuxDirectory(.{ .temp = "/var/tmp/" }, .temp, &buffer));
    var small: [8]u8 = undefined;
    try std.testing.expectError(error.ResultCapacityExceeded, linuxDirectory(environment, .config, &small));
    try std.testing.expectError(error.ResultCapacityExceeded, linuxDirectory(environment, .documents, &small));
}
