//! macOS distribution: the `.app` bundle (Info.plist, PkgInfo, icon,
//! localizations, provisioning profile), universal executables, code
//! signing, disk images and notarization. Bundles, Info.plist and universal
//! executables are written anywhere; signing, disk images and notarization
//! run the tools of macOS (codesign, hdiutil, xcrun) and need a Mac.
const std = @import("std");
const builtin = @import("builtin");
const icon = @import("icon.zig");
const dsstore = @import("dsstore.zig");

/// `macos` in ziggurat.json.
pub const MacOS = struct {
    /// The app's icon on macOS in place of the one rendered from `icon`: an
    /// `.icns` drawn per size, an `Assets.car` compiled with actool whose app
    /// icon is named AppIcon, or an Icon Composer `.icon`, which builds
    /// compile on a Mac with Xcode 26 or later and skip elsewhere.
    icon: ?[]const u8 = null,
    /// The oldest macOS the app runs on, which is also the oldest Zig
    /// targets.
    minimumSystemVersion: []const u8 = default_minimum_system_version,
    /// Signs the app and the disk image, e.g. "Developer ID Application:
    /// Jane Doe (TEAMID)". "-" signs ad hoc: the app runs on the Mac that
    /// built it, but Gatekeeper blocks it on others.
    signingIdentity: []const u8 = "-",
    /// A property list of entitlements to sign the app with.
    entitlements: ?[]const u8 = null,
    /// Embedded as Contents/embedded.provisionprofile before signing. It
    /// must authorize the app's identity and entitlements and match its
    /// signing identity; ad-hoc signing cannot use a profile.
    provisioningProfile: ?[]const u8 = null,
    /// Extra keys of Info.plist, which replace the framework's own, such as
    /// usage descriptions: "NSCameraUsageDescription": "Scan documents."
    infoPlist: ?std.json.Value = null,
    /// The volume name of the disk image (default: the app's name).
    dmgTitle: ?[]const u8 = null,
    /// Submits disk images to Apple's notary service and staples the
    /// ticket. It needs a Developer ID signing identity.
    notarize: ?Notarize = null,

    /// notarytool credentials stored in the keychain with
    /// `xcrun notarytool store-credentials PROFILE`.
    pub const Notarize = struct {
        keychainProfile: []const u8,
        /// The keychain holding the profile (default: the login keychain).
        keychain: ?[]const u8 = null,
    };
};

pub const default_minimum_system_version = "13.0";

/// A type of file the app opens: Finder offers it for files with these
/// extensions.
pub const FileAssociation = struct {
    /// Extensions without the dot.
    ext: []const []const u8,
    /// Shown by Finder (default: "EXT file").
    name: ?[]const u8 = null,
    /// "Editor" (the default) or "Viewer".
    role: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// A language the app ships: a catalog of its messages.
pub const Language = struct {
    /// BCP 47, as the catalog's file name has it.
    tag: []const u8,
    /// The app's name in the language, where the catalog gives one.
    name: ?[]const u8 = null,
};

/// What a bundle says about the app.
pub const App = struct {
    name: []const u8,
    identity: []const u8,
    /// Four numbers, as ziggurat.json's.
    version: []const u8,
    copyright: ?[]const u8 = null,
    url_schemes: []const []const u8 = &.{},
    file_associations: []const FileAssociation = &.{},
    macos: MacOS = .{},
    /// The app's own language first.
    languages: []const Language = &.{},
};

pub const icon_file = "AppIcon.icns";
pub const icon_name = "AppIcon";
pub const catalog_file = "Assets.car";

/// `name` usable as a file name everywhere.
pub fn fileName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, name, " \t");
    const out = try allocator.dupe(u8, trimmed);
    for (out) |*byte| if (byte.* < ' ' or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", byte.*) != null) {
        byte.* = '-';
    };
    if (out.len == 0) {
        allocator.free(out);
        return allocator.dupe(u8, "app");
    }
    return out;
}

/// CFBundleShortVersionString: the first three numbers.
pub fn shortVersion(version: []const u8) []const u8 {
    var dots: usize = 0;
    for (version, 0..) |byte, index| if (byte == '.') {
        dots += 1;
        if (dots == 3) return version[0..index];
    };
    return version;
}

/// CFBundleVersion: three numbers, or four when the fourth is not 0.
pub fn bundleVersion(version: []const u8) []const u8 {
    const short = shortVersion(version);
    if (short.len < version.len and std.mem.eql(u8, version[short.len + 1 ..], "0")) return short;
    return version;
}

const TagParts = struct { language: []const u8, script: []const u8 = "", region: []const u8 = "" };

/// The language, script and region of a BCP 47 tag, with Chinese given its
/// script by its region.
fn tagParts(buffer: []u8, tag: []const u8) TagParts {
    const length = @min(buffer.len, tag.len);
    @memcpy(buffer[0..length], tag[0..length]);
    var parts = std.mem.tokenizeAny(u8, buffer[0..length], "-_");
    const language: []u8 = @constCast(parts.next() orelse return .{ .language = "" });
    for (language) |*byte| byte.* = std.ascii.toLower(byte.*);
    var result: TagParts = .{ .language = language };
    while (parts.next()) |part| {
        const subtag = @constCast(part);
        if (subtag.len == 4 and result.script.len == 0 and result.region.len == 0) {
            subtag[0] = std.ascii.toUpper(subtag[0]);
            for (subtag[1..]) |*byte| byte.* = std.ascii.toLower(byte.*);
            result.script = subtag;
        } else if (result.region.len == 0 and (subtag.len == 2 or (subtag.len == 3 and std.ascii.isDigit(subtag[0])))) {
            for (subtag) |*byte| byte.* = std.ascii.toUpper(byte.*);
            result.region = subtag;
        }
    }
    if (std.mem.eql(u8, result.language, "zh") and result.script.len == 0) {
        const traditional = std.mem.eql(u8, result.region, "TW") or std.mem.eql(u8, result.region, "HK") or std.mem.eql(u8, result.region, "MO");
        result.script = if (traditional) "Hant" else "Hans";
    }
    return result;
}

