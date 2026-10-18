const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});
const tray_message = c.WM_APP + 0x421;
const items = [_]system.Item{
    .{ .id = 1, .kind = .submenu, .label = "&File" },
    .{ .id = 2, .parent = 1, .label = "&Apply" },
    .{ .parent = 1, .kind = .separator },
    .{ .id = 3, .parent = 1, .label = "&Close" },
};

const Probe = struct {
    owner: system.Owner = undefined,
    actions: usize = 0,
    tray_actions: usize = 0,
    tray_point: ?system.ScreenPoint = null,
    detaches: usize = 0,
    notifications: usize = 0,
    raw_close: bool = false,

    fn action(ptr: *anyopaque, window: z.Window, value: system.Action) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        window.app.assertOwner();
        switch (value) {
            .menu => |id| {
                self.actions += 1;
                if (id == 3) {
                    if (self.raw_close) {
                        std.debug.assert(c.DestroyWindow(window.nativeHandle()) != 0);
                        std.debug.assert(self.owner.window == null);
                    } else std.debug.assert((window.destroy() catch unreachable) == .deferred);
                    std.debug.assert(self.detaches == 0 and self.notifications == 0);
                }
            },
            .tray_activate => self.tray_actions += 1,
            .tray_context => |point| self.tray_point = point,
            .hotkey, .notification_activated => {},
        }
    }
    fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
    fn detach(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.owner.window == null and self.owner.menu == null and self.owner.tray == null);
        self.detaches += 1;
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.detaches == 1);
        self.notifications += 1;
    }
};

fn command(menu: c.HMENU, index: c_int) usize {
    return c.GetMenuItemID(c.GetSubMenu(menu, 0), index);
}
fn trayEvent(hwnd: c.HWND, id: u16, event: u16, point: usize) void {
    const payload: usize = (@as(usize, id) << 16) | event;
    _ = c.SendMessageW(hwnd, tray_message, point, @bitCast(payload));
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var base_user: ?c.DWORD = null;
    var base_gdi: ?c.DWORD = null;
    for (0..12) |cycle| {
        var probe: Probe = .{ .raw_close = cycle % 2 != 0 };
        probe.owner = system.Owner.init(&probe, Probe.action);
        const window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.closed } });
        const hwnd: c.HWND = window.nativeHandle();
        try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        try probe.owner.attach(window);
        try probe.owner.setMenu(&items);
        const first_menu = c.GetMenu(hwnd);
        try std.testing.expect(first_menu != null and c.IsMenu(first_menu) != 0);
        const old_command = command(first_menu, 0);
        try std.testing.expectEqual(3, c.GetMenuItemCount(c.GetSubMenu(first_menu, 0)));
        _ = c.SendMessageW(hwnd, c.WM_COMMAND, old_command, 0);
        try std.testing.expectEqual(1, probe.actions);
        try probe.owner.setItemState(2, false, true);
        try std.testing.expect(c.GetMenuState(c.GetSubMenu(first_menu, 0), @intCast(old_command), c.MF_BYCOMMAND) & c.MF_CHECKED != 0);
        _ = c.SendMessageW(hwnd, c.WM_COMMAND, old_command, 0);
        try std.testing.expectEqual(1, probe.actions);
        try std.testing.expectError(error.InvalidMenuParent, probe.owner.setMenu(&.{.{ .id = 8, .parent = 999, .label = "Invalid" }}));
        try std.testing.expect(c.GetMenu(hwnd) == first_menu);
        try probe.owner.setTray(.{ .tooltip = "System smoke / 工具" });
        const old_tray = probe.owner.tray.?.id;
        trayEvent(hwnd, old_tray, c.NIN_SELECT, 0);
        trayEvent(hwnd, old_tray, c.WM_CONTEXTMENU, (@as(usize, 21) << 16) | @as(u16, @bitCast(@as(i16, -12))));
        try std.testing.expectEqual(1, probe.tray_actions);
        try std.testing.expectEqual(system.ScreenPoint{ .x = -12, .y = 21 }, probe.tray_point.?);

        // Remove our own shell item, then simulate the documented shell restart
        // notification. This does not restart Explorer or touch another icon.
        var removed = std.mem.zeroes(c.NOTIFYICONDATAW);
        removed.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        removed.hWnd = hwnd;
        removed.uID = old_tray;
        try std.testing.expect(c.Shell_NotifyIconW(c.NIM_DELETE, &removed) != 0);
        _ = c.SendMessageW(hwnd, probe.owner.taskbar_created, 0, 0);
        try std.testing.expectEqual(0, probe.owner.last_error);
        try probe.owner.detach();
        try std.testing.expect(probe.owner.window == null);
        try std.testing.expect(c.GetMenu(hwnd) == null and c.IsMenu(first_menu) == 0);
        try std.testing.expectEqual(0, probe.detaches);

        // A different Owner on the same HWND must not reuse identifiers from
        // detached services: queued old native callbacks are harmless.
        probe.owner = system.Owner.init(&probe, Probe.action);
        try probe.owner.attach(window);
        try probe.owner.setMenu(&items);
        try probe.owner.setTray(.{ .tooltip = "Replacement owner" });
        const current_menu = c.GetMenu(hwnd);
        const current_command = command(current_menu, 0);
        try std.testing.expect(current_command != old_command);
        try std.testing.expect(probe.owner.tray.?.id != old_tray);
        _ = c.SendMessageW(hwnd, c.WM_COMMAND, old_command, 0);
        trayEvent(hwnd, old_tray, c.NIN_SELECT, 0);
        try std.testing.expectEqual(1, probe.actions);
        try std.testing.expectEqual(1, probe.tray_actions);
        _ = c.SendMessageW(hwnd, c.WM_COMMAND, command(current_menu, 2), 0);
        try app.dispatch();
        try std.testing.expect(window.isClosed());
        try std.testing.expectEqual(1, probe.detaches);
        try std.testing.expectEqual(1, probe.notifications);
        try std.testing.expect(probe.owner.window == null and probe.owner.menu == null and probe.owner.tray == null);
        try std.testing.expect(c.IsMenu(current_menu) == 0);
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
        try std.testing.expectError(error.Closed, system.clipboard.readText(window, &.{}));
        const user = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
        const gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
        if (base_user) |baseline| try std.testing.expectEqual(baseline, user) else base_user = user;
        if (base_gdi) |baseline| try std.testing.expectEqual(baseline, gdi) else base_gdi = gdi;
    }
    std.debug.print("system native smoke passed: 12 menu/tray lifetimes, real shell add/delete/recovery, state and commands, stale owner events rejected, callback closure cleans resources; USER={d} GDI={d} unchanged after warmup\n", .{ base_user.?, base_gdi.? });
}
