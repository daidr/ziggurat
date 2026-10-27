const std = @import("std");

pub const icon_id: u16 = 101;
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
    revision: u16 = 0,
};
pub const Metadata = struct {
    /// Assembly identity: ASCII letters, numbers, dots, underscores and hyphens.
    identity: []const u8,
    display_name: []const u8,
    version: Version,
    description: ?[]const u8 = null,
    company_name: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    common_controls: bool = true,
    /// The BCP 47 tag of the language `display_name` and `description` are
    /// in, the app's own.
    language: []const u8 = "en-US",
    /// The name and description in other languages. The file properties of
    /// Windows show those of the system's language, else the app's own;
    /// languages Windows has no ID for, and repeats of one ID, are left out.
    translations: []const Translation = &.{},
};
pub const Translation = struct {
    /// A BCP 47 tag, such as `zh-Hans` or `pt-BR`.
    language: []const u8,
    /// Defaults to the app's `display_name`.
    display_name: ?[]const u8 = null,
    /// Defaults to the app's description.
    description: ?[]const u8 = null,
};
pub const Options = struct {
    metadata: Metadata,
    icon: std.Build.LazyPath,
};
pub const Resources = struct {
    manifest: std.Build.LazyPath,
    rc: std.Build.LazyPath,
    icon: std.Build.LazyPath,
};

/// Call once per executable. All inputs are copied into its generated resource directory.
/// Zig's own resource compiler handles the .rc file; no external RC executable is needed.
pub fn addWindowsResources(b: *std.Build, exe: *std.Build.Step.Compile, options: Options) !Resources {
    try validate(options.metadata);
    try validateFilename(exe.name);
    const files = b.addWriteFiles();
    const manifest = files.add("application.manifest", try renderManifest(b.allocator, options.metadata));
    const icon = files.addCopyFile(options.icon, "application.ico");
    const rc = files.add("application.rc", try renderRc(b.allocator, options.metadata, exe.name));
    exe.root_module.addWin32ResourceFile(.{ .file = rc, .include_paths = &.{files.getDirectory()} });
    return .{ .manifest = manifest, .rc = rc, .icon = icon };
}

pub fn validate(metadata: Metadata) !void {
    if (metadata.identity.len == 0 or metadata.identity.len > 128) return error.InvalidIdentity;
    for (metadata.identity, 0..) |byte, index| {
        const alphanumeric = std.ascii.isAlphanumeric(byte);
        if (!alphanumeric and (index == 0 or (byte != '.' and byte != '_' and byte != '-'))) return error.InvalidIdentity;
    }
    try validateText(metadata.display_name, 255);
    if (metadata.description) |text| try validateText(text, 1024);
    if (metadata.company_name) |text| try validateText(text, 1024);
    if (metadata.copyright) |text| try validateText(text, 1024);
    for (metadata.translations) |translation| {
        if (translation.display_name) |text| try validateText(text, 255);
        if (translation.description) |text| try validateText(text, 1024);
    }
}

/// The Windows language ID of a BCP 47 tag, as 0x0409 for en-US: of the
/// language and region, else the language and script, else the language.
/// Chinese without a script is Simplified, or Traditional in Taiwan, Hong
/// Kong and Macao.
pub fn languageId(tag: []const u8) ?u16 {
    var language: []const u8 = "";
    var script: []const u8 = "";
    var region: []const u8 = "";
    var parts = std.mem.tokenizeAny(u8, tag, "-_");
    language = parts.next() orelse return null;
    while (parts.next()) |part| {
        if (part.len == 4 and script.len == 0 and region.len == 0) {
            script = part;
        } else if (region.len == 0 and (part.len == 2 or (part.len == 3 and std.ascii.isDigit(part[0])))) region = part;
    }
    if (language.len == 0 or language.len > 3) return null;
    if (std.ascii.eqlIgnoreCase(language, "zh") and script.len == 0) {
        const traditional = std.ascii.eqlIgnoreCase(region, "TW") or std.ascii.eqlIgnoreCase(region, "HK") or std.ascii.eqlIgnoreCase(region, "MO");
        script = if (traditional) "Hant" else "Hans";
    }
    var key: [16]u8 = undefined;
    if (region.len > 0) if (lookup(&key, language, region)) |id| return id;
    if (script.len > 0) if (lookup(&key, language, script)) |id| return id;
    return lookup(&key, language, "");
}