/// The name of a tag's localization folder in a bundle, as Xcode names
/// them: the language with its script or its region, as zh-Hans, sr-Latn
/// and pt-BR. Chinese is named by its script, but Hong Kong's is zh-HK.
pub fn lprojName(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    var buffer: [64]u8 = undefined;
    const parts = tagParts(&buffer, tag);
    if (std.mem.eql(u8, parts.language, "zh")) {
        if (std.mem.eql(u8, parts.region, "HK")) return allocator.dupe(u8, "zh-HK");
        return std.fmt.allocPrint(allocator, "zh-{s}", .{if (std.mem.eql(u8, parts.script, "Hant")) "Hant" else "Hans"});
    }
    if (parts.script.len > 0) return std.fmt.allocPrint(allocator, "{s}-{s}", .{ parts.language, parts.script });
    if (parts.region.len > 0) return std.fmt.allocPrint(allocator, "{s}-{s}", .{ parts.language, parts.region });
    return allocator.dupe(u8, parts.language);
}

/// A property list value: what Info.plist holds.
const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    array: []const Value,
    dict: []const Entry,
    json: std.json.Value,
};
const Entry = struct { key: []const u8, value: Value };

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        else => try writer.writeByte(byte),
    };
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeByte('\t');
}

fn writeDict(allocator: std.mem.Allocator, writer: *std.Io.Writer, entries: []const Entry, depth: usize) !void {
    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.sort.insertion(Entry, sorted, {}, lessEntry);
    try writeIndent(writer, depth);
    try writer.writeAll("<dict>\n");
    for (sorted) |entry| {
        try writeIndent(writer, depth + 1);
        try writer.writeAll("<key>");
        try writeEscaped(writer, entry.key);
        try writer.writeAll("</key>\n");
        try writeValue(allocator, writer, entry.value, depth + 1);
    }
    try writeIndent(writer, depth);
    try writer.writeAll("</dict>\n");
}

fn writeValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: Value, depth: usize) anyerror!void {
    switch (value) {
        .string => |text| {
            try writeIndent(writer, depth);
            try writer.writeAll("<string>");
            try writeEscaped(writer, text);
            try writer.writeAll("</string>\n");
        },
        .boolean => |flag| {
            try writeIndent(writer, depth);
            try writer.writeAll(if (flag) "<true/>\n" else "<false/>\n");
        },
        .array => |items| {
            try writeIndent(writer, depth);
            try writer.writeAll("<array>\n");
            for (items) |item| try writeValue(allocator, writer, item, depth + 1);
            try writeIndent(writer, depth);
            try writer.writeAll("</array>\n");
        },
        .dict => |entries| try writeDict(allocator, writer, entries, depth),
        .json => |json| switch (json) {
            .null => try writeValue(allocator, writer, .{ .string = "" }, depth),
            .bool => |flag| try writeValue(allocator, writer, .{ .boolean = flag }, depth),
            .integer => |number| {
                try writeIndent(writer, depth);
                try writer.print("<integer>{d}</integer>\n", .{number});
            },
            .float => |number| {
                try writeIndent(writer, depth);
                // Whole numbers are integers, as JSON does not tell them apart.
                if (number == @trunc(number) and @abs(number) < 1 << 53) {
                    try writer.print("<integer>{d}</integer>\n", .{@as(i64, @intFromFloat(number))});
                } else try writer.print("<real>{d}</real>\n", .{number});
            },
            .number_string => |text| {
                try writeIndent(writer, depth);
                try writer.print("<integer>{s}</integer>\n", .{text});
            },
            .string => |text| try writeValue(allocator, writer, .{ .string = text }, depth),
            .array => |items| {
                const values = try allocator.alloc(Value, items.items.len);
                defer allocator.free(values);
                for (items.items, values) |item, *out| out.* = .{ .json = item };
                try writeValue(allocator, writer, .{ .array = values }, depth);
            },
            .object => |object| {
                const entries = try allocator.alloc(Entry, object.count());
                defer allocator.free(entries);
                var iterator = object.iterator();
                var index: usize = 0;
                while (iterator.next()) |pair| : (index += 1) entries[index] = .{ .key = pair.key_ptr.*, .value = .{ .json = pair.value_ptr.* } };
                try writeDict(allocator, writer, entries, depth);
            },
        },
    }
}

const plist_header =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\
;

fn plist(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(plist_header);
    try writeDict(allocator, &out.writer, entries, 0);
    try out.writer.writeAll("</plist>\n");
    return out.toOwnedSlice();
}

fn put(list: *std.ArrayList(Entry), allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
    for (list.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
        entry.value = value;
        return;
    };
    try list.append(allocator, .{ .key = key, .value = value });
}

