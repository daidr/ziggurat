//! Real-process checks for single instance, handler registration, login
//! items, power assertions, taskbar state, identity and directories.
//! Linux D-Bus checks need a session bus whose address is also exported as
//! DBUS_SYSTEM_BUS_ADDRESS; pass --require-dbus to fail instead of skipping.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const probe = @import("os_integration_probe");
const instance = system.instance;
const integration = system.integration;
const win = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

const words = [_][]const u8{ "", "two words", "中文🦎", "embedded\"quote", "tail\\", "\\\"", "$(literal);&|<>%^!", "line\nbreak", "zigsmoke://open?x=1&y=%20" };
const handler_id = "org.zg.OsSmoke";
const allocator = std.heap.page_allocator;

pub const panic = std.debug.FullPanic(@import("macos_panic.zig").panic);
pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

pub fn main(init: std.process.Init.Minimal) !void {
    const arguments = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, arguments);
    if (arguments.len >= 3 and std.mem.eql(u8, arguments[1], "--secondary")) return secondary(arguments[2], arguments[3..]);
    if (arguments.len == 4 and std.mem.eql(u8, arguments[1], "--hold-primary")) return holdPrimary(arguments[2], arguments[3]);
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--expect-primary")) {
        const claim = try instance.claim(.{ .id = arguments[2] });
        switch (claim) {
            .primary => |value| {
                var primary = value;
                primary.deinit();
            },
            .secondary => |value| {
                var forwarder = value;
                forwarder.deinit();
                std.process.exit(5);
            },
        }
        return;
    }
    const require_dbus = arguments.len == 2 and std.mem.eql(u8, arguments[1], "--require-dbus");
    // Anything else was launched through a registered scheme or file type.
    if (arguments.len >= 2 and !require_dbus) return secondary(handler_id, arguments[1..]);

    const executable = try zio.executablePathAlloc(allocator);
    try directories();
    try singleInstance(executable);
    // Registration, login items, power and the dock belong to the app
    // bundle on macOS; smoke-macos-services covers what runs without one.
    if (comptime builtin.os.tag == .macos) {
        try longIdentity();
    } else {
        try registration(executable);
        try power(require_dbus);
        try taskbar(require_dbus);
    }
    std.debug.print("os integration smoke passed\n", .{});
}

fn secondary(id: []const u8, forwarded: []const []const u8) !void {
    var cwd_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try zio.getCwd(&cwd_storage);
    if (try instance.claimOrForward(.{ .id = id, .timeout_ms = 5000 }, .{ .cwd = cwd, .arguments = forwarded }, 8)) |value| {
        var primary = value;
        primary.deinit();
        std.process.exit(3);
    }
}
fn holdPrimary(id: []const u8, marker: []const u8) !void {
    const claim = try instance.claim(.{ .id = id });
    if (claim != .primary) std.process.exit(5);
    const file = try std.Io.Dir.createFileAbsolute(zio.io(), marker, .{});
    file.close(zio.io());
    while (true) zio.sleep(std.time.ns_per_s);
}

fn directories() !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    inline for (.{ .home, .config, .data, .cache, .state, .temp }) |kind| {
        const path = try system.identity.directory(kind, &buffer);
        if (!std.fs.path.isAbsolute(path)) return error.RelativeDirectory;
        std.debug.print("directory {s}={s}\n", .{ @tagName(kind), path });
    }
    const app = try system.identity.applicationDirectory(.config, handler_id, &buffer);
    if (!std.mem.endsWith(u8, app, handler_id)) return error.ApplicationDirectory;
    try std.testing.expectError(error.InvalidDirectory, system.identity.applicationDirectory(.documents, handler_id, &buffer));
}

