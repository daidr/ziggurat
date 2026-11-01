const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const identity = @import("identity.zig");
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

pub const max_url_schemes = 16;
pub const max_file_types = 64;
pub const max_login_arguments = 32;
pub const max_text_bytes = 255;
pub const capabilities = .{
    .login_item = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos,
    .url_schemes = builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos,
    // A macOS bundle declares its document types in Info.plist at build time.
    .file_associations = builtin.os.tag == .windows or builtin.os.tag == .linux,
};

// macOS: src/system/macos_services.m.
extern fn zsm_login_set(id: [*:0]const u8, arguments: [*]const [*:0]const u8, count: u32, code: *c_int) c_int;
extern fn zsm_login_remove(id: [*:0]const u8, code: *c_int) c_int;
extern fn zsm_login_registered(id: [*:0]const u8) c_int;
extern fn zsm_scheme_register(scheme: [*:0]const u8, make_default: c_int, code: *c_int) c_int;
extern fn zsm_scheme_is_default(scheme: [*:0]const u8) c_int;

pub const FileType = struct {
    /// Lowercase, starting with '.', then 1..31 ASCII letters, digits, '_' or '-'.
    extension: []const u8,
    /// `type/subtype`. Linux associates the desktop entry with it and declares
    /// the extension glob; Windows records it as the extension's Content Type.
    mime_type: []const u8,
    description: []const u8,
};
/// Everything a per-user registration writes. The same value unregisters it.
pub const Application = struct {
    /// identity.validate rules. Linux writes `<id>.desktop`; Windows ProgIDs
    /// are `<id>.<extension without dot>` and must stay within 39 characters.
    id: []const u8,
    name: []const u8,
    /// Absolute path. Windows requires an `.exe` path.
    executable: []const u8,
    /// Windows: icon resource location, e.g. `C:\App\app.exe,0`. Linux: an
    /// icon theme name or absolute image path. Null leaves it unset.
    icon: ?[]const u8 = null,
    /// Lowercase RFC 3986 scheme names, opened as `<executable> <url>`.
    url_schemes: []const []const u8 = &.{},
    /// Opened as `<executable> <path>`; Linux desktop launchers may pass a
    /// `file://` URL instead, which localPath converts.
    file_types: []const FileType = &.{},
    /// Linux desktop entry categories, e.g. "Utility". Ignored on Windows.
    categories: []const []const u8 = &.{},
};
pub const Scope = struct {
    /// Linux only: replacements for XDG_DATA_HOME and XDG_CONFIG_HOME, for a
    /// staging root or an isolated test. Absolute.
    data_home: ?[]const u8 = null,
    config_home: ?[]const u8 = null,
};
pub const RegisterOptions = struct {
    /// Become the default handler for the schemes and MIME types. Linux edits
    /// `[Default Applications]` in the user's mimeapps.list; Windows sets the
    /// extension's default ProgID. Windows keeps a hash-protected user choice
    /// made in Settings, which no registration API may override.
    make_default: bool = true,
    /// Linux: run update-desktop-database and update-mime-database from
    /// /usr/bin or /bin when present, so the new extension glob is visible.
    refresh_caches: bool = true,
    scope: Scope = .{},
};
pub const Report = struct {
    desktop_database_refreshed: bool = false,
    mime_database_refreshed: bool = false,
};
pub const LoginItem = struct {
    id: []const u8,
    name: []const u8,
    executable: []const u8,
    arguments: []const []const u8 = &.{},
};

/// Writes the per-user handler registration. Blocking disk/registry work:
/// call it from an installer, a first-run step or an application worker, not
/// from a UI callback. Repeating it with the same value is idempotent. Nothing
/// is registered machine-wide and no elevation is requested.
///
/// macOS: the app bundle's Info.plist declares its URL schemes and document
/// types, and Launch Services registers them with the bundle. Here each
/// scheme must be declared (SchemeNotDeclared otherwise; AppBundleRequired
/// outside a bundle) and, with make_default, the bundle becomes its default
/// handler. File types return UnsupportedCapability: they are the bundle's.
pub fn register(allocator: std.mem.Allocator, application: Application, options: RegisterOptions) !Report {
    try validateApplication(application);
    return switch (builtin.os.tag) {
        .windows => windowsRegister(application, options),
        .linux => linuxRegister(allocator, application, options),
        .macos => macosRegister(application, options),
        else => error.UnsupportedCapability,
    };
}
/// macOS only: whether this app bundle is the default handler of `scheme`.
pub fn isDefaultSchemeHandler(scheme: []const u8) !bool {
    try validateScheme(scheme);
    if (builtin.os.tag != .macos) return error.UnsupportedCapability;
    var storage: [33]u8 = undefined;
    return zsm_scheme_is_default(terminate(&storage, scheme)) == 1;
}
fn macosRegister(application: Application, options: RegisterOptions) !Report {
    if (application.file_types.len != 0) return error.UnsupportedCapability;
    for (application.url_schemes) |scheme| {
        var storage: [33]u8 = undefined;
        var code: c_int = 0;
        switch (zsm_scheme_register(terminate(&storage, scheme), @intFromBool(options.make_default), &code)) {
            0 => {},
            1 => return error.AppBundleRequired,
            2 => return error.SchemeNotDeclared,
            else => {
                last_macos_status = code;
                return error.RegistrationFailed;
            },
        }
    }
    return .{};
}
/// macOS: the OSStatus or NSError code of the last failed registration or
/// login item call on this thread.
pub threadlocal var last_macos_status: c_int = 0;
fn terminate(storage: []u8, text: []const u8) [*:0]const u8 {
    @memcpy(storage[0..text.len], text);
    storage[text.len] = 0;
    return storage[0..text.len :0];
}
/// Removes what register wrote for this value. Entries that another
/// application owns now, such as a scheme re-registered by someone else, are
/// left alone. Missing entries are not an error. macOS returns
/// UnsupportedCapability: the schemes belong to the bundle.
pub fn unregister(allocator: std.mem.Allocator, application: Application, options: RegisterOptions) !Report {
    try validateApplication(application);
    return switch (builtin.os.tag) {
        .windows => windowsUnregister(application),
        .linux => linuxUnregister(allocator, application, options),
        else => error.UnsupportedCapability,
    };
}