/// The bundle's Info.plist, with `icon_file` and `icon_name` when the bundle
/// has an .icns and an asset catalog. The keys of `macos.infoPlist` win.
pub fn infoPlist(allocator: std.mem.Allocator, app: App, executable: []const u8, icns: bool, catalog: bool) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    const fixed = [_]Entry{
        .{ .key = "CFBundleName", .value = .{ .string = app.name } },
        .{ .key = "CFBundleDisplayName", .value = .{ .string = app.name } },
        .{ .key = "CFBundleIdentifier", .value = .{ .string = app.identity } },
        .{ .key = "CFBundleVersion", .value = .{ .string = bundleVersion(app.version) } },
        .{ .key = "CFBundleShortVersionString", .value = .{ .string = shortVersion(app.version) } },
        .{ .key = "CFBundleExecutable", .value = .{ .string = executable } },
        .{ .key = "CFBundlePackageType", .value = .{ .string = "APPL" } },
        .{ .key = "CFBundleInfoDictionaryVersion", .value = .{ .string = "6.0" } },
        .{ .key = "LSMinimumSystemVersion", .value = .{ .string = app.macos.minimumSystemVersion } },
        .{ .key = "NSPrincipalClass", .value = .{ .string = "NSApplication" } },
        .{ .key = "NSHighResolutionCapable", .value = .{ .boolean = true } },
        .{ .key = "NSSupportsAutomaticGraphicsSwitching", .value = .{ .boolean = true } },
    };
    try entries.appendSlice(arena, &fixed);
    if (app.languages.len > 0) {
        // The app's own language, which the system falls back to, and those
        // it ships, which AppKit picks the language of its own texts among.
        try put(&entries, arena, "CFBundleDevelopmentRegion", .{ .string = try lprojName(arena, app.languages[0].tag) });
        var names: std.ArrayList(Value) = .empty;
        for (app.languages) |language| {
            const name = try lprojName(arena, language.tag);
            for (names.items) |known| {
                if (std.mem.eql(u8, known.string, name)) break;
            } else try names.append(arena, .{ .string = name });
        }
        try put(&entries, arena, "CFBundleLocalizations", .{ .array = names.items });
    }
    if (icns) try put(&entries, arena, "CFBundleIconFile", .{ .string = icon_file });
    if (catalog) try put(&entries, arena, "CFBundleIconName", .{ .string = icon_name });
    if (app.copyright) |text| try put(&entries, arena, "NSHumanReadableCopyright", .{ .string = text });
    if (app.file_associations.len > 0) {
        const documents = try arena.alloc(Value, app.file_associations.len);
        for (app.file_associations, documents) |association, *out| {
            const extensions = try arena.alloc(Value, association.ext.len);
            for (association.ext, extensions) |ext, *value| value.* = .{ .string = ext };
            const first = if (association.ext.len > 0) association.ext[0] else "";
            const name = association.name orelse try std.fmt.allocPrint(arena, "{s} file", .{try std.ascii.allocUpperString(arena, first)});
            var document: std.ArrayList(Entry) = .empty;
            try document.appendSlice(arena, &.{
                .{ .key = "CFBundleTypeName", .value = .{ .string = name } },
                .{ .key = "CFBundleTypeRole", .value = .{ .string = association.role orelse "Editor" } },
                .{ .key = "LSHandlerRank", .value = .{ .string = "Default" } },
                .{ .key = "CFBundleTypeExtensions", .value = .{ .array = extensions } },
            });
            if (association.mimeType) |mime| {
                const types = try arena.alloc(Value, 1);
                types[0] = .{ .string = mime };
                try document.append(arena, .{ .key = "CFBundleTypeMIMETypes", .value = .{ .array = types } });
            }
            out.* = .{ .dict = document.items };
        }
        try put(&entries, arena, "CFBundleDocumentTypes", .{ .array = documents });
    }
    if (app.url_schemes.len > 0) {
        const schemes = try arena.alloc(Value, app.url_schemes.len);
        for (app.url_schemes, schemes) |scheme, *out| out.* = .{ .string = scheme };
        const types = try arena.alloc(Value, 1);
        types[0] = .{ .dict = try arena.dupe(Entry, &.{
            .{ .key = "CFBundleURLName", .value = .{ .string = app.identity } },
            .{ .key = "CFBundleURLSchemes", .value = .{ .array = schemes } },
        }) };
        try put(&entries, arena, "CFBundleURLTypes", .{ .array = types });
    }
    if (app.macos.infoPlist) |extra| switch (extra) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |pair| try put(&entries, arena, pair.key_ptr.*, .{ .json = pair.value_ptr.* });
        },
        else => return error.InvalidInfoPlist,
    };
    return plist(allocator, entries.items);
}

/// The InfoPlist.strings of a localization: the app's name in its language.
pub fn localizedStrings(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return plist(allocator, &.{
        .{ .key = "CFBundleDisplayName", .value = .{ .string = name } },
        .{ .key = "CFBundleName", .value = .{ .string = name } },
    });
}

/// What goes into a bundle besides Info.plist.
pub const BundleContents = struct {
    /// The executable, thin or universal.
    executable: []const u8,
    icns: ?[]const u8 = null,
    /// A compiled asset catalog, Assets.car.
    catalog: ?[]const u8 = null,
    provisioning_profile: ?[]const u8 = null,
};

/// Writes `<name>.app` into `parent`, replacing an older one, and returns
/// its file name.
pub fn writeBundle(allocator: std.mem.Allocator, parent: std.fs.Dir, app: App, contents: BundleContents) ![]u8 {
    const name = try fileName(allocator, app.name);
    defer allocator.free(name);
    const bundle = try std.fmt.allocPrint(allocator, "{s}.app", .{name});
    errdefer allocator.free(bundle);
    try parent.deleteTree(bundle);
    var root = try parent.makeOpenPath(bundle, .{});
    defer root.close();
    try root.makePath("Contents/MacOS");
    try root.makePath("Contents/Resources");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try root.writeFile(.{ .sub_path = try std.fmt.bufPrint(&buffer, "Contents/MacOS/{s}", .{name}), .data = contents.executable, .flags = .{ .mode = 0o755 } });
    if (contents.provisioning_profile) |profile| try root.writeFile(.{ .sub_path = "Contents/embedded.provisionprofile", .data = profile });
    if (contents.icns) |bytes| try root.writeFile(.{ .sub_path = "Contents/Resources/" ++ icon_file, .data = bytes });
    if (contents.catalog) |bytes| try root.writeFile(.{ .sub_path = "Contents/Resources/" ++ catalog_file, .data = bytes });
    for (app.languages) |language| {
        const folder = try lprojName(allocator, language.tag);
        defer allocator.free(folder);
        const path = try std.fmt.bufPrint(&buffer, "Contents/Resources/{s}.lproj", .{folder});
        try root.makePath(path);
        const localized = language.name orelse continue;
        if (std.mem.eql(u8, localized, app.name)) continue;
        const strings = try localizedStrings(allocator, localized);
        defer allocator.free(strings);
        try root.writeFile(.{ .sub_path = try std.fmt.bufPrint(&buffer, "Contents/Resources/{s}.lproj/InfoPlist.strings", .{folder}), .data = strings });
    }
    const info = try infoPlist(allocator, app, name, contents.icns != null, contents.catalog != null);
    defer allocator.free(info);
    try root.writeFile(.{ .sub_path = "Contents/Info.plist", .data = info });
    try root.writeFile(.{ .sub_path = "Contents/PkgInfo", .data = "APPL????" });
    return bundle;
}

