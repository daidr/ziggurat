const std = @import("std");
const core = @import("../root.zig");
const icons = @import("windows_icons.zig");
const text_input = @import("windows_text.zig");
const pointer_press = @import("pointer_press.zig");
const c = @import("ziggurat_c_win32");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Window.0");
const dispatch_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.Dispatch.0");
const wake_message = c.WM_APP + 1;
const interaction_message = c.WM_APP + 2;
/// Asks a focusable popup, after the activation that moved away from it,
/// whether it closes.
const popup_dismiss_message = c.WM_APP + 3;
const popup_shadow_class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.PopupShadow.0");
const identity_property = std.unicode.utf8ToUtf16LeStringLiteral("Ziggurat.NativeIdentity");
var next_native_identity: usize = 1;
var next_interaction: usize = 1;
const NativeDelegate = struct { message: c.UINT, wp: c.WPARAM, lp: c.LPARAM };
const PendingInteraction = struct { serial: usize, command: usize, point: c.LPARAM };
const KeyDispatch = struct { hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, available: bool = true };
const PointerRelease = struct { operation: u64, sequence: u64, identity: usize, preserve_pair: bool };
const PointerDispatch = struct {
    hwnd: c.HWND,
    message: c.UINT,
    wp: c.WPARAM,
    lp: c.LPARAM,
    tick: u32,
    point: c.POINT,
    available: bool = true,
    release: ?PointerRelease = null,
};
const Wait = struct { handle: c.HANDLE = null, task: core.Task = undefined, generation: u64 = 1, retired: bool = false };
pub const AppData = struct { popup_shadow_class: c.ATOM = 0, taskbar_created: c.UINT = 0, taskbar: ?*TaskbarList = null, dispatcher: c.HWND = null, wake_event: c.HANDLE = null, wake_pending: std.atomic.Value(bool) = .init(false), class_icons: icons.Icons = .{}, waits: [16]Wait = @splat(.{}), window_class: c.ATOM = 0, key_dispatch: ?*KeyDispatch = null, pointer_dispatch: ?*PointerDispatch = null, pointer_windows: usize = 0 };
const FullscreenPlacement = struct { style: isize, ex_style: isize, placement: c.WINDOWPLACEMENT };
pub const WindowData = struct { hwnd: c.HWND = null, icons: icons.Icons = .{}, text: text_input.Handler = .{}, fullscreen: bool = false, restoring_placement: bool = false, saved: ?FullscreenPlacement = null, identity: usize = 0, gesture_active: bool = false, gesture_used: bool = false, gesture_point: c.LPARAM = 0, pending_interaction: ?PendingInteraction = null, interaction_handoff: bool = false, native_loop_depth: usize = 0, pointer_operation: pointer_press.Operation = .{}, pointer_counted: bool = false, opacity: f32 = 1, ignore_pointer: bool = false, skip_taskbar: bool = false };
var active_app: std.atomic.Value(bool) = .init(false);

pub fn init(app: *core.App) !void {
    // One STA and one dispatcher per App. Multiple simultaneous Apps are unsupported.
    if (active_app.swap(true, .acq_rel)) return error.AppAlreadyExists;
    errdefer active_app.store(false, .release);
    const hr = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    if (hr < 0) {
        app.captureNativeFailure(.hresult, @bitCast(hr));
        return error.ComInitializationFailed;
    }
    errdefer c.CoUninitialize();
    app.native.wake_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
    if (app.native.wake_event == null) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.CreateWakeEventFailed;
    }
    errdefer _ = c.CloseHandle(app.native.wake_event);
    // Zero when unavailable: then a restarted shell simply re-adds skipped tabs.
    app.native.taskbar_created = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"));
    _ = c.SetProcessDpiAwarenessContext(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));
    const instance = c.GetModuleHandleW(null);
    app.native.class_icons = loadIcons(app, c.GetDpiForSystem()) catch |err| return err;
    errdefer app.native.class_icons.deinit();
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.hInstance = instance;
    wc.hIcon = app.native.class_icons.large;
    wc.hIconSm = app.native.class_icons.small;
    wc.lpfnWndProc = windowProc;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    wc.lpszClassName = class_name;
    app.native.window_class = c.RegisterClassExW(&wc);
    if (app.native.window_class == 0) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.RegisterClassFailed;
    }
    errdefer _ = c.UnregisterClassW(class_name, instance);
    wc.lpfnWndProc = dispatchProc;
    wc.lpszClassName = dispatch_name;
    wc.hIcon = null;
    wc.hIconSm = null;
    if (c.RegisterClassExW(&wc) == 0) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.RegisterClassFailed;
    }
    errdefer _ = c.UnregisterClassW(dispatch_name, instance);
    app.native.dispatcher = c.CreateWindowExW(0, dispatch_name, null, 0, 0, 0, 0, 0, null, null, instance, app);
    if (app.native.dispatcher == null) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.CreateDispatcherFailed;
    }
}

pub fn deinit(app: *core.App) void {
    if (app.native.taskbar) |list| _ = list.vtable.release(list);
    app.native.taskbar = null;
    _ = c.DestroyWindow(app.native.dispatcher);
    _ = c.UnregisterClassW(dispatch_name, c.GetModuleHandleW(null));
    _ = c.UnregisterClassW(class_name, c.GetModuleHandleW(null));
    if (app.native.popup_shadow_class != 0) _ = c.UnregisterClassW(popup_shadow_class_name, c.GetModuleHandleW(null));
    app.native.popup_shadow_class = 0;
    app.native.class_icons.deinit();
    _ = c.CloseHandle(app.native.wake_event);
    c.CoUninitialize();
    active_app.store(false, .release);
}

fn loadIcons(app: *core.App, dpi: u32) !icons.Icons {
    if (app.icon_policy == .disabled) return .{};
    return icons.Icons.load(c.GetModuleHandleW(null), dpi) catch |err| {
        if (err == error.IconResourceMissing and app.icon_policy == .automatic) return .{};
        app.captureNativeFailure(.win32, c.GetLastError());
        return err;
    };
}

pub fn create(window: *core.WindowRecord, options: core.WindowOptions) !void {
    const app = window.window.app;
    if (options.native_pointer_clicks) {
        if (app.native.pointer_windows == std.math.maxInt(usize)) return error.IdExhausted;
        app.native.pointer_windows += 1;
        window.native.pointer_counted = true;
    }
    errdefer uncountPointer(window);
    if (next_native_identity == std.math.maxInt(usize)) return error.IdExhausted;
    window.native.identity = next_native_identity;
    next_native_identity += 1;
    const title = try std.unicode.utf8ToUtf16LeAllocZ(app.allocator, options.title);
    defer app.allocator.free(title);
    if (window.phase != .creating or app.phase == .stopping or app.phase == .stopped) return error.CreateWindowFailed;
    const dpi = c.GetDpiForSystem();
    window.native.icons = try loadIcons(app, dpi);
    errdefer window.native.icons.deinit();
    if (window.phase != .creating or app.phase == .stopping or app.phase == .stopped) return error.CreateWindowFailed;
    const scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = @intFromFloat(@as(f32, @floatFromInt(options.width)) * scale), .bottom = @intFromFloat(@as(f32, @floatFromInt(options.height)) * scale) };
    var native_style: u32 = if (options.decoration == .system) c.WS_OVERLAPPEDWINDOW else c.WS_POPUP | c.WS_SYSMENU | c.WS_MINIMIZEBOX | c.WS_THICKFRAME | c.WS_MAXIMIZEBOX;
    if (!options.resizable) native_style &= ~@as(u32, c.WS_THICKFRAME | c.WS_MAXIMIZEBOX);
    if (options.decoration == .system and c.AdjustWindowRectExForDpi(&rect, native_style, c.FALSE, 0, dpi) == 0) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.AdjustWindowFailed;
    }
    const owner = if (window.owner_record) |parent| parent.native.hwnd else null;
    var ex_style: u32 = 0;
    var class: [*:0]const u16 = class_name;
    var origin: c_int = c.CW_USEDEFAULT;
    if (options.popup) |role| {
        // Owned popups stay above their owner; the tool-window style keeps
        // every popup out of the taskbar and the task switcher.
        native_style = c.WS_POPUP | c.WS_CLIPCHILDREN;
        ex_style = c.WS_EX_TOOLWINDOW;
        if (role.topmost) ex_style |= c.WS_EX_TOPMOST;
        if (!role.focusable) ex_style |= c.WS_EX_NOACTIVATE;
        if (role.shadow) class = try popupShadowClass(app);
        // Popups are placed before they show; CW_USEDEFAULT means 0 here.
        origin = 0;
    }
    window.native.hwnd = c.CreateWindowExW(ex_style, class, title.ptr, native_style, origin, origin, rect.right - rect.left, rect.bottom - rect.top, owner, null, c.GetModuleHandleW(null), window);
    if (window.native.hwnd == null) {
        if (app.native_failure == null) app.captureNativeFailure(.win32, c.GetLastError());
        return error.CreateWindowFailed;
    }
    window.native.icons.apply(window.native.hwnd);
    if (options.popup) |role| if (role.shadow) {
        // Windows 11 rounds, outlines and shades it as it does its menus;
        // earlier versions ignore the attribute and keep the class shadow.
        const round: u32 = dwm_corner_round;
        _ = DwmSetWindowAttribute(window.native.hwnd, dwm_window_corner_preference, &round, @sizeOf(u32));
    };
    if (options.text_input_mode != .system) {
        errdefer _ = c.DestroyWindow(window.native.hwnd);
        _ = try setTextInputMode(window, options.text_input_mode);
    }
}
const dwm_window_corner_preference = 33;
const dwm_corner_round = 2;
/// The class of popups with the drop shadow of menus and tooltips, which only
/// a class style gives. Registered once, beside the ordinary window class.
fn popupShadowClass(app: *core.App) ![*:0]const u16 {
    if (app.native.popup_shadow_class == 0) {
        var wc = std.mem.zeroes(c.WNDCLASSEXW);
        wc.cbSize = @sizeOf(c.WNDCLASSEXW);
        wc.style = c.CS_DROPSHADOW;
        wc.hInstance = c.GetModuleHandleW(null);
        wc.lpfnWndProc = windowProc;
        wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
        wc.lpszClassName = popup_shadow_class_name;
        app.native.popup_shadow_class = c.RegisterClassExW(&wc);
        if (app.native.popup_shadow_class == 0) {
            app.captureNativeFailure(.win32, c.GetLastError());
            return error.RegisterClassFailed;
        }
    }
    return popup_shadow_class_name;
}
fn quietPopup(window: *const core.WindowRecord) bool {
    const role = window.options.popup orelse return false;
    return !role.focusable;
}
/// Whether a visible focusable popup owned by `window`, directly or through
/// other windows, shows: a press that activates `window` then only dismisses
/// it, as a press outside a menu does, rather than also reaching what is
/// under the pointer, which may be what opened it.
fn ownsFocusablePopup(window: *core.WindowRecord) bool {
    var cursor = window.window.app.first;
    while (cursor) |record| : (cursor = record.next) {
        const role = record.options.popup orelse continue;
        if (!role.focusable or record.phase != .open or record.native.hwnd == null or c.IsWindowVisible(record.native.hwnd) == 0) continue;
        var owner = record.owner_record;
        while (owner) |item| : (owner = item.owner_record) if (item == window) return true;
    }
    return false;
}
/// Whether the window being activated is `popup` or one of the windows it owns.
fn popupFamily(popup: *core.WindowRecord, activated: c.HWND) bool {
    if (activated == null) return false;
    if (c.GetPropW(activated, identity_property) == null) return false;
    const address = c.GetWindowLongPtrW(activated, c.GWLP_USERDATA);
    if (address == 0) return false;
    var cursor: ?*core.WindowRecord = @ptrFromInt(@as(usize, @bitCast(address)));
    while (cursor) |record| : (cursor = record.owner_record) if (record == popup) return true;
    return false;
}
fn uncountPointer(window: *core.WindowRecord) void {
    if (!window.native.pointer_counted) return;
    window.native.pointer_counted = false;
    std.debug.assert(window.window.app.native.pointer_windows != 0);
    window.window.app.native.pointer_windows -= 1;
}
pub fn pointerOperation(window: *const core.WindowRecord) u64 {
    return window.native.pointer_operation.value;
}
pub fn advancePointerOperation(window: *core.WindowRecord) u64 {
    return window.native.pointer_operation.advance();
}

