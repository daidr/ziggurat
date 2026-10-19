//! GTK popup menus and message dialogs for one window. Menu bars, tray items,
//! hotkeys, notifications and pickers are not implemented on Linux and return
//! UnsupportedCapability. Nothing here runs a nested main loop.
const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const menus = @import("menus.zig");
const picker = @import("picker.zig");

const NativeItem = extern struct { label: [*:0]const u8, parent: i32, kind: u8, enabled: u8, checked: u8, padding: u8 = 0, keyval: u32, modifiers: u32, command: i32 };
const Done = *const fn (?*anyopaque, u64, i32) callconv(.c) void;
extern fn zsl_popup_show(?*anyopaque, [*]const NativeItem, u32, c_int, f64, f64, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_popup_cancel(*anyopaque) void;
extern fn zsl_message_show(?*anyopaque, [*:0]const u8, [*:0]const u8, [*]const [*:0]const u8, u32, i32, c_int, ?*anyopaque, u64, Done, *c_int) ?*anyopaque;
extern fn zsl_message_cancel(*anyopaque) void;
extern fn zsl_detach(*anyopaque) void;
extern fn zsl_live_links() c_int;
pub extern fn zsl_popup_activate(*anyopaque, i32) c_int;
pub extern fn zsl_message_press(*anyopaque, i32) c_int;
pub extern fn zsl_message_close(*anyopaque) c_int;

pub const message = struct {
    /// Native popup and dialog links still alive, including ones whose owner
    /// has detached while GTK finishes destroying the widget.
    pub fn resourceCount() u32 {
        return @intCast(zsl_live_links());
    }
};

const Pending = struct {
    native: ?*anyopaque = null,
    request: u64 = 0,
    serial: u64 = 0,
};

/// Keep at a stable address through detach/on_closed. All calls and actions
/// run on the main thread; a pending popup or message completes once unless
/// the Owner detaches or its window closes first.
pub const Owner = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, types.Action) void,
    window: ?z.Window = null,
    popup: Pending = .{},
    message_dialog: Pending = .{},
    popup_ids: [types.max_menu_items]u64 = undefined,
    popup_enabled: [types.max_menu_items]bool = undefined,
    popup_count: usize = 0,
    message_buttons: [types.max_message_buttons]u64 = @splat(0),
    message_cancel: ?u64 = null,
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
    pub fn detach(self: *Owner) !void {
        const window = self.window orelse return;
        window.app.assertOwner();
        self.release();
        window.clearService(self);
        self.window = null;
    }
    fn require(self: *Owner) !z.Window {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (window.isClosed()) return error.Closed;
        return window;
    }
    fn release(self: *Owner) void {
        if (self.popup.native) |native| {
            self.popup = .{};
            zsl_detach(native);
        }
        if (self.message_dialog.native) |native| {
            self.message_dialog = .{};
            zsl_detach(native);
        }
    }
    fn nativeDestroying(ptr: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(ptr));
        self.release();
        self.window = null;
    }
    fn nextSerial(self: *Owner) !u64 {
        if (self.serial == std.math.maxInt(u64)) return error.OperationGenerationExhausted;
        self.serial += 1;
        return self.serial;
    }

    pub fn popupMenu(self: *Owner, request: u64, items: []const types.Item, anchor: types.Anchor) !void {
        const window = try self.require();
        if (self.popup.native != null) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const plan = try menus.validate(items, true);
        var labels: [types.max_menu_items][512]u8 = undefined;
        var native_items: [types.max_menu_items]NativeItem = undefined;
        var ids: [types.max_menu_items]u64 = undefined;
        var enabled: [types.max_menu_items]bool = undefined;
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
        const serial = try self.nextSerial();
        var failure: c_int = 0;
        const native = zsl_popup_show(window.nativeHandle(), &native_items, @intCast(items.len), kind, x, y, self, serial, popupDone, &failure) orelse return error.MenuStartFailed;
        self.popup = .{ .native = native, .request = request, .serial = serial };
        @memcpy(self.popup_ids[0..commands], ids[0..commands]);
        @memcpy(self.popup_enabled[0..commands], enabled[0..commands]);
        self.popup_count = commands;
    }
    /// Closes a pending popup; its request still completes with null.
    pub fn cancelPopup(self: *Owner) !void {
        _ = try self.require();
        if (self.popup.native) |native| zsl_popup_cancel(native);
    }
    fn popupDone(ptr: ?*anyopaque, serial: u64, result: i32) callconv(.c) void {
        const self: *Owner = @ptrCast(@alignCast(ptr.?));
        if (self.popup.native == null or self.popup.serial != serial) return;
        const request = self.popup.request;
        self.popup = .{};
        const index: usize = if (result >= 0) @intCast(result) else std.math.maxInt(usize);
        const selected: ?u64 = if (index < self.popup_count and self.popup_enabled[index]) self.popup_ids[index] else null;
        self.deliver(.{ .popup = .{ .request = request, .selected = selected } });
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
    fn deliver(self: *Owner, action: types.Action) void {
        const window = self.window orelse return;
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        if (window.isClosed()) return;
        self.on_action(self.context, window, action);
    }

    pub fn setMenu(_: *Owner, _: []const types.Item) !void {
        return error.UnsupportedCapability;
    }
    pub fn clearMenu(_: *Owner) !void {
        return error.UnsupportedCapability;
    }
    pub fn setItemState(_: *Owner, _: u64, _: bool, _: bool) !void {
        return error.UnsupportedCapability;
    }
    pub fn setTray(_: *Owner, _: types.TrayOptions) !void {
        return error.UnsupportedCapability;
    }
    pub fn clearTray(_: *Owner) !void {
        return error.UnsupportedCapability;
    }
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
    pub fn openFile(_: *Owner, _: picker.Options, _: []u8, _: *anyopaque, _: picker.Callback) !void {
        return error.UnsupportedCapability;
    }
    pub fn cancelFileDialog(_: *Owner) !void {
        return error.UnsupportedCapability;
    }
    pub fn saveFile(_: *Owner, _: picker.Options, _: []u8, _: *anyopaque, _: picker.Callback) !void {
        return error.UnsupportedCapability;
    }
    pub fn openFiles(_: *Owner, _: picker.Options, _: []u8, _: *anyopaque, _: picker.Callback) !void {
        return error.UnsupportedCapability;
    }
    pub fn pickFolder(_: *Owner, _: picker.Options, _: []u8, _: *anyopaque, _: picker.Callback) !void {
        return error.UnsupportedCapability;
    }
};

fn terminated(destination: []u8, text: []const u8) ![*:0]const u8 {
    if (text.len >= destination.len) return error.TextCapacityExceeded;
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    return destination[0..text.len :0].ptr;
}

fn modifierMask(modifiers: types.Modifiers) u32 {
    // GDK_SHIFT_MASK, GDK_CONTROL_MASK, GDK_MOD1_MASK and GDK_SUPER_MASK.
    return @as(u32, if (modifiers.shift) 1 << 0 else 0) | @as(u32, if (modifiers.control) 1 << 2 else 0) | @as(u32, if (modifiers.alt) 1 << 3 else 0) | @as(u32, if (modifiers.super) 1 << 26 else 0);
}

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
