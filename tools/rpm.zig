const std = @import("std");
const flate = std.compress.flate;

/// Binary RPM package writer (format version 4, as rpm 4.x reads): the lead,
/// a signature header with the header's and payload's digests, the header,
/// and a gzip-compressed cpio (newc) payload. Output depends only on the
/// inputs and `mtime`, so equal inputs give equal packages.
pub const File = struct { path: []const u8, bytes: []const u8, mode: u32 = 0o644 };
pub const Link = struct { path: []const u8, target: []const u8 };

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    release: []const u8 = "1",
    /// RPM's name of the architecture, such as "x86_64"; see `architecture`.
    architecture: []const u8,
    summary: []const u8,
    description: []const u8,
    license: []const u8,
    packager: []const u8 = "",
    url: []const u8 = "",
    group: []const u8 = "Unspecified",
    /// Capabilities the package needs, each a package or a shared library's
    /// SONAME such as "libgtk-3.so.0()(64bit)".
    requires: []const []const u8 = &.{},
    /// Absolute paths inside the installed system, for example /usr/bin/app.
    files: []const File,
    links: []const Link = &.{},
    /// Directories the package owns, removed with it, such as
    /// /usr/lib/app. Their subdirectories that hold files are owned too.
    directories: []const []const u8 = &.{},
    /// Shell scripts run after install and after removal.
    postin: ?[]const u8 = null,
    postun: ?[]const u8 = null,
    mtime: u64 = 0,
};

pub fn architecture(arch: std.Target.Cpu.Arch) ![]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i386",
        .arm => "armv7hl",
        .riscv64 => "riscv64",
        else => error.UnsupportedArchitecture,
    };
}

/// Shared libraries carry "()(64bit)" in the capability names of 64-bit
/// systems.
pub fn sonameSuffix(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64, .aarch64, .riscv64 => "()(64bit)",
        else => "",
    };
}

/// An RPM version of a release's version: a pre-release sorts before its
/// release with "~", build metadata follows with "+", and any other byte an
/// RPM version cannot hold, the dash among them, becomes "_".
pub fn version(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var rest = if (std.mem.startsWith(u8, text, "v")) text[1..] else text;
    var build: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        build = rest[plus + 1 ..];
        rest = rest[0..plus];
    }
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        pre = rest[dash + 1 ..];
        rest = rest[0..dash];
    }
    var output: std.ArrayList(u8) = .empty;
    try appendVersion(allocator, &output, rest);
    if (pre.len > 0) {
        try output.append(allocator, '~');
        try appendVersion(allocator, &output, pre);
    }
    if (build.len > 0) {
        try output.append(allocator, '+');
        try appendVersion(allocator, &output, build);
    }
    if (output.items.len == 0) try output.append(allocator, '0');
    return output.toOwnedSlice(allocator);
}

fn appendVersion(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    var replaced = false;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "._+~^", byte) != null) {
            try output.append(allocator, byte);
            replaced = false;
        } else if (!replaced) {
            try output.append(allocator, '_');
            replaced = true;
        }
    }
}

/// The RPM capabilities of Debian packages that apps commonly depend on, by
/// the Debian name without its "t64" suffix; shared libraries by SONAME.
const rpm_packages = [_]struct { []const u8, []const []const u8 }{
    .{ "libgtk-3-0", &.{"libgtk-3.so.0"} },
    .{ "libpango-1.0-0", &.{"libpango-1.0.so.0"} },
    .{ "libwebkit2gtk-4.1-0", &.{"libwebkit2gtk-4.1.so.0"} },
    .{ "libayatana-appindicator3-1", &.{"libayatana-appindicator3.so.1"} },
    .{ "libnotify4", &.{"libnotify.so.4"} },
    .{ "libsecret-1-0", &.{"libsecret-1.so.0"} },
    .{ "libsoup-3.0-0", &.{"libsoup-3.0.so.0"} },
    .{ "libglib2.0-0", &.{ "libglib-2.0.so.0", "libgio-2.0.so.0", "libgobject-2.0.so.0", "libgmodule-2.0.so.0", "libgthread-2.0.so.0" } },
    .{ "libasound2", &.{"libasound.so.2"} },
    .{ "libpulse0", &.{"libpulse.so.0"} },
    .{ "libnss3", &.{"libnss3.so"} },
    .{ "libssl3", &.{"libssl.so.3"} },
    .{ "libx11-6", &.{"libX11.so.6"} },
    .{ "libxtst6", &.{"libXtst.so.6"} },
    .{ "libepoxy0", &.{"libepoxy.so.0"} },
    .{ "libvulkan1", &.{"libvulkan.so.1"} },
    .{ "libgl1", &.{"libGL.so.1"} },
    .{ "libegl1", &.{"libEGL.so.1"} },
    .{ "ffmpeg", &.{"/usr/bin/ffmpeg"} },
    .{ "xdg-utils", &.{"xdg-utils"} },
    .{ "zenity", &.{"zenity"} },
    .{ "curl", &.{"curl"} },
    .{ "git", &.{"git"} },
};

