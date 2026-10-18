const std = @import("std");
const builtin = @import("builtin");
const system = @import("ziggurat_system");
const shell = system.shell;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
const words = [_][]const u8{ "", "two words", "中文🦎", "embedded\"quote", "tail\\", "\\\"", "$(literal);&|<>%^!", "line\nbreak" };
const Probe = struct {
    main_thread: std.Thread.Id,
    executable: []const u8,
    cwd: []const u8,
    output: []const u8,
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
        const after_children = try handles();
        if (after_children != baseline) std.debug.print("process handles: before={d}, after={d}\n", .{ baseline, after_children });
        try std.testing.expectEqual(baseline, after_children);
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
            try std.testing.expectEqual(native_handles, try handles());
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
            const count = try handles();
            if (failure_baseline) |expected| try std.testing.expectEqual(expected, count) else failure_baseline = count;
        }
        worker.deinit();
        try std.testing.expectError(error.Closed, worker.launchExecutable(std.heap.page_allocator, .{ .executable = self.executable }));
    }
};
const Affinity = struct {
    worker: *shell.Worker,
    child: *shell.Child,
    launch_error: ?anyerror = null,
    wait_error: ?anyerror = null,
    fn run(self: *Affinity) void {
        _ = self.worker.launchExecutable(std.heap.page_allocator, .{ .executable = "relative.exe" }) catch |err| {
            self.launch_error = err;
        };
        _ = self.child.wait() catch |err| {
            self.wait_error = err;
        };
    }
};
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
    var probe: Probe = .{ .main_thread = std.Thread.getCurrentId(), .executable = executable, .cwd = cwd, .output = output };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();
    if (probe.err) |err| return err;
    const result = try std.fs.cwd().readFileAlloc(memory, output, 32 * 1024);
    defer memory.free(result);
    try std.testing.expectEqualStrings(cwd, result);
    std.debug.print("shell smoke passed: exact Unicode argv/cwd, cancellation/failure, owned child termination/reap, resources stable; file icon={any}\n", .{shell.capabilities.file_icon});
}