const Collector = struct {
    primary: *instance.Primary,
    mutex: zio.Mutex = .{},
    changed: zio.Condition = .{},
    messages: std.ArrayList([]const []const u8) = .empty,
    cwds: std.ArrayList([]const u8) = .empty,
    rejections: [zio.fields(instance.Rejection).len]usize = @splat(0),
    stopped: bool = false,
    failure: ?anyerror = null,

    fn run(self: *Collector) void {
        var storage: [instance.receive_storage_bytes]u8 = undefined;
        var slots: [instance.max_arguments][]const u8 = undefined;
        while (true) {
            const received = self.primary.receive(&storage, &slots) catch |err| {
                self.finish(err);
                return;
            };
            self.mutex.lock();
            defer self.mutex.unlock();
            defer self.changed.broadcast();
            switch (received) {
                .stopped => {
                    self.stopped = true;
                    return;
                },
                .rejected => |reason| self.rejections[@backingInt(reason)] += 1,
                .message => |message| {
                    const copy = allocator.alloc([]const u8, message.arguments.len) catch unreachable;
                    for (message.arguments, copy) |argument, *slot| slot.* = allocator.dupe(u8, argument) catch unreachable;
                    self.messages.append(allocator, copy) catch unreachable;
                    self.cwds.append(allocator, allocator.dupe(u8, message.cwd) catch unreachable) catch unreachable;
                },
            }
        }
    }
    fn finish(self: *Collector, err: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failure = err;
        self.stopped = true;
        self.changed.broadcast();
    }
    fn waitMessages(self: *Collector, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = zio.milliTimestamp() + 20_000;
        while (self.messages.items.len < count) {
            if (self.failure) |err| return err;
            const left = deadline - zio.milliTimestamp();
            if (left <= 0) return error.MessageTimeout;
            self.changed.timedWait(&self.mutex, @as(u64, @intCast(left)) * std.time.ns_per_ms) catch {};
        }
    }
    fn waitRejection(self: *Collector, reason: instance.Rejection, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const deadline = zio.milliTimestamp() + 20_000;
        while (self.rejections[@backingInt(reason)] < count) {
            const left = deadline - zio.milliTimestamp();
            if (left <= 0) return error.RejectionTimeout;
            self.changed.timedWait(&self.mutex, @as(u64, @intCast(left)) * std.time.ns_per_ms) catch {};
        }
    }
};

fn spawn(argv: []const []const u8, cwd: ?[]const u8) !std.process.Child {
    const child = try zio.spawn(.{ .argv = argv, .cwd = zio.cwd(cwd), .stdin = .ignore });
    return child;
}
fn expectExit(child: *std.process.Child, code: u8) !void {
    const term = try child.wait(zio.io());
    if (term != .exited or term.exited != code) {
        std.debug.print("child term {any}, expected exit {d}\n", .{ term, code });
        return error.UnexpectedChildExit;
    }
}

fn resourceCount() !usize {
    if (builtin.os.tag == .windows) {
        var count: win.DWORD = 0;
        if (win.GetProcessHandleCount(win.GetCurrentProcess(), &count) == 0) return error.HandleCount;
        return count;
    }
    var directory = try std.Io.Dir.openDirAbsolute(zio.io(), if (builtin.os.tag == .macos) "/dev/fd" else "/proc/self/fd", .{ .iterate = true });
    defer directory.close(zio.io());
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(zio.io())) |_| count += 1;
    return count;
}

fn processId() u32 {
    return if (builtin.os.tag == .windows) win.GetCurrentProcessId() else if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else @intCast(std.os.linux.getpid());
}
fn uniqueId(buffer: []u8, label: []const u8) ![]const u8 {
    const pid = processId();
    return std.fmt.bufPrint(buffer, "org.zg.smoke.{s}.{d}", .{ label, pid });
}

