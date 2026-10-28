//! Real-session check of relaunch, recent documents and the jump list. The
//! parent quits a hidden-window App through Relaunch and starts itself again;
//! the relaunched child records a document with the system (Linux: in a
//! private XDG data home, then reads the list back), sets and removes a
//! Windows jump list, and writes a marker the parent waits for.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Probe = struct {
    app: *z.App,
    relaunch: *system.relaunch.Relaunch,
    result: ?z.App.QuitResult = null,
    fn call(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.result = self.relaunch.request(self.app);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var allocator_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator_state.deinit() == .ok);
    const allocator = allocator_state.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    defer zio.argsFree(allocator, args);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--relaunched")) return relaunched(allocator, args[2]);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--echo")) return echo(allocator, args[2], args[3..]);
    if (args.len != 1) return error.InvalidArgument;

    var name: [64]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&name, ".zig-cache/tmp/system-session-{x}", .{zio.random.int(u64)});
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(zio.io(), sub_path, .{});
    defer {
        dir.close(zio.io());
        cwd.deleteTree(zio.io(), sub_path) catch {};
    }
    const root = try zio.realPathAlloc(dir, ".", allocator);
    defer allocator.free(root);
    const marker = try std.fs.path.join(allocator, &.{ root, "relaunched" });
    defer allocator.free(marker);

    var relaunch: system.relaunch.Relaunch = .{};
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        _ = try app.createWindow(.{ .title = "Relaunch" });
        var probe: Probe = .{ .app = app, .relaunch = &relaunch };
        try app.post(.{ .context = &probe, .call = Probe.call });
        try app.run();
        try std.testing.expectEqual(z.App.QuitResult.accepted, probe.result.?);
    }
    try std.testing.expect(try relaunch.finish(allocator, .{ .arguments = &.{ "--relaunched", root } }));
    try std.testing.expect(!try relaunch.finish(allocator, .{}));

    var timer = try zio.Timer.start();
    while (true) {
        if (dir.readFileAlloc(zio.io(), "relaunched", allocator, .limited(4096))) |data| {
            defer allocator.free(data);
            if (std.mem.endsWith(u8, data, "\n")) {
                std.debug.print("system session passed: relaunch; {s}", .{data});
                return;
            }
        } else |err| if (err != error.FileNotFound) return err;
        if (timer.read() > 20 * std.time.ns_per_s) return error.RelaunchTimeout;
        zio.sleep(50 * std.time.ns_per_ms);
    }
}

fn relaunched(allocator: std.mem.Allocator, root: []const u8) !void {
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    const document = try std.fs.path.join(allocator, &.{ root, "notes.txt" });
    defer allocator.free(document);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = document, .data = "hello" });

    if (builtin.os.tag == .linux) {
        const data_home = try std.fs.path.joinZ(allocator, &.{ root, "data" });
        defer allocator.free(data_home);
        // Before any GLib call, which caches the user data directory.
        if (setenv("XDG_DATA_HOME", data_home.ptr, 1) != 0) return error.SetEnvFailed;
        try system.recent.addToSystem(allocator, document, "Ziggurat Session Smoke");
        try system.recent.addToSystem(allocator, document, "Ziggurat Session Smoke");
        const list_path = try std.fs.path.join(allocator, &.{ data_home, "recently-used.xbel" });
        defer allocator.free(list_path);
        const list = try std.Io.Dir.cwd().readFileAlloc(zio.io(), list_path, allocator, .limited(1024 * 1024));
        defer allocator.free(list);
        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{document});
        defer allocator.free(uri);
        if (std.mem.count(u8, list, uri) != 1) return error.RecentEntryMissing;
        if (std.mem.indexOf(u8, list, "Ziggurat Session Smoke") == null) return error.RecentApplicationMissing;
        try report.writer.writeAll("recent: one entry in the user's recently used files");
    } else if (builtin.os.tag == .windows) {
        try system.recent.addToSystem(allocator, document, "Ziggurat Session Smoke");
        try system.jump_list.setTasks(allocator, &.{
            .{ .title = "New note", .description = "Open a new note", .arguments = &.{ "--new", "a \"quoted\" value" } },
            .{ .title = "Notepad", .path = "C:\\Windows\\System32\\notepad.exe", .icon_path = "C:\\Windows\\System32\\notepad.exe" },
        }, .{ .recent = true });
        try system.jump_list.setTasks(allocator, &.{}, .{});
        try argumentRoundTrips(allocator, root);
        try report.writer.writeAll("recent: shell accepted; jump list: set with two tasks and Recent, then removed; task argv round-trips through a real process");
    } else return error.UnsupportedCapability;
    try std.testing.expectError(error.MissingTitle, system.jump_list.setTasks(allocator, &.{.{ .title = "" }}, .{}));

    try report.writer.writeByte('\n');
    var marker_dir = try std.Io.Dir.cwd().openDir(zio.io(), root, .{});
    defer marker_dir.close(zio.io());
    // Written whole, then renamed, so the parent never reads half of it.
    try marker_dir.writeFile(zio.io(), .{ .sub_path = "relaunched.tmp", .data = report.written() });
    try marker_dir.rename("relaunched.tmp", marker_dir, "relaunched", zio.io());
}

