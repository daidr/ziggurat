const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const update = @import("ziggurat_update");
const options = @import("cli_options");
const setup_format = @import("setup_format");
const deb = @import("deb");
const publish = @import("publish.zig");
const console_mod = @import("console.zig");
const i18n_gen = @import("i18n_gen.zig");
const install_script = @import("install_script.zig");
const s3 = @import("s3.zig");
const icon_mod = @import("icon.zig");
const winsign = @import("winsign.zig");
const vet = @import("vet.zig");

const usage =
    \\ziggurat init DIR [--template native|web|hybrid] [--name NAME] [--id IDENTITY] [--framework PATH]
    \\ziggurat dev [--watch DIR]... [--frontend COMMAND] [-- ZIG_BUILD_ARGS...]
    \\ziggurat build [--debug] [--target TRIPLE] [--package] [-- ZIG_BUILD_ARGS...]
    \\ziggurat package setup --zip PACKAGE [--stub SETUP_STUB] [--publisher NAME] [--comment TEXT] [--categories LIST] [--icon PNG] [--output FILE]
    \\ziggurat package deb --zip PACKAGE --maintainer "NAME <EMAIL>" [--depends LIST] [--webview] [--comment TEXT] [--categories LIST] [--icon PNG] [--output FILE]
    \\ziggurat package install-script --zip PACKAGE [--github OWNER/REPO [--tag-prefix PREFIX]] [--url BASE] [--webview] [--output FILE]
    \\ziggurat publish DIR (--github OWNER/REPO --tag TAG [--notes FILE] [--not-latest] | --s3 BUCKET --url BASE [--prefix DIR] [--region REGION] [--endpoint URL] [--path-style])
    \\ziggurat generate [-o FILE] [--framework PATH] [DIR]
    \\ziggurat i18n check [DIR]
    \\ziggurat install-skills [DIR]
    \\ziggurat icon PNG [-o FILE]
    \\ziggurat sign FILE...
    \\ziggurat vet [DIR]
    \\ziggurat doctor [--webview]
    \\
    \\init writes a project that depends on this framework checkout by path.
    \\dev runs `zig build` and the installed executable, and rebuilds and restarts
    \\when src/, build.zig, build.zig.zon or a --watch directory changes; --frontend starts a frontend
    \\watcher next to it and stops it on exit.
    \\build runs `zig build` with ReleaseSafe; --package writes an update package
    \\to dist/ from zig-out/bin and ziggurat.json, with the icon of ziggurat.json,
    \\and signs the Windows executable first when windows in ziggurat.json says how.
    \\package setup appends an update package to the setup stub, producing one
    \\installer file (Windows or Linux, matching the stub), signed as the executable is.
    \\package deb writes a Debian package that installs under /usr/lib/EXECUTABLE.
    \\--icon names a PNG inside the package for the Linux menu (default: the package's icon.png).
    \\package install-script writes install.sh, which installs a Linux app for the
    \\current user with its setup installer: the one next to it, else the newest one
    \\it downloads from the GitHub releases or BASE.
    \\publish uploads a release directory to a GitHub release with the GitHub CLI, or
    \\to an S3 bucket (credentials from AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and
    \\AWS_SESSION_TOKEN) that BASE serves.
    \\generate checks the catalogs of the app's messages (i18n in ziggurat.json) and
    \\writes their accessors: catalog.zig in their directory and, with bindings, a
    \\TypeScript module next to the client; then the typed TypeScript client of
    \\the service (service and bindings in ziggurat.json, or -o FILE).
    \\i18n check lists the problems of the catalogs; errors exit with status 1.
    \\install-skills installs or refreshes the bundled agent skills in .agents/skills.
    \\icon renders a square PNG as a Windows .ico (default: the PNG's name with .ico).
    \\sign signs Windows executables and installers as windows in ziggurat.json says:
    \\certificate (password from ZIGGURAT_WINDOWS_CERTIFICATE_PASSWORD), timestampUrl,
    \\or signCommand with %1 for the file.
    \\vet checks the Zig files of src/ with `zig ast-check`, then that values of a
    \\view pass (*view.View, *ui.Frame) are not kept in structs, container-level
    \\variables or thread arguments.
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
    /// The catalogs of the app's messages: `<dir>/<tag>.json`.
    i18n: ?I18n = null,
    /// Where `ziggurat generate` writes the TypeScript client.
    bindings: ?[]const u8 = null,
    /// The Zig source exporting the `Service` type the client is made from.
    service: ?[]const u8 = null,
    /// A square PNG, ideally 1024x1024, that `build --package` ships as
    /// icon.png: the icon of the Linux menu entries the packages write.
    icon: ?[]const u8 = null,
    /// How Windows executables and installers are signed.
    windows: ?winsign.Windows = null,

    /// `dir` under src/ lets the app import `catalog.zig` from its sources.
    pub const I18n = struct { dir: []const u8 = "src/locales", source: []const u8 = "en" };
};

pub fn main(process_init: std.process.Init.Minimal) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const code = run(arena.allocator(), process_init.args) catch |err| {
        std.debug.print("ziggurat: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn run(allocator: std.mem.Allocator, process_args: std.process.Args) !u8 {
    const args = try zio.argsAlloc(allocator, process_args);
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help")) {
        try std.Io.File.stdout().writeStreamingAll(zio.io(), usage);
        return 0;
    }
    const command = args[1];
    const rest = args[2..];
    if (std.mem.eql(u8, command, "init")) return init(allocator, rest);
    if (std.mem.eql(u8, command, "dev")) return dev(allocator, rest);
    if (std.mem.eql(u8, command, "build")) return buildCommand(allocator, rest);
    if (std.mem.eql(u8, command, "doctor")) return doctor(allocator, rest);
    if (std.mem.eql(u8, command, "package")) return packageCommand(allocator, rest);
    if (std.mem.eql(u8, command, "publish")) return publishCommand(allocator, rest);
    if (std.mem.eql(u8, command, "generate")) return generateCommand(allocator, rest);
    if (std.mem.eql(u8, command, "i18n")) return i18nCommand(allocator, rest);
    if (std.mem.eql(u8, command, "install-skills")) return installSkillsCommand(allocator, rest);
    if (std.mem.eql(u8, command, "icon")) return iconCommand(allocator, rest);
    if (std.mem.eql(u8, command, "sign")) return signCommand(allocator, rest);
    if (std.mem.eql(u8, command, "vet")) return vetCommand(allocator, rest);
    try std.Io.File.stderr().writeStreamingAll(zio.io(), usage);
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
    try createProject(allocator, std.Io.Dir.cwd(), init_options);
    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "created {s}; next: cd {s} && ziggurat dev\n", .{ init_options.directory, init_options.directory }));
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

