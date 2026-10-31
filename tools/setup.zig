const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const update = @import("ziggurat_update");
const format = @import("setup_format");

const windows = builtin.os.tag == .windows;
const exe_suffix = if (windows) ".exe" else "";

const usage =
    \\Setup program: SETUP [--silent] [--scope user|machine] [--dir PATH]
    \\Uninstaller:   uninstall [--silent] [--purge]
    \\Launcher:      any other name starts the current release with the given arguments.
    \\
    \\user scope installs without elevation and supports in-application updates;
    \\machine scope needs an administrator (Windows) or root (Linux). --purge also
    \\removes this user's application data. Running applications are not closed.
    \\
;

/// Written beside the launcher; read by the launcher and the uninstaller.
const InstallRecord = struct {
    format: u16 = 1,
    name: []const u8,
    identity: []const u8,
    target: []const u8,
    executable: []const u8,
    version: []const u8,
    scope: []const u8,
    desktop: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    link: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
    uninstall_hook: ?[]const u8 = null,
};

pub fn main(init: std.process.Init.Minimal) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const code = run(arena.allocator(), init.args) catch |err| {
        std.debug.print("setup: {s}\n", .{@errorName(err)});
        if (builtin.mode == .debug) if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn run(allocator: std.mem.Allocator, process_args: std.process.Args) !u8 {
    const args = try zio.argsAlloc(allocator, process_args);
    const self_path = try zio.executablePathAlloc(allocator);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--uninstall-from")) return finishUninstall(allocator, args[2..]);
    var self = try std.Io.Dir.openFileAbsolute(zio.io(), self_path, .{});
    defer self.close(zio.io());
    if (try format.locate(self)) |located| return install(allocator, args[1..], self, located);
    const base = std.fs.path.basename(self_path);
    const directory = std.fs.path.dirname(self_path) orelse return error.InvalidExecutablePath;
    if (std.ascii.startsWithIgnoreCase(base, "uninstall")) return uninstall(allocator, args[1..], directory, self_path);
    return launch(allocator, args, directory);
}

// ---------------------------------------------------------------- launcher

fn launch(allocator: std.mem.Allocator, args: []const []const u8, directory: []const u8) !u8 {
    const record = readRecord(allocator, directory) catch |err| {
        if (err == error.FileNotFound) {
            try std.Io.File.stderr().writeStreamingAll(zio.io(), usage);
            return 2;
        }
        return err;
    };
    const executable = try update.launch.currentExecutable(allocator, directory, record.identity, record.target);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, executable);
    if (args.len > 1) try argv.appendSlice(allocator, args[1..]);
    if (windows) {
        // Start detached so the launcher never holds its own file open while
        // an update or the installer replaces it.
        try update.launch.spawnDetached(allocator, argv.items, std.fs.path.dirname(executable));
        return 0;
    }
    const err = zio.replace(.{ .argv = argv.items });
    return err;
}

fn readRecord(allocator: std.mem.Allocator, directory: []const u8) !InstallRecord {
    var dir = try std.Io.Dir.cwd().openDir(zio.io(), directory, .{});
    defer dir.close(zio.io());
    const bytes = try dir.readFileAlloc(zio.io(), "install.json", allocator, .limited(64 * 1024));
    const record = std.json.parseFromSliceLeaky(InstallRecord, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidInstallRecord;
    if (record.format != 1) return error.InvalidInstallRecord;
    return record;
}

// ---------------------------------------------------------------- install

const Scope = enum { user, machine };

const Locations = struct {
    root: []const u8,
    data: []const u8,
    desktop: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    link: ?[]const u8 = null,
    shortcut: ?[]const u8 = null,
};

fn env(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return zio.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => error.MissingEnvironment,
        else => err,
    };
}