// ---------------------------------------------------------------- Mach-O

const mach_o_64 = 0xfeedfacf;
const fat_magic = 0xcafebabe;
const fat_align = 14; // 2^14 = 16 KiB

pub const Arch = enum {
    aarch64,
    x86_64,

    pub fn cpuType(self: Arch) u32 {
        return switch (self) {
            .aarch64 => 0x0100000c,
            .x86_64 => 0x01000007,
        };
    }
};

/// The architecture of a thin 64-bit Mach-O executable.
pub fn machOArch(bytes: []const u8) !Arch {
    if (bytes.len < 12 or std.mem.readInt(u32, bytes[0..4], .little) != mach_o_64) return error.NotMachO;
    const cpu = std.mem.readInt(u32, bytes[4..8], .little);
    inline for (std.meta.fields(Arch)) |field| if (cpu == @as(Arch, @enumFromInt(field.value)).cpuType()) return @enumFromInt(field.value);
    return error.UnsupportedArchitecture;
}

/// Combines thin 64-bit Mach-O executables into one universal (fat)
/// executable, as lipo does, so no Xcode tools are needed.
pub fn writeUniversal(allocator: std.mem.Allocator, slices: []const []const u8) ![]u8 {
    if (slices.len == 0) return error.NoSlices;
    for (slices, 0..) |slice, index| {
        const arch = try machOArch(slice);
        for (slices[0..index]) |other| if (try machOArch(other) == arch) return error.DuplicateArchitecture;
    }
    const page = @as(usize, 1) << fat_align;
    var offset = page;
    var total = page;
    for (slices) |slice| total = std.mem.alignForward(usize, total, page) + slice.len;
    if (total > std.math.maxInt(u32)) return error.UniversalTooLarge;
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], fat_magic, .big);
    std.mem.writeInt(u32, out[4..8], @intCast(slices.len), .big);
    for (slices, 0..) |slice, index| {
        const header = out[8 + 20 * index ..][0..20];
        std.mem.writeInt(u32, header[0..4], std.mem.readInt(u32, slice[4..8], .little), .big);
        std.mem.writeInt(u32, header[4..8], std.mem.readInt(u32, slice[8..12], .little), .big);
        std.mem.writeInt(u32, header[8..12], @intCast(offset), .big);
        std.mem.writeInt(u32, header[12..16], @intCast(slice.len), .big);
        std.mem.writeInt(u32, header[16..20], fat_align, .big);
        @memcpy(out[offset..][0..slice.len], slice);
        offset = std.mem.alignForward(usize, offset + slice.len, page);
    }
    return out;
}

/// The architectures of a universal executable, in order.
pub fn universalArchs(allocator: std.mem.Allocator, bytes: []const u8) ![]Arch {
    if (bytes.len < 8 or std.mem.readInt(u32, bytes[0..4], .big) != fat_magic) return error.NotUniversal;
    const count = std.mem.readInt(u32, bytes[4..8], .big);
    if (bytes.len < 8 + 20 * @as(usize, count)) return error.NotUniversal;
    const archs = try allocator.alloc(Arch, count);
    errdefer allocator.free(archs);
    for (archs, 0..) |*arch, index| {
        const header = bytes[8 + 20 * index ..][0..20];
        const offset = std.mem.readInt(u32, header[8..12], .big);
        const size = std.mem.readInt(u32, header[12..16], .big);
        if (@as(usize, offset) + size > bytes.len) return error.NotUniversal;
        arch.* = try machOArch(bytes[offset..][0..size]);
    }
    return archs;
}

// ---------------------------------------------------------------- signing

/// The arguments of codesign that sign `path`. Real identities get the
/// hardened runtime and a secure timestamp, which notarization requires.
pub fn codesignArgs(allocator: std.mem.Allocator, path: []const u8, identity: []const u8, entitlements: ?[]const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{ "codesign", "--force", "--deep", "--sign", identity });
    if (!std.mem.eql(u8, identity, "-")) try args.appendSlice(allocator, &.{ "--options", "runtime", "--timestamp" });
    if (entitlements) |file| try args.appendSlice(allocator, &.{ "--entitlements", file });
    try args.append(allocator, path);
    return args.toOwnedSlice(allocator);
}

/// Output of a finished tool.
pub const Output = struct {
    ok: bool,
    /// Its standard output, then its errors.
    text: []const u8,
};

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !Output {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 16 * 1024 * 1024 }) catch |err| {
        return .{ .ok = false, .text = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ argv[0], @errorName(err) }) };
    };
    const ok = result.term == .Exited and result.term.Exited == 0;
    return .{ .ok = ok, .text = try std.mem.concat(allocator, u8, &.{ result.stdout, result.stderr }) };
}

/// Runs a tool, printing what it said when it fails.
pub fn command(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const output = try run(allocator, argv);
    if (output.ok) return;
    std.debug.print("ziggurat: {s} failed\n{s}\n", .{ try std.mem.join(allocator, " ", argv), std.mem.trim(u8, output.text, " \r\n") });
    return error.CommandFailed;
}