pub fn createProject(allocator: std.mem.Allocator, cwd: std.Io.Dir, init_options: InitOptions) !void {
    const base = std.fs.path.basename(init_options.directory);
    const name = init_options.name orelse base;
    if (!validDisplayName(name)) return error.InvalidName;
    const package = try packageName(allocator, name);
    const identity = init_options.identity orelse try std.fmt.allocPrint(allocator, "com.example.{s}", .{package});
    if (!validIdentity(identity)) return error.InvalidIdentity;
    const executable = try std.mem.replaceOwned(u8, allocator, package, "_", "-");

    var project = cwd.createDirPathOpen(zio.io(), init_options.directory, .{ .open_options = .{ .iterate = true } }) catch |err| return err;
    defer project.close(zio.io());
    var iterator = project.iterate();
    if (try iterator.next(zio.io()) != null) return error.DirectoryNotEmpty;

    // build.zig.zon paths are relative to the project.
    const project_absolute = try zio.realPathAlloc(cwd, init_options.directory, allocator);
    const framework_absolute = try zio.realPathAlloc(cwd, init_options.framework, allocator);
    var framework_check = try std.Io.Dir.openDirAbsolute(zio.io(), framework_absolute, .{});
    framework_check.access(zio.io(), "build.zig.zon", .{}) catch return error.FrameworkNotFound;
    framework_check.close(zio.io());
    const relative = try std.fs.path.relativeAlloc(allocator, project_absolute, null, project_absolute, framework_absolute);
    const framework = try std.mem.replaceOwned(u8, allocator, relative, "\\", "/");

    var id: u32 = undefined;
    zio.random.bytes(std.mem.asBytes(&id));
    if (id == 0 or id == std.math.maxInt(u32)) id = 1;
    const fingerprint = (@as(u64, std.hash.Crc32.hash(package)) << 32) | id;

    const web = init_options.template != .native;
    const imports = switch (init_options.template) {
        .native =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_i18n", .module = ziggurat.module("ziggurat_i18n") },
        \\                .{ .name = "ziggurat_view", .module = ziggurat.module("ziggurat_view") },
        \\
        ,
        .web =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_i18n", .module = ziggurat.module("ziggurat_i18n") },
        \\                .{ .name = "ziggurat_webview", .module = ziggurat.module("ziggurat_webview") },
        \\
        ,
        .hybrid =>
        \\                .{ .name = "ziggurat", .module = ziggurat.module("ziggurat") },
        \\                .{ .name = "ziggurat_i18n", .module = ziggurat.module("ziggurat_i18n") },
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
    try project.createDirPath(zio.io(), "src");
    try write(project, "build.zig", try render(allocator, build_template, &replacements));
    try write(project, "build.zig.zon", try render(allocator, zon_template, &replacements));
    try write(project, ".gitignore", gitignore_template);
    try write(project, "src/main.zig", try render(allocator, switch (init_options.template) {
        .native => native_template,
        .web => web_template,
        .hybrid => hybrid_template,
    }, &replacements));
    if (web) try write(project, "src/index.html", try render(allocator, html_template, &replacements));
    const config = try std.json.Stringify.valueAlloc(allocator, Project{ .name = name, .identity = identity, .executable = executable, .template = @tagName(init_options.template) }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    try write(project, "ziggurat.json", try std.mem.concat(allocator, u8, &.{ config, "\n" }));
    try installSkills(project);
}

fn write(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(zio.io(), .{ .sub_path = path, .data = bytes, .flags = .{ .exclusive = true } });
}

pub fn readProject(allocator: std.mem.Allocator, dir: std.Io.Dir) !Project {
    const bytes = dir.readFileAlloc(zio.io(), "ziggurat.json", allocator, .limited(16 * 1024)) catch |err| {
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
    return zio.getEnvVarOwned(allocator, "ZIG") catch "zig";
}

fn runZig(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigExecutable(allocator));
    try argv.appendSlice(allocator, args);
    var child = try zio.spawn(.{ .argv = argv.items });
    const term = try child.wait(zio.io());
    return switch (term) {
        .exited => |code| code,
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
    const cwd = std.Io.Dir.cwd();
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
    const executable_path = try std.fs.path.join(allocator, &.{ "zig-out", "bin", executable });
    if (windows) if (info.windows) |config| if (config.signs()) {
        if (try signFile(allocator, config, executable_path) != 0) return 1;
    };
    var files: std.ArrayList(update.archive.Entry) = .empty;
    try files.append(allocator, .{ .name = executable, .bytes = try cwd.readFileAlloc(zio.io(), executable_path, allocator, .limited(512 * 1024 * 1024)) });
    if (info.icon) |path| {
        const bytes = try cwd.readFileAlloc(zio.io(), path, allocator, .limited(64 * 1024 * 1024));
        icon_mod.validate(bytes) catch |err| {
            std.debug.print("ziggurat: icon {s}: {s}\n", .{ path, if (err == error.IconNotSquare) "the icon must be square" else "the icon must be a PNG" });
            return 1;
        };
        try files.append(allocator, .{ .name = "icon.png", .bytes = bytes });
    }
    // WebView applications on Windows ship the loader beside the executable.
    if (windows) if (cwd.readFileAlloc(zio.io(), "zig-out/bin/WebView2Loader.dll", allocator, .limited(16 * 1024 * 1024))) |loader| {
        // Libraries their publishers signed keep their signatures.
        const unsigned = !winsign.peKind(loader).signed;
        if (unsigned) if (info.windows) |config| if (config.signs()) {
            if (try signFile(allocator, config, "zig-out/bin/WebView2Loader.dll") != 0) return 1;
        };
        try files.append(allocator, .{ .name = "WebView2Loader.dll", .bytes = if (unsigned and info.windows != null and info.windows.?.signs()) try cwd.readFileAlloc(zio.io(), "zig-out/bin/WebView2Loader.dll", allocator, .limited(16 * 1024 * 1024)) else loader });
    } else |_| {};
    for ([_][]const u8{ "LICENSE", "LICENSE.txt" }) |license| if (cwd.readFileAlloc(zio.io(), license, allocator, .limited(4 * 1024 * 1024))) |bytes| {
        try files.append(allocator, .{ .name = "LICENSE.txt", .bytes = bytes });
        break;
    } else |_| {};
    const version = try update.retention.parseVersion(info.version);
    const zip = try update.archive.buildPackage(allocator, .{ .name = info.name, .identity = info.identity, .target = target, .version = version, .executable = executable }, files.items);
    try cwd.createDirPath(zio.io(), "dist");
    const output = try std.fmt.allocPrint(allocator, "dist/{s}-{s}-{s}.zip", .{ info.identity, target, info.version });
    try cwd.writeFile(zio.io(), .{ .sub_path = output, .data = zip });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &digest, .{});
    try std.Io.File.stdout().writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ std.fmt.bytesToHex(digest, .lower), output }));
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
    github: ?[]const u8 = null,
    tag_prefix: []const u8 = "",
    url: ?[]const u8 = null,
};

