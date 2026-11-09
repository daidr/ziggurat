//! Native Win32 menus shared by the window Owner and standalone tray items.
//! Popup tracking starts from a posted message on a private helper window,
//! never inside an application or framework callback. The system's menu
//! tracking loop then runs the same way native window move/resize does.
const std = @import("std");
const types = @import("types.zig");
const menus = @import("menus.zig");
const c = @import("ziggurat_c_win32");

/// `radio_first`/`radio_last` are the command IDs bounding a radio item's group.
/// `top`: an item of a bar itself, which shows no icon.
pub const Entry = struct { id: u64, command: u16, menu: c.HMENU, enabled: bool, ancestor_enabled: bool, accelerator: ?types.Accelerator, radio_first: u16 = 0, radio_last: u16 = 0, top: bool = false };
pub const Built = struct { menu: c.HMENU, count: usize };

/// Popup menus are dark since the app's appearance last was (theme.zig):
/// template icons take their text color.
pub var dark_menus = false;

/// The color of menu text, 0xRRGGBB, which template icons take.
fn textColor() u32 {
    var contrast = std.mem.zeroes(c.HIGHCONTRASTW);
    contrast.cbSize = @sizeOf(c.HIGHCONTRASTW);
    const high = c.SystemParametersInfoW(c.SPI_GETHIGHCONTRAST, contrast.cbSize, &contrast, 0) != 0 and contrast.dwFlags & c.HCF_HIGHCONTRASTON != 0;
    if (dark_menus and !high) return 0xffffff;
    const color: u32 = c.GetSysColor(c.COLOR_MENUTEXT);
    return (color & 0xff) << 16 | (color & 0xff00) | (color >> 16 & 0xff);
}

/// Builds a menu bar (`popup == false`) or a popup root. Labels are copied by
/// Win32 during the call. Command IDs run consecutively from `first_command`.
/// Item icons are made for `dpi`; the items of a bar itself show none.
pub fn build(items: []const types.Item, plan: *const menus.Plan, popup: bool, first_command: u32, entries: []Entry, dpi: u32) !Built {
    const root = (if (popup) c.CreatePopupMenu() else c.CreateMenu()) orelse return error.MenuCreationFailed;
    var owned = true;
    defer if (owned) {
        _ = c.DestroyMenu(root);
    };
    var submenus: [types.max_menu_items]c.HMENU = @splat(null);
    var count: usize = 0;
    var command: u32 = first_command;
    const tint = textColor();
    for (items, 0..) |item, index| {
        const parent_menu = if (plan.parent[index]) |parent| submenus[parent].? else root;
        if (item.kind == .separator) {
            if (c.AppendMenuW(parent_menu, c.MF_SEPARATOR, 0, null) == 0) return error.MenuCreationFailed;
            continue;
        }
        var label: [1024]u16 = undefined;
        const text = try labelText(&label, item);
        const flags: c.UINT = @as(c.UINT, @intCast(c.MF_STRING)) | @as(c.UINT, @intCast(if (item.enabled) 0 else c.MF_GRAYED)) | @as(c.UINT, @intCast(if (item.checked) c.MF_CHECKED else 0));
        if (item.kind == .submenu) {
            const submenu = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
            if (c.AppendMenuW(parent_menu, flags | @as(c.UINT, @intCast(c.MF_POPUP)), @intFromPtr(submenu), text.ptr) == 0) {
                _ = c.DestroyMenu(submenu);
                return error.MenuCreationFailed;
            }
            submenus[index] = submenu;
            try setIcon(parent_menu, c.GetMenuItemCount(parent_menu) - 1, true, if (popup or item.parent != null) item.icon else null, dpi, tint);
        } else {
            if (c.AppendMenuW(parent_menu, flags, command, text.ptr) == 0) return error.MenuCreationFailed;
            entries[count] = .{ .id = item.id, .command = @intCast(command), .menu = parent_menu, .enabled = plan.enabled[index], .ancestor_enabled = plan.ancestors_enabled[index], .accelerator = item.accelerator, .top = !popup and item.parent == null };
            if (!entries[count].top) try setIcon(parent_menu, command, false, item.icon, dpi, tint);
            if (plan.radio_group[index]) |group| {
                var info = std.mem.zeroes(c.MENUITEMINFOW);
                info.cbSize = @sizeOf(c.MENUITEMINFOW);
                info.fMask = c.MIIM_FTYPE;
                info.fType = c.MFT_STRING | c.MFT_RADIOCHECK;
                if (c.SetMenuItemInfoW(parent_menu, command, c.FALSE, &info) == 0) return error.MenuCreationFailed;
                // Commands of a group are consecutive: the group's first
                // entry is the earliest one with the same first command.
                const first: u16 = if (group != index) entries[count - 1].radio_first else @intCast(command);
                entries[count].radio_first = first;
                var at = count;
                while (at > 0 and entries[at - 1].radio_first == first and entries[at - 1].radio_last != 0) : (at -= 1) entries[at - 1].radio_last = @intCast(command);
                entries[count].radio_last = @intCast(command);
            }
            count += 1;
            command += 1;
        }
    }
    owned = false;
    return .{ .menu = root, .count = count };
}

