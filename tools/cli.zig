const std = @import("std");
const builtin = @import("builtin");
const update = @import("ziggurat_update");
const options = @import("cli_options");
const setup_format = @import("setup_format");
const deb = @import("deb");

const usage =
    \\ziggurat init DIR [--template native|web|hybrid] [--name NAME] [--id IDENTITY] [--framework PATH]
    \\ziggurat dev [--watch DIR]... [--frontend COMMAND] [-- ZIG_BUILD_ARGS...]
    \\ziggurat build [--debug] [--target TRIPLE] [--package] [-- ZIG_BUILD_ARGS...]
    \\ziggurat package setup --zip PACKAGE [--stub SETUP_STUB] [--publisher NAME] [--comment TEXT] [--categories LIST] [--icon PNG] [--output FILE]
    \\ziggurat package deb --zip PACKAGE --maintainer "NAME <EMAIL>" [--depends LIST] [--webview] [--comment TEXT] [--categories LIST] [--icon PNG] [--output FILE]
    \\ziggurat doctor [--webview]
    \\
    \\init writes a project that depends on this framework checkout by path.
    \\dev runs `zig build` and the installed executable, and rebuilds and restarts
    \\when src/, build.zig, build.zig.zon or a --watch directory changes; --frontend starts a frontend
    \\watcher next to it and stops it on exit.
    \\build runs `zig build` with ReleaseSafe; --package writes an update package
    \\to dist/ from zig-out/bin and ziggurat.json.
    \\package setup appends an update package to the setup stub, producing one
    \\installer file (Windows or Linux, matching the stub); sign the result after.
    \\package deb writes a Debian package that installs under /usr/lib/EXECUTABLE.
    \\--icon names a PNG inside the package for the Linux menu.
    \\doctor reports the toolchain and native dependencies this machine provides.
    \\Set ZIG to choose the zig executable.
    \\
;

const Template = enum { native, web, hybrid };

pub const Project = struct {
    name: []const u8,
    identity: []const u8,
    executable: []const u8,
    template: []const u8,
    version: []const u8 = "0.1.0.0",
};

pub fn main() void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const code = run(arena.allocator()) catch |err| {
        std.debug.print("ziggurat: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn run(allocator: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        try std.fs.File.stdout().writeAll(usage);
        return 0;
    }
    const command = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, command, "init")) return init(allocator, rest);
    if (std.mem.eql(u8, command, "dev")) return dev(allocator, rest);
    if (std.mem.eql(u8, command, "build")) return buildCommand(allocator, rest);
    if (std.mem.eql(u8, command, "doctor")) return doctor(allocator, rest);
    if (std.mem.eql(u8, command, "package")) return packageCommand(allocator, rest);
    try std.fs.File.stderr().writeAll(usage);
    return 2;
}

// ---------------------------------------------------------------- init

pub const InitOptions = struct {
    directory: []const u8,
    template: Template = .native,
    name: ?[]const u8 = null,
    identity: ?[]const u8 = null,
    framework: []const u8,
};

fn init(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var init_options: InitOptions = .{ .directory = "", .framework = options.framework_root };
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else null;
        if (std.mem.eql(u8, arg, "--template")) {
            init_options.template = std.meta.stringToEnum(Template, value orelse return error.InvalidArguments) orelse return error.UnknownTemplate;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--name")) {
            init_options.name = value orelse return error.InvalidArguments;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--id")) {
            init_options.identity = value orelse return error.InvalidArguments;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--framework")) {
            init_options.framework = value orelse return error.InvalidArguments;
            index += 1;
        } else if (init_options.directory.len == 0 and !std.mem.startsWith(u8, arg, "--")) {
            init_options.directory = arg;
        } else return error.InvalidArguments;
    }
    if (init_options.directory.len == 0) return error.InvalidArguments;
    try createProject(allocator, std.fs.cwd(), init_options);
    var stdout = std.fs.File.stdout();
    try stdout.writeAll(try std.fmt.allocPrint(allocator, "created {s}; next: cd {s} && ziggurat dev\n", .{ init_options.directory, init_options.directory }));
    return 0;
}

