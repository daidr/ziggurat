//! AppKit menus, popup menus, alerts, open and save panels and status items
//! for one window, and status items of the App. macOS has one menu bar: an
//! Owner's menu is the application's main menu while its window is the main
//! window, and the menu set last otherwise. Nothing here runs a modal loop:
//! alerts and panels show as sheets of a visible window, or as windows of
//! their own, and popup menus open from the run loop after the call returns.
//!
//! Items whose IDs are standard roles (`menu_roles`) that AppKit performs
//! itself do so and report no `Action.menu`: the Edit commands go to the
//! first responder, a window's content view, which runs them as their
//! Command shortcuts, or a page; About, Hide, Hide Others, Show All, Bring
//! All to Front and the Speech commands go to the application. The
//! Services, Window and Help submenus become AppKit's own.
const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const menus = @import("menus.zig");
const roles = @import("menu_roles.zig");
const picker = @import("picker.zig");
const desktop = @import("desktop.zig");

pub const NativeItem = extern struct {
    label: [*:0]const u8,
    parent: i32,
    kind: u8,
    enabled: u8,
    checked: u8,
    radio: u8 = 0,
    key: u32,
    modifiers: u32,
    command: i32,
    icon: ?*anyopaque = null,
    role: i32 = 0,
};
const Done = *const fn (?*anyopaque, u64, i32) callconv(.c) void;
const TrayEvent = *const fn (?*anyopaque, u64, i32, i32, i32) callconv(.c) void;
extern fn zsm_live_links() i32;
extern fn zsm_bar_set(?*anyopaque, [*]const NativeItem, u32, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsm_bar_remove(*anyopaque, c_int) void;
extern fn zsm_bar_state(*anyopaque, i32, c_int, c_int) c_int;
extern fn zsm_bar_icon(*anyopaque, i32, ?*anyopaque) c_int;
extern fn zsm_popup_show(?*anyopaque, [*]const NativeItem, u32, c_int, f64, f64, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsm_tray_popup(*anyopaque, [*]const NativeItem, u32, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsm_popup_cancel(*anyopaque) void;
extern fn zsm_popup_detach(*anyopaque) void;
extern fn zsm_tray_show(?*anyopaque, c_int, [*:0]const u8, [*:0]const u8, ?[*:0]const u8, ?*anyopaque, u64, TrayEvent) ?*anyopaque;
extern fn zsm_tray_update(*anyopaque, ?*anyopaque, c_int, [*:0]const u8, [*:0]const u8) c_int;
extern fn zsm_tray_menu(*anyopaque, [*]const NativeItem, u32) void;
extern fn zsm_tray_frame(*anyopaque, *f64, *f64, *f64, *f64) c_int;
extern fn zsm_tray_pointer_over(*anyopaque) c_int;
extern fn zsm_tray_remove(*anyopaque) void;
extern fn zsm_message_show(?*anyopaque, [*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, u32, u32, i32, i32, c_int, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsm_message_cancel(*anyopaque) void;
extern fn zsm_message_detach(*anyopaque) void;
extern fn zsm_chooser_show(?*anyopaque, c_int, [*]const [*:0]const u8, u32, [*:0]const u8, ?*anyopaque, u64, Done) ?*anyopaque;
extern fn zsm_chooser_path(*anyopaque, u32, *?[*]const u8, *usize) void;
extern fn zsm_chooser_cancel(*anyopaque) void;
extern fn zsm_chooser_detach(*anyopaque) void;

pub const message = struct {
    /// Native menu, popup, alert, panel, status item and Dock records still
    /// alive, including ones whose owner has detached while AppKit finishes
    /// with them.
    pub fn resourceCount() u32 {
        return @intCast(zsm_live_links());
    }
};

const Pending = struct {
    native: ?*anyopaque = null,
    request: u64 = 0,
    serial: u64 = 0,
};
const BarEntry = struct { id: u64, enabled: bool, ancestors: bool, own: bool = true, group: ?u8 = null };
const Chooser = struct {
    native: *anyopaque,
    serial: u64,
    kind: picker.Kind,
    destination: []u8,
    context: *anyopaque,
    on_result: picker.Callback,
};

/// Popup menu state shared by window owners and status items.
const Popup = struct {
    pending: Pending = .{},
    ids: [types.max_menu_items]u64 = undefined,
    enabled: [types.max_menu_items]bool = undefined,
    count: usize = 0,

    fn start(self: *Popup, window: ?*anyopaque, tray: ?*anyopaque, items: []const types.Item, kind: c_int, x: f64, y: f64, owner: *anyopaque, request: u64, serial: u64, done: Done) !void {
        if (self.pending.native != null) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const plan = try menus.validate(items, true);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        const commands = try nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        const native = if (tray) |item|
            zsm_tray_popup(item, &native_items, @intCast(items.len), owner, serial, done)
        else
            zsm_popup_show(window, &native_items, @intCast(items.len), kind, x, y, owner, serial, done);
        self.pending = .{ .native = native orelse return error.MenuStartFailed, .request = request, .serial = serial };
        @memcpy(self.ids[0..commands], ids[0..commands]);
        @memcpy(self.enabled[0..commands], enabled[0..commands]);
        self.count = commands;
    }
    fn finish(self: *Popup, serial: u64, result: i32) ?types.PopupResult {
        const native = self.pending.native orelse return null;
        if (self.pending.serial != serial) return null;
        const request = self.pending.request;
        self.pending = .{};
        zsm_popup_detach(native);
        const index: usize = if (result >= 0) @intCast(result) else std.math.maxInt(usize);
        return .{ .request = request, .selected = if (index < self.count and self.enabled[index]) self.ids[index] else null };
    }
    fn cancel(self: *Popup) void {
        if (self.pending.native) |native| zsm_popup_cancel(native);
    }
    fn detach(self: *Popup) void {
        if (self.pending.native) |native| {
            self.pending = .{};
            zsm_popup_detach(native);
        }
    }
};

/// Keep at a stable address through detach/on_closed. All calls and actions
/// run on the main thread; a pending popup, message or panel completes once
/// unless the Owner detaches or its window closes first.
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
    chooser: ?Chooser = null,
    chooser_paths: [128][]const u8 = undefined,
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
    /// Removes the menu bar and status item, and dismisses pending popups,
    /// alerts and panels without completing them.
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
            zsm_message_detach(native);
        }
        if (self.chooser) |chooser| {
            self.chooser = null;
            zsm_chooser_detach(chooser.native);
        }
        if (self.tray) |tray| {
            self.tray = null;
            zsm_tray_remove(tray);
        }
        if (self.bar) |bar| {
            self.bar = null;
            self.bar_count = 0;
            zsm_bar_remove(bar, @intFromBool(restore));
        }
    }
    fn nativeDestroying(ptr: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.release(true);
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

    /// Replaces the menu transactionally: the new menu takes the old one's
    /// place as the main menu before the old one is released. Labels are
    /// copied during this call; `&` mnemonics are dropped, as macOS menus
    /// have none.
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
        var entries: [types.max_menu_items]BarEntry = undefined;
        var command: usize = 0;
        for (items, 0..) |item, index| {
            // AppKit greys what an ancestor disables only for items it
            // validates; give every command its effective state.
            native_items[index].enabled = @intFromBool(plan.enabled[index]);
            if (item.kind != .command) continue;
            entries[command] = .{ .id = ids[command], .enabled = enabled[command], .ancestors = plan.ancestors_enabled[index], .own = item.enabled, .group = plan.radio_group[index] };
            command += 1;
        }
        const serial = try self.nextSerial();
        const bar = zsm_bar_set(window.nativeHandle(), &native_items, @intCast(items.len), self, serial, barDone) orelse return error.MenuAttachFailed;
        const old = self.bar;
        self.bar = bar;
        self.bar_serial = serial;
        @memcpy(self.bar_entries[0..commands], entries[0..commands]);
        self.bar_count = commands;
        if (old) |value| zsm_bar_remove(value, 0);
    }
    pub fn clearMenu(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const bar = self.bar orelse return;
        self.bar = null;
        self.bar_count = 0;
        zsm_bar_remove(bar, 1);
    }
    /// Updates a command item. Submenu state changes use a new setMenu snapshot.
    /// Checking a radio item unchecks the rest of its group.
    pub fn setItemState(self: *Owner, id: u64, enabled: bool, checked: bool) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const bar = self.bar orelse return error.MenuItemNotFound;
        for (self.bar_entries[0..self.bar_count], 0..) |*entry, index| if (entry.id == id) {
            const effective = enabled and entry.ancestors;
            if (zsm_bar_state(bar, @intCast(index), @intFromBool(effective), @intFromBool(checked)) == 0) return error.MenuUpdateFailed;
            entry.enabled = effective;
            entry.own = enabled;
            if (checked) if (entry.group) |group| for (self.bar_entries[0..self.bar_count], 0..) |sibling, other| {
                if (other == index or sibling.group != group) continue;
                if (zsm_bar_state(bar, @intCast(other), @intFromBool(sibling.enabled), 0) == 0) return error.MenuUpdateFailed;
            };
            return;
        };
        return error.MenuItemNotFound;
    }
    /// Replaces a command item's icon, or removes it with null; the items
    /// of the menu bar itself show none.
    pub fn setItemIcon(self: *Owner, id: u64, icon: ?*types.MenuIcon) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const bar = self.bar orelse return error.MenuItemNotFound;
        for (self.bar_entries[0..self.bar_count], 0..) |entry, index| if (entry.id == id) {
            if (zsm_bar_icon(bar, @intCast(index), if (icon) |value| value.native else null) == 0) return error.MenuUpdateFailed;
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

    /// Opens a menu after this call returns. `client` points are the content
    /// view's; `screen` points are from the top-left of the primary display,
    /// as window positions are.
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
        try self.popup.start(window.nativeHandle(), null, items, kind, x, y, self, request, try self.nextSerial(), popupDone);
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

    /// An NSAlert: the title is its bold message and the message its
    /// informative text. Return presses the default button, which has none
    /// without `default_button`; Escape and Command-period press the cancel
    /// button, or dismiss an alert without one.
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
        var destructive: u32 = 0;
        for (options.buttons, 0..) |button, index| {
            buttons[index] = (try menus.plainLabel(&labels[index], button.label)).ptr;
            if (button.destructive) destructive |= @as(u32, 1) << @intCast(index);
        }
        const serial = try self.nextSerial();
        const default_index: i32 = if (options.default_button) |index| @intCast(index) else -1;
        const cancel_index: i32 = if (options.cancel_button) |index| @intCast(index) else -1;
        const native = zsm_message_show(window.nativeHandle(), try terminated(&title, options.title), try terminated(&text, options.message), &buttons, @intCast(options.buttons.len), destructive, default_index, cancel_index, @backingInt(options.kind), self, serial, messageDone) orelse return error.MessageDialogCreationFailed;
        self.message_dialog = .{ .native = native, .request = request, .serial = serial };
        self.message_buttons = @splat(0);
        for (options.buttons, 0..) |button, index| self.message_buttons[index] = button.id;
        self.message_cancel = if (options.cancel_button) |index| options.buttons[index].id else null;
    }
    /// Closes a pending message; its request still completes as dismissed.
    pub fn cancelMessage(self: *Owner) !void {
        _ = try self.require();
        if (self.message_dialog.native) |native| zsm_message_cancel(native);
    }
    fn messageDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        const native = self.message_dialog.native orelse return;
        if (self.message_dialog.serial != serial) return;
        const request = self.message_dialog.request;
        self.message_dialog = .{};
        zsm_message_detach(native);
        const response: types.MessageResponse = if (result >= 0 and result < self.message_buttons.len and self.message_buttons[@intCast(result)] != 0)
            .{ .button = self.message_buttons[@intCast(result)] }
        else if (result == -1 and self.message_cancel != null) .{ .button = self.message_cancel.? } else .dismissed;
        self.deliver(.{ .message = .{ .request = request, .response = response } });
    }

    /// Adds a status item to the menu bar, or replaces its icon and tooltip
    /// in place. `icon` is a borrowed NSImage, copied before return; null
    /// shows the application icon. Clicks report `tray_activate`, and
    /// right-clicks and Control-clicks `tray_context`.
    pub fn setTray(self: *Owner, options: types.TrayOptions) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        var tooltip: [512]u8 = undefined;
        const tip = try trayText(&tooltip, options.tooltip);
        if (self.tray) |tray| {
            if (zsm_tray_update(tray, options.icon, @intFromBool(options.template), tip, "") == 0) return error.IconCopyFailed;
            return;
        }
        const serial = try self.nextSerial();
        self.tray = zsm_tray_show(options.icon, @intFromBool(options.template), tip, "", null, self, serial, trayEvent) orelse return error.TrayCreationFailed;
        self.tray_serial = serial;
    }
    pub fn clearTray(self: *Owner) !void {
        const window = try self.require();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const tray = self.tray orelse return;
        self.tray = null;
        zsm_tray_remove(tray);
    }
    fn trayEvent(ptr: ?*anyopaque, serial: u64, kind: i32, x: i32, y: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        if (self.tray == null or self.tray_serial != serial) return;
        switch (kind) {
            0 => self.deliver(.tray_activate),
            1 => self.deliver(.{ .tray_context = .{ .x = x, .y = y } }),
            else => {},
        }
    }

    /// Global hotkeys and notifications are not implemented on macOS yet.
    pub fn registerHotkey(_: *Owner, _: u64, _: types.Hotkey) !void {
        return error.UnsupportedCapability;
    }
    pub fn unregisterHotkey(_: *Owner, _: u64) !void {
        return error.UnsupportedCapability;
    }
    pub fn clearHotkeys(_: *Owner) !void {
        return error.UnsupportedCapability;
    }
    pub fn showNotification(_: *Owner, _: u64, _: types.NotificationOptions) !void {
        return error.UnsupportedCapability;
    }
    pub fn clearNotification(_: *Owner) !void {
        return error.UnsupportedCapability;
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
    /// Hides the panel; its result still arrives, as cancelled.
    pub fn cancelFileDialog(self: *Owner) !void {
        _ = try self.require();
        if (self.chooser) |chooser| zsm_chooser_cancel(chooser.native);
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
        const native = zsm_chooser_show(window.nativeHandle(), @intCast(@backingInt(kind)), &filters, @intCast(extensions.len), suggested, self, serial, chooserDone) orelse return error.FilePickerCreationFailed;
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
        zsm_chooser_detach(chooser.native);
        if (window.isClosed()) return;
        chooser.on_result(chooser.context, window, result);
    }
};

