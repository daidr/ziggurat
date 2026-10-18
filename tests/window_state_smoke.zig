const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

fn checkBounds(expected: z.ClientBounds, actual: z.ClientBounds) !void {
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    if (expected.position) |position| try std.testing.expectEqualDeep(position, actual.position.?);
}

const Reentry = struct {
    callbacks: usize = 0,
    detached: usize = 0,
    closed: usize = 0,
    raw_close: bool = false,
    fn event(ptr: *anyopaque, window: z.Window, event_value: z.Event) void {
        if (event_value != .resize) return;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.callbacks += 1;
        std.testing.expectError(error.Busy, window.setFullscreen(true)) catch unreachable;
        std.testing.expectError(error.Busy, window.setAlwaysOnTop(true)) catch unreachable;
        std.testing.expectError(error.Busy, window.resize(500, 300)) catch unreachable;
        if (builtin.os.tag == .windows and self.raw_close) {
            std.debug.assert(c.DestroyWindow(@ptrCast(window.nativeHandle())) != 0);
            std.debug.assert(self.detached == 0 and self.closed == 0);
        }
    }
    fn detach(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.detached += 1;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.detached == 1);
        self.closed += 1;
    }
};

fn windowsSmoke() !void {
    var allocator_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(allocator_state.deinit() == .ok);
    const app = try z.App.init(allocator_state.allocator());
    defer app.deinit();
    var probe: Reentry = .{};
    const window = try app.createWindow(.{ .width = 720, .height = 480, .min_width = 200, .min_height = 100, .on_closed = .{ .context = &probe, .notify = Reentry.notify } });
    try window.setContent(.{ .context = &probe, .event = Reentry.event, .detach = Reentry.detach });
    try std.testing.expectEqualDeep(z.WindowCapabilities{ .client_position = true, .fullscreen = true, .always_on_top = true, .owned_windows = true, .modal_windows = true, .custom_decoration = true, .native_move_resize = true, .system_menu = true }, try window.capabilities());
    const target: z.ClientBounds = .{ .position = .{ .x = 111, .y = 139 }, .width = 601, .height = 399 };
    try window.setClientBounds(target);
    try checkBounds(target, try window.clientBounds());
    try window.resize(640, 420);
    const initial = try window.clientBounds();
    const hwnd: c.HWND = @ptrCast(window.nativeHandle());
    const initial_style = c.GetWindowLongPtrW(hwnd, c.GWL_STYLE);
    for (0..4) |_| {
        try window.setFullscreen(true);
        try window.setFullscreen(true);
        try std.testing.expect((try window.state()).fullscreen and !(try window.state()).visible);
        try std.testing.expect(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE) & (c.WS_CAPTION | c.WS_THICKFRAME) == 0);
        var monitor = std.mem.zeroes(c.MONITORINFO);
        monitor.cbSize = @sizeOf(c.MONITORINFO);
        try std.testing.expect(c.GetMonitorInfoW(c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST), &monitor) != 0);
        var rect: c.RECT = undefined;
        try std.testing.expect(c.GetWindowRect(hwnd, &rect) != 0);
        try std.testing.expectEqualDeep(monitor.rcMonitor, rect);
        try std.testing.expectError(error.InvalidWindowState, window.resize(400, 200));
        try std.testing.expectError(error.InvalidWindowState, window.perform(.maximize));
        try window.setAlwaysOnTop(true);
        try std.testing.expect((try window.state()).always_on_top);
        try window.setFullscreen(false);
        try window.setFullscreen(false);
        try std.testing.expect(!(try window.state()).fullscreen and !(try window.state()).visible);
        try std.testing.expect((try window.state()).always_on_top);
        try std.testing.expectEqual(initial_style, c.GetWindowLongPtrW(hwnd, c.GWL_STYLE));
        try checkBounds(initial, try window.clientBounds());
        try window.setAlwaysOnTop(false);
        try std.testing.expect(!(try window.state()).always_on_top);
    }
    try std.testing.expectError(error.InvalidGeometry, window.setClientBounds(.{ .position = .{ .x = std.math.maxInt(i32), .y = 0 }, .width = 600, .height = 400 }));
    try checkBounds(initial, try window.clientBounds());
    probe.raw_close = true;
    try std.testing.expectError(error.Closed, window.resize(650, 430));
    try std.testing.expectEqual(@as(usize, 0), probe.closed);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), probe.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectError(error.Closed, window.setAlwaysOnTop(false));
    const placement_window = try app.createWindow(.{ .width = 640, .height = 420 });
    const placement_hwnd: c.HWND = @ptrCast(placement_window.nativeHandle());
    const menu = c.CreateMenu();
    try std.testing.expect(menu != null);
    defer std.debug.assert(c.DestroyMenu(menu) != 0);
    try std.testing.expect(c.AppendMenuW(menu, c.MF_STRING, 1, std.unicode.utf8ToUtf16LeStringLiteral("State test")) != 0);
    try std.testing.expect(c.SetMenu(placement_hwnd, menu) != 0);
    try placement_window.setClientBounds(initial);
    for ([_]z.WindowAction{ .maximize, .minimize }) |action| {
        try placement_window.perform(action);
        const before = try placement_window.state();
        try std.testing.expect(if (action == .maximize) before.maximized else before.minimized);
        try placement_window.setFullscreen(true);
        try std.testing.expect((try placement_window.state()).fullscreen);
        try std.testing.expect(!(try placement_window.state()).minimized);
        var monitor = std.mem.zeroes(c.MONITORINFO);
        monitor.cbSize = @sizeOf(c.MONITORINFO);
        try std.testing.expect(c.GetMonitorInfoW(c.MonitorFromWindow(placement_hwnd, c.MONITOR_DEFAULTTONEAREST), &monitor) != 0);
        var client: c.RECT = undefined;
        try std.testing.expect(c.GetClientRect(placement_hwnd, &client) != 0);
        try std.testing.expectEqual(monitor.rcMonitor.right - monitor.rcMonitor.left, client.right);
        try std.testing.expectEqual(monitor.rcMonitor.bottom - monitor.rcMonitor.top, client.bottom);
        try placement_window.setFullscreen(false);
        try std.testing.expect(c.GetMenu(placement_hwnd) == menu);
        const after = try placement_window.state();
        try std.testing.expectEqual(before.maximized, after.maximized);
        try std.testing.expectEqual(before.minimized, after.minimized);
        try placement_window.perform(.restore);
        try checkBounds(initial, try placement_window.clientBounds());
    }
    try placement_window.perform(.maximize);
    try placement_window.perform(.hide);
    try placement_window.setFullscreen(true);
    try std.testing.expect(!(try placement_window.state()).visible);
    try placement_window.setFullscreen(false);
    try std.testing.expect((try placement_window.state()).maximized and !(try placement_window.state()).visible);
    try placement_window.perform(.restore);
    try checkBounds(initial, try placement_window.clientBounds());
    try placement_window.perform(.minimize);
    try placement_window.perform(.hide);
    try std.testing.expectError(error.InvalidWindowState, placement_window.setFullscreen(true));
    try std.testing.expect(!(try placement_window.state()).visible and (try placement_window.state()).minimized);
    try std.testing.expect(c.SetMenu(placement_hwnd, null) != 0);
    _ = try placement_window.destroy();
    std.debug.print("window state passed: native client bounds, normal/maximized/minimized fullscreen restore, topmost, hidden visibility, callback reentry and raw close\n", .{});
}