/// Lowercase ASCII letters, digits and underscores, starting with a letter.
fn packageName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (name) |byte| {
        const c = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(c)) try result.append(allocator, c) else if (result.items.len > 0 and result.items[result.items.len - 1] != '_') try result.append(allocator, '_');
    }
    while (result.items.len > 0 and result.items[result.items.len - 1] == '_') _ = result.pop();
    if (result.items.len == 0 or !std.ascii.isAlphabetic(result.items[0])) try result.insertSlice(allocator, 0, "app_");
    if (result.items.len > 32) result.shrinkRetainingCapacity(32);
    return result.toOwnedSlice(allocator);
}

fn validDisplayName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return false;
    // Names are spliced into Zig strings, HTML and resources; keep them plain.
    for (name) |byte| if (byte < 0x20 or byte == '"' or byte == '\\' or byte == '<' or byte == '>' or byte == '&' or byte == '@') return false;
    return true;
}

fn validIdentity(identity: []const u8) bool {
    if (identity.len == 0 or identity.len > 128 or !std.ascii.isAlphanumeric(identity[0])) return false;
    for (identity) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-' and byte != '_') return false;
    return true;
}

fn render(allocator: std.mem.Allocator, template: []const u8, replacements: []const [2][]const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var rest = template;
    outer: while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "@@")) for (replacements) |pair| {
            if (rest.len >= pair[0].len + 4 and std.mem.startsWith(u8, rest[2..], pair[0]) and std.mem.startsWith(u8, rest[2 + pair[0].len ..], "@@")) {
                try output.appendSlice(allocator, pair[1]);
                rest = rest[pair[0].len + 4 ..];
                continue :outer;
            }
        };
        try output.append(allocator, rest[0]);
        rest = rest[1..];
    }
    if (std.mem.indexOf(u8, output.items, "@@") != null) return error.UnresolvedTemplate;
    return output.toOwnedSlice(allocator);
}

const build_template = @embedFile("templates/build.zig.template");
const zon_template = @embedFile("templates/build.zig.zon.template");
const native_template = @embedFile("templates/native.zig.template");
const web_template = @embedFile("templates/web.zig.template");
const hybrid_template = @embedFile("templates/hybrid.zig.template");
const html_template = @embedFile("templates/index.html.template");
const gitignore_template = @embedFile("templates/gitignore.template");

pub fn createProject(allocator: std.mem.Allocator, cwd: std.fs.Dir, init_options: InitOptions) !void {
    const base = std.fs.path.basename(init_options.directory);
    const name = init_options.name orelse base;
    if (!validDisplayName(name)) return error.InvalidName;
    const package = try packageName(allocator, name);
    const identity = init_options.identity orelse try std.fmt.allocPrint(allocator, "com.example.{s}", .{package});
    if (!validIdentity(identity)) return error.InvalidIdentity;
    const executable = try std.mem.replaceOwned(u8, allocator, package, "_", "-");

    var project = cwd.makeOpenPath(init_options.directory, .{ .iterate = true }) catch |err| return err;
    defer project.close();
    var iterator = project.iterate();
    if (try iterator.next() != null) return error.DirectoryNotEmpty;

    // build.zig.zon paths are relative to the project.
    const project_absolute = try cwd.realpathAlloc(allocator, init_options.directory);
    const framework_absolute = try cwd.realpathAlloc(allocator, init_options.framework);
    var framework_check = try std.fs.openDirAbsolute(framework_absolute, .{});
    framework_check.access("build.zig.zon", .{}) catch return error.FrameworkNotFound;
    framework_check.close();
    const relative = try std.fs.path.relative(allocator, project_absolute, framework_absolute);
    const framework = try std.mem.replaceOwned(u8, allocator, relative, "\\", "/");

    var id: u32 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&id));
    if (id == 0 or id == std.math.maxInt(u32)) id = 1;
    const fingerprint = (@as(u64, std.hash.Crc32.hash(package)) << 32) | id;

    const web = init_options.template != .native;
    const imports = switch (init_options.template) {
        .native =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_view", .module = ziggurat.module("ziggurat_view") },
        \\
        ,
        .web =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_webview", .module = ziggurat.module("ziggurat_webview") },
        \\
        ,
        .hybrid =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_view", .module = ziggurat.module("ziggurat_view") },
        \\                .{ .name = "ziggurat_webview", .module = ziggurat.module("ziggurat_webview") },
        \\
        ,
    };
    const replacements = [_][2][]const u8{
        .{ "NAME", name },
        .{ "ID", identity },
        .{ "EXE", executable },
        .{ "PACKAGE", package },
        .{ "FRAMEWORK", framework },
        .{ "FINGERPRINT", try std.fmt.allocPrint(allocator, "0x{x}", .{fingerprint}) },
        .{ "WEB", if (web) "true" else "false" },
        .{ "IMPORTS", imports },
    };
    try project.makePath("src");
    try write(project, "build.zig", try render(allocator, build_template, &replacements));
    try write(project, "build.zig.zon", try render(allocator, zon_template, &replacements));
    try write(project, ".gitignore", gitignore_template);
    try write(project, "src/main.zig", try render(allocator, switch (init_options.template) {
        .native => native_template,
        .web => web_template,
        .hybrid => hybrid_template,
    }, &replacements));
    if (web) try write(project, "src/index.html", try render(allocator, html_template, &replacements));
    const config = try std.json.Stringify.valueAlloc(allocator, Project{ .name = name, .identity = identity, .executable = executable, .template = @tagName(init_options.template) }, .{ .whitespace = .indent_2 });
    try write(project, "ziggurat.json", try std.mem.concat(allocator, u8, &.{ config, "\n" }));
}