fn linuxDataHome(allocator: std.mem.Allocator) ![]const u8 {
    if (zio.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |value| {
        if (std.fs.path.isAbsolute(value)) return value;
    } else |_| {}
    return std.fs.path.join(allocator, &.{ try env(allocator, "HOME"), ".local", "share" });
}

fn locations(allocator: std.mem.Allocator, config: format.Config, scope: Scope, directory: ?[]const u8) !Locations {
    const id = config.identity;
    if (windows) {
        const folder = config.install_dir_name orelse id;
        const local = try env(allocator, "LOCALAPPDATA");
        const menu_base = if (scope == .user)
            try std.fs.path.join(allocator, &.{ try env(allocator, "APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs" })
        else
            try std.fs.path.join(allocator, &.{ try env(allocator, "ProgramData"), "Microsoft", "Windows", "Start Menu", "Programs" });
        return .{
            .root = directory orelse if (scope == .user) try std.fs.path.join(allocator, &.{ local, "Programs", folder }) else try std.fs.path.join(allocator, &.{ try env(allocator, "ProgramFiles"), folder }),
            .data = try std.fs.path.join(allocator, &.{ local, id }),
            .shortcut = try std.fs.path.join(allocator, &.{ menu_base, try std.fmt.allocPrint(allocator, "{s}.lnk", .{config.name}) }),
        };
    }
    const data_home = try linuxDataHome(allocator);
    const share = if (scope == .user) data_home else "/usr/share";
    return .{
        .root = directory orelse if (scope == .user) try std.fs.path.join(allocator, &.{ data_home, id, "install" }) else try std.fs.path.join(allocator, &.{ "/opt", id }),
        .data = try std.fs.path.join(allocator, &.{ data_home, id }),
        .desktop = try std.fs.path.join(allocator, &.{ share, "applications", try std.fmt.allocPrint(allocator, "{s}.desktop", .{id}) }),
        .icon = if (config.icon != null) try std.fs.path.join(allocator, &.{ share, "icons", "hicolor", "256x256", "apps", try std.fmt.allocPrint(allocator, "{s}.png", .{id}) }) else null,
        .link = if (scope == .user) try std.fs.path.join(allocator, &.{ try env(allocator, "HOME"), ".local", "bin", config.executable }) else try std.fs.path.join(allocator, &.{ "/usr/local/bin", config.executable }),
    };
}

fn say(silent: bool, comptime fmt: []const u8, args: anytype) void {
    if (!silent) std.debug.print(fmt ++ "\n", args);
}

const HookContext = struct {
    root: []const u8,
    scope: []const u8,
    version: []const u8,
    silent: bool,
    launcher: ?[]const u8 = null,
};

/// Runs one of the app's hooks with the shell and reports whether it
/// succeeded. Its output goes where the setup program's does.
fn runHook(allocator: std.mem.Allocator, kind: []const u8, command: []const u8, context: HookContext) bool {
    return runHookChecked(allocator, command, context) catch |err| {
        std.debug.print("setup: the {s} hook could not run: {s}\n", .{ kind, @errorName(err) });
        return false;
    };
}

fn runHookChecked(allocator: std.mem.Allocator, command: []const u8, context: HookContext) !bool {
    var map = try zio.getEnvMap(allocator);
    try map.put("ZIGGURAT_INSTALL_DIR", context.root);
    try map.put("ZIGGURAT_SCOPE", context.scope);
    try map.put("ZIGGURAT_VERSION", context.version);
    try map.put("ZIGGURAT_SILENT", if (context.silent) "1" else "0");
    if (context.launcher) |path| try map.put("ZIGGURAT_APP", path);
    if (!windows) {
        var child = try zio.spawn(.{ .argv = &.{ "/bin/sh", "-c", command }, .environ_map = &map });
        return switch (try child.wait(zio.io())) {
            .exited => |code| code == 0,
            else => false,
        };
    }
    // cmd.exe reads quotes its own way, which no argument quoting gives it:
    // the command runs as a batch file's line instead.
    var random: [8]u8 = undefined;
    zio.random.bytes(&random);
    const script = try std.fs.path.join(allocator, &.{ try env(allocator, "TEMP"), try std.fmt.allocPrint(allocator, "ziggurat-hook-{s}.cmd", .{std.fmt.bytesToHex(random, .lower)}) });
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = script, .data = try std.fmt.allocPrint(allocator, "@echo off\r\n{s}\r\n", .{command}) });
    defer std.Io.Dir.cwd().deleteFile(zio.io(), script) catch {};
    var child = try zio.spawn(.{ .argv = &.{script}, .environ_map = &map });
    return switch (try child.wait(zio.io())) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn install(allocator: std.mem.Allocator, args: []const []const u8, self: std.Io.File, located: format.Located) !u8 {
    var silent = false;
    var scope: Scope = .user;
    var directory: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "/S")) silent = true else if (std.mem.eql(u8, arg, "--scope") and index + 1 < args.len) {
            scope = std.meta.stringToEnum(Scope, args[index + 1]) orelse return error.InvalidArguments;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--dir") and index + 1 < args.len) {
            directory = try std.fs.path.resolve(allocator, &.{ try std.process.currentPathAlloc(zio.io(), allocator), args[index + 1] });
            index += 1;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(zio.io(), usage);
            return 0;
        } else return error.InvalidArguments;
    }
    if (scope == .machine and !elevated()) return error.ElevationRequired;

    // The code signature (when present) authenticates the setup file; these
    // digests reject a truncated or corrupted payload before anything is written.
    const config_bytes = try allocator.alloc(u8, located.config_bytes);
    if (try self.readPositionalAll(zio.io(), config_bytes, located.config_offset) != config_bytes.len) return error.InvalidSetupPayload;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(config_bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &located.config_sha256)) return error.InvalidSetupPayload;
    const config = std.json.parseFromSliceLeaky(format.Config, allocator, config_bytes, .{ .allocate = .alloc_always }) catch return error.InvalidSetupPayload;
    try update.publication.validateFilename(config.executable);
    if (config.install_dir_name) |name| if (!format.validInstallDirName(name)) return error.InvalidSetupPayload;
    const version = try update.retention.parseVersion(config.version);
    const where = try locations(allocator, config, scope, directory);
    const hook_context: HookContext = .{ .root = where.root, .scope = @tagName(scope), .version = config.version, .silent = silent };
    if (config.hooks.init) |command| if (!runHook(allocator, "init", command, hook_context)) {
        std.debug.print("setup: the app's init hook failed; nothing was installed\n", .{});
        return 1;
    };
    say(silent, "Installing {s} {s} into {s}", .{ config.name, config.version, where.root });

    // The root is dedicated to this application: uninstalling deletes it whole,
    // so an existing directory must be empty or an earlier installation.
    const root_existed = if (std.Io.Dir.cwd().access(zio.io(), where.root, .{})) |_| true else |_| false;
    try std.Io.Dir.cwd().createDirPath(zio.io(), where.root);
    var root = try std.Io.Dir.cwd().openDir(zio.io(), where.root, .{ .iterate = true });
    defer root.close(zio.io());
    if (root_existed) {
        var iterator = root.iterate();
        if (try iterator.next(zio.io()) != null) {
            const existing = readRecord(allocator, where.root) catch return error.DirectoryNotEmpty;
            if (!std.mem.eql(u8, existing.identity, config.identity)) return error.DirectoryNotEmpty;
        }
    }
    const previous: ?update.Version = if (update.publication.readCurrent(allocator, root, config.identity, config.target)) |current| current.version else |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (previous) |old| if (old.order(version) == .gt) return error.NewerVersionInstalled;

    // Stage the package where publication copies and re-verifies it.
    var random: [8]u8 = undefined;
    zio.random.bytes(&random);
    const staged_name = try std.fmt.allocPrint(allocator, "setup-{s}.zip", .{std.fmt.bytesToHex(random, .lower)});
    var staged = try root.createFile(zio.io(), staged_name, .{ .read = true, .exclusive = true });
    defer {
        staged.close(zio.io());
        root.deleteFile(zio.io(), staged_name) catch {};
    }
    try copyRange(self, staged, located.zip_offset, located.zip_bytes);
    const manifest: update.Manifest = .{ .identity = config.identity, .target = config.target, .version = version, .url = "https://setup.invalid/package.zip", .bytes = located.zip_bytes, .sha256 = located.zip_sha256, .signature = @splat(0) };
    const fresh = previous == null;
    var published = false;
    errdefer if (fresh) {
        removeIntegration(where);
        if (root_existed) emptyDirectory(root) else std.Io.Dir.cwd().deleteTree(zio.io(), where.root) catch {};
    } else if (published and previous.?.order(version) != .eq) {
        _ = update.retention.rollback(allocator, root, config.identity, config.target, previous.?) catch {};
    };
    if (update.publication.publishAuthenticated(allocator, root, staged, manifest, .{ .retain_archive = true })) |_| {
        published = true;
    } else |err| if (err != error.AlreadyPublished) return err;

    // Launcher and uninstaller are copies of this stub without the payload.
    const launcher_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.fs.path.stem(config.executable), exe_suffix });
    try writeStub(root, self, located.stub_bytes, launcher_name);
    try writeStub(root, self, located.stub_bytes, "uninstall" ++ exe_suffix);
    const launcher = try std.fs.path.join(allocator, &.{ where.root, launcher_name });
    const record: InstallRecord = .{
        .name = config.name,
        .identity = config.identity,
        .target = config.target,
        .executable = config.executable,
        .version = config.version,
        .scope = @tagName(scope),
        .desktop = where.desktop,
        .icon = where.icon,
        .link = where.link,
        .shortcut = where.shortcut,
        .uninstall_hook = config.hooks.uninstall,
    };
    try atomicWrite(root, "install.json", try std.json.Stringify.valueAlloc(allocator, record, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }));
    if (windows) try integrateWindows(allocator, config, where, scope, launcher, located.zip_bytes) else try integrateLinux(allocator, config, where, root, launcher, version);
    if (config.hooks.install) |command| {
        var context = hook_context;
        context.launcher = launcher;
        if (!runHook(allocator, "install", command, context)) {
            std.debug.print("setup: {s} is installed, but the app's install hook failed\n", .{config.name});
            return 1;
        }
    }
    say(silent, "Installed. Start {s}; uninstall with {s}", .{ launcher, try std.fs.path.join(allocator, &.{ where.root, "uninstall" ++ exe_suffix }) });
    return 0;
}