fn rpmPackage(debian: []const u8) ?[]const []const u8 {
    const bare = if (std.mem.endsWith(u8, debian, "t64")) debian[0 .. debian.len - 3] else debian;
    for (rpm_packages) |pair| if (std.mem.eql(u8, pair[0], bare)) return pair[1];
    return null;
}

pub const Depends = struct {
    requires: []const []const u8,
    /// The Debian dependencies with no RPM capability known for them.
    unknown: []const []const u8,
};

/// The RPM capabilities of a Debian Depends list: each dependency, with its
/// version and architecture left out, or alternatives, of which the first
/// that has one counts. Shared libraries get `suffix`.
pub fn depends(allocator: std.mem.Allocator, debian: []const u8, suffix: []const u8) !Depends {
    var found: std.ArrayList([]const u8) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var entries = std.mem.tokenizeScalar(u8, debian, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\n");
        if (entry.len == 0) continue;
        var match: ?[]const []const u8 = null;
        var alternatives = std.mem.tokenizeScalar(u8, entry, '|');
        while (alternatives.next()) |alternative| {
            var package = std.mem.trim(u8, alternative, " \t");
            package = package[0 .. std.mem.indexOfAny(u8, package, " (:") orelse package.len];
            if (rpmPackage(package)) |value| {
                match = value;
                break;
            }
        }
        const values = match orelse {
            try unknown.append(allocator, entry);
            continue;
        };
        for (values) |value| {
            const capability = if (std.mem.indexOf(u8, value, ".so") != null and value[0] != '/') try std.mem.concat(allocator, u8, &.{ value, suffix }) else value;
            for (found.items) |existing| {
                if (std.mem.eql(u8, existing, capability)) break;
            } else try found.append(allocator, capability);
        }
    }
    return .{ .requires = try found.toOwnedSlice(allocator), .unknown = try unknown.toOwnedSlice(allocator) };
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[0] == '.') return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._+-", byte) == null) return false;
    return true;
}