const Inventory = struct { schema_version: u16, name: []const u8 = "", identity: []const u8, version: []const u8, target: []const u8, executable: []const u8 };

/// Read every entry of a stored or deflated package into memory.
fn readPackage(allocator: std.mem.Allocator, path: []const u8) !struct { inventory: Inventory, files: []update.archive.Entry } {
    var file = try std.Io.Dir.cwd().openFile(zio.io(), path, .{});
    defer file.close(zio.io());
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(zio.io(), &buffer);
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
        if (std.mem.eql(u8, arg, "--zip")) package_options.zip = value else if (std.mem.eql(u8, arg, "--stub")) package_options.stub = value else if (std.mem.eql(u8, arg, "--output")) package_options.output = value else if (std.mem.eql(u8, arg, "--publisher")) package_options.publisher = value else if (std.mem.eql(u8, arg, "--comment")) package_options.comment = value else if (std.mem.eql(u8, arg, "--categories")) package_options.categories = value else if (std.mem.eql(u8, arg, "--icon")) package_options.icon = value else if (std.mem.eql(u8, arg, "--maintainer")) package_options.maintainer = value else if (std.mem.eql(u8, arg, "--depends")) package_options.depends = value else if (std.mem.eql(u8, arg, "--github")) package_options.github = value else if (std.mem.eql(u8, arg, "--tag-prefix")) package_options.tag_prefix = value else if (std.mem.eql(u8, arg, "--url")) package_options.url = value else return error.InvalidArguments;
    }
    const zip_path = package_options.zip orelse return error.InvalidArguments;
    const package = try readPackage(allocator, zip_path);
    const info = package.inventory;
    const name = if (info.name.len > 0) info.name else info.executable;
    if (package_options.icon == null) for (package.files) |entry| {
        if (std.mem.eql(u8, entry.name, "icon.png")) package_options.icon = "icon.png";
    };
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
            const directory = try std.process.executableDirPathAlloc(zio.io(), allocator);
            break :blk try std.fs.path.join(allocator, &.{ directory, if (windows) "ziggurat-setup.exe" else "ziggurat-setup" });
        };
        const stub = try std.Io.Dir.cwd().readFileAlloc(zio.io(), stub_path, allocator, .limited(64 * 1024 * 1024));
        if ((stub.len >= 2 and std.mem.eql(u8, stub[0..2], "MZ")) != windows) return error.StubTargetMismatch;
        const zip = try std.Io.Dir.cwd().readFileAlloc(zio.io(), zip_path, allocator, .limited(1024 * 1024 * 1024));
        const config_json = try std.json.Stringify.valueAlloc(allocator, config, .{ .emit_null_optional_fields = false });
        const output = package_options.output orelse try std.fmt.allocPrint(allocator, "dist/{s}-{s}-{s}-setup{s}", .{ stem, info.version, info.target, if (windows) ".exe" else "" });
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        try bytes.writer.writeAll(stub);
        try bytes.writer.writeAll(zip);
        try bytes.writer.writeAll(config_json);
        try setup_format.writeFooter(&bytes.writer, zip, config_json);
        if (std.fs.path.dirname(output)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
        try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = output, .data = bytes.written(), .flags = .{ .permissions = zio.mode(0o755) } });
        // The stub skips the certificate table, so the installer is signed
        // after the package is appended.
        if (windows) if (readProject(allocator, std.Io.Dir.cwd()) catch null) |project| if (project.windows) |signing| if (signing.signs()) {
            if (try signFile(allocator, signing, output) != 0) return 1;
        };
        try std.Io.File.stdout().writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
        return 0;
    }
    if (std.mem.eql(u8, kind, "install-script")) {
        if (!std.mem.startsWith(u8, info.target, "linux-")) return error.WrongTarget;
        if (package_options.github) |repository| if (!publish.validRepository(repository)) return error.InvalidRepository;
        if (package_options.url) |url| if (!std.mem.endsWith(u8, url, "/") or !(std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"))) return error.InvalidUrl;
        var script: std.Io.Writer.Allocating = .init(allocator);
        try install_script.write(&script.writer, .{ .app_name = name, .identity = info.identity, .stem = stem, .version = info.version, .github = package_options.github, .tag_prefix = package_options.tag_prefix, .url = package_options.url, .webview = package_options.webview });
        const output = package_options.output orelse "dist/" ++ install_script.name;
        if (std.fs.path.dirname(output)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
        try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = output, .data = script.written(), .flags = .{ .permissions = zio.mode(0o755) } });
        try std.Io.File.stdout().writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
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
    const mtime: u64 = if (zio.getEnvVarOwned(allocator, "SOURCE_DATE_EPOCH")) |text| std.fmt.parseInt(u64, text, 10) catch 0 else |_| 0;
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
    if (std.fs.path.dirname(output)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = output, .data = output_bytes.written() });
    try std.Io.File.stdout().writeStreamingAll(zio.io(), try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
    return 0;
}

// ---------------------------------------------------------------- dev

/// Change detection over a set of trees: a digest of every regular file's
/// path, size and modification time. Directories named .zig-cache, zig-out,
/// node_modules or starting with a dot are skipped.
pub fn snapshot(allocator: std.mem.Allocator, dir: std.Io.Dir, roots: []const []const u8) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (roots) |root| {
        // Open as a directory first: on Windows statFile fails for directories.
        var tree = dir.openDir(zio.io(), root, .{ .iterate = true }) catch {
            const stat = dir.statFile(zio.io(), root, .{}) catch continue;
            if (stat.kind != .file) continue;
            hasher.update(root);
            hasher.update(std.mem.asBytes(&stat.size));
            hasher.update(std.mem.asBytes(&stat.mtime));
            continue;
        };
        defer tree.close(zio.io());
        var walker = try tree.walk(allocator);
        defer walker.deinit();
        var entries: std.ArrayList([]const u8) = .empty;
        defer {
            for (entries.items) |entry| allocator.free(entry);
            entries.deinit(allocator);
        }
        while (try walker.next(zio.io())) |entry| {
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
            const stat = tree.statFile(zio.io(), path, .{}) catch continue;
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
    child.kill(zio.io());
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
    const cwd = std.Io.Dir.cwd();
    cwd.access(zio.io(), "build.zig", .{}) catch return error.MissingBuildFile;
    var frontend_child: ?std.process.Child = null;
    if (frontend) |command| {
        frontend_child = try zio.spawn(.{ .argv = try shellCommand(allocator, command) });
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
            app = try zio.spawn(.{ .argv = &.{executable} });
            std.debug.print("ziggurat: running {s} (watching {d} paths)\n", .{ executable, roots.items.len });
        } else std.debug.print("ziggurat: build failed; waiting for changes\n", .{});
        while (true) {
            zio.sleep(300 * std.time.ns_per_ms);
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
        windows.WaitForSingleObject(child.id.?, 0) catch |err| switch (err) {
            error.WaitTimeOut => return false,
            else => return err,
        };
        _ = try child.wait(zio.io());
        return true;
    }
    const result = zio.posix.waitpid(child.id.?, std.posix.W.NOHANG);
    if (result.pid == 0) return false;
    // Reaped here: the child holds nothing more to release.
    child.id = null;
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
    const result = zio.run(allocator, .{ .argv = argv, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
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
        if (std.mem.eql(u8, version, "0.17.0")) report(.ok, "zig", version) else {
            report(.missing, "zig", try std.fmt.allocPrint(allocator, "{s} (this framework targets 0.17.0)", .{version}));
            failed = true;
        }
    } else {
        report(.missing, "zig", "not found; install Zig 0.17.0 or set ZIG");
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
            if ((zio.hasEnvVar(allocator, "DISPLAY") catch false) or (zio.hasEnvVar(allocator, "WAYLAND_DISPLAY") catch false)) report(.ok, "display", "available") else report(.warning, "display", "no DISPLAY or WAYLAND_DISPLAY; windows cannot open here");
        },
        .windows => {
            const sdk = std.fs.path.join(allocator, &.{ options.framework_root, ".deps", "webview2", "build", "native", "include", "WebView2.h" }) catch unreachable;
            if (std.Io.Dir.cwd().access(sdk, .{})) |_| report(.ok, "WebView2 SDK", sdk) else |_| {
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
    if (readProject(allocator, std.Io.Dir.cwd())) |project| report(.ok, "project", project.identity) else |err| switch (err) {
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

// ---------------------------------------------------------------- publish

fn publishCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var publish_options: publish.Options = .{ .directory = "", .repository = "", .tag = "" };
    var bucket: ?s3.Bucket = null;
    var prefix: []const u8 = "";
    var region: ?[]const u8 = null;
    var endpoint: ?[]const u8 = null;
    var path_style: ?bool = null;
    var url: []const u8 = "";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else null;
        if (std.mem.eql(u8, arg, "--not-latest")) {
            publish_options.latest = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--path-style")) {
            path_style = true;
            continue;
        }
        if (publish_options.directory.len == 0 and !std.mem.startsWith(u8, arg, "--")) {
            publish_options.directory = arg;
            continue;
        }
        const text = value orelse return error.InvalidArguments;
        index += 1;
        if (std.mem.eql(u8, arg, "--github")) publish_options.repository = text else if (std.mem.eql(u8, arg, "--tag")) publish_options.tag = text else if (std.mem.eql(u8, arg, "--notes")) publish_options.notes_file = text else if (std.mem.eql(u8, arg, "--s3")) bucket = .{ .name = text } else if (std.mem.eql(u8, arg, "--prefix")) prefix = text else if (std.mem.eql(u8, arg, "--region")) region = text else if (std.mem.eql(u8, arg, "--endpoint")) endpoint = text else if (std.mem.eql(u8, arg, "--url")) url = text else return error.InvalidArguments;
    }
    if (publish_options.directory.len == 0) return error.InvalidArguments;
    if (bucket) |*target| {
        if (publish_options.repository.len > 0 or url.len == 0) return error.InvalidArguments;
        target.prefix = prefix;
        target.region = region;
        target.endpoint = endpoint;
        target.path_style = path_style;
        var environment = try zio.getEnvMap(allocator);
        var console: console_mod.Console = .stderr(&environment);
        defer console.deinit();
        publish.toS3(allocator, .{ .directory = publish_options.directory, .bucket = target.*, .url = url }, &environment, &console) catch |err| {
            console.fatal("{s}", .{publish.describe(err)});
            return 1;
        };
        return 0;
    }
    if (publish_options.repository.len == 0 or publish_options.tag.len == 0) return error.InvalidArguments;
    if (zio.getEnvVarOwned(allocator, "GH")) |gh| publish_options.gh = gh else |_| {}
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(zio.io(), &buffer);
    try publish.github(allocator, publish_options, &stdout.interface);
    return 0;
}

// ---------------------------------------------------------------- generate

fn projectDirectory(args: []const []const u8) ![]const u8 {
    if (args.len > 1) return error.InvalidArguments;
    return if (args.len == 1) args[0] else ".";
}

/// Writes `bytes` at `path` unless it holds them already. Returns whether it wrote.
fn writeChanged(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !bool {
    if (dir.readFileAlloc(zio.io(), path, allocator, .limited(64 * 1024 * 1024))) |old| {
        if (std.mem.eql(u8, old, bytes)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(zio.io(), parent);
    try dir.writeFile(zio.io(), .{ .sub_path = path, .data = bytes });
    return true;
}

/// Where the TypeScript module of the catalogs goes: next to the client,
/// named after the catalogs' directory, as src/locales.ts.
pub fn i18nModule(allocator: std.mem.Allocator, project: Project) !?[]const u8 {
    const config = project.i18n orelse return null;
    const bindings = project.bindings orelse return null;
    const name = try std.fmt.allocPrint(allocator, "{s}.ts", .{std.fs.path.basename(config.dir)});
    return if (std.fs.path.dirname(bindings)) |parent| try std.fs.path.join(allocator, &.{ parent, name }) else name;
}

/// Shows the diagnostics of the catalogs and returns their errors.
fn reportCatalog(console: *console_mod.Console, catalog: *const i18n_gen.Catalog, warnings: bool) usize {
    for (catalog.diagnostics) |d| {
        if (!d.warning) console.problem("{f}", .{d}) else if (warnings) console.warn("{f}", .{d});
    }
    return catalog.errors();
}

pub const I18nOutput = struct { written: []const []const u8, catalog: i18n_gen.Catalog };

/// Checks the catalogs and writes their accessors where they changed:
/// `catalog.zig` in their directory and, with bindings, the TypeScript
/// module. Errors of the catalogs fail it after `console` shows them.
pub fn writeI18n(allocator: std.mem.Allocator, dir: std.Io.Dir, project: Project, console: *console_mod.Console) !I18nOutput {
    const config = project.i18n orelse return .{ .written = &.{}, .catalog = undefined };
    var catalogs = dir.openDir(zio.io(), config.dir, .{ .iterate = true }) catch return error.MissingCatalogs;
    defer catalogs.close(zio.io());
    const catalog = try i18n_gen.load(allocator, catalogs, .{ .dir_name = config.dir, .source = config.source });
    const errors = reportCatalog(console, &catalog, false);
    if (errors > 0) {
        console.fatal("{d} {s} in the catalogs (ziggurat i18n check lists the warnings too)", .{ errors, if (errors == 1) "error" else "errors" });
        return error.CatalogErrors;
    }
    var written: std.ArrayList([]const u8) = .empty;
    const zig = try i18n_gen.formattedZig(allocator, &catalog);
    const zig_path = try std.fs.path.join(allocator, &.{ config.dir, i18n_gen.zig_file });
    if (try writeChanged(allocator, dir, zig_path, zig)) try written.append(allocator, zig_path);
    if (try i18nModule(allocator, project)) |module| {
        var typescript: std.Io.Writer.Allocating = .init(allocator);
        try i18n_gen.writeTypeScript(&typescript.writer, &catalog);
        if (try writeChanged(allocator, dir, module, typescript.written())) try written.append(allocator, module);
    }
    return .{ .written = written.items, .catalog = catalog };
}

fn generateCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var output: ?[]const u8 = null;
    var framework: []const u8 = options.framework_root;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--framework")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            if (arg[1] == 'o') output = args[index + 1] else framework = args[index + 1];
            index += 1;
        } else if (std.mem.startsWith(u8, arg, "-")) return error.InvalidArguments else try rest.append(allocator, arg);
    }
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), try projectDirectory(rest.items), .{});
    defer dir.close(zio.io());
    var project = try readProject(allocator, dir);
    if (output) |path| project.bindings = path;
    if (project.bindings == null and project.i18n == null) {
        console.fatal("the project has nothing to generate: set i18n or bindings in ziggurat.json, or pass -o", .{});
        return 1;
    }
    // The accessors come first: the app's Zig code calls them.
    if (project.i18n) |config| {
        var task: console_mod.Task = undefined;
        console.start(&task, "Generating the accessors of the catalogs");
        const result = writeI18n(allocator, dir, project, &console) catch |err| {
            task.fail();
            if (err == error.CatalogErrors) return 1;
            if (err == error.MissingCatalogs) {
                console.fatal("i18n.dir {s} is not a directory: create it with {s}.json, the messages of the source language", .{ config.dir, config.source });
                return 1;
            }
            return err;
        };
        if (result.written.len > 0) {
            var names: std.Io.Writer.Allocating = .init(allocator);
            for (result.written, 0..) |path, i| try names.writer.print("{s}{s}", .{ if (i > 0) ", " else "", path });
            task.done("Wrote {s}", .{names.written()});
        } else task.done("The accessors of {s} are up to date", .{config.dir});
        for (result.catalog.diagnostics) |d| if (d.warning) console.warn("{f}", .{d});
    }
    const bindings = project.bindings orelse return 0;
    const service = project.service orelse {
        console.fatal("writing the client of {s} needs service in ziggurat.json: the Zig source that exports the Service type", .{bindings});
        return 1;
    };
    var task: console_mod.Task = undefined;
    console.start(&task, "Generating the TypeScript client");
    const client = generateClient(allocator, dir, framework, service, &console) catch |err| {
        task.fail();
        if (err == error.ClientGenerationFailed) return 1;
        return err;
    };
    if (try writeChanged(allocator, dir, bindings, client)) task.done("Wrote {s}", .{bindings}) else task.done("{s} is up to date", .{bindings});
    return 0;
}

/// The client of the Service type `service` exports, made by the
/// framework's `ipc-client` step.
fn generateClient(allocator: std.mem.Allocator, dir: std.Io.Dir, framework: []const u8, service: []const u8, console: *console_mod.Console) ![]const u8 {
    const root = try zio.realPathAlloc(dir, ".", allocator);
    const source = try std.fs.path.resolve(allocator, &.{ root, service });
    const prefix = try std.fs.path.join(allocator, &.{ root, ".zig-cache", "ziggurat-generate" });
    const result = try zio.run(allocator, .{
        .argv = &.{ try zigExecutable(allocator), "build", "ipc-client", try std.fmt.allocPrint(allocator, "-Dipc-service={s}", .{source}), "--prefix", prefix },
        .cwd = .{ .path = framework },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) {
        console.problem("zig build ipc-client failed:\n{s}", .{std.mem.trimEnd(u8, result.stderr, "\n")});
        return error.ClientGenerationFailed;
    }
    var out = try std.Io.Dir.openDirAbsolute(zio.io(), prefix, .{});
    defer out.close(zio.io());
    return out.readFileAlloc(zio.io(), "share/ziggurat/client.ts", allocator, .limited(64 * 1024 * 1024));
}

fn i18nCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "check")) {
        try std.Io.File.stderr().writeStreamingAll(zio.io(),
            \\Usage: ziggurat i18n check [DIR]
            \\
            \\Checks the catalogs of the app's messages (i18n in ziggurat.json): that their
            \\messages parse, that translations have the arguments of the source language's
            \\messages and the plural forms of their languages, and which messages they
            \\lack. Errors exit with status 1; warnings do not.
            \\
        );
        return 2;
    }
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), try projectDirectory(args[1..]), .{});
    defer dir.close(zio.io());
    const project = try readProject(allocator, dir);
    const config = project.i18n orelse {
        console.fatal("the project has no catalogs: set i18n in ziggurat.json, as \"i18n\": {{\"dir\": \"locales\", \"source\": \"en\"}}", .{});
        return 1;
    };
    var catalogs = dir.openDir(zio.io(), config.dir, .{ .iterate = true }) catch {
        console.fatal("i18n.dir {s} is not a directory: create it with {s}.json, the messages of the source language", .{ config.dir, config.source });
        return 1;
    };
    defer catalogs.close(zio.io());
    const catalog = try i18n_gen.load(allocator, catalogs, .{ .dir_name = config.dir, .source = config.source });
    const errors = reportCatalog(&console, &catalog, true);
    if (errors > 0) {
        console.fatal("{d} {s} in the catalogs", .{ errors, if (errors == 1) "error" else "errors" });
        return 1;
    }
    var languages: std.Io.Writer.Allocating = .init(allocator);
    for (catalog.languages, 0..) |tag, i| try languages.writer.print("{s}{s}", .{ if (i > 0) ", " else "", tag });
    console.log("{d} messages in {s}", .{ catalog.keys.len, languages.written() });
    return 0;
}

