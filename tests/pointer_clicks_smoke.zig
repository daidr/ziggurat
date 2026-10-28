const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zgpu_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*f64, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const checkpoint_message = 0x8000 + 191;
const Case = enum { counts, rejected_frame, stale_clear, consumed, rejected_action, close_action, affine, disabled, preinput_frame };

const Native = struct {
    fn paint(window: z.Window) void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        } else {
            const size = window.contentSize() catch unreachable;
            const factor: u32 = @intFromFloat(size.scale);
            std.debug.assert(factor != 0 and size.width % factor == 0 and size.height % factor == 0);
            zlg_test_paint(window.app.windows.get(window.key).?.native.native.?, size.width / factor, size.height / factor);
        }
    }
    fn button(window: z.Window, point: z.Point, phase: z.PointerPhase, tick: u32) !void {
        if (builtin.os.tag == .windows) {
            const scale = (try window.contentSize()).scale;
            const x: i16 = @intFromFloat(@round(point.x * scale));
            const y: i16 = @intFromFloat(@round(point.y * scale));
            const encoded: u32 = @as(u32, @as(u16, @bitCast(y))) << 16 | @as(u16, @bitCast(x));
            const hwnd: c.HWND = window.nativeHandle();
            // Real queue delivery supplies GetMessageTime and the Core queue
            // envelope. No direct Zig callback or synthetic receipt is used.
            if (c.PostMessageW(hwnd, if (phase == .down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP, if (phase == .down) c.MK_LBUTTON else 0, @intCast(encoded)) == 0) return error.PostPointerFailed;
        } else {
            const area = g_object_ref(gtk_bin_get_child(window.nativeHandle().?).?);
            defer g_object_unref(area);
            const native_window = g_object_ref(gtk_widget_get_window(area).?);
            defer g_object_unref(native_window);
            // GTK's actual registered signal/adapter consumes deterministic
            // native facts. This does not claim physical-device provenance.
            var event: ButtonEvent = .{ .kind = if (phase == .down) 4 else 7, .window = native_window, .send_event = 1, .time = tick, .x = point.x, .y = point.y, .axes = null, .state = if (phase == .up) 1 << 8 else 0, .button = 1, .device = null, .x_root = point.x, .y_root = point.y };
            var handled: c_int = 0;
            g_signal_emit_by_name(area, if (phase == .down) "button-press-event" else "button-release-event", &event, &handled);
        }
    }
    fn checkpoint(host: *Host) !void {
        if (host.window.isClosed()) return;
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = host.window.nativeHandle();
            if (c.PostMessageW(hwnd, checkpoint_message, 0, 0) == 0) return error.PostCheckpointFailed;
        } else if (!host.window.isClosed()) try host.app.post(.{ .context = host, .call = Host.checkStage });
    }
};

