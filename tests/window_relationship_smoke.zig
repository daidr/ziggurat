const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_window_get_transient_for(*anyopaque) ?*anyopaque;
extern fn gtk_window_get_modal(*anyopaque) c_int;
extern fn gtk_window_get_group(*anyopaque) *anyopaque;
extern fn gtk_widget_get_sensitive(*anyopaque) c_int;
extern fn gtk_widget_destroy(*anyopaque) void;
extern fn zlg_resource_count() u32;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_grab_add(*anyopaque) void;
extern fn gtk_grab_remove(*anyopaque) void;
extern fn gtk_window_group_get_current_grab(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };

fn blockedPointer(blocked: z.Window, allowed: z.Window) !void {
    if (builtin.os.tag == .windows) {
        const focus_before = c.GetFocus();
        _ = c.SetCapture(allowed.nativeHandle());
        defer _ = c.ReleaseCapture();
        try std.testing.expect(c.GetCapture() == allowed.nativeHandle());
        _ = c.SendMessageW(blocked.nativeHandle(), c.WM_LBUTTONDOWN, 0, 0);
        _ = c.SendMessageW(blocked.nativeHandle(), c.WM_LBUTTONUP, 0, 0);
        try std.testing.expect(c.GetCapture() == allowed.nativeHandle());
        try std.testing.expect(c.GetFocus() == focus_before);
    } else {
        const area = gtk_bin_get_child(blocked.nativeHandle().?).?;
        const active_area = gtk_bin_get_child(allowed.nativeHandle().?).?;
        const group = gtk_window_get_group(allowed.nativeHandle().?);
        gtk_grab_add(active_area);
        defer gtk_grab_remove(active_area);
        const event = gdk_event_new(4) orelse return error.EventAllocationFailed;
        defer gdk_event_free(event);
        const button: *ButtonEvent = @ptrCast(@alignCast(event));
        button.* = .{ .kind = 4, .window = g_object_ref(gtk_widget_get_window(area).?), .send_event = 1, .time = 0, .x = 0, .y = 0, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
        var handled: c_int = 0;
        g_signal_emit_by_name(area, "button-press-event", button, &handled);
        button.kind = 7;
        g_signal_emit_by_name(area, "button-release-event", button, &handled);
        try std.testing.expect(gtk_window_group_get_current_grab(group) == active_area);
    }
}

const Probe = struct {
    app: *z.App,
    windows: [7]z.Window = undefined,
    contexts: [7]Context = undefined,
    closed: [7]bool = @splat(false),
    stage: enum { first, second, restored, owner_focus, closing, done } = .first,
    pending: bool = false,
    veto: bool = true,
    raw_on_disable: bool = false,
    raw_fired: bool = false,
    const Context = struct { probe: *Probe, index: usize };
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const context: *Context = @ptrCast(@alignCast(ptr));
        const self = context.probe;
        if (self.app.phase == .stopping or self.app.phase == .stopped) return;
        if (self.raw_on_disable and context.index == 0 and value == .window_state and !value.window_state.enabled and !self.raw_fired) {
            self.raw_fired = true;
            if (builtin.os.tag == .windows) std.debug.assert(c.DestroyWindow(window.nativeHandle()) != 0) else gtk_widget_destroy(window.nativeHandle().?);
            std.debug.assert(!self.closed[0]);
            return;
        }
        if (self.raw_on_disable or self.pending or self.stage == .done or window.isClosed()) return;
        if (value == .window_state or value == .focus) {
            self.pending = true;
            self.app.post(.{ .context = self, .call = advance }) catch unreachable;
        }
    }
    fn detach(_: *anyopaque) void {}
    fn request(ptr: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
        const context: *Context = @ptrCast(@alignCast(ptr));
        return if (context.index == 4 and context.probe.veto) .cancel else .allow;
    }
    fn notify(ptr: *anyopaque, _: z.Window) void {
        const context: *Context = @ptrCast(@alignCast(ptr));
        const self = context.probe;
        const i = context.index;
        std.debug.assert(!self.closed[i]);
        if (i == 0) std.debug.assert(self.closed[1] and self.closed[2] and self.closed[3] and self.closed[4] and self.closed[5]);
        if (i == 1) std.debug.assert(self.closed[3] and self.closed[5]);
        if (i == 2) std.debug.assert(self.closed[4]);
        if (i == 3) std.debug.assert(self.closed[5]);
        self.closed[i] = true;
        if (i == 0) self.stage = .done;
    }
    fn init(self: *Probe) !void {
        const parents = [_]?usize{ null, 0, 0, 1, 2, 3, null };
        for (&self.windows, 0..) |*window, i| {
            self.contexts[i] = .{ .probe = self, .index = i };
            const context = &self.contexts[i];
            window.* = try self.app.createWindow(.{ .title = "Window relationships", .width = 240, .height = 150, .owner = if (parents[i]) |index| self.windows[index] else null, .modal = i == 3 or i == 4 or i == 5, .on_close = .{ .context = context, .request = request }, .on_closed = .{ .context = context, .notify = notify } });
            try window.setContent(.{ .context = context, .event = event, .detach = detach });
            if (parents[i]) |index| {
                if (builtin.os.tag == .windows) {
                    try std.testing.expect(c.GetWindow(window.nativeHandle(), c.GW_OWNER) == self.windows[index].nativeHandle());
                } else {
                    try std.testing.expect(gtk_window_get_transient_for(window.nativeHandle().?) == self.windows[index].nativeHandle());
                    try std.testing.expectEqual(i == 3 or i == 4 or i == 5, gtk_window_get_modal(window.nativeHandle().?) != 0);
                    try std.testing.expect(gtk_window_get_group(window.nativeHandle().?) == gtk_window_get_group(self.windows[0].nativeHandle().?));
                }
            }
        }
        if (builtin.os.tag == .linux) try std.testing.expect(gtk_window_get_group(self.windows[0].nativeHandle().?) != gtk_window_get_group(self.windows[6].nativeHandle().?));
    }
    fn enabled(self: *Probe, index: usize, expected: bool) !void {
        const window = self.windows[index];
        try std.testing.expectEqual(expected, (try window.state()).enabled);
        if (builtin.os.tag == .windows) try std.testing.expectEqual(expected, c.IsWindowEnabled(window.nativeHandle()) != 0) else try std.testing.expectEqual(expected, gtk_widget_get_sensitive(window.nativeHandle().?) != 0);
    }
    fn advance(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.pending = false;
        self.step() catch |err| std.debug.panic("relationship stage {s}: {s}", .{ @tagName(self.stage), @errorName(err) });
    }
    fn focus(self: *Probe, index: usize) !void {
        self.windows[index].perform(.focus) catch |err| {
            // An inactive Windows desktop cannot become foreground, but its
            // own thread focus must still move without switching desktops.
            if (builtin.os.tag != .windows or err != error.FocusDenied) return err;
            try std.testing.expect(c.GetFocus() == self.windows[index].nativeHandle());
        };
    }
    fn step(self: *Probe) !void {
        switch (self.stage) {
            .first => {
                if (!(try self.windows[3].state()).focused) return;
                try self.enabled(0, false);
                try self.enabled(1, false);
                try self.enabled(2, false);
                try self.enabled(3, true);
                try self.enabled(6, true);
                try blockedPointer(self.windows[0], self.windows[3]);
                try std.testing.expectError(error.ModalBlocked, self.windows[0].perform(.focus));
                self.stage = .second;
                try self.windows[4].perform(.show);
                try self.focus(4);
            },
            .second => {
                if (!(try self.windows[4].state()).focused) return;
                try self.enabled(3, false);
                try self.enabled(4, true);
                try std.testing.expectEqual(self.windows[4].key, (try self.windows[1].focusTarget()).key);
                self.stage = .restored;
                try self.windows[4].perform(.hide);
            },
            .restored => {
                if (!(try self.windows[3].state()).focused) return;
                try self.enabled(0, false);
                try self.enabled(3, true);
                self.stage = .owner_focus;
                _ = try self.windows[3].destroy();
            },
            .owner_focus => {
                if (!self.closed[3] or !(try self.windows[1].state()).focused) return;
                try self.enabled(0, true);
                try self.enabled(1, true);
                try std.testing.expectEqual(z.CloseResult.cancelled, try self.windows[0].requestClose());
                try std.testing.expect(!self.windows[0].isClosed() and !self.windows[4].isClosed());
                self.veto = false;
                self.stage = .closing;
                _ = try self.windows[6].destroy();
                _ = try self.windows[0].requestClose();
            },
            .closing, .done => {},
        }
    }
};

