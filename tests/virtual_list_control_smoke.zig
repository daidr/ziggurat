const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const virtual = @import("ziggurat_virtual_list");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zvl_release(*anyopaque) void;
extern fn zvl_catalog_probe(*anyopaque, u32, *?*anyopaque) i32;
extern fn zvl_selection_probe(*anyopaque, c_int) i32;
extern fn zvl_row_request(*anyopaque, c_int) i32;
extern fn zvl_row_status(*anyopaque, [*:0]const u16, c_int) i32;
extern fn zvl_stale(*anyopaque) i32;
extern fn zvl_late_identity(*anyopaque) i32;
extern fn zua_begin_close(*anyopaque) void;
extern fn zua_test_before_enqueue(*anyopaque, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) i32;
const unavailable: i32 = @bitCast(@as(u32, 0x80040201));
const viewport: ui.Rect = .{ .x = 10, .y = 10, .width = 180, .height = 60 };
const Host = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    control: *virtual.Control = undefined,
    rows: [257]virtual.Row = undefined,
    labels: [257]virtual.Control.Label = undefined,
    text: [257][16]u8 = undefined,
    anchor: ?*anyopaque = null,
    old_row: ?*anyopaque = null,
    new_row: ?*anyopaque = null,
    worker: ?std.Thread = null,
    wake: zio.ResetEvent = .{},
    error_value: ?anyerror = null,
    worker_error: ?anyerror = null,
    stopped: std.atomic.Value(bool) = .init(false),
    hr: i32 = -1,
    changes: usize = 0,
    replacement_done: bool = false,
    fail_paint: bool = false,
    expected_diagnostics: usize = 0,
    diagnostics: usize = 0,
    step: u8 = 0,
    fn fail(self: *Host, err: anyerror) void {
        if (self.error_value == null) self.error_value = err;
        std.debug.print("List Control stage={d}: {s}\n", .{ self.step, @errorName(err) });
        self.app.quit();
        self.stopped.store(true, .release);
        self.wake.set();
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        std.debug.print("List diagnostic {s}/{s} code={?x} err={s}\n", .{ @tagName(value.domain), @tagName(value.operation), value.code, @errorName(value.err orelse error.UnknownDiagnostic) });
        self.diagnostics += 1;
        if (self.diagnostics > self.expected_diagnostics) self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn changed(ptr: ?*anyopaque, _: z.Window, _: *virtual.Control, _: virtual.Control.Change) void {
        const self: *Host = @ptrCast(@alignCast(ptr.?));
        self.changes += 1;
    }
    fn row(_: *anyopaque, frame: *ui.Frame, value: virtual.Control.RowView) !void {
        frame.rect(value.row.visible_bounds, if (value.selected) 0x3399cc else 0x226644);
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        frame.clear(0xffffff);
        _ = self.control.draw(frame, viewport, "Complete list", .{ .context = self, .draw = row }, .{}) catch |err| {
            self.fail(err);
            return;
        };
        if (self.fail_paint) frame.failure = error.ListCandidateRejected;
    }
    fn paint(self: *Host) !void {
        _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (self.error_value) |err| return err;
    }
    fn catalog(self: *Host) !void {
        const input = try self.control.snapshotCatalog(self.app.allocator, &self.labels, .{});
        defer input.close();
        const prepared = try virtual.Control.NativeCatalog.prepare(input, 1024 * 1024);
        errdefer prepared.close();
        try self.control.installCatalog(prepared);
    }
    fn begin(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.beginChecked() catch |err| self.fail(err);
    }
    fn beginChecked(self: *Host) !void {
        try self.paint();
        self.anchor = try self.context.accessibility_bridge.retainProvider(7);
        try std.testing.expectEqual(@as(i32, 0), zvl_catalog_probe(self.anchor.?, 257, &self.old_row));
        try std.testing.expectEqual(@as(i32, 0), zvl_selection_probe(self.anchor.?, 0));
        try std.testing.expectEqual(@as(i32, 0), zua_test_before_enqueue(self.context.accessibility_bridge.native.?, beforeEnqueue, self));
        self.worker = try std.Thread.spawn(.{}, workerMain, .{self});
    }
    fn beforeEnqueue(ptr: *anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.app.post(.{ .context = self, .call = replace }) catch return 0;
        return 1;
    }
    fn replace(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.replaceChecked() catch |err| self.fail(err);
    }
    fn replaceChecked(self: *Host) !void {
        const old = try self.control.rowToken(257);
        _ = try self.control.replace(self.rows[0..256], viewport.height);
        _ = try self.control.replace(&self.rows, viewport.height);
        try std.testing.expect(old.incarnation != (try self.control.rowToken(257)).incarnation);
        try self.catalog();
        try self.paint();
        self.replacement_done = true;
    }
    fn workerMain(self: *Host) void {
        const init = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        defer if (init >= 0) c.CoUninitialize();
        if (init < 0) {
            self.worker_error = error.NativeMtaInitializationFailed;
            self.app.post(.{ .context = self, .call = verify }) catch |err| std.debug.panic("List worker verification post failed: {s}", .{@errorName(err)});
            return;
        }
        self.hr = zvl_row_request(self.old_row.?, 0);
        self.app.post(.{ .context = self, .call = verify }) catch |err| std.debug.panic("List worker verification post failed: {s}", .{@errorName(err)});
        self.wake.wait();
        self.wake.reset();
        if (self.stopped.load(.acquire)) return;
        self.hr = zvl_row_request(self.new_row.?, 0);
        self.app.post(.{ .context = self, .call = verify }) catch |err| std.debug.panic("List worker verification post failed: {s}", .{@errorName(err)});
        self.wake.wait();
        self.wake.reset();
        if (self.stopped.load(.acquire)) return;
        self.hr = zvl_row_request(self.new_row.?, 1);
        self.app.post(.{ .context = self, .call = verify }) catch |err| std.debug.panic("List worker verification post failed: {s}", .{@errorName(err)});
    }
    fn verify(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.verifyChecked() catch |err| self.fail(err);
    }
    fn verifyChecked(self: *Host) !void {
        if (self.worker_error) |err| return err;
        try std.testing.expectEqual(@as(i32, 0), self.hr);
        try std.testing.expectEqual(@as(u32, 0), ui.accessibility.resourceCounts().actions);
        switch (self.step) {
            0 => {
                try std.testing.expect(self.replacement_done);
                try std.testing.expectEqual(@as(usize, 2), self.changes);
                try std.testing.expectEqual(@as(usize, 0), try self.control.selectedCount());
                try std.testing.expectEqual(unavailable, zvl_stale(self.old_row.?));
                try std.testing.expectEqual(@as(i32, 0), zvl_catalog_probe(self.anchor.?, 257, &self.new_row));
                self.step = 1;
                self.wake.set();
            },
            1 => {
                try std.testing.expect(try self.control.selected(257));
                // Accepted accessibility remains on the old successful paint.
                try std.testing.expectEqual(@as(i32, 0), zvl_selection_probe(self.anchor.?, 0));
                self.fail_paint = true;
                self.expected_diagnostics += 1;
                const generation = self.context.space_generation;
                try self.paint();
                try std.testing.expectEqual(generation, self.context.space_generation);
                try std.testing.expectEqual(@as(i32, 0), zvl_selection_probe(self.anchor.?, 0));
                self.fail_paint = false;
                try self.paint();
                try std.testing.expectEqual(@as(i32, 0), zvl_selection_probe(self.anchor.?, 1));
                try std.testing.expect(self.context.input_state.focused == null);
                self.step = 2;
                self.wake.set();
            },
            2 => {
                try std.testing.expect((try self.control.scrollOffset(viewport.height)) > 0);
                try self.paint();
                try std.testing.expectEqual(@as(i32, 0), zvl_row_status(self.new_row.?, std.unicode.utf8ToUtf16LeStringLiteral("row 257"), 0));
                try std.testing.expect(self.context.input_state.focused == null);
                try std.testing.expectEqual(self.expected_diagnostics, self.diagnostics);
                // The disconnect algorithm needs immutable COM identity after
                // semantic withdrawal, before it releases the native root.
                zua_begin_close(self.context.accessibility_bridge.native.?);
                try std.testing.expectEqual(@as(i32, 0), zvl_late_identity(self.new_row.?));
                try std.testing.expectEqual(unavailable, zvl_stale(self.new_row.?));
                try std.testing.expectEqual(unavailable, zvl_row_request(self.new_row.?, 0));
                self.step = 3;
                self.app.quit();
            },
            else => return error.UnexpectedStage,
        }
    }
};

