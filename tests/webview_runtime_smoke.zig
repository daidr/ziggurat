const std = @import("std");
const runtime = @import("ziggurat_webview_runtime");
const win = @import("ziggurat_c_win32");

const Probe = struct {
    main_thread: std.Thread.Id,
    loader: []const u8,
    failure: ?anyerror = null,
    result: ?runtime.Result = null,
    fn run(self: *Probe) void {
        self.exercise() catch |err| {
            self.failure = err;
        };
    }
    fn exercise(self: *Probe) !void {
        var cancelled: runtime.Cancellation = .{};
        cancelled.request();
        const unreadable: [*]const u8 = @ptrFromInt(4096);
        try std.testing.expectError(error.Cancelled, runtime.probe(self.main_thread, .{ .loader_path = unreadable[0..1], .cancellation = &cancelled }));
        try std.testing.expectError(error.AbsolutePathRequired, runtime.probe(self.main_thread, .{ .loader_path = "WebView2Loader.dll" }));

        var loader_wide: [runtime.max_path_units + 1]u16 = undefined;
        const length = try std.unicode.utf8ToUtf16Le(&loader_wide, self.loader);
        loader_wide[length] = 0;
        const loader_z = loader_wide[0..length :0];
        try std.testing.expect(win.GetModuleHandleW(loader_z.ptr) == null);
        const first = try runtime.probe(self.main_thread, .{ .loader_path = self.loader });
        if (first.status != .available) {
            std.debug.print("runtime discovery failure: {any}\n", .{first});
            return error.InstalledRuntimeRequired;
        }
        try std.testing.expect(first.version().len > 0 and first.failure == null);
        try std.testing.expect(win.GetModuleHandleW(loader_z.ptr) == null);
        var baseline: win.DWORD = 0;
        try std.testing.expect(win.GetProcessHandleCount(win.GetCurrentProcess(), &baseline) != 0);
        for (0..8) |_| {
            const result = try runtime.probe(self.main_thread, .{ .loader_path = self.loader });
            try std.testing.expect(result.status == .available and result.version().len > 0);
            try std.testing.expect(win.GetModuleHandleW(loader_z.ptr) == null);
        }
        var after: win.DWORD = 0;
        try std.testing.expect(win.GetProcessHandleCount(win.GetCurrentProcess(), &after) != 0);
        try std.testing.expectEqual(baseline, after);

        var missing_storage: [runtime.max_path_units * 3]u8 = undefined;
        const missing = try std.fmt.bufPrint(&missing_storage, "{s}.ziggurat-missing.dll", .{self.loader});
        const missing_result = try runtime.probe(self.main_thread, .{ .loader_path = missing });
        try std.testing.expect(missing_result.status == .failed and missing_result.failure.?.phase == .load_loader and missing_result.failure.?.domain == .win32);

        var system_directory: [win.MAX_PATH + 1]u16 = undefined;
        const units = win.GetSystemDirectoryW(&system_directory, system_directory.len);
        try std.testing.expect(units > 0 and units < system_directory.len);
        var system_path: [win.MAX_PATH * 3 + 32]u8 = undefined;
        const prefix = try std.unicode.utf16LeToUtf8(&system_path, system_directory[0..units]);
        const suffix = "\\kernel32.dll";
        @memcpy(system_path[prefix..][0..suffix.len], suffix);
        const wrong = try runtime.probe(self.main_thread, .{ .loader_path = system_path[0 .. prefix + suffix.len] });
        try std.testing.expect(wrong.status == .failed and wrong.failure.?.phase == .find_entry and wrong.failure.?.code == win.ERROR_PROC_NOT_FOUND);
        try expectNoChildProcess();
        self.result = first;
    }
};

fn expectNoChildProcess() !void {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    try std.testing.expect(snapshot != win.INVALID_HANDLE_VALUE);
    defer _ = win.CloseHandle(snapshot);
    var entry = std.mem.zeroes(win.PROCESSENTRY32W);
    entry.dwSize = @sizeOf(win.PROCESSENTRY32W);
    var found = win.Process32FirstW(snapshot, &entry);
    const current = win.GetCurrentProcessId();
    while (found != 0) : (found = win.Process32NextW(snapshot, &entry)) {
        try std.testing.expect(entry.th32ParentProcessID != current);
    }
    try std.testing.expectEqual(@as(win.DWORD, win.ERROR_NO_MORE_FILES), win.GetLastError());
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = try init.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    const loader = args.next() orelse return error.LoaderPathRequired;
    if (args.next() != null) return error.UnexpectedArgument;
    const main_thread = std.Thread.getCurrentId();
    try std.testing.expectError(error.UiThreadForbidden, runtime.probe(main_thread, .{ .loader_path = loader }));
    var probe: Probe = .{ .main_thread = main_thread, .loader = loader };
    const worker = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    // This standalone harness has no App or UI loop. Production callers own
    // their worker lifecycle and use App.post when delivering results to UI.
    worker.join();
    if (probe.failure) |err| return err;
    std.debug.print("runtime discovery: installed={s}, explicit worker, no App/page/profile; loader released on nine queries, process handles stable, zero surviving child processes; missing loader and missing entry distinct\n", .{probe.result.?.version()});
}