fn copyRange(source: std.Io.File, destination: std.Io.File, offset: u64, length: u64) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var done: u64 = 0;
    while (done < length) {
        const part: usize = @intCast(@min(buffer.len, length - done));
        if (try source.readPositionalAll(zio.io(), buffer[0..part], offset + done) != part) return error.InvalidSetupPayload;
        try destination.writeStreamingAll(zio.io(), buffer[0..part]);
        done += part;
    }
    try destination.sync(zio.io());
}

fn writeStub(root: std.Io.Dir, self: std.Io.File, length: u64, name: []const u8) !void {
    // A running launcher cannot be overwritten on Windows, but it can be renamed.
    if (windows) {
        const old = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.old", .{name});
        defer std.heap.page_allocator.free(old);
        root.deleteFile(zio.io(), old) catch {};
        root.rename(name, root, old, zio.io()) catch {};
        root.deleteFile(zio.io(), old) catch {};
    }
    var atomic_buffer: [4096]u8 = undefined;
    var atomic = try zio.AtomicFile.init(root, name, .{ .write_buffer = &atomic_buffer, .permissions = .executable_file });
    defer atomic.deinit();
    try copyRange(self, atomic.file_writer.file, 0, length);
    try atomic.renameIntoPlace();
}

fn atomicWrite(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var atomic_buffer: [4096]u8 = undefined;
    var atomic = try zio.AtomicFile.init(dir, name, .{ .write_buffer = &atomic_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.flush();
    try atomic.file_writer.file.sync(zio.io());
    try atomic.renameIntoPlace();
}

fn writePath(path: []const u8, bytes: []const u8, mode: u32) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
    var file = try std.Io.Dir.cwd().createFile(zio.io(), path, .{ .permissions = zio.mode(mode) });
    defer file.close(zio.io());
    try file.writeStreamingAll(zio.io(), bytes);
}

fn integrateLinux(allocator: std.mem.Allocator, config: format.Config, where: Locations, root: std.Io.Dir, launcher: []const u8, version: update.Version) !void {
    var icon_name: ?[]const u8 = null;
    if (config.icon) |icon| {
        update.publication.validateFilename(icon) catch return error.InvalidSetupPayload;
        var path_buffer: [512]u8 = undefined;
        const release = try std.fmt.bufPrint(&path_buffer, "releases/{s}-{d}.{d}.{d}.{d}/{s}", .{ config.target, version.major, version.minor, version.patch, version.revision, icon });
        const bytes = try root.readFileAlloc(zio.io(), release, allocator, .limited(16 * 1024 * 1024));
        try writePath(where.icon.?, bytes, 0o644);
        icon_name = config.identity;
    }
    try writePath(where.desktop.?, try format.desktopEntry(allocator, config, launcher, icon_name), 0o644);
    const link = where.link.?;
    if (std.fs.path.dirname(link)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
    std.Io.Dir.cwd().deleteFile(zio.io(), link) catch {};
    try std.Io.Dir.cwd().symLink(zio.io(), launcher, link, .{});
}

fn emptyDirectory(dir: std.Io.Dir) void {
    var iterator = dir.iterate();
    while (iterator.next(zio.io()) catch null) |entry| dir.deleteTree(zio.io(), entry.name) catch {};
}

fn removeIntegration(where: Locations) void {
    for ([_]?[]const u8{ where.desktop, where.icon, where.shortcut }) |path| if (path) |value| std.Io.Dir.cwd().deleteFile(zio.io(), value) catch {};
    // Remove the command link only while it still points into this installation.
    if (where.link) |link| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target = buffer[0 .. std.Io.Dir.cwd().readLink(zio.io(), link, &buffer) catch return];
        if (std.mem.startsWith(u8, target, where.root)) std.Io.Dir.cwd().deleteFile(zio.io(), link) catch {};
    }
}

// ---------------------------------------------------------------- uninstall

fn uninstall(allocator: std.mem.Allocator, args: []const []const u8, directory: []const u8, self_path: []const u8) !u8 {
    for (args) |arg| if (!std.mem.eql(u8, arg, "--silent") and !std.mem.eql(u8, arg, "/S") and !std.mem.eql(u8, arg, "--purge")) return error.InvalidArguments;
    const record = try readRecord(allocator, directory);
    if (std.mem.eql(u8, record.scope, "machine") and !elevated()) return error.ElevationRequired;
    if (!windows) return removeInstallation(allocator, record, directory, args);
    // Windows cannot delete the running uninstaller: continue from a copy in
    // the temporary directory once this process has exited.
    var random: [8]u8 = undefined;
    zio.random.bytes(&random);
    const temporary = try std.fs.path.join(allocator, &.{ try env(allocator, "TEMP"), try std.fmt.allocPrint(allocator, "{s}-uninstall-{s}.exe", .{ record.identity, std.fmt.bytesToHex(random, .lower) }) });
    try std.Io.Dir.copyFileAbsolute(self_path, temporary, zio.io(), .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ temporary, "--uninstall-from", directory, "--parent", try std.fmt.allocPrint(allocator, "{d}", .{win.GetCurrentProcessId()}) });
    try argv.appendSlice(allocator, args);
    try update.launch.spawnDetached(allocator, argv.items, null);
    return 0;
}