fn write(dir: std.fs.Dir, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(.{ .sub_path = path, .data = bytes, .flags = .{ .exclusive = true } });
}

pub fn readProject(allocator: std.mem.Allocator, dir: std.fs.Dir) !Project {
    const bytes = dir.readFileAlloc(allocator, "ziggurat.json", 16 * 1024) catch |err| {
        if (err == error.FileNotFound) return error.MissingProjectFile;
        return err;
    };
    const project = std.json.parseFromSliceLeaky(Project, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidProjectFile;
    if (!validIdentity(project.identity) or !validDisplayName(project.name)) return error.InvalidProjectFile;
    update.publication.validateFilename(project.executable) catch return error.InvalidProjectFile;
    _ = update.retention.parseVersion(project.version) catch return error.InvalidProjectFile;
    return project;
}

// ---------------------------------------------------------------- build

fn zigExecutable(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "ZIG") catch "zig";
}

fn runZig(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigExecutable(allocator));
    try argv.appendSlice(allocator, args);
    var child = std.process.Child.init(argv.items, allocator);
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn targetName(allocator: std.mem.Allocator, triple: ?[]const u8) ![]const u8 {
    if (triple) |text| {
        const query = try std.Target.Query.parse(.{ .arch_os_abi = text });
        const os = query.os_tag orelse builtin.os.tag;
        const arch = query.cpu_arch orelse builtin.cpu.arch;
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ @tagName(os), @tagName(arch) });
    }
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
}

fn buildCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var debug = false;
    var package = false;
    var triple: ?[]const u8 = null;
    var extra: []const []const u8 = &.{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--debug")) debug = true else if (std.mem.eql(u8, arg, "--package")) package = true else if (std.mem.eql(u8, arg, "--target") and index + 1 < args.len) {
            triple = args[index + 1];
            index += 1;
        } else if (std.mem.eql(u8, arg, "--")) {
            extra = args[index + 1 ..];
            break;
        } else return error.InvalidArguments;
    }
    const cwd = std.fs.cwd();
    const project = if (package) try readProject(allocator, cwd) else null;
    var zig_args: std.ArrayList([]const u8) = .empty;
    try zig_args.appendSlice(allocator, &.{ "build", if (debug) "-Doptimize=Debug" else "-Doptimize=ReleaseSafe" });
    if (triple) |text| try zig_args.append(allocator, try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{text}));
    try zig_args.appendSlice(allocator, extra);
    const code = try runZig(allocator, zig_args.items);
    if (code != 0 or !package) return code;
    const info = project.?;
    const target = try targetName(allocator, triple);
    const windows = std.mem.startsWith(u8, target, "windows-");
    const executable = try std.fmt.allocPrint(allocator, "{s}{s}", .{ info.executable, if (windows) ".exe" else "" });
    var files: std.ArrayList(update.archive.Entry) = .empty;
    try files.append(allocator, .{ .name = executable, .bytes = try cwd.readFileAlloc(allocator, try std.fs.path.join(allocator, &.{ "zig-out", "bin", executable }), 512 * 1024 * 1024) });
    // WebView applications on Windows ship the loader beside the executable.
    if (windows) if (cwd.readFileAlloc(allocator, "zig-out/bin/WebView2Loader.dll", 16 * 1024 * 1024)) |loader| {
        try files.append(allocator, .{ .name = "WebView2Loader.dll", .bytes = loader });
    } else |_| {};
    for ([_][]const u8{ "LICENSE", "LICENSE.txt" }) |license| if (cwd.readFileAlloc(allocator, license, 4 * 1024 * 1024)) |bytes| {
        try files.append(allocator, .{ .name = "LICENSE.txt", .bytes = bytes });
        break;
    } else |_| {};
    const version = try update.retention.parseVersion(info.version);
    const zip = try update.archive.buildPackage(allocator, .{ .name = info.name, .identity = info.identity, .target = target, .version = version, .executable = executable }, files.items);
    try cwd.makePath("dist");
    const output = try std.fmt.allocPrint(allocator, "dist/{s}-{s}-{s}.zip", .{ info.identity, target, info.version });
    try cwd.writeFile(.{ .sub_path = output, .data = zip });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ std.fmt.bytesToHex(digest, .lower), output }));
    return 0;
}