fn scenario(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var host: Host = .{};
    defer {
        if (host.old_row) |value| zvl_release(value);
        if (host.new_row) |value| zvl_release(value);
        if (host.anchor) |value| zvl_release(value);
    }
    for (&host.rows, &host.labels, &host.text, 0..) |*row, *label, *text, index| {
        row.* = .{ .id = index + 1, .height = 10 };
        label.* = .{ .id = index + 1, .text = try std.fmt.bufPrint(text, "row {d}", .{index + 1}) };
    }
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    host.app = app;
    host.window = try app.createWindow(.{ .width = 220, .height = 110 });
    try host.window.perform(.show);
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    try host.context.attach(host.window);
    try host.context.prepareRecipients(allocator, .{ .recipients = 4 });
    try host.context.prepareVirtualLists(.{ .lists = 1, .model_bytes = 1024 * 1024 });
    host.control = try virtual.Control.create(allocator, std.Thread.getCurrentId(), &host.rows, .{ .native_semantics = true, .context = &host, .changed = Host.changed });
    defer host.control.close() catch unreachable;
    try host.control.attach(&host.context, 7);
    try host.catalog();
    const recipient_stats = try host.context.recipientsStats();
    const list_stats = try host.context.virtualListStats();
    std.debug.print("List Control budgets registry4={d} native-base={d} aggregate={d}; native-list metadata={d} capacity={d} physical-model={d} provider={d} request={d}\n", .{ recipient_stats.registry_bytes, recipient_stats.native_bytes, recipient_stats.total_bytes, list_stats.metadata, list_stats.capacity, list_stats.physical_models, list_stats.providers, list_stats.requests });
    try app.post(.{ .context = &host, .call = Host.begin });
    const run_result = app.run();
    host.stopped.store(true, .release);
    host.wake.set();
    if (host.worker) |worker| worker.join();
    try run_result;
    if (host.error_value) |err| return err;
    try std.testing.expectEqual(@as(u8, 3), host.step);
    // Retained COM objects now have only C state; the Zig Window is detached.
    try std.testing.expectEqual(unavailable, zvl_stale(host.new_row.?));
    zvl_release(host.old_row.?);
    host.old_row = null;
    zvl_release(host.new_row.?);
    host.new_row = null;
    zvl_release(host.anchor.?);
    host.anchor = null;
    try std.testing.expectEqualDeep(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
    try std.testing.expectEqual(@as(u32, 0), ui.accessibility.collectionsResourceCount());
    try std.testing.expectEqual(@as(u32, 0), ui.accessibility.geometryResourceCount());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("List Control native: full257 offscreen/name/navigation/Selection2, captured MTA old incarnation dropped, current selection accepted only after successful paint, explicit reveal no focus, late COM detach; resources=0\n", .{});
}

fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.ListControl.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    if (count + 1 + suffix.len >= command.len) return error.CommandTooLong;
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
    // Parent-process test deadline only. The child uses the real App queue;
    // it never blocks a UI callback or pumps a nested event loop.
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) {
        std.debug.print("List-control private-desktop child exit=0x{x}\n", .{exit_code});
        return error.TestProcessFailed;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = try init.args.iterateAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    const child = if (args.next()) |arg| if (std.mem.eql(u8, arg, "--desktop-child")) true else return error.InvalidArgument else false;
    if (args.next() != null) return error.InvalidArgument;
    if (builtin.os.tag == .windows and !child) return isolatedWindows();
    try scenario(gpa.allocator());
}
