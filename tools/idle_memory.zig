//! Launches apps and reports how much memory each takes once idle, alone
//! and with the processes it runs, such as its WebView's. It needs a
//! desktop session.
//!
//!     zig build idle-memory -- [--count 3] [--idle 6] APP...
//!
//! Each app runs `count` times, for `idle` seconds each time, and the
//! medians print as JSON by the name of the app's file:
//! `{"hello": {"app": bytes, "total": bytes}}`. Memory is what each
//! platform shows for a process:
//!
//! - Linux: the proportional set size of the app and of its descendants,
//!   WebKitGTK's processes, so that pages they share count once;
//! - Windows: the private working set, as Task Manager shows it, of the
//!   app and of its descendants, WebView2's processes.
const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try zio.argsAlloc(allocator, init.args);
    var count: usize = 3;
    var idle_seconds: f64 = 6;
    var apps: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if ((std.mem.eql(u8, arg, "--count") or std.mem.eql(u8, arg, "--idle")) and index + 1 < args.len) {
            index += 1;
            if (arg[2] == 'c') count = try std.fmt.parseInt(usize, args[index], 10) else idle_seconds = try std.fmt.parseFloat(f64, args[index]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage();
        } else try apps.append(allocator, arg);
    }
    if (apps.items.len == 0 or count == 0 or !(idle_seconds > 0)) return usage();
    const idle_ns: u64 = @intFromFloat(idle_seconds * std.time.ns_per_s);

    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('{');
    for (apps.items, 0..) |app, app_index| {
        const name = stem(app);
        const own = try allocator.alloc(u64, count);
        const totals = try allocator.alloc(u64, count);
        for (0..count) |run| {
            const result = measure(allocator, app, idle_ns) catch |err| {
                std.debug.print("idle-memory: {s}: {s}\n", .{ name, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("{s}: {d:.1} MB, {d:.1} MB with its processes\n", .{ name, @as(f64, @floatFromInt(result.app)) / 1e6, @as(f64, @floatFromInt(result.total)) / 1e6 });
            own[run] = result.app;
            totals[run] = result.total;
        }
        if (app_index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(name, .{}, &out.writer);
        try out.writer.print(":{{\"app\":{d},\"total\":{d}}}", .{ median(own), median(totals) });
    }
    try out.writer.writeAll("}\n");
    try std.Io.File.stdout().writeStreamingAll(zio.io(), out.written());
}

fn usage() void {
    std.debug.print("usage: idle-memory [--count N] [--idle SECONDS] APP...\n", .{});
    std.process.exit(2);
}

/// The app's file name without `.exe`.
pub fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.ascii.endsWithIgnoreCase(base, ".exe")) base[0 .. base.len - 4] else base;
}

pub fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const n = values.len;
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2;
}

const Usage = struct { app: u64, total: u64 };

fn measure(allocator: std.mem.Allocator, app: []const u8, idle_ns: u64) !Usage {
    var child = try zio.spawn(.{ .argv = &.{app}, .stdin = .ignore });
    if (platform.waitExit(&child, idle_ns)) return error.ExitedAfterStarting;
    const processes = try platform.descendants(allocator, platform.id(&child));
    var result: Usage = .{ .app = 0, .total = 0 };
    for (processes, 0..) |pid, i| {
        const bytes = platform.memory(pid) catch |err| {
            if (i == 0) {
                platform.stop(&child, processes);
                return err;
            }
            continue;
        };
        if (i == 0) result.app = bytes;
        result.total += bytes;
    }
    platform.stop(&child, processes);
    return result;
}

const platform = switch (builtin.os.tag) {
    .linux => linux,
    .windows => windows,
    else => @compileError("idle-memory measures on Linux and Windows"),
};