const Host = struct {
    allocator: std.mem.Allocator,
    renderer: ui.RenderMode,
    case: Case,
    app: *z.App = undefined,
    app_ready: bool = false,
    window: z.Window = undefined,
    context: ?*ui.Context = null,
    targets: [2]ui.ClickTarget = undefined,
    failure: ?anyerror = null,
    phase: enum { front, failed_front, inputs, done } = .front,
    check_posted: bool = false,
    fail_candidate: bool = false,
    repaint_once: bool = false,
    baseline_frames: usize = 0,
    baseline_front: u64 = 0,
    counts: [8]u8 = undefined,
    ids: [8]u64 = undefined,
    calls: usize = 0,
    legacy: usize = 0,
    closed: usize = 0,
    diagnostics: usize = 0,
    raw_downs: usize = 0,
    gpu_frames: usize = 0,
    presents: u32 = 0,
    matrix: ui.affine.Affine = .{ .xx = 1, .xy = 0.4, .yx = 0.2, .yy = 1, .x0 = 30, .y0 = 25 },

    fn fail(self: *Host, err: anyerror) void {
        self.failure = self.failure orelse err;
        std.debug.print("registered native {s} failed: {s}\n", .{ @tagName(self.case), @errorName(err) });
        if (self.app_ready) self.app.quit();
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.project(frame) catch |err| {
            frame.failure = frame.failure orelse err;
        };
    }
    fn project(self: *Host, frame: *ui.Frame) !void {
        frame.rect(.{ .x = 0, .y = 0, .width = 240, .height = 160 }, 0x18304a);
        if (self.case == .stale_clear and self.fail_candidate) {
            frame.failure = error.RejectedClickCandidate;
            return;
        }
        if (self.case == .affine) {
            try frame.beginTransform(.{ .width = 100, .height = 80 }, self.matrix);
            try frame.pushClip(.{ .x = 0, .y = 0, .width = 90, .height = 70 });
            try frame.pushOffset(.{ .x = 2, .y = 3 });
        }
        const boxes = if (self.case == .affine) [_]ui.Rect{ .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .{ .x = 30, .y = 0, .width = 20, .height = 20 } } else [_]ui.Rect{ .{ .x = 8, .y = 8, .width = 20, .height = 30 }, .{ .x = 40, .y = 8, .width = 20, .height = 30 } };
        for (self.targets, boxes) |target, bounds| try frame.clickButton(target, bounds, "Click", .{ .enabled = self.case != .disabled });
        if (self.case == .affine) {
            try frame.popOffset();
            try frame.popClip();
            try frame.endTransform();
        }
        // A whole candidate fails after normal recording; the real renderer
        // and Input retain their successful old front together.
        if (self.fail_candidate) frame.failure = error.RejectedClickCandidate;
    }
    fn ordinary(ptr: *anyopaque, _: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.legacy += 1;
    }
    fn clicked(ptr: *anyopaque, window: z.Window, value: ui.ControlClick) ui.ClickOutcome {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.calls == self.counts.len) {
            self.fail(error.TooManyCallbacks);
            return .rejected;
        }
        const raw = window.pointerPressSnapshot(value.press, .up) catch |err| {
            self.fail(err);
            return .rejected;
        };
        if (raw.button != .primary or value.button != .primary) self.fail(error.WrongRawButton);
        self.counts[self.calls] = value.count;
        self.ids[self.calls] = value.id;
        self.calls += 1;
        if (self.case == .close_action) {
            self.captureRenderer() catch |err| self.fail(err);
            _ = window.destroy() catch |err| self.fail(err);
        }
        return if (self.case == .rejected_action) .rejected else .accepted;
    }
    fn queuePaintCheck(self: *Host) void {
        if ((self.phase == .front or self.phase == .failed_front) and !self.check_posted) {
            self.check_posted = true;
            self.app.post(.{ .context = self, .call = afterPaint }) catch |err| self.fail(err);
        }
    }
    fn pointerInput(ptr: *anyopaque, _: *ui.Context, ev: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (ev == .pointer_down) {
            self.raw_downs += 1;
            _ = self.window.pointerPressSnapshot(ev.pointer_down.press, .down) catch |err| self.fail(err);
            if (self.repaint_once) {
                self.repaint_once = false;
                Native.paint(self.window);
            }
        }
        return self.case == .consumed;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        // Compare the unwrapped error value, retaining the exact expected
        // failure. The independent Zig0.15.2 optional-error probe records why
        // the previous optional-to-optional comparison is not used here.
        const expected_error = if (value.err) |err| err == error.RejectedClickCandidate else false;
        if (self.fail_candidate and value.domain == .renderer and value.operation == .paint and expected_error) self.diagnostics += 1 else self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn message(ptr: *anyopaque, _: z.Window, kind: u32, _: usize, _: isize) ?isize {
        const self: *Host = @ptrCast(@alignCast(ptr));
        // This service runs before the real paint body. App.post executes the
        // check after that native callback completes, including failed/busy
        // attempts. A new GPU-ready paint supplies the next notification.
        if (builtin.os.tag == .windows and kind == c.WM_PAINT) self.queuePaintCheck();
        if (kind == checkpoint_message) {
            self.app.post(.{ .context = self, .call = checkStage }) catch |err| self.fail(err);
            return 0;
        }
        return null;
    }
    fn serviceDestroy(_: *anyopaque) void {}
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const context = self.context;
        self.context = null;
        self.closed += 1;
        if (context) |value| self.allocator.destroy(value);
        if (self.case == .close_action) self.app.quit();
    }
    fn start(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = self.window.nativeHandle();
            _ = c.SetFocus(hwnd);
            if (c.GetFocus() != hwnd) return self.fail(error.NativeFocusUnavailable);
        }
        Native.paint(self.window);
        // Cairo's explicit hidden draw is synchronous. There is no second
        // event loop, polling task or draw callback that submits business work.
        if (builtin.os.tag == .linux) self.queuePaintCheck();
    }
    fn afterPaint(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.check_posted = false;
        self.advanceAfterPaint() catch |err| self.fail(err);
    }
    fn advanceAfterPaint(self: *Host) !void {
        if (self.failure) |err| return err;
        const context = self.context orelse return error.ClosedBeforeFront;
        if (self.phase == .front) {
            // PresentationBusy keeps waiting for the existing gpu_wait-driven
            // next paint; this task never polls or reposts itself.
            if (context.frames == self.baseline_frames) return;
            try self.captureRenderer();
            self.baseline_frames = context.frames;
            self.baseline_front = context.input_state.clicks.?.state.front_serial;
            if (self.case == .rejected_frame) {
                self.fail_candidate = true;
                self.phase = .failed_front;
                Native.paint(self.window);
                if (builtin.os.tag == .linux) self.queuePaintCheck();
                return;
            }
            if (self.case == .stale_clear) {
                self.fail_candidate = true; // Even an incidental paint keeps the stale old front.
                try context.clearPointerClicks();
            }
            self.phase = .inputs;
            try self.queueInputs();
        } else if (self.phase == .failed_front and self.diagnostics != 0) {
            try std.testing.expectEqual(self.baseline_frames, context.frames);
            try std.testing.expectEqual(self.baseline_front, context.input_state.clicks.?.state.front_serial);
            self.phase = .inputs;
            try self.queueInputs();
        }
    }
    fn point(self: *const Host, second: bool) z.Point {
        if (self.case != .affine) return .{ .x = if (second) 45 else 13, .y = 15 };
        const x: f64 = (if (second) @as(f64, 35) else 5) + 2;
        const y: f64 = 5 + 3;
        const m = self.matrix;
        // Independently honor the public native-f32 forward coefficients;
        // never fetch expected coordinates from an actual Mapping table.
        return .{ .x = @floatCast(@as(f64, @as(f32, @floatCast(m.xx))) * x + @as(f64, @as(f32, @floatCast(m.xy))) * y + @as(f64, @as(f32, @floatCast(m.x0)))), .y = @floatCast(@as(f64, @as(f32, @floatCast(m.yx))) * x + @as(f64, @as(f32, @floatCast(m.yy))) * y + @as(f64, @as(f32, @floatCast(m.y0)))) };
    }
    fn queuePair(self: *Host, point_value: z.Point, tick: u32) !void {
        try Native.button(self.window, point_value, .down, tick);
        try Native.button(self.window, point_value, .up, tick + 1);
    }
    fn queueInputs(self: *Host) !void {
        self.repaint_once = self.case == .preinput_frame;
        const a = self.point(false);
        const b = self.point(true);
        switch (self.case) {
            .counts => {
                try self.queuePair(a, 10);
                try self.queuePair(b, 20);
                try self.queuePair(b, 30);
                try self.queuePair(b, 40);
            },
            .affine => {
                try self.queuePair(a, 10);
                try self.queuePair(b, 20);
                try self.queuePair(b, 30);
                // Inside the transformed AABB, outside its exact polygon.
                // First button's independently known AABB is approximately
                // [33.2,61.2] x [28.4,52.4], including offset(2,3). Its inverse
                // at (59,30) has y<0, outside local button y=[3,23).
                try self.queuePair(.{ .x = 59, .y = 30 }, 40);
                try self.queuePair(b, 50);
            },
            .close_action => try self.queuePair(a, 10),
            else => {
                try self.queuePair(a, 10);
                try self.queuePair(a, 20);
            },
        }
        try Native.checkpoint(self);
    }
    fn captureRenderer(self: *Host) !void {
        const context = self.context orelse return error.ContextGone;
        if (self.renderer == .gdi) {
            try std.testing.expect(context.gdi_frames > 0);
        } else if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) {
            const stats = context.gpu_renderer.stats();
            try std.testing.expect(context.gpu_frames > 0 and stats.presents > 0 and context.gdi_frames == 0 and context.fallbacks == 0);
            self.gpu_frames = context.gpu_frames;
            self.presents = stats.presents;
        } else return error.UnsupportedTestRenderer;
    }
    fn checkStage(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.check() catch |err| {
            self.fail(err);
            return;
        };
        self.phase = .done;
        self.app.quit();
    }
    fn check(self: *Host) !void {
        if (self.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 0), self.legacy);
        const expected: []const u8 = switch (self.case) {
            .counts => &.{ 1, 1, 2, 3 },
            .affine => &.{ 1, 1, 2, 1 },
            .rejected_frame => &.{ 1, 2 },
            .rejected_action => &.{ 1, 1 },
            .preinput_frame, .close_action => &.{1},
            .stale_clear, .consumed, .disabled => &.{},
        };
        try std.testing.expectEqualSlices(u8, expected, self.counts[0..self.calls]);
        const ids: []const u64 = if (self.case == .counts or self.case == .affine) &.{ 7, 8, 8, 8 } else &.{ 7, 7 };
        try std.testing.expectEqualSlices(u64, ids[0..self.calls], self.ids[0..self.calls]);
        if (self.case == .close_action) try std.testing.expect(self.context == null and self.closed == 1) else try self.captureRenderer();
    }
};