fn singleInstance(executable: []const u8) !void {
    var id_storage: [64]u8 = undefined;
    const id = try uniqueId(&id_storage, "instance");
    var claim = try instance.claim(.{ .id = id, .timeout_ms = 1000 });
    if (claim != .primary) return error.ExpectedPrimary;
    var primary = &claim.primary;
    var second = try instance.claim(.{ .id = id });
    if (second != .secondary) return error.ExpectedSecondary;
    second.secondary.deinit();

    var collector: Collector = .{ .primary = primary };
    const worker = try std.Thread.spawn(.{}, Collector.run, .{&collector});
    var cwd_storage: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try zio.realpath(std.Io.Dir.cwd(), if (builtin.os.tag == .windows) "C:\\Windows" else "/", &cwd_storage);

    // Eight concurrent second processes, each forwarding the full word list.
    var argv: [3 + words.len][]const u8 = undefined;
    argv[0] = executable;
    argv[1] = "--secondary";
    argv[2] = id;
    @memcpy(argv[3..], &words);
    var children: [8]std.process.Child = undefined;
    for (&children) |*child| child.* = try spawn(&argv, cwd);
    for (&children) |*child| try expectExit(child, 0);
    try collector.waitMessages(children.len);
    for (collector.messages.items, collector.cwds.items) |message, message_cwd| {
        try std.testing.expectEqualStrings(cwd, message_cwd);
        try std.testing.expectEqual(words.len, message.len);
        for (words, message) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }
    // Maximum-size arguments. A Windows command line holds at most 32767
    // UTF-16 units, so only one maximum argument reaches the child there.
    const long = try allocator.alloc(u8, instance.max_argument_bytes);
    @memset(long, 'x');
    long[0] = 'L';
    const long_argv = [_][]const u8{ executable, "--secondary", id, long, long, long };
    var long_child = try spawn(long_argv[0..if (builtin.os.tag == .windows) 4 else 6], null);
    try expectExit(&long_child, 0);
    try collector.waitMessages(children.len + 1);
    const long_message = collector.messages.items[children.len];
    try std.testing.expectEqual(@as(usize, if (builtin.os.tag == .windows) 1 else 3), long_message.len);
    for (long_message) |argument| try std.testing.expectEqualStrings(long, argument);

    // Hostile peers: malformed, oversized and stalled exchanges are refused
    // and the listener keeps serving.
    var raw_header: [instance.header_bytes]u8 = @splat(0);
    @memcpy(raw_header[0..4], "BAD!");
    try rawPeer(id, &raw_header, error.Rejected);
    try collector.waitRejection(.malformed, 1);
    @memcpy(raw_header[0..4], &[4]u8{ 'Z', 'G', 'I', 1 });
    std.mem.writeInt(u32, raw_header[4..8], instance.max_payload_bytes + 1, .little);
    std.mem.writeInt(u32, raw_header[8..12], 1, .little);
    try rawPeer(id, &raw_header, error.Rejected);
    try collector.waitRejection(.too_large, 1);
    try rawPeer(id, raw_header[0..6], error.PrimaryUnavailable);
    try collector.waitRejection(.timeout, 1);
    var after = try spawn(&.{ executable, "--secondary", id, "after-rejections" }, null);
    try expectExit(&after, 0);
    try collector.waitMessages(children.len + 2);

    var expect_secondary = try spawn(&.{ executable, "--expect-primary", id }, null);
    try expectExit(&expect_secondary, 5);
    var stale = try instance.claim(.{ .id = id });
    if (stale != .secondary) return error.ExpectedSecondary;
    defer stale.secondary.deinit();
    primary.requestStop();
    worker.join();
    if (collector.failure) |err| return err;
    if (!collector.stopped) return error.NotStopped;
    primary.deinit();
    // A secondary that saw the old primary must be told to claim again.
    try std.testing.expectError(error.PrimaryUnavailable, stale.secondary.forward(.{ .cwd = cwd }));
    var expect_primary = try spawn(&.{ executable, "--expect-primary", id }, null);
    try expectExit(&expect_primary, 0);

    // A primary that dies without cleanup releases the lock.
    var marker_storage: [std.fs.max_path_bytes]u8 = undefined;
    var temp_storage: [std.fs.max_path_bytes]u8 = undefined;
    const temp = try system.identity.directory(.temp, &temp_storage);
    const marker = try std.fmt.bufPrint(&marker_storage, "{s}{c}{s}.ready", .{ temp, std.fs.path.sep, id });
    std.Io.Dir.deleteFileAbsolute(zio.io(), marker) catch {};
    var holder = try spawn(&.{ executable, "--hold-primary", id, marker }, null);
    const deadline = zio.milliTimestamp() + 20_000;
    while (true) {
        if (std.Io.Dir.accessAbsolute(zio.io(), marker, .{})) |_| break else |_| {}
        if (zio.milliTimestamp() > deadline) return error.HolderTimeout;
        zio.sleep(10 * std.time.ns_per_ms);
    }
    std.Io.Dir.deleteFileAbsolute(zio.io(), marker) catch {};
    var blocked = try instance.claim(.{ .id = id });
    if (blocked != .secondary) return error.ExpectedSecondary;
    blocked.secondary.deinit();
    holder.kill(zio.io());
    var recovered = try instance.claim(.{ .id = id });
    if (recovered != .primary) return error.ExpectedPrimary;
    recovered.primary.deinit();

    // Stop before any peer, and repeated cycles without resource growth.
    const baseline = try resourceCount();
    for (0..12) |_| {
        var cycle = try instance.claim(.{ .id = id });
        if (cycle != .primary) return error.ExpectedPrimary;
        var idle: Collector = .{ .primary = &cycle.primary };
        const idle_worker = try std.Thread.spawn(.{}, Collector.run, .{&idle});
        var peer = try instance.claim(.{ .id = id });
        try peer.secondary.forward(.{ .cwd = cwd, .arguments = &.{"cycle"} });
        peer.secondary.deinit();
        try idle.waitMessages(1);
        cycle.primary.requestStop();
        idle_worker.join();
        cycle.primary.deinit();
    }
    const final = try resourceCount();
    std.debug.print("instance resources before={d} after={d}\n", .{ baseline, final });
    if (final != baseline) return error.ResourceGrowth;
    if (builtin.os.tag == .linux) try unsafeRuntimeDirectory(id);
    std.debug.print("single instance: {d} forwarded messages, rejections malformed={d} too_large={d} timeout={d}\n", .{ collector.messages.items.len, collector.rejections[0], collector.rejections[1], collector.rejections[2] });
}
/// macOS socket paths hold 103 bytes: an ID of the maximum length still
/// claims and forwards.
fn longIdentity() !void {
    var id_storage: [200]u8 = undefined;
    const prefix = try uniqueId(&id_storage, "long");
    var id_buffer: [200]u8 = undefined;
    const filler: [64]u8 = @splat('a');
    const full = try std.fmt.bufPrint(&id_buffer, "{s}.{s}", .{ prefix, &filler });
    const id = full[0..system.identity.max_id_bytes];
    var claim = try instance.claim(.{ .id = id });
    if (claim != .primary) return error.ExpectedPrimary;
    var collector: Collector = .{ .primary = &claim.primary };
    const worker = try std.Thread.spawn(.{}, Collector.run, .{&collector});
    var peer = try instance.claim(.{ .id = id });
    if (peer != .secondary) return error.ExpectedSecondary;
    try peer.secondary.forward(.{ .cwd = "/", .arguments = &.{"long"} });
    peer.secondary.deinit();
    try collector.waitMessages(1);
    claim.primary.requestStop();
    worker.join();
    claim.primary.deinit();
}
fn rawPeer(id: []const u8, bytes: []const u8, expected: anyerror) !void {
    var claim = try instance.claim(.{ .id = id, .timeout_ms = 5000 });
    if (claim != .secondary) return error.ExpectedSecondary;
    defer claim.secondary.deinit();
    try std.testing.expectError(expected, instance.testing.sendRaw(&claim.secondary, bytes));
}
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
fn unsafeRuntimeDirectory(id: []const u8) !void {
    const original = zio.getenv("XDG_RUNTIME_DIR") orelse return;
    var saved: [std.fs.max_path_bytes:0]u8 = undefined;
    const restore = try std.fmt.bufPrintSentinel(&saved, "{s}", .{original}, 0);
    const open_directory = "/tmp/ziggurat-open-runtime";
    zio.posix.mkdir(open_directory, 0o755) catch |err| if (err != error.PathAlreadyExists) return err;
    defer std.Io.Dir.deleteDirAbsolute(zio.io(), open_directory) catch {};
    {
        const fd = try zio.posix.open(open_directory, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
        defer zio.posix.close(fd);
        try zio.posix.fchmod(fd, 0o755);
    }
    _ = setenv("XDG_RUNTIME_DIR", open_directory, 1);
    defer _ = setenv("XDG_RUNTIME_DIR", restore, 1);
    try std.testing.expectError(error.RuntimeDirectoryUnsafe, instance.claim(.{ .id = id }));
}

fn registration(executable_arg: []const u8) !void {
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try zio.realpath(std.Io.Dir.cwd(), executable_arg, &executable_storage);
    var scheme_storage: [32]u8 = undefined;
    const pid = processId();
    const scheme = try std.fmt.bufPrint(&scheme_storage, "zigsmoke{d}", .{pid % 100000});
    var extension_storage: [16]u8 = undefined;
    const extension = try std.fmt.bufPrint(&extension_storage, ".zgs{d}", .{pid % 1000});
    var mime_storage: [64]u8 = undefined;
    const mime = try std.fmt.bufPrint(&mime_storage, "application/x-zgsmoke-{d}", .{pid % 1000});
    const application: integration.Application = .{
        .id = handler_id,
        .name = "Ziggurat OS smoke",
        .executable = executable,
        .url_schemes = &.{scheme},
        .file_types = &.{.{ .extension = extension, .mime_type = mime, .description = "Ziggurat smoke document" }},
    };
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_storage, "{s}{c}.zig-cache{c}tmp{c}os-integration-{d}", .{ try zio.getCwd(&cwd_storage), std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, pid });
    try std.Io.Dir.cwd().createDirPath(zio.io(), root);
    defer std.Io.Dir.cwd().deleteTree(zio.io(), root) catch {};
    if (builtin.os.tag == .linux) {
        // GIO and this module read the same XDG roots; set them before any GIO use.
        var data: [std.fs.max_path_bytes:0]u8 = undefined;
        var config: [std.fs.max_path_bytes:0]u8 = undefined;
        _ = probe.probe_setenv("XDG_DATA_HOME", try std.fmt.bufPrintSentinel(&data, "{s}/data", .{root}, 0));
        _ = probe.probe_setenv("XDG_CONFIG_HOME", try std.fmt.bufPrintSentinel(&config, "{s}/config", .{root}, 0));
    }
    // An unrelated user association survives registration and removal.
    if (builtin.os.tag == .linux) {
        try std.Io.Dir.cwd().createDirPath(zio.io(), try std.fmt.bufPrint(&cwd_storage, "{s}/config", .{root}));
        const list = try std.Io.Dir.createFileAbsolute(zio.io(), try std.fmt.bufPrint(&cwd_storage, "{s}/config/mimeapps.list", .{root}), .{});
        try list.writeStreamingAll(zio.io(), "[Default Applications]\ntext/x-unrelated=other.desktop;\n");
        list.close(zio.io());
    }
    const report = try integration.register(allocator, application, .{});
    std.debug.print("registration report {any}\n", .{report});
    var collector_claim = try instance.claim(.{ .id = handler_id });
    if (collector_claim != .primary) return error.ExpectedPrimary;
    var collector: Collector = .{ .primary = &collector_claim.primary };
    const worker = try std.Thread.spawn(.{}, Collector.run, .{&collector});
    var uri_storage: [128:0]u8 = undefined;
    const uri = try std.fmt.bufPrintSentinel(&uri_storage, "{s}://open/%E4%B8%AD?x=1", .{scheme}, 0);
    var document_storage: [std.fs.max_path_bytes:0]u8 = undefined;
    const document = try std.fmt.bufPrintSentinel(&document_storage, "{s}{c}a document{s}", .{ root, std.fs.path.sep, extension }, 0);
    {
        // Empty files are typed by size alone; give the glob something to name.
        const file = try std.Io.Dir.createFileAbsolute(zio.io(), document, .{});
        defer file.close(zio.io());
        try file.writeStreamingAll(zio.io(), "Ziggurat smoke document\n");
    }

    if (builtin.os.tag == .linux) {
        var answer: [256]u8 = undefined;
        var scheme_z: [40:0]u8 = undefined;
        var mime_z: [64:0]u8 = undefined;
        if (probe.probe_default_for_scheme(try std.fmt.bufPrintSentinel(&scheme_z, "{s}", .{scheme}, 0), &answer, answer.len) != 0) return error.SchemeNotResolved;
        try std.testing.expectEqualStrings(handler_id ++ ".desktop", std.mem.sliceTo(&answer, 0));
        if (probe.probe_default_for_type(try std.fmt.bufPrintSentinel(&mime_z, "{s}", .{mime}, 0), &answer, answer.len) != 0) return error.TypeNotResolved;
        try std.testing.expectEqualStrings(handler_id ++ ".desktop", std.mem.sliceTo(&answer, 0));
        if (report.mime_database_refreshed) {
            if (probe.probe_guess(document, &answer, answer.len) != 0) return error.GlobNotResolved;
            try std.testing.expectEqualStrings(mime, std.mem.sliceTo(&answer, 0));
        } else std.debug.print("update-mime-database unavailable: extension glob not checked\n", .{});
        if (probe.probe_launch_uri(uri) != 0) return error.LaunchFailed;
        try collector.waitMessages(1);
        if (report.mime_database_refreshed) {
            var file_uri: [std.fs.max_path_bytes:0]u8 = undefined;
            var used: usize = 0;
            for ("file://") |byte| {
                file_uri[used] = byte;
                used += 1;
            }
            for (document) |byte| {
                if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null) {
                    file_uri[used] = byte;
                    used += 1;
                } else {
                    _ = try std.fmt.bufPrint(file_uri[used..][0..3], "%{X:0>2}", .{byte});
                    used += 3;
                }
            }
            file_uri[used] = 0;
            if (probe.probe_launch_uri(file_uri[0..used :0]) != 0) return error.LaunchFailed;
        }
    } else {
        try windowsAssociation(scheme, executable);
        try windowsAssociation(extension, executable);
        try shellOpen(uri);
        try collector.waitMessages(1);
        try shellOpen(document);
    }
    std.debug.print("forwarded handler arguments: {s}\n", .{collector.messages.items[0][0]});
    try std.testing.expectEqualStrings(uri, collector.messages.items[0][0]);
    if (builtin.os.tag == .windows or report.mime_database_refreshed) {
        try collector.waitMessages(2);
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const forwarded = collector.messages.items[1][0];
        std.debug.print("forwarded document argument: {s}\n", .{forwarded});
        const local = (try integration.localPath(forwarded, &path)) orelse forwarded;
        try std.testing.expectEqualStrings(document, local);
    }
    collector_claim.primary.requestStop();
    worker.join();
    collector_claim.primary.deinit();

    _ = try integration.unregister(allocator, application, .{});
    if (builtin.os.tag == .linux) {
        var answer: [256]u8 = undefined;
        var scheme_z: [40:0]u8 = undefined;
        if (probe.probe_default_for_scheme(try std.fmt.bufPrintSentinel(&scheme_z, "{s}", .{scheme}, 0), &answer, answer.len) == 0) return error.SchemeStillRegistered;
        const list = try std.Io.Dir.cwd().readFileAlloc(zio.io(), try std.fmt.bufPrint(&cwd_storage, "{s}/config/mimeapps.list", .{root}), allocator, .limited(1 << 20));
        if (std.mem.indexOf(u8, list, handler_id) != null or std.mem.indexOf(u8, list, "text/x-unrelated=other.desktop;") == null) return error.MimeAppsNotRestored;
    } else {
        try std.testing.expectError(error.AssociationMissing, windowsAssociation(scheme, executable));
    }

    const item: integration.LoginItem = .{ .id = handler_id, .name = "Ziggurat OS smoke", .executable = executable, .arguments = &.{ "--background", "two words" } };
    try integration.setLoginItem(item, .{});
    if (!try integration.loginItemRegistered(handler_id, .{})) return error.LoginItemMissing;
    try integration.removeLoginItem(handler_id, .{});
    if (try integration.loginItemRegistered(handler_id, .{})) return error.LoginItemRemains;
    try integration.removeLoginItem(handler_id, .{});
    std.debug.print("registration: scheme, file type and login item verified\n", .{});
}

