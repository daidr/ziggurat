//! Authenticode signing of Windows executables and installers by the
//! ziggurat command, configured by `windows` in ziggurat.json. signtool
//! signs on Windows and osslsigncode elsewhere; `signCommand` replaces
//! both, for signing services and certificates on hardware tokens.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub const password_variable = "ZIGGURAT_WINDOWS_CERTIFICATE_PASSWORD";
pub const default_timestamp_url = "http://timestamp.digicert.com";

pub const Windows = struct {
    /// A code signing certificate (.pfx), relative to the project, to sign
    /// the executable and the installer with, which keeps SmartScreen from
    /// warning users. Its password comes from
    /// ZIGGURAT_WINDOWS_CERTIFICATE_PASSWORD.
    certificate: ?[]const u8 = null,
    /// A shell command that signs a file instead, with %1 standing for its
    /// quoted path, e.g.
    /// "signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /a %1".
    signCommand: ?[]const u8 = null,
    /// The RFC 3161 time stamping server of `certificate`.
    timestampUrl: ?[]const u8 = null,
    /// The install folder's name instead of the identity, as
    /// `%LOCALAPPDATA%\Programs\ZhiLian`; the shortcuts, the entry in
    /// Settings > Apps and the executable keep their names.
    installDirName: ?[]const u8 = null,

    pub fn signs(self: Windows) bool {
        return self.certificate != null or self.signCommand != null;
    }
};

/// The command line that signs `file`. `password` is passed to the tool,
/// never printed.
pub fn command(allocator: std.mem.Allocator, windows: Windows, root: []const u8, file: []const u8, host: std.Target.Os.Tag, tool: []const u8, password: ?[]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (windows.signCommand) |text| {
        const line = try std.mem.replaceOwned(u8, allocator, text, "%1", try shellQuote(allocator, file, host));
        if (host == .windows) try argv.appendSlice(allocator, &.{ "cmd.exe", "/d", "/s", "/c", line }) else try argv.appendSlice(allocator, &.{ "/bin/sh", "-c", line });
        return argv.toOwnedSlice(allocator);
    }
    const relative = windows.certificate orelse return error.NoSigningConfiguration;
    const absolute = if (host == .windows) std.fs.path.isAbsoluteWindows(relative) else std.fs.path.isAbsolutePosix(relative);
    const separator = if (host == .windows) "\\" else "/";
    const certificate = if (absolute) relative else try std.mem.concat(allocator, u8, &.{ std.mem.trimEnd(u8, root, "/\\"), separator, relative });
    const timestamp = windows.timestampUrl orelse default_timestamp_url;
    if (host == .windows) {
        try argv.appendSlice(allocator, &.{ tool, "sign", "/f", certificate, "/fd", "sha256", "/tr", timestamp, "/td", "sha256" });
        if (password) |text| try argv.appendSlice(allocator, &.{ "/p", text });
        try argv.append(allocator, file);
    } else {
        try argv.appendSlice(allocator, &.{ tool, "sign", "-pkcs12", certificate, "-h", "sha256", "-ts", timestamp, "-in", file, "-out", try signedPath(allocator, file) });
        if (password) |text| try argv.appendSlice(allocator, &.{ "-pass", text });
    }
    return argv.toOwnedSlice(allocator);
}

fn signedPath(allocator: std.mem.Allocator, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.signed", .{file});
}

/// Quote an argument for the shell that runs `signCommand`.
pub fn shellQuote(allocator: std.mem.Allocator, text: []const u8, host: std.Target.Os.Tag) ![]const u8 {
    if (host == .windows) return std.fmt.allocPrint(allocator, "\"{s}\"", .{text});
    const inner = try std.mem.replaceOwned(u8, allocator, text, "'", "'\\''");
    return std.fmt.allocPrint(allocator, "'{s}'", .{inner});
}

/// Sign `file` in place. `root` is the project directory the certificate
/// path is relative to.
pub fn sign(allocator: std.mem.Allocator, windows: Windows, root: []const u8, file: []const u8) !void {
    const password = zio.getEnvVarOwned(allocator, password_variable) catch null;
    const tool: []const u8 = if (windows.signCommand != null) "" else if (builtin.os.tag == .windows)
        (try signtool(allocator)) orelse return error.SigntoolNotFound
    else
        (try findInPath(allocator, "osslsigncode")) orelse return error.OsslsigncodeNotFound;
    const argv = try command(allocator, windows, root, file, builtin.os.tag, tool, password);
    // The command's own output tells what failed; it is not echoed, as it
    // may hold credentials.
    var child = try zio.spawn(.{ .argv = argv, .cwd = zio.cwd(root) });
    const term = try child.wait(zio.io());
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (windows.signCommand != null) return if (ok) {} else error.SignCommandFailed;
    if (builtin.os.tag == .windows) return if (ok) {} else error.SigntoolFailed;
    const signed = try signedPath(allocator, file);
    if (!ok) {
        std.Io.Dir.cwd().deleteFile(zio.io(), signed) catch {};
        return error.OsslsigncodeFailed;
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), signed, std.Io.Dir.cwd(), file, zio.io());
}

