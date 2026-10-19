//! Standalone notification-area items that belong to the App rather than to a
//! window. Each Tray owns a hidden message window, a copied icon and a stop
//! registration, so App shutdown removes it even if the caller forgets to.
const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const native_menu = @import("windows_menu.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

pub const callback_message: u32 = c.WM_APP + 0x422;
const self_slot = 0;
var tray_class: c.ATOM = 0;

/// Keep at a stable address from show() until remove() or App stop. Every
/// operation and callback runs on the App's main thread.
pub const Tray = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void,
    app: ?*z.App = null,
    hwnd: c.HWND = null,
    icon: c.HICON = null,
    tooltip: [128]u16 = @splat(0),
    guid: ?c.GUID = null,
    /// Advances for every shell registration, so late callbacks for a
    /// replaced icon cannot reach the current one.
    id: u16 = 0,
    taskbar_created: u32 = 0,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    popup: native_menu.Host = .{ .context = undefined, .done = popupDone },
    last_error: u32 = 0,

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void) Tray {
        return .{ .context = context, .on_action = on_action };
    }

    /// Creates the item, or replaces its icon and tooltip in place. The icon
    /// is borrowed during the call; the Tray keeps its own copy.
    pub fn show(self: *Tray, app: *z.App, options: types.TrayItemOptions) !void {
        app.assertOwner();
        if (self.app) |current| if (current != app) return error.AlreadyAttached;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        var tooltip: [128]u16 = @splat(0);
        try wideZ(&tooltip, options.tooltip);
        const source: c.HICON = if (options.icon) |icon| @ptrCast(icon) else c.LoadIconW(null, @ptrFromInt(32512));
        const icon = c.CopyIcon(source) orelse return self.failed(error.IconCopyFailed);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyIcon(icon);
        };
        const guid: ?c.GUID = if (options.guid) |bytes| nativeGuid(bytes) else null;
        if (self.app == null) {
            if (self.id == std.math.maxInt(u16)) return error.IdExhausted;
            try self.createWindow();
            errdefer self.destroyWindow();
            self.stop_node = .{ .context = self, .stop = stopped };
            self.stop_token = try app.registerStop(&self.stop_node);
            errdefer _ = app.cancelStop(self.stop_token.?) catch {};
            self.id += 1;
            self.guid = guid;
            try self.add(icon, tooltip);
            self.app = app;
            self.icon = icon;
            self.tooltip = tooltip;
            owned = false;
            return;
        }
        if (!std.meta.eql(self.guid, guid)) return error.TrayIdentityChanged;
        var value = self.data(icon, tooltip);
        if (c.Shell_NotifyIconW(c.NIM_MODIFY, &value) == 0) return self.failed(error.TrayUpdateFailed);
        _ = c.DestroyIcon(self.icon);
        self.icon = icon;
        self.tooltip = tooltip;
        owned = false;
    }

    /// Removes the item. A pending popup is dismissed silently.
    pub fn remove(self: *Tray) !void {
        const app = self.app orelse return;
        app.assertOwner();
        const scope = app.beginTeardownCallback();
        defer scope.end();
        if (self.stop_token) |token| _ = try app.cancelStop(token);
        self.stop_token = null;
        self.release();
    }

    /// Opens a menu near the tray icon after this call returns. Use it from
    /// `TrayAction.context` so the shell grants the foreground. The request
    /// completes once with `TrayAction.popup` unless the Tray is removed.
    pub fn popupMenu(self: *Tray, request: u64, items: []const types.Item, anchor: types.TrayAnchor) !void {
        const app = self.app orelse return error.NotAttached;
        app.assertOwner();
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        var placement: native_menu.Placement = .{ .x = 0, .y = 0, .foreground = true };
        var cursor: c.POINT = .{ .x = 0, .y = 0 };
        switch (anchor) {
            .screen => |point| {
                placement.x = point.x;
                placement.y = point.y;
            },
            .pointer => {
                if (c.GetCursorPos(&cursor) == 0) return self.failed(error.MenuStartFailed);
                placement.x = cursor.x;
                placement.y = cursor.y;
            },
            .icon => {
                var identifier = std.mem.zeroes(c.NOTIFYICONIDENTIFIER);
                identifier.cbSize = @sizeOf(c.NOTIFYICONIDENTIFIER);
                identifier.hWnd = self.hwnd;
                identifier.uID = self.id;
                if (self.guid) |guid| identifier.guidItem = guid;
                var rect = std.mem.zeroes(c.RECT);
                if (c.Shell_NotifyIconGetRect(&identifier, &rect) >= 0) {
                    placement.x = rect.left;
                    placement.y = rect.top;
                    placement.exclude = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                } else {
                    if (c.GetCursorPos(&cursor) == 0) return self.failed(error.MenuStartFailed);
                    placement.x = cursor.x;
                    placement.y = cursor.y;
                }
            },
        }
        self.popup.context = self;
        self.popup.start(request, items, self.hwnd, placement) catch |err| {
            if (self.popup.last_error != 0) self.last_error = self.popup.last_error;
            return err;
        };
    }
    pub fn cancelPopup(self: *Tray) void {
        if (self.app) |app| app.assertOwner();
        self.popup.cancel();
    }

    fn popupDone(ptr: *anyopaque, request: u64, selected: ?u64) void {
        const self: *Tray = @ptrCast(@alignCast(ptr));
        const app = self.app orelse return;
        const scope = app.beginCallback() orelse return;
        defer scope.end();
        self.on_action(self.context, self, .{ .popup = .{ .request = request, .selected = selected } });
    }

    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *Tray = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.release();
    }

    fn release(self: *Tray) void {
        self.popup.detach();
        if (self.icon != null) {
            var value = self.data(self.icon, self.tooltip);
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &value);
            _ = c.DestroyIcon(self.icon);
            self.icon = null;
        }
        self.destroyWindow();
        self.app = null;
        self.guid = null;
    }

    fn failed(self: *Tray, err: anyerror) anyerror {
        self.last_error = c.GetLastError();
        return err;
    }

    fn data(self: *const Tray, icon: c.HICON, tooltip: [128]u16) c.NOTIFYICONDATAW {
        var result = std.mem.zeroes(c.NOTIFYICONDATAW);
        result.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        result.hWnd = self.hwnd;
        result.uID = self.id;
        result.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP | c.NIF_SHOWTIP;
        if (self.guid) |guid| {
            result.uFlags |= c.NIF_GUID;
            result.guidItem = guid;
        }
        result.uCallbackMessage = callback_message;
        result.hIcon = icon;
        result.szTip = tooltip;
        return result;
    }

    fn add(self: *Tray, icon: c.HICON, tooltip: [128]u16) !void {
        var value = self.data(icon, tooltip);
        if (c.Shell_NotifyIconW(c.NIM_ADD, &value) == 0) return self.failed(error.TrayCreationFailed);
        value.unnamed_0.uVersion = c.NOTIFYICON_VERSION_4;
        if (c.Shell_NotifyIconW(c.NIM_SETVERSION, &value) == 0) {
            self.last_error = c.GetLastError();
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &value);
            return error.TrayVersionFailed;
        }
    }

    fn createWindow(self: *Tray) !void {
        const instance = c.GetModuleHandleW(null);
        const name = std.unicode.utf8ToUtf16LeStringLiteral("ZigguratSystemTray");
        if (tray_class == 0) {
            var class = std.mem.zeroes(c.WNDCLASSEXW);
            class.cbSize = @sizeOf(c.WNDCLASSEXW);
            class.lpfnWndProc = trayProc;
            class.cbWndExtra = @sizeOf(usize);
            class.hInstance = instance;
            class.lpszClassName = name;
            tray_class = c.RegisterClassExW(&class);
            if (tray_class == 0) return self.failed(error.TrayCreationFailed);
        }
        if (self.taskbar_created == 0) {
            self.taskbar_created = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));
            if (self.taskbar_created == 0) return self.failed(error.MessageRegistrationFailed);
        }
        // A hidden top-level window, not a message-only one, receives the
        // shell's TaskbarCreated broadcast and can own the tray menu.
        const hwnd = c.CreateWindowExW(c.WS_EX_TOOLWINDOW, name, name, c.WS_POPUP, 0, 0, 0, 0, null, null, instance, null) orelse return self.failed(error.TrayCreationFailed);
        _ = c.SetWindowLongPtrW(hwnd, self_slot, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
    }

    fn destroyWindow(self: *Tray) void {
        const hwnd = self.hwnd orelse return;
        self.hwnd = null;
        _ = c.SetWindowLongPtrW(hwnd, self_slot, 0);
        _ = c.DestroyWindow(hwnd);
    }

    fn message(self: *Tray, native_message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) void {
        const app = self.app orelse return;
        if (native_message == self.taskbar_created) {
            // Explorer restarted: the shell forgot every icon. Re-add ours.
            self.add(self.icon, self.tooltip) catch |err| app.report(.{ .severity = .warning, .domain = .win32, .operation = .window_update, .err = err, .code = self.last_error });
            return;
        }
        if (native_message != callback_message) return;
        const bits: usize = @bitCast(lp);
        if (@as(u16, @truncate(bits >> 16)) != self.id) return;
        const scope = app.beginCallback() orelse return;
        defer scope.end();
        switch (@as(u16, @truncate(bits))) {
            c.NIN_SELECT, c.NIN_KEYSELECT => self.on_action(self.context, self, .activate),
            c.WM_CONTEXTMENU => self.on_action(self.context, self, .{ .context = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(wp)))), .y = @as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))) } }),
            else => {},
        }
    }
};

fn trayProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const address: usize = @bitCast(c.GetWindowLongPtrW(hwnd, self_slot));
    if (address != 0 and (message == callback_message or message >= 0xc000)) {
        const tray: *Tray = @ptrFromInt(address);
        if (tray.hwnd == hwnd) tray.message(message, wp, lp);
        return 0;
    }
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

/// Bytes in the order the identifier is written as text.
fn nativeGuid(bytes: [16]u8) c.GUID {
    return .{ .Data1 = std.mem.readInt(u32, bytes[0..4], .big), .Data2 = std.mem.readInt(u16, bytes[4..6], .big), .Data3 = std.mem.readInt(u16, bytes[6..8], .big), .Data4 = bytes[8..16].* };
}

fn wideZ(destination: []u16, source: []const u8) !void {
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.EmbeddedNul;
    const needed = std.unicode.calcUtf16LeLen(source) catch return error.InvalidUtf8;
    if (needed >= destination.len) return error.TextCapacityExceeded;
    const count = std.unicode.utf8ToUtf16Le(destination[0..needed], source) catch return error.InvalidUtf8;
    destination[count] = 0;
}