fn lookup(key: *[16]u8, language: []const u8, suffix: []const u8) ?u16 {
    if (language.len + 1 + suffix.len > key.len) return null;
    var length = std.ascii.lowerString(key, language).len;
    if (suffix.len > 0) {
        key[length] = '-';
        length += 1 + std.ascii.lowerString(key[length + 1 ..], suffix).len;
    }
    return language_ids.get(key[0..length]);
}

const language_ids: std.StaticStringMap(u16) = .initComptime(.{
    .{ "af", 0x0436 },      .{ "am", 0x045E },      .{ "ar", 0x0401 },    .{ "ar-eg", 0x0C01 },   .{ "ar-sa", 0x0401 },
    .{ "az", 0x042C },      .{ "az-latn", 0x042C }, .{ "ba", 0x046D },    .{ "be", 0x0423 },      .{ "bg", 0x0402 },
    .{ "bn", 0x0445 },      .{ "bs", 0x141A },      .{ "ca", 0x0403 },    .{ "co", 0x0483 },      .{ "cs", 0x0405 },
    .{ "cy", 0x0452 },      .{ "da", 0x0406 },      .{ "de", 0x0407 },    .{ "de-at", 0x0C07 },   .{ "de-ch", 0x0807 },
    .{ "de-de", 0x0407 },   .{ "el", 0x0408 },      .{ "en", 0x0409 },    .{ "en-au", 0x0C09 },   .{ "en-ca", 0x1009 },
    .{ "en-gb", 0x0809 },   .{ "en-ie", 0x1809 },   .{ "en-in", 0x4009 }, .{ "en-nz", 0x1409 },   .{ "en-sg", 0x4809 },
    .{ "en-us", 0x0409 },   .{ "en-za", 0x1C09 },   .{ "es", 0x0C0A },    .{ "es-ar", 0x2C0A },   .{ "es-cl", 0x340A },
    .{ "es-co", 0x240A },   .{ "es-es", 0x0C0A },   .{ "es-mx", 0x080A }, .{ "es-us", 0x540A },   .{ "es-419", 0x580A },
    .{ "et", 0x0425 },      .{ "eu", 0x042D },      .{ "fa", 0x0429 },    .{ "fi", 0x040B },      .{ "fil", 0x0464 },
    .{ "fo", 0x0438 },      .{ "fr", 0x040C },      .{ "fr-be", 0x080C }, .{ "fr-ca", 0x0C0C },   .{ "fr-ch", 0x100C },
    .{ "fr-fr", 0x040C },   .{ "ga", 0x083C },      .{ "gd", 0x0491 },    .{ "gl", 0x0456 },      .{ "gsw", 0x0484 },
    .{ "gu", 0x0447 },      .{ "ha", 0x0468 },      .{ "he", 0x040D },    .{ "hi", 0x0439 },      .{ "hr", 0x041A },
    .{ "hsb", 0x042E },     .{ "hu", 0x040E },      .{ "hy", 0x042B },    .{ "id", 0x0421 },      .{ "ig", 0x0470 },
    .{ "ii", 0x0478 },      .{ "is", 0x040F },      .{ "it", 0x0410 },    .{ "it-ch", 0x0810 },   .{ "it-it", 0x0410 },
    .{ "iu", 0x045D },      .{ "ja", 0x0411 },      .{ "ka", 0x0437 },    .{ "kk", 0x043F },      .{ "kl", 0x046F },
    .{ "km", 0x0453 },      .{ "kn", 0x044B },      .{ "ko", 0x0412 },    .{ "kok", 0x0457 },     .{ "ky", 0x0440 },
    .{ "lb", 0x046E },      .{ "lo", 0x0454 },      .{ "lt", 0x0427 },    .{ "lv", 0x0426 },      .{ "mi", 0x0481 },
    .{ "mk", 0x042F },      .{ "ml", 0x044C },      .{ "mn", 0x0450 },    .{ "moh", 0x047C },     .{ "mr", 0x044E },
    .{ "ms", 0x043E },      .{ "mt", 0x043A },      .{ "nb", 0x0414 },    .{ "ne", 0x0461 },      .{ "nl", 0x0413 },
    .{ "nl-be", 0x0813 },   .{ "nl-nl", 0x0413 },   .{ "nn", 0x0814 },    .{ "no", 0x0414 },      .{ "nso", 0x046C },
    .{ "oc", 0x0482 },      .{ "or", 0x0448 },      .{ "pa", 0x0446 },    .{ "pl", 0x0415 },      .{ "prs", 0x048C },
    .{ "ps", 0x0463 },      .{ "pt", 0x0416 },      .{ "pt-br", 0x0416 }, .{ "pt-pt", 0x0816 },   .{ "qut", 0x0486 },
    .{ "quz", 0x046B },     .{ "rm", 0x0417 },      .{ "ro", 0x0418 },    .{ "ru", 0x0419 },      .{ "rw", 0x0487 },
    .{ "sa", 0x044F },      .{ "sah", 0x0485 },     .{ "se", 0x043B },    .{ "si", 0x045B },      .{ "sk", 0x041B },
    .{ "sl", 0x0424 },      .{ "sq", 0x041C },      .{ "sr", 0x281A },    .{ "sr-cyrl", 0x281A }, .{ "sr-latn", 0x241A },
    .{ "sv", 0x041D },      .{ "sw", 0x0441 },      .{ "ta", 0x0449 },    .{ "te", 0x044A },      .{ "tg", 0x0428 },
    .{ "th", 0x041E },      .{ "tn", 0x0432 },      .{ "tr", 0x041F },    .{ "tt", 0x0444 },      .{ "ug", 0x0480 },
    .{ "uk", 0x0422 },      .{ "ur", 0x0420 },      .{ "uz", 0x0443 },    .{ "vi", 0x042A },      .{ "wo", 0x0488 },
    .{ "xh", 0x0434 },      .{ "yo", 0x046A },      .{ "zh", 0x0804 },    .{ "zh-cn", 0x0804 },   .{ "zh-hans", 0x0804 },
    .{ "zh-hant", 0x0404 }, .{ "zh-hk", 0x0C04 },   .{ "zh-mo", 0x1404 }, .{ "zh-sg", 0x1004 },   .{ "zh-tw", 0x0404 },
    .{ "zu", 0x0435 },
});