// ---------------------------------------------------------------- skills

/// The agent skills every project carries, by path under .agents/skills.
const skills = [_]struct { path: []const u8, bytes: []const u8 }{
    .{ .path = "ziggurat-maintenance/SKILL.md", .bytes = @embedFile("templates/skills/ziggurat-maintenance/SKILL.md") },
    .{ .path = "ziggurat-maintenance/agents/openai.yaml", .bytes = @embedFile("templates/skills/ziggurat-maintenance/agents/openai.yaml") },
};

/// Writes the bundled skill files, replacing older copies of them and
/// leaving other skills and other files of a bundled skill alone.
pub fn installSkills(dir: std.Io.Dir) !void {
    var root = try dir.createDirPathOpen(zio.io(), ".agents/skills", .{});
    defer root.close(zio.io());
    for (skills) |skill| {
        if (std.fs.path.dirname(skill.path)) |parent| try root.createDirPath(zio.io(), parent);
        try root.writeFile(zio.io(), .{ .sub_path = skill.path, .data = skill.bytes });
    }
}

fn installSkillsCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const path = try projectDirectory(args);
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    var dir = std.Io.Dir.cwd().openDir(zio.io(), path, .{}) catch {
        console.fatal("{s} is not a directory", .{path});
        return 1;
    };
    defer dir.close(zio.io());
    try installSkills(dir);
    console.log("Installed skills in {s}", .{try std.fs.path.join(allocator, &.{ path, ".agents", "skills" })});
    return 0;
}

