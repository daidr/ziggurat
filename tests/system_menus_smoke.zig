const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

const popup_items = [_]system.Item{
    .{ .id = 1, .label = "&Open", .accelerator = .{ .key = .o, .modifiers = .{ .control = true } } },
    .{ .id = 2, .kind = .submenu, .label = "Locked", .enabled = false },
    .{ .id = 3, .parent = 2, .label = "Hidden" },
    .{ .kind = .separator },
    .{ .id = 4, .label = "Checked", .checked = true },
};
const bar_items = [_]system.Item{
    .{ .id = 10, .kind = .submenu, .label = "&File" },
    .{ .id = 11, .parent = 10, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
    .{ .id = 12, .parent = 10, .label = "Re&load", .accelerator = .{ .key = .f5 } },
    .{ .id = 13, .kind = .submenu, .label = "&Edit", .enabled = false },
    .{ .id = 14, .parent = 13, .label = "&Undo", .accelerator = .{ .key = .z, .modifiers = .{ .alt = true } } },
};

/// What the next timer tick does inside the system menu loop.
const Driver = enum { idle, choose_first, cancel, detach, tray_choose };

const Probe = struct {
    owner: system.Owner = undefined,
    window: z.Window = undefined,
    popups: [8]system.PopupResult = undefined,
    popup_count: usize = 0,
    menus: [8]u64 = undefined,
    menu_count: usize = 0,
    message: ?system.MessageResult = null,
    driver: Driver = .idle,
    ticks: usize = 0,
    tray: system.Tray = undefined,
    tray_events: [8]system.TrayAction = undefined,
    tray_count: usize = 0,

    fn action(ptr: *anyopaque, window: z.Window, value: system.Action) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        window.app.assertOwner();
        switch (value) {
            .popup => |result| {
                std.debug.assert(!self.owner.popup.pending());
                self.popups[self.popup_count] = result;
                self.popup_count += 1;
            },
            .menu => |id| {
                self.menus[self.menu_count] = id;
                self.menu_count += 1;
            },
            .message => |result| {
                self.message = result;
                _ = window.destroy() catch unreachable;
            },
            else => unreachable,
        }
    }
    fn trayAction(ptr: *anyopaque, tray: *system.Tray, value: system.TrayAction) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(tray == &self.tray);
        self.tray_events[self.tray_count] = value;
        self.tray_count += 1;
    }
};
var active: ?*Probe = null;

fn drive(_: c.HWND, _: c.UINT, timer: usize, _: c.DWORD) callconv(.winapi) void {
    const probe = active orelse return;
    var info = std.mem.zeroes(c.GUITHREADINFO);
    info.cbSize = @sizeOf(c.GUITHREADINFO);
    const tracking = c.GetGUIThreadInfo(c.GetCurrentThreadId(), &info) != 0 and info.flags & c.GUI_POPUPMENUMODE != 0;
    probe.ticks += 1;
    if (!tracking and probe.ticks > 200) {
        // Never leave a hidden menu loop running if the system did not
        // report popup mode; the caller's expectation then fails visibly.
        std.debug.print("menu driver {s}: popup mode not observed\n", .{@tagName(probe.driver)});
        _ = c.EndMenu();
        probe.driver = .idle;
        _ = c.KillTimer(null, timer);
        return;
    }
    switch (probe.driver) {
        .idle => {},
        .choose_first, .tray_choose => {
            // The menu loop reads keyboard input from this thread's queue.
            if (!tracking) return;
            _ = c.PostMessageW(info.hwndMenuOwner, c.WM_KEYDOWN, c.VK_DOWN, 0);
            _ = c.PostMessageW(info.hwndMenuOwner, c.WM_KEYDOWN, c.VK_RETURN, 0);
        },
        .cancel, .detach => if (!tracking) return,
    }
    switch (probe.driver) {
        .idle, .choose_first, .tray_choose => {},
        .cancel => probe.owner.cancelPopup() catch unreachable,
        .detach => probe.owner.detach() catch unreachable,
    }
    probe.driver = .idle;
    _ = c.KillTimer(null, timer);
}

