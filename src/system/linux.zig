//! GTK menu bars, popup menus, message dialogs and file choosers for one
//! window, plus session-bus tray items and notifications and X11 global key
//! grabs. Nothing here runs a nested main loop or waits on the bus; native
//! completions return to the main thread through GLib's main context.
const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const menus = @import("menus.zig");
const picker = @import("picker.zig");
const desktop = @import("desktop.zig");

const NativeItem = extern struct { label: [*:0]const u8, parent: i32, kind: u8, enabled: u8, checked: u8, padding: u8 = 0, keyval: u32, modifiers: u32, command: i32 };
const Done = *const fn (?*anyopaque, u64, i32) callconv(.c) void;
const TrayEvent = *const fn (?*anyopaque, u64, i32, i32, i32) callconv(.c) void;
extern fn zsl_popup_show(?*anyopaque, [*]const NativeItem, u32, c_int, f64, f64, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_popup_cancel(*anyopaque) void;
extern fn zsl_message_show(?*anyopaque, [*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, u32, i32, c_int, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_message_cancel(*anyopaque) void;
extern fn zsl_detach(*anyopaque) void;
extern fn zsl_live_links() c_int;
extern fn zsl_menubar_set(?*anyopaque, [*]const NativeItem, u32, [*]const u8, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_menubar_state(*anyopaque, i32, c_int, c_int, c_int) c_int;
extern fn zsl_menubar_remove(*anyopaque, c_int) void;
extern fn zsl_chooser_show(?*anyopaque, c_int, [*]const [*:0]const u8, u32, [*:0]const u8, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_chooser_path(*anyopaque, u32, *?[*]const u8, *usize) void;
extern fn zsl_chooser_cancel(*anyopaque) void;
extern fn zsl_chooser_detach(*anyopaque) void;
extern fn zsl_tray_show(?*anyopaque, [*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?*anyopaque, u64, TrayEvent, *c_int) ?*anyopaque;
extern fn zsl_tray_update(*anyopaque, ?*anyopaque, [*:0]const u8, [*:0]const u8) c_int;
extern fn zsl_tray_menu(*anyopaque, [*]const NativeItem, u32) void;
extern fn zsl_tray_remove(*anyopaque) void;
extern fn zsl_note_show([*:0]const u8, [*:0]const u8, c_int, c_int, c_int, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsl_note_close(*anyopaque) void;
extern fn zsl_hotkey_register(u32, u32, c_int, ?*anyopaque, u64, Done, *c_int, *c_int) ?*anyopaque;
extern fn zsl_hotkey_unregister(*anyopaque) void;
extern fn zsl_desktop_live_records() c_int;
pub extern fn zsl_popup_activate(*anyopaque, i32) c_int;
pub extern fn zsl_message_press(*anyopaque, i32) c_int;
pub extern fn zsl_message_close(*anyopaque) c_int;
pub extern fn zsl_menubar_activate(*anyopaque, i32) c_int;
pub extern fn zsl_menubar_height(*anyopaque) c_int;
pub extern fn zsl_chooser_select(*anyopaque, [*]const [*:0]const u8, u32, ?[*:0]const u8) c_int;
pub extern fn zsl_chooser_accept(*anyopaque, u32, ?[*:0]const u8) c_int;
pub extern fn zsl_chooser_complete(*anyopaque, [*]const [*:0]const u8, u32) c_int;
pub extern fn zsl_tray_path(*anyopaque) [*:0]const u8;
pub extern fn zsl_tray_menu_path(*anyopaque) [*:0]const u8;
pub extern fn zsl_note_server_id(*anyopaque) u32;

pub const message = struct {
    /// Native menu, dialog, chooser, tray, notification and key-grab records
    /// still alive, including ones whose owner has detached while GTK or a bus
    /// call finishes with them.
    pub fn resourceCount() u32 {
        return @intCast(zsl_live_links() + zsl_desktop_live_records());
    }
};

const Pending = struct {
    native: ?*anyopaque = null,
    request: u64 = 0,
    serial: u64 = 0,
};
const BarEntry = struct { id: u64, enabled: bool, ancestors: bool };
const HotkeyEntry = struct { id: u64, native: *anyopaque, serial: u64 };
const Notification = struct { id: u64, native: *anyopaque, serial: u64 };
const Chooser = struct {
    native: *anyopaque,
    serial: u64,
    kind: picker.Kind,
    destination: []u8,
    context: *anyopaque,
    on_result: picker.Callback,
};

/// Popup menu state shared by window owners and standalone tray items.
const Popup = struct {
    pending: Pending = .{},
    ids: [types.max_menu_items]u64 = undefined,
    enabled: [types.max_menu_items]bool = undefined,
    count: usize = 0,

    fn start(self: *Popup, window: ?*anyopaque, items: []const types.Item, kind: c_int, x: f64, y: f64, owner: *anyopaque, request: u64, serial: u64, done: Done) !void {
        if (self.pending.native != null) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const plan = try menus.validate(items, true);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        const commands = try nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        var failure: c_int = 0;
        const native = zsl_popup_show(window, &native_items, @intCast(items.len), kind, x, y, owner, serial, done, &failure) orelse return error.MenuStartFailed;
        self.pending = .{ .native = native, .request = request, .serial = serial };
        @memcpy(self.ids[0..commands], ids[0..commands]);
        @memcpy(self.enabled[0..commands], enabled[0..commands]);
        self.count = commands;
    }
    fn finish(self: *Popup, serial: u64, result: i32) ?types.PopupResult {
        if (self.pending.native == null or self.pending.serial != serial) return null;
        const request = self.pending.request;
        self.pending = .{};
        const index: usize = if (result >= 0) @intCast(result) else std.math.maxInt(usize);
        return .{ .request = request, .selected = if (index < self.count and self.enabled[index]) self.ids[index] else null };
    }
    fn cancel(self: *Popup) void {
        if (self.pending.native) |native| zsl_popup_cancel(native);
    }
    fn detach(self: *Popup) void {
        if (self.pending.native) |native| {
            self.pending = .{};
            zsl_detach(native);
        }
    }
};

/// Keep at a stable address through detach/on_closed. All calls and actions
/// run on the main thread; a pending popup, message or file chooser completes
/// once unless the Owner detaches or its window closes first.
pub const Owner = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, types.Action) void,
    window: ?z.Window = null,
    popup: Popup = .{},
    message_dialog: Pending = .{},
    message_buttons: [types.max_message_buttons]u64 = @splat(0),
    message_cancel: ?u64 = null,
    bar: ?*anyopaque = null,
    bar_serial: u64 = 0,
    bar_entries: [types.max_menu_items]BarEntry = undefined,
    bar_count: usize = 0,
    tray: ?*anyopaque = null,
    tray_serial: u64 = 0,
    notification: ?Notification = null,
    hotkeys: [types.max_hotkeys]HotkeyEntry = undefined,
    hotkey_count: usize = 0,
    chooser: ?Chooser = null,
    chooser_paths: [128][]const u8 = undefined,
    /// The X error code of the last refused key grab, or a bus error code.
    last_error: u32 = 0,
    /// Monotonic, so a late native completion cannot adopt a newer request.
    serial: u64 = 0,

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, types.Action) void) Owner {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(self: *Owner, window: z.Window) !void {
        window.app.assertOwner();
        if (self.window != null) return error.AlreadyAttached;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (window.nativeHandle() == null) return error.Closed;
        self.window = window;
        errdefer self.window = null;
        try window.setService(.{ .context = self, .native_destroying = nativeDestroying });
    }
    /// Removes the menu bar, tray item, notification and key grabs, and
    /// dismisses pending popups, messages and choosers without completing them.
    pub fn detach(self: *Owner) !void {
        const window = self.window orelse return;
        window.app.assertOwner();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.release(!window.isClosed());
        window.clearService(self);
        self.window = null;
    }
    fn require(self: *Owner) !z.Window {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (window.isClosed()) return error.Closed;
        return window;
    }
    fn release(self: *Owner, restore: bool) void {
        self.popup.detach();
        if (self.message_dialog.native) |native| {
            self.message_dialog = .{};
            zsl_detach(native);
        }
        if (self.chooser) |chooser| {
            self.chooser = null;
            zsl_chooser_detach(chooser.native);
        }
        while (self.hotkey_count != 0) {
            self.hotkey_count -= 1;
            zsl_hotkey_unregister(self.hotkeys[self.hotkey_count].native);
        }
        if (self.notification) |notification| {
            self.notification = null;
            zsl_note_close(notification.native);
        }
        if (self.tray) |tray| {
            self.tray = null;
            zsl_tray_remove(tray);
        }
        if (self.bar) |bar| {
            self.bar = null;
            self.bar_count = 0;
            zsl_menubar_remove(bar, @intFromBool(restore));
        }
    }
    fn nativeDestroying(ptr: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.release(false);
        self.window = null;
    }
    fn nextSerial(self: *Owner) !u64 {
        if (self.serial == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.serial += 1;
        return self.serial;
    }
    fn deliver(self: *Owner, action: types.Action) void {
        const window = self.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        if (window.isClosed()) return;
        self.on_action(self.context, window, action);
    }
    fn report(self: *Owner, domain: z.diagnostics.Domain, err: anyerror, code: ?u32) void {
        const window = self.window orelse return;
        if (window.isClosed()) return;
        window.report(.{ .severity = .warning, .domain = domain, .operation = .window_update, .err = err, .code = code });
    }

    /// Replaces the bar transactionally: the new bar takes the old one's place
    /// in the window before the old one is destroyed. Labels are copied by GTK
    /// during this call. Accelerators match keys the content leaves unconsumed.
    pub fn setMenu(self: *Owner, items: []const types.Item) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const plan = try menus.validate(items, false);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        const commands = try nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        var effective: [types.max_menu_items]u8 = undefined;
        var entries: [types.max_menu_items]BarEntry = undefined;
        var command: usize = 0;
        for (items, 0..) |item, index| if (item.kind == .command) {
            effective[command] = @intFromBool(enabled[command]);
            entries[command] = .{ .id = ids[command], .enabled = enabled[command], .ancestors = plan.ancestors_enabled[index] };
            command += 1;
        };
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        const bar = zsl_menubar_set(window.nativeHandle(), &native_items, @intCast(items.len), &effective, self, serial, barDone, &failure) orelse return if (failure == 2) error.Busy else error.MenuAttachFailed;
        const old = self.bar;
        self.bar = bar;
        self.bar_serial = serial;
        @memcpy(self.bar_entries[0..commands], entries[0..commands]);
        self.bar_count = commands;
        if (old) |value| zsl_menubar_remove(value, 0);
    }
    pub fn clearMenu(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const bar = self.bar orelse return;
        self.bar = null;
        self.bar_count = 0;
        zsl_menubar_remove(bar, 1);
    }
    /// Updates a command item. Submenu state changes use a new setMenu snapshot.
    pub fn setItemState(self: *Owner, id: u64, enabled: bool, checked: bool) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const bar = self.bar orelse return error.MenuItemNotFound;
        for (self.bar_entries[0..self.bar_count], 0..) |*entry, index| if (entry.id == id) {
            const effective = enabled and entry.ancestors;
            if (zsl_menubar_state(bar, @intCast(index), @intFromBool(enabled), @intFromBool(effective), @intFromBool(checked)) == 0) return error.MenuUpdateFailed;
            entry.enabled = effective;
            return;
        };
        return error.MenuItemNotFound;
    }
    fn barDone(ptr: ?*anyopaque, serial: u64, command: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        if (self.bar == null or self.bar_serial != serial or command < 0 or command >= self.bar_count) return;
        const entry = self.bar_entries[@intCast(command)];
        if (entry.enabled) self.deliver(.{ .menu = entry.id });
    }

    pub fn popupMenu(self: *Owner, request: u64, items: []const types.Item, anchor: types.Anchor) !void {
        const window = try self.require();
        if (self.popup.pending.native != null) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var kind: c_int = 0;
        var x: f64 = 0;
        var y: f64 = 0;
        switch (anchor) {
            .pointer => {},
            .client => |point| {
                if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or @abs(point.x) > 1e7 or @abs(point.y) > 1e7) return error.InvalidAnchor;
                kind = 1;
                x = point.x;
                y = point.y;
            },
            .screen => |point| {
                kind = 2;
                x = @floatFromInt(point.x);
                y = @floatFromInt(point.y);
            },
        }
        try self.popup.start(window.nativeHandle(), items, kind, x, y, self, request, try self.nextSerial(), popupDone);
    }
    /// Closes a pending popup; its request still completes with null.
    pub fn cancelPopup(self: *Owner) !void {
        _ = try self.require();
        self.popup.cancel();
    }
    fn popupDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        const value = self.popup.finish(serial, result) orelse return;
        self.deliver(.{ .popup = value });
    }

    pub fn showMessage(self: *Owner, request: u64, options: types.MessageOptions) !void {
        const window = try self.require();
        if (self.message_dialog.native != null) return error.MessageAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        try menus.validateMessage(options);
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var title: [1024]u8 = undefined;
        var text: [16384]u8 = undefined;
        var labels: [types.max_message_buttons][256]u8 = undefined;
        var buttons: [types.max_message_buttons][*:0]const u8 = undefined;
        for (options.buttons, 0..) |button, index| buttons[index] = (try menus.gtkMnemonic(&labels[index], button.label)).ptr;
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        const default_index: i32 = if (options.default_button) |index| @intCast(index) else -1;
        const native = zsl_message_show(window.nativeHandle(), try terminated(&title, options.title), try terminated(&text, options.message), &buttons, @intCast(options.buttons.len), default_index, @intFromEnum(options.kind), self, serial, messageDone, &failure) orelse return error.MessageDialogCreationFailed;
        self.message_dialog = .{ .native = native, .request = request, .serial = serial };
        self.message_buttons = @splat(0);
        for (options.buttons, 0..) |button, index| self.message_buttons[index] = button.id;
        self.message_cancel = if (options.cancel_button) |index| options.buttons[index].id else null;
    }
    /// Closes a pending message; its request still completes as dismissed.
    pub fn cancelMessage(self: *Owner) !void {
        _ = try self.require();
        if (self.message_dialog.native) |native| zsl_message_cancel(native);
    }
    fn messageDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        if (self.message_dialog.native == null or self.message_dialog.serial != serial) return;
        const request = self.message_dialog.request;
        self.message_dialog = .{};
        const response: types.MessageResponse = if (result >= 0 and result < self.message_buttons.len and self.message_buttons[@intCast(result)] != 0)
            .{ .button = self.message_buttons[@intCast(result)] }
        else if (result == -1 and self.message_cancel != null) .{ .button = self.message_cancel.? } else .dismissed;
        self.deliver(.{ .message = .{ .request = request, .response = response } });
    }

    /// Exports a status notifier item, or replaces its icon and tooltip in
    /// place. `icon` is a borrowed GdkPixbuf copied before return; null names
    /// the generic application icon. The item appears once a status notifier
    /// host is running and returns after a host restart.
    pub fn setTray(self: *Owner, options: types.TrayOptions) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var tooltip: [512]u8 = undefined;
        const title = try trayText(&tooltip, options.tooltip);
        if (self.tray) |tray| {
            if (zsl_tray_update(tray, options.icon, title, "") == 0) return error.IconCopyFailed;
            return;
        }
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        self.tray = zsl_tray_show(options.icon, title, "", null, self, serial, trayEvent, &failure) orelse return error.IconCopyFailed;
        self.tray_serial = serial;
    }
    pub fn clearTray(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const tray = self.tray orelse return;
        self.tray = null;
        zsl_tray_remove(tray);
    }
    fn trayEvent(ptr: ?*anyopaque, serial: u64, kind: i32, x: i32, y: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        if (self.tray == null or self.tray_serial != serial) return;
        switch (kind) {
            0 => self.deliver(.tray_activate),
            1 => self.deliver(.{ .tray_context = .{ .x = x, .y = y } }),
            -1 => {
                self.last_error = @bitCast(y);
                self.report(.dbus, trayFailure(x), @bitCast(y));
            },
            else => {},
        }
    }

    /// IDs are local to this Owner and nonzero. X11 only: other displays
    /// return UnsupportedCapability. A grab held by another client returns
    /// HotkeyRegistrationFailed with the X error in `last_error`.
    pub fn registerHotkey(self: *Owner, id: u64, hotkey: types.Hotkey) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (id == 0) return error.InvalidHotkeyId;
        for (self.hotkeys[0..self.hotkey_count]) |entry| if (entry.id == id) return error.DuplicateHotkeyId;
        if (self.hotkey_count == self.hotkeys.len) return error.TooManyHotkeys;
        const modifiers = hotkey.modifiers;
        const bits: u32 = @as(u32, @intFromBool(modifiers.shift)) | @as(u32, @intFromBool(modifiers.control)) << 1 | @as(u32, @intFromBool(modifiers.alt)) << 2 | @as(u32, @intFromBool(modifiers.super)) << 3;
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        var x_error: c_int = 0;
        const native = zsl_hotkey_register(keyval(hotkey.key), bits, @intFromBool(hotkey.repeat), self, serial, hotkeyDone, &failure, &x_error) orelse {
            self.last_error = @intCast(x_error);
            return switch (failure) {
                1 => error.UnsupportedCapability,
                2 => error.UnsupportedKey,
                else => error.HotkeyRegistrationFailed,
            };
        };
        self.hotkeys[self.hotkey_count] = .{ .id = id, .native = native, .serial = serial };
        self.hotkey_count += 1;
    }
    pub fn unregisterHotkey(self: *Owner, id: u64) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        for (self.hotkeys[0..self.hotkey_count], 0..) |entry, index| if (entry.id == id) {
            self.hotkey_count -= 1;
            self.hotkeys[index] = self.hotkeys[self.hotkey_count];
            zsl_hotkey_unregister(entry.native);
            return;
        };
        return error.HotkeyNotFound;
    }
    pub fn clearHotkeys(self: *Owner) !void {
        _ = try self.require();
        while (self.hotkey_count != 0) try self.unregisterHotkey(self.hotkeys[self.hotkey_count - 1].id);
    }
    fn hotkeyDone(ptr: ?*anyopaque, serial: u64, _: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        for (self.hotkeys[0..self.hotkey_count]) |entry| if (entry.serial == serial) {
            self.deliver(.{ .hotkey = entry.id });
            return;
        };
    }

    /// One outstanding notification per Owner. Submission to the session bus
    /// completes after this call returns; a refusal is reported through the
    /// window's diagnostic sink. Success never guarantees the user saw it.
    pub fn showNotification(self: *Owner, id: u64, options: types.NotificationOptions) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (id == 0) return error.InvalidNotificationId;
        if (options.body.len == 0) return error.EmptyNotification;
        var title: [256]u8 = undefined;
        var body: [1024]u8 = undefined;
        const summary = try boundedText(&title, options.title, 63);
        const text = try boundedText(&body, options.body, 255);
        const serial = try self.nextSerial();
        const native = zsl_note_show(summary, text, @intFromEnum(options.kind), @intFromBool(options.silent), @intFromBool(options.real_time), self, serial, noteDone) orelse return error.NotificationSubmissionFailed;
        const previous = self.notification;
        self.notification = .{ .id = id, .native = native, .serial = serial };
        if (previous) |old| zsl_note_close(old.native);
    }
    pub fn clearNotification(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const notification = self.notification orelse return;
        self.notification = null;
        zsl_note_close(notification.native);
    }
    fn noteDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        const notification = self.notification orelse return;
        if (notification.serial != serial) return;
        self.notification = null;
        zsl_note_close(notification.native);
        if (result == 1) self.deliver(.{ .notification_activated = notification.id }) else if (result < 0) self.report(.dbus, error.NotificationSubmissionFailed, null);
    }

    pub fn openFile(self: *Owner, options: picker.Options, destination: []u8, context: *anyopaque, on_result: picker.Callback) !void {
        try self.startChooser(.open_file, options, destination, context, on_result);
    }
    pub fn saveFile(self: *Owner, options: picker.Options, destination: []u8, context: *anyopaque, on_result: picker.Callback) !void {
        try self.startChooser(.save_file, options, destination, context, on_result);
    }
    pub fn openFiles(self: *Owner, options: picker.Options, destination: []u8, context: *anyopaque, on_result: picker.Callback) !void {
        try self.startChooser(.open_files, options, destination, context, on_result);
    }
    pub fn pickFolder(self: *Owner, options: picker.Options, destination: []u8, context: *anyopaque, on_result: picker.Callback) !void {
        try self.startChooser(.folder, options, destination, context, on_result);
    }
    /// Hides the chooser; its result still arrives, as cancelled.
    pub fn cancelFileDialog(self: *Owner) !void {
        _ = try self.require();
        if (self.chooser) |chooser| zsl_chooser_cancel(chooser.native);
    }
    fn startChooser(self: *Owner, kind: picker.Kind, options: picker.Options, destination: []u8, context: *anyopaque, on_result: picker.Callback) !void {
        const window = try self.require();
        if (self.chooser != null) return error.DialogAlreadyPending;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const extensions: []const []const u8 = if (options.extensions.len != 0) options.extensions else if (kind == .save_file) &.{".txt"} else &.{"*"};
        if (extensions.len > 16) return error.InvalidFileFilters;
        var text: [16][512]u8 = undefined;
        var filters: [16][*:0]const u8 = undefined;
        for (extensions, 0..) |extension, index| {
            if (extension.len == 0 or (!std.mem.eql(u8, extension, "*") and (extension.len < 2 or extension[0] != '.' or std.mem.indexOfAny(u8, extension, "\\/:;*?[]\x00") != null))) return error.InvalidFileFilters;
            if (kind == .save_file and std.mem.eql(u8, extension, "*")) return error.InvalidFileFilters;
            if (!std.unicode.utf8ValidateSlice(extension)) return error.InvalidUtf8;
            if ((std.unicode.calcUtf16LeLen(extension) catch return error.InvalidUtf8) > 128) return error.FileFilterTooLong;
            filters[index] = try terminated(&text[index], extension);
        }
        if (std.mem.indexOfAny(u8, options.suggested_name, "\\/:*?\"<>|\x00") != null) return error.InvalidSuggestedName;
        var name: [1024]u8 = undefined;
        if ((std.unicode.calcUtf16LeLen(options.suggested_name) catch return error.InvalidUtf8) > 256) return error.SuggestedNameTooLong;
        const suggested = try terminated(&name, options.suggested_name);
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        const native = zsl_chooser_show(window.nativeHandle(), @intCast(@intFromEnum(kind)), &filters, @intCast(extensions.len), suggested, self, serial, chooserDone, &failure) orelse return error.FilePickerCreationFailed;
        self.chooser = .{ .native = native, .serial = serial, .kind = kind, .destination = destination, .context = context, .on_result = on_result };
    }
    fn chooserDone(ptr: ?*anyopaque, serial: u64, code: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        const chooser = self.chooser orelse return;
        if (chooser.serial != serial) return;
        const window = self.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        const result: picker.Result = switch (code) {
            -1 => .cancelled,
            -3 => .{ .failed = .{ .err = error.NonFilesystemSelection } },
            -4 => .{ .failed = .{ .err = error.InvalidPathEncoding } },
            -5 => .{ .failed = .{ .err = error.InvalidResultCount } },
            else => result: {
                if (code <= 0 or code > self.chooser_paths.len or (chooser.kind != .open_files and code != 1)) break :result .{ .failed = .{ .err = error.InvalidResultCount } };
                const count: u32 = @intCast(code);
                var needed: usize = 0;
                for (0..count) |index| needed += chooserPath(chooser.native, @intCast(index)).len;
                if (needed > chooser.destination.len) break :result .{ .failed = .{ .err = error.ResultCapacityExceeded } };
                var used: usize = 0;
                for (0..count) |index| {
                    const path = chooserPath(chooser.native, @intCast(index));
                    @memcpy(chooser.destination[used..][0..path.len], path);
                    self.chooser_paths[index] = chooser.destination[used..][0..path.len];
                    used += path.len;
                }
                break :result if (chooser.kind == .open_files) .{ .selected_multiple = self.chooser_paths[0..count] } else .{ .selected = self.chooser_paths[0] };
            },
        };
        self.chooser = null;
        zsl_chooser_detach(chooser.native);
        if (window.isClosed()) return;
        chooser.on_result(chooser.context, window, result);
    }
};

