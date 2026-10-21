const std = @import("std");
const host = @import("host.zig");

pub const file_name = "ziggurat-plugin.json";
pub const max_manifest_bytes = 64 * 1024;
pub const max_libraries = 16;
pub const max_files = 16;

/// Targets that a native library can be supplied for, as Zig names them.
pub const Target = enum {
    @"x86_64-windows",
    @"aarch64-windows",
    @"x86_64-linux",
    @"aarch64-linux",
    @"x86_64-macos",
    @"aarch64-macos",

    pub fn of(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag) ?Target {
        return switch (os) {
            .windows => switch (arch) {
                .x86_64 => .@"x86_64-windows",
                .aarch64 => .@"aarch64-windows",
                else => null,
            },
            .linux => switch (arch) {
                .x86_64 => .@"x86_64-linux",
                .aarch64 => .@"aarch64-linux",
                else => null,
            },
            .macos => switch (arch) {
                .x86_64 => .@"x86_64-macos",
                .aarch64 => .@"aarch64-macos",
                else => null,
            },
            else => null,
        };
    }
};

/// One file of a native library for one target. Exactly one of `path` (relative
/// to the manifest, inside the plugin) and `url` (https, with sha256) is set.
pub const File = struct {
    /// The file name placed beside the application's executable.
    name: []const u8,
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    /// Lowercase hex SHA-256 of the file's bytes; required with url.
    sha256: ?[]const u8 = null,
};

pub const TargetFile = struct { target: Target, file: File };
pub const Library = struct {
    name: []const u8,
    files: []const TargetFile,
};

/// What a plugin ships beside its Zig module: the JavaScript package its pages
/// import, and native libraries the application distributes with itself.
pub const Manifest = struct {
    /// The plugin's name, as given to Host.use; pages reach "plugin:<name>".
    name: []const u8,
    /// The npm package of the page half, e.g. "@ziggurat/plugin-sqlite".
    package: ?[]const u8 = null,
    libraries: []const Library = &.{},

    /// The library files to ship for one target, in manifest order.
    pub fn filesFor(self: *const Manifest, target: Target, out: []File) ![]File {
        var count: usize = 0;
        for (self.libraries) |library| {
            for (library.files) |entry| if (entry.target == target) {
                if (count == out.len) return error.BufferTooSmall;
                out[count] = entry.file;
                count += 1;
            };
        }
        return out[0..count];
    }
};

/// Names the offending field; copied, so it outlives the failed parse.
pub const Diagnostic = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,
    pub fn field(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Parsed manifests own their strings; deinit frees them.
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    manifest: Manifest,
    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Strict: unknown fields, duplicate names, missing hashes, non-https URLs,
/// absolute or escaping paths and file names with separators are rejected.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, diagnostic: ?*Diagnostic) !Parsed {
    if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var unused: Diagnostic = .{};
    const d = diagnostic orelse &unused;
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .duplicate_field_behavior = .@"error" }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return fail(d, "");
    };
    const root = try object(value, &.{ "name", "package", "libraries" }, d, "");
    const name = try string(root, "name", d) orelse return fail(d, "name");
    if (!host.validName(name)) return fail(d, "name");
    const package = try string(root, "package", d);
    if (package) |text| if (!validPackage(text)) return fail(d, "package");
    var libraries: std.ArrayList(Library) = .empty;
    if (root.get("libraries")) |list| {
        if (list != .array or list.array.items.len > max_libraries) return fail(d, "libraries");
        for (list.array.items) |item| {
            const library = try object(item, &.{ "name", "files" }, d, "libraries");
            const library_name = try string(library, "name", d) orelse return fail(d, "libraries.name");
            if (!validFileName(library_name)) return fail(d, "libraries.name");
            for (libraries.items) |previous| if (std.mem.eql(u8, previous.name, library_name)) return fail(d, "libraries.name");
            const files_value = library.get("files") orelse return fail(d, "libraries.files");
            if (files_value != .object or files_value.object.count() == 0 or files_value.object.count() > max_files) return fail(d, "libraries.files");
            const files = try a.alloc(TargetFile, files_value.object.count());
            var iterator = files_value.object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                const target = std.meta.stringToEnum(Target, entry.key_ptr.*) orelse return fail(d, "libraries.files");
                const file = try object(entry.value_ptr.*, &.{ "name", "path", "url", "sha256" }, d, "libraries.files");
                const result: File = .{
                    .name = try string(file, "name", d) orelse return fail(d, "libraries.files.name"),
                    .path = try string(file, "path", d),
                    .url = try string(file, "url", d),
                    .sha256 = try string(file, "sha256", d),
                };
                try validateFile(result, d);
                files[index] = .{ .target = target, .file = result };
            }
            try libraries.append(a, .{ .name = library_name, .files = files });
        }
    }
    return .{ .arena = arena, .manifest = .{ .name = name, .package = package, .libraries = libraries.items } };
}

fn fail(d: *Diagnostic, field: []const u8) error{InvalidManifest} {
    d.len = @min(field.len, d.buffer.len);
    @memcpy(d.buffer[0..d.len], field[0..d.len]);
    return error.InvalidManifest;
}