fn finishUninstall(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--parent")) return error.InvalidArguments;
    const directory = args[0];
    if (windows) {
        const pid = try std.fmt.parseInt(u32, args[2], 10);
        if (win.OpenProcess(win.SYNCHRONIZE, .FALSE, pid)) |handle| {
            _ = win.WaitForSingleObject(handle, 30_000);
            _ = win.CloseHandle(handle);
        }
        // Remove this temporary copy at the next restart when permitted.
        const self_path = try zio.executablePathAlloc(allocator);
        _ = win.MoveFileExW(try std.unicode.wtf8ToWtf16LeAllocZ(allocator, self_path), null, win.MOVEFILE_DELAY_UNTIL_REBOOT);
    }
    const record = try readRecord(allocator, directory);
    return removeInstallation(allocator, record, directory, args[3..]);
}

fn removeInstallation(allocator: std.mem.Allocator, record: InstallRecord, directory: []const u8, args: []const []const u8) !u8 {
    var silent = false;
    var purge = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "/S")) silent = true else if (std.mem.eql(u8, arg, "--purge")) purge = true;
    }
    if (std.mem.eql(u8, std.fs.path.basename(directory), "") or std.mem.eql(u8, directory, "/")) return error.InvalidInstallRecord;
    if (record.uninstall_hook) |command| {
        const launcher = try std.fs.path.join(allocator, &.{ directory, try std.fmt.allocPrint(allocator, "{s}{s}", .{ std.fs.path.stem(record.executable), exe_suffix }) });
        if (!runHook(allocator, "uninstall", command, .{ .root = directory, .scope = record.scope, .version = record.version, .silent = silent, .launcher = launcher }))
            std.debug.print("setup: the app's uninstall hook failed; removing {s} anyway\n", .{record.name});
    }
    removeIntegration(.{ .root = directory, .data = "", .desktop = record.desktop, .icon = record.icon, .link = record.link, .shortcut = record.shortcut });
    if (windows) try unregisterWindows(allocator, record);
    try std.Io.Dir.cwd().deleteTree(zio.io(), directory);
    if (purge) {
        const config: format.Config = .{ .name = record.name, .identity = record.identity, .version = record.version, .target = record.target, .executable = record.executable };
        const where = try locations(allocator, config, .user, null);
        try std.Io.Dir.cwd().deleteTree(zio.io(), where.data);
        if (windows) try std.Io.Dir.cwd().deleteTree(zio.io(), try std.fs.path.join(allocator, &.{ try env(allocator, "APPDATA"), record.identity }));
    }
    say(silent, "Removed {s}{s}", .{ record.name, if (purge) " and its user data" else "; user data was kept" });
    return 0;
}