/// A notification-area item that belongs to the App rather than a window,
/// exported as a status notifier item on the session bus. Its own menu is
/// exported beside it as a dbusmenu, which the panel draws and reports
/// clicks on.
pub const Tray = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void,
    app: ?*z.App = null,
    native: ?*anyopaque = null,
    guid: ?[16]u8 = null,
    popup: Popup = .{},
    /// The exported menu's items by index; separators and submenus keep 0.
    menu_ids: [types.max_menu_items]u64 = undefined,
    menu_count: usize = 0,
    /// The last point a host reported, used by `TrayAnchor.icon`.
    point: ?types.ScreenPoint = null,
    serial: u64 = 0,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,
    last_error: u32 = 0,

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void) Tray {
        return .{ .context = context, .on_action = on_action };
    }
    /// Creates the item, or replaces its icon and tooltip in place. The icon
    /// is a borrowed GdkPixbuf copied during the call. A guid becomes the
    /// item's stable identifier for hosts that remember placement.
    pub fn show(self: *Tray, app: *z.App, options: types.TrayItemOptions) !void {
        app.assertOwner();
        if (self.app) |current| if (current != app) return error.AlreadyAttached;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        var tooltip: [512]u8 = undefined;
        const title = try trayText(&tooltip, options.tooltip);
        var label_buffer: [512]u8 = undefined;
        const label = try trayText(&label_buffer, options.title);
        if (options.menu) |items| _ = try menus.validate(items, false);
        if (self.native) |native| {
            if (!std.meta.eql(self.guid, options.guid)) return error.TrayIdentityChanged;
            if (zsl_tray_update(native, options.icon, title, label) == 0) return error.IconCopyFailed;
            if (options.menu) |items| try self.setMenu(items);
            return;
        }
        if (self.serial == std.math.maxInt(u64)) return error.IdExhausted;
        var identity: [33]u8 = undefined;
        const id: ?[*:0]const u8 = if (options.guid) |bytes| blk: {
            _ = std.fmt.bufPrint(&identity, "{x}", .{bytes}) catch unreachable;
            identity[32] = 0;
            break :blk identity[0..32 :0].ptr;
        } else null;
        self.stop_node = .{ .context = self, .stop = stopped };
        self.stop_token = try app.registerStop(&self.stop_node);
        errdefer {
            _ = app.cancelStop(self.stop_token.?) catch {};
            self.stop_token = null;
        }
        self.serial += 1;
        var failure: c_int = 0;
        self.native = zsl_tray_show(options.icon, title, label, id, self, self.serial, event, &failure) orelse return error.IconCopyFailed;
        self.app = app;
        self.guid = options.guid;
        self.menu_count = 0;
        if (options.menu) |items| self.setMenu(items) catch |err| {
            _ = app.cancelStop(self.stop_token.?) catch {};
            self.stop_token = null;
            self.release();
            return err;
        };
    }
    /// Replaces the item's own menu, which the panel opens itself; an empty
    /// slice removes it. Items are copied. Panels that cannot draw a dbusmenu
    /// call ContextMenu instead, reported as `TrayAction.context`, where
    /// popupMenu() can open the same items. Commands report `TrayAction.menu`.
    pub fn setMenu(self: *Tray, items: []const types.Item) !void {
        const app = self.app orelse return error.NotAttached;
        app.assertOwner();
        const native = self.native orelse return error.NotAttached;
        const plan = try menus.validate(items, false);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        _ = try nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        for (items, 0..) |item, index| {
            // The panel greys what an ancestor disables, too.
            native_items[index].enabled = @intFromBool(plan.enabled[index]);
            self.menu_ids[index] = if (item.kind == .command) item.id else 0;
        }
        self.menu_count = items.len;
        zsl_tray_menu(native, &native_items, @intCast(items.len));
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
    /// Opens a menu after this call returns. X11 only: Wayland gives an item
    /// no surface to anchor a menu, so this returns MenuStartFailed there.
    /// The request completes once with `TrayAction.popup` unless removed.
    pub fn popupMenu(self: *Tray, request: u64, items: []const types.Item, anchor: types.TrayAnchor) !void {
        const app = self.app orelse return error.NotAttached;
        app.assertOwner();
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        const point: ?types.ScreenPoint = switch (anchor) {
            .screen => |value| value,
            .pointer => null,
            .icon => self.point,
        };
        if (self.serial == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.serial += 1;
        // The item keeps its own events on the earlier serial.
        const popup_serial = self.serial;
        try self.popup.start(null, items, if (point != null) 2 else 0, if (point) |value| @floatFromInt(value.x) else 0, if (point) |value| @floatFromInt(value.y) else 0, self, request, popup_serial, popupDone);
    }
    pub fn cancelPopup(self: *Tray) void {
        if (self.app) |app| app.assertOwner();
        self.popup.cancel();
    }
    /// Status notifier hosts tell no icon rectangle, only where the last
    /// click happened, which hosts that report it give here as an empty
    /// rectangle. Null when no host has reported a point.
    pub fn iconRect(self: *Tray) ?desktop.Rect {
        if (self.app) |app| app.assertOwner();
        const point = self.point orelse return null;
        // Hosts that do not know the pointer report the origin.
        if (point.x == 0 and point.y == 0) return null;
        return .{ .x = point.x, .y = point.y, .width = 0, .height = 0 };
    }
    /// Linux hosts report no icon rectangle to test the pointer against.
    pub fn pointerOverIcon(_: *Tray) bool {
        return false;
    }
    fn popupDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(ptr.?));
        const value = self.popup.finish(serial, result) orelse return;
        self.deliver(.{ .popup = value });
    }
    fn event(ptr: ?*anyopaque, _: u64, kind: i32, x: i32, y: i32) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(ptr.?));
        if (self.native == null) return;
        switch (kind) {
            0 => {
                self.point = .{ .x = x, .y = y };
                self.deliver(.activate);
            },
            1 => {
                self.point = .{ .x = x, .y = y };
                self.deliver(.{ .context = .{ .x = x, .y = y } });
            },
            3 => {
                const index: usize = @intCast(x);
                if (index < self.menu_count and self.menu_ids[index] != 0) self.deliver(.{ .menu = self.menu_ids[index] });
            },
            -1 => {
                self.last_error = @bitCast(y);
                const app = self.app orelse return;
                app.report(.{ .severity = .warning, .domain = .dbus, .operation = .window_update, .err = trayFailure(x), .code = @bitCast(y) });
            },
            else => {},
        }
    }
    fn deliver(self: *Tray, action: types.TrayAction) void {
        const app = self.app orelse return;
        const scope = app.beginCallback() orelse return;
        defer scope.end();
        self.on_action(self.context, self, action);
    }
    fn stopped(ptr: *anyopaque) anyerror!void {
        const self: *Tray = @ptrCast(@alignCast(ptr));
        self.stop_token = null;
        self.release();
    }
    fn release(self: *Tray) void {
        self.popup.detach();
        if (self.native) |native| {
            self.native = null;
            zsl_tray_remove(native);
        }
        self.app = null;
        self.guid = null;
        self.point = null;
        self.menu_count = 0;
    }
};

