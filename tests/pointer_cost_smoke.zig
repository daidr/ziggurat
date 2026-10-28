const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const c = @import("ziggurat_c_win32");

// Only calls through this test executable's selected IAT entries are counted.
// Wrappers preserve real SDK behavior. SDK/GDI internal allocations, DLL-local
// imports, elapsed CPU time and whole-stack peaks are outside this fixture.
const SDKCounts = extern struct {
    double_click_time: u64 = 0,
    metrics_total: u64 = 0,
    metrics_cx: u64 = 0,
    metrics_cy: u64 = 0,
    key_state_total: u64 = 0,
    key_shift: u64 = 0,
    key_control: u64 = 0,
    key_alt: u64 = 0,
    key_super: u64 = 0,
    other_thread: u64 = 0,
};
comptime {
    if (@sizeOf(SDKCounts) != 80 or @alignOf(SDKCounts) != 8) @compileError("pointer cost counter ABI");
}
extern fn zpc_install() c_int;
extern fn zpc_restore() c_int;
extern fn zpc_begin() c_int;
extern fn zpc_end(*SDKCounts) c_int;
extern fn zpc_last_error() u32;
extern fn zpc_counts_size() usize;
extern fn zpc_self_test(*SDKCounts) c_int;

const Kind = enum { alloc, resize, remap, free };
const Request = struct { kind: Kind, before: usize, after: usize, succeeded: bool };
const MemorySnapshot = struct {
    allocations: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,
    frees: usize = 0,
    requested_bytes: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    trace_at: usize = 0,
};
const Memory = struct {
    child: std.mem.Allocator,
    stats: MemorySnapshot = .{},
    requests: [256]Request = undefined,
    overflow: bool = false,

    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn record(self: *Memory, kind: Kind, before: usize, after: usize, succeeded: bool) void {
        if (self.stats.trace_at < self.requests.len) {
            self.requests[self.stats.trace_at] = .{ .kind = kind, .before = before, .after = after, .succeeded = succeeded };
            self.stats.trace_at += 1;
        } else self.overflow = true;
    }
    fn changed(self: *Memory, before: usize, after: usize) void {
        self.stats.live = self.stats.live - before + after;
        self.stats.peak = @max(self.stats.peak, self.stats.live);
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.stats.allocations += 1;
        self.stats.requested_bytes += len;
        const bytes = self.child.rawAlloc(len, alignment, ret);
        self.record(.alloc, 0, len, bytes != null);
        if (bytes != null) self.changed(0, len);
        return bytes;
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.stats.resizes += 1;
        const succeeded = self.child.rawResize(bytes, alignment, len, ret);
        self.record(.resize, bytes.len, len, succeeded);
        if (succeeded) self.changed(bytes.len, len);
        return succeeded;
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.stats.remaps += 1;
        const result = self.child.rawRemap(bytes, alignment, len, ret);
        self.record(.remap, bytes.len, len, result != null);
        if (result != null) self.changed(bytes.len, len);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.stats.frees += 1;
        self.record(.free, bytes.len, 0, true);
        self.changed(bytes.len, 0);
        self.child.rawFree(bytes, alignment, ret);
    }
    fn printRequests(self: *const Memory, label: []const u8, begin: usize, end: usize) void {
        std.debug.print("pointer-cost trace={s} [", .{label});
        for (self.requests[begin..end], 0..) |request, i| {
            std.debug.print("{s}{s}:{d}->{d}:{}", .{ if (i == 0) "" else ",", @tagName(request.kind), request.before, request.after, request.succeeded });
        }
        std.debug.print("]\n", .{});
    }
};

