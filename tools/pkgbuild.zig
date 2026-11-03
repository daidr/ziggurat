//! The PKGBUILD from which `makepkg -si` packages an app for Arch Linux and
//! installs it. Its source is the app's update package, which makepkg
//! checks against its SHA-256 and extracts, and its package() installs what
//! the Debian package holds: the app in /usr/lib/<name> with the same
//! modes, a link in /usr/bin for each command, the desktop entry and the
//! icon. pacman's hooks refresh the menus and icon caches, so it needs no
//! install script.
const std = @import("std");
const zio = @import("ziggurat_io");

pub const name = "PKGBUILD";

pub const File = struct {
    /// The path inside the update package, which makepkg extracts as it is.
    path: []const u8,
    executable: bool = false,
};

pub const Options = struct {
    /// The Arch Linux package name; see `packageName`.
    pkgname: []const u8,
    /// The app's version, as the update package has it.
    version: []const u8,
    /// The Zig architecture of the build.
    arch: std.Target.Cpu.Arch,
    description: []const u8,
    maintainer: []const u8 = "",
    url: ?[]const u8 = null,
    /// An SPDX expression; none means LicenseRef-custom, the app's own.
    license: ?[]const u8 = null,
    /// Arch Linux packages; see `depends`.
    depends: []const []const u8,
    /// The update package's file name, next to the PKGBUILD.
    source: []const u8,
    /// Its SHA-256, in hex.
    sha256: []const u8,
    /// The files of the update package to install, without package.json.
    files: []const File,
    /// /usr/lib/<pkgname>/<executable>, which the commands and the desktop
    /// entry run.
    executable: []const u8,
    /// Each gets a link in /usr/bin.
    commands: []const []const u8,
    /// The contents of the desktop entry and its file name.
    desktop: []const u8,
    desktop_name: []const u8,
    /// The update package's PNG for the menu, installed as `icon_name`.png.
    icon: ?[]const u8 = null,
    icon_name: []const u8 = "",
    /// The update package's license, installed in /usr/share/licenses.
    license_file: ?[]const u8 = null,
};

/// The architectures of Arch Linux, and of Arch Linux 32 and Arch Linux ARM
/// for those it has not.
pub fn architecture(arch: std.Target.Cpu.Arch) !([]const u8) {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "armv7h",
        .riscv64 => "riscv64",
        else => error.UnsupportedArchitecture,
    };
}

/// The Arch Linux packages of Debian packages that apps commonly depend
/// on, by the Debian name without its "t64" suffix.
const arch_packages = [_][2][]const u8{
    .{ "libgtk-3-0", "gtk3" },
    .{ "libpango-1.0-0", "pango" },
    .{ "libwebkit2gtk-4.1-0", "webkit2gtk-4.1" },
    .{ "libsoup-3.0-0", "libsoup3" },
    .{ "libayatana-appindicator3-1", "libayatana-appindicator" },
    .{ "libnotify4", "libnotify" },
    .{ "libsecret-1-0", "libsecret" },
    .{ "libglib2.0-0", "glib2" },
    .{ "libasound2", "alsa-lib" },
    .{ "libpulse0", "libpulse" },
    .{ "libnss3", "nss" },
    .{ "libssl3", "openssl" },
    .{ "libx11-6", "libx11" },
    .{ "libxtst6", "libxtst" },
    .{ "libepoxy0", "libepoxy" },
    .{ "libvulkan1", "vulkan-icd-loader" },
    .{ "libgl1", "libglvnd" },
    .{ "libegl1", "libglvnd" },
    .{ "libicu74", "icu" },
    .{ "gstreamer1.0-plugins-base", "gst-plugins-base" },
    .{ "gstreamer1.0-plugins-good", "gst-plugins-good" },
    .{ "gstreamer1.0-plugins-bad", "gst-plugins-bad" },
    .{ "gstreamer1.0-plugins-ugly", "gst-plugins-ugly" },
    .{ "gstreamer1.0-libav", "gst-libav" },
    .{ "ffmpeg", "ffmpeg" },
    .{ "xdg-utils", "xdg-utils" },
    .{ "zenity", "zenity" },
    .{ "curl", "curl" },
    .{ "git", "git" },
};

fn archPackage(debian: []const u8) ?[]const u8 {
    const bare = if (std.mem.endsWith(u8, debian, "t64")) debian[0 .. debian.len - 3] else debian;
    for (arch_packages) |pair| if (std.mem.eql(u8, pair[0], bare)) return pair[1];
    return null;
}