// ---------------------------------------------------------------- package

const PackageOptions = struct {
    zip: ?[]const u8 = null,
    stub: ?[]const u8 = null,
    output: ?[]const u8 = null,
    publisher: []const u8 = "",
    comment: []const u8 = "",
    categories: []const u8 = "Utility;",
    icon: ?[]const u8 = null,
    maintainer: []const u8 = "",
    depends: ?[]const u8 = null,
    webview: bool = false,
};

const Inventory = struct { schema_version: u16, name: []const u8 = "", identity: []const u8, version: []const u8, target: []const u8, executable: []const u8 };

/// Read every entry of a stored or deflated package into memory.
fn readPackage(allocator: std.mem.Allocator, path: []const u8) !struct { inventory: Inventory, files: []update.archive.Entry } {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(&buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var files: std.ArrayList(update.archive.Entry) = .empty;
    var name_buffer: [256]u8 = undefined;
    while (try iterator.next()) |entry| {
        if (entry.filename_len > name_buffer.len) return error.InvalidPayloadName;
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = name_buffer[0..entry.filename_len];
        try reader.interface.readSliceAll(name);
        try update.publication.validateFilename(name);
        if (entry.uncompressed_size > 512 * 1024 * 1024) return error.ExpandedSizeLimit;
        var output: std.Io.Writer.Allocating = .init(allocator);
        try reader.seekTo(entry.file_offset);
        const local = try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        try reader.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len);
        switch (entry.compression_method) {
            .store => try reader.interface.streamExact64(&output.writer, entry.uncompressed_size),
            .deflate => {
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var inflate: std.compress.flate.Decompress = .init(&reader.interface, .raw, &window);
                try inflate.reader.streamExact64(&output.writer, entry.uncompressed_size);
            },
            else => return error.UnsupportedCompression,
        }
        if (std.hash.Crc32.hash(output.written()) != entry.crc32) return error.ChecksumMismatch;
        try files.append(allocator, .{ .name = try allocator.dupe(u8, name), .bytes = try output.toOwnedSlice() });
    }
    for (files.items) |entry| if (std.mem.eql(u8, entry.name, "package.json")) {
        const inventory = std.json.parseFromSliceLeaky(Inventory, allocator, entry.bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidInventory;
        if (inventory.schema_version != 1) return error.InvalidInventory;
        return .{ .inventory = inventory, .files = files.items };
    };
    return error.InvalidInventory;
}

fn packageCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidArguments;
    const kind = args[0];
    var package_options: PackageOptions = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--webview")) {
            package_options.webview = true;
            continue;
        }
        if (index + 1 >= args.len) return error.InvalidArguments;
        const value = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, arg, "--zip")) package_options.zip = value else if (std.mem.eql(u8, arg, "--stub")) package_options.stub = value else if (std.mem.eql(u8, arg, "--output")) package_options.output = value else if (std.mem.eql(u8, arg, "--publisher")) package_options.publisher = value else if (std.mem.eql(u8, arg, "--comment")) package_options.comment = value else if (std.mem.eql(u8, arg, "--categories")) package_options.categories = value else if (std.mem.eql(u8, arg, "--icon")) package_options.icon = value else if (std.mem.eql(u8, arg, "--maintainer")) package_options.maintainer = value else if (std.mem.eql(u8, arg, "--depends")) package_options.depends = value else return error.InvalidArguments;
    }
    const zip_path = package_options.zip orelse return error.InvalidArguments;
    const package = try readPackage(allocator, zip_path);
    const info = package.inventory;
    const name = if (info.name.len > 0) info.name else info.executable;
    if (package_options.icon) |icon| {
        var found = false;
        for (package.files) |entry| found = found or std.mem.eql(u8, entry.name, icon);
        if (!found) return error.IconNotInPackage;
    }
    const config: setup_format.Config = .{ .name = name, .identity = info.identity, .version = info.version, .target = info.target, .executable = info.executable, .publisher = package_options.publisher, .comment = package_options.comment, .categories = package_options.categories, .icon = package_options.icon };
    const stem = std.fs.path.stem(info.executable);
    if (std.mem.eql(u8, kind, "setup")) {
        const windows = std.mem.startsWith(u8, info.target, "windows-");
        const stub_path = package_options.stub orelse blk: {
            const directory = try std.fs.selfExeDirPathAlloc(allocator);
            break :blk try std.fs.path.join(allocator, &.{ directory, if (windows) "ziggurat-setup.exe" else "ziggurat-setup" });
        };
        const stub = try std.fs.cwd().readFileAlloc(allocator, stub_path, 64 * 1024 * 1024);
        if ((stub.len >= 2 and std.mem.eql(u8, stub[0..2], "MZ")) != windows) return error.StubTargetMismatch;
        const zip = try std.fs.cwd().readFileAlloc(allocator, zip_path, 1024 * 1024 * 1024);
        const config_json = try std.json.Stringify.valueAlloc(allocator, config, .{ .emit_null_optional_fields = false });
        const output = package_options.output orelse try std.fmt.allocPrint(allocator, "dist/{s}-{s}-{s}-setup{s}", .{ stem, info.version, info.target, if (windows) ".exe" else "" });
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        try bytes.writer.writeAll(stub);
        try bytes.writer.writeAll(zip);
        try bytes.writer.writeAll(config_json);
        try setup_format.writeFooter(&bytes.writer, zip, config_json);
        if (std.fs.path.dirname(output)) |parent| try std.fs.cwd().makePath(parent);
        try std.fs.cwd().writeFile(.{ .sub_path = output, .data = bytes.written(), .flags = .{ .mode = 0o755 } });
        try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
        return 0;
    }
    if (!std.mem.eql(u8, kind, "deb")) return error.InvalidArguments;
    if (!std.mem.startsWith(u8, info.target, "linux-")) return error.WrongTarget;
    if (package_options.maintainer.len == 0) return error.MissingMaintainer;
    const arch = std.meta.stringToEnum(std.Target.Cpu.Arch, info.target["linux-".len..]) orelse return error.UnsupportedArchitecture;
    const package_name = try std.ascii.allocLowerString(allocator, stem);
    if (!deb.validName(package_name)) return error.InvalidPackageName;
    const lib = try std.fmt.allocPrint(allocator, "/usr/lib/{s}", .{package_name});
    var files: std.ArrayList(deb.File) = .empty;
    for (package.files) |entry| {
        if (std.mem.eql(u8, entry.name, "package.json")) continue;
        const executable = std.mem.eql(u8, entry.name, info.executable);
        try files.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ lib, entry.name }), .bytes = entry.bytes, .mode = if (executable) 0o755 else 0o644 });
        if (std.ascii.eqlIgnoreCase(entry.name, "LICENSE.txt")) try files.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "/usr/share/doc/{s}/copyright", .{package_name}), .bytes = entry.bytes });
        if (package_options.icon) |icon| if (std.mem.eql(u8, entry.name, icon)) try files.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "/usr/share/icons/hicolor/256x256/apps/{s}.png", .{info.identity}), .bytes = entry.bytes });
    }
    const exec = try std.fmt.allocPrint(allocator, "/usr/bin/{s}", .{package_name});
    try files.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "/usr/share/applications/{s}.desktop", .{info.identity}), .bytes = try setup_format.desktopEntry(allocator, config, exec, if (package_options.icon != null) info.identity else null) });
    const depends = package_options.depends orelse if (package_options.webview) "libgtk-3-0t64 | libgtk-3-0, libpango-1.0-0, libwebkit2gtk-4.1-0, libsoup-3.0-0" else "libgtk-3-0t64 | libgtk-3-0, libpango-1.0-0";
    const debian_version = try std.mem.replaceOwned(u8, allocator, info.version, "-", "~");
    // Menus and icon caches refresh when the tools exist; failures never block.
    const refresh = "#!/bin/sh\nset -e\nif command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || true; fi\nif command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true; fi\n";
    var output_bytes: std.Io.Writer.Allocating = .init(allocator);
    const mtime: u64 = if (std.process.getEnvVarOwned(allocator, "SOURCE_DATE_EPOCH")) |text| std.fmt.parseInt(u64, text, 10) catch 0 else |_| 0;
    try deb.write(allocator, &output_bytes.writer, .{
        .name = package_name,
        .version = debian_version,
        .architecture = try deb.architecture(arch),
        .maintainer = package_options.maintainer,
        .description = if (package_options.comment.len > 0) try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ name, package_options.comment }) else name,
        .depends = depends,
        .files = files.items,
        .links = &.{.{ .path = exec, .target = try std.fmt.allocPrint(allocator, "../lib/{s}/{s}", .{ package_name, info.executable }) }},
        .postinst = refresh,
        .postrm = refresh,
        .mtime = mtime,
    });
    const output = package_options.output orelse try std.fmt.allocPrint(allocator, "dist/{s}_{s}_{s}.deb", .{ package_name, debian_version, try deb.architecture(arch) });
    if (std.fs.path.dirname(output)) |parent| try std.fs.cwd().makePath(parent);
    try std.fs.cwd().writeFile(.{ .sub_path = output, .data = output_bytes.written() });
    try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
    return 0;
}