const linux = struct {
    const posix = std.posix;

    fn id(child: *std.process.Child) i32 {
        return child.id.?;
    }

    /// Whether the child exited within `timeout_ns`; it is reaped if so.
    fn waitExit(child: *std.process.Child, timeout_ns: u64) bool {
        var waited: u64 = 0;
        const step = 50 * std.time.ns_per_ms;
        while (waited < timeout_ns) : (waited += step) {
            const result = zio.posix.waitpid(child.id.?, posix.W.NOHANG);
            if (result.pid == child.id.?) {
                child.id = null;
                return true;
            }
            zio.sleep(step);
        }
        return false;
    }

    /// The app, then the processes it started and theirs.
    fn descendants(allocator: std.mem.Allocator, pid: i32) ![]i32 {
        var parents: std.AutoHashMapUnmanaged(i32, std.ArrayList(i32)) = .empty;
        var proc = try std.Io.Dir.openDirAbsolute(zio.io(), "/proc", .{ .iterate = true });
        defer proc.close(zio.io());
        var iterator = proc.iterate();
        var buffer: [4096]u8 = undefined;
        while (try iterator.next(zio.io())) |entry| {
            const child = std.fmt.parseInt(i32, entry.name, 10) catch continue;
            var path: [64]u8 = undefined;
            const stat = proc.readFile(zio.io(), std.fmt.bufPrint(&path, "{s}/stat", .{entry.name}) catch continue, &buffer) catch continue;
            const ppid = parentOf(stat) orelse continue;
            const list = try parents.getOrPut(allocator, ppid);
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(allocator, child);
        }
        var out: std.ArrayList(i32) = .empty;
        try out.append(allocator, pid);
        var next: usize = 0;
        while (next < out.items.len) : (next += 1) {
            if (parents.get(out.items[next])) |children| try out.appendSlice(allocator, children.items);
        }
        return out.toOwnedSlice(allocator);
    }

    /// The parent in `/proc/PID/stat`: `pid (comm) state ppid …`, where
    /// comm may hold anything, parentheses included.
    pub fn parentOf(stat: []const u8) ?i32 {
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        _ = fields.next() orelse return null;
        return std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch null;
    }

    fn memory(pid: i32) !u64 {
        var path: [64]u8 = undefined;
        var buffer: [8192]u8 = undefined;
        const rollup = try std.Io.Dir.cwd().readFile(zio.io(), try std.fmt.bufPrint(&path, "/proc/{d}/smaps_rollup", .{pid}), &buffer);
        return pss(rollup) orelse error.NoProportionalSetSize;
    }

    pub fn pss(rollup: []const u8) ?u64 {
        var lines = std.mem.tokenizeScalar(u8, rollup, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "Pss:")) continue;
            const value = std.mem.trim(u8, line["Pss:".len..], " \t");
            const number = std.mem.trimEnd(u8, std.mem.trimEnd(u8, value, "kB"), " ");
            const kb = std.fmt.parseInt(u64, number, 10) catch return null;
            return kb * 1024;
        }
        return null;
    }

    /// Ask the app to quit, which its WebKit processes follow; kill it if
    /// it has not after 10 seconds.
    fn stop(child: *std.process.Child, _: []const i32) void {
        const pid = child.id orelse return;
        posix.kill(pid, .TERM) catch {};
        if (!waitExit(child, 10 * std.time.ns_per_s)) {
            posix.kill(pid, .KILL) catch {};
            _ = zio.posix.waitpid(pid, 0);
            child.id = null;
        }
    }
};

