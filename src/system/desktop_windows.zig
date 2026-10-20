//! Windows desktop snapshots and the per-Watch hidden notification window.
//! Owner thread only, except networkChanged, which only posts a message.
const std = @import("std");
const desktop = @import("desktop.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Native = struct {
    hwnd: c.HWND = null,
    network: c.HANDLE = null,
    power: ?*anyopaque = null,
    pending: u32 = 0,
    flush_posted: bool = false,
};

var live_windows: usize = 0;
pub fn resourceCount() usize {
    return live_windows;
}

// System DLLs loaded once from System32 on the owner thread and kept mapped
// for the process; absent exports leave the corresponding field unknown.
const HintLevel = enum(c_int) { unknown = 0, none = 1, local = 2, internet = 3, constrained = 4, hidden = 5, _ };
const HintCost = enum(c_int) { unknown = 0, unrestricted = 1, fixed = 2, variable = 3, _ };
const Hint = extern struct { level: HintLevel, cost: HintCost, approaching_limit: u8, over_limit: u8, roaming: u8 };
const HintCallback = *const fn (?*anyopaque, Hint) callconv(.winapi) void;
const Functions = struct {
    loaded: bool = false,
    dpi_for_monitor: ?*const fn (c.HMONITOR, c_int, *c_uint, *c_uint) callconv(.winapi) c.HRESULT = null,
    colorization: ?*const fn (*u32, *c.BOOL) callconv(.winapi) c.HRESULT = null,
    connectivity_hint: ?*const fn (*Hint) callconv(.winapi) c_long = null,
    notify_hint: ?*const fn (HintCallback, ?*anyopaque, u8, *c.HANDLE) callconv(.winapi) c_long = null,
    cancel_notify: ?*const fn (c.HANDLE) callconv(.winapi) c_long = null,
};
var functions: Functions = .{};
fn system(name: [*:0]const u16) c.HMODULE {
    return c.LoadLibraryExW(name, null, 0x00000800); // LOAD_LIBRARY_SEARCH_SYSTEM32
}
fn lookup(comptime T: type, module: c.HMODULE, name: [*:0]const u8) ?T {
    if (module == null) return null;
    const address = c.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}
fn Function(comptime name: []const u8) type {
    return @typeInfo(@FieldType(Functions, name)).optional.child;
}
fn api() *const Functions {
    if (!functions.loaded) {
        functions.loaded = true;
        const shcore = system(L("shcore.dll"));
        const dwmapi = system(L("dwmapi.dll"));
        const iphlpapi = system(L("iphlpapi.dll"));
        functions.dpi_for_monitor = lookup(Function("dpi_for_monitor"), shcore, "GetDpiForMonitor");
        functions.colorization = lookup(Function("colorization"), dwmapi, "DwmGetColorizationColor");
        functions.connectivity_hint = lookup(Function("connectivity_hint"), iphlpapi, "GetNetworkConnectivityHint");
        functions.notify_hint = lookup(Function("notify_hint"), iphlpapi, "NotifyNetworkConnectivityHintChange");
        functions.cancel_notify = lookup(Function("cancel_notify"), iphlpapi, "CancelMibChangeNotify2");
    }
    return &functions;
}

fn rect(value: c.RECT) desktop.Rect {
    return .{ .x = value.left, .y = value.top, .width = @intCast(@max(0, @as(i64, value.right) - value.left)), .height = @intCast(@max(0, @as(i64, value.bottom) - value.top)) };
}
const Enumeration = struct {
    out: *[desktop.max_monitors]desktop.Monitor,
    count: usize = 0,
    err: ?anyerror = null,
    fn visit(handle: c.HMONITOR, _: c.HDC, _: ?*c.RECT, context: c.LPARAM) callconv(.winapi) c.BOOL {
        const self: *Enumeration = @ptrFromInt(@as(usize, @bitCast(context)));
        if (self.count == self.out.len) {
            self.err = error.TooManyMonitors;
            return 0;
        }
        var info = std.mem.zeroes(c.MONITORINFOEXW);
        info.unnamed_0.cbSize = @sizeOf(c.MONITORINFOEXW);
        if (c.GetMonitorInfoW(handle, @ptrCast(&info)) == 0) {
            self.err = error.DesktopQueryFailed;
            return 0;
        }
        var scale: f32 = @as(f32, @floatFromInt(c.GetDpiForSystem())) / 96;
        if (api().dpi_for_monitor) |dpi_for_monitor| {
            var x: c_uint = 0;
            var y: c_uint = 0;
            if (dpi_for_monitor(handle, 0, &x, &y) >= 0 and x != 0) scale = @as(f32, @floatFromInt(x)) / 96;
        }
        var mode = std.mem.zeroes(c.DEVMODEW);
        mode.dmSize = @sizeOf(c.DEVMODEW);
        var refresh: ?u32 = null;
        if (c.EnumDisplaySettingsW(&info.szDevice, c.ENUM_CURRENT_SETTINGS, &mode) != 0 and mode.dmDisplayFrequency > 1) refresh = mode.dmDisplayFrequency;
        self.out[self.count] = .{ .bounds = rect(info.unnamed_0.rcMonitor), .work_area = rect(info.unnamed_0.rcWork), .scale = scale, .primary = info.unnamed_0.dwFlags & c.MONITORINFOF_PRIMARY != 0, .refresh_hz = refresh };
        self.count += 1;
        return 1;
    }
};
pub fn monitors(out: *[desktop.max_monitors]desktop.Monitor) !usize {
    var enumeration: Enumeration = .{ .out = out };
    if (c.EnumDisplayMonitors(null, null, Enumeration.visit, @bitCast(@intFromPtr(&enumeration))) == 0) return enumeration.err orelse error.DesktopQueryFailed;
    if (enumeration.count == 0) return error.DesktopQueryFailed;
    return enumeration.count;
}