fn validVersion(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._+~^", byte) == null) return false;
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

// Header tags and types, as rpm's rpmtag.h numbers them.
const Type = enum(u32) { int16 = 3, int32 = 4, string = 6, bin = 7, string_array = 8, i18n_string = 9 };
const tag = struct {
    const header_signatures = 62;
    const header_immutable = 63;
    const i18n_table = 100;
    const sig_sha1 = 269;
    const sig_sha256 = 273;
    const sig_size = 1000;
    const sig_md5 = 1004;
    const sig_payload_size = 1007;
    const name = 1000;
    const version = 1001;
    const release = 1002;
    const summary = 1004;
    const description = 1005;
    const build_time = 1006;
    const build_host = 1007;
    const size = 1009;
    const license = 1014;
    const packager = 1015;
    const group = 1016;
    const url = 1020;
    const os = 1021;
    const arch = 1022;
    const postin = 1024;
    const postun = 1026;
    const file_sizes = 1028;
    const file_modes = 1030;
    const file_rdevs = 1033;
    const file_mtimes = 1034;
    const file_digests = 1035;
    const file_linktos = 1036;
    const file_flags = 1037;
    const file_username = 1039;
    const file_groupname = 1040;
    const source_rpm = 1044;
    const provide_name = 1047;
    const require_flags = 1048;
    const require_name = 1049;
    const require_version = 1050;
    const rpm_version = 1064;
    const postin_prog = 1086;
    const postun_prog = 1088;
    const file_devices = 1095;
    const file_inodes = 1096;
    const file_langs = 1097;
    const provide_flags = 1112;
    const provide_version = 1113;
    const dir_indexes = 1116;
    const base_names = 1117;
    const dir_names = 1118;
    const payload_format = 1124;
    const payload_compressor = 1125;
    const payload_flags = 1126;
    const file_digest_algo = 5011;
    const payload_digest = 5092;
    const payload_digest_algo = 5093;
};
const sense_less = 1 << 1;
const sense_equal = 1 << 3;
const sense_interp = 1 << 8;
const sense_script_post = 1 << 10;
const sense_script_postun = 1 << 12;
const sense_rpmlib = 1 << 24;
const digest_sha256 = 8;

/// One header under construction: entries are added in ascending tag
/// order, each with its data aligned in the store after the one before.
const Header = struct {
    allocator: std.mem.Allocator,
    index: std.ArrayList([4]u32) = .empty,
    store: std.ArrayList(u8) = .empty,

    fn add(self: *Header, number: u32, kind: Type, count: usize, bytes: []const u8) !void {
        const alignment: usize = switch (kind) {
            .int16 => 2,
            .int32 => 4,
            else => 1,
        };
        while (self.store.items.len % alignment != 0) try self.store.append(self.allocator, 0);
        try self.index.append(self.allocator, .{ number, @backingInt(kind), @intCast(self.store.items.len), @intCast(count) });
        try self.store.appendSlice(self.allocator, bytes);
    }
    fn string(self: *Header, number: u32, value: []const u8) !void {
        try self.add(number, .string, 1, try std.mem.concat(self.allocator, u8, &.{ value, "\x00" }));
    }
    fn i18n(self: *Header, number: u32, value: []const u8) !void {
        try self.add(number, .i18n_string, 1, try std.mem.concat(self.allocator, u8, &.{ value, "\x00" }));
    }
    fn strings(self: *Header, number: u32, values: []const []const u8) !void {
        var bytes: std.ArrayList(u8) = .empty;
        for (values) |value| {
            try bytes.appendSlice(self.allocator, value);
            try bytes.append(self.allocator, 0);
        }
        try self.add(number, .string_array, values.len, bytes.items);
    }
    fn int32s(self: *Header, number: u32, values: []const u32) !void {
        const bytes = try self.allocator.alloc(u8, values.len * 4);
        for (values, 0..) |value, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], value, .big);
        try self.add(number, .int32, values.len, bytes);
    }
    fn int32(self: *Header, number: u32, value: u32) !void {
        try self.int32s(number, &.{value});
    }
    fn int16s(self: *Header, number: u32, values: []const u16) !void {
        const bytes = try self.allocator.alloc(u8, values.len * 2);
        for (values, 0..) |value, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], value, .big);
        try self.add(number, .int16, values.len, bytes);
    }

    /// The header's bytes, with the region tag's entry first and its
    /// trailer at the end of the store.
    fn finish(self: *Header, region: u32) ![]u8 {
        const count: u32 = @intCast(self.index.items.len + 1);
        var output: std.ArrayList(u8) = .empty;
        try output.appendSlice(self.allocator, &.{ 0x8e, 0xad, 0xe8, 0x01, 0, 0, 0, 0 });
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, count, .big);
        try output.appendSlice(self.allocator, &word);
        std.mem.writeInt(u32, &word, @intCast(self.store.items.len + 16), .big);
        try output.appendSlice(self.allocator, &word);
        const trailer_offset: u32 = @intCast(self.store.items.len);
        try appendEntry(self.allocator, &output, .{ region, @backingInt(Type.bin), trailer_offset, 16 });
        for (self.index.items) |entry| try appendEntry(self.allocator, &output, entry);
        try output.appendSlice(self.allocator, self.store.items);
        const back: i32 = -@as(i32, @intCast(count * 16));
        try appendEntry(self.allocator, &output, .{ region, @backingInt(Type.bin), @bitCast(back), 16 });
        return output.toOwnedSlice(self.allocator);
    }
};

fn appendEntry(allocator: std.mem.Allocator, output: *std.ArrayList(u8), entry: [4]u32) !void {
    var bytes: [16]u8 = undefined;
    for (entry, 0..) |value, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], value, .big);
    try output.appendSlice(allocator, &bytes);
}

const Entry = struct {
    path: []const u8,
    mode: u32,
    bytes: []const u8 = "",
    target: []const u8 = "",
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.path, b.path) == .lt;
    }
};