const windows = struct {
    const w = std.os.windows;
    const PROCESS_TERMINATE = 0x0001;
    const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const TH32CS_SNAPPROCESS = 0x00000002;

    /// PROCESS_MEMORY_COUNTERS_EX2, of Windows 10 1809 and later.
    const MemoryCounters = extern struct {
        cb: u32,
        PageFaultCount: u32,
        PeakWorkingSetSize: usize,
        WorkingSetSize: usize,
        QuotaPeakPagedPoolUsage: usize,
        QuotaPagedPoolUsage: usize,
        QuotaPeakNonPagedPoolUsage: usize,
        QuotaNonPagedPoolUsage: usize,
        PagefileUsage: usize,
        PeakPagefileUsage: usize,
        PrivateUsage: usize,
        PrivateWorkingSetSize: usize,
        SharedCommitUsage: u64,
    };
    const ProcessEntry = extern struct {
        dwSize: u32,
        cntUsage: u32,
        th32ProcessID: u32,
        th32DefaultHeapID: usize,
        th32ModuleID: u32,
        cntThreads: u32,
        th32ParentProcessID: u32,
        pcPriClassBase: i32,
        dwFlags: u32,
        szExeFile: [260]u16,
    };
    extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn K32GetProcessMemoryInfo(process: w.HANDLE, counters: *MemoryCounters, size: u32) callconv(.winapi) c_int;
    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn WaitForSingleObject(handle: w.HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn Process32FirstW(snapshot: w.HANDLE, entry: *ProcessEntry) callconv(.winapi) c_int;
    extern "kernel32" fn Process32NextW(snapshot: w.HANDLE, entry: *ProcessEntry) callconv(.winapi) c_int;
    extern "kernel32" fn TerminateProcess(process: w.HANDLE, code: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessId(process: w.HANDLE) callconv(.winapi) u32;

    fn id(child: *std.process.Child) u32 {
        return GetProcessId(child.id.?);
    }

    fn waitExit(child: *std.process.Child, timeout_ns: u64) bool {
        const ms: u32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(u32) - 1));
        return WaitForSingleObject(child.id.?, ms) == 0;
    }

    /// The app, then the processes it started and theirs. A parent's ID
    /// may have been reused by a process it did not start, so each process
    /// is listed once.
    fn descendants(allocator: std.mem.Allocator, pid: u32) ![]u32 {
        const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == w.INVALID_HANDLE_VALUE) return allocator.dupe(u32, &.{pid});
        defer w.CloseHandle(snapshot);
        var pairs: std.ArrayList([2]u32) = .empty;
        var entry: ProcessEntry = undefined;
        entry.dwSize = @sizeOf(ProcessEntry);
        var more = Process32FirstW(snapshot, &entry) != 0;
        while (more) : (more = Process32NextW(snapshot, &entry) != 0) try pairs.append(allocator, .{ entry.th32ParentProcessID, entry.th32ProcessID });
        var out: std.ArrayList(u32) = .empty;
        try out.append(allocator, pid);
        var next: usize = 0;
        while (next < out.items.len) : (next += 1) {
            for (pairs.items) |pair| if (pair[0] == out.items[next] and std.mem.indexOfScalar(u32, out.items, pair[1]) == null) try out.append(allocator, pair[1]);
        }
        return out.toOwnedSlice(allocator);
    }

    /// The pages of the process in memory that no other process shares.
    fn memory(pid: u32) !u64 {
        const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return error.OpenProcessFailed;
        defer w.CloseHandle(process);
        var counters = std.mem.zeroes(MemoryCounters);
        counters.cb = @sizeOf(MemoryCounters);
        if (K32GetProcessMemoryInfo(process, &counters, counters.cb) == 0) return error.MemoryInfoFailed;
        return counters.PrivateWorkingSetSize;
    }

    /// End the app and the processes it ran: Windows has no signal to ask
    /// it to quit.
    fn stop(child: *std.process.Child, processes: []const u32) void {
        _ = TerminateProcess(child.id.?, 1);
        for (processes[1..]) |pid| if (OpenProcess(PROCESS_TERMINATE, 0, pid)) |process| {
            _ = TerminateProcess(process, 1);
            w.CloseHandle(process);
        };
        _ = child.wait(zio.io()) catch {};
    }
};

test "medians and names" {
    var odd = [_]u64{ 5, 1, 3 };
    try std.testing.expectEqual(@as(u64, 3), median(&odd));
    var even = [_]u64{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(u64, 2), median(&even));
    try std.testing.expectEqualStrings("hello", stem("zig-out/bin/hello.exe"));
    try std.testing.expectEqualStrings("hello", stem("hello"));
}

test "Linux process files" {
    try std.testing.expectEqual(@as(?i32, 41), linux.parentOf("42 (a (weird) name) S 41 42 42 0"));
    try std.testing.expectEqual(@as(?u64, 12 * 1024 * 1024), linux.pss("55a0-55b0 ---p 00000000 00:00 0 [rollup]\nRss:  20000 kB\nPss:   12288 kB\nPss_Anon: 1 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), linux.pss("Rss: 1 kB\n"));
}