fn validateText(text: []const u8, maximum: usize) !void {
    if (text.len == 0 or text.len > maximum or !std.unicode.utf8ValidateSlice(text)) return error.InvalidMetadata;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidMetadata;
    var iterator = (std.unicode.Utf8View.initUnchecked(text)).iterator();
    while (iterator.nextCodepoint()) |codepoint| if (codepoint == 0xfffe or codepoint == 0xffff) return error.InvalidMetadata;
}

fn validateFilename(name: []const u8) !void {
    if (name.len == 0 or name.len > 200 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFilename;
    if (name[0] == ' ' or name[name.len - 1] == ' ' or name[name.len - 1] == '.') return error.InvalidFilename;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-' and byte != ' ') return error.InvalidFilename;
}

fn escaped(allocator: std.mem.Allocator, text: []const u8, comptime xml: bool) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (text) |byte| {
        const replacement: ?[]const u8 = if (xml) switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        } else switch (byte) {
            '\\' => "\\\\",
            '"' => "\"\"",
            else => null,
        };
        if (replacement) |value| try result.appendSlice(allocator, value) else try result.append(allocator, byte);
    }
    return result.toOwnedSlice(allocator);
}

pub fn renderManifest(allocator: std.mem.Allocator, metadata: Metadata) ![]const u8 {
    try validate(metadata);
    const name = try escaped(allocator, metadata.display_name, true);
    defer allocator.free(name);
    const v = metadata.version;
    const controls = if (metadata.common_controls)
        \\  <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/></dependentAssembly></dependency>
        \\
    else
        "";
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
        \\  <assemblyIdentity type="win32" name="{s}" version="{d}.{d}.{d}.{d}" processorArchitecture="*"/>
        \\  <description>{s}</description>
        \\  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security></trustInfo>
        \\  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application><supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/></application></compatibility>
        \\  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
        \\    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
        \\    <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, PerMonitor</dpiAwareness>
        \\    <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
        \\    <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
        \\  </windowsSettings></application>
        \\{s}</assembly>
        \\
    , .{ metadata.identity, v.major, v.minor, v.patch, v.revision, name, controls });
}

