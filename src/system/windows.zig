const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const picker_api = @import("picker.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

/// Reserved on the owner HWND while attached. Command IDs and tray IDs are never
/// reused during the HWND's lifetime, so queued old messages cannot target a
/// replacement item. No business state or callback dispatch table is global.
pub const tray_message: u32 = c.WM_APP + 0x421;
const Entry = struct { id: u64, command: u16, menu: c.HMENU, enabled: bool, ancestor_enabled: bool };
const Tray = struct { id: u16, icon: c.HICON, tooltip: [128]u16 };
const HotkeyEntry = struct { id: u64, native_id: u16, key: u32, modifiers: u32 };
const Notification = struct { id: u64, tray: Tray };

/// Keep at a stable address through detach/on_closed. All operations and action
/// callbacks run on the window's owner thread. Native resources are reclaimed
/// before the owner HWND disappears, independently of Content attachment.
pub const Owner = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, types.Action) void,
    window: ?z.Window = null,
    hwnd: c.HWND = null,
    menu: c.HMENU = null,
    entries: [types.max_menu_items]Entry = undefined,
    entry_count: usize = 0,
    tray: ?Tray = null,
    notification: ?Notification = null,
    hotkeys: [types.max_hotkeys]HotkeyEntry = undefined,
    hotkey_count: usize = 0,
    taskbar_created: u32 = 0,
    last_error: u32 = 0,
    picker: picker_api.Picker = .{},

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, types.Action) void) Owner {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(self: *Owner, window: z.Window) !void {
        window.app.assertOwner();
        if (self.window != null) return error.AlreadyAttached;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const hwnd: c.HWND = window.nativeHandle() orelse return error.Closed;
        if (c.GetMenu(hwnd) != null) return error.NativeMenuAlreadyPresent;
        const registered = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
        if (registered == 0) return self.failed(error.MessageRegistrationFailed);
        self.hwnd = hwnd;
        self.window = window;
        errdefer {
            self.window = null;
            self.hwnd = null;
        }
        self.taskbar_created = registered;
        try window.setService(.{ .context = self, .message = message, .native_destroying = nativeDestroying });
    }
    pub fn detach(self: *Owner) !void {
        const window = self.window orelse return;
        window.app.assertOwner();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.picker.detach();
        if (self.window == null) return;
        try self.clearHotkeys();
        try self.clearNotification();
        try self.clearTray();
        try self.clearMenu();
        window.clearService(self);
    }
    fn require(self: *Owner) !z.Window {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (window.isClosed() or self.hwnd == null) return error.Closed;
        return window;
    }
    pub fn openFile(self: *Owner, options: picker_api.Options, destination: []u8, context: *anyopaque, on_result: picker_api.Callback) !void {
        const window = try self.require();
        try self.picker.start(window, .open_file, options, destination, context, on_result);
    }
    pub fn saveFile(self: *Owner, options: picker_api.Options, destination: []u8, context: *anyopaque, on_result: picker_api.Callback) !void {
        try self.picker.start(try self.require(), .save_file, options, destination, context, on_result);
    }
    pub fn openFiles(self: *Owner, options: picker_api.Options, destination: []u8, context: *anyopaque, on_result: picker_api.Callback) !void {
        try self.picker.start(try self.require(), .open_files, options, destination, context, on_result);
    }
    pub fn pickFolder(self: *Owner, options: picker_api.Options, destination: []u8, context: *anyopaque, on_result: picker_api.Callback) !void {
        try self.picker.start(try self.require(), .folder, options, destination, context, on_result);
    }
    pub fn cancelFileDialog(self: *Owner) !void {
        _ = try self.require();
        try self.picker.cancel();
    }
    fn failed(self: *Owner, err: anyerror) anyerror {
        self.last_error = c.GetLastError();
        return err;
    }

    /// IDs are local to this Owner and nonzero. Native IDs are never reused on
    /// the window, including failed registration, removal and service changes.
    pub fn registerHotkey(self: *Owner, id: u64, hotkey: types.Hotkey) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (id == 0) return error.InvalidHotkeyId;
        for (self.hotkeys[0..self.hotkey_count]) |entry| if (entry.id == id) return error.DuplicateHotkeyId;
        if (self.hotkey_count == self.hotkeys.len) return error.TooManyHotkeys;
        // Windows reserves F12 for the debugger, even outside a debug session.
        if (hotkey.key == .f12) return error.UnsupportedKey;
        const key = virtualKey(hotkey.key);
        const modifiers = modifierBits(hotkey.modifiers);
        const native_id = try window.reserveNativeIds(1);
        if (native_id > 0xbfff) return error.IdExhausted;
        const hwnd = self.hwnd;
        if (c.RegisterHotKey(hwnd, native_id, modifiers | @as(u32, if (hotkey.repeat) 0 else c.MOD_NOREPEAT), key) == 0) return self.failed(error.HotkeyRegistrationFailed);
        if (window.isClosed()) {
            _ = c.UnregisterHotKey(hwnd, native_id);
            return error.Closed;
        }
        self.hotkeys[self.hotkey_count] = .{ .id = id, .native_id = native_id, .key = key, .modifiers = modifiers };
        self.hotkey_count += 1;
    }
    pub fn unregisterHotkey(self: *Owner, id: u64) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        for (self.hotkeys[0..self.hotkey_count], 0..) |entry, index| if (entry.id == id) {
            if (c.UnregisterHotKey(self.hwnd, entry.native_id) == 0) return self.failed(error.HotkeyRemovalFailed);
            self.hotkey_count -= 1;
            self.hotkeys[index] = self.hotkeys[self.hotkey_count];
            return;
        };
        return error.HotkeyNotFound;
    }
    pub fn clearHotkeys(self: *Owner) !void {
        _ = try self.require();
        while (self.hotkey_count != 0) try self.unregisterHotkey(self.hotkeys[self.hotkey_count - 1].id);
    }

    /// One outstanding notification per Owner, on its own shell icon. Replacing
    /// it allocates a new native identity, so late events cannot target it.
    /// Success means submission to the shell, not guaranteed user visibility.
    pub fn showNotification(self: *Owner, id: u64, options: types.NotificationOptions) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (id == 0) return error.InvalidNotificationId;
        if (options.body.len == 0) return error.EmptyNotification;
        var value = std.mem.zeroes(c.NOTIFYICONDATAW);
        _ = try wideZ(&value.szInfoTitle, options.title);
        _ = try wideZ(&value.szInfo, options.body);
        const native_id = try window.reserveNativeIds(1);
        const hwnd = self.hwnd;
        const icon = c.CopyIcon(c.LoadIconW(null, @ptrFromInt(32512))) orelse return self.failed(error.IconCopyFailed);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyIcon(icon);
        };
        const tray: Tray = .{ .id = native_id, .icon = icon, .tooltip = @splat(0) };
        try self.addTray(tray);
        var added = true;
        defer if (added) {
            _ = self.deleteTrayAt(hwnd, tray);
        };
        value.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        value.hWnd = hwnd;
        value.uID = native_id;
        value.uFlags = @as(c.UINT, @intCast(c.NIF_INFO)) | @as(c.UINT, if (options.real_time) c.NIF_REALTIME else 0);
        value.dwInfoFlags = @as(c.DWORD, switch (options.kind) {
            .info => c.NIIF_INFO,
            .warning => c.NIIF_WARNING,
            .err => c.NIIF_ERROR,
        }) | @as(c.DWORD, if (options.silent) c.NIIF_NOSOUND else 0);
        if (c.Shell_NotifyIconW(c.NIM_MODIFY, &value) == 0) return self.failed(error.NotificationSubmissionFailed);
        if (window.isClosed()) return error.Closed;
        const previous = self.notification;
        self.notification = .{ .id = id, .tray = tray };
        owned = false;
        added = false;
        if (previous) |old| {
            _ = self.deleteTrayAt(hwnd, old.tray);
            _ = c.DestroyIcon(old.tray.icon);
        }
    }
    pub fn clearNotification(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const notification = self.notification orelse return;
        self.notification = null;
        const removed = self.deleteTrayAt(self.hwnd, notification.tray);
        _ = c.DestroyIcon(notification.tray.icon);
        if (!removed) return error.NotificationRemovalFailed;
    }

    /// Replaces the bar transactionally. Labels are copied by Win32 during this
    /// call. Native menus allocate only on explicit configuration changes.
    pub fn setMenu(self: *Owner, items: []const types.Item) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (items.len > types.max_menu_items) return error.TooManyMenuItems;
        var command_count: usize = 0;
        for (items, 0..) |item, index| {
            if (item.kind != .separator) {
                if (item.id == 0) return error.InvalidMenuId;
                for (items[0..index]) |previous| if (previous.kind != .separator and previous.id == item.id) return error.DuplicateMenuId;
            }
            if (item.parent) |parent| {
                var found = false;
                for (items[0..index]) |previous| if (previous.kind == .submenu and previous.id == parent) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidMenuParent;
            }
            if (item.kind == .command) command_count += 1;
            if (item.kind != .separator) {
                var scratch: [256]u16 = undefined;
                _ = try wideZ(&scratch, item.label);
            }
        }
        const first_command = if (command_count == 0) @as(u16, 0) else try window.reserveNativeIds(@intCast(command_count));
        const menu = c.CreateMenu() orelse return self.failed(error.MenuCreationFailed);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyMenu(menu);
        };
        var submenus: [types.max_menu_items]c.HMENU = @splat(null);
        var enabled: [types.max_menu_items]bool = undefined;
        var entries: [types.max_menu_items]Entry = undefined;
        var count: usize = 0;
        var command: u32 = first_command;
        for (items, 0..) |item, index| {
            var parent_menu = menu;
            enabled[index] = item.enabled;
            if (item.parent) |parent| for (items[0..index], 0..) |previous, parent_index| {
                if (previous.kind == .submenu and previous.id == parent) {
                    parent_menu = submenus[parent_index].?;
                    enabled[index] = item.enabled and enabled[parent_index];
                    break;
                }
            };
            if (item.kind == .separator) {
                if (c.AppendMenuW(parent_menu, c.MF_SEPARATOR, 0, null) == 0) return self.failed(error.MenuCreationFailed);
                continue;
            }
            var label: [256]u16 = undefined;
            const text = try wideZ(&label, item.label);
            const flags: c.UINT = @as(c.UINT, @intCast(c.MF_STRING)) | @as(c.UINT, @intCast(if (item.enabled) 0 else c.MF_GRAYED)) | @as(c.UINT, @intCast(if (item.checked) c.MF_CHECKED else 0));
            if (item.kind == .submenu) {
                const submenu = c.CreatePopupMenu() orelse return self.failed(error.MenuCreationFailed);
                if (c.AppendMenuW(parent_menu, flags | @as(c.UINT, @intCast(c.MF_POPUP)), @intFromPtr(submenu), text.ptr) == 0) {
                    _ = c.DestroyMenu(submenu);
                    return self.failed(error.MenuCreationFailed);
                }
                submenus[index] = submenu;
            } else {
                if (c.AppendMenuW(parent_menu, flags, command, text.ptr) == 0) return self.failed(error.MenuCreationFailed);
                var ancestor_enabled = true;
                if (item.parent) |parent| for (items[0..index], 0..) |previous, parent_index| {
                    if (previous.kind == .submenu and previous.id == parent) {
                        ancestor_enabled = enabled[parent_index];
                        break;
                    }
                };
                entries[count] = .{ .id = item.id, .command = @intCast(command), .menu = parent_menu, .enabled = enabled[index], .ancestor_enabled = ancestor_enabled };
                count += 1;
                command += 1;
            }
        }
        if (c.SetMenu(self.hwnd, menu) == 0) return self.failed(error.MenuAttachFailed);
        owned = false;
        const old = self.menu;
        self.menu = menu;
        @memcpy(self.entries[0..count], entries[0..count]);
        self.entry_count = count;
        if (old != null) _ = c.DestroyMenu(old);
        _ = c.DrawMenuBar(self.hwnd);
    }
    pub fn clearMenu(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const menu = self.menu orelse return;
        if (c.SetMenu(self.hwnd, null) == 0) return self.failed(error.MenuDetachFailed);
        self.menu = null;
        self.entry_count = 0;
        _ = c.DestroyMenu(menu);
        _ = c.DrawMenuBar(self.hwnd);
    }
    /// Updates a command item. Submenu state changes use a new setMenu snapshot.
    pub fn setItemState(self: *Owner, id: u64, enabled: bool, checked: bool) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        for (self.entries[0..self.entry_count]) |*entry| if (entry.id == id) {
            var info = std.mem.zeroes(c.MENUITEMINFOW);
            info.cbSize = @sizeOf(c.MENUITEMINFOW);
            info.fMask = c.MIIM_STATE;
            info.fState = @as(c.UINT, @intCast(if (enabled) c.MFS_ENABLED else c.MFS_DISABLED)) | @as(c.UINT, @intCast(if (checked) c.MFS_CHECKED else c.MFS_UNCHECKED));
            if (c.SetMenuItemInfoW(entry.menu, entry.command, c.FALSE, &info) == 0) return self.failed(error.MenuUpdateFailed);
            entry.enabled = enabled and entry.ancestor_enabled;
            _ = c.DrawMenuBar(self.hwnd);
            return;
        };
        return error.MenuItemNotFound;
    }

    pub fn setTray(self: *Owner, options: types.TrayOptions) !void {
        const window = try self.require();
        const hwnd = self.hwnd;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const id = try window.reserveNativeIds(1);
        var tooltip: [128]u16 = @splat(0);
        _ = try wideZ(&tooltip, options.tooltip);
        const source: c.HICON = if (options.icon) |icon| @ptrCast(icon) else c.LoadIconW(null, @ptrFromInt(32512));
        const icon = c.CopyIcon(source) orelse return self.failed(error.IconCopyFailed);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyIcon(icon);
        };
        const tray: Tray = .{ .id = id, .icon = icon, .tooltip = tooltip };
        try self.addTray(tray);
        if (window.isClosed()) {
            _ = self.deleteTrayAt(hwnd, tray);
            return error.Closed;
        }
        const previous = self.tray;
        self.tray = tray;
        owned = false;
        if (previous) |old| {
            _ = self.deleteTrayAt(hwnd, old);
            _ = c.DestroyIcon(old.icon);
        }
    }
    pub fn clearTray(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const tray = self.tray orelse return;
        self.tray = null;
        const removed = self.deleteTrayAt(self.hwnd, tray);
        _ = c.DestroyIcon(tray.icon);
        if (!removed) return error.TrayRemovalFailed;
    }
    fn data(self: *const Owner, tray: Tray) c.NOTIFYICONDATAW {
        var result = std.mem.zeroes(c.NOTIFYICONDATAW);
        result.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        result.hWnd = self.hwnd;
        result.uID = tray.id;
        result.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP | c.NIF_SHOWTIP;
        result.uCallbackMessage = tray_message;
        result.hIcon = tray.icon;
        result.szTip = tray.tooltip;
        return result;
    }
    fn addTray(self: *Owner, tray: Tray) !void {
        var value = self.data(tray);
        if (c.Shell_NotifyIconW(c.NIM_ADD, &value) == 0) return self.failed(error.TrayCreationFailed);
        value.unnamed_0.uVersion = c.NOTIFYICON_VERSION_4;
        if (c.Shell_NotifyIconW(c.NIM_SETVERSION, &value) == 0) {
            self.last_error = c.GetLastError();
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &value);
            return error.TrayVersionFailed;
        }
    }
    fn deleteTrayAt(self: *Owner, hwnd: c.HWND, tray: Tray) bool {
        var value = self.data(tray);
        value.hWnd = hwnd;
        c.SetLastError(0);
        if (c.Shell_NotifyIconW(c.NIM_DELETE, &value) != 0) return true;
        self.last_error = c.GetLastError();
        return false;
    }
    fn nativeDestroying(ptr: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.picker.detach();
        while (self.hotkey_count != 0) {
            self.hotkey_count -= 1;
            _ = c.UnregisterHotKey(self.hwnd, self.hotkeys[self.hotkey_count].native_id);
        }
        if (self.notification) |notification| {
            self.notification = null;
            _ = self.deleteTrayAt(self.hwnd, notification.tray);
            _ = c.DestroyIcon(notification.tray.icon);
        }
        if (self.tray) |tray| {
            self.tray = null;
            _ = self.deleteTrayAt(self.hwnd, tray);
            _ = c.DestroyIcon(tray.icon);
        }
        if (self.menu) |menu| {
            self.menu = null;
            // A menu still assigned to a dying HWND is destroyed by Win32.
            // Once detached (including explicit service removal), we own it.
            if (c.SetMenu(self.hwnd, null) != 0) _ = c.DestroyMenu(menu);
        }
        self.entry_count = 0;
        self.window = null;
        self.hwnd = null;
    }
    fn message(ptr: *anyopaque, window: z.Window, native_message: u32, wp: usize, lp: isize) ?isize {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        if (native_message == c.WM_HOTKEY) {
            for (self.hotkeys[0..self.hotkey_count]) |entry| if (wp == entry.native_id) {
                const bits: usize = @bitCast(lp);
                if (bits == (@as(usize, entry.key) << 16) | entry.modifiers) self.on_action(self.context, window, .{ .hotkey = entry.id });
                return 0;
            };
            return 0;
        } else if (native_message == c.WM_COMMAND and lp == 0 and wp >> 16 == 0) {
            const command: u16 = @truncate(wp);
            for (self.entries[0..self.entry_count]) |entry| if (entry.command == command) {
                if (entry.enabled) self.on_action(self.context, window, .{ .menu = entry.id });
                return 0;
            };
        } else if (native_message == tray_message) {
            const bits: usize = @bitCast(lp);
            if (self.notification) |notification| if (@as(u16, @truncate(bits >> 16)) == notification.tray.id) {
                switch (@as(u16, @truncate(bits))) {
                    c.NIN_BALLOONUSERCLICK, c.NIN_BALLOONTIMEOUT, c.NIN_BALLOONHIDE => {
                        const clicked = @as(u16, @truncate(bits)) == c.NIN_BALLOONUSERCLICK;
                        self.clearNotification() catch |err| {
                            window.report(.{ .severity = .warning, .domain = .win32, .operation = .window_update, .err = err, .code = if (self.last_error != 0) self.last_error else null });
                            // The diagnostic sink may detach and replace Owner.
                            return 0;
                        };
                        if (clicked and !window.isClosed()) self.on_action(self.context, window, .{ .notification_activated = notification.id });
                    },
                    else => {},
                }
                return 0;
            };
            const tray = self.tray orelse return 0;
            if (@as(u16, @truncate(bits >> 16)) != tray.id) return 0;
            switch (@as(u16, @truncate(bits))) {
                c.NIN_SELECT, c.NIN_KEYSELECT => self.on_action(self.context, window, .tray_activate),
                c.WM_CONTEXTMENU => self.on_action(self.context, window, .{ .tray_context = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(wp)))), .y = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))) } }),
                else => {},
            }
            return 0;
        } else if (native_message == self.taskbar_created) {
            // Shell restart invalidates submitted notifications; do not replay
            // stale user messages. Persistent tray configuration is restored.
            if (self.notification) |notification| {
                self.notification = null;
                _ = c.DestroyIcon(notification.tray.icon);
            }
            if (self.tray) |tray| self.addTray(tray) catch |err| window.report(.{ .severity = .warning, .domain = .win32, .operation = .window_update, .err = err, .code = self.last_error });
            return 0;
        }
        return null;
    }
};