pub fn write(allocator: std.mem.Allocator, output: *std.Io.Writer, package: Package) !void {
    if (!validName(package.name)) return error.InvalidPackageName;
    if (!validVersion(package.version) or !validVersion(package.release) or std.mem.indexOfScalar(u8, package.release, '-') != null) return error.InvalidVersion;
    for ([_][]const u8{ package.architecture, package.summary, package.license, package.packager, package.url, package.group }) |field| if (!validField(field)) return error.InvalidHeaderField;
    for (package.requires) |field| if (field.len == 0 or !validField(field) or std.mem.indexOfAny(u8, field, " \t,") != null) return error.InvalidHeaderField;
    if (package.summary.len == 0 or package.description.len == 0 or package.license.len == 0 or package.architecture.len == 0) return error.InvalidHeaderField;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var installed: u64 = 0;
    for (package.files) |file| {
        if (!validPath(file.path)) return error.InvalidPath;
        if ((try seen.fetchPut(scratch, file.path, {})) != null) return error.DuplicatePath;
        try entries.append(scratch, .{ .path = file.path, .mode = 0o100000 | (file.mode & 0o7777), .bytes = file.bytes });
        installed += file.bytes.len;
    }
    for (package.links) |link| {
        if (!validPath(link.path) or link.target.len == 0 or !validField(link.target)) return error.InvalidPath;
        if ((try seen.fetchPut(scratch, link.path, {})) != null) return error.DuplicatePath;
        try entries.append(scratch, .{ .path = link.path, .mode = 0o120777, .target = link.target });
        installed += link.target.len;
    }
    // The owned directories, and every directory between one and what it
    // holds.
    for (package.directories) |directory| {
        if (!validPath(directory)) return error.InvalidPath;
        if ((try seen.fetchPut(scratch, directory, {})) != null) return error.DuplicatePath;
        try entries.append(scratch, .{ .path = directory, .mode = 0o040755 });
    }
    var between: std.ArrayList([]const u8) = .empty;
    for (package.directories) |directory| {
        for (entries.items) |entry| {
            if (entry.path.len <= directory.len + 1 or !std.mem.startsWith(u8, entry.path, directory) or entry.path[directory.len] != '/') continue;
            var end = directory.len + 1;
            while (std.mem.indexOfScalarPos(u8, entry.path, end, '/')) |slash| : (end = slash + 1) {
                const parent = entry.path[0..slash];
                if ((try seen.fetchPut(scratch, parent, {})) == null) try between.append(scratch, parent);
            }
        }
    }
    for (between.items) |parent| try entries.append(scratch, .{ .path = parent, .mode = 0o040755 });
    std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

    // The payload: a cpio archive of every entry, paths prefixed with ".".
    var cpio: std.Io.Writer.Allocating = .init(scratch);
    for (entries.items, 1..) |entry, inode| {
        const data = if (entry.mode & 0o170000 == 0o120000) entry.target else entry.bytes;
        try cpioEntry(&cpio.writer, try std.mem.concat(scratch, u8, &.{ ".", entry.path }), @intCast(inode), entry.mode, @intCast(package.mtime), data);
    }
    try cpioEntry(&cpio.writer, "TRAILER!!!", 0, 0, 0, "");
    const archive = cpio.written();
    var compressed: std.Io.Writer.Allocating = try .initCapacity(scratch, archive.len / 2 + 1024);
    const window = try scratch.alloc(u8, flate.max_window_len);
    const compress = try scratch.create(flate.Compress);
    compress.* = try .init(&compressed.writer, window, .gzip, .default);
    try compress.writer.writeAll(archive);
    try compress.finish();
    const payload = compressed.written();

    // The header.
    const count = entries.items.len;
    var directories: std.ArrayList([]const u8) = .empty;
    const dir_indexes = try scratch.alloc(u32, count);
    const base_names = try scratch.alloc([]const u8, count);
    const sizes = try scratch.alloc(u32, count);
    const modes = try scratch.alloc(u16, count);
    const rdevs = try scratch.alloc(u16, count);
    const mtimes = try scratch.alloc(u32, count);
    const digests = try scratch.alloc([]const u8, count);
    const link_targets = try scratch.alloc([]const u8, count);
    const flags = try scratch.alloc(u32, count);
    const users = try scratch.alloc([]const u8, count);
    const devices = try scratch.alloc(u32, count);
    const inodes = try scratch.alloc(u32, count);
    const langs = try scratch.alloc([]const u8, count);
    for (entries.items, 0..) |entry, i| {
        const slash = std.mem.lastIndexOfScalar(u8, entry.path, '/').?;
        const directory = entry.path[0 .. slash + 1];
        dir_indexes[i] = for (directories.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, directory)) break @intCast(index);
        } else blk: {
            try directories.append(scratch, directory);
            break :blk @intCast(directories.items.len - 1);
        };
        base_names[i] = entry.path[slash + 1 ..];
        const link = entry.mode & 0o170000 == 0o120000;
        const regular = entry.mode & 0o170000 == 0o100000;
        sizes[i] = if (link) @intCast(entry.target.len) else if (regular) @intCast(entry.bytes.len) else 4096;
        modes[i] = @intCast(entry.mode);
        rdevs[i] = 0;
        mtimes[i] = @intCast(package.mtime);
        if (regular) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(entry.bytes, &digest, .{});
            digests[i] = try scratch.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        } else digests[i] = "";
        link_targets[i] = entry.target;
        flags[i] = 0;
        users[i] = "root";
        devices[i] = 1;
        inodes[i] = @intCast(i + 1);
        langs[i] = "";
    }

    var requires: std.ArrayList([]const u8) = .empty;
    var require_flags: std.ArrayList(u32) = .empty;
    var require_versions: std.ArrayList([]const u8) = .empty;
    for (package.requires) |name| {
        try requires.append(scratch, name);
        try require_flags.append(scratch, 0);
        try require_versions.append(scratch, "");
    }
    if (package.postin != null or package.postun != null) {
        try requires.append(scratch, "/bin/sh");
        try require_flags.append(scratch, sense_interp | (if (package.postin != null) @as(u32, sense_script_post) else 0) | (if (package.postun != null) @as(u32, sense_script_postun) else 0));
        try require_versions.append(scratch, "");
    }
    for ([_][2][]const u8{ .{ "rpmlib(CompressedFileNames)", "3.0.4-1" }, .{ "rpmlib(FileDigests)", "4.6.0-1" }, .{ "rpmlib(PayloadFilesHavePrefix)", "4.0-1" } }) |pair| {
        try requires.append(scratch, pair[0]);
        try require_flags.append(scratch, sense_rpmlib | sense_less | sense_equal);
        try require_versions.append(scratch, pair[1]);
    }

    var payload_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &payload_digest, .{});
    const full_version = try std.fmt.allocPrint(scratch, "{s}-{s}", .{ package.version, package.release });

    var header: Header = .{ .allocator = scratch };
    try header.strings(tag.i18n_table, &.{"C"});
    try header.string(tag.name, package.name);
    try header.string(tag.version, package.version);
    try header.string(tag.release, package.release);
    try header.i18n(tag.summary, package.summary);
    try header.i18n(tag.description, package.description);
    try header.int32(tag.build_time, @intCast(package.mtime));
    try header.string(tag.build_host, "localhost");
    try header.int32(tag.size, std.math.cast(u32, installed) orelse return error.PackageTooLarge);
    try header.string(tag.license, package.license);
    if (package.packager.len > 0) try header.string(tag.packager, package.packager);
    try header.i18n(tag.group, package.group);
    if (package.url.len > 0) try header.string(tag.url, package.url);
    try header.string(tag.os, "linux");
    try header.string(tag.arch, package.architecture);
    if (package.postin) |script| try header.string(tag.postin, script);
    if (package.postun) |script| try header.string(tag.postun, script);
    try header.int32s(tag.file_sizes, sizes);
    try header.int16s(tag.file_modes, modes);
    try header.int16s(tag.file_rdevs, rdevs);
    try header.int32s(tag.file_mtimes, mtimes);
    try header.strings(tag.file_digests, digests);
    try header.strings(tag.file_linktos, link_targets);
    try header.int32s(tag.file_flags, flags);
    try header.strings(tag.file_username, users);
    try header.strings(tag.file_groupname, users);
    try header.string(tag.source_rpm, try std.fmt.allocPrint(scratch, "{s}-{s}.src.rpm", .{ package.name, full_version }));
    try header.strings(tag.provide_name, &.{package.name});
    try header.int32s(tag.require_flags, require_flags.items);
    try header.strings(tag.require_name, requires.items);
    try header.strings(tag.require_version, require_versions.items);
    try header.string(tag.rpm_version, "4.16.0");
    if (package.postin != null) try header.string(tag.postin_prog, "/bin/sh");
    if (package.postun != null) try header.string(tag.postun_prog, "/bin/sh");
    try header.int32s(tag.file_devices, devices);
    try header.int32s(tag.file_inodes, inodes);
    try header.strings(tag.file_langs, langs);
    try header.int32s(tag.provide_flags, &.{sense_equal});
    try header.strings(tag.provide_version, &.{full_version});
    try header.int32s(tag.dir_indexes, dir_indexes);
    try header.strings(tag.base_names, base_names);
    try header.strings(tag.dir_names, directories.items);
    try header.string(tag.payload_format, "cpio");
    try header.string(tag.payload_compressor, "gzip");
    try header.string(tag.payload_flags, "9");
    try header.int32(tag.file_digest_algo, digest_sha256);
    try header.strings(tag.payload_digest, &.{&std.fmt.bytesToHex(payload_digest, .lower)});
    try header.int32(tag.payload_digest_algo, digest_sha256);
    const header_bytes = try header.finish(tag.header_immutable);

    // The signature: digests of the header, and of the header and payload.
    var sha1: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(header_bytes, &sha1, .{});
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header_bytes, &sha256, .{});
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(header_bytes);
    md5.update(payload);
    var md5_digest: [16]u8 = undefined;
    md5.final(&md5_digest);
    var signature: Header = .{ .allocator = scratch };
    try signature.string(tag.sig_sha1, &std.fmt.bytesToHex(sha1, .lower));
    try signature.string(tag.sig_sha256, &std.fmt.bytesToHex(sha256, .lower));
    try signature.int32(tag.sig_size, std.math.cast(u32, header_bytes.len + payload.len) orelse return error.PackageTooLarge);
    try signature.add(tag.sig_md5, .bin, 16, &md5_digest);
    try signature.int32(tag.sig_payload_size, std.math.cast(u32, archive.len) orelse return error.PackageTooLarge);
    const signature_bytes = try signature.finish(tag.header_signatures);

    // The lead: rpm reads only its magic and type now.
    var lead: [96]u8 = @splat(0);
    lead[0..4].* = .{ 0xed, 0xab, 0xee, 0xdb };
    lead[4] = 3;
    lead[5] = 0;
    std.mem.writeInt(u16, lead[6..8], 0, .big);
    std.mem.writeInt(u16, lead[8..10], 1, .big);
    const lead_name = try std.fmt.allocPrint(scratch, "{s}-{s}", .{ package.name, full_version });
    const shown = @min(lead_name.len, 65);
    @memcpy(lead[10..][0..shown], lead_name[0..shown]);
    std.mem.writeInt(u16, lead[76..78], 1, .big);
    std.mem.writeInt(u16, lead[78..80], 5, .big);

    try output.writeAll(&lead);
    try output.writeAll(signature_bytes);
    try output.splatByteAll(0, (8 - signature_bytes.len % 8) % 8);
    try output.writeAll(header_bytes);
    try output.writeAll(payload);
}

