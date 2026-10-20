const std = @import("std");
const builtin = @import("builtin");
const system = @import("ziggurat_system");
const shell = system.shell;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
const fake = if (builtin.os.tag == .linux) struct {
    extern fn zsf_provider_present() c_int;
    extern fn zsf_start() c_int;
    extern fn zsf_stop() void;
    extern fn zsf_set_delay(milliseconds: c_int) void;
    extern fn zsf_calls(uri: [*]u8, capacity: c_uint, count: *c_uint) c_uint;
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
} else struct {};
const words = [_][]const u8{ "", "two words", "中文🦎", "embedded\"quote", "tail\\", "\\\"", "$(literal);&|<>%^!", "line\nbreak" };
const Probe = struct {
    main_thread: std.Thread.Id,
    executable: []const u8,
    cwd: []const u8,
    output: []const u8,
    /// Linux: private XDG data home whose Trash receives the trash test.
    data_home: []const u8,
    trash_note: []const u8 = "not run",
    reveal_note: []const u8 = "not run",
    err: ?anyerror = null,
    fn run(self: *Probe) void {
        self.checked() catch |err| {
            self.err = err;
        };
    }
    fn checked(self: *Probe) !void {
        var worker = try shell.Worker.init(self.main_thread);
        defer worker.deinit();
        var arguments: [words.len + 2][]const u8 = undefined;
        arguments[0] = "--helper";
        arguments[1] = self.output;
        @memcpy(arguments[2..], &words);
        var cancel: shell.Cancellation = .{};
        cancel.request();
        try std.testing.expectError(error.Cancelled, worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable, .arguments = &arguments, .cancellation = &cancel }));
        try std.testing.expectError(error.AbsolutePathRequired, worker.launchExecutable(std.heap.page_allocator, .{ .executable = "relative.exe" }));
        if (builtin.os.tag == .windows) try std.testing.expectError(error.ExecutableRequired, worker.launchExecutable(std.heap.page_allocator, .{ .executable = "C:\\tool.cmd" }));
        var child = try worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable, .arguments = &arguments, .cwd = self.cwd });
        errdefer _ = child.terminateAndWait() catch {};
        const term = try child.wait();
        try std.testing.expectEqual(shell.Term{ .Exited = 0 }, term);
        try std.testing.expectEqual(term, try child.wait());
        try std.testing.expectEqual(term, try child.terminateAndWait());
        var affinity: Affinity = .{ .worker = &worker, .child = &child };
        const other = try std.Thread.spawn(.{}, Affinity.run, .{&affinity});
        other.join();
        try std.testing.expectEqual(@as(?anyerror, error.WrongThread), affinity.launch_error);
        try std.testing.expectEqual(@as(?anyerror, error.WrongThread), affinity.wait_error);
        for (affinity.operation_errors) |err| try std.testing.expectEqual(@as(?anyerror, error.WrongThread), err);
        try self.operations(&worker, &cancel);
        if (builtin.os.tag == .windows) {
            var high_exit = try worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable, .arguments = &.{"--high-exit"} });
            errdefer _ = high_exit.terminateAndWait() catch {};
            try std.testing.expectEqual(shell.Term{ .Exited = 0x12345678 }, try high_exit.wait());
        }
        const baseline = try handles();
        for (0..12) |_| {
            var held = try worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable, .arguments = &.{"--hold"} });
            errdefer _ = held.terminateAndWait() catch {};
            const stopped = try held.terminateAndWait();
            try std.testing.expectEqual(if (builtin.os.tag == .windows) shell.Term{ .Exited = 1 } else shell.Term{ .Signal = std.posix.SIG.KILL }, stopped);
            try std.testing.expectEqual(stopped, try held.wait());
        }
        try expectHandles("process", baseline, 12);
        var pixels: [32 * 32 * 4]u8 = @splat(0x6b);
        if (builtin.os.tag == .windows) {
            try std.testing.expectError(error.ResultCapacityExceeded, worker.fileIcon(self.executable, .{}, pixels[0..4]));
            try std.testing.expectEqual(@as(u8, 0x6b), pixels[0]);
            try std.testing.expectError(error.Cancelled, worker.fileIcon(self.executable, .{ .cancellation = &cancel }, &pixels));
            for (0..2) |_| _ = try worker.fileIcon(self.executable, .{}, &pixels);
            const native_handles = try handles();
            const gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            for (0..12) |index| {
                const size: u16 = if (index % 2 == 0) 16 else 32;
                const icon = try worker.fileIcon(self.executable, .{ .size = size, .background = 0x204060 }, &pixels);
                try std.testing.expectEqual(@as(usize, size) * size * 4, icon.pixels.len);
                try std.testing.expectEqual(@as(usize, size) * 4, icon.stride);
                var differing = false;
                var at: usize = 0;
                while (at < icon.pixels.len) : (at += 4) {
                    try std.testing.expectEqual(@as(u8, 255), icon.pixels[at + 3]);
                    differing = differing or !std.mem.eql(u8, icon.pixels[at..][0..3], &.{ 0x20, 0x40, 0x60 });
                }
                try std.testing.expect(differing);
            }
            try expectHandles("icon", native_handles, 12);
            try std.testing.expectEqual(gdi, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        } else try std.testing.expectError(error.UnsupportedCapability, worker.fileIcon(self.executable, .{}, &pixels));
        const missing = try std.fs.path.join(std.heap.page_allocator, &.{ self.cwd, "missing.exe" });
        defer std.heap.page_allocator.free(missing);
        var failure_baseline: ?usize = null;
        for (0..13) |_| {
            var failed = false;
            if (worker.launchExecutable(std.heap.page_allocator, .{ .executable = missing })) |owned| {
                var unexpected = owned;
                _ = try unexpected.terminateAndWait();
            } else |_| failed = true;
            try std.testing.expect(failed);
            if (failure_baseline == null) failure_baseline = try handles();
        }
        try expectHandles("failed launch", failure_baseline.?, 12);
        worker.deinit();
        try std.testing.expectError(error.Closed, worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable }));
        try std.testing.expectError(error.Closed, worker.openUrl("https://example.invalid/", .{}));
        try std.testing.expectError(error.Closed, worker.trash(self.output, .{}));
    }
    /// Open/reveal/trash checks. No browser, user file or real file manager is
    /// reached: URL/path requests stop in validation, at a missing path or at an
    /// unhandled private scheme; reveal only targets this test's own provider.
    fn operations(self: *Probe, worker: *shell.Worker, cancel: *const shell.Cancellation) !void {
        const allocator = std.heap.page_allocator;
        const url_cases = [_]struct { []const u8, anyerror }{
            .{ "file:///etc/passwd", error.SchemeNotAllowed },
            .{ "javascript:alert(1)", error.SchemeNotAllowed },
            .{ "ftp://example.invalid/", error.SchemeNotAllowed },
            .{ "ms-settings:privacy", error.SchemeNotAllowed },
            .{ "C:\\Windows\\notepad.exe", error.InvalidUrl },
            .{ "relative/page.html", error.InvalidUrl },
            .{ "//example.invalid/", error.InvalidUrl },
            .{ "https:example.invalid", error.InvalidUrl },
            .{ "https://example.invalid/a b", error.InvalidUrl },
            .{ "https://example.invalid/\x00", error.EmbeddedNul },
            .{ "https://example.invalid/\xc3", error.InvalidUtf8 },
        };
        for (url_cases) |case| try std.testing.expectError(case[1], worker.openUrl(case[0], .{}));
        try std.testing.expectError(error.InvalidScheme, worker.openUrl("file:///etc/passwd", .{ .extra_schemes = &.{"file"} }));
        try std.testing.expectError(error.Cancelled, worker.openUrl("https://example.invalid/", .{ .cancellation = cancel }));
        try std.testing.expectEqual(@as(?shell.NativeFailure, null), worker.last_failure);
        const long = try allocator.alloc(u8, shell.max_url_bytes + 1);
        defer allocator.free(long);
        @memset(long, 'a');
        try std.testing.expectError(error.ArgumentTooLong, worker.openUrl(long, .{}));

        const existing = self.output; // written earlier by the helper child
        const missing = try std.fs.path.join(allocator, &.{ self.cwd, "missing 缺失.txt" });
        defer allocator.free(missing);
        const relative = "relative/file.txt";
        try std.testing.expectError(error.AbsolutePathRequired, worker.openPath(relative, .{}));
        try std.testing.expectError(error.AbsolutePathRequired, worker.reveal(relative, .{}));
        try std.testing.expectError(error.AbsolutePathRequired, worker.trash(relative, .{}));
        try std.testing.expectError(error.EmbeddedNul, worker.openPath("/a\x00b", .{}));
        try std.testing.expectError(error.EmbeddedNul, worker.trash("/a\x00b", .{}));
        try std.testing.expectError(error.InvalidUtf8, worker.reveal("/\xff", .{}));
        try std.testing.expectError(error.Cancelled, worker.openPath(existing, .{ .cancellation = cancel }));
        try std.testing.expectError(error.Cancelled, worker.reveal(existing, .{ .cancellation = cancel }));
        try std.testing.expectError(error.Cancelled, worker.trash(existing, .{ .cancellation = cancel }));
        try std.testing.expectError(error.InvalidTimeout, worker.reveal(existing, .{ .timeout_ms = 0 }));
        try std.testing.expectError(error.InvalidTimeout, worker.reveal(existing, .{ .timeout_ms = shell.max_reveal_timeout_ms + 1 }));
        try std.testing.expectError(error.FileNotFound, worker.openPath(missing, .{}));
        try std.testing.expectError(error.FileNotFound, worker.reveal(missing, .{}));
        try std.testing.expectError(error.FileNotFound, worker.trash(missing, .{}));
        const roots: []const []const u8 = if (builtin.os.tag == .windows) &.{ "C:\\", "C:/", "\\\\server\\share\\" } else &.{ "/", "//" };
        for (roots) |path| try std.testing.expectError(error.InvalidTrashPath, worker.trash(path, .{}));
        if (builtin.os.tag == .windows) {
            const wildcard = try std.fs.path.join(allocator, &.{ self.cwd, "*.txt" });
            defer allocator.free(wildcard);
            try std.testing.expectError(error.InvalidTrashPath, worker.trash(wildcard, .{}));
        }
        // Real trash, inside this test's directory. Linux sends it to the
        // private XDG data home configured by main, never the user's Trash.
        var baseline_handles: usize = 0;
        var trashed: usize = 0;
        for (0..12) |index| {
            const name = try std.fmt.allocPrint(allocator, "trash 回收 {d}.txt", .{index});
            defer allocator.free(name);
            const victim = try std.fs.path.join(allocator, &.{ self.cwd, name });
            defer allocator.free(victim);
            try std.fs.cwd().writeFile(.{ .sub_path = victim, .data = name });
            worker.trash(victim, .{}) catch |err| switch (err) {
                error.TrashUnsupported => {
                    self.trash_note = "unsupported here (distinct error asserted)";
                    try std.fs.deleteFileAbsolute(victim);
                    break;
                },
                else => return err,
            };
            try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(victim, .{}));
            if (builtin.os.tag == .linux) {
                const stored = try std.fs.path.join(allocator, &.{ self.data_home, "Trash", "files", name });
                defer allocator.free(stored);
                const contents = try std.fs.cwd().readFileAlloc(allocator, stored, 1024);
                defer allocator.free(contents);
                try std.testing.expectEqualStrings(name, contents);
                const info_name = try std.fmt.allocPrint(allocator, "{s}.trashinfo", .{name});
                defer allocator.free(info_name);
                const info = try std.fs.path.join(allocator, &.{ self.data_home, "Trash", "info", info_name });
                defer allocator.free(info);
                try std.fs.accessAbsolute(info, .{});
            }
            trashed += 1;
            // The first call may initialize process-wide system state.
            if (index == 0) baseline_handles = try handles();
        }
        if (trashed == 12) {
            self.trash_note = if (builtin.os.tag == .linux) "12 files moved into the private XDG Trash" else "12 files moved to the Recycle Bin";
            const after = try handles();
            if (after != baseline_handles) std.debug.print("trash handles: after first={d}, after 12={d}\n", .{ baseline_handles, after });
            // SHFileOperationW returns no handle to the caller, while the
            // shell's Recycle Bin code grows its own caches and thread pool by
            // a run-dependent amount. Only Linux asserts an exact count.
            if (builtin.os.tag != .windows) try std.testing.expectEqual(baseline_handles, after);
        }
        if (builtin.os.tag == .linux) {
            // An unhandled private scheme reaches GIO and fails without any
            // application: no handler exists for it.
            try std.testing.expectError(error.NoAssociation, worker.openUrl("ziggurat-unhandled-test:probe", .{ .extra_schemes = &.{"ziggurat-unhandled-test"} }));
            try std.testing.expect(worker.last_failure != null and worker.last_failure.?.domain == .gio);
            try self.revealProvider(worker, existing);
        }
    }
    fn revealProvider(self: *Probe, worker: *shell.Worker, existing: []const u8) !void {
        const address = std.posix.getenv("DBUS_SESSION_BUS_ADDRESS") orelse {
            self.reveal_note = "skipped: no DBUS_SESSION_BUS_ADDRESS";
            return;
        };
        if (address.len == 0) return;
        const present = fake.zsf_provider_present();
        if (present < 0) {
            self.reveal_note = "skipped: session bus unreachable";
            return;
        }
        if (present == 0) {
            try std.testing.expectError(error.FileManagerUnavailable, worker.reveal(existing, .{}));
            try std.testing.expect(worker.last_failure != null and worker.last_failure.?.domain == .dbus);
        }
        if (fake.zsf_start() != 0) {
            fake.zsf_stop();
            self.reveal_note = "skipped: FileManager1 owned by another provider";
            return;
        }
        defer fake.zsf_stop();
        var uri: [4096]u8 = undefined;
        var count: c_uint = 0;
        var baseline: usize = 0;
        for (0..13) |round| {
            try worker.reveal(existing, .{ .timeout_ms = 5000 });
            const calls = fake.zsf_calls(&uri, uri.len, &count);
            try std.testing.expectEqual(@as(c_uint, @intCast(round + 1)), calls);
            try std.testing.expectEqual(@as(c_uint, 1), count);
            const received = std.mem.sliceTo(&uri, 0);
            try std.testing.expect(std.mem.startsWith(u8, received, "file:///"));
            var decoded: [4096]u8 = undefined;
            @memcpy(decoded[0 .. received.len - 7], received[7..]);
            try std.testing.expectEqualStrings(existing, std.Uri.percentDecodeInPlace(decoded[0 .. received.len - 7]));
            // Each call closes its private bus connection: descriptors return
            // to the post-warm-up count.
            if (round == 0) baseline = try handles() else try std.testing.expectEqual(baseline, try handles());
        }
        fake.zsf_set_delay(1500);
        try std.testing.expectError(error.RevealTimedOut, worker.reveal(existing, .{ .timeout_ms = 200 }));
        fake.zsf_set_delay(0);
        self.reveal_note = if (present == 0) "absent provider error + 13 calls to the private provider + timeout" else "13 calls to the private provider + timeout";
    }
};
const Affinity = struct {
    worker: *shell.Worker,
    child: *shell.Child,
    launch_error: ?anyerror = null,
    wait_error: ?anyerror = null,
    operation_errors: [4]?anyerror = @splat(null),
    fn run(self: *Affinity) void {
        const path = if (builtin.os.tag == .windows) "C:\\missing" else "/missing";
        self.worker.openUrl("https://example.invalid/", .{}) catch |err| {
            self.operation_errors[0] = err;
        };
        self.worker.openPath(path, .{}) catch |err| {
            self.operation_errors[1] = err;
        };
        self.worker.reveal(path, .{}) catch |err| {
            self.operation_errors[2] = err;
        };
        self.worker.trash(path, .{}) catch |err| {
            self.operation_errors[3] = err;
        };
        _ = self.worker.launchExecutable(std.heap.page_allocator, .{ .executable = "relative.exe" }) catch |err| {
            self.launch_error = err;
        };
        _ = self.child.wait() catch |err| {
            self.wait_error = err;
        };
    }
};
/// Windows grows and shrinks process-owned handles on its own (shell pool
/// threads, loader and registry caches) by a run-dependent amount, so an
/// exact count is not stable there. A handle leaked per call still grows the
/// count by at least `calls`. Other systems keep the exact count.
fn expectHandles(label: []const u8, baseline: usize, calls: usize) !void {
    const count = try handles();
    if (count != baseline) std.debug.print("{s} handles: before={d}, after={d}\n", .{ label, baseline, count });
    if (builtin.os.tag != .windows) return std.testing.expectEqual(baseline, count);
    if (count >= baseline + calls) return error.HandleLeak;
}
fn handles() !usize {
    if (builtin.os.tag == .windows) {
        var count: c.DWORD = 0;
        if (c.GetProcessHandleCount(c.GetCurrentProcess(), &count) == 0) return error.HandleCountUnavailable;
        return count;
    }
    var directory = try std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next()) |_| count += 1;
    return count;
}
fn helper(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != words.len + 3) return error.ArgumentCountChanged;
    for (words, args[3..]) |word, arg| try std.testing.expectEqualStrings(word, arg);
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    var file = try std.fs.createFileAbsolute(args[2], .{});
    defer file.close();
    try file.writeAll(cwd);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const memory = allocator.allocator();
    const args = try std.process.argsAlloc(memory);
    defer std.process.argsFree(memory, args);
    if (builtin.os.tag == .windows and args.len > 1 and std.mem.eql(u8, args[1], "--high-exit")) c.ExitProcess(0x12345678);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--hold")) {
        var parked = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&parked, 0);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--helper")) return helper(memory, args);
    try std.testing.expectError(error.UiThreadForbidden, shell.Worker.init(std.Thread.getCurrentId()));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("cwd 空格");
    if (builtin.os.tag == .windows) try temporary.dir.writeFile(.{ .sub_path = "cwd 空格/missing.exe.cmd", .data = "@exit /b 77\r\n" });
    const cwd = try temporary.dir.realpathAlloc(memory, "cwd 空格");
    defer memory.free(cwd);
    const output = try std.fs.path.join(memory, &.{ cwd, "receipt.txt" });
    defer memory.free(output);
    const executable = try std.fs.selfExePathAlloc(memory);
    defer memory.free(executable);
    // Linux: a private HOME and XDG data home on the test directory's device,
    // set before the first GLib call, so trash goes to <temp>/data/Trash.
    try temporary.dir.makePath("home/data");
    const home = try temporary.dir.realpathAlloc(memory, "home");
    defer memory.free(home);
    const data_home = try std.fs.path.join(memory, &.{ home, "data" });
    defer memory.free(data_home);
    if (builtin.os.tag == .linux) {
        const home_z = try memory.dupeZ(u8, home);
        defer memory.free(home_z);
        const data_z = try memory.dupeZ(u8, data_home);
        defer memory.free(data_z);
        if (fake.setenv("HOME", home_z, 1) != 0 or fake.setenv("XDG_DATA_HOME", data_z, 1) != 0) return error.EnvironmentUnavailable;
    }
    var probe: Probe = .{ .main_thread = std.Thread.getCurrentId(), .executable = executable, .cwd = cwd, .output = output, .data_home = data_home };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    if (probe.err) |err| return err;
    const result = try std.fs.cwd().readFileAlloc(memory, output, 32 * 1024);
    defer memory.free(result);
    try std.testing.expectEqualStrings(cwd, result);
    std.debug.print("shell smoke passed: exact Unicode argv/cwd, cancellation/failure, owned child termination/reap, resources stable; file icon={any}; open/reveal/trash validation; trash: {s}; reveal: {s}\n", .{ shell.capabilities.file_icon, probe.trash_note, probe.reveal_note });
}