fn isolatedWindowsSmoke() !void {
    var name_bytes: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_bytes, "Ziggurat.WindowState.{d}", .{c.GetCurrentProcessId()});
    var name_wide: [64:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&name_wide, name);
    name_wide[length] = 0;
    const previous = c.GetThreadDesktop(c.GetCurrentThreadId());
    const desktop = c.CreateDesktopW(&name_wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    if (c.SetThreadDesktop(desktop) == 0) return error.SetThreadDesktopFailed;
    defer std.debug.assert(c.SetThreadDesktop(previous) != 0);
    // This desktop is never activated; even maximize/minimize tests stay hidden.
    try windowsSmoke();
}

extern fn gtk_widget_get_mapped(*anyopaque) c_int;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn gtk_window_fullscreen(*anyopaque) void;
extern fn gtk_window_unfullscreen(*anyopaque) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_display(*anyopaque) *anyopaque;
extern fn gtk_widget_get_window(*anyopaque) *anyopaque;
extern fn gdk_display_get_monitor_at_window(*anyopaque, *anyopaque) ?*anyopaque;
const MonitorRect = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern fn gdk_monitor_get_geometry(*anyopaque, *MonitorRect) void;

fn monitorBounds(window: z.Window) !z.ClientBounds {
    const widget = window.nativeHandle().?;
    const monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(widget), gtk_widget_get_window(widget)) orelse return error.MonitorUnavailable;
    var rect: MonitorRect = undefined;
    gdk_monitor_get_geometry(monitor, &rect);
    return .{ .position = .{ .x = rect.x, .y = rect.y }, .width = @intCast(rect.width), .height = @intCast(rect.height) };
}