// ---------------------------------------------------------------- icon, sign, vet

fn iconCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var source: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-o") and index + 1 < args.len) {
            output = args[index + 1];
            index += 1;
        } else if (source == null and !std.mem.startsWith(u8, args[index], "-")) source = args[index] else return error.InvalidArguments;
    }
    const path = source orelse return error.InvalidArguments;
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(zio.io(), path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
        console.fatal("{s}: {s}", .{ path, @errorName(err) });
        return 1;
    };
    const ico = icon_mod.pngToIco(allocator, bytes) catch |err| {
        console.fatal("{s}: {s}", .{ path, switch (err) {
            error.IconNotPng => "the icon must be a PNG",
            error.IconNotSquare => "the icon must be square",
            else => @errorName(err),
        } });
        return 1;
    };
    const destination = output orelse try std.mem.concat(allocator, u8, &.{ path[0 .. path.len - std.fs.path.extension(path).len], ".ico" });
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = destination, .data = ico });
    console.log("Wrote {s}", .{destination});
    return 0;
}

/// Sign one file as `config` says, as a step of the console.
fn signFile(allocator: std.mem.Allocator, config: winsign.Windows, file: []const u8) !u8 {
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    var task: console_mod.Task = undefined;
    const name = std.fs.path.basename(file);
    console.start(&task, try std.fmt.allocPrint(allocator, "Signing {s}", .{name}));
    const root = try zio.realPathAlloc(std.Io.Dir.cwd(), ".", allocator);
    winsign.sign(allocator, config, root, file) catch |err| {
        task.fail();
        console.fatal("{s}", .{switch (@as(anyerror, err)) {
            error.SigntoolNotFound => "signing needs signtool from the Windows SDK",
            error.OsslsigncodeNotFound => "signing Windows apps on this system needs osslsigncode (apt install osslsigncode, brew install osslsigncode)",
            error.SignCommandFailed => "windows.signCommand failed",
            error.SigntoolFailed => "signtool failed",
            error.OsslsigncodeFailed => "osslsigncode failed",
            else => @errorName(err),
        }});
        return 1;
    };
    task.done("Signed {s}", .{name});
    return 0;
}