const Phase = enum { down, move, up, paint };
const Shot = struct { before: MemorySnapshot = .{}, after: MemorySnapshot = .{}, sdk: SDKCounts = .{}, callbacks: usize = 0, completed: bool = false };
const position: c.LPARAM = 20 | (20 << 16);
const Driver = struct {
    memory: *Memory,
    enabled: bool,
    app: *z.App = undefined,
    window: z.Window = undefined,
    phase: ?Phase = null,
    phase_index: usize = 0,
    measuring: bool = false,
    shots: [4]Shot = @splat(.{}),
    qualified_down: bool = false,
    detached: usize = 0,
    failure: ?anyerror = null,

    fn fail(self: *Driver, err: anyerror) void {
        if (self.failure == null) self.failure = err;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn detach(ptr: *anyopaque) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.detached += 1;
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.receive(window, value) catch |err| {
            self.fail(err);
            self.app.quit();
        };
    }
    fn receive(self: *Driver, window: z.Window, value: z.Event) !void {
        const phase = self.phase orelse return; // Includes the warm-up path.
        const actual: Phase = switch (value) {
            .pointer_down => .down,
            .pointer_move => .move,
            .pointer_up => .up,
            .paint => .paint,
            else => return,
        };
        if (actual != phase) return error.UnexpectedNativePhase;
        const shot = &self.shots[@backingInt(phase)];
        shot.callbacks += 1;
        if (shot.callbacks != 1) return error.DuplicateNativePhase;
        if (comptime @hasField(z.WindowOptions, "native_pointer_clicks") and @hasDecl(z.Window, "pointerPressSnapshot")) {
            if (self.enabled and phase == .down) {
                const receipt = value.pointer_down.press;
                try std.testing.expect(receipt.sequence != 0);
                const snapshot = try window.pointerPressSnapshot(receipt, .down);
                try std.testing.expect(snapshot.timing != null);
                self.qualified_down = true;
            }
        }
        // Core cannot run this App FIFO task until the entire native dispatch,
        // including capture release/final raw disposition, has returned.
        try self.app.post(.{ .context = self, .call = advance });
    }
    fn advance(ptr: *anyopaque) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.step() catch |err| {
            self.fail(err);
            if (self.measuring) {
                var discarded: SDKCounts = .{};
                _ = zpc_end(&discarded);
                self.measuring = false;
            }
            self.app.quit();
        };
    }
    fn step(self: *Driver) !void {
        if (self.phase) |phase| {
            const shot = &self.shots[@backingInt(phase)];
            try probe(zpc_end(&shot.sdk));
            self.measuring = false;
            shot.after = self.memory.stats;
            shot.completed = true;
            try std.testing.expectEqual(@as(usize, 1), shot.callbacks);
            try noMemoryTraffic(shot.before, shot.after);
            try std.testing.expectEqual(@as(u64, 0), shot.sdk.other_thread);
            if (!self.enabled) try noThresholdQueries(shot.sdk);
            if (self.enabled and phase == .down) {
                try std.testing.expect(self.qualified_down);
                try std.testing.expect(shot.sdk.double_click_time > 0);
                try std.testing.expect(shot.sdk.metrics_cx > 0);
                try std.testing.expect(shot.sdk.metrics_cy > 0);
            }
            self.phase_index += 1;
        }
        if (self.phase_index == self.shots.len) {
            self.phase = null;
            self.app.quit();
            return;
        }
        const phase: Phase = @fromBackingInt(@intCast(self.phase_index));
        self.phase = phase;
        self.shots[self.phase_index].before = self.memory.stats;
        try probe(zpc_begin());
        self.measuring = true;
        const message: c.UINT = switch (phase) {
            .down => c.WM_LBUTTONDOWN,
            .move => c.WM_MOUSEMOVE,
            .up => c.WM_LBUTTONUP,
            .paint => c.WM_PAINT,
        };
        const wp: c.WPARAM = if (phase == .down or phase == .move) c.MK_LBUTTON else 0;
        if (c.PostMessageW(@ptrCast(self.window.nativeHandle()), message, wp, if (phase == .paint) 0 else position) == 0) return error.PostFailed;
    }
};

fn probe(status: c_int) !void {
    if (status != 0) {
        std.debug.print("pointer-cost IAT probe status={d} native_error={d}\n", .{ status, zpc_last_error() });
        return error.NativeCostProbeFailed;
    }
}
fn noMemoryTraffic(before: MemorySnapshot, after: MemorySnapshot) !void {
    try std.testing.expectEqual(before.allocations, after.allocations);
    try std.testing.expectEqual(before.resizes, after.resizes);
    try std.testing.expectEqual(before.remaps, after.remaps);
    try std.testing.expectEqual(before.frees, after.frees);
    try std.testing.expectEqual(before.live, after.live);
}
fn noThresholdQueries(counts: SDKCounts) !void {
    try std.testing.expectEqual(@as(u64, 0), counts.double_click_time);
    try std.testing.expectEqual(@as(u64, 0), counts.metrics_cx);
    try std.testing.expectEqual(@as(u64, 0), counts.metrics_cy);
}
fn printSDK(label: []const u8, enabled: bool, counts: SDKCounts) void {
    std.debug.print("pointer-cost SDK phase={s} enabled={} DoubleClickTime={d} MetricsTotal={d} DoubleCx={d} DoubleCy={d} KeyStateTotal={d} shift={d} control={d} alt={d} super={d} other_thread={d}\n", .{ label, enabled, counts.double_click_time, counts.metrics_total, counts.metrics_cx, counts.metrics_cy, counts.key_state_total, counts.key_shift, counts.key_control, counts.key_alt, counts.key_super, counts.other_thread });
}