/// Converts menu items into the C layout. Labels become GTK mnemonics in
/// caller storage; command indices follow declaration order.
fn nativeItems(items: []const types.Item, plan: *const menus.Plan, labels: *[types.max_menu_items][512]u8, native_items: *[types.max_menu_items]NativeItem, ids: *[types.max_menu_items]u64, enabled: *[types.max_menu_items]bool) !usize {
    var commands: usize = 0;
    for (items, 0..) |item, index| {
        const label = try menus.gtkMnemonic(&labels[index], item.label);
        var command: i32 = -1;
        if (item.kind == .command) {
            command = @intCast(commands);
            ids[commands] = item.id;
            enabled[commands] = plan.enabled[index];
            commands += 1;
        }
        const accelerator = item.accelerator;
        native_items[index] = .{
            .label = label.ptr,
            .parent = if (plan.parent[index]) |parent| parent else -1,
            .kind = @intFromEnum(item.kind),
            .enabled = @intFromBool(item.enabled),
            .checked = @intFromBool(item.checked),
            .keyval = if (accelerator) |value| keyval(value.key) else 0,
            .modifiers = if (accelerator) |value| modifierMask(value.modifiers) else 0,
            .command = command,
        };
    }
    return commands;
}

fn chooserPath(native: *anyopaque, index: u32) []const u8 {
    var path: ?[*]const u8 = null;
    var length: usize = 0;
    zsl_chooser_path(native, index, &path, &length);
    return if (path) |value| value[0..length] else "";
}