/// A menu bar extra that belongs to the App rather than a window: an
/// NSStatusItem. With a menu of its own, a click opens the menu, as macOS
/// menu bar extras do; without one, a click reports `activate` and a
/// right-click or Control-click `context`.
pub const Tray = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void,
    app: ?*z.App = null,
    native: ?*anyopaque = null,
    guid: ?[16]u8 = null,
    popup: Popup = .{},
    /// The item's own menu's command IDs, by command index.
    menu_ids: [types.max_menu_items]u64 = undefined,
    menu_enabled: [types.max_menu_items]bool = undefined,
    menu_count: usize = 0,
    serial: u64 = 0,
    stop_node: z.StopParticipant = undefined,
    stop_token: ?z.StopToken = null,

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void) Tray {
        return .{ .context = context, .on_action = on_action };
    }
    /// Creates the item, or replaces its icon, tooltip and title in place.
    /// The icon is a borrowed NSImage copied during the call and shown 18
    /// points tall. The title shows beside the icon with digits of one
    /// width: pad a changing number with figure spaces (U+2007) to keep the
    /// item's width. A guid becomes the item's autosave name, under which
    /// macOS keeps where the user dragged it with Command held.
    pub fn show(self: *Tray, app: *z.App, options: types.TrayItemOptions) !void {
        app.assertOwner();
        if (self.app) |current| if (current != app) return error.AlreadyAttached;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        var tooltip: [512]u8 = undefined;
        const tip = try trayText(&tooltip, options.tooltip);
        var title_buffer: [512]u8 = undefined;
        const title = try trayText(&title_buffer, options.title);
        if (options.menu) |items| _ = try menus.validate(items, false);
        if (self.native) |native| {
            if (!std.meta.eql(self.guid, options.guid)) return error.TrayIdentityChanged;
            if (zsm_tray_update(native, options.icon, @intFromBool(options.template), tip, title) == 0) return error.IconCopyFailed;
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
        self.native = zsm_tray_show(options.icon, @intFromBool(options.template), tip, title, id, self, self.serial, event) orelse return error.TrayCreationFailed;
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
    /// Replaces the item's own menu, which AppKit opens on a click; an empty
    /// slice removes it, so clicks report again. Items are copied. Commands
    /// report `TrayAction.menu`.
    pub fn setMenu(self: *Tray, items: []const types.Item) !void {
        const app = self.app orelse return error.NotAttached;
        app.assertOwner();
        const native = self.native orelse return error.NotAttached;
        const plan = try menus.validate(items, false);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
        const commands = try nativeItems(items, &plan, &labels, &native_items, &ids, &enabled);
        for (native_items[0..items.len], 0..) |*item, index| item.enabled = @intFromBool(plan.enabled[index]);
        @memcpy(self.menu_ids[0..commands], ids[0..commands]);
        @memcpy(self.menu_enabled[0..commands], enabled[0..commands]);
        self.menu_count = commands;
        zsm_tray_menu(native, &native_items, @intCast(items.len));
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
    /// Opens a menu from the item after this call returns, placed by the
    /// status item with its button highlighted, whatever the anchor. The
    /// request completes once with `TrayAction.popup` unless removed.
    pub fn popupMenu(self: *Tray, request: u64, items: []const types.Item, anchor: types.TrayAnchor) !void {
        _ = anchor;
        const app = self.app orelse return error.NotAttached;
        app.assertOwner();
        const native = self.native orelse return error.NotAttached;
        const scope = app.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (self.serial == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.serial += 1;
        try self.popup.start(null, native, items, 0, 0, 0, self, request, self.serial, popupDone);
    }
    pub fn cancelPopup(self: *Tray) void {
        if (self.app) |app| app.assertOwner();
        self.popup.cancel();
    }
    /// Where the item shows, in points from the top-left of the primary
    /// display, as window positions are. macOS shows a menu bar item on
    /// every display: this is the copy the user clicked last, so a flyout
    /// placed against it opens on that display. Null before the item has
    /// a place in the menu bar.
    pub fn iconRect(self: *Tray) ?desktop.Rect {
        if (self.app) |app| app.assertOwner();
        const native = self.native orelse return null;
        var x: f64 = 0;
        var y: f64 = 0;
        var width: f64 = 0;
        var height: f64 = 0;
        if (zsm_tray_frame(native, &x, &y, &width, &height) == 0) return null;
        return .{ .x = @intFromFloat(@round(x)), .y = @intFromFloat(@round(y)), .width = @intFromFloat(@max(@round(width), 1)), .height = @intFromFloat(@max(@round(height), 1)) };
    }
    /// Whether the pointer is over the item now.
    pub fn pointerOverIcon(self: *Tray) bool {
        if (self.app) |app| app.assertOwner();
        const native = self.native orelse return false;
        return zsm_tray_pointer_over(native) != 0;
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
            0 => self.deliver(.activate),
            1 => self.deliver(.{ .context = .{ .x = x, .y = y } }),
            3 => {
                if (x < 0) return;
                const index: usize = @intCast(x);
                if (index < self.menu_count and self.menu_enabled[index]) self.deliver(.{ .menu = self.menu_ids[index] });
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
            zsm_tray_remove(native);
        }
        self.app = null;
        self.guid = null;
        self.menu_count = 0;
    }
};

/// The native action of a standard role's item, by the codes
/// macos_menu.m knows; 0 leaves the item to `Action.menu`.
pub fn roleCode(id: u64) i32 {
    const role = roles.Role.fromId(id) orelse return 0;
    return switch (role) {
        .undo => 1,
        .redo => 2,
        .cut => 3,
        .copy => 4,
        .paste => 5,
        .paste_and_match_style => 6,
        .delete => 7,
        .select_all => 8,
        .about => 9,
        .hide => 10,
        .hide_others => 11,
        .unhide => 12,
        .front => 13,
        .start_speaking => 14,
        .stop_speaking => 15,
        .services => 20,
        .window, .window_menu => 21,
        .help => 22,
        else => 0,
    };
}

/// Converts menu items into the C layout. Labels lose their mnemonics in
/// caller storage; command indices follow declaration order.
pub fn nativeItems(items: []const types.Item, plan: *const menus.Plan, labels: *[types.max_menu_items][512]u8, native_items: *[types.max_menu_items]NativeItem, ids: *[types.max_menu_items]u64, enabled: *[types.max_menu_items]bool) !usize {
    var commands: usize = 0;
    for (items, 0..) |item, index| {
        const label = try menus.plainLabel(&labels[index], item.label);
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
            .kind = @backingInt(item.kind),
            .enabled = @intFromBool(item.enabled),
            .checked = @intFromBool(item.checked),
            .radio = @intFromBool(item.radio),
            .key = if (accelerator) |value| menus.appleKeyEquivalent(value.key) else 0,
            .modifiers = if (accelerator) |value| menus.appleModifierMask(value.modifiers) else 0,
            .command = command,
            .icon = if (item.icon) |icon| icon.native else null,
            .role = if (item.kind != .separator) roleCode(item.id) else 0,
        };
    }
    return commands;
}

fn chooserPath(native: *anyopaque, index: u32) []const u8 {
    var path: ?[*]const u8 = null;
    var length: usize = 0;
    zsm_chooser_path(native, index, &path, &length);
    return if (path) |value| value[0..length] else "";
}

fn terminated(destination: []u8, text: []const u8) ![*:0]const u8 {
    if (text.len >= destination.len) return error.TextCapacityExceeded;
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    return destination[0..text.len :0].ptr;
}

fn trayText(destination: []u8, text: []const u8) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
    const needed = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    if (needed > 127) return error.TextCapacityExceeded;
    return terminated(destination, text);
}