fn scenario(child: std.mem.Allocator, enabled: bool) !void {
    var memory: Memory = .{ .child = child };
    var driver: Driver = .{ .memory = &memory, .enabled = enabled };
    var app_end: MemorySnapshot = .{};
    var create_end: MemorySnapshot = .{};
    var warm_end: MemorySnapshot = .{};
    var create_sdk: SDKCounts = .{};
    {
        const app = try z.App.initWithOptions(memory.allocator(), .{ .icon_policy = .disabled, .diagnostics_sink = .{ .context = &driver, .emit = Driver.diagnostic } });
        driver.app = app;
        defer app.deinit();
        defer {
            if (driver.measuring) {
                var discarded: SDKCounts = .{};
                _ = zpc_end(&discarded);
            }
        }
        app_end = memory.stats;
        var options: z.WindowOptions = .{ .title = "Pointer cost", .width = 240, .height = 120 };
        if (comptime @hasField(z.WindowOptions, "native_pointer_clicks")) options.native_pointer_clicks = enabled else if (enabled) return error.UnsupportedCapability;
        try probe(zpc_begin());
        driver.measuring = true;
        const window = try app.createWindow(options);
        driver.window = window;
        try probe(zpc_end(&create_sdk));
        driver.measuring = false;
        create_end = memory.stats;
        try window.setContent(.{ .context = &driver, .event = Driver.event, .detach = Driver.detach });
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        _ = c.SetFocus(hwnd);
        if (c.GetFocus() != hwnd) return error.ThreadFocusUnavailable;
        // Separate first-use native behavior from the queued warmed measurements.
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, c.MK_LBUTTON, position);
        _ = c.SendMessageW(hwnd, c.WM_MOUSEMOVE, c.MK_LBUTTON, position);
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, position);
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        warm_end = memory.stats;
        try app.post(.{ .context = &driver, .call = Driver.advance });
        try app.run();
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    std.debug.print("pointer-cost enabled={} AppInit allocs={d} bytes={d} live={d}; WindowCreate allocs={d} bytes={d} live_before={d} live_after={d}; Warm allocs={d}; caller_owned_peak={d} final_live={d}\n", .{ enabled, app_end.allocations, app_end.requested_bytes, app_end.live, create_end.allocations - app_end.allocations, create_end.requested_bytes - app_end.requested_bytes, app_end.live, create_end.live, warm_end.allocations - create_end.allocations, memory.stats.peak, memory.stats.live });
    memory.printRequests("app-init", 0, app_end.trace_at);
    memory.printRequests("window-create", app_end.trace_at, create_end.trace_at);
    memory.printRequests("warm", create_end.trace_at, warm_end.trace_at);
    printSDK("window-create", enabled, create_sdk);
    for (driver.shots, std.meta.tags(Phase)) |shot, phase| {
        if (!shot.completed) {
            std.debug.print("pointer-cost hot={s} enabled={} incomplete callbacks={d}\n", .{ @tagName(phase), enabled, shot.callbacks });
            continue;
        }
        printSDK(@tagName(phase), enabled, shot.sdk);
        std.debug.print("pointer-cost hot={s} enabled={} callbacks={d} caller alloc/resize/remap/free={d}/{d}/{d}/{d} live={d}->{d}\n", .{ @tagName(phase), enabled, shot.callbacks, shot.after.allocations - shot.before.allocations, shot.after.resizes - shot.before.resizes, shot.after.remaps - shot.before.remaps, shot.after.frees - shot.before.frees, shot.before.live, shot.after.live });
    }
    if (driver.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 4), driver.phase_index);
    try std.testing.expectEqual(@as(usize, 1), driver.detached);
    try std.testing.expectEqual(@as(usize, 0), memory.stats.live);
    try std.testing.expect(!memory.overflow);
    if (!enabled) try noThresholdQueries(create_sdk);
}

fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.PointerCost.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    var command: [32768:0]u16 = undefined;
    if (count + suffix.len + 1 >= command.len) return error.CommandTooLong;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) {
        std.debug.print("pointer-cost private-desktop child exit=0x{x}\n", .{exit_code});
        return error.TestProcessFailed;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (args.len == 1) return isolatedWindows();
    if (args.len != 2 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    try std.testing.expectEqual(@sizeOf(SDKCounts), zpc_counts_size());
    try probe(zpc_install());
    var installed = true;
    defer {
        if (installed) std.debug.assert(zpc_restore() == 0);
    }
    var positive: SDKCounts = .{};
    try probe(zpc_self_test(&positive));
    printSDK("probe-self-test-only", false, positive);
    try std.testing.expectEqual(@as(u64, 1), positive.double_click_time);
    try std.testing.expectEqual(@as(u64, 1), positive.metrics_cx);
    try std.testing.expectEqual(@as(u64, 1), positive.metrics_cy);
    try std.testing.expectEqual(@as(u64, 2), positive.metrics_total);
    try std.testing.expectEqual(@as(u64, 1), positive.key_shift);
    try std.testing.expectEqual(@as(u64, 1), positive.key_state_total);
    try std.testing.expectEqual(@as(u64, 0), positive.other_thread);
    std.debug.print("pointer-cost ABI Event={d} Options={d} Record={d} Native={d} App={d}\n", .{ @sizeOf(z.Event), @sizeOf(z.WindowOptions), @sizeOf(z.WindowRecord), @sizeOf(@FieldType(z.WindowRecord, "native")), @sizeOf(z.App) });
    if (comptime @hasDecl(z, "PointerPressSnapshot")) std.debug.print("pointer-cost Snapshot={d}\n", .{@sizeOf(z.PointerPressSnapshot)});
    try scenario(debug.allocator(), false);
    if (comptime @hasField(z.WindowOptions, "native_pointer_clicks")) try scenario(debug.allocator(), true) else std.debug.print("pointer-cost raw capability absent; old API default-off only\n", .{});
    try probe(zpc_restore());
    installed = false;
    std.debug.print("pointer-cost own IAT restored; caller allocation traces only; SDK/GDI internal storage and CPU/whole-stack peaks unmeasured\n", .{});
}