const hkcu: c.HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));
fn dword(key: [*:0]const u16, name: [*:0]const u16) ?u32 {
    var value: u32 = 0;
    var size: c.DWORD = @sizeOf(u32);
    if (c.RegGetValueW(hkcu, key, name, c.RRF_RT_REG_DWORD, null, &value, &size) != 0) return null;
    return value;
}
pub fn preferences() desktop.Preferences {
    const personalize = L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    var result: desktop.Preferences = .{};
    if (dword(personalize, L("AppsUseLightTheme"))) |light| result.color_scheme = if (light != 0) .light else .dark;
    if (dword(personalize, L("EnableTransparency"))) |transparency| result.reduce_transparency = transparency == 0;
    if (dword(L("Software\\Microsoft\\Windows\\DWM"), L("AccentColor"))) |abgr| {
        result.accent = (abgr & 0xff) << 16 | (abgr & 0xff00) | (abgr >> 16 & 0xff);
    } else if (api().colorization) |colorization| {
        var argb: u32 = 0;
        var opaque_blend: c.BOOL = 0;
        if (colorization(&argb, &opaque_blend) >= 0) result.accent = argb & 0xffffff;
    }
    var contrast = std.mem.zeroes(c.HIGHCONTRASTW);
    contrast.cbSize = @sizeOf(c.HIGHCONTRASTW);
    if (c.SystemParametersInfoW(c.SPI_GETHIGHCONTRAST, contrast.cbSize, &contrast, 0) != 0) result.high_contrast = contrast.dwFlags & c.HCF_HIGHCONTRASTON != 0;
    var animation: c.BOOL = 1;
    if (c.SystemParametersInfoW(c.SPI_GETCLIENTAREAANIMATION, 0, &animation, 0) != 0) result.reduce_motion = animation == 0;
    if (dword(L("Software\\Microsoft\\Accessibility"), L("TextScaleFactor"))) |percent| {
        if (percent >= 100 and percent <= 500) result.text_scale = @as(f32, @floatFromInt(percent)) / 100;
    }
    return result;
}

pub fn power() !desktop.Power {
    var status: c.SYSTEM_POWER_STATUS = undefined;
    if (c.GetSystemPowerStatus(&status) == 0) return error.DesktopQueryFailed;
    return .{
        .source = switch (status.ACLineStatus) {
            0 => .battery,
            1 => .ac,
            else => .unknown,
        },
        .battery_percent = if (status.BatteryFlag & 128 == 0 and status.BatteryLifePercent <= 100) status.BatteryLifePercent else null,
        .saver = status.SystemStatusFlag & 1 != 0,
    };
}

fn fromHint(hint: Hint) desktop.Network {
    return .{
        .state = switch (hint.level) {
            .none => .offline,
            .local, .internet, .constrained => .online,
            else => .unknown,
        },
        .metered = if (hint.roaming != 0 or hint.over_limit != 0) true else switch (hint.cost) {
            .unrestricted => false,
            .fixed, .variable => true,
            else => null,
        },
    };
}
pub fn network() desktop.Network {
    const get = api().connectivity_hint orelse return .{};
    var hint = std.mem.zeroes(Hint);
    if (get(&hint) != 0) return .{};
    return fromHint(hint);
}

const bit_monitors: u32 = 1;
const bit_preferences: u32 = 2;
const bit_power: u32 = 4;
const bit_network: u32 = 8;
var class_registered = false;
var flush_message: c.UINT = 0;
/// Written once before the first network registration; read by its callback.
var network_message: c.UINT = 0;
const class_name = L("ZigguratDesktopWatch");
// GUID_POWER_SAVING_STATUS (battery saver).
const power_saving_status: c.GUID = .{ .Data1 = 0xe00958c0, .Data2 = 0xc213, .Data3 = 0x4ace, .Data4 = .{ 0xac, 0x77, 0xfe, 0xcc, 0xed, 0x2e, 0xee, 0xa5 } };

