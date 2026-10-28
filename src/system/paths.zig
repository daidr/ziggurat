//! Well-known directories of the user and the application. Resolution reads
//! the environment and, on Linux, `user-dirs.dirs`; it allocates the result
//! with the caller's allocator and touches no App or window state.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const Name = enum {
    home,
    /// Per-user application data: `$XDG_CONFIG_HOME` (default `~/.config`)
    /// or `%AppData%`.
    app_data,
    /// `app_data` joined with the application name. Created on first use.
    user_data,
    /// The per-user cache directory joined with the application name:
    /// `$XDG_CACHE_HOME` (default `~/.cache`) or `%LocalAppData%`. Created on
    /// first use.
    cache,
    /// `user_data/logs`. Created on first use.
    logs,
    /// The directory of the files the application ships with: the
    /// executable's directory, after resolving symbolic links.
    resources,
    temp,
    /// The running executable itself.
    exe,
    desktop,
    documents,
    downloads,
    music,
    pictures,
    videos,

    fn creates(self: Name) bool {
        return self == .user_data or self == .cache or self == .logs;
    }
};

/// Supplies environment variables and small configuration files, so tests can
/// resolve without the process environment.
pub const Source = struct {
    context: ?*anyopaque = null,
    /// Returns an owned value, or null when the variable is unset or empty.
    env: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8 = processEnv,
    /// Returns owned contents, or null when the file does not exist.
    read: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8 = readFile,
    executable: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]u8 = selfExe,
    os: std.Target.Os.Tag = builtin.os.tag,
};

pub const max_name_bytes = 255;

/// Application paths with per-name overrides. Keep it on the owner thread or
/// guard it; it holds no native resources and needs no deinit.
pub const Paths = struct {
    /// Borrowed. Joined below app_data and the cache directory.
    app_name: []const u8,
    /// Borrowed override paths, returned as they are.
    overrides: std.EnumArray(Name, ?[]const u8) = .initFill(null),
    source: Source = .{},

    pub fn init(app_name: []const u8) !Paths {
        try validateAppName(app_name);
        return .{ .app_name = app_name };
    }
    /// Overrides a directory returned by `get`; null restores the default.
    /// The path is borrowed until replaced.
    pub fn set(self: *Paths, name: Name, path: ?[]const u8) void {
        self.overrides.set(name, path);
    }
    /// Returns an owned path. `user_data`, `cache` and `logs` are created
    /// when missing; an override is returned as given and never created.
    pub fn get(self: *const Paths, allocator: std.mem.Allocator, name: Name) ![]u8 {
        if (self.overrides.get(name)) |path| return allocator.dupe(u8, path);
        const path = try self.resolve(allocator, name);
        errdefer allocator.free(path);
        if (name.creates()) try std.Io.Dir.cwd().createDirPath(zio.io(), path);
        return path;
    }
    /// Like `get`, without creating anything.
    pub fn resolve(self: *const Paths, allocator: std.mem.Allocator, name: Name) ![]u8 {
        const source = self.source;
        const windows = source.os == .windows;
        switch (name) {
            .home => return home(allocator, source),
            .app_data => return configDir(allocator, source),
            .user_data => {
                const base = try configDir(allocator, source);
                defer allocator.free(base);
                return join(allocator, source, &.{ base, self.app_name });
            },
            .cache => {
                const base = if (windows) try requireEnv(allocator, source, "LocalAppData") else try xdg(allocator, source, "XDG_CACHE_HOME", ".cache");
                defer allocator.free(base);
                return join(allocator, source, &.{ base, self.app_name });
            },
            .logs => {
                const base = try configDir(allocator, source);
                defer allocator.free(base);
                return join(allocator, source, &.{ base, self.app_name, "logs" });
            },
            .temp => {
                if (windows) {
                    for ([_][]const u8{ "TMP", "TEMP", "USERPROFILE" }) |key| if (try source.env(source.context, allocator, key)) |value| return value;
                    return allocator.dupe(u8, "C:\\Windows");
                }
                return try source.env(source.context, allocator, "TMPDIR") orelse allocator.dupe(u8, "/tmp");
            },
            .exe => return source.executable(source.context, allocator),
            .resources => {
                const exe = try source.executable(source.context, allocator);
                defer allocator.free(exe);
                const directory = dirname(source, exe) orelse return error.PathUnavailable;
                return allocator.dupe(u8, directory);
            },
            .desktop, .documents, .downloads, .music, .pictures, .videos => return userDir(allocator, source, name),
        }
    }
};