/// Gives an item its icon's bitmap, or none. The icon keeps the bitmap,
/// which Win32 only borrows. An icon that cannot be drawn shows nothing.
pub fn setIcon(menu: c.HMENU, item: anytype, by_position: bool, icon: ?*types.MenuIcon, dpi: u32, tint: u32) !void {
    const handle: ?*anyopaque = if (icon) |value| value.bitmap(dpi, tint) else null;
    if (icon != null and handle == null) return;
    var info = std.mem.zeroes(c.MENUITEMINFOW);
    info.cbSize = @sizeOf(c.MENUITEMINFOW);
    info.fMask = c.MIIM_BITMAP;
    info.hbmpItem = @ptrCast(handle);
    if (c.SetMenuItemInfoW(menu, @intCast(item), @intFromBool(by_position), &info) == 0) return error.MenuCreationFailed;
}
/// The current menu text color for an update of one item's icon.
pub fn iconTint() u32 {
    return textColor();
}

fn labelText(destination: []u16, item: types.Item) ![:0]const u16 {
    var bytes: [2048]u8 = undefined;
    // The subtitle follows the label on the same line.
    var label = try menus.windowsLabel(bytes[1024..], item);
    if (item.accelerator) |accelerator| {
        @memcpy(bytes[0..label.len], label);
        bytes[label.len] = '\t';
        const name = try menus.formatAccelerator(bytes[label.len + 1 ..], accelerator, .windows);
        label = bytes[0 .. label.len + 1 + name.len];
    }
    const needed = std.unicode.calcUtf16LeLen(label) catch return error.InvalidUtf8;
    if (needed >= destination.len) return error.TextCapacityExceeded;
    const count = std.unicode.utf8ToUtf16Le(destination, label) catch return error.InvalidUtf8;
    destination[count] = 0;
    return destination[0..count :0];
}

/// Returns the accelerator for a WM_KEYDOWN/WM_SYSKEYDOWN, or null for keys
/// outside the named set, auto-repeat and AltGr text input.
pub fn pressed(wp: usize, lp: isize) ?types.Accelerator {
    if (@as(usize, @bitCast(lp)) & (1 << 30) != 0) return null;
    const key = keyFromVirtual(wp) orelse return null;
    const control = c.GetKeyState(c.VK_CONTROL) < 0;
    if (control and c.GetKeyState(c.VK_RMENU) < 0) return null;
    return .{ .key = key, .modifiers = .{ .control = control, .alt = c.GetKeyState(c.VK_MENU) < 0, .shift = c.GetKeyState(c.VK_SHIFT) < 0, .super = c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0 } };
}