fn pump(done: *const fn (*Probe) bool, probe: *Probe) !void {
    var message: c.MSG = undefined;
    for (0..2000) |_| {
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        if (done(probe)) return;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return error.Timeout;
}
fn popupCount(comptime count: usize) *const fn (*Probe) bool {
    return struct {
        fn check(probe: *Probe) bool {
            return probe.popup_count == count;
        }
    }.check;
}
fn settled(probe: *Probe) bool {
    return probe.driver == .idle and !probe.owner.popup.pending();
}
fn trayCount(comptime count: usize) *const fn (*Probe) bool {
    return struct {
        fn check(probe: *Probe) bool {
            return probe.tray_count == count;
        }
    }.check;
}

fn key(hwnd: c.HWND, message: c.UINT, code: usize, control: bool, alt: bool, repeat: bool) void {
    var state: [256]u8 = @splat(0);
    if (control) state[c.VK_CONTROL] = 0x80;
    if (alt) state[c.VK_MENU] = 0x80;
    _ = c.SetKeyboardState(&state);
    const lp: usize = 1 | (if (repeat) @as(usize, 1) << 30 else 0) | (if (alt) @as(usize, 1) << 29 else 0);
    _ = c.SendMessageW(hwnd, message, code, @bitCast(lp));
    state = @splat(0);
    _ = c.SetKeyboardState(&state);
}

fn startTimer(probe: *Probe, driver: Driver) !void {
    probe.driver = driver;
    // NO_STRICT declares TIMERPROC without a prototype.
    if (c.SetTimer(null, 0, 15, @ptrCast(&drive)) == 0) return error.TimerFailed;
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var probe: Probe = .{};
        active = &probe;
        defer active = null;
        probe.owner = system.Owner.init(&probe, Probe.action);
        probe.window = try app.createWindow(.{ .title = "System menus smoke" });
        const hwnd: c.HWND = probe.window.nativeHandle();
        try probe.owner.attach(probe.window);

        // Popup selection through the system menu loop's keyboard handling.
        try probe.owner.popupMenu(1, &popup_items, .{ .client = .{ .x = 8, .y = 8 } });
        try std.testing.expectError(error.MenuAlreadyPending, probe.owner.popupMenu(2, &popup_items, .pointer));
        try std.testing.expectEqual(0, probe.popup_count);
        try startTimer(&probe, .choose_first);
        try pump(popupCount(1), &probe);
        try std.testing.expectEqual(system.PopupResult{ .request = 1, .selected = 1 }, probe.popups[0]);

        // Cancellation while tracking and before tracking both report null.
        try probe.owner.popupMenu(2, &popup_items, .pointer);
        try startTimer(&probe, .cancel);
        try pump(popupCount(2), &probe);
        try std.testing.expectEqual(system.PopupResult{ .request = 2, .selected = null }, probe.popups[1]);
        try probe.owner.popupMenu(3, &popup_items, .{ .screen = .{ .x = 40, .y = 40 } });
        try probe.owner.cancelPopup();
        try pump(popupCount(3), &probe);
        try std.testing.expectEqual(system.PopupResult{ .request = 3, .selected = null }, probe.popups[2]);

        // Detach inside the loop completes nothing; the loop frees its menu.
        try probe.owner.popupMenu(4, &popup_items, .pointer);
        try startTimer(&probe, .detach);
        try pump(settled, &probe);
        try std.testing.expect(probe.owner.window == null);
        try std.testing.expectEqual(3, probe.popup_count);
        try probe.owner.attach(probe.window);
        try std.testing.expectError(error.EmptyMenu, probe.owner.popupMenu(5, &.{}, .pointer));
        try std.testing.expectError(error.InvalidRequestId, probe.owner.popupMenu(0, &popup_items, .pointer));
        try std.testing.expectError(error.InvalidAnchor, probe.owner.popupMenu(5, &popup_items, .{ .client = .{ .x = std.math.nan(f32), .y = 0 } }));

        // Menu bar accelerators see keys the content leaves unconsumed.
        try probe.owner.setMenu(&bar_items);
        var label: [64]u16 = undefined;
        const length = c.GetMenuStringW(c.GetSubMenu(c.GetMenu(hwnd), 0), 0, &label, label.len, c.MF_BYPOSITION);
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("&Save\tCtrl+S"), label[0..@intCast(length)]);
        key(hwnd, c.WM_KEYDOWN, 'S', true, false, false);
        key(hwnd, c.WM_KEYDOWN, 'S', true, false, true);
        key(hwnd, c.WM_KEYDOWN, 'S', false, false, false);
        key(hwnd, c.WM_KEYDOWN, c.VK_F5, false, false, false);
        key(hwnd, c.WM_SYSKEYDOWN, 'Z', false, true, false);
        try std.testing.expectEqualSlices(u64, &.{ 11, 12 }, probe.menus[0..probe.menu_count]);
        try probe.owner.setItemState(11, false, false);
        key(hwnd, c.WM_KEYDOWN, 'S', true, false, false);
        try std.testing.expectEqual(2, probe.menu_count);
        try std.testing.expectError(error.DuplicateAccelerator, probe.owner.setMenu(&.{
            .{ .id = 1, .label = "A", .accelerator = .{ .key = .f2 } },
            .{ .id = 2, .label = "B", .accelerator = .{ .key = .f2 } },
        }));
        try std.testing.expectError(error.InvalidAccelerator, probe.owner.setMenu(&.{.{ .id = 1, .label = "A", .accelerator = .{ .key = .a } }}));

        // A standalone tray item: shell add, events, anchored menu, recovery.
        probe.tray = system.Tray.init(&probe, Probe.trayAction);
        try probe.tray.show(app, .{ .tooltip = "Standalone tray / 托盘" });
        const tray_hwnd = probe.tray.hwnd;
        const tray_id = probe.tray.id;
        const tray_message: c.UINT = c.WM_APP + 0x422;
        _ = c.SendMessageW(tray_hwnd, tray_message, 0, @bitCast((@as(usize, tray_id) << 16) | c.NIN_SELECT));
        _ = c.SendMessageW(tray_hwnd, tray_message, (@as(usize, 30) << 16) | 20, @bitCast((@as(usize, tray_id) << 16) | c.WM_CONTEXTMENU));
        _ = c.SendMessageW(tray_hwnd, tray_message, 0, @bitCast((@as(usize, tray_id +% 1) << 16) | c.NIN_SELECT));
        try std.testing.expectEqual(2, probe.tray_count);
        try std.testing.expect(probe.tray_events[0] == .activate);
        try std.testing.expectEqual(system.ScreenPoint{ .x = 20, .y = 30 }, probe.tray_events[1].context);
        try probe.tray.show(app, .{ .tooltip = "Updated tooltip" });
        try std.testing.expectEqual(tray_hwnd, probe.tray.hwnd);
        try probe.tray.popupMenu(30, &popup_items, .icon);
        try startTimer(&probe, .tray_choose);
        try pump(trayCount(3), &probe);
        try std.testing.expectEqual(system.PopupResult{ .request = 30, .selected = 1 }, probe.tray_events[2].popup);
        // The item's own menu opens after the context event and reports
        // its command as a menu action rather than a popup result.
        try std.testing.expectError(error.DuplicateMenuId, probe.tray.setMenu(&.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } }));
        try probe.tray.setMenu(&popup_items);
        _ = c.SendMessageW(tray_hwnd, tray_message, (@as(usize, 30) << 16) | 20, @bitCast((@as(usize, tray_id) << 16) | c.WM_CONTEXTMENU));
        try std.testing.expect(probe.tray_events[3] == .context);
        try startTimer(&probe, .tray_choose);
        try pump(trayCount(5), &probe);
        try std.testing.expectEqual(1, probe.tray_events[4].menu);
        try probe.tray.setMenu(&.{});
        var removed = std.mem.zeroes(c.NOTIFYICONDATAW);
        removed.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        removed.hWnd = tray_hwnd;
        removed.uID = tray_id;
        try std.testing.expect(c.Shell_NotifyIconW(c.NIM_DELETE, &removed) != 0);
        _ = c.SendMessageW(tray_hwnd, probe.tray.taskbar_created, 0, 0);
        try std.testing.expect(c.Shell_NotifyIconW(c.NIM_DELETE, &removed) != 0);
        _ = c.SendMessageW(tray_hwnd, probe.tray.taskbar_created, 0, 0);
        // A second, independent item coexists; the first is removed explicitly.
        var second = system.Tray.init(&probe, Probe.trayAction);
        try second.show(app, .{ .tooltip = "Second tray" });
        try std.testing.expect(second.hwnd != tray_hwnd);
        try probe.tray.remove();
        try std.testing.expect(probe.tray.hwnd == null and probe.tray.icon == null);
        try std.testing.expect(c.Shell_NotifyIconW(c.NIM_DELETE, &removed) == 0);
        try probe.tray.show(app, .{ .tooltip = "Shown again" });
        try std.testing.expect(probe.tray.id != tray_id);
        try std.testing.expectEqual(2, app.resourceStats().stop_participants);

        // Asynchronous message: cancel reports dismissed through the
        // one-shot native wait; the action closes the window and ends run.
        probe.owner.showMessage(40, .{ .title = "Smoke", .message = "Asynchronous message / 消息", .buttons = &.{ .{ .id = 1, .label = "OK" }, .{ .id = 2, .label = "Cancel" } }, .default_button = 0, .cancel_button = 1 }) catch |err| {
            std.debug.print("message dialog failed to start: {s}, HRESULT=0x{x}\n", .{ @errorName(err), @as(u32, @bitCast(probe.owner.message_dialog.last_hresult)) });
            return err;
        };
        try std.testing.expectError(error.MessageAlreadyPending, probe.owner.showMessage(41, .{ .message = "x", .buttons = &.{.{ .id = 1, .label = "OK" }} }));
        try probe.owner.cancelMessage();
        try std.testing.expect(probe.tray.hwnd != null and second.hwnd != null);
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        try app.run();
        try std.testing.expect(!watchdog.expired);
        if (probe.message) |result| if (result.response == .failed) std.debug.print("message completion failed: {any}\n", .{result.response.failed});
        try std.testing.expectEqual(system.MessageResult{ .request = 40, .response = .dismissed }, probe.message.?);
        try std.testing.expect(probe.owner.window == null);
        // Trays left shown are removed by App stop when run returns.
        try std.testing.expect(probe.tray.hwnd == null and probe.tray.icon == null and second.hwnd == null and second.icon == null);
        try std.testing.expectEqual(0, app.resourceStats().stop_participants);
    }
    // Closing the sole window immediately after a message starts suppresses
    // the result and leaves no business callback behind.
    {
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        var probe: Probe = .{};
        probe.owner = system.Owner.init(&probe, Probe.action);
        probe.window = try app.createWindow(.{});
        try probe.owner.attach(probe.window);
        try probe.owner.showMessage(50, .{ .message = "Closed underneath", .buttons = &.{.{ .id = 1, .label = "OK" }} });
        try probe.owner.popupMenu(51, &popup_items, .pointer);
        _ = try probe.window.destroy();
        try std.testing.expect(probe.owner.window == null and !probe.owner.message_dialog.pending() and !probe.owner.popup.pending());
        try std.testing.expect(probe.message == null and probe.popup_count == 0);
    }
    std.debug.print("system menus smoke passed: popup select/cancel/queued-cancel/detach-in-loop, menu bar accelerators with repeat/disabled/ancestor rules, standalone tray events/anchored menu/shell recovery/App-stop removal, async message cancel and closure; message native states={d}\n", .{system.message.resourceCount()});
}