pub const Language = struct { id: u16, display_name: []const u8, description: []const u8 };

/// The languages of the version resource: the app's own first, then each
/// translation whose language Windows has an ID for and no earlier entry
/// took. An app's own language without an ID falls back to en-US.
pub fn languages(allocator: std.mem.Allocator, metadata: Metadata) ![]Language {
    var out: std.ArrayList(Language) = .empty;
    errdefer out.deinit(allocator);
    const description = metadata.description orelse metadata.display_name;
    try out.append(allocator, .{ .id = languageId(metadata.language) orelse 0x0409, .display_name = metadata.display_name, .description = description });
    outer: for (metadata.translations) |translation| {
        const id = languageId(translation.language) orelse {
            std.log.warn("the file properties of the app are not in {s}: Windows has no ID of the language", .{translation.language});
            continue;
        };
        for (out.items) |existing| if (existing.id == id) continue :outer;
        try out.append(allocator, .{ .id = id, .display_name = translation.display_name orelse metadata.display_name, .description = translation.description orelse description });
    }
    return out.toOwnedSlice(allocator);
}

pub fn renderRc(allocator: std.mem.Allocator, metadata: Metadata, executable_name: []const u8) ![]const u8 {
    try validate(metadata);
    try validateFilename(executable_name);
    const company = try escaped(allocator, metadata.company_name orelse "", false);
    defer allocator.free(company);
    const copyright = try escaped(allocator, metadata.copyright orelse "", false);
    defer allocator.free(copyright);
    const v = metadata.version;
    const tables = try languages(allocator, metadata);
    defer allocator.free(tables);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print(
        \\#pragma code_page(65001)
        \\LANGUAGE 0, 0
        \\101 ICON "application.ico"
        \\1 24 "application.manifest"
        \\1 VERSIONINFO
        \\FILEVERSION {d},{d},{d},{d}
        \\PRODUCTVERSION {d},{d},{d},{d}
        \\FILEFLAGSMASK 0x3fL
        \\FILEFLAGS 0
        \\FILEOS 0x40004L
        \\FILETYPE 1
        \\FILESUBTYPE 0
        \\BEGIN
        \\  BLOCK "StringFileInfo"
        \\  BEGIN
        \\
    , .{ v.major, v.minor, v.patch, v.revision, v.major, v.minor, v.patch, v.revision });
    // A table's key is its language and the Unicode code page, 1200.
    for (tables) |table| {
        const name = try escaped(allocator, table.display_name, false);
        defer allocator.free(name);
        const description = try escaped(allocator, table.description, false);
        defer allocator.free(description);
        try w.print(
            \\    BLOCK "{X:0>4}04B0"
            \\    BEGIN
            \\      VALUE "CompanyName", L"{s}\0"
            \\      VALUE "FileDescription", L"{s}\0"
            \\      VALUE "FileVersion", "{d}.{d}.{d}.{d}\0"
            \\      VALUE "InternalName", "{s}\0"
            \\      VALUE "LegalCopyright", L"{s}\0"
            \\      VALUE "OriginalFilename", "{s}.exe\0"
            \\      VALUE "ProductName", L"{s}\0"
            \\      VALUE "ProductVersion", "{d}.{d}.{d}.{d}\0"
            \\    END
            \\
        , .{ table.id, company, description, v.major, v.minor, v.patch, v.revision, executable_name, copyright, executable_name, name, v.major, v.minor, v.patch, v.revision });
    }
    try w.writeAll(
        \\  END
        \\  BLOCK "VarFileInfo"
        \\  BEGIN
        \\    VALUE "Translation"
    );
    for (tables, 0..) |table, i| try w.print("{s} 0x{X:0>4}, 1200", .{ if (i == 0) "" else ",", table.id });
    try w.writeAll(
        \\
        \\  END
        \\END
        \\
    );
    return out.toOwnedSlice();
}