pub fn run(app: *core.App) !void {
    var message: c.MSG = undefined;
    while (true) {
        var handles: [17]c.HANDLE = undefined;
        var tokens: [16]core.NativeWaitToken = undefined;
        handles[0] = app.native.wake_event;
        var count: u32 = 1;
        for (app.native.waits, 0..) |wait, index| if (wait.handle != null) {
            handles[count] = wait.handle;
            tokens[count - 1] = .{ .index = @intCast(index), .generation = wait.generation };
            count += 1;
        };
        const result = c.MsgWaitForMultipleObjectsEx(count, &handles, c.INFINITE, c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE);
        if (result == c.WAIT_FAILED) {
            app.captureNativeFailure(.win32, c.GetLastError());
            return error.EventLoopFailed;
        }
        if (result == c.WAIT_OBJECT_0) consumeWake(app);
        if (result > c.WAIT_OBJECT_0 and result < c.WAIT_OBJECT_0 + count) {
            const token = tokens[result - c.WAIT_OBJECT_0 - 1];
            fireWait(app, token);
        }
        // A continuously signaled task wake must not starve higher-index events.
        // Poll only this turn's bounded snapshot after a real wake, never at idle.
        for (tokens[0 .. count - 1]) |token| {
            if (app.phase != .running) break;
            const wait = &app.native.waits[token.index];
            if (wait.handle != null and wait.generation == token.generation and c.WaitForSingleObject(wait.handle, 0) == c.WAIT_OBJECT_0) fireWait(app, token);
        }
        // Posted task wakes must not outrank input, paint or timers forever.
        // These queues have explicit turns before the ordinary posted messages.
        for (0..32) |_| {
            if (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE | c.PM_QS_INPUT) == 0) break;
            if (!dispatchMessage(app, &message)) return;
        }
        for (0..8) |_| {
            if (c.PeekMessageW(&message, null, c.WM_PAINT, c.WM_PAINT, c.PM_REMOVE) == 0) break;
            if (!dispatchMessage(app, &message)) return;
        }
        for (0..8) |_| {
            if (c.PeekMessageW(&message, null, c.WM_TIMER, c.WM_TIMER, c.PM_REMOVE) == 0) break;
            if (!dispatchMessage(app, &message)) return;
        }
        // Always give queued native input a turn, even with continuous task producers.
        for (0..256) |_| {
            if (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) == 0) break;
            if (!dispatchMessage(app, &message)) return;
        }
    }
}
fn fireWait(app: *core.App, token: core.NativeWaitToken) void {
    if (app.phase != .running) return;
    const task = app.native.waits[token.index].task;
    if (unwatchNative(app, token)) app.dispatchNativeTask(task);
}
pub fn watchNative(app: *core.App, handle_value: *anyopaque, task: core.Task) !core.NativeWaitToken {
    for (app.native.waits) |wait| if (wait.handle == handle_value) return error.AlreadyWatched;
    for (&app.native.waits, 0..) |*wait, index| {
        if (wait.handle == null and !wait.retired) {
            wait.handle = handle_value;
            wait.task = task;
            return .{ .index = @intCast(index), .generation = wait.generation };
        }
    }
    return error.TooManyWaitables;
}
pub fn unwatchNative(app: *core.App, token: core.NativeWaitToken) bool {
    if (token.index >= app.native.waits.len) return false;
    const wait = &app.native.waits[token.index];
    if (wait.handle == null or wait.generation != token.generation) return false;
    wait.handle = null;
    if (wait.generation == std.math.maxInt(u64)) wait.retired = true else wait.generation += 1;
    return true;
}
pub fn cancelAllNativeWaits(app: *core.App) void {
    for (&app.native.waits, 0..) |*wait, index| {
        if (wait.handle != null) {
            _ = unwatchNative(app, .{ .index = @intCast(index), .generation = wait.generation });
            wait.task = undefined;
        }
    }
}
fn dispatchMessage(app: *core.App, message: *c.MSG) bool {
    if (message.message == c.WM_QUIT) return false;
    // The main loop already dispatches from the kernel event once per turn.
    // The window procedure remains usable by native resize/modal loops.
    if (message.hwnd == app.native.dispatcher and message.message == wake_message) return true;
    if (message.message == c.WM_KEYDOWN or message.message == c.WM_SYSKEYDOWN) {
        if (keyRecord(app, message.hwnd)) |record| {
            const scope = record.enterNative();
            if (nativeKeyInput(record, message.hwnd, message.wParam, message.lParam)) {
                scope.end();
                return true;
            }
            if (record.native.text.composing or !superDown()) _ = c.TranslateMessage(message);
            const valid = record.phase == .open and record.native.hwnd == message.hwnd;
            const identity = record.native.identity;
            scope.end();
            if (!valid or !nativeIdentity(message.hwnd, identity)) return true;
            var marker: KeyDispatch = .{ .hwnd = message.hwnd, .message = message.message, .wp = message.wParam, .lp = message.lParam };
            const previous = app.native.key_dispatch;
            app.native.key_dispatch = &marker;
            defer app.native.key_dispatch = previous;
            _ = c.DispatchMessageW(message);
            return true;
        }
    }
    if (app.native.pointer_windows != 0 and pointerEnvelopeMessage(message.message)) {
        dispatchPointer(app, message);
        return true;
    }
    _ = c.TranslateMessage(message);
    _ = c.DispatchMessageW(message);
    return true;
}
fn pointerEnvelopeMessage(message: c.UINT) bool {
    return buttonPhase(message) != null or message == c.WM_MOUSEMOVE or message == c.WM_NCMOUSEMOVE;
}
noinline fn dispatchPointer(app: *core.App, message: *const c.MSG) void {
    var marker: PointerDispatch = .{ .hwnd = message.hwnd, .message = message.message, .wp = message.wParam, .lp = message.lParam, .tick = message.time, .point = message.pt };
    const previous = app.native.pointer_dispatch;
    app.native.pointer_dispatch = &marker;
    defer app.native.pointer_dispatch = previous;
    _ = c.DispatchMessageW(message);
}
fn takePointerEnvelope(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) ?*const PointerDispatch {
    const marker = window.window.app.native.pointer_dispatch orelse return null;
    if (!marker.available or marker.hwnd != hwnd or marker.message != message or marker.wp != wp or marker.lp != lp) return null;
    marker.available = false;
    return marker;
}
fn buttonPhase(message: c.UINT) ?core.PointerPhase {
    return switch (message) {
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN, c.WM_XBUTTONDOWN, c.WM_NCLBUTTONDOWN, c.WM_NCRBUTTONDOWN, c.WM_NCMBUTTONDOWN, c.WM_NCXBUTTONDOWN, c.WM_LBUTTONDBLCLK, c.WM_RBUTTONDBLCLK, c.WM_MBUTTONDBLCLK, c.WM_XBUTTONDBLCLK, c.WM_NCLBUTTONDBLCLK, c.WM_NCRBUTTONDBLCLK, c.WM_NCMBUTTONDBLCLK, c.WM_NCXBUTTONDBLCLK => .down,
        c.WM_LBUTTONUP, c.WM_RBUTTONUP, c.WM_MBUTTONUP, c.WM_XBUTTONUP, c.WM_NCLBUTTONUP, c.WM_NCRBUTTONUP, c.WM_NCMBUTTONUP, c.WM_NCXBUTTONUP => .up,
        else => null,
    };
}
fn nativeButton(message: c.UINT, wp: c.WPARAM) ?core.PointerButton {
    return switch (message) {
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK, c.WM_LBUTTONUP, c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK, c.WM_NCLBUTTONUP => .primary,
        c.WM_RBUTTONDOWN, c.WM_RBUTTONDBLCLK, c.WM_RBUTTONUP, c.WM_NCRBUTTONDOWN, c.WM_NCRBUTTONDBLCLK, c.WM_NCRBUTTONUP => .secondary,
        c.WM_MBUTTONDOWN, c.WM_MBUTTONDBLCLK, c.WM_MBUTTONUP, c.WM_NCMBUTTONDOWN, c.WM_NCMBUTTONDBLCLK, c.WM_NCMBUTTONUP => .middle,
        c.WM_XBUTTONDOWN, c.WM_XBUTTONDBLCLK, c.WM_XBUTTONUP, c.WM_NCXBUTTONDOWN, c.WM_NCXBUTTONDBLCLK, c.WM_NCXBUTTONUP => switch ((wp >> 16) & 0xffff) {
            c.XBUTTON1 => .back,
            c.XBUTTON2 => .forward,
            else => null,
        },
        else => null,
    };
}
fn pointerModifiers(wp: c.WPARAM, message: c.UINT) core.KeyModifiers {
    const client = message >= c.WM_MOUSEFIRST and message <= c.WM_MOUSELAST;
    return .{ .shift = if (client) wp & c.MK_SHIFT != 0 else c.GetKeyState(c.VK_SHIFT) < 0, .control = if (client) wp & c.MK_CONTROL != 0 else c.GetKeyState(c.VK_CONTROL) < 0, .alt = c.GetKeyState(c.VK_MENU) < 0, .super = superDown() };
}
noinline fn pointerButtonMessage(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, delegation: *?NativeDelegate, operation: u64, phase: core.PointerPhase, capture_owned: bool) c.LRESULT {
    // Copy the one-use queue envelope before any settings/native callback.
    const envelope = takePointerEnvelope(window, hwnd, message, wp, lp);
    const tick = if (envelope) |value| value.tick else 0;
    const sample = if (envelope) |value| value.point else c.POINT{ .x = 0, .y = 0 };
    const identity = window.native.identity;
    const modifiers = pointerModifiers(wp, message);
    const button = nativeButton(message, wp);
    var timing: ?core.PointerClickTiming = null;
    if (phase == .down and envelope != null) {
        const interval = c.GetDoubleClickTime();
        const width = c.GetSystemMetrics(c.SM_CXDOUBLECLK);
        const height = c.GetSystemMetrics(c.SM_CYDOUBLECLK);
        if (interval != 0 and interval < 0x80000000 and width > 0 and height > 0) {
            const x: f64 = @floatFromInt(@divTrunc(width, 2));
            const y: f64 = @floatFromInt(@divTrunc(height, 2));
            timing = .{ .tick_ms = tick, .position = .{ .x = @floatFromInt(sample.x), .y = @floatFromInt(sample.y), .domain = 0 }, .policy = .{ .interval_ms = interval, .min_x = -x, .max_x = @as(f64, @floatFromInt(width)) - x, .min_y = -y, .max_y = @as(f64, @floatFromInt(height)) - y } };
        }
    }
    // Settings and native key-state reads are foreign calls. History may only
    // observe the original operation after the full native/permission guard.
    if (!sameWindow(window, hwnd) or window.native.identity != identity or !window.pointerCurrent(operation) or c.IsWindowEnabled(hwnd) == 0) {
        window.pointerRevoke(operation, false);
        return 0;
    }
    const transition = if (phase == .down) window.pointerBeginDown(operation, button, timing) else window.pointerBeginUp(operation, button);
    const sequence = if (transition) |value| value.press.sequence else 0;
    var delivered = false;
    const result = windowMessageBody(window, hwnd, message, wp, lp, delegation, operation, sequence, modifiers, &delivered, .ordinary, capture_owned);
    if (sameWindow(window, hwnd) and window.native.identity == identity and window.pointerCurrent(operation) and c.IsWindowEnabled(hwnd) != 0) {
        _ = window.pointerFinish(operation, sequence, button, phase, if (delivered) .delivered else .consumed);
    }
    return result;
}
noinline fn pointerMotionMessage(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) void {
    const operation = pointerOperation(window);
    const envelope = takePointerEnvelope(window, hwnd, message, wp, lp);
    const sample: ?core.ClickSample = if (envelope) |value| .{ .x = @floatFromInt(value.point.x), .y = @floatFromInt(value.point.y), .domain = 0 } else null;
    window.pointerMotion(operation, sample);
}
fn keyRecord(app: *core.App, hwnd: c.HWND) ?*core.WindowRecord {
    if (hwnd == null or c.GetClassLongPtrW(hwnd, c.GCW_ATOM) != app.native.window_class or c.GetWindowThreadProcessId(hwnd, null) != c.GetCurrentThreadId()) return null;
    const address = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (address == 0) return null;
    const record: *core.WindowRecord = @ptrFromInt(@as(usize, @bitCast(address)));
    return if (record.window.app == app and record.native.hwnd == hwnd) record else null;
}
fn nativeKeyInput(window: *core.WindowRecord, hwnd: c.HWND, wp: c.WPARAM, lp: c.LPARAM) bool {
    if (!window.inputAllowed() or c.IsWindowEnabled(hwnd) == 0) return true;
    if (window.native.text.composing) return false;
    const content = window.content orelse return false;
    if (content.key_input == null) return false;
    const control = c.GetKeyState(c.VK_CONTROL) < 0;
    // Layout-generated AltGr text uses Right Alt plus a synthetic Control.
    if (control and c.GetKeyState(c.VK_RMENU) < 0) return false;
    return window.keyInput(.{ .key = keyCode(wp), .modifiers = keyModifiers(), .repeat = @as(usize, @bitCast(lp)) & (1 << 30) != 0, .physical = physicalKey(lp) });
}
fn keyModifiers() core.KeyModifiers {
    return .{ .shift = c.GetKeyState(c.VK_SHIFT) < 0, .control = c.GetKeyState(c.VK_CONTROL) < 0, .alt = c.GetKeyState(c.VK_MENU) < 0, .super = superDown() };
}
/// The key's position from the scan code and extended flag of lParam.
fn physicalKey(lp: c.LPARAM) core.KeyCode {
    const bits = @as(usize, @bitCast(lp));
    return core.physical_keys.fromScanCode(@intCast((bits >> 16) & 0xff), bits & (1 << 24) != 0);
}
/// WM_KEYUP and WM_SYSKEYUP reach content that asks for releases; native
/// handling, such as Alt opening the window menu, continues after.
fn nativeKeyRelease(window: *core.WindowRecord, hwnd: c.HWND, wp: c.WPARAM, lp: c.LPARAM) void {
    if (!window.inputAllowed() or c.IsWindowEnabled(hwnd) == 0) return;
    const content = window.content orelse return;
    if (content.key_release == null) return;
    window.keyRelease(.{ .key = keyCode(wp), .modifiers = keyModifiers(), .physical = physicalKey(lp) });
}
fn superDown() bool {
    return c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0;
}
fn keyCode(code: usize) core.KeyCode {
    if (code >= 'A' and code <= 'Z') return @fromBackingInt(@intCast(@backingInt(core.KeyCode.a) + code - 'A'));
    if (code >= '0' and code <= '9') return @fromBackingInt(@intCast(@backingInt(core.KeyCode.digit0) + code - '0'));
    if (code >= c.VK_F1 and code <= c.VK_F24) return @fromBackingInt(@intCast(@backingInt(core.KeyCode.f1) + code - c.VK_F1));
    if (code >= c.VK_NUMPAD0 and code <= c.VK_NUMPAD9) return @fromBackingInt(@intCast(@backingInt(core.KeyCode.numpad0) + code - c.VK_NUMPAD0));
    return switch (code) {
        c.VK_TAB => .tab,
        c.VK_RETURN => .enter,
        c.VK_SPACE => .space,
        c.VK_ESCAPE => .escape,
        c.VK_LEFT => .left,
        c.VK_RIGHT => .right,
        c.VK_UP => .up,
        c.VK_DOWN => .down,
        c.VK_HOME => .home,
        c.VK_END => .end,
        c.VK_PRIOR => .page_up,
        c.VK_NEXT => .page_down,
        c.VK_INSERT => .insert,
        c.VK_DELETE => .delete,
        c.VK_BACK => .backspace,
        c.VK_CAPITAL => .caps_lock,
        c.VK_NUMLOCK => .num_lock,
        c.VK_SCROLL => .scroll_lock,
        c.VK_SNAPSHOT => .print_screen,
        c.VK_PAUSE => .pause,
        c.VK_SHIFT, c.VK_LSHIFT, c.VK_RSHIFT => .shift,
        c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL => .control,
        c.VK_MENU, c.VK_LMENU, c.VK_RMENU => .alt,
        c.VK_LWIN, c.VK_RWIN => .super,
        c.VK_APPS => .context_menu,
        c.VK_DECIMAL => .decimal,
        c.VK_ADD => .add,
        c.VK_SUBTRACT => .subtract,
        c.VK_MULTIPLY => .multiply,
        c.VK_DIVIDE => .divide,
        c.VK_MEDIA_PLAY_PAUSE => .media_play_pause,
        c.VK_MEDIA_STOP => .media_stop,
        c.VK_MEDIA_NEXT_TRACK => .media_next,
        c.VK_MEDIA_PREV_TRACK => .media_previous,
        c.VK_VOLUME_MUTE => .volume_mute,
        c.VK_VOLUME_DOWN => .volume_down,
        c.VK_VOLUME_UP => .volume_up,
        c.VK_BROWSER_BACK => .browser_back,
        c.VK_BROWSER_FORWARD => .browser_forward,
        c.VK_BROWSER_REFRESH => .browser_refresh,
        c.VK_BROWSER_STOP => .browser_stop,
        c.VK_BROWSER_SEARCH => .browser_search,
        c.VK_BROWSER_FAVORITES => .browser_favorites,
        c.VK_BROWSER_HOME => .browser_home,
        else => switch (c.MapVirtualKeyExW(@intCast(code), c.MAPVK_VK_TO_CHAR, c.GetKeyboardLayout(0)) & 0x7fffffff) {
            '-' => .minus,
            '=' => .equal,
            '[' => .left_bracket,
            ']' => .right_bracket,
            '\\' => .backslash,
            ';' => .semicolon,
            '\'' => .apostrophe,
            '`' => .grave,
            ',' => .comma,
            '.' => .period,
            '/' => .slash,
            else => .unknown,
        },
    };
}
pub fn wake(app: *core.App) void {
    if (!app.native.wake_pending.swap(true, .acq_rel)) {
        // Kernel wake remains available if the native message queue reaches its quota.
        if (c.SetEvent(app.native.wake_event) == 0) @panic("UI wake event is invalid; App must outlive its producers");
        _ = c.PostMessageW(app.native.dispatcher, wake_message, 0, 0);
    }
}
fn consumeWake(app: *core.App) void {
    // Reset before publishing the empty wake flag; producers then either join this
    // dispatch or signal a fresh event. Reversing these operations can lose a wake.
    _ = c.ResetEvent(app.native.wake_event);
    app.native.wake_pending.store(false, .release);
    app.dispatch() catch |err| std.log.err("window destruction: {s} (native code {d})", .{ @errorName(err), app.last_native_error });
}
pub fn quit(app: *core.App) void {
    // A native move/size loop must release capture before the outer loop can
    // reach Stop and deferred destruction. Other hosts retain their capture.
    const capture = c.GetCapture();
    const owns_capture = capture != null and keyRecord(app, c.GetAncestor(capture, c.GA_ROOT)) != null;
    // ReleaseCapture can reenter; do not retain a record across this call.
    if (owns_capture) _ = c.ReleaseCapture();
    var cursor = app.first;
    while (cursor) |record| : (cursor = record.next) {
        if (record.native.hwnd != null) _ = c.PostMessageW(record.native.hwnd, c.WM_CANCELMODE, 0, 0);
    }
    c.PostQuitMessage(0);
}
pub fn cleanupSafe() bool {
    const flags = c.InSendMessageEx(null);
    return flags & c.ISMEX_SEND == 0 or flags & c.ISMEX_REPLIED != 0;
}
pub fn show(window: *core.WindowRecord) void {
    if (quietPopup(window)) {
        _ = c.ShowWindow(window.native.hwnd, c.SW_SHOWNOACTIVATE);
        return;
    }
    _ = c.ShowWindow(window.native.hwnd, c.SW_SHOW);
    // A focusable popup takes the keyboard as it shows, as a menu does.
    if (window.options.popup != null) _ = c.SetForegroundWindow(window.native.hwnd);
}
pub fn perform(window: *core.WindowRecord, action: core.WindowAction) !void {
    const hwnd = window.native.hwnd;
    if ((action == .show or action == .focus) and window.options.popup != null) {
        // A quiet popup never takes the keyboard; focusing it only shows it.
        if (action == .show or quietPopup(window)) return show(window);
    }
    switch (action) {
        .show => _ = c.ShowWindow(hwnd, c.SW_SHOW),
        .hide => _ = c.ShowWindow(hwnd, c.SW_HIDE),
        .minimize => _ = c.ShowWindow(hwnd, c.SW_MINIMIZE),
        .maximize => _ = c.ShowWindow(hwnd, c.SW_MAXIMIZE),
        .restore => _ = c.ShowWindow(hwnd, c.SW_RESTORE),
        .enable => _ = c.EnableWindow(hwnd, c.TRUE),
        .disable => _ = c.EnableWindow(hwnd, c.FALSE),
        .focus => {
            const foreground = c.SetForegroundWindow(hwnd) != 0;
            if (!sameWindow(window, hwnd)) return error.Closed;
            _ = c.SetFocus(hwnd);
            if (!sameWindow(window, hwnd)) return error.Closed;
            if (!foreground or c.GetFocus() != hwnd) return error.FocusDenied;
        },
    }
}
pub fn state(window: *core.WindowRecord) core.WindowState {
    const hwnd = window.native.hwnd;
    const topmost = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE) & c.WS_EX_TOPMOST != 0;
    return .{ .visible = c.IsWindowVisible(hwnd) != 0, .minimized = c.IsIconic(hwnd) != 0, .maximized = c.IsZoomed(hwnd) != 0, .focused = c.GetFocus() == hwnd, .enabled = c.IsWindowEnabled(hwnd) != 0, .fullscreen = window.native.fullscreen, .fullscreen_requested = window.native.fullscreen, .always_on_top = topmost, .always_on_top_requested = topmost };
}
pub fn capabilities(window: *core.WindowRecord) core.WindowCapabilities {
    return .{ .client_position = true, .fullscreen = true, .always_on_top = true, .owned_windows = true, .modal_windows = true, .custom_decoration = true, .native_move_resize = true, .system_menu = true, .backdrop_material = window.options.decoration == .system and systemBackdropAvailable(), .opacity = true, .ignore_pointer = true, .content_protection = true, .attention = true, .skip_taskbar = true, .window_buttons = true };
}
/// Style bits owned by WindowTraits. A window without resize has no maximize
/// box, as at creation.
fn traitStyle(current: isize, traits: core.WindowTraits) isize {
    const owned: isize = c.WS_THICKFRAME | c.WS_MINIMIZEBOX | c.WS_MAXIMIZEBOX;
    var bits: isize = 0;
    if (traits.resizable) bits |= c.WS_THICKFRAME;
    if (traits.minimizable) bits |= c.WS_MINIMIZEBOX;
    if (traits.resizable and traits.maximizable) bits |= c.WS_MAXIMIZEBOX;
    return (current & ~owned) | bits;
}
pub fn setTraits(window: *core.WindowRecord, traits: core.WindowTraits) !void {
    const hwnd = window.native.hwnd;
    if (window.native.saved) |*saved| {
        // Fullscreen strips the frame; leaving it restores these bits.
        saved.style = traitStyle(saved.style, traits);
    } else {
        const current = c.GetWindowLongPtrW(hwnd, c.GWL_STYLE);
        const next = traitStyle(current, traits);
        if (next != current) {
            if (!writeStyle(hwnd, c.GWL_STYLE, next)) return updateFailure(window);
            if (!sameWindow(window, hwnd)) return error.Closed;
            if (c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
            if (!sameWindow(window, hwnd)) return error.Closed;
        }
    }
    // Graying SC_CLOSE disables the close button and Alt+F4 as well.
    if (c.GetSystemMenu(hwnd, c.FALSE)) |menu| _ = c.EnableMenuItem(menu, c.SC_CLOSE, @as(c.UINT, c.MF_BYCOMMAND) | @as(c.UINT, if (traits.closable) c.MF_ENABLED else c.MF_GRAYED));
    if (!sameWindow(window, hwnd)) return error.Closed;
}
/// Layered while translucent or transparent to the pointer.
fn applyLayered(window: *core.WindowRecord, opacity: f32, ignore_pointer: bool) !void {
    const hwnd = window.native.hwnd;
    const layered = opacity < 1 or ignore_pointer;
    const current = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    var next = current & ~@as(isize, c.WS_EX_TRANSPARENT);
    if (ignore_pointer) next |= c.WS_EX_TRANSPARENT;
    if (layered) next |= c.WS_EX_LAYERED else next &= ~@as(isize, c.WS_EX_LAYERED);
    if (next != current) {
        if (!writeStyle(hwnd, c.GWL_EXSTYLE, next)) return updateFailure(window);
        if (!sameWindow(window, hwnd)) return error.Closed;
    }
    if (layered and c.SetLayeredWindowAttributes(hwnd, 0, @intFromFloat(@round(opacity * 255)), c.LWA_ALPHA) == 0) return updateFailure(window);
    if (window.native.saved) |*saved| saved.ex_style = (saved.ex_style & ~@as(isize, c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT)) | (next & (c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT));
}
pub fn setOpacity(window: *core.WindowRecord, value: f32) !void {
    try applyLayered(window, value, window.native.ignore_pointer);
    window.native.opacity = value;
}
pub fn setIgnorePointer(window: *core.WindowRecord, enabled: bool) !void {
    try applyLayered(window, window.native.opacity, enabled);
    window.native.ignore_pointer = enabled;
}
pub fn setContentProtection(window: *core.WindowRecord, enabled: bool) !void {
    const exclude_from_capture = 0x11;
    const monitor_only = 0x01;
    const hwnd = window.native.hwnd;
    if (c.SetWindowDisplayAffinity(hwnd, if (enabled) exclude_from_capture else c.WDA_NONE) != 0) return;
    // Before Windows 10 2004 only WDA_MONITOR exists: the window shows black.
    if (enabled and c.SetWindowDisplayAffinity(hwnd, monitor_only) != 0) return;
    return updateFailure(window);
}
pub fn flashFrame(window: *core.WindowRecord, enabled: bool) !void {
    var info = std.mem.zeroes(c.FLASHWINFO);
    info.cbSize = @sizeOf(c.FLASHWINFO);
    info.hwnd = window.native.hwnd;
    // Until the window comes to the foreground.
    info.dwFlags = if (enabled) c.FLASHW_ALL | c.FLASHW_TIMERNOFG else c.FLASHW_STOP;
    _ = c.FlashWindowEx(&info);
}
pub fn setSkipTaskbar(window: *core.WindowRecord, enabled: bool) !void {
    const list = try taskbarList(window.window.app);
    window.native.skip_taskbar = enabled;
    const result = if (enabled) list.vtable.delete_tab(list, window.native.hwnd) else list.vtable.add_tab(list, window.native.hwnd);
    if (result < 0) {
        window.native.skip_taskbar = !enabled;
        window.window.app.captureNativeFailure(.hresult, @bitCast(result));
        return error.WindowUpdateFailed;
    }
}
/// ITaskbarList, whose header COM macros do not translate.
const TaskbarList = extern struct {
    vtable: *const extern struct {
        query_interface: *const fn (*TaskbarList, *const c.GUID, *?*anyopaque) callconv(.winapi) c.HRESULT,
        add_ref: *const fn (*TaskbarList) callconv(.winapi) c.ULONG,
        release: *const fn (*TaskbarList) callconv(.winapi) c.ULONG,
        hr_init: *const fn (*TaskbarList) callconv(.winapi) c.HRESULT,
        add_tab: *const fn (*TaskbarList, c.HWND) callconv(.winapi) c.HRESULT,
        delete_tab: *const fn (*TaskbarList, c.HWND) callconv(.winapi) c.HRESULT,
        activate_tab: *const fn (*TaskbarList, c.HWND) callconv(.winapi) c.HRESULT,
        set_active_alt: *const fn (*TaskbarList, c.HWND) callconv(.winapi) c.HRESULT,
    },
};
const clsid_taskbar_list: c.GUID = .{ .Data1 = 0x56fdf344, .Data2 = 0xfd6d, .Data3 = 0x11d0, .Data4 = .{ 0x95, 0x8a, 0x00, 0x60, 0x97, 0xc9, 0xa0, 0x90 } };
const iid_taskbar_list: c.GUID = .{ .Data1 = 0x56fdf342, .Data2 = 0xfd6d, .Data3 = 0x11d0, .Data4 = .{ 0x95, 0x8a, 0x00, 0x60, 0x97, 0xc9, 0xa0, 0x90 } };
fn taskbarList(app: *core.App) !*TaskbarList {
    if (app.native.taskbar) |list| return list;
    var object: ?*anyopaque = null;
    var result = c.CoCreateInstance(&clsid_taskbar_list, null, c.CLSCTX_INPROC_SERVER, &iid_taskbar_list, &object);
    if (result < 0 or object == null) {
        app.captureNativeFailure(.hresult, @bitCast(result));
        return error.WindowUpdateFailed;
    }
    const list: *TaskbarList = @ptrCast(@alignCast(object.?));
    result = list.vtable.hr_init(list);
    if (result < 0) {
        _ = list.vtable.release(list);
        app.captureNativeFailure(.hresult, @bitCast(result));
        return error.WindowUpdateFailed;
    }
    app.native.taskbar = list;
    return list;
}
extern "dwmapi" fn DwmSetWindowAttribute(c.HWND, u32, *const anyopaque, u32) callconv(.winapi) c.HRESULT;
const dwm_system_backdrop_type = 38;
/// DWMWA_SYSTEMBACKDROP_TYPE is accepted from Windows 11 build 22621. The
/// version is read once per process; RtlGetVersion is not manifest-shimmed.
fn systemBackdropAvailable() bool {
    const Cache = struct {
        var value: std.atomic.Value(u8) = .init(0);
    };
    const cached = Cache.value.load(.acquire);
    if (cached != 0) return cached == 2;
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    const available = std.os.windows.ntdll.RtlGetVersion(&info) == .SUCCESS and (info.dwMajorVersion > 10 or (info.dwMajorVersion == 10 and info.dwBuildNumber >= 22621));
    Cache.value.store(if (available) 2 else 1, .release);
    return available;
}
pub fn setBackdrop(window: *core.WindowRecord, material: core.WindowBackdrop) !void {
    const hwnd = window.native.hwnd;
    const value: u32 = switch (material) {
        .system => 0,
        .none => 1,
        .mica => 2,
        .acrylic => 3,
        .mica_alt => 4,
    };
    const hr = DwmSetWindowAttribute(hwnd, dwm_system_backdrop_type, &value, @sizeOf(u32));
    if (!sameWindow(window, hwnd)) return error.Closed;
    if (hr < 0) {
        window.window.app.captureNativeFailure(.hresult, @bitCast(hr));
        return error.WindowUpdateFailed;
    }
}
fn nativeIdentity(hwnd: c.HWND, identity: usize) bool {
    return c.IsWindow(hwnd) != 0 and @intFromPtr(c.GetPropW(hwnd, identity_property)) == identity;
}
fn queueInteraction(window: *core.WindowRecord, command: usize, needs_gesture: bool) !void {
    if (needs_gesture and (!window.native.gesture_active or window.native.gesture_used)) return error.InvalidGesture;
    if (window.native.pending_interaction != null or window.native.interaction_handoff or window.native.native_loop_depth != 0) return error.Busy;
    if (next_interaction == std.math.maxInt(usize)) return error.IdExhausted;
    const serial = next_interaction;
    next_interaction += 1;
    const pending: PendingInteraction = .{ .serial = serial, .command = command, .point = if (command == c.SC_KEYMENU) ' ' else window.native.gesture_point };
    if (c.PostMessageW(window.native.hwnd, interaction_message, serial, 0) == 0) return updateFailure(window);
    window.native.pending_interaction = pending;
    if (needs_gesture) window.native.gesture_used = true;
}
pub fn startMove(window: *core.WindowRecord) !void {
    try queueInteraction(window, c.SC_MOVE | c.HTCAPTION, true);
}
pub fn startResize(window: *core.WindowRecord, edge: core.ResizeEdge) !void {
    const direction: usize = switch (edge) {
        .west => c.WMSZ_LEFT,
        .east => c.WMSZ_RIGHT,
        .north => c.WMSZ_TOP,
        .north_west => c.WMSZ_TOPLEFT,
        .north_east => c.WMSZ_TOPRIGHT,
        .south => c.WMSZ_BOTTOM,
        .south_west => c.WMSZ_BOTTOMLEFT,
        .south_east => c.WMSZ_BOTTOMRIGHT,
    };
    try queueInteraction(window, c.SC_SIZE | direction, true);
}
pub fn showSystemMenu(window: *core.WindowRecord) !void {
    try queueInteraction(window, c.SC_KEYMENU, false);
}
pub fn isActive(window: *core.WindowRecord) bool {
    return c.GetActiveWindow() == window.native.hwnd;
}
fn updateFailure(window: *core.WindowRecord) error{WindowUpdateFailed} {
    window.window.app.captureNativeFailure(.win32, c.GetLastError());
    return error.WindowUpdateFailed;
}
fn sameWindow(window: *core.WindowRecord, hwnd: c.HWND) bool {
    return window.native.hwnd == hwnd and window.phase == .open;
}
fn style(hwnd: c.HWND, index: c_int) u32 {
    return @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, index))));
}
fn writeStyle(hwnd: c.HWND, index: c_int, value: isize) bool {
    c.SetLastError(0);
    return c.SetWindowLongPtrW(hwnd, index, value) != 0 or c.GetLastError() == 0;
}
pub fn clientBounds(window: *core.WindowRecord) !core.ClientBounds {
    const hwnd = window.native.hwnd;
    var rect: c.RECT = undefined;
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    if (c.GetClientRect(hwnd, &rect) == 0 or c.ClientToScreen(hwnd, &origin) == 0) return updateFailure(window);
    const dpi = c.GetDpiForWindow(hwnd);
    if (dpi == 0) return error.Closed;
    return .{ .position = .{ .x = origin.x, .y = origin.y }, .width = @intCast(@max(0, c.MulDiv(rect.right - rect.left, 96, @intCast(dpi)))), .height = @intCast(@max(0, c.MulDiv(rect.bottom - rect.top, 96, @intCast(dpi)))) };
}
pub fn contentSize(window: *core.WindowRecord) !core.Size {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(window.native.hwnd, &rect) == 0) return updateFailure(window);
    const dpi = c.GetDpiForWindow(window.native.hwnd);
    if (dpi == 0) return error.Closed;
    return .{ .width = @intCast(@max(0, rect.right - rect.left)), .height = @intCast(@max(0, rect.bottom - rect.top)), .scale = @as(f32, @floatFromInt(dpi)) / 96 };
}
fn adjustedClient(window: *core.WindowRecord, width: u32, height: u32) !c.RECT {
    const hwnd = window.native.hwnd;
    const dpi = c.GetDpiForWindow(hwnd);
    if (dpi == 0) return error.Closed;
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = c.MulDiv(@intCast(width), @intCast(dpi), 96), .bottom = c.MulDiv(@intCast(height), @intCast(dpi), 96) };
    if (window.options.decoration != .system) {
        if (c.GetMenu(hwnd) != null) rect.top = -c.GetSystemMetricsForDpi(c.SM_CYMENU, dpi);
        return rect;
    }
    if (c.AdjustWindowRectExForDpi(&rect, style(hwnd, c.GWL_STYLE), @intFromBool(c.GetMenu(hwnd) != null), style(hwnd, c.GWL_EXSTYLE), dpi) == 0) return updateFailure(window);
    return rect;
}
fn outerPosition(position: core.ScreenPoint, rect: c.RECT) !core.ScreenPoint {
    const x = @as(i64, position.x) + rect.left;
    const y = @as(i64, position.y) + rect.top;
    if (x < std.math.minInt(i32) or y < std.math.minInt(i32) or x + rect.right - rect.left > std.math.maxInt(i32) or y + rect.bottom - rect.top > std.math.maxInt(i32)) return error.InvalidGeometry;
    return .{ .x = @intCast(x), .y = @intCast(y) };
}
pub fn setClientBounds(window: *core.WindowRecord, bounds: core.ClientBounds) !void {
    const hwnd = window.native.hwnd;
    var rect = try adjustedClient(window, bounds.width, bounds.height);
    if (bounds.position) |position| {
        var outer = try outerPosition(position, rect);
        // Moving can synchronously change DPI. Recompute the client size after it.
        if (c.SetWindowPos(hwnd, null, outer.x, outer.y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
        if (!sameWindow(window, hwnd)) return error.Closed;
        rect = try adjustedClient(window, bounds.width, bounds.height);
        outer = try outerPosition(position, rect);
        if (c.SetWindowPos(hwnd, null, outer.x, outer.y, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
    } else {
        if (c.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
    }
    if (!sameWindow(window, hwnd)) return error.Closed;
}
fn monitorRect(hwnd: c.HWND) ?c.RECT {
    var monitor = std.mem.zeroes(c.MONITORINFO);
    monitor.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST), &monitor) == 0) return null;
    return monitor.rcMonitor;
}
fn restorePlacement(window: *core.WindowRecord, hwnd: c.HWND, saved: FullscreenPlacement) bool {
    window.native.restoring_placement = true;
    defer window.native.restoring_placement = false;
    const visible = c.IsWindowVisible(hwnd) != 0;
    const current_style = c.GetWindowLongPtrW(hwnd, c.GWL_STYLE);
    const mutable_style: isize = c.WS_VISIBLE | c.WS_DISABLED;
    const restored_style = (saved.style & ~mutable_style) | (current_style & mutable_style);
    const current_ex = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    const live_ex: isize = c.WS_EX_TOPMOST | c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT;
    const restored_ex = (saved.ex_style & ~live_ex) | (current_ex & live_ex);
    if (!writeStyle(hwnd, c.GWL_STYLE, restored_style)) return false;
    if (!sameWindow(window, hwnd)) return false;
    if (!writeStyle(hwnd, c.GWL_EXSTYLE, restored_ex)) return false;
    if (!sameWindow(window, hwnd)) return false;
    var placement = saved.placement;
    if (!visible) placement.showCmd = c.SW_HIDE;
    if (c.SetWindowPlacement(hwnd, &placement) == 0) return false;
    if (!sameWindow(window, hwnd)) return false;
    return c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0 and sameWindow(window, hwnd);
}
pub fn setFullscreen(window: *core.WindowRecord, enabled: bool) !void {
    if (window.native.fullscreen == enabled) return;
    const hwnd = window.native.hwnd;
    if (enabled) {
        const iconic = c.IsIconic(hwnd) != 0;
        const visible = c.IsWindowVisible(hwnd) != 0;
        if (iconic and !visible) return error.InvalidWindowState;
        const rect = monitorRect(hwnd) orelse return updateFailure(window);
        var placement = std.mem.zeroes(c.WINDOWPLACEMENT);
        placement.length = @sizeOf(c.WINDOWPLACEMENT);
        if (c.GetWindowPlacement(hwnd, &placement) == 0) return updateFailure(window);
        const saved: FullscreenPlacement = .{ .style = c.GetWindowLongPtrW(hwnd, c.GWL_STYLE), .ex_style = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE), .placement = placement };
        window.native.saved = saved;
        window.native.fullscreen = true;
        errdefer {
            const failure = window.window.app.native_failure;
            if (sameWindow(window, hwnd) and restorePlacement(window, hwnd, saved)) {
                window.native.fullscreen = false;
                window.native.saved = null;
            }
            window.window.app.native_failure = failure;
        }
        if (iconic or (visible and c.IsZoomed(hwnd) != 0)) {
            var normal = placement;
            normal.flags &= ~@as(c.UINT, c.WPF_RESTORETOMAXIMIZED);
            normal.showCmd = c.SW_SHOWNOACTIVATE;
            if (c.SetWindowPlacement(hwnd, &normal) == 0) return updateFailure(window);
            if (!sameWindow(window, hwnd)) return error.Closed;
        }
        if (!writeStyle(hwnd, c.GWL_STYLE, saved.style & ~@as(isize, c.WS_CAPTION | c.WS_THICKFRAME | c.WS_MINIMIZE | c.WS_MAXIMIZE))) return updateFailure(window);
        if (!sameWindow(window, hwnd)) return error.Closed;
        if (c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_FRAMECHANGED | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
        if (!sameWindow(window, hwnd)) return error.Closed;
    } else {
        const saved = window.native.saved orelse return error.InvalidWindowState;
        if (!restorePlacement(window, hwnd, saved)) {
            if (!sameWindow(window, hwnd)) return error.Closed;
            return updateFailure(window);
        }
        window.native.fullscreen = false;
        window.native.saved = null;
    }
}
pub fn setAlwaysOnTop(window: *core.WindowRecord, enabled: bool) !void {
    const hwnd = window.native.hwnd;
    const insert_after: c.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, if (enabled) -1 else -2))));
    if (c.SetWindowPos(hwnd, insert_after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE) == 0) return updateFailure(window);
    if (!sameWindow(window, hwnd)) return error.Closed;
}
pub fn setTitle(window: *core.WindowRecord, title: []const u8) !void {
    const app = window.window.app;
    const text = try std.unicode.utf8ToUtf16LeAllocZ(app.allocator, title);
    defer app.allocator.free(text);
    if (c.SetWindowTextW(window.native.hwnd, text.ptr) == 0) {
        app.captureNativeFailure(.win32, c.GetLastError());
        return error.SetTitleFailed;
    }
}
pub fn resize(window: *core.WindowRecord, width: u32, height: u32) !void {
    try setClientBounds(window, .{ .width = width, .height = height });
}
pub fn setTextCaret(window: *core.WindowRecord, rect: core.Rect) !void {
    if (window.text_input_mode == .keyboard_compose) return;
    const scale = size(window.native.hwnd).scale;
    try text_input.setCaret(window.native.hwnd, .{ .x = @intFromFloat(rect.x * scale), .y = @intFromFloat(rect.y * scale), .width = @intFromFloat(rect.width * scale), .height = @intFromFloat(rect.height * scale) });
}
pub fn cancelTextComposition(window: *core.WindowRecord) !void {
    try window.native.text.cancel(window, window.text_input_mode == .system);
}
pub fn cancelTextForMode(window: *core.WindowRecord) !bool {
    const epoch = window.native.text.session_epoch;
    const ingress = window.native.text.message_epoch;
    window.native.text.cancel(window, false) catch |err| {
        if (err == error.Closed) return false;
        return err;
    };
    return !window.native.text.composing and epoch == window.native.text.session_epoch and ingress == window.native.text.message_epoch;
}
pub fn setTextInputMode(window: *core.WindowRecord, mode: core.TextInputMode) !core.TextInputModeResult {
    const hwnd = window.native.hwnd;
    window.native.text.mode_transition = true;
    defer window.native.text.mode_transition = false;
    if (c.ImmAssociateContextEx(hwnd, null, if (mode == .system) @as(c.DWORD, c.IACE_DEFAULT) else 0) == 0) {
        // This API documents BOOL failure, without a GetLastError contract.
        return error.InputAssociationFailed;
    }
    if (window.phase != .open and window.phase != .creating or window.native.hwnd != hwnd) return .superseded;
    window.native.text.system_enabled = mode == .system;
    window.publishTextInputMode(mode);
    return .applied;
}
pub fn invalidate(window: *core.WindowRecord) void {
    if (window.phase != .open) return;
    const hwnd = window.native.hwnd orelse return;
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}
pub fn invalidateRect(window: *core.WindowRecord, bounds: core.Rect) !void {
    const hwnd = window.native.hwnd orelse return error.Closed;
    const client = size(hwnd);
    const scale: f64 = client.scale;
    const left = @floor(@max(0, @as(f64, bounds.x) * scale));
    const top = @floor(@max(0, @as(f64, bounds.y) * scale));
    const right = @ceil(@min(@as(f64, @floatFromInt(client.width)), (@as(f64, bounds.x) + bounds.width) * scale));
    const bottom = @ceil(@min(@as(f64, @floatFromInt(client.height)), (@as(f64, bounds.y) + bounds.height) * scale));
    if (right <= left or bottom <= top) return;
    const rect: c.RECT = .{ .left = @intFromFloat(left), .top = @intFromFloat(top), .right = @intFromFloat(right), .bottom = @intFromFloat(bottom) };
    // InvalidateRect documents a boolean result, not extended last-error data.
    if (c.InvalidateRect(hwnd, &rect, c.FALSE) == 0) return error.InvalidateFailed;
}
pub fn destroy(window: *core.WindowRecord) !void {
    if (c.DestroyWindow(window.native.hwnd) == 0) {
        window.window.app.captureNativeFailure(.win32, c.GetLastError());
        return error.DestroyWindowFailed;
    }
}
pub fn handle(window: *core.WindowRecord) ?*anyopaque {
    return @ptrCast(window.native.hwnd);
}