fn signCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidArguments;
    const project = try readProject(allocator, std.Io.Dir.cwd());
    const config = project.windows orelse winsign.Windows{};
    if (!config.signs()) {
        std.debug.print("ziggurat: set windows.certificate or windows.signCommand in ziggurat.json\n", .{});
        return 1;
    }
    for (args) |file| if (try signFile(allocator, config, file) != 0) return 1;
    return 0;
}

fn vetCommand(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const path = try projectDirectory(args);
    var environment = try zio.getEnvMap(allocator);
    var console: console_mod.Console = .stderr(&environment);
    defer console.deinit();
    var dir = std.Io.Dir.cwd().openDir(zio.io(), path, .{}) catch {
        console.fatal("{s} is not a directory", .{path});
        return 1;
    };
    defer dir.close(zio.io());
    var files: std.ArrayList([]const u8) = .empty;
    if (dir.access(zio.io(), "build.zig", .{})) |_| try files.append(allocator, "build.zig") else |_| {}
    if (dir.openDir(zio.io(), "src", .{ .iterate = true })) |opened| {
        var src = opened;
        defer src.close(zio.io());
        var walker = try src.walk(allocator);
        defer walker.deinit();
        while (try walker.next(zio.io())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            try files.append(allocator, try std.fs.path.join(allocator, &.{ "src", entry.path }));
        }
    } else |_| {}
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    // The compiler's own checks of each file first: unused names, shadowing
    // and the other errors that need no analysis.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ try zigExecutable(allocator), "ast-check" });
    var failures: usize = 0;
    for (files.items) |file| {
        argv.items.len = 2;
        try argv.append(allocator, file);
        var child = try zio.spawn(.{ .argv = argv.items, .cwd = .{ .dir = dir } });
        const term = try child.wait(zio.io());
        if (term != .exited or term.exited != 0) failures += 1;
    }
    if (failures > 0) {
        console.fatal("zig ast-check: {d} file(s) with errors", .{failures});
        return 1;
    }
    var issues: usize = 0;
    for (files.items) |file| {
        const source = try dir.readFileAllocOptions(zio.io(), file, allocator, .limited(16 * 1024 * 1024), .of(u8), 0);
        const diagnostics = vet.analyze(allocator, source) catch |err| {
            console.fatal("{s}: {s}", .{ file, @errorName(err) });
            return 1;
        };
        for (diagnostics) |d| console.problem("{s}:{d}:{d}: {s}", .{ try std.fs.path.join(allocator, &.{ path, file }), d.line, d.column, d.message });
        issues += diagnostics.len;
    }
    if (issues > 0) {
        console.fatal("{d} view lifetime issue(s)", .{issues});
        return 1;
    }
    console.log("No issues in {d} file(s)", .{files.items.len});
    return 0;
}

