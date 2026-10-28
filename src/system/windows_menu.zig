//! Native Win32 menus shared by the window Owner and standalone tray items.
//! Popup tracking starts from a posted message on a private helper window,
//! never inside an application or framework callback. The system's menu
//! tracking loop then runs the same way native window move/resize does.
const std = @import("std");
const types = @import("types.zig");
const menus = @import("menus.zig");
const c = @import("ziggurat_c_win32");

pub const Entry = struct { id: u64, command: u16, menu: c.HMENU, enabled: bool, ancestor_enabled: bool, accelerator: ?types.Accelerator };
pub const Built = struct { menu: c.HMENU, count: usize };

/// Builds a menu bar (`popup == false`) or a popup root. Labels are copied by
/// Win32 during the call. Command IDs run consecutively from `first_command`.
pub fn build(items: []const types.Item, plan: *const menus.Plan, popup: bool, first_command: u32, entries: []Entry) !Built {
    const root = (if (popup) c.CreatePopupMenu() else c.CreateMenu()) orelse return error.MenuCreationFailed;
    var owned = true;
    defer if (owned) {
        _ = c.DestroyMenu(root);
    };
    var submenus: [types.max_menu_items]c.HMENU = @splat(null);
    var count: usize = 0;
    var command: u32 = first_command;
    for (items, 0..) |item, index| {
        const parent_menu = if (plan.parent[index]) |parent| submenus[parent].? else root;
        if (item.kind == .separator) {
            if (c.AppendMenuW(parent_menu, c.MF_SEPARATOR, 0, null) == 0) return error.MenuCreationFailed;
            continue;
        }
        var label: [320]u16 = undefined;
        const text = try labelText(&label, item);
        const flags: c.UINT = @as(c.UINT, @intCast(c.MF_STRING)) | @as(c.UINT, @intCast(if (item.enabled) 0 else c.MF_GRAYED)) | @as(c.UINT, @intCast(if (item.checked) c.MF_CHECKED else 0));
        if (item.kind == .submenu) {
            const submenu = c.CreatePopupMenu() orelse return error.MenuCreationFailed;
            if (c.AppendMenuW(parent_menu, flags | @as(c.UINT, @intCast(c.MF_POPUP)), @intFromPtr(submenu), text.ptr) == 0) {
                _ = c.DestroyMenu(submenu);
                return error.MenuCreationFailed;
            }
            submenus[index] = submenu;
        } else {
            if (c.AppendMenuW(parent_menu, flags, command, text.ptr) == 0) return error.MenuCreationFailed;
            entries[count] = .{ .id = item.id, .command = @intCast(command), .menu = parent_menu, .enabled = plan.enabled[index], .ancestor_enabled = plan.ancestors_enabled[index], .accelerator = item.accelerator };
            count += 1;
            command += 1;
        }
    }
    owned = false;
    return .{ .menu = root, .count = count };
}

fn labelText(destination: []u16, item: types.Item) ![:0]const u16 {
    var bytes: [1024]u8 = undefined;
    var label = item.label;
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
};

/// Keep at a stable address while pending. The helper window links back to
/// this Host; detach severs that link before the Host may disappear, so a
/// tracking loop that returns later only releases its own menu and window.
pub const Host = struct {
    context: *anyopaque,
    done: Done,
    helper: c.HWND = null,
    menu: c.HMENU = null,
    target: c.HWND = null,
    request: u64 = 0,
    placement: Placement = .{ .x = 0, .y = 0 },
    ids: [types.max_menu_items]u64 = undefined,
    enabled: [types.max_menu_items]bool = undefined,
    count: usize = 0,
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
        const built = try build(items, &plan, true, 1, &entries);
        var owned = true;
        defer if (owned) {
            _ = c.DestroyMenu(built.menu);
        };
        const helper = try createHelper(self);
        if (c.PostMessageW(helper, start_message, 0, 0) == 0) {
            self.last_error = c.GetLastError();
            _ = c.DestroyWindow(helper);
            return error.MenuStartFailed;
        }
        owned = false;
        self.helper = helper;
        self.menu = built.menu;
        self.target = target orelse helper;
        self.request = request;
        self.placement = placement;
        self.count = built.count;
        self.cancelled = false;
        for (entries[0..built.count], 0..) |entry, index| {
            self.ids[index] = entry.id;
            self.enabled[index] = entry.enabled;
        }
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
        const selected: ?u64 = if (command >= 1 and command <= self.count and self.enabled[command - 1]) self.ids[command - 1] else null;
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
    host.tracking = true;
    tracking_depth += 1;
    if (placement.foreground) _ = c.SetForegroundWindow(target);
    var params = std.mem.zeroes(c.TPMPARAMS);
    params.cbSize = @sizeOf(c.TPMPARAMS);
    if (placement.exclude) |rect| params.rcExclude = .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
    const flags: c.UINT = @intCast(c.TPM_RETURNCMD | c.TPM_NONOTIFY | c.TPM_RIGHTBUTTON | if (placement.exclude != null) c.TPM_VERTICAL else 0);
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