// ---------------------------------------------------------------- Windows

const win = if (windows) struct {
    const W = std.os.windows;
    const HKEY = *opaque {};
    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
    const KEY_WRITE: u32 = 0x20006;
    const REG_SZ: u32 = 1;
    const REG_DWORD: u32 = 4;
    const SYNCHRONIZE: u32 = 0x00100000;
    const MOVEFILE_DELAY_UNTIL_REBOOT: u32 = 4;
    extern "advapi32" fn RegCreateKeyExW(HKEY, [*:0]const u16, u32, ?[*:0]u16, u32, u32, ?*anyopaque, *HKEY, ?*u32) callconv(.winapi) i32;
    extern "advapi32" fn RegSetValueExW(HKEY, [*:0]const u16, u32, u32, [*]const u8, u32) callconv(.winapi) i32;
    extern "advapi32" fn RegDeleteTreeW(HKEY, [*:0]const u16) callconv(.winapi) i32;
    extern "advapi32" fn RegCloseKey(HKEY) callconv(.winapi) i32;
    extern "shell32" fn IsUserAnAdmin() callconv(.winapi) W.BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(u32, W.BOOL, u32) callconv(.winapi) ?W.HANDLE;
    extern "kernel32" fn WaitForSingleObject(W.HANDLE, u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(W.HANDLE) callconv(.winapi) W.BOOL;
    extern "kernel32" fn MoveFileExW([*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) W.BOOL;
    extern fn zsetup_create_shortcut([*:0]const u16, [*:0]const u16, [*:0]const u16, [*:0]const u16) callconv(.c) i32;
} else struct {};

fn elevated() bool {
    if (windows) return win.IsUserAnAdmin().toBool();
    return std.os.linux.geteuid() == 0;
}

fn uninstallKey(allocator: std.mem.Allocator, identity: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(allocator, try std.fmt.allocPrint(allocator, "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{s}", .{identity}));
}

fn setString(allocator: std.mem.Allocator, key: win.HKEY, name: []const u8, value: []const u8) !void {
    const wide_name = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, value);
    if (win.RegSetValueExW(key, wide_name, 0, win.REG_SZ, @ptrCast(wide.ptr), @intCast((wide.len + 1) * 2)) != 0) return error.RegistryWriteFailed;
}

fn setDword(allocator: std.mem.Allocator, key: win.HKEY, name: []const u8, value: u32) !void {
    const wide_name = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, name);
    if (win.RegSetValueExW(key, wide_name, 0, win.REG_DWORD, std.mem.asBytes(&value), 4) != 0) return error.RegistryWriteFailed;
}