/// Writes its arguments, one per line, for the argv round trip.
fn echo(allocator: std.mem.Allocator, path: []const u8, arguments: []const []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(arguments, .{}, &out.writer);
    try std.Io.Dir.cwd().writeFile(zio.io(), .{ .sub_path = path, .data = out.written() });
}

/// Starts this program with a jump list task's argument line, as the shell
/// does, and checks the child sees exactly the task's arguments.
fn argumentRoundTrips(allocator: std.mem.Allocator, root: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    const cases = [_][]const []const u8{
        &.{},
        &.{""},
        &.{ "plain", "two words", "" },
        &.{ "quote\"inside", "trailing\\", "both\\\"", "\\\\server\\share\\" },
        &.{"例子 ünicode"},
    };
    const exe = try zio.executablePathAlloc(allocator);
    defer allocator.free(exe);
    const out_path = try std.fs.path.join(allocator, &.{ root, "argv.json" });
    defer allocator.free(out_path);
    for (cases) |case| {
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(allocator);
        try full.appendSlice(allocator, &.{ "--echo", out_path });
        try full.appendSlice(allocator, case);
        var buffer: [4096]u8 = undefined;
        const arguments = try system.jump_list.argumentLine(&buffer, full.items);
        const line = try std.fmt.allocPrint(allocator, "\"{s}\" {s}", .{ exe, arguments });
        defer allocator.free(line);
        const line_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, line);
        defer allocator.free(line_w);
        const c = @import("ziggurat_c_win32");
        var startup = std.mem.zeroes(c.STARTUPINFOW);
        startup.cb = @sizeOf(c.STARTUPINFOW);
        var info: c.PROCESS_INFORMATION = undefined;
        if (c.CreateProcessW(null, line_w.ptr, null, null, 0, 0, null, null, &startup, &info) == 0) return error.CreateProcessFailed;
        defer _ = c.CloseHandle(info.hProcess);
        defer _ = c.CloseHandle(info.hThread);
        if (c.WaitForSingleObject(info.hProcess, 20_000) != 0) return error.WaitFailed;
        const data = try std.Io.Dir.cwd().readFileAlloc(zio.io(), out_path, allocator, .limited(64 * 1024));
        defer allocator.free(data);
        const parsed = try std.json.parseFromSlice([]const []const u8, allocator, data, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.len, parsed.value.len);
        for (case, parsed.value) |want, got| try std.testing.expectEqualStrings(want, got);
        try std.Io.Dir.cwd().deleteFile(zio.io(), out_path);
    }
}