pub fn keyFromVirtual(code: usize) ?types.Key {
    if (code >= 'A' and code <= 'Z') return @fromBackingInt(@intCast(@backingInt(types.Key.a) + code - 'A'));
    if (code >= '0' and code <= '9') return @fromBackingInt(@intCast(@backingInt(types.Key.digit0) + code - '0'));
    if (code >= c.VK_F1 and code <= c.VK_F24) return @fromBackingInt(@intCast(@backingInt(types.Key.f1) + code - c.VK_F1));
    return switch (code) {
        c.VK_SPACE => .space,
        c.VK_RETURN => .enter,
        c.VK_ESCAPE => .escape,
        c.VK_TAB => .tab,
        c.VK_BACK => .backspace,
        c.VK_DELETE => .delete,
        c.VK_INSERT => .insert,
        c.VK_HOME => .home,
        c.VK_END => .end,
        c.VK_PRIOR => .page_up,
        c.VK_NEXT => .page_down,
        c.VK_LEFT => .left,
        c.VK_RIGHT => .right,
        c.VK_UP => .up,
        c.VK_DOWN => .down,
        c.VK_OEM_PLUS => .plus,
        c.VK_OEM_MINUS => .minus,
        else => null,
    };
}

const start_message: u32 = c.WM_APP + 1;
const host_slot = 0;
var helper_class: c.ATOM = 0;
/// Main-thread only. A request posted while another menu tracks is dismissed
/// instead of stacking a second tracking loop inside the first.
var tracking_depth: u32 = 0;

pub const Done = *const fn (*anyopaque, u64, ?u64) void;
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };
/// Screen pixels. Plain integers keep callers independent of this file's
/// imported Win32 declarations.
pub const Placement = struct {
    x: i32,
    y: i32,
    /// Screen rectangle the menu should avoid covering, such as a tray icon.
    exclude: ?Rect = null,
    /// Tray menus must own the foreground to be dismissed by outside clicks.
    foreground: bool = false,
    /// TrackPopupMenuEx alignment flags; null aligns the menu's corner to
    /// the point, beside `exclude` vertically when there is one.
    alignment: ?c.UINT = null,
};

