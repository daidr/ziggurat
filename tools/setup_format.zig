const std = @import("std");
const zio = @import("ziggurat_io");

/// A setup program is the setup stub followed by an update package, the
/// install configuration and a footer. When the result is Authenticode
/// signed, the signature table follows the footer; `locate` excludes it.
pub const magic = "ZGSETUP1";
pub const footer_bytes = magic.len + 8 + 8 + 32 + 32;

pub const Config = struct {
    name: []const u8,
    identity: []const u8,
    version: []const u8,
    target: []const u8,
    executable: []const u8,
    publisher: []const u8 = "",
    comment: []const u8 = "",
    /// Freedesktop categories, for example "Utility;".
    categories: []const u8 = "Utility;",
    /// Optional PNG file in the package used as the Linux menu icon.
    icon: ?[]const u8 = null,
    /// The Windows install folder's name instead of the identity, as
    /// `%LOCALAPPDATA%\Programs\<name>`; see `validInstallDirName`.
    install_dir_name: ?[]const u8 = null,
    hooks: Hooks = .{},
};

/// Commands of the app's own that the setup program runs, with the shell
/// (a batch file's line on Windows, `/bin/sh -c` elsewhere), in silent
/// installs too. They see ZIGGURAT_INSTALL_DIR, ZIGGURAT_SCOPE (user or
/// machine), ZIGGURAT_VERSION and ZIGGURAT_SILENT (1 or 0); `install` and
/// `uninstall` also ZIGGURAT_APP, the launcher.
pub const Hooks = struct {
    /// Before anything is written; failing stops the install.
    init: ?[]const u8 = null,
    /// Once the app is installed and integrated.
    install: ?[]const u8 = null,
    /// Before the uninstaller removes the app's folder; failing does not
    /// stop it.
    uninstall: ?[]const u8 = null,
};

/// One folder's name: not empty, ".", "..", a path, a name with :*?"<>|
/// or control characters, one ending with a dot or a space, or a device's
/// name such as CON or COM1.
pub fn validInstallDirName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ' or name[0] == ' ') return false;
    for (name) |byte| if (byte < 0x20 or std.mem.indexOfScalar(u8, "/\\:*?\"<>|", byte) != null) return false;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")) and stem[3] >= '0' and stem[3] <= '9') return false;
    return true;
}

test "install folder names are one plain folder" {
    for ([_][]const u8{ "ZhiLian", "My App", "智链", "app.v2" }) |name| try std.testing.expect(validInstallDirName(name));
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "C:", "what?", "end.", "end ", " start", "con", "Com1", "nul.txt", "tab\tname" }) |name| try std.testing.expect(!validInstallDirName(name));
}

pub const Located = struct {
    stub_bytes: u64,
    zip_offset: u64,
    zip_bytes: u64,
    zip_sha256: [32]u8,
    config_offset: u64,
    config_bytes: u64,
    config_sha256: [32]u8,
};

pub fn writeFooter(writer: *std.Io.Writer, zip: []const u8, config: []const u8) !void {
    var digest: [32]u8 = undefined;
    try writer.writeAll(magic);
    try writer.writeInt(u64, zip.len, .little);
    try writer.writeInt(u64, config.len, .little);
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    try writer.writeAll(&digest);
    std.crypto.hash.sha2.Sha256.hash(config, &digest, .{});
    try writer.writeAll(&digest);
}

/// Byte length of a PE image before its attribute certificate table, or the
/// whole length for unsigned images and other formats.
pub fn contentEnd(file: std.Io.File, size: u64) !u64 {
    var dos: [64]u8 = undefined;
    if (size < dos.len or try file.readPositionalAll(zio.io(), &dos, 0) != dos.len or !std.mem.eql(u8, dos[0..2], "MZ")) return size;
    const pe = std.mem.readInt(u32, dos[0x3c..][0..4], .little);
    var header: [24 + 2]u8 = undefined;
    if (pe > size or try file.readPositionalAll(zio.io(), &header, pe) != header.len or !std.mem.eql(u8, header[0..4], "PE\x00\x00")) return size;
    const optional = pe + 24;
    const magic_value = std.mem.readInt(u16, header[24..26], .little);
    const directories: u64 = switch (magic_value) {
        0x10b => optional + 96,
        0x20b => optional + 112,
        else => return size,
    };
    // Data directory 4 holds the certificate table as a file offset.
    var security: [8]u8 = undefined;
    if (try file.readPositionalAll(zio.io(), &security, directories + 4 * 8) != security.len) return size;
    const offset = std.mem.readInt(u32, security[0..4], .little);
    const length = std.mem.readInt(u32, security[4..8], .little);
    if (offset == 0 or length == 0) return size;
    if (@as(u64, offset) + length != size) return error.UnexpectedSignatureLayout;
    return offset;
}

pub fn locate(file: std.Io.File) !?Located {
    const size = (try file.stat(zio.io())).size;
    const end = try contentEnd(file, size);
    if (end < footer_bytes) return null;
    var footer: [footer_bytes]u8 = undefined;
    if (try file.readPositionalAll(zio.io(), &footer, end - footer_bytes) != footer.len) return null;
    if (!std.mem.eql(u8, footer[0..magic.len], magic)) return null;
    var located: Located = undefined;
    located.zip_bytes = std.mem.readInt(u64, footer[8..16], .little);
    located.config_bytes = std.mem.readInt(u64, footer[16..24], .little);
    @memcpy(&located.zip_sha256, footer[24..56]);
    @memcpy(&located.config_sha256, footer[56..88]);
    const payload = std.math.add(u64, located.zip_bytes, located.config_bytes) catch return error.InvalidSetupPayload;
    if (located.config_bytes > 64 * 1024 or payload > end - footer_bytes) return error.InvalidSetupPayload;
    located.config_offset = end - footer_bytes - located.config_bytes;
    located.zip_offset = located.config_offset - located.zip_bytes;
    located.stub_bytes = located.zip_offset;
    return located;
}