fn modifierBits(modifiers: types.Modifiers) u32 {
    return @as(u32, if (modifiers.control) c.MOD_CONTROL else 0) | @as(u32, if (modifiers.alt) c.MOD_ALT else 0) | @as(u32, if (modifiers.shift) c.MOD_SHIFT else 0) | @as(u32, if (modifiers.super) c.MOD_WIN else 0);
}
fn virtualKey(key: types.Key) u32 {
    return switch (key) {
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => 0x41 + @as(u32, @intFromEnum(key)) - @intFromEnum(types.Key.a),
        .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => 0x30 + @as(u32, @intFromEnum(key)) - @intFromEnum(types.Key.digit0),
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => 0x70 + @as(u32, @intFromEnum(key)) - @intFromEnum(types.Key.f1),
        .space => c.VK_SPACE,
        .enter => c.VK_RETURN,
        .escape => c.VK_ESCAPE,
        .tab => c.VK_TAB,
        .backspace => c.VK_BACK,
        .delete => c.VK_DELETE,
        .insert => c.VK_INSERT,
        .home => c.VK_HOME,
        .end => c.VK_END,
        .page_up => c.VK_PRIOR,
        .page_down => c.VK_NEXT,
        .left => c.VK_LEFT,
        .right => c.VK_RIGHT,
        .up => c.VK_UP,
        .down => c.VK_DOWN,
    };
}

fn wideZ(destination: []u16, source: []const u8) ![:0]const u16 {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.EmbeddedNul;
    const needed = std.unicode.calcUtf16LeLen(source) catch return error.InvalidUtf8;
    if (needed >= destination.len) return error.TextCapacityExceeded;
    const count = std.unicode.utf8ToUtf16Le(destination[0..needed], source) catch return error.InvalidUtf8;
    destination[count] = 0;
    return destination[0..count :0];
}