/// Signs a bundle (or another file). Signing needs macOS: elsewhere a
/// warning says a real identity was not used, and arm64 executables keep the
/// ad-hoc signature of the Zig linker.
pub fn codesign(allocator: std.mem.Allocator, path: []const u8, identity: []const u8, entitlements: ?[]const u8, provisioning_profile: bool) !void {
    if (provisioning_profile and std.mem.eql(u8, identity, "-")) return error.ProvisioningProfileNeedsIdentity;
    if (builtin.os.tag != .macos) {
        if (!std.mem.eql(u8, identity, "-")) std.debug.print("ziggurat: not signing {s}: code signing needs macOS\n", .{std.fs.path.basename(path)});
        return;
    }
    try command(allocator, try codesignArgs(allocator, path, identity, entitlements));
}

// ---------------------------------------------------------------- icon

/// Compiles an Icon Composer `.icon` with actool (Xcode 26 or later) into an
/// asset catalog with the .icns actool renders from it for older systems.
pub fn compileIcon(allocator: std.mem.Allocator, source: []const u8, minimum_system_version: []const u8) !struct { catalog: []u8, icns: []u8 } {
    if (builtin.os.tag != .macos) return error.NeedsMacOS;
    var temporary = try TempDir.create(allocator, null, "ziggurat-actool");
    defer temporary.remove();
    // actool names the icon after the document, AppIcon in every app.
    const document = try std.fs.path.join(allocator, &.{ temporary.path, icon_name ++ ".icon" });
    try command(allocator, &.{ "/bin/cp", "-R", source, document });
    const out = try std.fs.path.join(allocator, &.{ temporary.path, "out" });
    try std.fs.cwd().makePath(out);
    const output = try run(allocator, &.{ "xcrun", "actool", document, "--compile", out, "--output-format", "human-readable-text", "--platform", "macosx", "--target-device", "mac", "--minimum-deployment-target", minimum_system_version, "--app-icon", icon_name, "--output-partial-info-plist", try std.fs.path.join(allocator, &.{ out, "partial.plist" }) });
    var dir = try std.fs.cwd().openDir(out, .{});
    defer dir.close();
    const catalog = dir.readFileAlloc(allocator, catalog_file, 64 * 1024 * 1024) catch null;
    const icns = dir.readFileAlloc(allocator, icon_name ++ ".icns", 64 * 1024 * 1024) catch null;
    if (!output.ok or catalog == null or icns == null) {
        std.debug.print("ziggurat: actool could not compile {s} (it needs Xcode 26 or later)\n{s}\n", .{ source, std.mem.trim(u8, output.text, " \r\n") });
        return error.IconNotCompiled;
    }
    return .{ .catalog = catalog.?, .icns = icns.? };
}

/// The bundle's icon: `macos.icon` as an .icns or a catalog, else `png`
/// (the project's icon) rendered as .icns.
pub fn bundleIcons(allocator: std.mem.Allocator, project: std.fs.Dir, macos: MacOS, png: ?[]const u8) !struct { icns: ?[]const u8 = null, catalog: ?[]const u8 = null } {
    var rendered: ?[]const u8 = null;
    if (png) |bytes| rendered = try icon.pngToIcns(allocator, bytes);
    const source = macos.icon orelse return .{ .icns = rendered };
    const extension = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(extension, ".icns")) {
        const bytes = try project.readFileAlloc(allocator, source, 64 * 1024 * 1024);
        if (!std.mem.startsWith(u8, bytes, "icns")) return error.IconNotIcns;
        return .{ .icns = bytes };
    }
    if (std.ascii.eqlIgnoreCase(extension, ".icon")) {
        const path = try project.realpathAlloc(allocator, source);
        const compiled = compileIcon(allocator, path, macos.minimumSystemVersion) catch |err| {
            std.debug.print("ziggurat: skipping {s}: {s}\n", .{ source, if (err == error.NeedsMacOS) "compiling it needs macOS with Xcode 26 or later" else @errorName(err) });
            return .{ .icns = rendered };
        };
        return .{ .icns = compiled.icns, .catalog = compiled.catalog };
    }
    if (std.ascii.eqlIgnoreCase(extension, ".car")) return .{ .icns = rendered, .catalog = try project.readFileAlloc(allocator, source, 64 * 1024 * 1024) };
    return error.UnknownIconType;
}

// ---------------------------------------------------------------- disk image

/// `<stem>-<version>-<arch>.dmg`, or `<stem>-<version>.dmg` for a universal
/// app, which is for every Mac: the images of two architectures uploaded to
/// one release keep both.
pub fn dmgFileName(allocator: std.mem.Allocator, stem: []const u8, version: []const u8, arch: ?Arch) ![]u8 {
    if (arch) |a| return std.fmt.allocPrint(allocator, "{s}-{s}-{s}.dmg", .{ stem, version, @tagName(a) });
    return std.fmt.allocPrint(allocator, "{s}-{s}.dmg", .{ stem, version });
}

/// Creates a writable HFS+ image of `source`, as large as its contents
/// need. hdiutil runs without -quiet, which would leave out why it failed.
pub fn hdiutilCreateArgs(volume: []const u8, source: []const u8, output: []const u8) [14][]const u8 {
    return .{ "hdiutil", "create", "-ov", "-volname", volume, "-srcfolder", source, "-fs", "HFS+", "-fsargs", "-c c=64,a=16,e=16", "-format", "UDRW", output };
}

/// The first device `hdiutil attach` prints: the whole disk, as /dev/disk4.
/// Detaching it works even after an earlier attempt unmounted the volume
/// but could not eject the disk.
pub fn attachedDisk(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const first = fields.next() orelse continue;
        if (std.mem.startsWith(u8, first, "/dev/disk")) return first;
    }
    return null;
}