/// Keep at a stable address while pending. The helper window links back to
/// this Host; detach severs that link before the Host may disappear, so a
/// tracking loop that returns later only releases its own menu and window.
pub const Host = struct {
    context: *anyopaque,
    done: Done,
    /// Runs just before the menu loop starts, which dispatches only
    /// messages: an App whose wake has no message queued re-posts it here.
    entering: ?*const fn (*anyopaque) void = null,
    helper: c.HWND = null,
    menu: c.HMENU = null,
    target: c.HWND = null,
    request: u64 = 0,
    placement: Placement = .{ .x = 0, .y = 0 },
    ids: [types.max_menu_items]u64 = undefined,
    enabled: [types.max_menu_items]bool = undefined,
    count: usize = 0,
    /// The menu came from startMenu: complete with its commands as they are.
    raw: bool = false,
    tracking: bool = false,
    cancelled: bool = false,
    last_error: u32 = 0,

    pub fn pending(self: *const Host) bool {
        return self.helper != null;
    }

    /// `target` receives the menu's native notifications; null uses the
    /// helper window itself. The request completes through `done` exactly
    /// once unless detach() runs first.
    pub fn start(self: *Host, request: u64, items: []const types.Item, target: c.HWND, placement: Placement) !void {
        if (self.pending()) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        const plan = try menus.validate(items, true);
        var entries: [types.max_menu_items]Entry = undefined;
        const dpi = if (target) |window| c.GetDpiForWindow(window) else c.GetDpiForSystem();
        const built = try build(items, &plan, true, 1, &entries, if (dpi == 0) 96 else dpi);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyMenu(built.menu);
        };
        try self.begin(request, built.menu, target, placement);
        owned = false;
        self.count = built.count;
        self.raw = false;
        for (entries[0..built.count], 0..) |entry, index| {
            self.ids[index] = entry.id;
            self.enabled[index] = entry.enabled;
        }
    }

    /// Tracks a menu the caller built, which the Host then owns and destroys;
    /// on error the caller keeps it.
    /// The request completes with the chosen native command itself, or null.
    pub fn startMenu(self: *Host, request: u64, menu: c.HMENU, target: c.HWND, placement: Placement) !void {
        if (self.pending()) return error.MenuAlreadyPending;
        if (request == 0) return error.InvalidRequestId;
        try self.begin(request, menu, target, placement);
        self.count = 0;
        self.raw = true;
    }

    fn begin(self: *Host, request: u64, menu: c.HMENU, target: c.HWND, placement: Placement) !void {
        const helper = try createHelper(self);
        if (c.PostMessageW(helper, start_message, 0, 0) == 0) {
            self.last_error = c.GetLastError();
            _ = c.DestroyWindow(helper);
            return error.MenuStartFailed;
        }
        self.helper = helper;
        self.menu = menu;
        self.target = target orelse helper;
        self.request = request;
        self.placement = placement;
        self.cancelled = false;
    }

    /// Closes the menu; the request still completes with `selected = null`.
    pub fn cancel(self: *Host) void {
        if (!self.pending()) return;
        if (self.tracking) {
            _ = c.EndMenu();
        } else self.cancelled = true;
    }

    /// Silent: no completion runs after this returns.
    pub fn detach(self: *Host) void {
        const helper = self.helper orelse return;
        _ = c.SetWindowLongPtrW(helper, host_slot, 0);
        if (self.tracking) {
            // The tracking frame owns the menu and helper from here on.
            _ = c.EndMenu();
        } else {
            _ = c.DestroyWindow(helper);
            _ = c.DestroyMenu(self.menu);
        }
        self.reset();
    }

    fn reset(self: *Host) void {
        self.helper = null;
        self.menu = null;
        self.target = null;
        self.tracking = false;
        self.cancelled = false;
        self.count = 0;
    }

    fn finish(self: *Host, command: usize) void {
        const request = self.request;
        const selected: ?u64 = if (self.raw)
            (if (command != 0) command else null)
        else if (command >= 1 and command <= self.count and self.enabled[command - 1]) self.ids[command - 1] else null;
        const helper = self.helper;
        const menu = self.menu;
        self.reset();
        _ = c.SetWindowLongPtrW(helper, host_slot, 0);
        _ = c.DestroyWindow(helper);
        _ = c.DestroyMenu(menu);
        self.done(self.context, request, selected);
    }
};

fn busy() bool {
    if (tracking_depth != 0) return true;
    var info = std.mem.zeroes(c.GUITHREADINFO);
    info.cbSize = @sizeOf(c.GUITHREADINFO);
    if (c.GetGUIThreadInfo(c.GetCurrentThreadId(), &info) == 0) return false;
    return info.flags & (c.GUI_INMENUMODE | c.GUI_INMOVESIZE | c.GUI_POPUPMENUMODE | c.GUI_SYSTEMMENUMODE) != 0;
}

fn createHelper(host: *Host) !c.HWND {
    const instance = c.GetModuleHandleW(null);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ZigguratSystemMenuHost");
    if (helper_class == 0) {
        var class = std.mem.zeroes(c.WNDCLASSEXW);
        class.cbSize = @sizeOf(c.WNDCLASSEXW);
        class.lpfnWndProc = helperProc;
        class.cbWndExtra = @sizeOf(usize);
        class.hInstance = instance;
        class.lpszClassName = name;
        helper_class = c.RegisterClassExW(&class);
        if (helper_class == 0) {
            host.last_error = c.GetLastError();
            return error.MenuStartFailed;
        }
    }
    // A hidden tool window can take the foreground for tray menus without
    // appearing in the taskbar.
    const helper = c.CreateWindowExW(c.WS_EX_TOOLWINDOW, name, name, c.WS_POPUP, 0, 0, 0, 0, null, null, instance, null) orelse {
        host.last_error = c.GetLastError();
        return error.MenuStartFailed;
    };
    _ = c.SetWindowLongPtrW(helper, host_slot, @bitCast(@intFromPtr(host)));
    return helper;
}