test "payload is found after the stub with and without a certificate table" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.writeAll("stub-bytes");
    try output.writer.writeAll("zip!");
    try output.writer.writeAll("{}");
    try writeFooter(&output.writer, "zip!", "{}");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "setup", .data = output.written() });
    var file = try temp.dir.openFile(zio.io(), "setup", .{});
    defer file.close(zio.io());
    const located = (try locate(file)).?;
    try std.testing.expectEqual(10, located.stub_bytes);
    try std.testing.expectEqual(4, located.zip_bytes);
    try std.testing.expectEqual(14, located.config_offset);

    // A minimal PE32+ header whose certificate table follows the footer.
    var image: [512]u8 = @splat(0);
    image[0] = 'M';
    image[1] = 'Z';
    std.mem.writeInt(u32, image[0x3c..][0..4], 0x80, .little);
    @memcpy(image[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, image[0x80 + 24 ..][0..2], 0x20b, .little);
    var signed: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer signed.deinit();
    const total = image.len + 4 + 2 + footer_bytes + 16;
    std.mem.writeInt(u32, image[0x80 + 24 + 112 + 32 ..][0..4], @intCast(total - 16), .little);
    std.mem.writeInt(u32, image[0x80 + 24 + 112 + 36 ..][0..4], 16, .little);
    try signed.writer.writeAll(&image);
    try signed.writer.writeAll("zip!");
    try signed.writer.writeAll("{}");
    try writeFooter(&signed.writer, "zip!", "{}");
    try signed.writer.writeAll(&@as([16]u8, @splat(0xcc)));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "signed.exe", .data = signed.written() });
    var pe = try temp.dir.openFile(zio.io(), "signed.exe", .{});
    defer pe.close(zio.io());
    try std.testing.expectEqual(image.len, (try locate(pe)).?.stub_bytes);
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "plain", .data = "no payload here" });
    var plain = try temp.dir.openFile(zio.io(), "plain", .{});
    defer plain.close(zio.io());
    try std.testing.expect((try locate(plain)) == null);
}

fn appendEscaped(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\n', '\r', '\t' => return error.InvalidDesktopValue,
        else => {
            if (byte < 0x20) return error.InvalidDesktopValue;
            try output.append(allocator, byte);
        },
    };
}

/// Freedesktop entry for `exec`, quoted per the Exec rules and then escaped
/// as a desktop string value. `icon` is an icon theme name or absolute path.
pub fn desktopEntry(allocator: std.mem.Allocator, config: Config, exec: []const u8, icon: ?[]const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(config.name) or !std.unicode.utf8ValidateSlice(config.comment)) return error.InvalidDesktopValue;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "[Desktop Entry]\nType=Application\nVersion=1.5\nName=");
    try appendEscaped(&output, allocator, config.name);
    if (config.comment.len > 0) {
        try output.appendSlice(allocator, "\nComment=");
        try appendEscaped(&output, allocator, config.comment);
    }
    try output.appendSlice(allocator, "\nExec=\"");
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(allocator);
    for (exec) |byte| {
        if (byte == '"' or byte == '`' or byte == '$' or byte == '\\') try quoted.append(allocator, '\\');
        if (byte == '%') try quoted.append(allocator, '%');
        try quoted.append(allocator, byte);
    }
    try appendEscaped(&output, allocator, quoted.items);
    try output.appendSlice(allocator, "\" %U\nTerminal=false\nStartupNotify=true\n");
    if (icon) |value| {
        try output.appendSlice(allocator, "Icon=");
        try appendEscaped(&output, allocator, value);
        try output.append(allocator, '\n');
    }
    for (config.categories) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != ';' and byte != '-') return error.InvalidDesktopValue;
    if (config.categories.len > 0) {
        try output.appendSlice(allocator, "Categories=");
        try output.appendSlice(allocator, config.categories);
        if (!std.mem.endsWith(u8, config.categories, ";")) try output.append(allocator, ';');
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

test "desktop entries quote Exec and escape values" {
    const entry = try desktopEntry(std.testing.allocator, .{ .name = "My \\ App", .identity = "org.example.App", .version = "1.0.0.0", .target = "linux-x86_64", .executable = "app", .comment = "Says \"hi\"" }, "/opt/my app/$x\"%", "org.example.App");
    defer std.testing.allocator.free(entry);
    try std.testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Version=1.5
        \\Name=My \\ App
        \\Comment=Says "hi"
        \\Exec="/opt/my app/\\$x\\"%%" %U
        \\Terminal=false
        \\StartupNotify=true
        \\Icon=org.example.App
        \\Categories=Utility;
        \\
    , entry);
    try std.testing.expectError(error.InvalidDesktopValue, desktopEntry(std.testing.allocator, .{ .name = "a\nb", .identity = "x", .version = "1.0.0.0", .target = "t", .executable = "e" }, "/x", null));
}
