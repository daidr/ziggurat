const builtin = @import("builtin");
pub const max_menu_items = 128;
pub const Item = struct {
    /// Zero denotes the menu root and is reserved. Separators do not need an ID.
    id: u64 = 0,
    /// A submenu declared earlier in this slice; null denotes the menu bar.
    parent: ?u64 = null,
    kind: enum { command, submenu, separator } = .command,
    label: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
    /// Command items only. Shows a radio mark instead of a check mark. Radio
    /// commands next to each other under the same parent form one group, of
    /// which at most one is checked; `setItemState` checking one unchecks the
    /// rest of its group. The app keeps the state, as for check marks.
    radio: bool = false,
    /// Command items only. Shown beside the label; a menu bar also dispatches
    /// it as `Action.menu` when the window's content leaves the key unconsumed.
    /// On macOS `super` is Command, and the menu bar takes its key equivalents
    /// before the window's content, as AppKit does.
    accelerator: ?Accelerator = null,
    /// Commands and submenus. Shown before the label, except on the items of
    /// a menu bar itself; borrowed while any menu shows it.
    icon: ?*MenuIcon = null,
};
pub const MenuIcon = @import("menu_icon.zig").MenuIcon;
/// Letters, digits and navigation keys need Control, Alt or Super, so typing
/// never triggers a command. Function keys may stand alone.
pub const Accelerator = struct { key: Key, modifiers: Modifiers = .{} };
pub const ScreenPoint = struct { x: i32, y: i32 };
/// Where a popup menu opens. `client` is in DIPs relative to the window's
/// client area; `screen` is in physical pixels; `pointer` uses the cursor.
pub const Anchor = union(enum) { pointer, client: ClientPoint, screen: ScreenPoint };
pub const ClientPoint = struct { x: f32, y: f32 };
/// Delivered once for every accepted popup request unless its Owner detaches
/// or its window closes first. A dismissed menu reports `selected = null`.
pub const PopupResult = struct { request: u64, selected: ?u64 };
pub const max_message_buttons = 3;
pub const MessageButton = struct {
    id: u64,
    label: []const u8,
    /// Marks a button that destroys data, which macOS shows in red and GTK
    /// in its destructive style; Windows' task dialogs have no such style.
    destructive: bool = false,
};
pub const MessageOptions = struct {
    title: []const u8 = "",
    message: []const u8,
    /// One to three buttons in display order. IDs are nonzero and unique.
    buttons: []const MessageButton,
    /// Indices into `buttons`. Escape or the close button reports the cancel
    /// button when one is named, otherwise `dismissed`. Without a default,
    /// Return answers no button on macOS.
    default_button: ?usize = null,
    cancel_button: ?usize = null,
    /// Selects the icon where the system dialog shows one.
    kind: enum { info, warning, err, question } = .info,
};
pub const MessageResponse = union(enum) {
    button: u64,
    /// Closed without a button, including an explicit cancelMessage.
    dismissed,
    failed: struct { err: anyerror, code: ?i32 = null },
};
pub const MessageResult = struct { request: u64, response: MessageResponse };
pub const Action = union(enum) { menu: u64, tray_activate, tray_context: ScreenPoint, hotkey: u64, notification_activated: u64, popup: PopupResult, message: MessageResult };
pub const TrayOptions = struct {
    /// Borrowed only by setTray. The module owns a CopyIcon result afterward.
    /// Null selects the shared system application icon as the copy source.
    icon: ?*anyopaque = null,
    tooltip: []const u8 = "",
    /// The icon is black and transparent, which macOS tints to match the
    /// menu bar; other systems show it as it is.
    template: bool = false,
};

pub const TrayItemOptions = struct {
    /// Borrowed only by show(). Null copies the shared system application icon.
    icon: ?*anyopaque = null,
    /// The icon is black and transparent, which macOS tints to match the
    /// menu bar; other systems show it as it is.
    template: bool = false,
    tooltip: []const u8 = "",
    /// Text beside the icon where the panel shows one, such as Linux
    /// indicator panels and the macOS menu bar. The Windows notification area shows only icons, so
    /// it validates the title and otherwise ignores it.
    title: []const u8 = "",
    /// The item's own menu, copied during show(), as setMenu() takes it.
    /// Null keeps the current menu; an empty slice removes it.
    menu: ?[]const Item = null,
    /// Optional stable identity, written in the identifier's text byte order.
    /// The shell then remembers the user's placement across runs; it binds
    /// the identity to this executable path, so another path fails to add it.
    guid: ?[16]u8 = null,
};
/// `icon` opens beside the item where the shell reports its rectangle and at
/// the pointer otherwise.
pub const TrayAnchor = union(enum) { icon, pointer, screen: ScreenPoint };
/// `menu` reports an enabled command of the item's own menu (setMenu).
pub const TrayAction = union(enum) { activate, context: ScreenPoint, popup: PopupResult, menu: u64 };

pub const max_hotkeys = 32;
pub const Key = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    space,
    enter,
    escape,
    tab,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    left,
    right,
    up,
    down,
    /// The "=" / "+" key of the main block, as "CmdOrCtrl+Plus" names it.
    plus,
    minus,
};
pub const Modifiers = struct {
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    /// The Windows key, Super on Linux and Command on macOS.
    super: bool = false,
    /// The modifier of standard shortcuts: Command on macOS, Control elsewhere.
    pub const primary: Modifiers = if (builtin.os.tag == .macos) .{ .super = true } else .{ .control = true };
};
pub const Hotkey = struct { key: Key, modifiers: Modifiers = .{}, repeat: bool = false };
pub const NotificationOptions = struct {
    title: []const u8,
    body: []const u8,
    kind: enum { info, warning, err } = .info,
    silent: bool = true,
    /// Discard if the shell cannot show it immediately.
    real_time: bool = true,
};
