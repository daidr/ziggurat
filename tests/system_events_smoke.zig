const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const c = @import("ziggurat_c_win32");
const tray_message = c.WM_APP + 0x421;
const hotkey: system.Hotkey = .{ .key = .f24, .modifiers = .{ .control = true, .alt = true, .shift = true } };
const native_key = c.VK_F24;
const native_modifiers = c.MOD_CONTROL | c.MOD_ALT | c.MOD_SHIFT;
/// A 2 by 1 PNG, red and blue.
const tiny_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x0e\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\x00\x42\xff\x01\x0f\xf9\x03\xfd\x85\x11\x99\x76\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
const Probe = struct {
    owner: system.Owner = undefined,
    hotkeys: usize = 0,
    notifications: usize = 0,
    close_on_action: bool = false,

    fn action(ptr: *anyopaque, window: z.Window, value: system.Action) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        switch (value) {
            .hotkey => |id| {
                std.debug.assert(id == 7 or id == 8);
                self.hotkeys += 1;
            },
            .notification_activated => |id| {
                std.debug.assert(id == 9);
                std.debug.assert(self.owner.notification == null);
                self.notifications += 1;
            },
            else => {},
        }
        if (self.close_on_action) std.debug.assert((window.destroy() catch unreachable) == .deferred);
    }
};
const DiagnosticReentry = struct {
    probe: ?*Probe = null,
    window: ?z.Window = null,
    replaced: bool = false,
    fn emit(ptr: *anyopaque, diagnostic: z.diagnostics.Diagnostic) void {
        const self: *DiagnosticReentry = @ptrCast(@alignCast(ptr));
        const err = diagnostic.err orelse return;
        if (err != error.NotificationRemovalFailed) return;
        const probe = self.probe orelse return;
        const window = self.window.?;
        probe.owner.detach() catch unreachable;
        probe.owner = system.Owner.init(probe, Probe.action);
        probe.owner.attach(window) catch unreachable;
        self.replaced = true;
    }
};
fn sendHotkey(hwnd: c.HWND, id: u16) void {
    _ = c.SendMessageW(hwnd, c.WM_HOTKEY, id, (native_key << 16) | native_modifiers);
}
fn sendNotification(hwnd: c.HWND, id: u16, event: u16) void {
    _ = c.SendMessageW(hwnd, tray_message, 0, @bitCast((@as(usize, id) << 16) | event));
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var diagnostic_reentry: DiagnosticReentry = .{};
    const app = try z.App.initWithOptions(allocator.allocator(), .{ .diagnostics_sink = .{ .context = &diagnostic_reentry, .emit = DiagnosticReentry.emit } });
    defer app.deinit();
    var baseline_user: ?c.DWORD = null;
    var baseline_gdi: ?c.DWORD = null;
    for (0..12) |cycle| {
        var first: Probe = .{};
        var second: Probe = .{};
        first.owner = system.Owner.init(&first, Probe.action);
        second.owner = system.Owner.init(&second, Probe.action);
        const window = try app.createWindow(.{});
        const other = try app.createWindow(.{});
        const hwnd: c.HWND = window.nativeHandle();
        try first.owner.attach(window);
        try second.owner.attach(other);
        try std.testing.expectError(error.InvalidHotkeyId, first.owner.registerHotkey(0, hotkey));
        try std.testing.expectError(error.UnsupportedKey, first.owner.registerHotkey(1, .{ .key = .f12 }));
        try first.owner.registerHotkey(7, hotkey);
        const old_id = first.owner.hotkeys[0].native_id;
        try std.testing.expectError(error.DuplicateHotkeyId, first.owner.registerHotkey(7, .{ .key = .f23 }));
        try std.testing.expectError(error.HotkeyRegistrationFailed, second.owner.registerHotkey(8, hotkey));
        try std.testing.expect(second.owner.last_error != 0 and second.owner.hotkey_count == 0);
        sendHotkey(hwnd, old_id);
        try std.testing.expectEqual(1, first.hotkeys);
        _ = c.SendMessageW(hwnd, c.WM_HOTKEY, old_id, 0);
        try std.testing.expectEqual(1, first.hotkeys);
        try first.owner.unregisterHotkey(7);
        try std.testing.expectError(error.HotkeyNotFound, first.owner.unregisterHotkey(7));
        sendHotkey(hwnd, old_id);
        try std.testing.expectEqual(1, first.hotkeys);
        try second.owner.registerHotkey(8, hotkey);
        second.close_on_action = true;
        sendHotkey(other.nativeHandle(), second.owner.hotkeys[0].native_id);
        try app.dispatch();
        try std.testing.expect(other.isClosed() and second.owner.hotkey_count == 0 and second.owner.window == null);
        try first.owner.registerHotkey(7, hotkey);
        const current_id = first.owner.hotkeys[0].native_id;
        try std.testing.expect(current_id != old_id);
        sendHotkey(hwnd, old_id);
        try std.testing.expectEqual(1, first.hotkeys);
        try first.owner.detach();
        try std.testing.expectEqual(0, first.owner.hotkey_count);
        first.owner = system.Owner.init(&first, Probe.action);
        try first.owner.attach(window);
        try first.owner.registerHotkey(7, hotkey);
        sendHotkey(hwnd, current_id);
        try std.testing.expectEqual(1, first.hotkeys);
        if (cycle == 0) {
            try std.testing.expectError(error.InvalidNotificationId, first.owner.showNotification(0, .{ .title = "Title", .body = "Body" }));
            try std.testing.expectError(error.EmptyNotification, first.owner.showNotification(9, .{ .title = "Title", .body = "" }));
            try std.testing.expectError(error.EmbeddedNul, first.owner.showNotification(9, .{ .title = "bad\x00title", .body = "Body" }));
            try std.testing.expectError(error.InvalidUtf8, first.owner.showNotification(9, .{ .title = "Title", .body = "\xff" }));
            const overlong = @as([256]u8, @splat('a'));
            try std.testing.expectError(error.TextCapacityExceeded, first.owner.showNotification(9, .{ .title = "Title", .body = &overlong }));
            try first.owner.showNotification(9, .{ .title = "Ziggurat integration check", .body = "Silent notification lifecycle check", .silent = true });
            const notification_id = first.owner.notification.?.tray.id;
            // Production Shell submission is real. The click is a native
            // protocol injection; this does not prove user-visible delivery.
            sendNotification(hwnd, notification_id, c.NIN_BALLOONUSERCLICK);
            try std.testing.expectEqual(1, first.notifications);
            try std.testing.expect(first.owner.notification == null);
            sendNotification(hwnd, notification_id, c.NIN_BALLOONUSERCLICK);
            try std.testing.expectEqual(1, first.notifications);
            try first.owner.clearNotification();
            // The image becomes the balloon's large icon; a toast that never
            // says it is done loses its icon on the owner's timer.
            try first.owner.showNotification(9, .{ .title = "Ziggurat integration check", .body = "Notification with an image", .silent = true, .image = tiny_png });
            try std.testing.expect(first.owner.notification.?.balloon != null);
            _ = c.SendMessageW(hwnd, c.WM_TIMER, 0x5a4e, 0);
            try std.testing.expect(first.owner.notification == null);
            try std.testing.expectEqual(1, first.notifications);
            try first.owner.showNotification(9, .{ .title = "Ziggurat integration check", .body = "Undecodable image", .silent = true, .image = "\x89PNG\r\n\x1a\nnot really an image" });
            try std.testing.expect(first.owner.notification.?.balloon == null);
            try first.owner.clearNotification();
            try first.owner.showNotification(9, .{ .title = "Ziggurat integration check", .body = "Pending notification is removed on close", .silent = true });
            try std.testing.expect(first.owner.notification != null);
            const failing_id = first.owner.notification.?.tray.id;
            var removed = std.mem.zeroes(c.NOTIFYICONDATAW);
            removed.cbSize = @sizeOf(c.NOTIFYICONDATAW);
            removed.hWnd = hwnd;
            removed.uID = failing_id;
            try std.testing.expect(c.Shell_NotifyIconW(c.NIM_DELETE, &removed) != 0);
            diagnostic_reentry.probe = &first;
            diagnostic_reentry.window = window;
            sendNotification(hwnd, failing_id, c.NIN_BALLOONUSERCLICK);
            diagnostic_reentry.probe = null;
            try std.testing.expect(diagnostic_reentry.replaced);
            try std.testing.expectEqual(1, first.notifications);
            try std.testing.expect(first.owner.window != null and first.owner.notification == null);
            try first.owner.registerHotkey(7, hotkey);
            try first.owner.showNotification(9, .{ .title = "Ziggurat integration check", .body = "Pending notification is removed on close", .silent = true });
        }
        first.close_on_action = true;
        sendHotkey(hwnd, first.owner.hotkeys[0].native_id);
        try app.dispatch();
        try std.testing.expect(window.isClosed() and first.owner.hotkey_count == 0 and first.owner.notification == null);
        try std.testing.expectEqual(0, app.resourceStats().allocated_records);
        // OS registration must be available again after callback-driven close.
        try std.testing.expect(c.RegisterHotKey(null, 0xbffe, native_modifiers | c.MOD_NOREPEAT, native_key) != 0);
        try std.testing.expect(c.UnregisterHotKey(null, 0xbffe) != 0);
        const user = c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS);
        const gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
        if (baseline_user) |value| try std.testing.expectEqual(value, user) else baseline_user = user;
        if (baseline_gdi) |value| try std.testing.expectEqual(value, gdi) else baseline_gdi = gdi;
    }
    var exhausted: Probe = .{};
    exhausted.owner = system.Owner.init(&exhausted, Probe.action);
    const last = try app.createWindow(.{});
    try exhausted.owner.attach(last);
    _ = try last.reserveNativeIds(0xbfff);
    try std.testing.expectError(error.IdExhausted, exhausted.owner.registerHotkey(7, hotkey));
    try std.testing.expectEqual(0, exhausted.owner.hotkey_count);
    _ = try last.destroy();
    std.debug.print("system events passed: real hotkey registration/conflict/unregistration; 12 close/replacement cycles reject stale events; notification submission/activation/cleanup; exhausted IDs; USER={d} GDI={d} stable\n", .{ baseline_user.?, baseline_gdi.? });
}