fn ensureClass() !void {
    if (class_registered) return;
    flush_message = c.RegisterWindowMessageW(L("Ziggurat.Desktop.Flush"));
    network_message = c.RegisterWindowMessageW(L("Ziggurat.Desktop.Network"));
    if (flush_message == 0 or network_message == 0) return error.WatchFailed;
    var class = std.mem.zeroes(c.WNDCLASSEXW);
    class.cbSize = @sizeOf(c.WNDCLASSEXW);
    class.lpfnWndProc = procedure;
    class.hInstance = c.GetModuleHandleW(null);
    class.lpszClassName = class_name;
    if (c.RegisterClassExW(&class) == 0 and c.GetLastError() != c.ERROR_CLASS_ALREADY_EXISTS) return error.WatchFailed;
    class_registered = true;
}

pub fn start(watch: *desktop.Watch) !void {
    try ensureClass();
    // A never-shown top-level window: message-only windows miss broadcasts.
    const hwnd = c.CreateWindowExW(c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE, class_name, L(""), c.WS_POPUP, 0, 0, 0, 0, null, null, c.GetModuleHandleW(null), null) orelse return error.WatchFailed;
    live_windows += 1;
    watch.native = .{ .hwnd = hwnd };
    errdefer stop(watch);
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(watch)));
    if (watch.kinds.power) watch.native.power = c.RegisterPowerSettingNotification(hwnd, &power_saving_status, c.DEVICE_NOTIFY_WINDOW_HANDLE);
    if (watch.kinds.network) {
        if (api().notify_hint) |notify| {
            var handle: c.HANDLE = null;
            // The callback context is the HWND value, never a Zig pointer.
            if (notify(networkChanged, hwnd, 0, &handle) != 0) return error.WatchFailed;
            watch.native.network = handle;
        }
    }
}

pub fn stop(watch: *desktop.Watch) void {
    const hwnd = watch.native.hwnd orelse return;
    // Cancellation waits for an in-flight callback, which only posts.
    if (watch.native.network) |handle| if (api().cancel_notify) |cancel| {
        _ = cancel(handle);
    };
    if (watch.native.power) |handle| _ = c.UnregisterPowerSettingNotification(@ptrCast(handle));
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
    watch.native = .{};
    _ = c.DestroyWindow(hwnd);
    live_windows -= 1;
}

/// Test hook: the hidden window receiving this Watch's notifications.
pub fn notificationWindow(watch: *const desktop.Watch) ?*anyopaque {
    return watch.native.hwnd;
}

fn networkChanged(context: ?*anyopaque, _: Hint) callconv(.winapi) void {
    _ = c.PostMessageW(@ptrCast(context), network_message, 0, 0);
}

fn classify(message: c.UINT, wp: c.WPARAM) u32 {
    return switch (message) {
        c.WM_DISPLAYCHANGE, 0x02E0 => bit_monitors, // WM_DPICHANGED
        // ImmersiveColorSet, high contrast, animation and text scale all
        // arrive here; the area string is not parsed, the host re-queries.
        c.WM_SETTINGCHANGE => if (wp == c.SPI_SETWORKAREA) bit_monitors else bit_preferences,
        c.WM_THEMECHANGED, c.WM_DWMCOLORIZATIONCOLORCHANGED, c.WM_SYSCOLORCHANGE => bit_preferences,
        c.WM_POWERBROADCAST => if (wp == c.PBT_APMPOWERSTATUSCHANGE or wp == c.PBT_POWERSETTINGCHANGE) bit_power else 0,
        else => if (message == network_message and network_message != 0) bit_network else 0,
    };
}

fn procedure(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (raw == 0) return c.DefWindowProcW(hwnd, message, wp, lp);
    const watch: *desktop.Watch = @ptrFromInt(@as(usize, @bitCast(raw)));
    if (message == flush_message and flush_message != 0) {
        const bits = watch.native.pending;
        watch.native.pending = 0;
        watch.native.flush_posted = false;
        // The Watch may be stopped or freed inside; do not touch it afterwards.
        desktop.deliver(watch, bits);
        return 0;
    }
    const bits = classify(message, wp) & watch.kinds.bits();
    if (bits != 0) {
        watch.native.pending |= bits;
        if (!watch.native.flush_posted and c.PostMessageW(hwnd, flush_message, 0, 0) != 0) watch.native.flush_posted = true;
    }
    if (message == c.WM_POWERBROADCAST) return 1;
    if (message == network_message and network_message != 0) return 0;
    return c.DefWindowProcW(hwnd, message, wp, lp);
}