fn windowsAssociation(name: []const u8, executable: []const u8) !void {
    if (comptime builtin.os.tag != .windows) unreachable;
    var wide_name: [64]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide_name, name);
    wide_name[length] = 0;
    var out: [win.MAX_PATH * 2]u16 = undefined;
    var size: win.DWORD = out.len;
    if (win.AssocQueryStringW(0, win.ASSOCSTR_EXECUTABLE, @ptrCast(&wide_name), null, &out, &size) < 0) return error.AssociationMissing;
    var utf8: [win.MAX_PATH * 6]u8 = undefined;
    const resolved = utf8[0..try std.unicode.utf16LeToUtf8(&utf8, out[0 .. size - 1])];
    if (!std.ascii.eqlIgnoreCase(resolved, executable)) {
        std.debug.print("association {s} -> {s}\n", .{ name, resolved });
        return error.AssociationMismatch;
    }
}
fn shellOpen(target: []const u8) !void {
    if (comptime builtin.os.tag != .windows) unreachable;
    var wide_target: [std.fs.max_path_bytes]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide_target, target);
    wide_target[length] = 0;
    var info = std.mem.zeroes(win.SHELLEXECUTEINFOW);
    info.cbSize = @sizeOf(win.SHELLEXECUTEINFOW);
    info.fMask = win.SEE_MASK_NOCLOSEPROCESS | win.SEE_MASK_FLAG_NO_UI;
    info.lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    info.lpFile = @ptrCast(&wide_target);
    info.nShow = win.SW_HIDE;
    if (win.ShellExecuteExW(&info) == 0) return error.ShellOpenFailed;
    if (info.hProcess) |process| {
        _ = win.WaitForSingleObject(process, 20_000);
        _ = win.CloseHandle(process);
    }
}