fn helperProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message != start_message) return c.DefWindowProcW(hwnd, message, wp, lp);
    const address: usize = @bitCast(c.GetWindowLongPtrW(hwnd, host_slot));
    if (address == 0) return 0;
    const host: *Host = @ptrFromInt(address);
    if (host.helper != hwnd or host.tracking) return 0;
    if (host.cancelled or busy()) {
        host.finish(0);
        return 0;
    }
    const menu = host.menu;
    const target = host.target;
    const placement = host.placement;
    if (host.entering) |entering| entering(host.context);
    host.tracking = true;
    tracking_depth += 1;
    if (placement.foreground) _ = c.SetForegroundWindow(target);
    var params = std.mem.zeroes(c.TPMPARAMS);
    params.cbSize = @sizeOf(c.TPMPARAMS);
    if (placement.exclude) |rect| params.rcExclude = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
    const flags: c.UINT = @as(c.UINT, @intCast(c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON)) | (placement.alignment orelse @as(c.UINT, if (placement.exclude != null) c.TPM_VERTICAL else 0));
    const command = c.TrackPopupMenuEx(menu, flags, placement.x, placement.y, target, if (placement.exclude != null) &params else null);
    tracking_depth -= 1;
    if (placement.foreground) _ = c.PostMessageW(target, c.WM_NULL, 0, 0);
    // Detach during tracking severed the link; the Host may no longer exist.
    const current: usize = if (c.IsWindow(hwnd) != 0) @bitCast(c.GetWindowLongPtrW(hwnd, host_slot)) else 0;
    if (current == 0) {
        _ = c.DestroyMenu(menu);
        if (c.IsWindow(hwnd) != 0) _ = c.DestroyWindow(hwnd);
        return 0;
    }
    host.tracking = false;
    host.finish(@intCast(@max(command, 0)));
    return 0;
}

/// Appends copies of `source`'s items to `into`, submenus copied in turn,
/// with the same commands, labels, states and bitmaps. Bitmaps stay shared:
/// destroying the copy leaves them to `source`'s owner.
pub fn copyItems(source: c.HMENU, into: c.HMENU) bool {
    const count = c.GetMenuItemCount(source);
    if (count < 0) return false;
    for (0..@intCast(count)) |index| {
        var label: [256]u16 = undefined;
        var info = std.mem.zeroes(c.MENUITEMINFOW);
        info.cbSize = @sizeOf(c.MENUITEMINFOW);
        info.fMask = @intCast(c.MIIM_FTYPE | c.MIIM_STATE | c.MIIM_ID | c.MIIM_STRING | c.MIIM_SUBMENU | c.MIIM_BITMAP | c.MIIM_CHECKMARKS | c.MIIM_DATA);
        info.dwTypeData = &label;
        info.cch = label.len;
        if (c.GetMenuItemInfoW(source, @intCast(index), c.TRUE, &info) == 0) return false;
        if (info.hSubMenu) |submenu| {
            const copied = c.CreatePopupMenu() orelse return false;
            if (!copyItems(submenu, copied)) {
                _ = c.DestroyMenu(copied);
                return false;
            }
            info.hSubMenu = copied;
        }
        if (info.fType & @as(c.UINT, @intCast(c.MFT_SEPARATOR)) != 0) info.fMask &= ~@as(c.UINT, @intCast(c.MIIM_STRING));
        if (c.InsertMenuItemW(into, @intCast(index), c.TRUE, &info) == 0) {
            if (info.hSubMenu) |copied| _ = c.DestroyMenu(copied);
            return false;
        }
    }
    return true;
}

/// How far from the taskbar, in DIPs, Windows 11 opens the menus of the
/// notification area it shows itself: centered on their icons, rather than
/// at the pointer as Win32 menus open.
const tray_menu_gap = 12;

