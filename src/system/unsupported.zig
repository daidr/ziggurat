const z = @import("ziggurat");
const types = @import("types.zig");
const picker = @import("picker.zig");

pub const Owner = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, types.Action) void,
    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, types.Action) void) Owner {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(_: *Owner, window: z.Window) !void {
        window.app.assertOwner();
        return error.UnsupportedCapability;
    }
    pub fn detach(_: *Owner) !void {}
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
    pub fn popupMenu(_: *Owner, _: u64, _: []const types.Item, _: types.Anchor) !void {
        return error.UnsupportedCapability;
    }
    pub fn cancelPopup(_: *Owner) !void {
        return error.UnsupportedCapability;
    }
    pub fn showMessage(_: *Owner, _: u64, _: types.MessageOptions) !void {
        return error.UnsupportedCapability;
    }
    pub fn cancelMessage(_: *Owner) !void {
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

pub const Tray = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void,
    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, *Tray, types.TrayAction) void) Tray {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn show(_: *Tray, app: *z.App, _: types.TrayItemOptions) !void {
        app.assertOwner();
        return error.UnsupportedCapability;
    }
    pub fn remove(_: *Tray) !void {}
    pub fn popupMenu(_: *Tray, _: u64, _: []const types.Item, _: types.TrayAnchor) !void {
        return error.UnsupportedCapability;
    }
    pub fn cancelPopup(_: *Tray) void {}
};