/// Starts the application when the user signs in. Windows writes the
/// per-user Run value; Linux writes an XDG autostart entry. Blocking I/O.
///
/// macOS needs the process to run from an app bundle (AppBundleRequired
/// otherwise) and starts that bundle, not `executable`. From macOS 13 the
/// bundle registers as the user's login item (System Settings > General >
/// Login Items), which ignores `arguments`; ApprovalRequired then means it
/// is registered but the user has to allow it there. Earlier versions get a
/// launch agent, ~/Library/LaunchAgents/<id>.plist, that opens the bundle
/// with the arguments.
pub fn setLoginItem(item: LoginItem, scope: Scope) !void {
    try validateLoginItem(item);
    switch (builtin.os.tag) {
        .macos => {
            var id: [identity.max_id_bytes + 1]u8 = undefined;
            var storage: [max_login_arguments][1025]u8 = undefined;
            var arguments: [max_login_arguments][*:0]const u8 = undefined;
            for (item.arguments, 0..) |argument, index| arguments[index] = terminate(&storage[index], argument);
            var code: c_int = 0;
            switch (zsm_login_set(terminate(&id, item.id), &arguments, @intCast(item.arguments.len), &code)) {
                0 => {},
                1 => return error.AppBundleRequired,
                2 => return error.ApprovalRequired,
                else => {
                    last_macos_status = code;
                    return error.LoginItemFailed;
                },
            }
        },
        .windows => {
            var command: [max_command_bytes]u8 = undefined;
            const line = try windowsCommand(&command, item.executable, item.arguments, false);
            try windowsSetString(run_key, item.id, line);
        },
        .linux => {
            var buffer: [16 * 1024]u8 = undefined;
            var path: [std.fs.max_path_bytes]u8 = undefined;
            const contents = try autostartEntry(&buffer, item);
            try writeFileAtomic(try linuxPath(&path, scope, .config, &.{ "/autostart/", item.id, ".desktop" }), contents);
        },
        else => return error.UnsupportedCapability,
    }
}
pub fn removeLoginItem(id: []const u8, scope: Scope) !void {
    try identity.validate(id);
    switch (builtin.os.tag) {
        .macos => {
            var storage: [identity.max_id_bytes + 1]u8 = undefined;
            var code: c_int = 0;
            switch (zsm_login_remove(terminate(&storage, id), &code)) {
                0 => {},
                1 => return error.AppBundleRequired,
                else => {
                    last_macos_status = code;
                    return error.LoginItemFailed;
                },
            }
        },
        .windows => try windowsDeleteValue(run_key, id),
        .linux => {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            std.Io.Dir.deleteFileAbsolute(zio.io(), try linuxPath(&path, scope, .config, &.{ "/autostart/", id, ".desktop" })) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
        else => return error.UnsupportedCapability,
    }
}
/// Reports whether this application's own login entry exists. It does not
/// read desktop-specific disable switches such as Windows Startup Apps.
/// macOS reports whether the login item is enabled, so one waiting for the
/// user's approval is not.
pub fn loginItemRegistered(id: []const u8, scope: Scope) !bool {
    try identity.validate(id);
    switch (builtin.os.tag) {
        .macos => {
            var storage: [identity.max_id_bytes + 1]u8 = undefined;
            const status = zsm_login_registered(terminate(&storage, id));
            if (status < 0) return error.AppBundleRequired;
            return status == 1;
        },
        .windows => {
            var value: [max_command_bytes]u8 = undefined;
            return (try windowsGetString(run_key, id, &value)) != null;
        },
        .linux => {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            std.Io.Dir.accessAbsolute(zio.io(), try linuxPath(&path, scope, .config, &.{ "/autostart/", id, ".desktop" }), .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        },
        else => return error.UnsupportedCapability,
    }
}

/// Converts a forwarded `file://` argument (empty or `localhost` host) into a
/// local path with percent escapes decoded. Returns null for other arguments,
/// which the application treats as plain paths or URLs of its own schemes.
pub fn localPath(argument: []const u8, destination: []u8) !?[]u8 {
    const prefix = "file://";
    if (argument.len < prefix.len or !std.ascii.eqlIgnoreCase(argument[0..prefix.len], prefix)) return null;
    var rest = argument[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidFileUrl;
    const host = rest[0..slash];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.InvalidFileUrl;
    rest = rest[slash..];
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return error.InvalidFileUrl;
    // A Windows drive URL is file:///C:/path.
    if (builtin.os.tag == .windows and rest.len >= 3 and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') rest = rest[1..];
    var used: usize = 0;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        var byte = rest[index];
        if (byte == '%') {
            if (index + 2 >= rest.len) return error.InvalidFileUrl;
            byte = std.fmt.parseInt(u8, rest[index + 1 .. index + 3], 16) catch return error.InvalidFileUrl;
            if (byte == 0) return error.InvalidFileUrl;
            index += 2;
        }
        if (builtin.os.tag == .windows and byte == '/') byte = '\\';
        if (used == destination.len) return error.ResultCapacityExceeded;
        destination[used] = byte;
        used += 1;
    }
    return destination[0..used];
}

fn validateText(value: []const u8, allow_empty: bool) !void {
    if ((!allow_empty and value.len == 0) or value.len > max_text_bytes) return error.InvalidText;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
}
fn validateExecutable(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidExecutable;
    for (path) |byte| if (byte < 0x20 or byte == '"') return error.InvalidExecutable;
    if (builtin.os.tag == .windows) {
        if (path.len < 4 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) {
            if (!std.mem.startsWith(u8, path, "\\\\")) return error.AbsolutePathRequired;
        }
        if (!std.ascii.endsWithIgnoreCase(path, ".exe")) return error.ExecutableRequired;
    } else if (path[0] != '/') return error.AbsolutePathRequired;
}
pub fn validateScheme(scheme: []const u8) !void {
    if (scheme.len == 0 or scheme.len > 32 or !std.ascii.isLower(scheme[0])) return error.InvalidScheme;
    for (scheme) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '+' or byte == '-' or byte == '.')) return error.InvalidScheme;
}
pub fn validateExtension(extension: []const u8) !void {
    if (extension.len < 2 or extension.len > 32 or extension[0] != '.') return error.InvalidExtension;
    for (extension[1..]) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '-')) return error.InvalidExtension;
}
pub fn validateMimeType(mime: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse return error.InvalidMimeType;
    if (slash == 0 or slash + 1 == mime.len or mime.len > 127) return error.InvalidMimeType;
    for (mime, 0..) |byte, index| {
        if (index == slash) continue;
        if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$&^_.+-", byte) != null)) return error.InvalidMimeType;
    }
}
fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 64) return error.InvalidCategory;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return error.InvalidCategory;
}
fn validateApplication(application: Application) !void {
    try identity.validate(application.id);
    try validateText(application.name, false);
    try validateExecutable(application.executable);
    if (application.icon) |icon| {
        try validateText(icon, false);
        if (std.mem.indexOfScalar(u8, icon, '"') != null) return error.InvalidText;
    }
    if (application.url_schemes.len > max_url_schemes) return error.TooManySchemes;
    if (application.file_types.len > max_file_types) return error.TooManyFileTypes;
    if (application.categories.len > 16) return error.InvalidCategory;
    for (application.url_schemes, 0..) |scheme, index| {
        try validateScheme(scheme);
        for (application.url_schemes[0..index]) |earlier| if (std.mem.eql(u8, earlier, scheme)) return error.DuplicateScheme;
    }
    for (application.file_types, 0..) |file_type, index| {
        try validateExtension(file_type.extension);
        try validateMimeType(file_type.mime_type);
        try validateText(file_type.description, false);
        for (application.file_types[0..index]) |earlier| if (std.mem.eql(u8, earlier.extension, file_type.extension)) return error.DuplicateExtension;
        if (builtin.os.tag == .windows and application.id.len + file_type.extension.len > 39) return error.ProgIdTooLong;
    }
    for (application.categories) |category| try validateToken(category);
}
fn validateLoginItem(item: LoginItem) !void {
    try identity.validate(item.id);
    try validateText(item.name, false);
    try validateExecutable(item.executable);
    if (item.arguments.len > max_login_arguments) return error.TooManyArguments;
    for (item.arguments) |argument| {
        if (argument.len > 1024 or !std.unicode.utf8ValidateSlice(argument)) return error.InvalidArgument;
        for (argument) |byte| if (byte < 0x20) return error.InvalidArgument;
    }
}