fn object(value: std.json.Value, allowed: []const []const u8, d: *Diagnostic, field: []const u8) !std.json.ObjectMap {
    if (value != .object) return fail(d, field);
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) break;
        } else return fail(d, entry.key_ptr.*);
    }
    return value.object;
}

fn string(map: std.json.ObjectMap, name: []const u8, d: *Diagnostic) !?[]const u8 {
    const value = map.get(name) orelse return null;
    if (value != .string or value.string.len == 0 or value.string.len > 2048) return fail(d, name);
    for (value.string) |c| if (c < 0x20 or c == 0x7f) return fail(d, name);
    return value.string;
}

fn validPackage(text: []const u8) bool {
    if (text.len > 214) return false;
    var rest = text;
    if (rest[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        if (!validPackagePart(rest[1..slash])) return false;
        rest = rest[slash + 1 ..];
    }
    return validPackagePart(rest);
}

fn validPackagePart(text: []const u8) bool {
    if (text.len == 0 or text[0] == '.' or text[0] == '_') return false;
    for (text) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '.' and c != '_') return false;
    return true;
}

fn validFileName(text: []const u8) bool {
    if (text.len > 255 or std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    for (text) |c| if (c == '/' or c == '\\' or c == ':') return false;
    return true;
}

fn validateFile(file: File, d: *Diagnostic) !void {
    if (!validFileName(file.name)) return fail(d, "libraries.files.name");
    if ((file.path == null) == (file.url == null)) return fail(d, "libraries.files");
    if (file.path) |path| {
        if (std.fs.path.isAbsolutePosix(path) or std.fs.path.isAbsoluteWindows(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return fail(d, "libraries.files.path");
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return fail(d, "libraries.files.path");
        if (file.sha256 != null) try validHash(file.sha256.?, d);
    }
    if (file.url) |url| {
        const uri = std.Uri.parse(url) catch return fail(d, "libraries.files.url");
        if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null) return fail(d, "libraries.files.url");
        try validHash(file.sha256 orelse return fail(d, "libraries.files.sha256"), d);
    }
}

fn validHash(text: []const u8, d: *Diagnostic) !void {
    if (text.len != 64) return fail(d, "libraries.files.sha256");
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return fail(d, "libraries.files.sha256");
}

test "manifests list the files of a target" {
    const allocator = std.testing.allocator;
    var parsed = try parse(allocator,
        \\{"name":"vault","package":"@acme/vault-page","libraries":[{"name":"vault-core","files":{
        \\  "x86_64-linux":{"name":"libvault.so","path":"native/linux-x64/libvault.so"},
        \\  "x86_64-windows":{"name":"vault.dll","url":"https://example.com/vault.dll","sha256":"9b98b6d304a3f76cfe517340c5aae83d0e1835b680a056600d5ae3ac19bd4067"}}}]}
    , null);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("vault", parsed.manifest.name);
    var out: [4]File = undefined;
    const linux = try parsed.manifest.filesFor(.@"x86_64-linux", &out);
    try std.testing.expectEqual(1, linux.len);
    try std.testing.expectEqualStrings("native/linux-x64/libvault.so", linux[0].path.?);
    try std.testing.expectEqual(0, (try parsed.manifest.filesFor(.@"aarch64-macos", &out)).len);
    try std.testing.expectEqual(Target.@"x86_64-windows", Target.of(.x86_64, .windows).?);
}

test "manifests reject what cannot ship safely" {
    const allocator = std.testing.allocator;
    const hash = "9b98b6d304a3f76cfe517340c5aae83d0e1835b680a056600d5ae3ac19bd4067";
    const cases = [_]struct { json: []const u8, field: []const u8 }{
        .{ .json = "{\"name\":\"Bad\"}", .field = "name" },
        .{ .json = "{\"name\":\"ok\",\"extra\":1}", .field = "extra" },
        .{ .json = "{\"name\":\"ok\",\"package\":\"Upper\"}", .field = "package" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"a.so\",\"url\":\"http://e.com/a\",\"sha256\":\"" ++ hash ++ "\"}}}]}", .field = "libraries.files.url" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"a.so\",\"url\":\"https://e.com/a\"}}}]}", .field = "libraries.files.sha256" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"a.so\",\"path\":\"../a.so\"}}}]}", .field = "libraries.files.path" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"sub/a.so\",\"path\":\"a.so\"}}}]}", .field = "libraries.files.name" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"riscv-linux\":{\"name\":\"a.so\",\"path\":\"a.so\"}}}]}", .field = "libraries.files" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"a.so\",\"path\":\"a.so\",\"url\":\"https://e.com/a\",\"sha256\":\"" ++ hash ++ "\"}}}]}", .field = "libraries.files" },
        .{ .json = "{\"name\":\"ok\",\"libraries\":[{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"a.so\",\"path\":\"a.so\"}}},{\"name\":\"a\",\"files\":{\"x86_64-linux\":{\"name\":\"b.so\",\"path\":\"b.so\"}}}]}", .field = "libraries.name" },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidManifest, parse(allocator, case.json, &diagnostic));
        try std.testing.expectEqualStrings(case.field, diagnostic.field());
    }
    try std.testing.expectError(error.InvalidManifest, parse(allocator, "{\"name\":\"a\",\"name\":\"b\"}", null));
}