test {
    _ = publish;
    _ = console_mod;
    _ = i18n_gen;
    _ = install_script;
    _ = s3;
    _ = icon_mod;
    _ = winsign;
    _ = vet;
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
    try temp.dir.createDirPath(zio.io(), "framework");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "framework/build.zig.zon", .data = ".{}" });
    for ([_]Template{ .native, .web, .hybrid }) |template| {
        const directory = try std.fmt.allocPrint(allocator, "apps/{s}", .{@tagName(template)});
        try createProject(allocator, temp.dir, .{ .directory = directory, .template = template, .name = "Sample App", .framework = "framework" });
        var project = try temp.dir.openDir(zio.io(), directory, .{});
        defer project.close(zio.io());
        const zon = try project.readFileAlloc(zio.io(), "build.zig.zon", allocator, .limited(4096));
        try std.testing.expect(std.mem.indexOf(u8, zon, ".path = \"../../framework\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .sample_app") != null);
        const info = try readProject(allocator, project);
        try std.testing.expectEqualStrings("com.example.sample_app", info.identity);
        try std.testing.expectEqualStrings("sample-app", info.executable);
        try std.testing.expectEqual(template != .native, if (project.access(zio.io(), "src/index.html", .{})) |_| true else |_| false);
        try project.access(zio.io(), ".agents/skills/ziggurat-maintenance/SKILL.md", .{});
        try std.testing.expectError(error.DirectoryNotEmpty, createProject(allocator, temp.dir, .{ .directory = directory, .framework = "framework" }));
    }
    try std.testing.expectError(error.FrameworkNotFound, createProject(allocator, temp.dir, .{ .directory = "apps/none", .framework = "apps" }));
}