// Desktop entry generation (Desktop Entry Specification 1.5).

const Writer = struct {
    buffer: []u8,
    used: usize = 0,
    fn bytes(self: *Writer, value: []const u8) !void {
        if (self.buffer.len - self.used < value.len) return error.ResultCapacityExceeded;
        @memcpy(self.buffer[self.used..][0..value.len], value);
        self.used += value.len;
    }
    fn byte(self: *Writer, value: u8) !void {
        try self.bytes(&.{value});
    }
    /// A `string`/`localestring` value: escape the backslash; control
    /// characters were rejected during validation.
    fn string(self: *Writer, text: []const u8) !void {
        for (text) |c| if (c == '\\') try self.bytes("\\\\") else try self.byte(c);
    }
    /// One Exec argument: quoted when it holds a reserved character, with the
    /// quoting backslashes then escaped again by the string value rule.
    fn execArgument(self: *Writer, argument: []const u8) !void {
        const reserved = " \t\n\"'\\><~|&;$*?#()`";
        const quote = argument.len == 0 or std.mem.indexOfAny(u8, argument, reserved) != null;
        if (quote) try self.byte('"');
        for (argument) |c| {
            if (c == '%') {
                try self.bytes("%%");
                continue;
            }
            if (quote and (c == '"' or c == '`' or c == '$' or c == '\\')) try self.bytes("\\\\");
            if (c == '\\') try self.bytes("\\\\") else try self.byte(c);
        }
        if (quote) try self.byte('"');
    }
    fn xml(self: *Writer, text: []const u8) !void {
        for (text) |c| switch (c) {
            '&' => try self.bytes("&amp;"),
            '<' => try self.bytes("&lt;"),
            '>' => try self.bytes("&gt;"),
            '"' => try self.bytes("&quot;"),
            '\'' => try self.bytes("&apos;"),
            else => try self.byte(c),
        };
    }
    fn result(self: *Writer) []u8 {
        return self.buffer[0..self.used];
    }
};

pub fn desktopEntry(buffer: []u8, application: Application) ![]u8 {
    var out: Writer = .{ .buffer = buffer };
    try out.bytes("[Desktop Entry]\nType=Application\nVersion=1.5\nName=");
    try out.string(application.name);
    try out.bytes("\nExec=");
    try out.execArgument(application.executable);
    try out.bytes(" %U\nTerminal=false\n");
    if (application.icon) |icon| {
        try out.bytes("Icon=");
        try out.string(icon);
        try out.byte('\n');
    }
    if (application.categories.len != 0) {
        try out.bytes("Categories=");
        for (application.categories) |category| {
            try out.bytes(category);
            try out.byte(';');
        }
        try out.byte('\n');
    }
    if (application.url_schemes.len + application.file_types.len != 0) {
        try out.bytes("MimeType=");
        for (application.url_schemes) |scheme| {
            try out.bytes("x-scheme-handler/");
            try out.bytes(scheme);
            try out.byte(';');
        }
        for (application.file_types) |file_type| {
            try out.bytes(file_type.mime_type);
            try out.byte(';');
        }
        try out.byte('\n');
    }
    return out.result();
}
pub fn autostartEntry(buffer: []u8, item: LoginItem) ![]u8 {
    var out: Writer = .{ .buffer = buffer };
    try out.bytes("[Desktop Entry]\nType=Application\nVersion=1.5\nName=");
    try out.string(item.name);
    try out.bytes("\nExec=");
    try out.execArgument(item.executable);
    for (item.arguments) |argument| {
        try out.byte(' ');
        try out.execArgument(argument);
    }
    try out.bytes("\nTerminal=false\nX-GNOME-Autostart-enabled=true\n");
    return out.result();
}
/// Whether the app defines a file type itself: an unregistered one (subtype
/// `x-...`), which no system knows. Registered types such as `text/markdown`
/// are the system's, and the app only says it opens them.
pub fn definesMimeType(mime: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse return false;
    return std.mem.startsWith(u8, mime[slash + 1 ..], "x-");
}
pub fn mimePackage(buffer: []u8, application: Application) ![]u8 {
    var out: Writer = .{ .buffer = buffer };
    try out.bytes("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<mime-info xmlns=\"http://www.freedesktop.org/standards/shared-mime-info\">\n");
    for (application.file_types) |file_type| {
        if (!definesMimeType(file_type.mime_type)) continue;
        try out.bytes("  <mime-type type=\"");
        try out.bytes(file_type.mime_type);
        try out.bytes("\">\n    <comment>");
        try out.xml(file_type.description);
        try out.bytes("</comment>\n    <glob pattern=\"*");
        try out.bytes(file_type.extension);
        try out.bytes("\"/>\n  </mime-type>\n");
    }
    try out.bytes("</mime-info>\n");
    return out.result();
}