pub fn validateAppName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidAppName;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidAppName;
    for (name) |byte| switch (byte) {
        0...31, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return error.InvalidAppName,
        else => {},
    };
}

fn home(allocator: std.mem.Allocator, source: Source) ![]u8 {
    return requireEnv(allocator, source, if (source.os == .windows) "USERPROFILE" else "HOME");
}
fn configDir(allocator: std.mem.Allocator, source: Source) ![]u8 {
    if (source.os == .windows) return requireEnv(allocator, source, "AppData");
    return xdg(allocator, source, "XDG_CONFIG_HOME", ".config");
}
/// An XDG base directory must be absolute; otherwise the default applies.
fn xdg(allocator: std.mem.Allocator, source: Source, key: []const u8, fallback: []const u8) ![]u8 {
    if (try source.env(source.context, allocator, key)) |value| {
        if (value[0] == '/') return value;
        allocator.free(value);
    }
    const base = try home(allocator, source);
    defer allocator.free(base);
    return join(allocator, source, &.{ base, fallback });
}
fn requireEnv(allocator: std.mem.Allocator, source: Source, key: []const u8) ![]u8 {
    return try source.env(source.context, allocator, key) orelse error.PathUnavailable;
}
fn join(allocator: std.mem.Allocator, source: Source, parts: []const []const u8) ![]u8 {
    const separator: u8 = if (source.os == .windows) '\\' else '/';
    var length: usize = 0;
    for (parts, 0..) |part, index| length += part.len + @intFromBool(index != 0);
    const result = try allocator.alloc(u8, length);
    var offset: usize = 0;
    for (parts, 0..) |part, index| {
        if (index != 0) {
            result[offset] = separator;
            offset += 1;
        }
        @memcpy(result[offset..][0..part.len], part);
        offset += part.len;
    }
    return result;
}
fn dirname(source: Source, path: []const u8) ?[]const u8 {
    return if (source.os == .windows) std.fs.path.dirnameWindows(path) else std.fs.path.dirnamePosix(path);
}

/// The user's standard folders below home, honoring the XDG user-dirs
/// configuration on Linux.
fn userDir(allocator: std.mem.Allocator, source: Source, name: Name) ![]u8 {
    const folder, const key = switch (name) {
        .desktop => .{ "Desktop", "XDG_DESKTOP_DIR" },
        .documents => .{ "Documents", "XDG_DOCUMENTS_DIR" },
        .downloads => .{ "Downloads", "XDG_DOWNLOAD_DIR" },
        .music => .{ "Music", "XDG_MUSIC_DIR" },
        .pictures => .{ "Pictures", "XDG_PICTURES_DIR" },
        .videos => .{ "Videos", "XDG_VIDEOS_DIR" },
        else => unreachable,
    };
    const base = try home(allocator, source);
    defer allocator.free(base);
    if (source.os == .linux) {
        const config = try configDir(allocator, source);
        defer allocator.free(config);
        const file = try join(allocator, source, &.{ config, "user-dirs.dirs" });
        defer allocator.free(file);
        if (try source.read(source.context, allocator, file)) |contents| {
            defer allocator.free(contents);
            if (try userDirsValue(allocator, contents, key, base)) |value| return value;
        }
    }
    return join(allocator, source, &.{ base, folder });
}

/// Reads `KEY="value"` from user-dirs.dirs, expanding a leading `$HOME`.
pub fn userDirsValue(allocator: std.mem.Allocator, contents: []const u8, key: []const u8, home_path: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..equals], key)) continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], "\"");
        if (std.mem.startsWith(u8, value, "$HOME")) return try std.mem.concat(allocator, u8, &.{ home_path, value["$HOME".len..] });
        return try allocator.dupe(u8, value);
    }
    return null;
}

const max_config_bytes = 64 * 1024;