fn runRelationships(require_wm: bool) !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    for (0..if (builtin.os.tag == .linux) @as(usize, 3) else 1) |_| {
        {
            const app = try z.App.init(allocator.allocator());
            defer app.deinit();
            var probe: Probe = .{ .app = app };
            try probe.init();
            try probe.windows[0].perform(.disable);
            try blockedPointer(probe.windows[0], probe.windows[1]);
            try probe.windows[0].perform(.enable);
            if (builtin.os.tag == .linux and !(try probe.windows[0].capabilities()).fullscreen) {
                if (require_wm) return error.WindowManagerRequired;
                _ = try probe.windows[0].destroy();
                _ = try probe.windows[6].destroy();
                return;
            }
            var watchdog: Watchdog = .{ .app = app };
            try watchdog.start();
            defer watchdog.stop();
            try probe.windows[0].perform(.show);
            try probe.windows[1].perform(.show);
            try probe.windows[3].perform(.show);
            try probe.focus(3);
            try app.run();
            if (watchdog.expired) std.debug.print("relationship timeout in {s}\n", .{@tagName(probe.stage)});
            try std.testing.expect(!watchdog.expired);
            try std.testing.expectEqual(@FieldType(Probe, "stage").done, probe.stage);
            for (probe.closed) |closed| try std.testing.expect(closed);
            try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        }
        if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    }
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var probe: Probe = .{ .app = app, .raw_on_disable = true };
        try probe.init();
        try std.testing.expectError(error.Closed, probe.windows[3].perform(.show));
        try app.dispatch();
        try std.testing.expect(probe.raw_fired and probe.closed[0]);
        _ = try probe.windows[6].destroy();
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("window relationships passed: native ownership, modal branches/counts, focus restoration, veto preflight, child-first close and raw-destroy reentry; resources=0\n", .{});
}

fn runWindows(require_wm: bool) !void {
    var bytes: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&bytes, "Ziggurat.Relationships.{d}", .{c.GetCurrentProcessId()});
    var wide: [64:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, name);
    wide[length] = 0;
    const previous = c.GetThreadDesktop(c.GetCurrentThreadId());
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null);
    if (desktop == null) return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    if (c.SetThreadDesktop(desktop) == 0) return error.SetThreadDesktopFailed;
    defer std.debug.assert(c.SetThreadDesktop(previous) != 0);
    try runRelationships(require_wm);
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    var require_wm = false;
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--require-wm")) {
        require_wm = true;
    } else return error.InvalidArgument;
    if (builtin.os.tag == .windows) try runWindows(require_wm) else if (builtin.os.tag == .linux) try runRelationships(require_wm) else return error.UnsupportedPlatform;
}