fn scenario(allocator: std.mem.Allocator, renderer: ui.RenderMode, case: Case) !void {
    var host: Host = .{ .allocator = allocator, .renderer = renderer, .case = case };
    // Its allocator context is independent of the heap Context and remains
    // alive through App.deinit and every event-local owner release.
    var workspace_allocator = std.testing.FailingAllocator.init(allocator, .{});
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic }, .icon_policy = .disabled });
    defer app.deinit();
    host.app = app;
    host.app_ready = true;
    host.window = try app.createWindow(.{ .width = 280, .height = 180, .native_pointer_clicks = true, .on_closed = .{ .context = &host, .notify = Host.onClosed } });
    if (builtin.os.tag == .windows) try host.window.setService(.{ .context = &host, .message = Host.message, .native_destroying = Host.serviceDestroy });
    const context = try allocator.create(ui.Context);
    host.context = context;
    context.* = ui.Context.init(&host, Host.draw, Host.ordinary);
    context.render_mode = renderer;
    try context.attach(host.window);
    if (case == .affine) try context.prepareTransforms(allocator, .{ .layers = .{ .size = try host.window.contentSize(), .max_depth = 3 }, .source_size = .{ .width = 100, .height = 80 } });
    try context.preparePointerClicks(workspace_allocator.allocator(), .{ .context = &host, .on_input = Host.pointerInput, .on_click = Host.clicked });
    host.targets = .{ try context.newClickTarget(7), try context.newClickTarget(8) };
    workspace_allocator.fail_index = workspace_allocator.alloc_index;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.post(.{ .context = &host, .call = Host.start });
    try app.run();
    watchdog.stop();
    if (host.failure) |err| return err;
    try std.testing.expect(!watchdog.expired);
    if (case == .close_action) try host.check(); // Other checks preceded quit while Context was live.
    try std.testing.expect(host.context == null and host.closed == 1);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectEqual(@as(usize, 1), workspace_allocator.allocations);
    try std.testing.expectEqual(@as(usize, 1), workspace_allocator.deallocations);
    try std.testing.expectEqual(workspace_allocator.allocated_bytes, workspace_allocator.freed_bytes);
    try std.testing.expect(!workspace_allocator.has_induced_failure);
    std.debug.print("registered native {s} renderer={s} actions={d} raw_downs={d} gpu_frames={d} presents={d} owner_allocs=1/frees=1 records=0\n", .{ @tagName(case), @tagName(renderer), host.calls, host.raw_downs, host.gpu_frames, host.presents });
}

