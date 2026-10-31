const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const picker_api = @import("picker.zig");
const menus = @import("menus.zig");
const native_menu = @import("windows_menu.zig");
const message_api = @import("message.zig");
const c = @import("ziggurat_c_win32");

/// Reserved on the owner HWND while attached. Command IDs and tray IDs are never
/// reused during the HWND's lifetime, so queued old messages cannot target a
/// replacement item. No business state or callback dispatch table is global.
pub const tray_message: u32 = c.WM_APP + 0x421;
const Entry = native_menu.Entry;
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
    popup: native_menu.Host = .{ .context = undefined, .done = popupDone },
    message_dialog: message_api.Message = .{},
    /// A window that shows a material has no menu bar: the menu stays here
    /// and Alt or F10 open it in a popup.
    barless: bool = false,
    /// The letter of Alt and a letter that opened the bar popup, and the popup.
    menu_key: struct { popup: c.HMENU = null, key: usize = 0 } = .{},

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
        self.barless = (window.capabilities() catch return error.Closed).vibrancy;
        try window.setService(.{ .context = self, .message = message, .native_destroying = nativeDestroying });
    }
    pub fn detach(self: *Owner) !void {
        const window = self.window orelse return;
        window.app.assertOwner();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.picker.detach();
        self.message_dialog.detach();
        self.popup.detach();
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
    /// Accelerators match keys that the window's content leaves unconsumed.
    pub fn setMenu(self: *Owner, items: []const types.Item) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const plan = try menus.validate(items, false);
        const first_command = if (plan.commands == 0) @as(u16, 0) else try window.reserveNativeIds(@intCast(plan.commands));
        var entries: [types.max_menu_items]Entry = undefined;
        const built = native_menu.build(items, &plan, false, first_command, &entries) catch |err| return self.failed(err);
        const menu = built.menu;
        if (!self.barless and c.SetMenu(self.hwnd, menu) == 0) {
            _ = c.DestroyMenu(menu);
            return self.failed(error.MenuAttachFailed);
        }
        const old = self.menu;
        self.menu = menu;
        @memcpy(self.entries[0..built.count], entries[0..built.count]);
        self.entry_count = built.count;
        if (old != null) _ = c.DestroyMenu(old);
        _ = c.DrawMenuBar(self.hwnd);
    }
    pub fn clearMenu(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const menu = self.menu orelse return;
        if (!self.barless and c.SetMenu(self.hwnd, null) == 0) return self.failed(error.MenuDetachFailed);
        self.menu = null;
        self.entry_count = 0;
        _ = c.DestroyMenu(menu);
        _ = c.DrawMenuBar(self.hwnd);
    }
    /// Updates a command item. Submenu state changes use a new setMenu snapshot.
    /// Checking a radio item unchecks the rest of its group.
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
            if (checked and entry.radio_last != 0 and c.CheckMenuRadioItem(entry.menu, entry.radio_first, entry.radio_last, entry.command, c.MF_BYCOMMAND) == 0) return self.failed(error.MenuUpdateFailed);
            entry.enabled = enabled and entry.ancestor_enabled;
            _ = c.DrawMenuBar(self.hwnd);
            return;
        };
        return error.MenuItemNotFound;
    }

    /// Opens a context menu after this call returns. The request completes
    /// once with `Action.popup`; detach or window closure completes nothing.
    /// One popup is pending per Owner. Labels are copied before return.
    pub fn popupMenu(self: *Owner, request: u64, items: []const types.Item, anchor: types.Anchor) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var point: c.POINT = .{ .x = 0, .y = 0 };
        switch (anchor) {
            .pointer => if (c.GetCursorPos(&point) == 0) return self.failed(error.MenuStartFailed),
            .screen => |value| point = .{ .x = value.x, .y = value.y },
            .client => |value| {
                if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y)) return error.InvalidAnchor;
                const dpi = c.GetDpiForWindow(self.hwnd);
                const scale = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0;
                const x = @round(value.x * scale);
                const y = @round(value.y * scale);
                if (@abs(x) > 1e7 or @abs(y) > 1e7) return error.InvalidAnchor;
                point = .{ .x = @intFromFloat(x), .y = @intFromFloat(y) };
                if (c.ClientToScreen(self.hwnd, &point) == 0) return self.failed(error.MenuStartFailed);
            },
        }
        self.popup.context = self;
        self.popup.start(request, items, self.hwnd, .{ .x = point.x, .y = point.y }) catch |err| {
            if (self.popup.last_error != 0) self.last_error = self.popup.last_error;
            return err;
        };
    }
    /// Closes a pending popup; its request still completes with null.
    pub fn cancelPopup(self: *Owner) !void {
        _ = try self.require();
        self.popup.cancel();
    }
    fn popupDone(ptr: *anyopaque, request: u64, selected: ?u64) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        const window = self.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        if (window.isClosed()) return;
        self.on_action(self.context, window, .{ .popup = .{ .request = request, .selected = selected } });
    }

    /// Shows an asynchronous message dialog and returns before it closes.
    /// The result arrives once as `Action.message` on the main thread.
    pub fn showMessage(self: *Owner, request: u64, options: types.MessageOptions) !void {
        const window = try self.require();
        try self.message_dialog.start(window, request, options, self, messageDone);
    }
    /// Closes a pending message; its request still completes as dismissed.
    pub fn cancelMessage(self: *Owner) !void {
        _ = try self.require();
        try self.message_dialog.cancel();
    }
    fn messageDone(ptr: *anyopaque, window: z.Window, result: types.MessageResult) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.on_action(self.context, window, .{ .message = result });
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
        self.message_dialog.detach();
        self.popup.detach();
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
            if (self.barless or c.SetMenu(self.hwnd, null) != 0) _ = c.DestroyMenu(menu);
        }
        self.entry_count = 0;
        self.window = null;
        self.hwnd = null;
    }
    /// Shows the bar's menus in a popup at the top of the client area. The
    /// submenus are the bar's own, taken back before the popup is destroyed.
    fn popupMenuBar(self: *Owner, window: z.Window, key: usize) void {
        const bar = self.menu orelse return;
        const count = c.GetMenuItemCount(bar);
        if (count <= 0) return;
        const popup = c.CreatePopupMenu() orelse return;
        defer {
            var index = count;
            while (index > 0) {
                index -= 1;
                _ = c.RemoveMenu(popup, @intCast(index), c.MF_BYPOSITION);
            }
            _ = c.DestroyMenu(popup);
        }
        for (0..@intCast(count)) |index| {
            var label: [256]u16 = undefined;
            if (c.GetMenuStringW(bar, @intCast(index), &label, label.len, c.MF_BYPOSITION) < 0) label[0] = 0;
            const state: c.UINT = c.GetMenuState(bar, @intCast(index), c.MF_BYPOSITION);
            var flags: c.UINT = @as(c.UINT, c.MF_STRING) | (state & @as(c.UINT, c.MF_GRAYED));
            var item: usize = 0;
            if (c.GetSubMenu(bar, @intCast(index))) |submenu| {
                flags |= @as(c.UINT, c.MF_POPUP);
                item = @intFromPtr(submenu);
            } else item = c.GetMenuItemID(bar, @intCast(index));
            if (state & @as(c.UINT, c.MF_SEPARATOR) != 0) flags = c.MF_SEPARATOR;
            _ = c.AppendMenuW(popup, flags, item, &label);
        }
        var point: c.POINT = .{ .x = 0, .y = 0 };
        _ = c.ClientToScreen(self.hwnd, &point);
        if (key != 0) {
            // The menu loop takes the letter as typed in the popup.
            self.menu_key = .{ .popup = popup, .key = key };
            _ = c.PostMessageW(self.hwnd, c.WM_CHAR, key, 0);
        }
        const command = c.TrackPopupMenuEx(popup, c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_LEFTALIGN | c.TPM_TOPALIGN, point.x, point.y, self.hwnd, null);
        self.menu_key = .{};
        if (command <= 0 or window.isClosed() or self.window == null) return;
        for (self.entries[0..self.entry_count]) |entry| if (entry.command == command) {
            if (entry.enabled) self.on_action(self.context, window, .{ .menu = entry.id });
            return;
        };
    }
    fn message(ptr: *anyopaque, window: z.Window, native_message: u32, wp: usize, lp: isize) ?isize {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        if ((native_message == c.WM_KEYDOWN or native_message == c.WM_SYSKEYDOWN) and self.entry_count != 0) {
            const pressed = native_menu.pressed(wp, lp) orelse return null;
            for (self.entries[0..self.entry_count]) |entry| if (entry.accelerator) |accelerator| if (menus.sameAccelerator(accelerator, pressed)) {
                if (!entry.enabled) return null;
                self.on_action(self.context, window, .{ .menu = entry.id });
                return 0;
            };
            return null;
        }
        if (native_message == c.WM_SYSCOMMAND and wp & 0xfff0 == c.SC_KEYMENU and lp != ' ' and self.barless and self.menu != null) {
            // Alt or F10 alone (lp 0) take the keyboard to the menus, and Alt
            // and a letter (lp the letter) open the menu of the letter; Alt
            // and Space keep opening the window menu.
            self.popupMenuBar(window, @bitCast(lp));
            return 0;
        }
        if (native_message == c.WM_MENUCHAR) {
            // Alt and a letter that names no menu of the bar open none, as in
            // the bar: the popup closes.
            if (self.menu_key.popup != null and @intFromPtr(self.menu_key.popup) == @as(usize, @bitCast(lp)) and wp & 0xffff == self.menu_key.key) return c.MNC_CLOSE << 16;
            return null;
        }
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
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => 0x41 + @as(u32, @backingInt(key)) - @backingInt(types.Key.a),
        .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9 => 0x30 + @as(u32, @backingInt(key)) - @backingInt(types.Key.digit0),
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24 => 0x70 + @as(u32, @backingInt(key)) - @backingInt(types.Key.f1),
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
        .plus => c.VK_OEM_PLUS,
        .minus => c.VK_OEM_MINUS,
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