test "snapshots change with edits and ignore build output" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const allocator = std.testing.allocator;
    try temp.dir.createDirPath(zio.io(), "src/.zig-cache");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "src/main.zig", .data = "a" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "build.zig", .data = "b" });
    const first = try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "src/.zig-cache/x", .data = "ignored" });
    try std.testing.expectEqual(first, try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" }));
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "src/main.zig", .data = "changed" });
    try std.testing.expect(first != try snapshot(allocator, temp.dir, &.{ "src", "build.zig", "missing" }));
}

test "generate writes the accessors where they changed, and skills keep other files" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDirPath(zio.io(), "i18n");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "i18n/en.json", .data = "{\"hello\": \"Hello, {name}!\"}" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "i18n/de.json", .data = "{\"hello\": \"Hallo, {name}!\"}" });
    const project: Project = .{ .name = "App", .identity = "com.example.app", .executable = "app", .template = "web", .i18n = .{ .dir = "i18n" }, .bindings = "web/src/client.ts" };
    try std.testing.expectEqualStrings("web/src" ++ std.fs.path.sep_str ++ "i18n.ts", (try i18nModule(allocator, project)).?);
    const file = try temp.dir.createFile(zio.io(), "console", .{ .read = true });
    defer file.close(zio.io());
    var console: console_mod.Console = .{ .file = file, .mode = .{ .live = false, .color = false, .symbols = &console_mod.plain_symbols } };
    defer console.deinit();
    const first = try writeI18n(allocator, temp.dir, project, &console);
    try std.testing.expectEqual(@as(usize, 2), first.written.len);
    const zig = try temp.dir.readFileAlloc(zio.io(), "i18n/catalog.zig", allocator, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, zig, "pub fn hello(self: Messages, writer: *std.Io.Writer, name: []const u8)") != null);
    const module = try temp.dir.readFileAlloc(zio.io(), "web/src/i18n.ts", allocator, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, module, "hello(name: string): string;") != null);
    try std.testing.expectEqual(@as(usize, 0), (try writeI18n(allocator, temp.dir, project, &console)).written.len);
    try temp.dir.writeFile(zio.io(), .{ .sub_path = "i18n/de.json", .data = "{\"hello\": \"Hallo, {who}!\"}" });
    try std.testing.expectError(error.CatalogErrors, writeI18n(allocator, temp.dir, project, &console));
    var shown_reader = file.reader(zio.io(), &.{});
    const shown = try shown_reader.interface.allocRemaining(allocator, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, shown, "  × i18n/de.json:1: \"hello\" uses the argument who, but the source message has the arguments name\n") != null);

    try temp.dir.createDirPath(zio.io(), ".agents/skills/ziggurat-maintenance");
    try temp.dir.writeFile(zio.io(), .{ .sub_path = ".agents/skills/ziggurat-maintenance/SKILL.md", .data = "old" });
    try temp.dir.writeFile(zio.io(), .{ .sub_path = ".agents/skills/ziggurat-maintenance/notes.md", .data = "mine" });
    try temp.dir.createDirPath(zio.io(), ".agents/skills/other");
    try installSkills(temp.dir);
    const skill = try temp.dir.readFileAlloc(zio.io(), ".agents/skills/ziggurat-maintenance/SKILL.md", allocator, .limited(1 << 16));
    try std.testing.expect(std.mem.startsWith(u8, skill, "---\nname: ziggurat-maintenance\n"));
    try std.testing.expectEqualStrings("mine", try temp.dir.readFileAlloc(zio.io(), ".agents/skills/ziggurat-maintenance/notes.md", allocator, .limited(64)));
    try temp.dir.access(zio.io(), ".agents/skills/other", .{});
}