fn power(require_dbus: bool) !void {
    if (builtin.os.tag == .windows) {
        const baseline = try resourceCount();
        for (0..12) |_| {
            var held = try system.power.Assertion.acquire(.{ .reason = "Ziggurat smoke export" });
            var display = try system.power.Assertion.acquire(.{ .kind = .display, .reason = "Ziggurat smoke playback" });
            display.release();
            held.release();
            held.release();
        }
        if (try resourceCount() != baseline) return error.ResourceGrowth;
        std.debug.print("power: 12 paired system/display requests\n", .{});
        return;
    }
    if (zio.getenv("DBUS_SYSTEM_BUS_ADDRESS") == null) {
        if (require_dbus) return error.SystemBusRequired;
        std.debug.print("power: skipped, no private system bus\n", .{});
        return;
    }
    try std.testing.expectError(error.ServiceUnavailable, system.power.Assertion.acquire(.{ .reason = "before service", .timeout_ms = 2000 }));
    if (probe.probe_start(1) != 0) return error.ProbeUnavailable;
    defer probe.probe_stop();
    var what: [256]u8 = undefined;
    var who: [256]u8 = undefined;
    var why: [256]u8 = undefined;
    var mode: [256]u8 = undefined;
    for (0..12) |round| {
        const kind: system.power.Kind = if (round % 2 == 0) .system else .display;
        var held = try system.power.Assertion.acquire(.{ .kind = kind, .reason = "Ziggurat smoke export", .application = "Ziggurat smoke", .timeout_ms = 2000 });
        if (probe.probe_logind_wait(@intCast(round + 1), 2000, &what, &who, &why, &mode) != 0) return error.InhibitNotSeen;
        try std.testing.expectEqualStrings(if (kind == .system) "sleep" else "sleep:idle", std.mem.sliceTo(&what, 0));
        try std.testing.expectEqualStrings("Ziggurat smoke", std.mem.sliceTo(&who, 0));
        try std.testing.expectEqualStrings("Ziggurat smoke export", std.mem.sliceTo(&why, 0));
        try std.testing.expectEqualStrings("block", std.mem.sliceTo(&mode, 0));
        if (probe.probe_logind_released(0) == 0) return error.ReleasedEarly;
        held.release();
        held.release();
        if (probe.probe_logind_released(2000) != 0) return error.InhibitorLeaked;
    }
    std.debug.print("power: 12 logind inhibitors acquired and released\n", .{});
}