/// Runs hdiutil, again while it fails with "Resource busy", which it reports
/// when a service such as Spotlight or an antivirus holds an image or a
/// volume: after 2, 4, 8 then 16 seconds.
fn hdiutilRetrying(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var first: ?[]const u8 = null;
    var attempt: u6 = 0;
    while (true) : (attempt += 1) {
        const output = try run(allocator, argv);
        if (output.ok) return;
        if (first == null) first = output.text;
        if (attempt == 4 or std.mem.indexOf(u8, output.text, "Resource busy") == null) {
            std.debug.print("ziggurat: {s} failed\n{s}\n", .{ try std.mem.join(allocator, " ", argv), std.mem.trim(u8, output.text, " \r\n") });
            if (attempt > 0) std.debug.print("first attempt: {s}\n", .{std.mem.trim(u8, first.?, " \r\n")});
            return error.CommandFailed;
        }
        std.Thread.sleep((@as(u64, 2) << attempt) * std.time.ns_per_s);
    }
}

/// The com.apple.FinderInfo attribute of a folder with a custom icon.
pub fn finderInfoHex() [64]u8 {
    var info = [_]u8{0} ** 32;
    info[8] = 0x04; // kHasCustomIcon, 0x0400, big-endian
    return std.fmt.bytesToHex(info, .lower);
}

pub const TempDir = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    /// A new directory in `parent` (default: the system's temporary folder).
    pub fn create(allocator: std.mem.Allocator, parent: ?[]const u8, prefix: []const u8) !TempDir {
        const base = parent orelse std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
        var random: [8]u8 = undefined;
        std.crypto.random.bytes(&random);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}", .{ std.mem.trimRight(u8, base, "/"), prefix, std.fmt.bytesToHex(random, .lower) });
        try std.fs.cwd().makePath(path);
        return .{ .allocator = allocator, .path = path };
    }
    pub fn remove(self: TempDir) void {
        std.fs.cwd().deleteTree(self.path) catch {};
    }
};

pub const DmgOptions = struct {
    /// The bundle, which goes into the image.
    app: []const u8,
    /// Where the image goes.
    output: []const u8,
    volume: []const u8,
    identity: []const u8 = "-",
    notarize: ?MacOS.Notarize = null,
};

/// Packages a bundle into a compressed, read-only disk image. Opening it
/// shows the app next to a link to /Applications, laid out by a generated
/// .DS_Store; only hdiutil, which ships with macOS, is needed. A real
/// identity signs the image, and `notarize` notarizes it and staples the
/// ticket to the image and the app.
pub fn buildDmg(allocator: std.mem.Allocator, options: DmgOptions) !void {
    if (builtin.os.tag != .macos) return error.NeedsMacOS;
    const directory = std.fs.path.dirname(options.output) orelse ".";
    var work = try TempDir.create(allocator, directory, ".dmg");
    defer work.remove();

    // The image starts as a copy of a folder holding all it shows. ditto
    // keeps the bundle exactly as signed, and copies it without cloning:
    // hdiutil counts the blocks a file takes, fewer than its size in a
    // sparse file, which HFS+ cannot keep sparse.
    const source = try std.fs.path.join(allocator, &.{ work.path, "src" });
    const app_name = std.fs.path.basename(options.app);
    try std.fs.cwd().makePath(source);
    try command(allocator, &.{ "ditto", "--noclone", options.app, try std.fs.path.join(allocator, &.{ source, app_name }) });
    var source_dir = try std.fs.cwd().openDir(source, .{});
    defer source_dir.close();
    try source_dir.symLink("/Applications", "Applications", .{ .is_directory = true });
    // Finder hides the .app extension of bundles by default; hiding it with
    // the Finder flag would make the signature fail strict verification.
    const layout = try dsstore.dmgLayout(allocator, app_name);
    try source_dir.writeFile(.{ .sub_path = ".DS_Store", .data = layout });
    const volume_icon = try std.fs.path.join(allocator, &.{ options.app, "Contents", "Resources", icon_file });
    const has_icon = if (std.fs.cwd().access(volume_icon, .{})) |_| true else |_| false;
    if (has_icon) try std.fs.cwd().copyFile(volume_icon, source_dir, ".VolumeIcon.icns", .{});

    const writable = try std.fs.path.join(allocator, &.{ work.path, "rw.dmg" });
    try hdiutilRetrying(allocator, &hdiutilCreateArgs(options.volume, source, writable));
    const mount = try std.fs.path.join(allocator, &.{ work.path, "mnt" });
    try std.fs.cwd().makePath(mount);
    const attach = try run(allocator, &.{ "hdiutil", "attach", "-readwrite", "-noverify", "-noautoopen", "-nobrowse", "-mountpoint", mount, writable });
    const disk = if (attach.ok) attachedDisk(attach.text) else null;
    if (disk == null) {
        std.debug.print("ziggurat: hdiutil attach {s} failed\n{s}\n", .{ writable, std.mem.trim(u8, attach.text, " \r\n") });
        return error.CommandFailed;
    }
    var attached = true;
    defer if (attached) {
        _ = run(allocator, &.{ "hdiutil", "detach", "-force", disk.? }) catch {};
    };
    if (has_icon) try command(allocator, &.{ "/usr/bin/xattr", "-wx", "com.apple.FinderInfo", &finderInfoHex(), mount });
    // Created by macOS while the image is mounted.
    var mounted = try std.fs.cwd().openDir(mount, .{});
    mounted.deleteTree(".fseventsd") catch {};
    mounted.deleteTree(".Trashes") catch {};
    mounted.close();
    try hdiutilRetrying(allocator, &.{ "hdiutil", "detach", disk.? });
    attached = false;

    // LZMA makes the smallest images, for macOS 10.15 and later.
    try command(allocator, &.{ "hdiutil", "convert", writable, "-format", "ULMO", "-ov", "-o", options.output });
    if (!std.mem.eql(u8, options.identity, "-")) try command(allocator, &.{ "codesign", "--force", "--timestamp", "--sign", options.identity, options.output });
    if (options.notarize) |credentials| {
        try notarize(allocator, credentials, options.output);
        // The ticket covers the app too: staple it for those who copy the
        // bare app, as updates do.
        try command(allocator, &.{ "xcrun", "stapler", "staple", options.app });
    }
}