/// Rewrites a mimeapps.list. Every line it does not own is kept byte for byte.
/// Registration puts `desktop_id` first in `[Added Associations]` (and in
/// `[Default Applications]` for `register_default`) for each MIME type and
/// drops it from `[Removed Associations]`; removal drops it from all three.
pub fn editMimeApps(allocator: std.mem.Allocator, input: []const u8, desktop_id: []const u8, mime_types: []const []const u8, mode: MimeAppsMode) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Section = struct { header: ?[]const u8, kind: enum { other, default, added, removed }, lines: std.ArrayList([]const u8) = .empty };
    var sections: std.ArrayList(Section) = .empty;
    try sections.append(arena, .{ .header = null, .kind = .other });
    const body = if (std.mem.endsWith(u8, input, "\n")) input[0 .. input.len - 1] else input;
    if (input.len != 0) {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] == '[') {
                const kind: @FieldType(Section, "kind") = if (std.mem.eql(u8, trimmed, "[Default Applications]")) .default else if (std.mem.eql(u8, trimmed, "[Added Associations]")) .added else if (std.mem.eql(u8, trimmed, "[Removed Associations]")) .removed else .other;
                try sections.append(arena, .{ .header = line, .kind = kind });
            } else try sections.items[sections.items.len - 1].lines.append(arena, line);
        }
    }
    const handled = try arena.alloc(bool, mime_types.len);
    var present = [_]bool{ false, false };
    for (sections.items) |*section| {
        if (section.kind == .other) continue;
        const lead = switch (section.kind) {
            .default => mode == .register_default,
            .added => mode != .remove,
            else => false,
        };
        if (section.kind == .default) present[0] = true;
        if (section.kind == .added) present[1] = true;
        @memset(handled, false);
        var kept: std.ArrayList([]const u8) = .empty;
        for (section.lines.items) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const equals = std.mem.indexOfScalar(u8, line, '=');
            const index = if (trimmed.len == 0 or trimmed[0] == '#' or equals == null) null else for (mime_types, 0..) |mime, at| {
                if (std.mem.eql(u8, mime, std.mem.trim(u8, line[0..equals.?], " \t"))) break at;
            } else null;
            if (index == null) {
                try kept.append(arena, line);
                continue;
            }
            handled[index.?] = true;
            var list: std.ArrayList(u8) = .empty;
            try list.print(arena, "{s}=", .{mime_types[index.?]});
            const empty_length = list.items.len;
            if (lead) try list.print(arena, "{s};", .{desktop_id});
            var entries = std.mem.splitScalar(u8, std.mem.trim(u8, line[equals.? + 1 ..], " \t\r"), ';');
            while (entries.next()) |entry| {
                const name = std.mem.trim(u8, entry, " \t");
                if (name.len == 0 or std.mem.eql(u8, name, desktop_id)) continue;
                try list.print(arena, "{s};", .{name});
            }
            if (list.items.len != empty_length) try kept.append(arena, list.items);
        }
        if (lead) {
            // Missing keys go after the section's last non-blank line.
            var at = kept.items.len;
            while (at > 0 and std.mem.trim(u8, kept.items[at - 1], " \t\r").len == 0) at -= 1;
            for (mime_types, handled) |mime, done| if (!done) {
                try kept.insert(arena, at, try std.fmt.allocPrint(arena, "{s}={s};", .{ mime, desktop_id }));
                at += 1;
            };
        }
        section.lines = kept;
    }
    const wanted = [_]struct { header: []const u8, needed: bool }{
        .{ .header = "[Default Applications]", .needed = mode == .register_default and !present[0] },
        .{ .header = "[Added Associations]", .needed = mode != .remove and !present[1] },
    };
    for (wanted) |entry| if (entry.needed and mime_types.len != 0) {
        const last = &sections.items[sections.items.len - 1];
        if (last.header != null or last.lines.items.len != 0) {
            if (last.lines.items.len == 0 or std.mem.trim(u8, last.lines.items[last.lines.items.len - 1], " \t\r").len != 0) try last.lines.append(arena, "");
        }
        var section: Section = .{ .header = entry.header, .kind = .other };
        for (mime_types) |mime| try section.lines.append(arena, try std.fmt.allocPrint(arena, "{s}={s};", .{ mime, desktop_id }));
        try sections.append(arena, section);
    };
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (sections.items) |section| {
        if (section.header) |header| try output.print(allocator, "{s}\n", .{header});
        for (section.lines.items) |line| try output.print(allocator, "{s}\n", .{line});
    }
    return output.toOwnedSlice(allocator);
}
pub const MimeAppsMode = enum { register, register_default, remove };

// Linux files.