pub const Depends = struct {
    depends: []const []const u8,
    /// The Debian dependencies with no Arch Linux package known for them.
    unknown: []const []const u8,
};

/// The Arch Linux packages of a Debian Depends list: each dependency is one
/// package, with its version and architecture left out, or alternatives,
/// of which the first that has one counts.
pub fn depends(allocator: std.mem.Allocator, debian: []const u8) !Depends {
    var found: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.tokenizeScalar(u8, debian, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\n");
        if (entry.len == 0) continue;
        var match: ?[]const u8 = null;
        var alternatives = std.mem.tokenizeScalar(u8, entry, '|');
        while (alternatives.next()) |alternative| {
            var package = std.mem.trim(u8, alternative, " \t");
            package = package[0 .. std.mem.indexOfAny(u8, package, " (:") orelse package.len];
            if (archPackage(package)) |value| {
                match = value;
                break;
            }
        }
        if (match) |value| {
            for (found.items) |existing| {
                if (std.mem.eql(u8, existing, value)) break;
            } else try found.append(allocator, value);
        } else try unknown.append(allocator, entry);
    }
    return .{ .depends = try found.toOwnedSlice(allocator), .unknown = try unknown.toOwnedSlice(allocator) };
}

/// An Arch Linux package name: lower-case letters, digits and @._+-, not
/// starting with a hyphen or a dot.
pub fn packageName(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var replaced = false;
    for (text) |byte| {
        const lower = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lower) and byte < 0x80 or std.mem.indexOfScalar(u8, "@._+-", lower) != null) {
            try output.append(allocator, lower);
            replaced = false;
        } else if (!replaced) {
            try output.append(allocator, '-');
            replaced = true;
        }
    }
    const trimmed = std.mem.trimStart(u8, output.items, "-.");
    const end = std.mem.trimEnd(u8, trimmed, "-");
    if (end.len == 0) return "app";
    return allocator.dupe(u8, end);
}

/// A pkgver, which holds letters, digits, periods and underscores. vercmp
/// sorts a version whose rest after the release starts with a letter
/// before the release (1.2.0rc.1 < 1.2.0), so a pre-release follows the
/// release without its hyphen (1.2.0beta.1 of 1.2.0-beta.1), and with
/// "pre" when it starts with a digit (1.2.0pre1 of 1.2.0-1). Build
/// metadata follows with an underscore (1.2.0_build.5 of 1.2.0+build.5),
/// which sorts after the version without it, as a rebuild. Any other
/// character becomes an underscore.
pub fn version(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var rest = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    var build: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        build = rest[plus + 1 ..];
        rest = rest[0..plus];
    }
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |hyphen| {
        pre = rest[hyphen + 1 ..];
        rest = rest[0..hyphen];
    }
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, rest);
    if (pre.len > 0 and std.ascii.isDigit(pre[0])) try output.appendSlice(allocator, "pre");
    try output.appendSlice(allocator, pre);
    if (build.len > 0) {
        try output.append(allocator, '_');
        try output.appendSlice(allocator, build);
    }
    // Runs of other characters become one underscore.
    var cleaned: std.ArrayList(u8) = .empty;
    var replaced = false;
    for (output.items) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_') {
            try cleaned.append(allocator, byte);
            replaced = false;
        } else if (!replaced) {
            try cleaned.append(allocator, '_');
            replaced = true;
        }
    }
    if (cleaned.items.len == 0) return "0";
    return cleaned.toOwnedSlice(allocator);
}

/// Quotes `text` for bash in single quotes.
fn quote(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |byte| {
        if (byte == '\'') try writer.writeAll("'\\''") else try writer.writeByte(byte);
    }
    try writer.writeByte('\'');
}

/// A word bash reads as it is, else quoted.
fn word(writer: *std.Io.Writer, text: []const u8) !void {
    const plain = text.len > 0 and for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "@%+=:,./_-", byte) == null) break false;
    } else true;
    if (plain) try writer.writeAll(text) else try quote(writer, text);
}

fn array(writer: *std.Io.Writer, items: []const []const u8) !void {
    try writer.writeByte('(');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(' ');
        try quote(writer, item);
    }
    try writer.writeByte(')');
}