extern "glib-2.0" fn g_get_prgname() ?[*:0]const u8;
fn taskbar(require_dbus: bool) !void {
    // The identity must be in place before the toolkit starts.
    try system.identity.setProcessIdentity(handler_id);
    if (builtin.os.tag == .linux) try std.testing.expectEqualStrings(handler_id, std.mem.sliceTo(g_get_prgname().?, 0));
    try std.testing.expectError(error.InvalidIdentity, system.identity.setProcessIdentity("bad id"));
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .title = "OS integration smoke" });
    if (builtin.os.tag == .windows) {
        var bar = try system.taskbar.Taskbar.init(handler_id);
        defer bar.deinit();
        // A hidden window has no taskbar button; the shell may refuse it.
        const result = bar.setProgress(window, .{ .normal = 0.5 });
        std.debug.print("taskbar hidden-window progress: {any}\n", .{result});
        if (result) |_| {} else |err| if (err != error.TaskbarUnavailable) return err;
        try std.testing.expectError(error.InvalidProgress, bar.setProgress(window, .{ .normal = 1.5 }));
        try std.testing.expectError(error.UnsupportedCapability, bar.setBadgeCount(window, 3));
        _ = try window.destroy();
        try std.testing.expectError(error.Closed, bar.setProgress(window, .none));
        return;
    }
    if (zio.getenv("DBUS_SESSION_BUS_ADDRESS") == null) {
        if (require_dbus) return error.SessionBusRequired;
        std.debug.print("taskbar: skipped, no session bus\n", .{});
        return;
    }
    if (probe.probe_start(0) != 0) return error.ProbeUnavailable;
    defer probe.probe_stop();
    var bar = try system.taskbar.Taskbar.init(handler_id);
    defer bar.deinit();
    var uri: [256]u8 = undefined;
    var progress: f64 = 0;
    var progress_visible: c_int = 0;
    var count: c_longlong = 0;
    var count_visible: c_int = 0;
    var urgent: c_int = 0;
    try bar.setProgress(window, .{ .normal = 0.25 });
    if (probe.probe_launcher_wait(1, 5000, &uri, &progress, &progress_visible, &count, &count_visible, &urgent) != 0) return error.LauncherNotSeen;
    try std.testing.expectEqualStrings("application://" ++ handler_id ++ ".desktop", std.mem.sliceTo(&uri, 0));
    try std.testing.expect(progress_visible == 1 and @abs(progress - 0.25) < 1e-6 and count_visible == 0);
    try bar.setBadgeCount(window, 7);
    try bar.setAttention(window, true);
    if (probe.probe_launcher_wait(3, 5000, &uri, &progress, &progress_visible, &count, &count_visible, &urgent) != 0) return error.LauncherNotSeen;
    try std.testing.expect(progress_visible == 1 and count_visible == 1 and count == 7 and urgent == 1);
    try bar.setProgress(window, .none);
    try bar.setBadgeCount(window, null);
    if (probe.probe_launcher_wait(5, 5000, &uri, &progress, &progress_visible, &count, &count_visible, &urgent) != 0) return error.LauncherNotSeen;
    try std.testing.expect(progress_visible == 0 and count_visible == 0);
    try std.testing.expectError(error.InvalidProgress, bar.setProgress(window, .{ .paused = std.math.nan(f32) }));
    try std.testing.expectError(error.UnsupportedCapability, bar.setOverlay(window, null, ""));
    std.debug.print("taskbar: launcher entry progress, count and attention observed\n", .{});
}