fn integrateWindows(allocator: std.mem.Allocator, config: format.Config, where: Locations, scope: Scope, launcher: []const u8, package_bytes: u64) !void {
    if (!windows) unreachable;
    const shortcut = where.shortcut.?;
    if (std.fs.path.dirname(shortcut)) |parent| try std.Io.Dir.cwd().createDirPath(zio.io(), parent);
    const hr = win.zsetup_create_shortcut(
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, shortcut),
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, launcher),
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, where.root),
        try std.unicode.wtf8ToWtf16LeAllocZ(allocator, if (config.comment.len > 0) config.comment else config.name),
    );
    if (hr < 0) return error.ShortcutFailed;
    var key: win.HKEY = undefined;
    const hive = if (scope == .user) win.HKEY_CURRENT_USER else win.HKEY_LOCAL_MACHINE;
    if (win.RegCreateKeyExW(hive, try uninstallKey(allocator, config.identity), 0, null, 0, win.KEY_WRITE, null, &key, null) != 0) return error.RegistryWriteFailed;
    defer _ = win.RegCloseKey(key);
    const uninstaller = try std.fs.path.join(allocator, &.{ where.root, "uninstall.exe" });
    try setString(allocator, key, "DisplayName", config.name);
    try setString(allocator, key, "DisplayVersion", config.version);
    if (config.publisher.len > 0) try setString(allocator, key, "Publisher", config.publisher);
    try setString(allocator, key, "InstallLocation", where.root);
    try setString(allocator, key, "DisplayIcon", launcher);
    try setString(allocator, key, "UninstallString", try std.fmt.allocPrint(allocator, "\"{s}\"", .{uninstaller}));
    try setString(allocator, key, "QuietUninstallString", try std.fmt.allocPrint(allocator, "\"{s}\" --silent", .{uninstaller}));
    try setDword(allocator, key, "NoModify", 1);
    try setDword(allocator, key, "NoRepair", 1);
    try setDword(allocator, key, "EstimatedSize", @intCast(@min(package_bytes / 1024, std.math.maxInt(u32))));
}

fn unregisterWindows(allocator: std.mem.Allocator, record: InstallRecord) !void {
    if (!windows) unreachable;
    const hive = if (std.mem.eql(u8, record.scope, "machine")) win.HKEY_LOCAL_MACHINE else win.HKEY_CURRENT_USER;
    const status = win.RegDeleteTreeW(hive, try uninstallKey(allocator, record.identity));
    if (status != 0 and status != 2) return error.RegistryWriteFailed;
}
