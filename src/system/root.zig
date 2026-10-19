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
pub const Accelerator = types.Accelerator;
pub const Anchor = types.Anchor;
pub const ClientPoint = types.ClientPoint;
pub const PopupResult = types.PopupResult;
pub const MessageButton = types.MessageButton;
pub const MessageOptions = types.MessageOptions;
pub const MessageResponse = types.MessageResponse;
pub const MessageResult = types.MessageResult;
pub const TrayItemOptions = types.TrayItemOptions;
pub const TrayAnchor = types.TrayAnchor;
pub const TrayAction = types.TrayAction;
const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux and !builtin.is_test;
pub const Owner = if (windows) @import("windows.zig").Owner else if (linux) @import("linux.zig").Owner else @import("unsupported.zig").Owner;
/// An App-level notification-area item independent of any window.
pub const Tray = if (windows) @import("windows_tray.zig").Tray else @import("unsupported.zig").Tray;
pub const clipboard = @import("clipboard.zig");
pub const drop = @import("drop.zig");
pub const picker = @import("picker.zig");
pub const message = if (linux) @import("linux.zig").message else @import("message.zig");
pub const menus = @import("menus.zig");
pub const shell = @import("shell.zig");
pub const desktop = @import("desktop.zig");
pub const watch = @import("watch.zig");
pub const capabilities = .{
    .native_menu = windows,
    .menu_accelerators = windows,
    .context_menu = windows or linux,
    .message_dialog = windows or linux,
    .tray = windows,
    .standalone_tray = windows,
    .clipboard_text = windows,
    .clipboard = clipboard.capabilities,
    .drop = drop.capabilities,
    .async_file_dialog = windows,
    .global_hotkeys = windows,
    .notification_area = windows,
    .shell = shell.capabilities,
    .desktop = desktop.capabilities,
    .file_watch = builtin.os.tag == .windows or builtin.os.tag == .linux,
};