fn findInPath(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const path = zio.getEnvVarOwned(allocator, "PATH") catch return null;
    var parts = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (parts.next()) |dir| {
        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        std.Io.Dir.cwd().access(zio.io(), candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// signtool on PATH, else that of the newest Windows 10/11 SDK.
fn signtool(allocator: std.mem.Allocator) !?[]const u8 {
    if (try findInPath(allocator, "signtool.exe")) |found| return found;
    const program_files = zio.getEnvVarOwned(allocator, "ProgramFiles(x86)") catch return null;
    const bin = try std.fs.path.join(allocator, &.{ program_files, "Windows Kits", "10", "bin" });
    var dir = std.Io.Dir.cwd().openDir(zio.io(), bin, .{ .iterate = true }) catch return null;
    defer dir.close(zio.io());
    const arch = if (builtin.cpu.arch == .aarch64) "arm64" else "x64";
    var newest: ?[]const u8 = null;
    var iterator = dir.iterate();
    while (try iterator.next(zio.io())) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "10.")) continue;
        const candidate = try std.fs.path.join(allocator, &.{ bin, entry.name, arch, "signtool.exe" });
        std.Io.Dir.cwd().access(zio.io(), candidate, .{}) catch continue;
        if (newest == null or std.mem.order(u8, candidate, newest.?) == .gt) newest = candidate;
    }
    return newest;
}

pub const PeKind = struct { image: bool, signed: bool };

/// Whether `bytes` start a PE image, an executable or DLL, and whether it
/// carries an Authenticode signature: a certificate table, the fifth data
/// directory, of nonzero size.
pub fn peKind(bytes: []const u8) PeKind {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return .{ .image = false, .signed = false };
    const pe = std.mem.readInt(u32, bytes[0x3c..][0..4], .little);
    if (pe > bytes.len or bytes.len - pe < 26 or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return .{ .image = false, .signed = false };
    const optional_size = std.mem.readInt(u16, bytes[pe + 20 ..][0..2], .little);
    const directories: usize = switch (std.mem.readInt(u16, bytes[pe + 24 ..][0..2], .little)) {
        0x10b => 96, // PE32
        0x20b => 112, // PE32+
        else => return .{ .image = false, .signed = false },
    };
    const security = 4;
    if (optional_size < directories + (security + 1) * 8) return .{ .image = true, .signed = false };
    const at = pe + 24 + directories - 4;
    if (bytes.len < at + 4 + (security + 1) * 8) return .{ .image = true, .signed = false };
    const count = std.mem.readInt(u32, bytes[at..][0..4], .little);
    const size = std.mem.readInt(u32, bytes[at + 4 + security * 8 + 4 ..][0..4], .little);
    return .{ .image = true, .signed = count > security and size != 0 };
}

test "the signing command lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const windows: Windows = .{ .certificate = "certs/app.pfx" };
    const unix = try command(allocator, windows, "/work/app", "/work/app/dist/app setup.exe", .linux, "osslsigncode", "secret");
    const expected = [_][]const u8{ "osslsigncode", "sign", "-pkcs12", "/work/app/certs/app.pfx", "-h", "sha256", "-ts", default_timestamp_url, "-in", "/work/app/dist/app setup.exe", "-out", "/work/app/dist/app setup.exe.signed", "-pass", "secret" };
    try std.testing.expectEqual(expected.len, unix.len);
    for (expected, unix) |a, b| try std.testing.expectEqualStrings(a, b);
    const tool = try command(allocator, .{ .certificate = "app.pfx", .timestampUrl = "http://ts.example" }, "/work", "/work/app.exe", .windows, "signtool.exe", null);
    try std.testing.expectEqualStrings("http://ts.example", tool[7]);
    try std.testing.expectEqualStrings("/work/app.exe", tool[tool.len - 1]);
    const custom = try command(allocator, .{ .signCommand = "sign-it --file %1" }, "/work", "/tmp/it's.exe", .linux, "", null);
    try std.testing.expectEqualStrings("sign-it --file '/tmp/it'\\''s.exe'", custom[2]);
    const custom_windows = try command(allocator, .{ .signCommand = "sign-it %1" }, "C:\\work", "C:\\a b.exe", .windows, "", null);
    try std.testing.expectEqualStrings("sign-it \"C:\\a b.exe\"", custom_windows[4]);
    try std.testing.expect(!(Windows{}).signs());
}

test "PE images and their signatures are told apart" {
    var bytes = @as([512]u8, @splat(0));
    try std.testing.expect(!peKind(&bytes).image);
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..][0..4], 0x80, .little);
    @memcpy(bytes[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, bytes[0x80 + 20 ..][0..2], 240, .little); // optional header size
    std.mem.writeInt(u16, bytes[0x80 + 24 ..][0..2], 0x20b, .little);
    const count_at = 0x80 + 24 + 112 - 4;
    std.mem.writeInt(u32, bytes[count_at..][0..4], 16, .little);
    try std.testing.expectEqual(PeKind{ .image = true, .signed = false }, peKind(&bytes));
    std.mem.writeInt(u32, bytes[count_at + 4 + 4 * 8 + 4 ..][0..4], 0x1000, .little);
    try std.testing.expectEqual(PeKind{ .image = true, .signed = true }, peKind(&bytes));
    std.mem.writeInt(u16, bytes[0x80 + 24 ..][0..2], 0x10b, .little);
    try std.testing.expect(peKind(&bytes).image);
}
