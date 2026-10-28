const std = @import("std");

/// Binary Debian package writer: an ar archive holding debian-binary and
/// uncompressed control.tar and data.tar members. Output depends only on the
/// inputs and `mtime`, so equal inputs give equal packages.
pub const File = struct { path: []const u8, bytes: []const u8, mode: u32 = 0o644 };
pub const Link = struct { path: []const u8, target: []const u8 };

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    architecture: []const u8,
    maintainer: []const u8,
    description: []const u8,
    depends: []const u8 = "",
    section: []const u8 = "misc",
    homepage: []const u8 = "",
    /// Absolute paths inside the installed system, for example /usr/bin/app.
    files: []const File,
    links: []const Link = &.{},
    postinst: ?[]const u8 = null,
    postrm: ?[]const u8 = null,
    mtime: u64 = 0,
};

pub fn validName(name: []const u8) bool {
    if (name.len < 2 or !std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '+' and byte != '-' and byte != '.') return false;
    return true;
}

fn validField(value: []const u8) bool {
    for (value) |byte| if (byte == '\n' or byte == '\r' or byte < 0x20 and byte != '\t') return false;
    return true;
}

fn validPath(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path[path.len - 1] == '/') return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f or byte == '\\') return false;
    return true;
}

pub fn architecture(arch: std.Target.Cpu.Arch) ![]const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "i386",
        .arm => "armhf",
        .riscv64 => "riscv64",
        else => error.UnsupportedArchitecture,
    };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn write(allocator: std.mem.Allocator, output: *std.Io.Writer, package: Package) !void {
    if (!validName(package.name)) return error.InvalidPackageName;
    if (package.version.len == 0 or !std.ascii.isDigit(package.version[0])) return error.InvalidVersion;
    for (package.version) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".+~-", byte) == null) return error.InvalidVersion;
    for ([_][]const u8{ package.architecture, package.maintainer, package.depends, package.section, package.homepage }) |field| if (!validField(field)) return error.InvalidControlField;
    if (package.maintainer.len == 0 or package.description.len == 0) return error.InvalidControlField;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Every parent directory appears once, sorted, before the entries in it.
    var directories: std.StringArrayHashMapUnmanaged(void) = .empty;
    var installed: u64 = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (package.files) |file| {
        if (!validPath(file.path)) return error.InvalidPath;
        if ((try seen.fetchPut(scratch, file.path, {})) != null) return error.DuplicatePath;
        installed += file.bytes.len;
    }
    for (package.links) |link| {
        if (!validPath(link.path) or link.target.len == 0 or !validField(link.target)) return error.InvalidPath;
        if ((try seen.fetchPut(scratch, link.path, {})) != null) return error.DuplicatePath;
    }
    var paths: std.ArrayList([]const u8) = .empty;
    for (package.files) |file| try paths.append(scratch, file.path);
    for (package.links) |link| try paths.append(scratch, link.path);
    for (paths.items) |path| {
        var end: usize = 1;
        while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) try directories.put(scratch, path[0..slash], {});
    }
    const sorted_directories = try scratch.dupe([]const u8, directories.keys());
    std.mem.sort([]const u8, sorted_directories, {}, lessThan);

    var data: std.Io.Writer.Allocating = .init(scratch);
    var tar: std.tar.Writer = .{ .underlying_writer = &data.writer };
    const options: std.tar.Writer.Options = .{ .mode = 0o755, .mtime = package.mtime };
    try tar.writeDir(".", options);
    for (sorted_directories) |directory| try tar.writeDir(try std.fmt.allocPrint(scratch, ".{s}", .{directory}), options);
    const files = try scratch.dupe(File, package.files);
    std.mem.sort(File, files, {}, struct {
        fn order(_: void, a: File, b: File) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.order);
    var md5sums: std.ArrayList(u8) = .empty;
    for (files) |file| {
        try tar.writeFileBytes(try std.fmt.allocPrint(scratch, ".{s}", .{file.path}), file.bytes, .{ .mode = file.mode, .mtime = package.mtime });
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(file.bytes, &digest, .{});
        try md5sums.print(scratch, "{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), file.path[1..] });
    }
    for (package.links) |link| try tar.writeLink(try std.fmt.allocPrint(scratch, ".{s}", .{link.path}), link.target, .{ .mode = 0o777, .mtime = package.mtime });
    try tar.finishPedantically();

    var control_text: std.ArrayList(u8) = .empty;
    try control_text.print(scratch, "Package: {s}\nVersion: {s}\nArchitecture: {s}\nMaintainer: {s}\nInstalled-Size: {d}\nSection: {s}\nPriority: optional\n", .{ package.name, package.version, package.architecture, package.maintainer, (installed + 1023) / 1024, package.section });
    if (package.depends.len > 0) try control_text.print(scratch, "Depends: {s}\n", .{package.depends});
    if (package.homepage.len > 0) try control_text.print(scratch, "Homepage: {s}\n", .{package.homepage});
    // The first description line is the synopsis; later lines are indented.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, package.description, "\n"), '\n');
    try control_text.print(scratch, "Description: {s}\n", .{lines.next().?});
    while (lines.next()) |line| {
        if (!validField(line)) return error.InvalidControlField;
        try control_text.print(scratch, " {s}\n", .{if (std.mem.trim(u8, line, " ").len == 0) "." else line});
    }
    var control: std.Io.Writer.Allocating = .init(scratch);
    var control_tar: std.tar.Writer = .{ .underlying_writer = &control.writer };
    try control_tar.writeDir(".", options);
    try control_tar.writeFileBytes("./control", control_text.items, .{ .mode = 0o644, .mtime = package.mtime });
    try control_tar.writeFileBytes("./md5sums", md5sums.items, .{ .mode = 0o644, .mtime = package.mtime });
    if (package.postinst) |script| try control_tar.writeFileBytes("./postinst", script, .{ .mode = 0o755, .mtime = package.mtime });
    if (package.postrm) |script| try control_tar.writeFileBytes("./postrm", script, .{ .mode = 0o755, .mtime = package.mtime });
    try control_tar.finishPedantically();

    try output.writeAll("!<arch>\n");
    try member(output, "debian-binary", "2.0\n", package.mtime);
    try member(output, "control.tar", control.written(), package.mtime);
    try member(output, "data.tar", data.written(), package.mtime);
}

fn member(output: *std.Io.Writer, name: []const u8, bytes: []const u8, mtime: u64) !void {
    var header: [60]u8 = @splat(' ');
    @memcpy(header[0..name.len], name);
    _ = try std.fmt.bufPrint(header[16..28], "{d}", .{mtime});
    header[28] = '0';
    header[34] = '0';
    _ = try std.fmt.bufPrint(header[40..48], "100644", .{});
    _ = try std.fmt.bufPrint(header[48..58], "{d}", .{bytes.len});
    header[58] = '`';
    header[59] = '\n';
    try output.writeAll(&header);
    try output.writeAll(bytes);
    if (bytes.len % 2 == 1) try output.writeByte('\n');
}

test "package layout is deterministic and rejects unsafe paths and fields" {
    const allocator = std.testing.allocator;
    const package: Package = .{
        .name = "sample-app",
        .version = "1.2.0.0",
        .architecture = "amd64",
        .maintainer = "Example <dev@example.invalid>",
        .description = "Sample\nA longer description.\n\nSecond paragraph.",
        .depends = "libgtk-3-0",
        .files = &.{ .{ .path = "/usr/lib/sample-app/sample-app", .bytes = "binary", .mode = 0o755 }, .{ .path = "/usr/share/doc/sample-app/copyright", .bytes = "license" } },
        .links = &.{.{ .path = "/usr/bin/sample-app", .target = "../lib/sample-app/sample-app" }},
    };
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try write(allocator, &first.writer, package);
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try write(allocator, &second.writer, package);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    try std.testing.expect(std.mem.startsWith(u8, first.written(), "!<arch>\ndebian-binary   0           0     0     100644  4         `\n2.0\n"));
    var bad = package;
    bad.files = &.{.{ .path = "/usr/../etc/passwd", .bytes = "" }};
    try std.testing.expectError(error.InvalidPath, write(allocator, &first.writer, bad));
    bad = package;
    bad.depends = "x\nPackage: evil";
    try std.testing.expectError(error.InvalidControlField, write(allocator, &first.writer, bad));
    bad = package;
    bad.name = "Bad_Name";
    try std.testing.expectError(error.InvalidPackageName, write(allocator, &first.writer, bad));
}