fn linuxPath(destination: []u8, scope: Scope, root: enum { data, config }, parts: []const []const u8) ![]u8 {
    var base_storage: [std.fs.max_path_bytes]u8 = undefined;
    const override = switch (root) {
        .data => scope.data_home,
        .config => scope.config_home,
    };
    const base = if (override) |value| blk: {
        if (value.len == 0 or value[0] != '/') return error.AbsolutePathRequired;
        break :blk value;
    } else try identity.directory(if (root == .data) .data else .config, &base_storage);
    var out: Writer = .{ .buffer = destination };
    try out.bytes(base);
    for (parts) |part| try out.bytes(part);
    return out.result();
}
fn writeFileAtomic(path: []const u8, contents: []const u8) !void {
    const directory = std.fs.path.dirname(path) orelse return error.AbsolutePathRequired;
    try std.Io.Dir.cwd().createDirPath(zio.io(), directory);
    var temporary: [std.fs.max_path_bytes]u8 = undefined;
    var random: [8]u8 = undefined;
    zio.random.bytes(&random);
    const temp_path = try std.fmt.bufPrint(&temporary, "{s}.{x}.tmp", .{ path, std.mem.readInt(u64, &random, .little) });
    {
        const file = try std.Io.Dir.createFileAbsolute(zio.io(), temp_path, .{ .exclusive = true, .permissions = zio.mode(0o644) });
        defer file.close(zio.io());
        errdefer std.Io.Dir.deleteFileAbsolute(zio.io(), temp_path) catch {};
        try file.writeStreamingAll(zio.io(), contents);
        try file.sync(zio.io());
    }
    std.Io.Dir.renameAbsolute(temp_path, path, zio.io()) catch |err| {
        std.Io.Dir.deleteFileAbsolute(zio.io(), temp_path) catch {};
        return err;
    };
}
fn deleteIfPresent(path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(zio.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
fn updateMimeApps(allocator: std.mem.Allocator, application: Application, scope: Scope, mode: MimeAppsMode) !void {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try linuxPath(&path, scope, .config, &.{"/mimeapps.list"});
    const input = std.Io.Dir.cwd().readFileAlloc(zio.io(), file_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(input);
    var desktop: [identity.max_id_bytes + 8]u8 = undefined;
    const desktop_id = try std.fmt.bufPrint(&desktop, "{s}.desktop", .{application.id});
    var names = try allocator.alloc([]const u8, application.url_schemes.len + application.file_types.len);
    defer allocator.free(names);
    var scheme_storage: [max_url_schemes][64]u8 = undefined;
    for (application.url_schemes, 0..) |scheme, index| names[index] = try std.fmt.bufPrint(&scheme_storage[index], "x-scheme-handler/{s}", .{scheme});
    for (application.file_types, 0..) |file_type, index| names[application.url_schemes.len + index] = file_type.mime_type;
    const output = try editMimeApps(allocator, input, desktop_id, names, mode);
    defer allocator.free(output);
    if (std.mem.eql(u8, input, output)) return;
    if (output.len == 0) return deleteIfPresent(file_path);
    try writeFileAtomic(file_path, output);
}
fn refresh(tool: []const u8, directory: []const u8) bool {
    const roots = [_][]const u8{ "/usr/bin/", "/bin/" };
    var storage: [64]u8 = undefined;
    const executable = for (roots) |root| {
        const candidate = std.fmt.bufPrint(&storage, "{s}{s}", .{ root, tool }) catch unreachable;
        std.Io.Dir.accessAbsolute(zio.io(), candidate, .{}) catch continue;
        break candidate;
    } else return false;
    var child = zio.spawn(.{ .argv = &.{ executable, directory }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(zio.io()) catch return false;
    return term == .exited and term.exited == 0;
}
fn linuxRefresh(application: Application, options: RegisterOptions, report: *Report) !void {
    if (!options.refresh_caches) return;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    report.desktop_database_refreshed = refresh("update-desktop-database", try linuxPath(&path, options.scope, .data, &.{"/applications"}));
    if (application.file_types.len != 0) {
        report.mime_database_refreshed = refresh("update-mime-database", try linuxPath(&path, options.scope, .data, &.{"/mime"}));
    }
}
fn linuxRegister(allocator: std.mem.Allocator, application: Application, options: RegisterOptions) !Report {
    var buffer: [64 * 1024]u8 = undefined;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const package_path = try linuxPath(&path, options.scope, .data, &.{ "/mime/packages/", application.id, ".xml" });
    if (application.file_types.len != 0) try writeFileAtomic(package_path, try mimePackage(&buffer, application)) else try deleteIfPresent(package_path);
    try writeFileAtomic(try linuxPath(&path, options.scope, .data, &.{ "/applications/", application.id, ".desktop" }), try desktopEntry(&buffer, application));
    try updateMimeApps(allocator, application, options.scope, if (options.make_default) .register_default else .register);
    var report: Report = .{};
    try linuxRefresh(application, options, &report);
    return report;
}
fn linuxUnregister(allocator: std.mem.Allocator, application: Application, options: RegisterOptions) !Report {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    try updateMimeApps(allocator, application, options.scope, .remove);
    try deleteIfPresent(try linuxPath(&path, options.scope, .data, &.{ "/applications/", application.id, ".desktop" }));
    try deleteIfPresent(try linuxPath(&path, options.scope, .data, &.{ "/mime/packages/", application.id, ".xml" }));
    var report: Report = .{};
    try linuxRefresh(application, options, &report);
    return report;
}

// Windows registry. Every key lives under HKEY_CURRENT_USER.

const max_command_bytes = 8 * 1024;
const run_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const classes = "Software\\Classes\\";
/// Registry value naming the identity that owns a scheme or ProgID key, so
/// unregister never deletes another application's registration.
const owner_value = "ZigguratApplicationId";

/// Quotes `"executable" args...` with the usual Windows argv rules. A handler
/// command appends `"%1"`.
pub fn windowsCommand(buffer: []u8, executable: []const u8, arguments: []const []const u8, handler: bool) ![]u8 {
    var out: Writer = .{ .buffer = buffer };
    try out.byte('"');
    try out.bytes(executable);
    try out.byte('"');
    for (arguments) |argument| {
        try out.bytes(" \"");
        var at: usize = 0;
        while (at <= argument.len) {
            var slashes: usize = 0;
            while (at < argument.len and argument[at] == '\\') : (at += 1) slashes += 1;
            if (at == argument.len) {
                for (0..slashes * 2) |_| try out.byte('\\');
                break;
            }
            if (argument[at] == '"') {
                for (0..slashes * 2 + 1) |_| try out.byte('\\');
            } else for (0..slashes) |_| try out.byte('\\');
            try out.byte(argument[at]);
            at += 1;
        }
        try out.byte('"');
    }
    if (handler) try out.bytes(" \"%1\"");
    return out.result();
}
fn wide(destination: []u16, text: []const u8) ![:0]u16 {
    if (text.len >= destination.len) return error.ResultCapacityExceeded;
    const length = std.unicode.utf8ToUtf16Le(destination[0 .. destination.len - 1], text) catch return error.ResultCapacityExceeded;
    destination[length] = 0;
    return destination[0..length :0];
}
fn keyPath(destination: []u16, parts: []const []const u8) ![:0]u16 {
    var bytes: [1024]u8 = undefined;
    var out: Writer = .{ .buffer = &bytes };
    for (parts) |part| try out.bytes(part);
    return wide(destination, out.result());
}
fn windowsCreate(path: []const []const u8) !win.HKEY {
    var storage: [1024]u16 = undefined;
    const key_path = try keyPath(&storage, path);
    var key: win.HKEY = null;
    if (win.RegCreateKeyExW(win.HKEY_CURRENT_USER, key_path.ptr, 0, null, 0, win.KEY_SET_VALUE | win.KEY_QUERY_VALUE, null, &key, null) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
    return key;
}
fn windowsOpen(path: []const []const u8) !?win.HKEY {
    var storage: [1024]u16 = undefined;
    const key_path = try keyPath(&storage, path);
    var key: win.HKEY = null;
    return switch (win.RegOpenKeyExW(win.HKEY_CURRENT_USER, key_path.ptr, 0, win.KEY_QUERY_VALUE | win.KEY_SET_VALUE, &key)) {
        win.ERROR_SUCCESS => key,
        win.ERROR_FILE_NOT_FOUND => null,
        else => error.RegistryReadFailed,
    };
}
fn setValue(key: win.HKEY, name: ?[]const u8, value: []const u8) !void {
    var name_storage: [256]u16 = undefined;
    const name_wide: ?[*:0]const u16 = if (name) |text| (try wide(&name_storage, text)).ptr else null;
    var value_storage: [max_command_bytes]u16 = undefined;
    const data = try wide(&value_storage, value);
    const bytes: win.DWORD = @intCast((data.len + 1) * 2);
    if (win.RegSetValueExW(key, name_wide, 0, win.REG_SZ, @ptrCast(data.ptr), bytes) != win.ERROR_SUCCESS) return error.RegistryWriteFailed;
}
fn getValue(key: win.HKEY, name: ?[]const u8, destination: []u8) !?[]u8 {
    var name_storage: [256]u16 = undefined;
    const name_wide: ?[*:0]const u16 = if (name) |text| (try wide(&name_storage, text)).ptr else null;
    var value_storage: [max_command_bytes]u16 = undefined;
    var size: win.DWORD = @sizeOf(@TypeOf(value_storage)) - 2;
    var kind: win.DWORD = 0;
    switch (win.RegQueryValueExW(key, name_wide, null, &kind, @ptrCast(&value_storage), &size)) {
        win.ERROR_SUCCESS => {},
        win.ERROR_FILE_NOT_FOUND => return null,
        else => return error.RegistryReadFailed,
    }
    if (kind != win.REG_SZ and kind != win.REG_EXPAND_SZ) return null;
    var units: usize = size / 2;
    while (units > 0 and value_storage[units - 1] == 0) units -= 1;
    const length = std.unicode.utf16LeToUtf8(destination, value_storage[0..units]) catch return error.ResultCapacityExceeded;
    return destination[0..length];
}
fn windowsSetString(path: []const u8, name: []const u8, value: []const u8) !void {
    const key = try windowsCreate(&.{path});
    defer _ = win.RegCloseKey(key);
    try setValue(key, name, value);
}
fn windowsGetString(path: []const u8, name: []const u8, destination: []u8) !?[]u8 {
    const key = (try windowsOpen(&.{path})) orelse return null;
    defer _ = win.RegCloseKey(key);
    return getValue(key, name, destination);
}
fn windowsDeleteValue(path: []const u8, name: []const u8) !void {
    const key = (try windowsOpen(&.{path})) orelse return;
    defer _ = win.RegCloseKey(key);
    var name_storage: [256]u16 = undefined;
    switch (win.RegDeleteValueW(key, (try wide(&name_storage, name)).ptr)) {
        win.ERROR_SUCCESS, win.ERROR_FILE_NOT_FOUND => {},
        else => return error.RegistryWriteFailed,
    }
}
fn windowsDeleteTree(path: []const []const u8) !void {
    var storage: [1024]u16 = undefined;
    const key_path = try keyPath(&storage, path);
    switch (win.RegDeleteTreeW(win.HKEY_CURRENT_USER, key_path.ptr)) {
        win.ERROR_SUCCESS, win.ERROR_FILE_NOT_FOUND => {},
        else => return error.RegistryWriteFailed,
    }
    _ = win.RegDeleteKeyW(win.HKEY_CURRENT_USER, key_path.ptr);
}
fn ownedBy(path: []const []const u8, id: []const u8) !bool {
    const key = (try windowsOpen(path)) orelse return false;
    defer _ = win.RegCloseKey(key);
    var value: [identity.max_id_bytes * 2]u8 = undefined;
    const owner = (try getValue(key, owner_value, &value)) orelse return false;
    return std.mem.eql(u8, owner, id);
}
/// Writes `<root>\DefaultIcon` and `<root>\shell\open\command`.
fn windowsHandlerKeys(root: []const []const u8, application: Application, command: []const u8) !void {
    var parts: [8][]const u8 = undefined;
    @memcpy(parts[0..root.len], root);
    if (application.icon) |icon| {
        parts[root.len] = "\\DefaultIcon";
        const key = try windowsCreate(parts[0 .. root.len + 1]);
        defer _ = win.RegCloseKey(key);
        try setValue(key, null, icon);
    }
    parts[root.len] = "\\shell\\open\\command";
    const key = try windowsCreate(parts[0 .. root.len + 1]);
    defer _ = win.RegCloseKey(key);
    try setValue(key, null, command);
}
fn progId(destination: []u8, application: Application, file_type: FileType) ![]u8 {
    return std.fmt.bufPrint(destination, "{s}.{s}", .{ application.id, file_type.extension[1..] });
}
fn windowsRegister(application: Application, options: RegisterOptions) !Report {
    if (comptime builtin.os.tag != .windows) unreachable;
    var command: [max_command_bytes]u8 = undefined;
    const line = try windowsCommand(&command, application.executable, &.{}, true);
    var label: [max_text_bytes + 8]u8 = undefined;
    for (application.url_schemes) |scheme| {
        if (!options.make_default and !try ownedBy(&.{ classes, scheme }, application.id)) {
            // A scheme key without our marker belongs to another application.
            if (try windowsOpen(&.{ classes, scheme })) |existing| {
                _ = win.RegCloseKey(existing);
                continue;
            }
        }
        const key = try windowsCreate(&.{ classes, scheme });
        defer _ = win.RegCloseKey(key);
        try setValue(key, null, try std.fmt.bufPrint(&label, "URL:{s}", .{application.name}));
        try setValue(key, "URL Protocol", "");
        try setValue(key, owner_value, application.id);
        try windowsHandlerKeys(&.{ classes, scheme }, application, line);
    }
    for (application.file_types) |file_type| {
        var prog: [40]u8 = undefined;
        const prog_id = try progId(&prog, application, file_type);
        {
            const key = try windowsCreate(&.{ classes, prog_id });
            defer _ = win.RegCloseKey(key);
            try setValue(key, null, file_type.description);
            try setValue(key, owner_value, application.id);
        }
        try windowsHandlerKeys(&.{ classes, prog_id }, application, line);
        {
            const key = try windowsCreate(&.{ classes, file_type.extension, "\\OpenWithProgids" });
            defer _ = win.RegCloseKey(key);
            try setValue(key, prog_id, "");
        }
        const key = try windowsCreate(&.{ classes, file_type.extension });
        defer _ = win.RegCloseKey(key);
        var current: [128]u8 = undefined;
        if (options.make_default) try setValue(key, null, prog_id);
        if ((try getValue(key, "Content Type", &current)) == null) try setValue(key, "Content Type", file_type.mime_type);
    }
    win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, win.SHCNF_IDLIST, null, null);
    return .{};
}
fn windowsUnregister(application: Application) !Report {
    if (comptime builtin.os.tag != .windows) unreachable;
    for (application.url_schemes) |scheme| {
        if (try ownedBy(&.{ classes, scheme }, application.id)) try windowsDeleteTree(&.{ classes, scheme });
    }
    for (application.file_types) |file_type| {
        var prog: [40]u8 = undefined;
        const prog_id = try progId(&prog, application, file_type);
        if (try ownedBy(&.{ classes, prog_id }, application.id)) try windowsDeleteTree(&.{ classes, prog_id });
        var path: [256]u8 = undefined;
        try windowsDeleteValue(try std.fmt.bufPrint(&path, "{s}{s}\\OpenWithProgids", .{ classes, file_type.extension }), prog_id);
        if (try windowsOpen(&.{ classes, file_type.extension })) |key| {
            defer _ = win.RegCloseKey(key);
            var current: [128]u8 = undefined;
            if (try getValue(key, null, &current)) |value| if (std.mem.eql(u8, value, prog_id)) {
                _ = win.RegDeleteValueW(key, null);
            };
        }
    }
    win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, win.SHCNF_IDLIST, null, null);
    return .{};
}

const example: Application = .{
    .id = "org.example.Notes",
    .name = "Example \\ Notes",
    .executable = "/opt/Example Notes/bin/notes%1",
    .icon = "org.example.Notes",
    .url_schemes = &.{ "example-notes", "web+notes" },
    .file_types = &.{.{ .extension = ".exnote", .mime_type = "application/x-example-note", .description = "Example <note> & \"draft\"" }},
    .categories = &.{ "Office", "Utility" },
};

test "desktop entries quote Exec arguments and declare handled types" {
    var buffer: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Version=1.5
        \\Name=Example \\ Notes
        \\Exec="/opt/Example Notes/bin/notes%%1" %U
        \\Terminal=false
        \\Icon=org.example.Notes
        \\Categories=Office;Utility;
        \\MimeType=x-scheme-handler/example-notes;x-scheme-handler/web+notes;application/x-example-note;
        \\
    , try desktopEntry(&buffer, example));
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Version=1.5
        \\Name=Notes
        \\Exec=/usr/bin/notes --hidden "two words" "" "a\\\\b" "\\"q\\"" "\\$HOME"
        \\Terminal=false
        \\X-GNOME-Autostart-enabled=true
        \\
    , try autostartEntry(&buffer, .{ .id = "org.example.Notes", .name = "Notes", .executable = "/usr/bin/notes", .arguments = &.{ "--hidden", "two words", "", "a\\b", "\"q\"", "$HOME" } }));
    try std.testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        \\  <mime-type type="application/x-example-note">
        \\    <comment>Example &lt;note&gt; &amp; &quot;draft&quot;</comment>
        \\    <glob pattern="*.exnote"/>
        \\  </mime-type>
        \\</mime-info>
        \\
    , try mimePackage(&buffer, example));
    // The system's own types stay the system's.
    var mixed = example;
    mixed.file_types = &.{ .{ .extension = ".md", .mime_type = "text/markdown", .description = "Markdown" }, .{ .extension = ".sketch", .mime_type = "application/x-example-sketch", .description = "Sketch" } };
    const package = try mimePackage(&buffer, mixed);
    try std.testing.expect(std.mem.indexOf(u8, package, "text/markdown") == null);
    try std.testing.expect(std.mem.indexOf(u8, package, "<mime-type type=\"application/x-example-sketch\">\n    <comment>Sketch</comment>\n    <glob pattern=\"*.sketch\"/>") != null);
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.ResultCapacityExceeded, desktopEntry(&small, example));
}