test "metadata rejects control characters and path injection" {
    const valid: Metadata = .{ .identity = "org.example.Counter", .display_name = "Counter", .version = .{ .major = 1, .minor = 2, .patch = 3 } };
    try validate(valid);
    var invalid = valid;
    invalid.identity = "x\"/><evil/>";
    try std.testing.expectError(error.InvalidIdentity, validate(invalid));
    invalid = valid;
    invalid.display_name = "Counter\nInjected";
    try std.testing.expectError(error.InvalidMetadata, validate(invalid));
    invalid.display_name = "Counter \u{fffe}";
    try std.testing.expectError(error.InvalidMetadata, validate(invalid));
    try std.testing.expectError(error.InvalidFilename, renderRc(std.testing.allocator, valid, "../other"));
}

test "XML and RC escape user metadata independently" {
    const metadata: Metadata = .{ .identity = "org.example.Counter", .display_name = "计数 & <\"Panel\"> \\ test", .version = .{ .major = 1, .minor = 2, .patch = 3, .revision = 4 } };
    const manifest = try renderManifest(std.testing.allocator, metadata);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "计数 &amp; &lt;&quot;Panel&quot;&gt; \\ test") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "version=\"1.2.3.4\"") != null);
    const rc = try renderRc(std.testing.allocator, metadata, "counter");
    defer std.testing.allocator.free(rc);
    try std.testing.expect(std.mem.indexOf(u8, rc, "计数 & <\"\"Panel\"\"> \\\\ test") != null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "FILEVERSION 1,2,3,4") != null);
}

test "language IDs follow region, then script, then language" {
    try std.testing.expectEqual(@as(?u16, 0x0409), languageId("en"));
    try std.testing.expectEqual(@as(?u16, 0x0809), languageId("en-GB"));
    try std.testing.expectEqual(@as(?u16, 0x0409), languageId("en-XX"));
    try std.testing.expectEqual(@as(?u16, 0x0804), languageId("zh"));
    try std.testing.expectEqual(@as(?u16, 0x0404), languageId("zh-TW"));
    try std.testing.expectEqual(@as(?u16, 0x0404), languageId("zh-Hant"));
    try std.testing.expectEqual(@as(?u16, 0x0C04), languageId("zh-Hant-HK"));
    try std.testing.expectEqual(@as(?u16, 0x241A), languageId("sr-Latn"));
    try std.testing.expectEqual(@as(?u16, 0x580A), languageId("es-419"));
    try std.testing.expectEqual(@as(?u16, null), languageId("tlh"));
}

test "every language gets its own string table" {
    const metadata: Metadata = .{
        .identity = "org.example.Counter",
        .display_name = "Counter",
        .description = "Counts",
        .version = .{ .major = 1, .minor = 2, .patch = 3 },
        .translations = &.{
            .{ .language = "zh-Hans", .display_name = "计数器" },
            .{ .language = "zh-CN", .display_name = "repeat of 0804" },
            .{ .language = "tlh" },
            .{ .language = "de" },
        },
    };
    const rc = try renderRc(std.testing.allocator, metadata, "counter");
    defer std.testing.allocator.free(rc);
    try std.testing.expect(std.mem.indexOf(u8, rc, "BLOCK \"040904B0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "BLOCK \"080404B0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "BLOCK \"040704B0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "L\"计数器\\0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "repeat") == null);
    try std.testing.expect(std.mem.indexOf(u8, rc, "VALUE \"Translation\" 0x0409, 1200, 0x0804, 1200, 0x0407, 1200") != null);
    const manifest = try renderManifest(std.testing.allocator, metadata);
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ">UTF-8</activeCodePage>") != null);
}