fn dispatchProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
    }
    if (message == wake_message) {
        const address = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
        if (address != 0) {
            const app: *core.App = @ptrFromInt(@as(usize, @bitCast(address)));
            consumeWake(app);
        }
        return 0;
    }
    if (message == c.WM_NCDESTROY) _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
    return c.DefWindowProcW(hwnd, message, wp, lp);
}

fn size(hwnd: c.HWND) core.Size {
    var rect = std.mem.zeroes(c.RECT);
    if (hwnd == null or c.GetClientRect(hwnd, &rect) == 0) return .{ .width = 0, .height = 0, .scale = 1 };
    const dpi = c.GetDpiForWindow(hwnd);
    return .{ .width = @intCast(@max(0, rect.right)), .height = @intCast(@max(0, rect.bottom)), .scale = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0 };
}

fn point(hwnd: c.HWND, lp: c.LPARAM) core.Point {
    const bits: usize = @bitCast(lp);
    const scale = size(hwnd).scale;
    return .{ .x = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(bits)))))) / scale, .y = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))))) / scale };
}

fn windowProc(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        const record: *core.WindowRecord = @ptrCast(@alignCast(cs.lpCreateParams));
        record.native.hwnd = hwnd;
        if (c.SetPropW(hwnd, identity_property, @ptrFromInt(record.native.identity)) == 0) {
            record.window.app.captureNativeFailure(.win32, c.GetLastError());
            return 0;
        }
    }
    const address = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (address == 0) return c.DefWindowProcW(hwnd, message, wp, lp);
    const window: *core.WindowRecord = @ptrFromInt(@as(usize, @bitCast(address)));
    const scope = window.enterNative();
    var delegation: ?NativeDelegate = null;
    const result = windowMessage(window, hwnd, message, wp, lp, &delegation);
    const identity = window.native.identity;
    const valid = (window.phase == .open or window.phase == .creating) and window.native.hwnd == hwnd;
    scope.end();
    // DefWindowProc can run a native move/size/menu loop. Its callbacks must
    // reach their own safe points, without holding this record or its content.
    if (delegation) |native| {
        if (!valid or !nativeIdentity(hwnd, identity) or c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA) != address) return 0;
        return c.DefWindowProcW(hwnd, native.message, native.wp, native.lp);
    }
    return result;
}
fn delegate(native: *?NativeDelegate, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) c.LRESULT {
    native.* = .{ .message = message, .wp = wp, .lp = lp };
    return 0;
}
fn windowMessage(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, delegation: *?NativeDelegate) c.LRESULT {
    if (buttonPhase(message)) |phase| {
        // Mandatory even when raw timing is disabled or decoration consumes it.
        const operation = advancePointerOperation(window);
        if (operation == std.math.maxInt(u64)) {
            window.pointerRevoke(operation, false);
            return 0;
        }
        // Capture acquired by a Content/service callback belongs to that new
        // action, even when no new button operation was needed to acquire it.
        const capture_owned = message == c.WM_LBUTTONUP and c.GetCapture() == hwnd;
        if (window.pointerEnabled()) return pointerButtonMessage(window, hwnd, message, wp, lp, delegation, operation, phase, capture_owned);
        return windowMessageBody(window, hwnd, message, wp, lp, delegation, operation, 0, if (message >= c.WM_MOUSEFIRST and message <= c.WM_MOUSELAST) pointerModifiers(wp, message) else .{}, null, .ordinary, capture_owned);
    }
    if (message == c.WM_CAPTURECHANGED and (window.pointerEnabled() or window.native.interaction_handoff)) return pointerCaptureMessage(window, hwnd, message, wp, lp, delegation);
    if ((message == c.WM_MOUSEMOVE or message == c.WM_NCMOUSEMOVE) and window.pointerEnabled()) pointerMotionMessage(window, hwnd, message, wp, lp);
    // Activating an unfocused window can synchronously report a self-to-self
    // focus transfer. Capture that fact before services can change focus.
    const focus_echo = message == c.WM_KILLFOCUS and wp == @intFromPtr(hwnd) and c.GetFocus() == hwnd;
    const operation = if (focus_echo) pointerOperation(window) else switch (message) {
        c.WM_KILLFOCUS, c.WM_CAPTURECHANGED, c.WM_CANCELMODE, c.WM_ENTERSIZEMOVE, c.WM_ENTERMENULOOP => window.invalidatePointer(false),
        c.WM_SIZE, c.WM_MOVE, c.WM_DPICHANGED => window.invalidatePointer(true),
        c.WM_SHOWWINDOW, c.WM_ENABLE => if (wp == 0) window.invalidatePointer(false) else pointerOperation(window),
        else => pointerOperation(window),
    };
    return windowMessageBody(window, hwnd, message, wp, lp, delegation, operation, 0, .{}, null, if (focus_echo) .focus_echo else .ordinary, false);
}
noinline fn pointerCaptureMessage(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, delegation: *?NativeDelegate) c.LRESULT {
    if (window.window.app.native.pointer_dispatch) |marker| if (marker.release) |release| {
        // Consume before any business callback. A nested capture change cannot
        // borrow this expected release, nor may an old up release new capture.
        if (marker.hwnd == hwnd and release.identity == window.native.identity) {
            marker.release = null;
            if (lp == 0 and c.GetCapture() == null and window.pointerCurrent(release.operation)) {
                return windowMessageBody(window, hwnd, message, wp, lp, delegation, release.operation, release.sequence, .{}, null, if (release.preserve_pair) .own_up_capture else .ordinary, false);
            }
        }
    };
    const operation = window.invalidatePointer(false);
    return windowMessageBody(window, hwnd, message, wp, lp, delegation, operation, 0, .{}, null, .ordinary, false);
}
noinline fn releasePointerCapture(window: *core.WindowRecord, hwnd: c.HWND, operation: u64, sequence: u64, preserve_pair: bool) bool {
    if (!sameWindow(window, hwnd) or !window.pointerCurrent(operation) or c.GetCapture() != hwnd) return false;
    var marker: PointerDispatch = .{ .hwnd = hwnd, .message = 0, .wp = 0, .lp = 0, .tick = 0, .point = .{ .x = 0, .y = 0 }, .available = false, .release = .{ .operation = operation, .sequence = sequence, .identity = window.native.identity, .preserve_pair = preserve_pair } };
    const previous = window.window.app.native.pointer_dispatch;
    window.window.app.native.pointer_dispatch = &marker;
    defer window.window.app.native.pointer_dispatch = previous;
    _ = c.ReleaseCapture();
    return pointerContinuation(window, hwnd, operation);
}
fn pointerContinuation(window: *core.WindowRecord, hwnd: c.HWND, operation: u64) bool {
    return sameWindow(window, hwnd) and pointerOperation(window) == operation and window.inputAllowed() and c.IsWindowEnabled(hwnd) != 0;
}
const NativeNotification = enum(u8) { ordinary, own_up_capture, focus_echo };
fn windowMessageBody(window: *core.WindowRecord, hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM, delegation: *?NativeDelegate, operation: u64, sequence: u64, modifiers: core.KeyModifiers, delivered: ?*bool, notification: NativeNotification, capture_owned: bool) c.LRESULT {
    if (message == c.WM_ENTERSIZEMOVE or message == c.WM_ENTERMENULOOP) {
        window.native.native_loop_depth += 1;
        // The main loop drops queued wake messages and answers the kernel
        // event instead. A wake still pending when a native loop starts may
        // have had its message dropped this turn; the loop only sees messages.
        const app = window.window.app;
        if (app.native.wake_pending.load(.acquire)) _ = c.PostMessageW(app.native.dispatcher, wake_message, 0, 0);
    }
    if (message == c.WM_EXITSIZEMOVE or message == c.WM_EXITMENULOOP) {
        if (window.native.native_loop_depth != 0) window.native.native_loop_depth -= 1;
    }
    if (message == interaction_message) {
        const pending = window.native.pending_interaction orelse return 0;
        if (pending.serial != wp) return 0;
        window.native.pending_interaction = null;
        if (!window.inputAllowed() or c.IsWindowEnabled(hwnd) == 0 or c.IsWindowVisible(hwnd) == 0 or window.native.fullscreen or c.IsIconic(hwnd) != 0 or window.native.native_loop_depth != 0) return 0;
        if (pending.command & 0xfff0 == c.SC_SIZE and (!window.options.resizable or c.IsZoomed(hwnd) != 0)) return 0;
        if (pending.command & 0xfff0 == c.SC_MOVE and !window.options.movable) return 0;
        window.native.interaction_handoff = true;
        defer window.native.interaction_handoff = false;
        const handoff = window.invalidatePointer(false);
        if (handoff == std.math.maxInt(u64)) return 0;
        if (c.GetCapture() == hwnd and !releasePointerCapture(window, hwnd, handoff, 0, false)) return 0;
        if (!pointerContinuation(window, hwnd, handoff)) return 0;
        return delegate(delegation, c.WM_SYSCOMMAND, pending.command, pending.point);
    }
    if (message == c.WM_NCLBUTTONDOWN or message == c.WM_NCLBUTTONDBLCLK or message == c.WM_NCLBUTTONUP or message == c.WM_NCRBUTTONUP or message == c.WM_SYSCOMMAND) {
        if (!window.inputAllowed() or c.IsWindowEnabled(hwnd) == 0) return 0;
        if (message == c.WM_SYSCOMMAND) {
            const command = wp & 0xfff0;
            if ((command == c.SC_SIZE or command == c.SC_MAXIMIZE) and (!window.options.resizable or window.native.fullscreen)) return 0;
            if (command == c.SC_MAXIMIZE and !window.options.maximizable) return 0;
            if (command == c.SC_MINIMIZE and !window.options.minimizable) return 0;
            if (command == c.SC_CLOSE and !window.options.closable) return 0;
            if (command == c.SC_MOVE and (window.native.fullscreen or !window.options.movable)) return 0;
            if (command == c.SC_RESTORE and window.native.fullscreen) return 0;
        }
    }
    // A restarted shell recreates every button; keep skipped windows off it.
    if (message != 0 and message == window.window.app.native.taskbar_created and window.native.skip_taskbar) {
        if (window.window.app.native.taskbar) |list| _ = list.vtable.delete_tab(list, hwnd);
    }
    var key_filtered = false;
    if (message == c.WM_KEYDOWN or message == c.WM_SYSKEYDOWN) {
        if (window.window.app.native.key_dispatch) |marker| {
            if (marker.available and marker.hwnd == hwnd and marker.message == message and marker.wp == wp and marker.lp == lp) {
                marker.available = false;
                key_filtered = true;
            }
        }
    }
    if ((message == c.WM_KEYDOWN or message == c.WM_SYSKEYDOWN) and !key_filtered and nativeKeyInput(window, hwnd, wp, lp)) return 0;
    if (message == c.WM_KEYUP or message == c.WM_SYSKEYUP) {
        nativeKeyRelease(window, hwnd, wp, lp);
        if (window.phase != .open or window.native.hwnd == null) return 0;
    }
    if (message == c.WM_GETOBJECT) if (window.content) |content| if (content.accessibility) |query| {
        if (query(content.context, window.window, wp, lp)) |result| return result;
        if (window.phase != .open or window.native.hwnd == null) return 0;
    };
    if (message != c.WM_NCCREATE and message != c.WM_DESTROY and message != c.WM_NCDESTROY and message != c.WM_CLOSE and window.phase == .open) {
        if (window.service) |service| if (service.message) |callback| {
            if (callback(service.context, window.window, message, wp, lp)) |result| return result;
            if (window.phase != .open or window.native.hwnd == null) return 0;
        };
    }
    const guarded_pointer = pointerEnvelopeMessage(message) or switch (message) {
        c.WM_KILLFOCUS, c.WM_CAPTURECHANGED, c.WM_CANCELMODE, c.WM_SIZE, c.WM_MOVE, c.WM_DPICHANGED, c.WM_SHOWWINDOW, c.WM_ENABLE => true,
        else => false,
    };
    if (guarded_pointer and (!sameWindow(window, hwnd) or pointerOperation(window) != operation)) return 0;
    // Keep the raw service notification, but do not turn a captured self-focus
    // echo into text cancellation or a public focus loss. Real reentry above
    // must still pass the original operation guard.
    if (notification == .focus_echo) return 0;
    if (message == c.WM_KEYDOWN and !window.native.text.composing and (superDown() or c.GetKeyState(c.VK_MENU) < 0)) return delegate(delegation, message, wp, lp);
    if (window.native.text.process(window, hwnd, message, wp, lp)) |result| return result;
    // KILLFOCUS can emit a synchronous composition-cancel callback. A closed
    // or replaced HWND must not reach the following native state queries.
    if (guarded_pointer and (!sameWindow(window, hwnd) or pointerOperation(window) != operation)) return 0;
    switch (message) {
        c.WM_NCCALCSIZE => {
            if (window.native.fullscreen and !window.native.restoring_placement and style(hwnd, c.GWL_STYLE) & c.WS_CAPTION == 0) return 0;
            if (window.options.decoration != .system) {
                const rect: *c.RECT = if (wp == 0) @ptrFromInt(@as(usize, @bitCast(lp))) else &@as(*c.NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @bitCast(lp)))).rgrc[0];
                if (c.IsZoomed(hwnd) != 0) {
                    var monitor = std.mem.zeroes(c.MONITORINFO);
                    monitor.cbSize = @sizeOf(c.MONITORINFO);
                    if (c.GetMonitorInfoW(c.MonitorFromRect(rect, c.MONITOR_DEFAULTTONULL), &monitor) != 0) rect.* = monitor.rcWork;
                }
                if (c.GetMenu(hwnd) != null) rect.top += c.GetSystemMetricsForDpi(c.SM_CYMENU, c.GetDpiForWindow(hwnd));
                return 0;
            }
        },
        c.WM_SETCURSOR => {
            // Over the client area the window's own shape shows; the frame
            // and resize edges keep the system's.
            const area: c_int = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp))))));
            if (@as(c.HWND, @ptrFromInt(@as(usize, @bitCast(wp)))) == hwnd and area == c.HTCLIENT and window.cursor != .default) {
                _ = c.SetCursor(cursorHandle(window.cursor));
                return c.TRUE;
            }
        },
        c.WM_NCHITTEST => {
            if (window.native.fullscreen) return c.HTCLIENT;
            if (window.options.decoration != .system) {
                const coordinate_bits: usize = @bitCast(lp);
                var pixel: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(coordinate_bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(coordinate_bits >> 16)))) };
                if (c.ScreenToClient(hwnd, &pixel) == 0) return c.HTCLIENT;
                const current_size = size(hwnd);
                const hit = window.hitTest(.{ .x = @as(f32, @floatFromInt(pixel.x)) / current_size.scale, .y = @as(f32, @floatFromInt(pixel.y)) / current_size.scale }, @as(f32, @floatFromInt(current_size.width)) / current_size.scale, @as(f32, @floatFromInt(current_size.height)) / current_size.scale);
                return switch (hit) {
                    .client => c.HTCLIENT,
                    .caption => c.HTCAPTION,
                    .system_menu => c.HTSYSMENU,
                    .north_west => c.HTTOPLEFT,
                    .north => c.HTTOP,
                    .north_east => c.HTTOPRIGHT,
                    .west => c.HTLEFT,
                    .east => c.HTRIGHT,
                    .south_west => c.HTBOTTOMLEFT,
                    .south => c.HTBOTTOM,
                    .south_east => c.HTBOTTOMRIGHT,
                };
            }
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            defer _ = c.EndPaint(hwnd, &ps);
            if (dc) |context| window.emit(.{ .paint = .{ .native_context = @ptrCast(context), .native_window = hwnd, .size = size(hwnd) } });
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_MOUSEACTIVATE => {
            if (quietPopup(window)) return c.MA_NOACTIVATE;
            if (ownsFocusablePopup(window)) return c.MA_ACTIVATEANDEAT;
        },
        c.WM_ACTIVATE => if (window.options.popup) |role| {
            if (role.focusable and wp & 0xffff == c.WA_INACTIVE and !popupFamily(window, @ptrFromInt(@as(usize, @bitCast(lp))))) {
                // Decide after the activation completes, outside its handler.
                _ = c.PostMessageW(hwnd, popup_dismiss_message, 0, 0);
            }
        },
        popup_dismiss_message => {
            if (c.IsWindowVisible(hwnd) != 0 and c.GetActiveWindow() != hwnd) window.popupDismissed();
            return 0;
        },
        c.WM_GETMINMAXINFO => {
            if (window.native.fullscreen and !window.native.restoring_placement) return 0;
            const limits: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            const dpi = c.GetDpiForWindow(hwnd);
            var rect: c.RECT = .{ .left = 0, .top = 0, .right = c.MulDiv(@intCast(window.options.min_width), @intCast(dpi), 96), .bottom = c.MulDiv(@intCast(window.options.min_height), @intCast(dpi), 96) };
            if (window.options.decoration != .system) {
                var monitor = std.mem.zeroes(c.MONITORINFO);
                monitor.cbSize = @sizeOf(c.MONITORINFO);
                if (c.GetMonitorInfoW(c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST), &monitor) != 0) {
                    limits.ptMaxPosition = .{ .x = monitor.rcWork.left - monitor.rcMonitor.left, .y = monitor.rcWork.top - monitor.rcMonitor.top };
                    limits.ptMaxSize = .{ .x = monitor.rcWork.right - monitor.rcWork.left, .y = monitor.rcWork.bottom - monitor.rcWork.top };
                }
                if (c.GetMenu(hwnd) != null) rect.bottom += c.GetSystemMetricsForDpi(c.SM_CYMENU, dpi);
            }
            if (window.options.decoration != .system or c.AdjustWindowRectExForDpi(&rect, style(hwnd, c.GWL_STYLE), @intFromBool(c.GetMenu(hwnd) != null), style(hwnd, c.GWL_EXSTYLE), dpi) != 0) {
                if (window.options.min_width != 0) limits.ptMinTrackSize.x = @max(limits.ptMinTrackSize.x, rect.right - rect.left);
                if (window.options.min_height != 0) limits.ptMinTrackSize.y = @max(limits.ptMinTrackSize.y, rect.bottom - rect.top);
            }
            return 0;
        },
        c.WM_SIZE => {
            window.emitPointerLifecycle(operation, .{ .resize = size(hwnd) });
            window.emitPointerState(operation);
            invalidate(window);
            return 0;
        },
        c.WM_MOVE => {
            window.emitPointerLifecycle(operation, .window_position);
            return 0;
        },
        c.WM_WINDOWPOSCHANGED, c.WM_SHOWWINDOW, c.WM_ENABLE => {
            if ((message == c.WM_SHOWWINDOW or message == c.WM_ENABLE) and wp == 0) {
                window.native.gesture_active = false;
                window.native.pending_interaction = null;
            }
            const result = c.DefWindowProcW(hwnd, message, wp, lp);
            window.emitPointerState(operation);
            return result;
        },
        c.WM_DPICHANGED => {
            if (window.native.icons.large != null) {
                window.native.icons.reload(c.GetModuleHandleW(null), @intCast(wp & 0xffff), hwnd) catch |err| {
                    window.window.report(.{ .severity = .warning, .domain = .win32, .operation = .icon_load, .code = c.GetLastError(), .err = err });
                };
            }
            if (!sameWindow(window, hwnd) or pointerOperation(window) != operation) return 0;
            const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            const rect = if (window.native.fullscreen and !window.native.restoring_placement) monitorRect(hwnd) orelse suggested.* else suggested.*;
            _ = c.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            if (!sameWindow(window, hwnd) or pointerOperation(window) != operation) return 0;
            window.emitPointerLifecycle(operation, .{ .resize = size(hwnd) });
            invalidate(window);
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            // SetFocus would activate a popup that never takes the keyboard.
            if (!quietPopup(window)) _ = c.SetFocus(hwnd);
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            if (c.GetCapture() != hwnd) _ = c.SetCapture(hwnd);
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            if (window.pointerEnabled() and c.GetCapture() != hwnd) window.pointerMotion(operation, null);
            const coordinate_bits: usize = @bitCast(lp);
            var pixel: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(coordinate_bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(coordinate_bits >> 16)))) };
            window.native.gesture_active = c.ClientToScreen(hwnd, &pixel) != 0 and pixel.x >= -32768 and pixel.x <= 32767 and pixel.y >= -32768 and pixel.y <= 32767;
            window.native.gesture_used = false;
            if (window.native.gesture_active) {
                const x: u16 = @bitCast(@as(i16, @intCast(pixel.x)));
                const y: u16 = @bitCast(@as(i16, @intCast(pixel.y)));
                window.native.gesture_point = @intCast(@as(u32, x) | (@as(u32, y) << 16));
            }
            defer if (pointerOperation(window) == operation) {
                window.native.gesture_active = false;
            };
            const input: core.PointerButtonInput = .{ .position = point(hwnd, lp), .button = .primary, .modifiers = modifiers };
            if (delivered) |value| value.* = true;
            if (window.pointerEnabled()) window.emitPointer(operation, sequence, .down, input) else window.emit(.{ .pointer_down = input });
            return 0;
        },
        c.WM_LBUTTONUP => {
            window.native.gesture_active = false;
            window.native.pending_interaction = null;
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            const input: core.PointerButtonInput = .{ .position = point(hwnd, lp), .button = .primary, .modifiers = modifiers };
            if (delivered) |value| value.* = true;
            if (window.pointerEnabled()) window.emitPointer(operation, sequence, .up, input) else window.emit(.{ .pointer_up = input });
            if (capture_owned and pointerContinuation(window, hwnd, operation) and c.GetCapture() == hwnd) {
                if (window.pointerEnabled()) _ = releasePointerCapture(window, hwnd, operation, sequence, true) else _ = c.ReleaseCapture();
            }
            return 0;
        },
        // Other client buttons reach content without taking focus or capture,
        // so a secondary press can open a context menu where it lands.
        c.WM_RBUTTONDOWN, c.WM_RBUTTONDBLCLK, c.WM_MBUTTONDOWN, c.WM_MBUTTONDBLCLK, c.WM_XBUTTONDOWN, c.WM_XBUTTONDBLCLK, c.WM_RBUTTONUP, c.WM_MBUTTONUP, c.WM_XBUTTONUP => {
            const button = nativeButton(message, wp) orelse return delegate(delegation, message, wp, lp);
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            const input: core.PointerButtonInput = .{ .position = point(hwnd, lp), .button = button, .modifiers = modifiers };
            if (delivered) |value| value.* = true;
            const down = buttonPhase(message) == .down;
            if (window.pointerEnabled()) window.emitPointer(operation, sequence, if (down) .down else .up, input) else if (down) window.emit(.{ .pointer_down = input }) else window.emit(.{ .pointer_up = input });
            // The default procedure still turns a secondary release into WM_CONTEXTMENU.
            if (!pointerContinuation(window, hwnd, operation)) return 0;
            return delegate(delegation, message, wp, lp);
        },
        c.WM_MOUSEMOVE => {
            window.emit(.{ .pointer_move = point(hwnd, lp) });
            return 0;
        },
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            const bits: usize = @bitCast(lp);
            var pixel: c.POINT = .{ .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))), .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))) };
            _ = c.ScreenToClient(hwnd, &pixel);
            const scale = size(hwnd).scale;
            const delta = @as(f32, @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(wp >> 16)))))) / 120.0 * 48.0;
            window.emit(.{ .wheel = .{ .position = .{ .x = @as(f32, @floatFromInt(pixel.x)) / scale, .y = @as(f32, @floatFromInt(pixel.y)) / scale }, .delta = if (message == c.WM_MOUSEWHEEL) .{ .x = 0, .y = -delta } else .{ .x = delta, .y = 0 } } });
            return 0;
        },
        c.WM_SETFOCUS => {
            window.emit(.{ .focus = true });
            window.emitState();
            return 0;
        },
        c.WM_KILLFOCUS => {
            window.native.gesture_active = false;
            window.native.pending_interaction = null;
            window.emitPointerLifecycle(operation, .{ .focus = false });
            window.emitPointerState(operation);
            window.emitPointerLifecycle(operation, .cancel_input);
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            window.native.gesture_active = false;
            window.native.pending_interaction = null;
            if (notification == .own_up_capture) window.emitPointerCancel(operation, sequence, .primary) else window.emitPointerLifecycle(operation, .cancel_input);
            return 0;
        },
        c.WM_KEYDOWN => {
            if (window.native.text.composing) return delegate(delegation, message, wp, lp);
            if (wp == c.VK_TAB) window.emit(.{ .key = .tab });
            if (wp == c.VK_SPACE or wp == c.VK_RETURN) window.emit(.{ .key = .activate });
            return 0;
        },
        c.WM_CLOSE => {
            _ = window.window.requestCloseFrom(.user) catch |err| {
                std.log.err("close request: {s}", .{@errorName(err)});
                return 0;
            };
            return 0;
        },
        c.WM_DESTROY => {
            window.nativeDestroying();
            return 0;
        },
        c.WM_NCDESTROY => {
            uncountPointer(window);
            _ = c.RemovePropW(hwnd, identity_property);
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            const result = c.DefWindowProcW(hwnd, message, wp, lp);
            window.native.hwnd = null;
            window.native.icons.deinit();
            window.nativeDestroyed();
            return result;
        },
        else => {},
    }
    if (message == c.WM_CANCELMODE and (!sameWindow(window, hwnd) or pointerOperation(window) != operation)) return 0;
    return delegate(delegation, message, wp, lp);
}
/// System cursor for a shape; Windows has no one-sided, column, row or
/// vertical text cursors and uses the nearest ones, and the arrow for copy,
/// alias and context menu. Shared system cursors need no release.
fn cursorHandle(cursor: core.Cursor) c.HCURSOR {
    const id: usize = switch (cursor) {
        .none => return null,
        .default, .copy, .alias, .context_menu => 32512,
        .pointer, .grab => 32649,
        .text, .vertical_text => 32513,
        .move, .grabbing => 32646,
        .resize_ew, .resize_e, .resize_w, .resize_column => 32644,
        .resize_ns, .resize_n, .resize_s, .resize_row => 32645,
        .resize_nwse => 32642,
        .resize_nesw => 32643,
        .not_allowed => 32648,
        .crosshair => 32515,
    };
    return c.LoadCursorW(null, @ptrFromInt(id));
}
/// Show the shape at once when the pointer is over the client area; later
/// moves keep it through WM_SETCURSOR.
pub fn setCursor(window: *core.WindowRecord, cursor: core.Cursor) void {
    const hwnd = window.native.hwnd orelse return;
    var at: c.POINT = undefined;
    if (c.GetCursorPos(&at) == 0) return;
    if (c.WindowFromPoint(at) != hwnd) return;
    if (c.ScreenToClient(hwnd, &at) == 0) return;
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return;
    if (at.x < client.left or at.y < client.top or at.x >= client.right or at.y >= client.bottom) return;
    _ = c.SetCursor(cursorHandle(cursor));
}