const LinuxProbe = struct {
    window: z.Window = undefined,
    stage: enum { mapped, geometry, above, enter, leave, maximizing, max_enter, max_leave, normal_after_max, minimizing, min_enter, min_leave, normal_after_min, external_enter, external_leave, framework_enter, external_exit, reassert_enter, reassert_leave, clear, closing, done } = .mapped,
    pending: bool = false,
    detaches: usize = 0,
    closed: usize = 0,
    target: z.ClientBounds = .{ .position = .{ .x = 91, .y = 117 }, .width = 601, .height = 399 },
    fullscreen_bounds: z.ClientBounds = undefined,
    fn schedule(self: *@This()) void {
        if (self.pending or self.window.isClosed()) return;
        self.pending = true;
        self.window.app.post(.{ .context = self, .call = advance }) catch unreachable;
    }
    fn event(ptr: *anyopaque, _: z.Window, event_value: z.Event) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (event_value == .resize or event_value == .window_state) self.schedule();
    }
    fn detach(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.detaches += 1;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.detaches == 1);
        self.closed += 1;
        if (self.stage == .closing) self.stage = .done;
    }
    fn advance(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.pending = false;
        self.step() catch |err| std.debug.panic("window state stage {s}: {s}", .{ @tagName(self.stage), @errorName(err) });
    }
    fn matches(self: *@This(), bounds: z.ClientBounds) bool {
        if (bounds.width != self.target.width or bounds.height != self.target.height) return false;
        if (self.target.position) |p| return if (bounds.position) |actual| std.meta.eql(p, actual) else false;
        return true;
    }
    fn step(self: *@This()) !void {
        if (self.window.isClosed()) return;
        const state = try self.window.state();
        const bounds = try self.window.clientBounds();
        switch (self.stage) {
            .mapped => {
                if (gtk_widget_get_mapped(self.window.nativeHandle().?) == 0) return;
                self.stage = .geometry;
                try self.window.setClientBounds(self.target);
            },
            .geometry => {
                if (!self.matches(bounds)) return;
                self.stage = .above;
                try self.window.setAlwaysOnTop(true);
                try std.testing.expect((try self.window.state()).always_on_top_requested);
            },
            .above => {
                if (!state.always_on_top) return;
                self.stage = .enter;
                try self.window.setFullscreen(true);
                try std.testing.expect((try self.window.state()).fullscreen_requested);
            },
            .enter => {
                // WM state and ConfigureNotify are independent acknowledgements.
                if (!state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                try std.testing.expectError(error.InvalidWindowState, self.window.resize(800, 600));
                try std.testing.expectError(error.InvalidWindowState, self.window.perform(.restore));
                self.stage = .leave;
                try self.window.setFullscreen(false);
                try std.testing.expect(!(try self.window.state()).fullscreen_requested);
            },
            .leave => {
                if (state.fullscreen or !self.matches(bounds)) return;
                try std.testing.expect(state.always_on_top);
                self.stage = .maximizing;
                try self.window.perform(.maximize);
            },
            .maximizing => {
                if (!state.maximized) return;
                self.stage = .max_enter;
                try self.window.setFullscreen(true);
            },
            .max_enter => {
                if (!state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                self.stage = .max_leave;
                try self.window.setFullscreen(false);
            },
            .max_leave => {
                if (state.fullscreen or !state.maximized) return;
                self.stage = .normal_after_max;
                try self.window.perform(.restore);
            },
            .normal_after_max => {
                if (state.maximized or !self.matches(bounds)) return;
                self.stage = .minimizing;
                try self.window.perform(.minimize);
            },
            .minimizing => {
                if (!state.minimized) return;
                self.stage = .min_enter;
                try self.window.setFullscreen(true);
            },
            .min_enter => {
                if (state.minimized or !state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                self.stage = .min_leave;
                try self.window.setFullscreen(false);
            },
            .min_leave => {
                if (state.fullscreen or !state.minimized) return;
                self.stage = .normal_after_min;
                try self.window.perform(.restore);
            },
            .normal_after_min => {
                if (state.minimized or !self.matches(bounds)) return;
                self.stage = .external_enter;
                gtk_window_fullscreen(self.window.nativeHandle().?);
            },
            .external_enter => {
                if (!state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                try std.testing.expect(!state.fullscreen_requested);
                self.stage = .external_leave;
                try self.window.setFullscreen(false);
            },
            .external_leave => {
                if (state.fullscreen or !self.matches(bounds)) return;
                self.stage = .framework_enter;
                try self.window.setFullscreen(true);
            },
            .framework_enter => {
                if (!state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                self.stage = .external_exit;
                gtk_window_unfullscreen(self.window.nativeHandle().?);
            },
            .external_exit => {
                if (state.fullscreen) return;
                try std.testing.expect(state.fullscreen_requested);
                self.stage = .reassert_enter;
                try self.window.setFullscreen(true);
            },
            .reassert_enter => {
                if (!state.fullscreen or !std.meta.eql(self.fullscreen_bounds, bounds)) return;
                self.stage = .reassert_leave;
                try self.window.setFullscreen(false);
            },
            .reassert_leave => {
                if (state.fullscreen or !self.matches(bounds)) return;
                self.stage = .clear;
                try self.window.setAlwaysOnTop(false);
            },
            .clear => {
                if (state.always_on_top) return;
                try checkBounds(self.target, bounds);
                self.stage = .closing;
                // Native destruction in a callback must defer final notifications.
                const scope = self.window.beginCallback().?;
                gtk_widget_destroy(self.window.nativeHandle().?);
                try std.testing.expectEqual(@as(usize, 0), self.closed);
                scope.end();
            },
            .closing, .done => {},
        }
    }
};

fn linuxSmoke(require_wm: bool) !void {
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    {
        var allocator_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
        defer std.debug.assert(allocator_state.deinit() == .ok);
        const app = try z.App.init(allocator_state.allocator());
        defer app.deinit();
        var probe: LinuxProbe = .{};
        probe.window = try app.createWindow(.{ .width = 400, .height = 300, .on_closed = .{ .context = &probe, .notify = LinuxProbe.notify } });
        try probe.window.setContent(.{ .context = &probe, .event = LinuxProbe.event, .detach = LinuxProbe.detach });
        const caps = try probe.window.capabilities();
        if (!caps.fullscreen or !caps.always_on_top) {
            if (require_wm) return error.WindowManagerRequired;
            if (!caps.fullscreen) try std.testing.expectError(error.UnsupportedCapability, probe.window.setFullscreen(true));
            if (!caps.always_on_top) try std.testing.expectError(error.UnsupportedCapability, probe.window.setAlwaysOnTop(true));
            if (!caps.client_position) {
                try std.testing.expect((try probe.window.clientBounds()).position == null);
                try std.testing.expectError(error.UnsupportedCapability, probe.window.setClientBounds(probe.target));
            }
            try std.testing.expect(!(try probe.window.state()).fullscreen_requested);
            // This mode intentionally verifies capability failure, not WM state changes.
            _ = try probe.window.destroy();
            std.debug.print("window state passed: unsupported compositor policy (position={} fullscreen={} topmost={})\n", .{ caps.client_position, caps.fullscreen, caps.always_on_top });
        } else {
            if (!caps.client_position) probe.target.position = null;
            probe.fullscreen_bounds = try monitorBounds(probe.window);
            if (!caps.client_position) probe.fullscreen_bounds.position = null;
            var watchdog: Watchdog = .{ .app = app };
            try watchdog.start();
            defer watchdog.stop();
            probe.window.show();
            try app.run();
            if (watchdog.expired) std.debug.print("timed out in {s}\n", .{@tagName(probe.stage)});
            try std.testing.expect(!watchdog.expired);
            try std.testing.expectEqual(@as(usize, 1), probe.closed);
            try std.testing.expectEqual(@FieldType(LinuxProbe, "stage").done, probe.stage);
            std.debug.print("window state passed: WM-observed bounds, normal/maximized/minimized fullscreen restore, external WM changes, topmost and callback close\n", .{});
        }
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var require_wm = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--require-wm")) require_wm = true else return error.InvalidArgument;
    }
    switch (builtin.os.tag) {
        .windows => try isolatedWindowsSmoke(),
        .linux => try linuxSmoke(require_wm),
        else => return error.UnsupportedPlatform,
    }
}
