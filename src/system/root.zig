const builtin = @import("builtin");
pub const types = @import("types.zig");
pub const Item = types.Item;
pub const Action = types.Action;
pub const ScreenPoint = types.ScreenPoint;
pub const TrayOptions = types.TrayOptions;
pub const Key = types.Key;
pub const Modifiers = types.Modifiers;
pub const Hotkey = types.Hotkey;
pub const NotificationOptions = types.NotificationOptions;
pub const Owner = if (builtin.os.tag == .windows) @import("windows.zig").Owner else @import("unsupported.zig").Owner;
pub const clipboard = @import("clipboard.zig");
pub const drop = @import("drop.zig");
pub const picker = @import("picker.zig");
pub const shell = @import("shell.zig");
pub const desktop = @import("desktop.zig");
pub const watch = @import("watch.zig");
pub const capabilities = .{
    .native_menu = builtin.os.tag == .windows,
    .tray = builtin.os.tag == .windows,
    .clipboard_text = builtin.os.tag == .windows,
    .clipboard = clipboard.capabilities,
    .drop = drop.capabilities,
    .async_file_dialog = builtin.os.tag == .windows,
    .global_hotkeys = builtin.os.tag == .windows,
    .notification_area = builtin.os.tag == .windows,
    .shell = shell.capabilities,
    .desktop = desktop.capabilities,
    .file_watch = builtin.os.tag == .windows or builtin.os.tag == .linux,
};