// ---------------------------------------------------------------- dev

/// Change detection over a set of trees: a digest of every regular file's
/// path, size and modification time. Directories named .zig-cache, zig-out,
/// node_modules or starting with a dot are skipped.
pub fn snapshot(allocator: std.mem.Allocator, dir: std.fs.Dir, roots: []const []const u8) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (roots) |root| {
        // Open as a directory first: on Windows statFile fails for directories.
        var tree = dir.openDir(root, .{ .iterate = true }) catch {
            const stat = dir.statFile(root) catch continue;
            if (stat.kind != .file) continue;
            hasher.update(root);
            hasher.update(std.mem.asBytes(&stat.size));
            hasher.update(std.mem.asBytes(&stat.mtime));
            continue;
        };
        defer tree.close();
        var walker = try tree.walk(allocator);
        defer walker.deinit();
        var entries: std.ArrayList([]const u8) = .empty;
        defer {
            for (entries.items) |entry| allocator.free(entry);
            entries.deinit(allocator);
        }
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            var skip = false;
            var parts = std.mem.tokenizeAny(u8, entry.path, "/\\");
            while (parts.next()) |part| if (part[0] == '.' or std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "node_modules")) {
                skip = true;
            };
            if (skip) continue;
            try entries.append(allocator, try allocator.dupe(u8, entry.path));
        }
        std.mem.sort([]const u8, entries.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (entries.items) |path| {
            const stat = tree.statFile(path) catch continue;
            hasher.update(root);
            hasher.update(path);
            hasher.update(std.mem.asBytes(&stat.size));
            hasher.update(std.mem.asBytes(&stat.mtime));
        }
    }
    return hasher.final();
}