fn cpioEntry(output: *std.Io.Writer, name: []const u8, inode: u32, mode: u32, mtime: u32, data: []const u8) !void {
    const nlink: u32 = if (mode & 0o170000 == 0o040000) 2 else 1;
    try output.print("070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{ inode, mode, 0, 0, if (std.mem.eql(u8, name, "TRAILER!!!")) 1 else nlink, mtime, data.len, 0, 0, 0, 0, name.len + 1, 0 });
    try output.writeAll(name);
    try output.writeByte(0);
    try output.splatByteAll(0, (4 - (110 + name.len + 1) % 4) % 4);
    try output.writeAll(data);
    try output.splatByteAll(0, (4 - data.len % 4) % 4);
}

test "versions and dependencies in RPM's terms" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1.2.0~rc.1", try version(allocator, "v1.2.0-rc.1"));
    try std.testing.expectEqualStrings("1.2.0~beta_1+build.5", try version(allocator, "1.2.0-beta-1+build.5"));
    try std.testing.expectEqualStrings("1.0.0.0", try version(allocator, "1.0.0.0"));
    try std.testing.expectEqualStrings("0", try version(allocator, ""));
    const mapped = try depends(allocator, "libgtk-3-0t64 | libgtk-3-0, libpango-1.0-0, libfoo1 (>= 2), xdg-utils, ffmpeg", "()(64bit)");
    try std.testing.expectEqual(4, mapped.requires.len);
    try std.testing.expectEqualStrings("libgtk-3.so.0()(64bit)", mapped.requires[0]);
    try std.testing.expectEqualStrings("libpango-1.0.so.0()(64bit)", mapped.requires[1]);
    try std.testing.expectEqualStrings("xdg-utils", mapped.requires[2]);
    try std.testing.expectEqualStrings("/usr/bin/ffmpeg", mapped.requires[3]);
    try std.testing.expectEqualStrings("libfoo1 (>= 2)", mapped.unknown[0]);
    const glib = try depends(allocator, "libglib2.0-0t64", "");
    try std.testing.expectEqual(5, glib.requires.len);
    try std.testing.expectEqualStrings("libgio-2.0.so.0", glib.requires[1]);
}