pub fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    for (options.commands) |command| if (std.mem.indexOfAny(u8, command, "/\n") != null) return error.InvalidCommandName;
    if (options.maintainer.len > 0) {
        try writer.writeAll("# Maintainer: ");
        var parts = std.mem.tokenizeAny(u8, options.maintainer, " \t\r\n");
        var first = true;
        while (parts.next()) |part| {
            if (!first) try writer.writeByte(' ');
            try writer.writeAll(part);
            first = false;
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("# Written by ziggurat package pkgbuild next to the app's update package:\n# makepkg -si packages the app for Arch Linux and installs it.\n");
    try writer.writeAll("pkgname=");
    try quote(writer, options.pkgname);
    try writer.writeAll("\npkgver=");
    try quote(writer, try version(allocator, options.version));
    try writer.writeAll("\npkgrel=1\npkgdesc=");
    try quote(writer, options.description);
    try writer.writeAll("\narch=");
    try array(writer, &.{try architecture(options.arch)});
    if (options.url) |url| {
        try writer.writeAll("\nurl=");
        try quote(writer, url);
    }
    try writer.writeAll("\nlicense=");
    try array(writer, &.{options.license orelse "LicenseRef-custom"});
    try writer.writeAll("\ndepends=");
    try array(writer, options.depends);
    // The executable as built, as the Debian package has it.
    try writer.writeAll("\noptions=('!strip' '!debug')\nsource=");
    try array(writer, &.{options.source});
    try writer.writeAll("\nsha256sums=");
    try array(writer, &.{options.sha256});
    try writer.writeAll("\n\npackage() {\n\tcd \"$srcdir\"\n");
    const lib = try std.fmt.allocPrint(allocator, "usr/lib/{s}", .{options.pkgname});
    // The modes of the Debian package: 755 for the executable, 644 for the
    // other files.
    for (options.files) |file| {
        try writer.writeAll(if (file.executable) "\tinstall -Dm755 " else "\tinstall -Dm644 ");
        try word(writer, file.path);
        try writer.writeAll(" \"$pkgdir\"/");
        try word(writer, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ lib, file.path }));
        try writer.writeByte('\n');
    }
    if (options.commands.len > 0) try writer.writeAll("\tinstall -d \"$pkgdir\"/usr/bin\n");
    for (options.commands) |command| {
        try writer.writeAll("\tln -s ");
        try word(writer, try std.fmt.allocPrint(allocator, "../lib/{s}/{s}", .{ options.pkgname, options.executable }));
        try writer.writeAll(" \"$pkgdir\"/");
        try word(writer, try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{command}));
        try writer.writeByte('\n');
    }
    try writer.writeAll("\tprintf '%s' ");
    try quote(writer, options.desktop);
    try writer.writeAll(" |\n\t\tinstall -Dm644 /dev/stdin \"$pkgdir\"/");
    try word(writer, try std.fmt.allocPrint(allocator, "usr/share/applications/{s}.desktop", .{options.desktop_name}));
    try writer.writeByte('\n');
    if (options.icon) |icon| {
        try writer.writeAll("\tinstall -Dm644 ");
        try word(writer, icon);
        try writer.writeAll(" \"$pkgdir\"/");
        try word(writer, try std.fmt.allocPrint(allocator, "usr/share/icons/hicolor/256x256/apps/{s}.png", .{options.icon_name}));
        try writer.writeByte('\n');
    }
    if (options.license_file) |license| {
        try writer.writeAll("\tinstall -Dm644 ");
        try word(writer, license);
        try writer.writeAll(" \"$pkgdir\"/");
        try word(writer, try std.fmt.allocPrint(allocator, "usr/share/licenses/{s}/LICENSE", .{options.pkgname}));
        try writer.writeByte('\n');
    }
    try writer.writeAll("}\n");
}

test "pkgver keeps the order of semantic versions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "1.2.0", "1.2.0" },
        .{ "v1.2.0", "1.2.0" },
        .{ "1.2.0.4", "1.2.0.4" },
        .{ "1.2.0-beta.1", "1.2.0beta.1" },
        .{ "1.2.0-rc.1", "1.2.0rc.1" },
        .{ "1.2.0-alpha-2", "1.2.0alpha_2" },
        .{ "1.2.0-1", "1.2.0pre1" },
        .{ "1.2.0-0.3.7", "1.2.0pre0.3.7" },
        .{ "1.2.0+build.5", "1.2.0_build.5" },
        .{ "1.2.0-beta.1+exp.sha", "1.2.0beta.1_exp.sha" },
        .{ "1.2 final", "1.2_final" },
        .{ "", "0" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try version(allocator, case[0]));
}

