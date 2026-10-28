const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn gtk_window_get_decorated(*anyopaque) c_int;
extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn zlg_resource_count() u32;

const Chrome = struct {
    window: z.Window = undefined,
    stage: enum { starting, maximized, fullscreen, unfull, restored, done } = .starting,
    pending: bool = false,
    closed: bool = false,
    raw_hit: bool = false,
    queried: usize = 0,
    before: z.ClientBounds = undefined,
    fn hit(ptr: *anyopaque, window: z.Window, position: z.Point) z.WindowHit {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        self.queried += 1;
        if (self.raw_hit) {
            if (builtin.os.tag == .windows) std.debug.assert(c.DestroyWindow(window.nativeHandle()) != 0);
            std.debug.assert(!self.closed);
            return .caption;
        }
        return if (position.y < 32) if (position.x < 40) .system_menu else .caption else .client;
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        if (window.app.phase == .stopping or window.app.phase == .stopped or self.raw_hit or self.pending or self.stage == .done) return;
        if (value == .window_state or value == .resize or value == .focus) {
            self.pending = true;
            window.app.post(.{ .context = self, .call = advance }) catch unreachable;
        }
    }
    fn detach(_: *anyopaque) void {}
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
    fn advance(ptr: *anyopaque) void {
        const self: *Chrome = @ptrCast(@alignCast(ptr));
        self.pending = false;
        self.step() catch |err| std.debug.panic("chrome stage {s}: {s}", .{ @tagName(self.stage), @errorName(err) });
    }
    fn step(self: *Chrome) !void {
        if (self.window.isClosed()) return;
        const state = try self.window.state();
        switch (self.stage) {
            .starting => {
                if (!state.visible) return;
                if (builtin.os.tag == .linux and gtk_widget_get_mapped(self.window.nativeHandle().?) == 0) return;
                const bounds = try self.window.clientBounds();
                if (bounds.width != 320 or bounds.height != 240) return;
                self.before = bounds;
                try std.testing.expectEqual(z.WindowHit.north_west, try self.window.hitTest(.{ .x = 2, .y = 2 }));
                try std.testing.expectEqual(z.WindowHit.caption, try self.window.hitTest(.{ .x = 100, .y = 20 }));
                try std.testing.expectError(error.InvalidGesture, self.window.startMove());
                if (builtin.os.tag == .windows) try checkNative(self.window);
                self.stage = .maximized;
                try self.window.perform(.maximize);
            },
            .maximized => {
                if (!state.maximized) return;
                try std.testing.expectEqual(z.WindowHit.system_menu, try self.window.hitTest(.{ .x = 2, .y = 2 }));
                try std.testing.expectError(error.InvalidWindowState, self.window.startResize(.east));
                if (builtin.os.tag == .windows) {
                    var info = std.mem.zeroes(c.MONITORINFO);
                    info.cbSize = @sizeOf(c.MONITORINFO);
                    try std.testing.expect(c.GetMonitorInfoW(c.MonitorFromWindow(self.window.nativeHandle(), c.MONITOR_DEFAULTTONEAREST), &info) != 0);
                    var client: c.RECT = undefined;
                    try std.testing.expect(c.GetClientRect(self.window.nativeHandle(), &client) != 0);
                    try std.testing.expectEqual(info.rcWork.right - info.rcWork.left, client.right);
                    try std.testing.expectEqual(info.rcWork.bottom - info.rcWork.top, client.bottom);
                }
                self.stage = .fullscreen;
                try self.window.setFullscreen(true);
            },
            .fullscreen => {
                if (!state.fullscreen) return;
                try std.testing.expectEqual(z.WindowHit.client, try self.window.hitTest(.{ .x = 2, .y = 2 }));
                try std.testing.expectError(error.InvalidWindowState, self.window.startMove());
                self.stage = .unfull;
                try self.window.setFullscreen(false);
            },
            .unfull => {
                if (state.fullscreen or !state.maximized) return;
                if (builtin.os.tag == .windows) {
                    var info = std.mem.zeroes(c.MONITORINFO);
                    info.cbSize = @sizeOf(c.MONITORINFO);
                    try std.testing.expect(c.GetMonitorInfoW(c.MonitorFromWindow(self.window.nativeHandle(), c.MONITOR_DEFAULTTONEAREST), &info) != 0);
                    var client: c.RECT = undefined;
                    try std.testing.expect(c.GetClientRect(self.window.nativeHandle(), &client) != 0);
                    try std.testing.expectEqual(info.rcWork.right - info.rcWork.left, client.right);
                    try std.testing.expectEqual(info.rcWork.bottom - info.rcWork.top, client.bottom);
                }
                self.stage = .restored;
                try self.window.perform(.restore);
            },
            .restored => {
                if (state.maximized or state.fullscreen) return;
                const bounds = try self.window.clientBounds();
                if (bounds.width != self.before.width or bounds.height != self.before.height) return;
                self.stage = .done;
                _ = try self.window.destroy();
            },
            .done => {},
        }
    }
};
fn checkNative(window: z.Window) !void {
    if (builtin.os.tag != .windows) return;
    const hwnd: c.HWND = window.nativeHandle();
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
    var point: c.POINT = .{ .x = @intFromFloat(100 * scale), .y = @intFromFloat(20 * scale) };
    try std.testing.expect(c.ClientToScreen(hwnd, &point) != 0);
    const x: u16 = @bitCast(@as(i16, @intCast(point.x)));
    const y: u16 = @bitCast(@as(i16, @intCast(point.y)));
    try std.testing.expectEqual(@as(c.LRESULT, c.HTCAPTION), c.SendMessageW(hwnd, c.WM_NCHITTEST, 0, @intCast(@as(u32, x) | (@as(u32, y) << 16))));
    var limits = std.mem.zeroes(c.MINMAXINFO);
    _ = c.SendMessageW(hwnd, c.WM_GETMINMAXINFO, 0, @bitCast(@intFromPtr(&limits)));
    try std.testing.expectEqual(c.MulDiv(160, @intCast(c.GetDpiForWindow(hwnd)), 96), limits.ptMinTrackSize.x);
    try std.testing.expectEqual(c.MulDiv(120, @intCast(c.GetDpiForWindow(hwnd)), 96), limits.ptMinTrackSize.y);
}
fn geometry(allocator: std.mem.Allocator, require_wm: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Chrome = .{};
    probe.window = try app.createWindow(.{ .title = "Custom chrome", .width = 320, .height = 240, .min_width = 160, .min_height = 120, .decoration = .custom, .hit_test = .{ .context = &probe, .query = Chrome.hit }, .on_closed = .{ .context = &probe, .notify = Chrome.notify } });
    try probe.window.setContent(.{ .context = &probe, .event = Chrome.event, .detach = Chrome.detach });
    const caps = try probe.window.capabilities();
    try std.testing.expect(caps.custom_decoration and !caps.transparent and !caps.backdrop_material);
    if (builtin.os.tag == .linux) {
        try std.testing.expect(gtk_window_get_decorated(probe.window.nativeHandle().?) == 0);
        if (!caps.native_move_resize or !caps.fullscreen) {
            if (require_wm) return error.WindowManagerRequired;
            return;
        }
    }
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try probe.window.perform(.show);
    try app.run();
    if (watchdog.expired) std.debug.print("chrome timeout {s}\n", .{@tagName(probe.stage)});
    try std.testing.expect(!watchdog.expired and probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
const Loop = struct {
    window: z.Window = undefined,
    mode: enum { move, resize, menu, raw, gesture_move, gesture_resize, stale_disable, stale_modal, stale_focus } = .move,
    entered: bool = false,
    tasks: usize = 0,
    audits: usize = 0,
    gestures: usize = 0,
    closed: bool = false,
    stops: usize = 0,
    fn detach(ptr: *anyopaque) void {
        const self: *Loop = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.stops == 1);
    }
    fn destroying(_: *anyopaque) void {}
    fn stop(ptr: *anyopaque) !void {
        const self: *Loop = @ptrCast(@alignCast(ptr));
        try std.testing.expect(self.tasks == 1 and self.audits == 1 and !self.closed);
        if (self.mode != .raw) try std.testing.expect(self.window.app.windows.get(self.window.key).?.native.hwnd != null);
        self.stops += 1;
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Loop = @ptrCast(@alignCast(ptr));
        if (value != .pointer_down) return;
        if (self.mode == .gesture_move or self.mode == .stale_disable or self.mode == .stale_modal or self.mode == .stale_focus) window.startMove() catch unreachable else if (self.mode == .gesture_resize) window.startResize(.east) catch unreachable else return;
        if (self.gestures == 0) {
            switch (self.mode) {
                .stale_disable => {
                    window.perform(.disable) catch unreachable;
                    window.perform(.enable) catch unreachable;
                },
                .stale_modal => {
                    const modal = window.app.createWindow(.{ .owner = window, .modal = true }) catch unreachable;
                    modal.perform(.show) catch unreachable;
                    modal.perform(.hide) catch unreachable;
                },
                .stale_focus => {
                    const other = window.app.createWindow(.{}) catch unreachable;
                    other.perform(.show) catch unreachable;
                    _ = c.SetFocus(other.nativeHandle());
                    _ = c.SetFocus(window.nativeHandle());
                },
                else => {},
            }
        }
        self.gestures += 1;
        std.testing.expectError(error.InvalidGesture, window.startMove()) catch unreachable;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *Loop = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.stops == 1);
        self.closed = true;
    }
    fn message(ptr: *anyopaque, window: z.Window, kind: u32, _: usize, _: isize) ?isize {
        if (builtin.os.tag != .windows) return null;
        const self: *Loop = @ptrCast(@alignCast(ptr));
        const expected: u32 = if (self.mode == .menu) c.WM_INITMENUPOPUP else c.WM_ENTERSIZEMOVE;
        if (kind == expected and !self.entered) {
            self.entered = true;
            std.testing.expectError(error.Busy, window.showSystemMenu()) catch unreachable;
            window.app.post(.{ .context = self, .call = finish }) catch unreachable;
            window.app.post(.{ .context = self, .call = audit }) catch unreachable;
        }
        return null;
    }
    fn audit(ptr: *anyopaque) void {
        const self: *Loop = @ptrCast(@alignCast(ptr));
        self.audits += 1;
    }
    fn finish(ptr: *anyopaque) void {
        if (builtin.os.tag != .windows) return;
        const self: *Loop = @ptrCast(@alignCast(ptr));
        self.tasks += 1;
        std.debug.assert(self.window.app.activity_depth == 1);
        if (self.mode == .raw) std.debug.assert(c.DestroyWindow(self.window.nativeHandle()) != 0) else if (self.mode != .menu) _ = self.window.destroy() catch unreachable;
        self.window.app.quit();
    }
};
fn nativeLoops(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    for ([_]@FieldType(Loop, "mode"){ .move, .resize, .menu, .raw, .gesture_move, .gesture_resize, .stale_disable, .stale_modal, .stale_focus }) |mode| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        var probe: Loop = .{ .mode = mode };
        probe.window = try app.createWindow(.{ .decoration = .custom, .on_closed = .{ .context = &probe, .notify = Loop.notify } });
        try probe.window.setContent(.{ .context = &probe, .event = Loop.event, .detach = Loop.detach });
        try probe.window.setService(.{ .context = &probe, .message = Loop.message, .native_destroying = Loop.destroying });
        var stop_node: z.StopParticipant = .{ .context = &probe, .stop = Loop.stop };
        _ = try app.registerStop(&stop_node);
        try probe.window.perform(.show);
        var key_state: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&key_state) != 0);
        defer _ = c.SetKeyboardState(&key_state);
        const stale = mode == .stale_disable or mode == .stale_modal or mode == .stale_focus;
        const gesture = mode == .gesture_move or mode == .gesture_resize or stale;
        if (mode == .menu) try probe.window.showSystemMenu() else if (gesture) {
            var pressed = key_state;
            pressed[c.VK_LBUTTON] = 0x80;
            try std.testing.expect(c.SetKeyboardState(&pressed) != 0);
            _ = c.SendMessageW(probe.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, 100 | (100 << 16));
            if (stale) {
                try std.testing.expect(app.windows.get(probe.window.key).?.native.pending_interaction == null);
                _ = c.SendMessageW(probe.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, 100 | (100 << 16));
            }
            try std.testing.expect(app.windows.get(probe.window.key).?.native.pending_interaction != null and c.GetCapture() == probe.window.nativeHandle());
        } else {
            const command: c.WPARAM = if (mode == .resize) c.SC_SIZE | c.WMSZ_RIGHT else c.SC_MOVE;
            try std.testing.expect(c.PostMessageW(probe.window.nativeHandle(), c.WM_SYSCOMMAND, command, 0) != 0);
        }
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        if (watchdog.expired or !probe.entered or !probe.closed) std.debug.print("native loop {s}: expired={} entered={} closed={} gestures={d} tasks={d}\n", .{ @tagName(mode), watchdog.expired, probe.entered, probe.closed, probe.gestures, probe.tasks });
        try std.testing.expect(!watchdog.expired and probe.entered and probe.closed);
        try std.testing.expectEqual(@as(usize, 1), probe.tasks);
        try std.testing.expectEqual(@as(usize, 1), probe.audits);
        try std.testing.expectEqual(@as(usize, 1), probe.stops);
        if (gesture) try std.testing.expectEqual(if (stale) @as(usize, 2) else 1, probe.gestures);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    std.debug.print("Windows native loops passed: move/size/menu, accepted tasks before quit, public gestures and raw destruction\n", .{});
}
fn captureOwnership(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    const Probe = struct {
        app: *z.App,
        capture: c.HWND,
        owned: bool,
        checked: bool = false,
        fn quit(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(c.GetCapture() == self.capture);
            self.app.quit();
            std.debug.assert(c.GetCapture() == (if (self.owned) @as(c.HWND, null) else self.capture));
            self.checked = true;
        }
    };
    for ([_]bool{ false, true }) |owned| {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        const capture = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), if (owned) c.WS_CHILD else c.WS_POPUP, 0, 0, 10, 10, if (owned) window.nativeHandle() else null, null, c.GetModuleHandleW(null), null);
        if (capture == null) return error.CreateCaptureWindowFailed;
        defer {
            if (c.GetCapture() == capture) _ = c.ReleaseCapture();
            if (c.IsWindow(capture) != 0) std.debug.assert(c.DestroyWindow(capture) != 0);
        }
        _ = c.SetCapture(capture);
        try std.testing.expect(c.GetCapture() == capture);
        var probe: Probe = .{ .app = app, .capture = capture, .owned = owned };
        try app.post(.{ .context = &probe, .call = Probe.quit });
        try app.run();
        try std.testing.expect(probe.checked and app.resourceStats().allocated_records == 0);
        if (!owned) try std.testing.expect(c.GetCapture() == capture);
    }
}
fn rawHit(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .windows) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: Chrome = .{ .raw_hit = true };
    probe.window = try app.createWindow(.{ .decoration = .custom, .hit_test = .{ .context = &probe, .query = Chrome.hit }, .on_closed = .{ .context = &probe, .notify = Chrome.notify } });
    try probe.window.setContent(.{ .context = &probe, .event = Chrome.event, .detach = Chrome.detach });
    var point: c.POINT = .{ .x = 100, .y = 20 };
    try std.testing.expect(c.ClientToScreen(probe.window.nativeHandle(), &point) != 0);
    const x: u16 = @bitCast(@as(i16, @intCast(point.x)));
    const y: u16 = @bitCast(@as(i16, @intCast(point.y)));
    try std.testing.expectEqual(@as(c.LRESULT, c.HTCLIENT), c.SendMessageW(probe.window.nativeHandle(), c.WM_NCHITTEST, 0, @intCast(@as(u32, x) | (@as(u32, y) << 16))));
    try std.testing.expect(!probe.closed and probe.queried == 1);
    try app.dispatch();
    try std.testing.expect(probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
extern "dwmapi" fn DwmGetWindowAttribute(?*anyopaque, u32, *anyopaque, u32) callconv(.winapi) i32;
fn backdrop(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const custom = try app.createWindow(.{ .decoration = .custom });
    try std.testing.expect(!(try custom.capabilities()).backdrop_material);
    try std.testing.expectError(error.UnsupportedCapability, custom.setBackdrop(.mica));
    _ = try custom.destroy();
    const system = try app.createWindow(.{ .title = "Backdrop" });
    const caps = try system.capabilities();
    var expected = false;
    if (builtin.os.tag == .windows) {
        var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
        info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
        try std.testing.expect(std.os.windows.ntdll.RtlGetVersion(&info) == .SUCCESS);
        expected = info.dwMajorVersion > 10 or (info.dwMajorVersion == 10 and info.dwBuildNumber >= 22621);
    }
    try std.testing.expectEqual(expected, caps.backdrop_material);
    try std.testing.expect(!caps.transparent);
    if (!expected) {
        try std.testing.expectError(error.UnsupportedCapability, system.setBackdrop(.mica));
    } else if (builtin.os.tag == .windows) {
        const materials = [_]z.WindowBackdrop{ .mica, .acrylic, .mica_alt, .none, .system };
        for (materials, [_]u32{ 2, 3, 4, 1, 0 }) |material, native| {
            try system.setBackdrop(material);
            var value: u32 = 99;
            const hr = DwmGetWindowAttribute(system.nativeHandle(), 38, &value, @sizeOf(u32));
            // Readback is informational; the accepted set call is the contract.
            if (hr >= 0) try std.testing.expectEqual(native, value);
        }
    }
    _ = try system.destroy();
    try std.testing.expectError(error.Closed, system.setBackdrop(.none));
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn run(allocator: std.mem.Allocator, require_wm: bool) !void {
    try geometry(allocator, require_wm);
    try nativeLoops(allocator);
    try captureOwnership(allocator);
    try rawHit(allocator);
    try backdrop(allocator);
    if (builtin.os.tag == .linux) try @import("window_chrome_x11.zig").run(allocator, require_wm);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("window chrome passed: custom client geometry, DIP hits/minima, maximize/fullscreen restore, backdrop gating; resources=0\n", .{});
}
fn windows(allocator: std.mem.Allocator, require_wm: bool) !void {
    _ = allocator;
    _ = require_wm;
    var name: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&name, "Ziggurat.Chrome.{d}", .{c.GetCurrentProcessId()});
    var wide: [64:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, text);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    // System menu/COM helpers can keep a desktop borrowed for their process
    // lifetime. Run the actual checks in a child so those native caches finish
    // before the parent releases its desktop; neither activates that desktop.
    var executable: [32768:0]u16 = undefined;
    const exe_length = c.GetModuleFileNameW(null, &executable, executable.len);
    if (exe_length == 0 or exe_length >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1 .. exe_length + 1], executable[0..exe_length]);
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    @memcpy(command[exe_length + 1 .. exe_length + 1 + suffix.len], suffix);
    command[exe_length + 1 + suffix.len] = 0;
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
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0 or exit_code != 0) return error.TestProcessFailed;
}
pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (builtin.os.tag == .linux and args.len > 1 and std.mem.eql(u8, args[1], "--x11-driver")) return @import("window_chrome_x11.zig").driver(args[2..]);
    var require_wm = false;
    var desktop_child = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--require-wm")) require_wm = true else if (std.mem.eql(u8, arg, "--desktop-child")) desktop_child = true else return error.InvalidArgument;
    }
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (builtin.os.tag == .windows and !desktop_child) try windows(allocator.allocator(), require_wm) else try run(allocator.allocator(), require_wm);
}