fn isolatedWindows(renderer: ui.RenderMode) !void {
    var name: [96]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.RegisteredClicks.{d}", .{c.GetCurrentProcessId()});
    var wide: [96:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    const suffix: []const u16 = switch (renderer) {
        .gdi => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child --renderer gdi"),
        .hardware => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child --renderer hardware"),
        .warp => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child --renderer warp"),
        else => return error.UnsupportedTestRenderer,
    };
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
    // Only the parent test process waits. The child uses App's ordinary loop.
    if (c.WaitForSingleObject(process.hProcess, 120000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) return error.TestProcessFailed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var args = try init.args.iterateAllocator(allocator.allocator());
    defer args.deinit();
    _ = args.next();
    var child = false;
    var renderer: ui.RenderMode = .gdi;
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--desktop-child")) child = true else if (std.mem.eql(u8, flag, "--renderer")) {
            const value = args.next() orelse return error.InvalidArguments;
            renderer = if (std.mem.eql(u8, value, "gdi")) .gdi else if (std.mem.eql(u8, value, "hardware")) .hardware else if (std.mem.eql(u8, value, "warp")) .warp else return error.InvalidArguments;
        } else return error.InvalidArguments;
    }
    if (renderer != .gdi and (builtin.os.tag != .windows or !ui.capabilities.gpu)) return error.UnsupportedTestRenderer;
    if (builtin.os.tag == .windows and !child) return isolatedWindows(renderer);
    inline for (std.meta.tags(Case)) |case| {
        try scenario(allocator.allocator(), renderer, case);
        // scenario's App.deinit has now retired the four tracked application
        // resources too; Window/owner checks already ran while App was alive.
        if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
        if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) try std.testing.expectEqual(@as(u32, 0), zgpu_resource_count());
    }
}