test "registration input is validated before any write" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try validateApplication(example);
    var bad = example;
    bad.url_schemes = &.{"Upper"};
    try std.testing.expectError(error.InvalidScheme, validateApplication(bad));
    bad.url_schemes = &.{ "dup", "dup" };
    try std.testing.expectError(error.DuplicateScheme, validateApplication(bad));
    bad = example;
    bad.file_types = &.{.{ .extension = "noext", .mime_type = "a/b", .description = "x" }};
    try std.testing.expectError(error.InvalidExtension, validateApplication(bad));
    bad.file_types = &.{.{ .extension = ".ok", .mime_type = "nobody", .description = "x" }};
    try std.testing.expectError(error.InvalidMimeType, validateApplication(bad));
    bad.file_types = &.{.{ .extension = ".ok", .mime_type = "a/b;c", .description = "x" }};
    try std.testing.expectError(error.InvalidMimeType, validateApplication(bad));
    bad = example;
    bad.name = "line\nbreak";
    try std.testing.expectError(error.InvalidText, validateApplication(bad));
    bad = example;
    bad.executable = "relative/notes";
    try std.testing.expectError(error.AbsolutePathRequired, validateApplication(bad));
    bad = example;
    bad.categories = &.{"Semi;colon"};
    try std.testing.expectError(error.InvalidCategory, validateApplication(bad));
}