/// Submits a disk image to Apple's notary service, waits for the verdict
/// and staples the ticket to the image.
pub fn notarize(allocator: std.mem.Allocator, credentials: MacOS.Notarize, dmg: []const u8) !void {
    std.debug.print("Notarizing {s} (usually a few minutes)\n", .{std.fs.path.basename(dmg)});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "xcrun", "notarytool", "submit", dmg, "--keychain-profile", credentials.keychainProfile, "--wait", "--output-format", "json" });
    if (credentials.keychain) |keychain| try argv.appendSlice(allocator, &.{ "--keychain", keychain });
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv.items, .max_output_bytes = 16 * 1024 * 1024 }) catch |err| {
        std.debug.print("ziggurat: xcrun notarytool: {s}\n", .{@errorName(err)});
        return error.NotarizationFailed;
    };
    const verdict = notaryVerdict(allocator, result.stdout);
    const exited = result.term == .Exited and result.term.Exited == 0;
    if (!exited or !std.mem.eql(u8, verdict.status, "Accepted")) {
        std.debug.print("ziggurat: notarization failed ({s} {s})\n{s}{s}\n", .{ verdict.status, verdict.message, result.stdout, result.stderr });
        if (verdict.id.len > 0) std.debug.print("see: xcrun notarytool log {s} --keychain-profile '{s}'\n", .{ verdict.id, credentials.keychainProfile });
        return error.NotarizationFailed;
    }
    try command(allocator, &.{ "xcrun", "stapler", "staple", dmg });
}

pub const Verdict = struct { id: []const u8 = "", status: []const u8 = "", message: []const u8 = "" };

/// The verdict of `notarytool submit --output-format json`, the last JSON
/// object it prints.
pub fn notaryVerdict(allocator: std.mem.Allocator, output: []const u8) Verdict {
    const start = std.mem.lastIndexOfScalar(u8, output, '{') orelse return .{};
    const parsed = std.json.parseFromSliceLeaky(Verdict, allocator, std.mem.trim(u8, output[start..], " \r\n"), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .{};
    return parsed;
}

const testing = std.testing;

test "Info.plist describes the app, its files, links and languages, and the app's keys win" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const extra = try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"NSCameraUsageDescription": "Scan <documents> & more", "LSMinimumSystemVersion": "14.0", "LSUIElement": true, "Count": 3, "List": ["a", 1.5]}
    , .{});
    const info = try infoPlist(allocator, .{
        .name = "Hello Ziggurat",
        .identity = "com.example.hello",
        .version = "1.2.3.0",
        .copyright = "(c) Example",
        .url_schemes = &.{"hello"},
        .file_associations = &.{.{ .ext = &.{ "hz", "hzz" } }},
        .macos = .{ .infoPlist = extra },
        .languages = &.{ .{ .tag = "en" }, .{ .tag = "zh-CN", .name = "你好" }, .{ .tag = "zh-Hans" }, .{ .tag = "pt-br" } },
    }, "Hello Ziggurat", true, false);
    try testing.expect(std.mem.startsWith(u8, info, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"));
    for ([_][]const u8{
        "\t<key>CFBundleExecutable</key>\n\t<string>Hello Ziggurat</string>\n",
        "\t<key>CFBundleIdentifier</key>\n\t<string>com.example.hello</string>\n",
        "\t<key>CFBundleShortVersionString</key>\n\t<string>1.2.3</string>\n",
        "\t<key>CFBundleVersion</key>\n\t<string>1.2.3</string>\n",
        "\t<key>CFBundleIconFile</key>\n\t<string>AppIcon.icns</string>\n",
        "\t<key>CFBundleDevelopmentRegion</key>\n\t<string>en</string>\n",
        "\t<key>CFBundleLocalizations</key>\n\t<array>\n\t\t<string>en</string>\n\t\t<string>zh-Hans</string>\n\t\t<string>pt-BR</string>\n\t</array>\n",
        "\t\t\t<key>CFBundleTypeExtensions</key>\n\t\t\t<array>\n\t\t\t\t<string>hz</string>\n\t\t\t\t<string>hzz</string>\n\t\t\t</array>\n",
        "\t\t\t<key>CFBundleTypeName</key>\n\t\t\t<string>HZ file</string>\n",
        "\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>Editor</string>\n",
        "\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>hello</string>\n",
        "\t<key>LSMinimumSystemVersion</key>\n\t<string>14.0</string>\n",
        "\t<key>NSCameraUsageDescription</key>\n\t<string>Scan &lt;documents&gt; &amp; more</string>\n",
        "\t<key>LSUIElement</key>\n\t<true/>\n",
        "\t<key>Count</key>\n\t<integer>3</integer>\n",
        "\t\t<string>a</string>\n\t\t<real>1.5</real>\n",
        "\t<key>NSHumanReadableCopyright</key>\n\t<string>(c) Example</string>\n",
    }) |expected| if (std.mem.indexOf(u8, info, expected) == null) {
        std.debug.print("missing:\n{s}\nin:\n{s}\n", .{ expected, info });
        return error.TestExpectedEqual;
    };
    try testing.expect(std.mem.indexOf(u8, info, "CFBundleIconName") == null);
    // Keys are sorted, so equal configurations give equal files.
    try testing.expect(std.mem.indexOf(u8, info, "CFBundleDisplayName").? < std.mem.indexOf(u8, info, "CFBundleExecutable").?);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, info, "LSMinimumSystemVersion"));
}

