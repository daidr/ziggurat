//! Browsers: a window's owner shows context menus as menus of HTML on the
//! page and asks with the browser's `alert` and `confirm`. Application
//! menus, trays, hotkeys, notifications and file dialogs have nothing in a
//! browser to stand for them, and report so.
const std = @import("std");
const z = @import("ziggurat");
const types = @import("types.zig");
const picker = @import("picker.zig");
const menus = @import("menus.zig");
const unsupported = @import("unsupported.zig");

/// Items as text: per item kind, enabled, checked, parent's index + 1 and
/// the label, separated by 0x1f, items by 0x1e. The page calls
/// `ziggurat_owner_popup` with the chosen item's index, or -1.
extern "ziggurat" fn zw_menu_popup(owner: *Owner, serial: u32, window: u32, items: [*]const u8, length: u32, kind: u32, x: f64, y: f64) void;
extern "ziggurat" fn zw_menu_cancel(owner: *Owner) void;
/// The index of the button pressed, or -1 when dismissed.
extern "ziggurat" fn zw_message(text: [*]const u8, length: u32, buttons: u32) i32;

pub const Owner = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, types.Action) void,
    window: ?z.Window = null,
    popup_request: u64 = 0,
    popup_serial: u32 = 0,
    popup_ids: [menus.max_items]u64 = undefined,
    popup_count: usize = 0,
    message_request: u64 = 0,
    message_response: types.MessageResponse = .dismissed,
    message_posted: bool = false,

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, types.Action) void) Owner {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(self: *Owner, window: z.Window) !void {
        window.app.assertOwner();
        if (self.window != null) return error.AlreadyAttached;
        if (window.isClosed()) return error.Closed;
        self.window = window;
    }
    pub fn detach(self: *Owner) !void {
        const window = self.window orelse return;
        window.app.assertOwner();
        if (self.popup_request != 0) zw_menu_cancel(self);
        self.popup_request = 0;
        self.message_request = 0;
        self.window = null;
    }
    fn require(self: *Owner) !z.Window {
        const window = self.window orelse return error.NotAttached;
        window.app.assertOwner();
        if (window.isClosed()) return error.Closed;
        return window;
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
    pub fn setItemIcon(_: *Owner, _: u64, _: ?*types.MenuIcon) !void {
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

    /// A menu of HTML at the anchor, in the window's coordinates, or at the
    /// pointer's last place on the page.
    pub fn popupMenu(self: *Owner, request: u64, items: []const types.Item, anchor: types.Anchor) !void {
        const window = try self.require();
        if (self.popup_request != 0) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const plan = try menus.validate(items, true);
        var text: [16384]u8 = undefined;
        var used: usize = 0;
        for (items, 0..) |item, index| {
            var label: [512]u8 = undefined;
            const plain: []const u8 = if (item.kind == .separator) "" else try menus.plainLabel(&label, item.label);
            const parent: usize = if (item.parent) |id| (for (items[0..index], 0..) |other, at| {
                if (other.kind == .submenu and other.id == id) break at + 1;
            } else 0) else 0;
            const kind: u8 = switch (item.kind) {
                .command => 'c',
                .submenu => 's',
                .separator => '-',
            };
            const written = std.fmt.bufPrint(text[used..], "{c}\x1f{d}\x1f{d}\x1f{d}\x1f{s}\x1e", .{ kind, @intFromBool(plan.enabled[index]), @intFromBool(item.checked), parent, plain }) catch return error.MenuTooLarge;
            used += written.len;
            self.popup_ids[index] = item.id;
        }
        self.popup_count = items.len;
        var kind: u32 = 0;
        var x: f64 = 0;
        var y: f64 = 0;
        switch (anchor) {
            .pointer => {},
            .client => |point| {
                if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidAnchor;
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
        self.popup_serial +%= 1;
        self.popup_request = request;
        const handle = window.nativeHandle() orelse return error.Closed;
        zw_menu_popup(self, self.popup_serial, @intCast(@intFromPtr(handle)), &text, @intCast(used), kind, x, y);
    }
    pub fn cancelPopup(self: *Owner) !void {
        _ = try self.require();
        if (self.popup_request == 0) return;
        zw_menu_cancel(self);
    }
    fn popupDone(self: *Owner, serial: u32, index: i32) callconv(.c) void {
        if (serial != self.popup_serial or self.popup_request == 0) return;
        const request = self.popup_request;
        self.popup_request = 0;
        const selected: ?u64 = if (index >= 0 and @as(usize, @intCast(index)) < self.popup_count) self.popup_ids[@intCast(index)] else null;
        self.deliver(.{ .popup = .{ .request = request, .selected = selected } });
    }

    /// One button asks with `alert`; more with `confirm`, whose OK is the
    /// default button (or the first other than the cancel one) and whose
    /// Cancel is the cancel button, or dismisses. The answer comes after
    /// this returns, as from the desktops' dialogs.
    pub fn showMessage(self: *Owner, request: u64, options: types.MessageOptions) !void {
        const window = try self.require();
        if (self.message_request != 0) return error.MessageAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        try menus.validateMessage(options);
        var text: [8192]u8 = undefined;
        const shown = if (options.title.len != 0)
            std.fmt.bufPrint(&text, "{s}\n\n{s}", .{ options.title, options.message }) catch return error.MessageTooLarge
        else
            std.fmt.bufPrint(&text, "{s}", .{options.message}) catch return error.MessageTooLarge;
        const pressed = zw_message(shown.ptr, @intCast(shown.len), @intCast(options.buttons.len));
        const ok: usize = options.default_button orelse for (options.buttons, 0..) |_, index| {
            if (options.cancel_button == null or options.cancel_button.? != index) break index;
        } else 0;
        self.message_response = if (options.buttons.len == 1)
            .{ .button = options.buttons[0].id }
        else if (pressed == 0)
            .{ .button = options.buttons[ok].id }
        else if (options.cancel_button) |index| .{ .button = options.buttons[index].id } else .dismissed;
        self.message_request = request;
        if (!self.message_posted) {
            try window.app.post(.{ .context = self, .call = messageDone });
            self.message_posted = true;
        }
    }
    pub fn cancelMessage(self: *Owner) !void {
        _ = try self.require();
    }
    fn messageDone(context: *anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context));
        self.message_posted = false;
        const request = self.message_request;
        if (request == 0) return;
        self.message_request = 0;
        self.deliver(.{ .message = .{ .request = request, .response = self.message_response } });
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

pub const Tray = unsupported.Tray;

fn popupResult(owner: *Owner, serial: u32, index: i32) callconv(.c) void {
    owner.popupDone(serial, index);
}
comptime {
    if (@import("builtin").cpu.arch == .wasm32) @export(&popupResult, .{ .name = "ziggurat_owner_popup" });
}