fn processEnv(_: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
    const value = zio.getEnvVarOwned(allocator, key) catch |err| return if (err == error.EnvironmentVariableNotFound) null else err;
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}
fn readFile(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(zio.io(), path, allocator, .limited(max_config_bytes)) catch |err| return if (err == error.FileNotFound) null else err;
}
fn selfExe(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const path = try zio.executablePathAlloc(allocator);
    errdefer allocator.free(path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real = zio.realpath(std.Io.Dir.cwd(), path, &buffer) catch return path;
    const result = try allocator.dupe(u8, real);
    allocator.free(path);
    return result;
}

const Fake = struct {
    os: std.Target.Os.Tag,
    vars: []const [2][]const u8,
    file: ?[]const u8 = null,
    fn env(ptr: ?*anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr.?));
        for (self.vars) |pair| if (std.mem.eql(u8, pair[0], key)) return try allocator.dupe(u8, pair[1]);
        return null;
    }
    fn read(ptr: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr.?));
        return if (self.file) |contents| try allocator.dupe(u8, contents) else null;
    }
    fn exe(ptr: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *Fake = @ptrCast(@alignCast(ptr.?));
        return allocator.dupe(u8, if (self.os == .windows) "C:\\Apps\\Notes\\notes.exe" else "/opt/notes/bin/notes");
    }
    fn paths(self: *Fake) !Paths {
        var result = try Paths.init("Notes");
        result.source = .{ .context = self, .env = env, .read = read, .executable = exe, .os = self.os };
        return result;
    }
};

fn expectPath(paths: *const Paths, name: Name, expected: []const u8) !void {
    const actual = try paths.resolve(std.testing.allocator, name);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "linux paths follow XDG with home fallbacks and user-dirs" {
    var fake: Fake = .{ .os = .linux, .vars = &.{ .{ "HOME", "/home/ada" }, .{ "XDG_CACHE_HOME", "relative/ignored" } }, .file =
        \\# written by xdg-user-dirs-update
        \\XDG_DESKTOP_DIR="$HOME/Schreibtisch"
        \\XDG_MUSIC_DIR="/srv/music"
    };
    const paths = try fake.paths();
    try expectPath(&paths, .home, "/home/ada");
    try expectPath(&paths, .app_data, "/home/ada/.config");
    try expectPath(&paths, .user_data, "/home/ada/.config/Notes");
    try expectPath(&paths, .cache, "/home/ada/.cache/Notes");
    try expectPath(&paths, .logs, "/home/ada/.config/Notes/logs");
    try expectPath(&paths, .desktop, "/home/ada/Schreibtisch");
    try expectPath(&paths, .music, "/srv/music");
    try expectPath(&paths, .videos, "/home/ada/Videos");
    try expectPath(&paths, .temp, "/tmp");
    try expectPath(&paths, .exe, "/opt/notes/bin/notes");
    try expectPath(&paths, .resources, "/opt/notes/bin");
}

test "windows paths use the known environment folders" {
    var fake: Fake = .{ .os = .windows, .vars = &.{ .{ "USERPROFILE", "C:\\Users\\Ada" }, .{ "AppData", "C:\\Users\\Ada\\AppData\\Roaming" }, .{ "LocalAppData", "C:\\Users\\Ada\\AppData\\Local" }, .{ "TEMP", "C:\\Temp" } } };
    var paths = try fake.paths();
    try expectPath(&paths, .user_data, "C:\\Users\\Ada\\AppData\\Roaming\\Notes");
    try expectPath(&paths, .cache, "C:\\Users\\Ada\\AppData\\Local\\Notes");
    try expectPath(&paths, .logs, "C:\\Users\\Ada\\AppData\\Roaming\\Notes\\logs");
    try expectPath(&paths, .downloads, "C:\\Users\\Ada\\Downloads");
    try expectPath(&paths, .temp, "C:\\Temp");
    try expectPath(&paths, .resources, "C:\\Apps\\Notes");
    paths.set(.cache, "D:\\cache");
    const cache = try paths.get(std.testing.allocator, .cache);
    defer std.testing.allocator.free(cache);
    try std.testing.expectEqualStrings("D:\\cache", cache);
}

test "missing home and invalid application names fail explicitly" {
    var fake: Fake = .{ .os = .linux, .vars = &.{} };
    const paths = try fake.paths();
    try std.testing.expectError(error.PathUnavailable, paths.resolve(std.testing.allocator, .user_data));
    try std.testing.expectError(error.InvalidAppName, Paths.init(""));
    try std.testing.expectError(error.InvalidAppName, Paths.init("a/b"));
    try std.testing.expectError(error.InvalidAppName, Paths.init(".."));
}

test "get creates the application's own directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try zio.realPathAlloc(tmp.dir, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var fake: Fake = .{ .os = builtin.os.tag, .vars = &.{ .{ "HOME", root }, .{ "USERPROFILE", root }, .{ "AppData", root }, .{ "LocalAppData", root } } };
    const paths = try fake.paths();
    const logs = try paths.get(std.testing.allocator, .logs);
    defer std.testing.allocator.free(logs);
    var directory = try std.Io.Dir.cwd().openDir(zio.io(), logs, .{});
    directory.close(zio.io());
}