fn shellCommand(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    if (builtin.os.tag == .windows) return allocator.dupe([]const u8, &.{ "cmd.exe", "/d", "/s", "/c", command });
    return allocator.dupe([]const u8, &.{ "/bin/sh", "-c", command });
}

fn stop(child: *std.process.Child) void {
    _ = child.kill() catch {};
}

fn dev(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.appendSlice(allocator, &.{ "src", "build.zig", "build.zig.zon" });
    var frontend: ?[]const u8 = null;
    var extra: []const []const u8 = &.{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--watch") and index + 1 < args.len) {
            try roots.append(allocator, args[index + 1]);
            index += 1;
        } else if (std.mem.eql(u8, arg, "--frontend") and index + 1 < args.len) {
            frontend = args[index + 1];
            index += 1;
        } else if (std.mem.eql(u8, arg, "--")) {
            extra = args[index + 1 ..];
            break;
        } else return error.InvalidArguments;
    }
    const cwd = std.fs.cwd();
    cwd.access("build.zig", .{}) catch return error.MissingBuildFile;
    var frontend_child: ?std.process.Child = null;
    if (frontend) |command| {
        frontend_child = std.process.Child.init(try shellCommand(allocator, command), allocator);
        try frontend_child.?.spawn();
    }
    defer if (frontend_child) |*child| stop(child);
    // Build, then run the installed executable as our own child so a change
    // stops the application itself rather than an intermediate build runner.
    const project = try readProject(allocator, cwd);
    const executable = try std.fs.path.join(allocator, &.{ "zig-out", "bin", try std.fmt.allocPrint(allocator, "{s}{s}", .{ project.executable, builtin.os.tag.exeFileExt(builtin.cpu.arch) }) });
    var build_args: std.ArrayList([]const u8) = .empty;
    try build_args.append(allocator, "build");
    try build_args.appendSlice(allocator, extra);
    var last = try snapshot(allocator, cwd, roots.items);
    while (true) {
        var app: ?std.process.Child = null;
        if (try runZig(allocator, build_args.items) == 0) {
            app = std.process.Child.init(&.{executable}, allocator);
            try app.?.spawn();
            std.debug.print("ziggurat: running {s} (watching {d} paths)\n", .{ executable, roots.items.len });
        } else std.debug.print("ziggurat: build failed; waiting for changes\n", .{});
        while (true) {
            std.Thread.sleep(300 * std.time.ns_per_ms);
            const now = try snapshot(allocator, cwd, roots.items);
            if (now != last) {
                last = now;
                break;
            }
            if (app) |*child| if (try childExited(child)) {
                std.debug.print("ziggurat: application exited; waiting for changes\n", .{});
                app = null;
            };
        }
        std.debug.print("ziggurat: change detected, rebuilding\n", .{});
        if (app) |*child| stop(child);
    }
}

