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
}

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
        \\  </windowsSettings></application>
        \\{s}</assembly>
        \\
    , .{ metadata.identity, v.major, v.minor, v.patch, v.revision, name, controls });
}

pub fn renderRc(allocator: std.mem.Allocator, metadata: Metadata, executable_name: []const u8) ![]const u8 {
    try validate(metadata);
    try validateFilename(executable_name);
    const name = try escaped(allocator, metadata.display_name, false);
    defer allocator.free(name);
    const description = try escaped(allocator, metadata.description orelse metadata.display_name, false);
    defer allocator.free(description);
    const company = try escaped(allocator, metadata.company_name orelse "", false);
    defer allocator.free(company);
    const copyright = try escaped(allocator, metadata.copyright orelse "", false);
    defer allocator.free(copyright);
    const v = metadata.version;
    return std.fmt.allocPrint(allocator,
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
        \\    BLOCK "040904B0"
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
        \\  END
        \\  BLOCK "VarFileInfo"
        \\  BEGIN
        \\    VALUE "Translation", 0x0409, 1200
        \\  END
        \\END
        \\
    , .{ v.major, v.minor, v.patch, v.revision, v.major, v.minor, v.patch, v.revision, company, description, v.major, v.minor, v.patch, v.revision, executable_name, copyright, executable_name, name, v.major, v.minor, v.patch, v.revision });
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