test "package layout is deterministic and rejects unsafe paths and fields" {
    const allocator = std.testing.allocator;
    const package: Package = .{
        .name = "notes",
        .version = "1.2.0",
        .architecture = "x86_64",
        .summary = "Notes",
        .description = "Notes\nTakes notes.",
        .license = "MIT",
        .packager = "Example <dev@example.invalid>",
        .requires = &.{"libgtk-3.so.0()(64bit)"},
        .files = &.{ .{ .path = "/usr/lib/notes/notes", .bytes = "binary", .mode = 0o755 }, .{ .path = "/usr/lib/notes/assets/app.css", .bytes = "body{}" }, .{ .path = "/usr/share/applications/org.example.Notes.desktop", .bytes = "[Desktop Entry]\n" } },
        .links = &.{.{ .path = "/usr/bin/notes", .target = "../lib/notes/notes" }},
        .directories = &.{"/usr/lib/notes"},
        .postin = "true\n",
        .mtime = 1_700_000_000,
    };
    var first: std.Io.Writer.Allocating = .init(allocator);
    defer first.deinit();
    try write(allocator, &first.writer, package);
    var second: std.Io.Writer.Allocating = .init(allocator);
    defer second.deinit();
    try write(allocator, &second.writer, package);
    const bytes = first.written();
    try std.testing.expectEqualSlices(u8, bytes, second.written());
    try std.testing.expectEqualSlices(u8, &.{ 0xed, 0xab, 0xee, 0xdb, 3, 0 }, bytes[0..6]);
    try std.testing.expectEqualStrings("notes-1.2.0-1", std.mem.sliceTo(bytes[10..76], 0));
    // The signature header follows the lead, the main one after its padding.
    try std.testing.expectEqualSlices(u8, &.{ 0x8e, 0xad, 0xe8, 0x01 }, bytes[96..100]);
    const signature_entries = std.mem.readInt(u32, bytes[104..108], .big);
    const signature_store = std.mem.readInt(u32, bytes[108..112], .big);
    const signature_end = 112 + signature_entries * 16 + signature_store;
    const header_start = signature_end + (8 - signature_end % 8) % 8;
    try std.testing.expectEqualSlices(u8, &.{ 0x8e, 0xad, 0xe8, 0x01 }, bytes[header_start..][0..4]);
    // The header lists the subdirectory under the owned one.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/usr/lib/notes/\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "assets\x00") != null);

    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    var bad = package;
    bad.files = &.{.{ .path = "/usr/../etc/passwd", .bytes = "" }};
    try std.testing.expectError(error.InvalidPath, write(allocator, &sink.writer, bad));
    bad = package;
    bad.summary = "two\nlines";
    try std.testing.expectError(error.InvalidHeaderField, write(allocator, &sink.writer, bad));
    bad = package;
    bad.version = "1.0-2";
    try std.testing.expectError(error.InvalidVersion, write(allocator, &sink.writer, bad));
    bad = package;
    bad.requires = &.{"libfoo >= 2"};
    try std.testing.expectError(error.InvalidHeaderField, write(allocator, &sink.writer, bad));
}