test "versions and localization folders follow Apple's names" {
    try testing.expectEqualStrings("1.2.3", shortVersion("1.2.3.4"));
    try testing.expectEqualStrings("1.2.3.4", bundleVersion("1.2.3.4"));
    try testing.expectEqualStrings("1.2.3", bundleVersion("1.2.3.0"));
    try testing.expectEqualStrings("1.2", bundleVersion("1.2"));
    const cases = [_][2][]const u8{ .{ "en", "en" }, .{ "zh", "zh-Hans" }, .{ "zh-TW", "zh-Hant" }, .{ "zh-HK", "zh-HK" }, .{ "zh-hant-hk", "zh-HK" }, .{ "sr-latn-RS", "sr-Latn" }, .{ "pt_br", "pt-BR" }, .{ "es-419", "es-419" } };
    for (cases) |case| {
        const name = try lprojName(testing.allocator, case[0]);
        defer testing.allocator.free(name);
        try testing.expectEqualStrings(case[1], name);
    }
    const name = try fileName(testing.allocator, " A/B: C ");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("A-B- C", name);
}

test "bundles hold the executable, the icon, the profile and the localized names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.makePath("Hello.app/Contents/stale");
    const app: App = .{ .name = "Hello", .identity = "com.example.hello", .version = "1.0.0.0", .languages = &.{ .{ .tag = "en" }, .{ .tag = "de", .name = "Hallo" }, .{ .tag = "fr" } } };
    const bundle = try writeBundle(allocator, temp.dir, app, .{ .executable = "binary", .icns = "icns....", .provisioning_profile = "profile" });
    try testing.expectEqualStrings("Hello.app", bundle);
    try testing.expectError(error.FileNotFound, temp.dir.access("Hello.app/Contents/stale", .{}));
    try testing.expectEqualStrings("binary", try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/MacOS/Hello", 64));
    if (builtin.os.tag != .windows) {
        const stat = try temp.dir.statFile("Hello.app/Contents/MacOS/Hello");
        try testing.expect(stat.mode & 0o111 != 0);
    }
    try testing.expectEqualStrings("APPL????", try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/PkgInfo", 64));
    try testing.expectEqualStrings("profile", try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/embedded.provisionprofile", 64));
    try testing.expectEqualStrings("icns....", try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/Resources/AppIcon.icns", 64));
    const strings = try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/Resources/de.lproj/InfoPlist.strings", 4096);
    try testing.expect(std.mem.indexOf(u8, strings, "<key>CFBundleName</key>\n\t<string>Hallo</string>") != null);
    try temp.dir.access("Hello.app/Contents/Resources/fr.lproj", .{});
    try testing.expectError(error.FileNotFound, temp.dir.access("Hello.app/Contents/Resources/fr.lproj/InfoPlist.strings", .{}));
    const info = try temp.dir.readFileAlloc(allocator, "Hello.app/Contents/Info.plist", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, info, "<key>CFBundleExecutable</key>\n\t<string>Hello</string>") != null);
}

fn thin(allocator: std.mem.Allocator, arch: Arch, size: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, size);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% @intFromEnum(arch));
    std.mem.writeInt(u32, bytes[0..4], mach_o_64, .little);
    std.mem.writeInt(u32, bytes[4..8], arch.cpuType(), .little);
    std.mem.writeInt(u32, bytes[8..12], if (arch == .aarch64) 0 else 3, .little);
    return bytes;
}

test "universal executables hold each slice page aligned, as lipo writes them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const arm = try thin(allocator, .aarch64, 20000);
    const intel = try thin(allocator, .x86_64, 5000);
    const fat = try writeUniversal(allocator, &.{ arm, intel });
    try testing.expectEqual(@as(u32, fat_magic), std.mem.readInt(u32, fat[0..4], .big));
    try testing.expectEqualSlices(Arch, &.{ .aarch64, .x86_64 }, try universalArchs(allocator, fat));
    try testing.expectEqual(@as(u32, 0x4000), std.mem.readInt(u32, fat[16..20], .big));
    try testing.expectEqual(@as(u32, 0xc000), std.mem.readInt(u32, fat[36..40], .big));
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, fat[32..36], .big));
    try testing.expectEqualSlices(u8, intel, fat[0xc000..][0..intel.len]);
    try testing.expectEqual(@as(usize, 0xc000 + 5000), fat.len);
    try testing.expectError(error.DuplicateArchitecture, writeUniversal(allocator, &.{ arm, arm }));
    try testing.expectError(error.NotMachO, writeUniversal(allocator, &.{"MZ not a mach-o file"}));
}

test "signing, disk image and notarization arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "codesign", "--force", "--deep", "--sign", "-", "A.app" }), try codesignArgs(allocator, "A.app", "-", null));
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "codesign", "--force", "--deep", "--sign", "Developer ID Application: X (T)", "--options", "runtime", "--timestamp", "--entitlements", "e.plist", "A.app" }), try codesignArgs(allocator, "A.app", "Developer ID Application: X (T)", "e.plist"));
    try testing.expectError(error.ProvisioningProfileNeedsIdentity, codesign(allocator, "A.app", "-", null, true));
    try testing.expectEqualStrings("hello-1.2.0.0-aarch64.dmg", try dmgFileName(allocator, "hello", "1.2.0.0", .aarch64));
    try testing.expectEqualStrings("hello-1.2.0.0.dmg", try dmgFileName(allocator, "hello", "1.2.0.0", null));
    try testing.expectEqualStrings("/dev/disk4", attachedDisk("/dev/disk4          \tGUID_partition_scheme\n/dev/disk4s1\tApple_HFS\t/tmp/mnt\n").?);
    try testing.expectEqual(null, attachedDisk("nothing\n"));
    const create = hdiutilCreateArgs("Hello", "src", "rw.dmg");
    try testing.expectEqualStrings("HFS+", create[8]);
    try testing.expectEqualStrings("UDRW", create[12]);
    const hex = finderInfoHex();
    try testing.expectEqualStrings("0000000000000000" ++ "0400", hex[0..20]);
    const verdict = notaryVerdict(allocator, "Conducting pre-submission checks...\n{\"id\":\"abc\",\"status\":\"Invalid\",\"message\":\"Processing complete\"}\n");
    try testing.expectEqualStrings("abc", verdict.id);
    try testing.expectEqualStrings("Invalid", verdict.status);
}