test "package names are what pacman takes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_][2][]const u8{ .{ "my-app", "my-app" }, .{ "My App", "my-app" }, .{ "-app", "app" }, .{ ".app_2", "app_2" }, .{ "云", "app" } };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try packageName(allocator, case[0]));
}

test "Debian dependencies map to Arch Linux packages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try depends(allocator, "libgtk-3-0t64 | libgtk-3-0, libpango-1.0-0, libnotify4, libasound2t64 (>= 1.2), libfoo1 | libsecret-1-0:any, libgtk-3-0, libfoo2");
    try std.testing.expectEqual(@as(usize, 5), result.depends.len);
    for ([_][]const u8{ "gtk3", "pango", "libnotify", "alsa-lib", "libsecret" }, result.depends) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 1), result.unknown.len);
    try std.testing.expectEqualStrings("libfoo2", result.unknown[0]);
}

test "package() installs what the Debian package does" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(allocator);
    try write(allocator, &output.writer, .{
        .pkgname = "sample-app",
        .version = "1.2.0-beta.1",
        .arch = .x86_64,
        .description = "Sample's app",
        .maintainer = "Sam  Ple <sam@example.com>",
        .depends = &.{ "gtk3", "pango" },
        .source = "sample-app-1.2.0-beta.1-linux-x86_64.zip",
        .sha256 = "00ff",
        .files = &.{ .{ .path = "sample-app", .executable = true }, .{ .path = "assets/a b.txt" }, .{ .path = "icon.png" }, .{ .path = "LICENSE.txt" } },
        .executable = "sample-app",
        .commands = &.{ "sample-app", "sa" },
        .desktop = "[Desktop Entry]\nName=It's\n",
        .desktop_name = "dev.sample.app",
        .icon = "icon.png",
        .icon_name = "dev.sample.app",
        .license_file = "LICENSE.txt",
    });
    const text = output.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "# Maintainer: Sam Ple <sam@example.com>\n"));
    for ([_][]const u8{ "pkgname='sample-app'\n", "pkgver='1.2.0beta.1'\n", "pkgdesc='Sample'\\''s app'\n", "arch=('x86_64')\n", "license=('LicenseRef-custom')\n", "depends=('gtk3' 'pango')\n", "sha256sums=('00ff')\n" }) |line|
        try std.testing.expect(std.mem.indexOf(u8, text, line) != null);

    // Run package() as makepkg does, over the files the update package holds.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = zio.io();
    try tmp.dir.createDirPath(io, "src/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample-app", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/assets/a b.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/icon.png", .data = "png" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/LICENSE.txt", .data = "MIT" });
    try tmp.dir.writeFile(io, .{ .sub_path = "PKGBUILD", .data = text });
    const base = try zio.realPathAlloc(tmp.dir, ".", allocator);
    const script = try std.fmt.allocPrint(allocator, "set -e; srcdir='{0s}/src'; pkgdir='{0s}/pkg'; . '{0s}/PKGBUILD'; package", .{base});
    const result = try zio.run(allocator, .{ .argv = &.{ "bash", "-c", script } });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const expected = [_]struct { path: []const u8, mode: u32 }{
        .{ .path = "pkg/usr/lib/sample-app/sample-app", .mode = 0o755 },
        .{ .path = "pkg/usr/lib/sample-app/assets/a b.txt", .mode = 0o644 },
        .{ .path = "pkg/usr/share/applications/dev.sample.app.desktop", .mode = 0o644 },
        .{ .path = "pkg/usr/share/icons/hicolor/256x256/apps/dev.sample.app.png", .mode = 0o644 },
        .{ .path = "pkg/usr/share/licenses/sample-app/LICENSE", .mode = 0o644 },
    };
    for (expected) |entry| {
        const stat = try tmp.dir.statFile(io, entry.path, .{});
        try std.testing.expectEqual(entry.mode, @as(u32, @intCast(zio.modeOf(stat.permissions) & 0o777)));
    }
    const desktop = try tmp.dir.readFileAlloc(io, "pkg/usr/share/applications/dev.sample.app.desktop", allocator, .limited(4096));
    try std.testing.expectEqualStrings("[Desktop Entry]\nName=It's\n", desktop);
    for ([_][]const u8{ "pkg/usr/bin/sample-app", "pkg/usr/bin/sa" }) |link| {
        var buffer: [256]u8 = undefined;
        const length = try tmp.dir.readLink(io, link, &buffer);
        try std.testing.expectEqualStrings("../lib/sample-app/sample-app", buffer[0..length]);
    }
}