test "mimeapps editing keeps foreign lines and owns only its entries" {
    const allocator = std.testing.allocator;
    const input =
        \\# user comment
        \\[Default Applications]
        \\text/plain=editor.desktop;
        \\x-scheme-handler/example-notes=other.desktop;org.example.Notes.desktop;
        \\
        \\[Removed Associations]
        \\application/x-example-note=org.example.Notes.desktop;viewer.desktop;
        \\
    ;
    const types = [_][]const u8{ "x-scheme-handler/example-notes", "application/x-example-note" };
    const registered = try editMimeApps(allocator, input, "org.example.Notes.desktop", &types, .register_default);
    defer allocator.free(registered);
    try std.testing.expectEqualStrings(
        \\# user comment
        \\[Default Applications]
        \\text/plain=editor.desktop;
        \\x-scheme-handler/example-notes=org.example.Notes.desktop;other.desktop;
        \\application/x-example-note=org.example.Notes.desktop;
        \\
        \\[Removed Associations]
        \\application/x-example-note=viewer.desktop;
        \\
        \\[Added Associations]
        \\x-scheme-handler/example-notes=org.example.Notes.desktop;
        \\application/x-example-note=org.example.Notes.desktop;
        \\
    , registered);
    const again = try editMimeApps(allocator, registered, "org.example.Notes.desktop", &types, .register_default);
    defer allocator.free(again);
    try std.testing.expectEqualStrings(registered, again);
    const removed = try editMimeApps(allocator, registered, "org.example.Notes.desktop", &types, .remove);
    defer allocator.free(removed);
    try std.testing.expectEqualStrings(
        \\# user comment
        \\[Default Applications]
        \\text/plain=editor.desktop;
        \\x-scheme-handler/example-notes=other.desktop;
        \\
        \\[Removed Associations]
        \\application/x-example-note=viewer.desktop;
        \\
        \\[Added Associations]
        \\
    , removed);
    const fresh = try editMimeApps(allocator, "", "a.desktop", &.{"x-scheme-handler/a"}, .register);
    defer allocator.free(fresh);
    try std.testing.expectEqualStrings("[Added Associations]\nx-scheme-handler/a=a.desktop;\n", fresh);
    const empty = try editMimeApps(allocator, "", "a.desktop", &.{"x-scheme-handler/a"}, .remove);
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "windows handler commands follow argv quoting" {
    var buffer: [512]u8 = undefined;
    const line = try windowsCommand(&buffer, "C:\\Program Files\\App\\app.exe", &.{ "--hidden", "", "a b", "tail\\", "q\"uote", "\\\"" }, false);
    try std.testing.expectEqualStrings("\"C:\\Program Files\\App\\app.exe\" \"--hidden\" \"\" \"a b\" \"tail\\\\\" \"q\\\"uote\" \"\\\\\\\"\"", line);
    var wide_line: [512]u16 = undefined;
    const units = try std.unicode.utf8ToUtf16Le(&wide_line, line);
    var args = try std.process.Args.Iterator.Windows.init(std.testing.allocator, wide_line[0..units]);
    defer args.deinit();
    try std.testing.expectEqualStrings("C:\\Program Files\\App\\app.exe", args.next().?);
    for ([_][]const u8{ "--hidden", "", "a b", "tail\\", "q\"uote", "\\\"" }) |expected| try std.testing.expectEqualStrings(expected, args.next().?);
    try std.testing.expect(args.next() == null);
    try std.testing.expectEqualStrings("\"C:\\a.exe\" \"%1\"", try windowsCommand(&buffer, "C:\\a.exe", &.{}, true));
}

test "file URLs convert to local paths" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/a b.txt", (try localPath("file:///home/me/a%20b.txt", &buffer)).?);
    try std.testing.expectEqualStrings("/x/中", (try localPath("FILE://localhost/x/%E4%B8%AD", &buffer)).?);
    try std.testing.expect((try localPath("/plain/path", &buffer)) == null);
    try std.testing.expect((try localPath("example-notes://open", &buffer)) == null);
    try std.testing.expectError(error.InvalidFileUrl, localPath("file://remote/x", &buffer));
    try std.testing.expectError(error.InvalidFileUrl, localPath("file:///a%00b", &buffer));
    try std.testing.expectError(error.InvalidFileUrl, localPath("file:///a%2", &buffer));
    try std.testing.expectError(error.InvalidFileUrl, localPath("file:///a?query", &buffer));
}