/// Where a tray icon's menu opens on Windows 11, as the system opens its own:
/// centered on the icon along the taskbar, `tray_menu_gap` DIPs from it.
/// Null on Windows 10, whose own menus open at the pointer, and for an icon
/// that is not on the taskbar (in its overflow, or nowhere).
pub fn trayPlacement(icon: c.RECT, dpi: u32) ?Placement {
    if (!windows11()) return null;
    var bar = std.mem.zeroes(c.APPBARDATA);
    bar.cbSize = @sizeOf(c.APPBARDATA);
    if (c.SHAppBarMessage(c.ABM_GETTASKBARPOS, &bar) == 0) return null;
    if (!(icon.left < bar.rc.right and bar.rc.left < icon.right and icon.top < bar.rc.bottom and bar.rc.top < icon.bottom)) return null;
    return trayMenuAt(icon, bar.rc, bar.uEdge, c.MulDiv(tray_menu_gap, @intCast(if (dpi == 0) 96 else dpi), 96));
}
/// The placement of a menu for an icon on a taskbar along an edge of its
/// monitor (ABE_*): the point, the flags that align the menu to it, and the
/// rectangle the menu keeps out of, the taskbar and the gap.
pub fn trayMenuAt(icon: c.RECT, bar: c.RECT, edge: c.UINT, gap: c_int) Placement {
    const x = @divTrunc(icon.left + icon.right, 2);
    const y = @divTrunc(icon.top + icon.bottom, 2);
    return switch (edge) {
        c.ABE_TOP => .{ .x = x, .y = bar.bottom + gap, .foreground = true, .alignment = c.TPM_CENTERALIGN | c.TPM_VERTICAL, .exclude = .{ .left = bar.left, .top = bar.top, .right = bar.right, .bottom = bar.bottom + gap } },
        c.ABE_LEFT => .{ .x = bar.right + gap, .y = y, .foreground = true, .alignment = c.TPM_VCENTERALIGN, .exclude = .{ .left = bar.left, .top = bar.top, .right = bar.right + gap, .bottom = bar.bottom } },
        c.ABE_RIGHT => .{ .x = bar.left - gap, .y = y, .foreground = true, .alignment = c.TPM_RIGHTALIGN | c.TPM_VCENTERALIGN, .exclude = .{ .left = bar.left - gap, .top = bar.top, .right = bar.right, .bottom = bar.bottom } },
        else => .{ .x = x, .y = bar.top - gap, .foreground = true, .alignment = c.TPM_CENTERALIGN | c.TPM_BOTTOMALIGN | c.TPM_VERTICAL, .exclude = .{ .left = bar.left, .top = bar.top - gap, .right = bar.right, .bottom = bar.bottom } },
    };
}
fn windows11() bool {
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    return std.os.windows.ntdll.RtlGetVersion(&info) == .SUCCESS and (info.dwMajorVersion > 10 or (info.dwMajorVersion == 10 and info.dwBuildNumber >= 22000));
}

test "a tray menu opens centered on its icon, a gap from the taskbar" {
    const bar: c.RECT = .{ .left = 0, .top = 1040, .right = 1920, .bottom = 1080 };
    const icon: c.RECT = .{ .left = 1700, .top = 1044, .right = 1732, .bottom = 1076 };
    const bottom = trayMenuAt(icon, bar, c.ABE_BOTTOM, 12);
    try std.testing.expectEqual(@as(i32, 1716), bottom.x);
    try std.testing.expectEqual(@as(i32, 1028), bottom.y);
    try std.testing.expectEqual(@as(i32, 1028), bottom.exclude.?.top);
    const left_bar: c.RECT = .{ .left = 0, .top = 0, .right = 48, .bottom = 1080 };
    const left = trayMenuAt(.{ .left = 8, .top = 900, .right = 40, .bottom = 932 }, left_bar, c.ABE_LEFT, 12);
    try std.testing.expectEqual(@as(i32, 60), left.x);
    try std.testing.expectEqual(@as(i32, 916), left.y);
}