fn terminated(destination: []u8, text: []const u8) ![*:0]const u8 {
    if (text.len >= destination.len) return error.TextCapacityExceeded;
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    return destination[0..text.len :0].ptr;
}

/// UTF-8 without NUL, at most `units` UTF-16 code units, matching the limits
/// the same calls have on other systems.
fn boundedText(destination: []u8, text: []const u8, units: usize) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    const needed = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    if (needed > units) return error.TextCapacityExceeded;
    return terminated(destination, text);
}

/// Bus failure stages the native item reports: 1 connection, 2 export,
/// 3 watcher registration, 4 menu export.
fn trayFailure(stage: i32) anyerror {
    return switch (stage) {
        3 => error.TrayRegistrationFailed,
        4 => error.TrayMenuExportFailed,
        else => error.TrayCreationFailed,
    };
}

fn trayText(destination: []u8, text: []const u8) ![*:0]const u8 {
    return boundedText(destination, text, 127);
}

fn modifierMask(modifiers: types.Modifiers) u32 {
    // GDK_SHIFT_MASK, GDK_CONTROL_MASK, GDK_MOD1_MASK and GDK_SUPER_MASK.
    return @as(u32, if (modifiers.shift) 1 << 0 else 0) | @as(u32, if (modifiers.control) 1 << 2 else 0) | @as(u32, if (modifiers.alt) 1 << 3 else 0) | @as(u32, if (modifiers.super) 1 << 26 else 0);
}

/// GDK keyvals equal X11 keysyms, so this also names keys for key grabs.
fn keyval(key: types.Key) u32 {
    const index = @intFromEnum(key);
    if (index >= @intFromEnum(types.Key.a) and index <= @intFromEnum(types.Key.z)) return 'a' + @as(u32, index - @intFromEnum(types.Key.a));
    if (index >= @intFromEnum(types.Key.digit0) and index <= @intFromEnum(types.Key.digit9)) return '0' + @as(u32, index - @intFromEnum(types.Key.digit0));
    if (index >= @intFromEnum(types.Key.f1) and index <= @intFromEnum(types.Key.f24)) return 0xffbe + @as(u32, index - @intFromEnum(types.Key.f1));
    return switch (key) {
        .space => 0x20,
        .enter => 0xff0d,
        .escape => 0xff1b,
        .tab => 0xff09,
        .backspace => 0xff08,
        .delete => 0xffff,
        .insert => 0xff63,
        .home => 0xff50,
        .end => 0xff57,
        .page_up => 0xff55,
        .page_down => 0xff56,
        .left => 0xff51,
        .up => 0xff52,
        .right => 0xff53,
        .down => 0xff54,
        else => unreachable,
    };
}