fn childExited(child: *std.process.Child) !bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        windows.WaitForSingleObject(child.id, 0) catch |err| switch (err) {
            error.WaitTimeOut => return false,
            else => return err,
        };
        _ = try child.wait();
        return true;
    }
    const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
    if (result.pid == 0) return false;
    child.term = .{ .Exited = 0 };
    return true;
}

// ---------------------------------------------------------------- doctor

const Status = enum { ok, warning, missing };

fn report(status: Status, label: []const u8, detail: []const u8) void {
    std.debug.print("[{s}] {s}: {s}\n", .{ switch (status) {
        .ok => "ok",
        .warning => "warn",
        .missing => "missing",
    }, label, detail });
}

fn capture(allocator: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 64 * 1024 }) catch return null;
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

fn doctor(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var webview = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--webview")) webview = true else return error.InvalidArguments;
    }
    var failed = false;
    report(.ok, "host", try std.fmt.allocPrint(allocator, "{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) }));
    const zig = try zigExecutable(allocator);
    if (capture(allocator, &.{ zig, "version" })) |version| {
        if (std.mem.eql(u8, version, "0.15.2")) report(.ok, "zig", version) else {
            report(.missing, "zig", try std.fmt.allocPrint(allocator, "{s} (this framework targets 0.15.2)", .{version}));
            failed = true;
        }
    } else {
        report(.missing, "zig", "not found; install Zig 0.15.2 or set ZIG");
        failed = true;
    }
    if (capture(allocator, &.{ "git", "--version" })) |version| report(.ok, "git", version) else report(.warning, "git", "not found");
    switch (builtin.os.tag) {
        .linux => {
            const packages = [_]struct { name: []const u8, required: bool }{
                .{ .name = "gtk+-3.0", .required = true },
                .{ .name = "pango", .required = true },
                .{ .name = "icu-uc", .required = true },
                .{ .name = "webkit2gtk-4.1", .required = webview },
                .{ .name = "libsoup-3.0", .required = webview },
            };
            if (capture(allocator, &.{ "pkg-config", "--version" }) == null) {
                report(.missing, "pkg-config", "not found");
                failed = true;
            } else for (packages) |package| {
                if (capture(allocator, &.{ "pkg-config", "--modversion", package.name })) |version| report(.ok, package.name, version) else {
                    report(if (package.required) .missing else .warning, package.name, if (package.required) "development files not found" else "not found (needed only with -Dwebview=true)");
                    if (package.required) failed = true;
                }
            }
            if (std.process.hasEnvVarConstant("DISPLAY") or std.process.hasEnvVarConstant("WAYLAND_DISPLAY")) report(.ok, "display", "available") else report(.warning, "display", "no DISPLAY or WAYLAND_DISPLAY; windows cannot open here");
        },
        .windows => {
            const sdk = std.fs.path.join(allocator, &.{ options.framework_root, ".deps", "webview2", "build", "native", "include", "WebView2.h" }) catch unreachable;
            if (std.fs.cwd().access(sdk, .{})) |_| report(.ok, "WebView2 SDK", sdk) else |_| {
                report(if (webview) .missing else .warning, "WebView2 SDK", "not extracted; run scripts/fetch-webview2.ps1");
                if (webview) failed = true;
            }
            if (webviewRuntimeVersion(allocator)) |version| report(.ok, "WebView2 Runtime", version) else {
                report(if (webview) .missing else .warning, "WebView2 Runtime", "not installed");
                if (webview) failed = true;
            }
        },
        else => report(.warning, "platform", "no runtime backend for this operating system"),
    }
    if (readProject(allocator, std.fs.cwd())) |project| report(.ok, "project", project.identity) else |err| switch (err) {
        error.MissingProjectFile => report(.warning, "project", "no ziggurat.json in this directory"),
        else => {
            report(.missing, "project", @errorName(err));
            failed = true;
        },
    }
    return if (failed) 1 else 0;
}

fn webviewRuntimeVersion(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    // The Evergreen Runtime registers its version under EdgeUpdate clients.
    const keys = [_][]const u8{
        "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKCU\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    };
    for (keys) |key| {
        const output = capture(allocator, &.{ "reg.exe", "query", key, "/v", "pv" }) orelse continue;
        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        while (lines.next()) |line| {
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const field = fields.next() orelse continue;
            if (!std.mem.eql(u8, field, "pv")) continue;
            _ = fields.next();
            const version = fields.next() orelse continue;
            if (!std.mem.eql(u8, version, "0.0.0.0")) return version;
        }
    }
    return null;
}

test "templates render without placeholders and identifiers are sanitized" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("my_tool", try packageName(allocator, "My Tool!"));
    try std.testing.expectEqualStrings("app_9lives", try packageName(allocator, "9lives"));
    try std.testing.expect(!validDisplayName("a\"b"));
    try std.testing.expect(!validIdentity("../x"));
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.makePath("framework");
    try temp.dir.writeFile(.{ .sub_path = "framework/build.zig.zon", .data = ".{}" });
    for ([_]Template{ .native, .web, .hybrid }) |template| {
        const directory = try std.fmt.allocPrint(allocator, "apps/{s}", .{@tagName(template)});
        try createProject(allocator, temp.dir, .{ .directory = directory, .template = template, .name = "Sample App", .framework = "framework" });
        var project = try temp.dir.openDir(directory, .{});
        defer project.close();
        const zon = try project.readFileAlloc(allocator, "build.zig.zon", 4096);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".path = \"../../framework\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .sample_app") != null);
        const info = try readProject(allocator, project);
        try std.testing.expectEqualStrings("com.example.sample_app", info.identity);
        try std.testing.expectEqualStrings("sample-app", info.executable);
        try std.testing.expectEqual(template != .native, if (project.access("src/index.html", .{})) |_| true else |_| false);
        try std.testing.expectError(error.DirectoryNotEmpty, createProject(allocator, temp.dir, .{ .directory = directory, .framework = "framework" }));
    }
    try std.testing.expectError(error.FrameworkNotFound, createProject(allocator, temp.dir, .{ .directory = "apps/none", .framework = "apps" }));
}

test "snapshots change with edits and ignore build output" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const allocator = std.testing.allocator;
    try temp.dir.makePath("src/.zig-cache");
    try temp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "a" });
    try temp.dir.writeFile(.{ .sub_path = "build.zig", .data = "b" });
    const first = try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" });
    try temp.dir.writeFile(.{ .sub_path = "src/.zig-cache/x", .data = "ignored" });
    try std.testing.expectEqual(first, try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" }));
    try temp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "changed" });
    try std.testing.expect(first != try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" }));
}
