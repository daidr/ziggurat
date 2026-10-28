const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_resource_count() u32;
extern fn zlg_test_text_mode_simple(*anyopaque) c_int;
extern fn zlg_test_text_key(*anyopaque, c_uint, c_uint) void;
extern fn zlg_test_text_key_release(*anyopaque, c_uint, c_uint) void;
extern fn zlg_test_preedit_start(*anyopaque) void;
extern fn zlg_test_retired_text_signals(*anyopaque) c_int;
extern fn zlg_test_text_context_hold(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;

const Host = struct {
    action: enum { none, restart, close, switch_text } = .none,
    text: [256]u8 = undefined,
    length: usize = 0,
    cancellations: usize = 0,
    expect_transition: bool = false,
    failure: ?anyerror = null,
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.checked(window, value) catch |err| {
            self.failure = err;
        };
    }
    fn checked(self: *Host, window: z.Window, value: z.Event) !void {
        switch (value) {
            .text_input => |input| {
                if (self.length + input.text.len > self.text.len) return error.CapacityExceeded;
                @memcpy(self.text[self.length..][0..input.text.len], input.text);
                self.length += input.text.len;
                if (self.action == .switch_text) {
                    self.action = .none;
                    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.system));
                }
            },
            .text_preedit_cancel => {
                self.cancellations += 1;
                if (self.expect_transition) try std.testing.expectError(error.Busy, window.setTextInputMode(.keyboard_compose));
                const action = self.action;
                self.action = .none;
                if (action == .restart) start(window);
                if (action == .close) _ = try window.destroy();
            },
            else => {},
        }
    }
    fn detach(_: *anyopaque) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn check(self: *Host) !void {
        if (self.failure) |err| return err;
    }
};
fn native(window: z.Window) *anyopaque {
    return window.app.windows.get(window.key).?.native.native.?;
}
fn start(window: z.Window) void {
    if (builtin.os.tag == .windows) _ = c.SendMessageW(window.nativeHandle(), c.WM_IME_STARTCOMPOSITION, 0, 0) else zlg_test_preedit_start(native(window));
}
fn check(allocator: std.mem.Allocator) !void {
    var host: Host = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    const direct = try app.createWindow(.{ .text_input_mode = .keyboard_compose });
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, try direct.textInputMode());
    if (builtin.os.tag == .windows) {
        const associated = c.ImmGetContext(direct.nativeHandle());
        if (associated != null) _ = c.ImmReleaseContext(direct.nativeHandle(), associated);
        try std.testing.expect(associated == null);
    } else try std.testing.expect(zlg_test_text_mode_simple(native(direct)) != 0);
    _ = try direct.destroy();
    try app.dispatch();
    try window.setContent(.{ .context = &host, .event = Host.event, .detach = Host.detach });
    if (builtin.os.tag == .windows) {
        _ = c.SetFocus(window.nativeHandle());
        try std.testing.expect(c.GetFocus() == window.nativeHandle());
    }
    const original = try window.textInputStamp();
    const retired_system: ?*anyopaque = if (builtin.os.tag == .linux) zlg_test_text_context_hold(native(window)) else null;
    defer if (retired_system) |context| g_object_unref(context);
    try std.testing.expectEqual(z.TextInputMode.system, original.mode);
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.system));
    try std.testing.expectEqual(original, try window.textInputStamp());
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
    const selected = try window.textInputStamp();
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(selected, try window.textInputStamp());
    if (builtin.os.tag == .windows) {
        const hwnd = window.nativeHandle();
        try std.testing.expect(c.ImmGetContext(hwnd) == null);
        _ = c.SendMessageW(hwnd, c.WM_IME_STARTCOMPOSITION, 0, 0);
        _ = c.SendMessageW(hwnd, c.WM_IME_COMPOSITION, 0, c.GCS_RESULTSTR);
        try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0));
        _ = c.SendMessageW(hwnd, c.WM_IME_ENDCOMPOSITION, 0, 0);
        try std.testing.expectEqual(@as(usize, 0), host.cancellations);
        _ = c.SendMessageW(hwnd, c.WM_CHAR, 'x', 0);
        _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd83d, 0);
        _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xde00, 0);
        _ = c.SendMessageW(hwnd, c.WM_UNICHAR, 0x4e2d, 0);
        try std.testing.expectEqualStrings("x😀中", host.text[0..host.length]);
        // Forward an actual current-layout notification. This is not a claim
        // that every TSF profile switch emits WM_INPUTLANGCHANGE.
        _ = c.SendMessageW(hwnd, c.WM_INPUTLANGCHANGE, 0, @bitCast(@intFromPtr(c.GetKeyboardLayout(0))));
        try std.testing.expect(c.ImmGetContext(hwnd) == null);
        var keys: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&keys) != 0);
        defer _ = c.SetKeyboardState(&keys);
        var clear: [256]u8 = @splat(0);
        try std.testing.expect(c.SetKeyboardState(&clear) != 0);
        var message = std.mem.zeroes(c.MSG);
        message.hwnd = hwnd;
        message.message = c.WM_KEYDOWN;
        message.wParam = 'Q';
        try std.testing.expect(c.TranslateMessage(&message) != 0);
        try std.testing.expect(c.PeekMessageW(&message, hwnd, c.WM_CHAR, c.WM_CHAR, c.PM_REMOVE) != 0);
        const previous_length = host.length;
        _ = c.DispatchMessageW(&message);
        try std.testing.expect(host.length > previous_length);
    } else {
        try std.testing.expect(zlg_test_text_mode_simple(native(window)) != 0);
        zlg_test_text_key(native(window), 'x', 0);
        zlg_test_text_key(native(window), 0xff20, 0); // Compose, apostrophe, e
        zlg_test_text_key(native(window), '\'', 0);
        zlg_test_text_key(native(window), 'e', 0);
        try std.testing.expectEqualStrings("xé", host.text[0..host.length]);
        zlg_test_text_key(native(window), 'U', 5); // Ctrl+Shift Unicode input
        zlg_test_text_key_release(native(window), 0xffe3, 5); // release Control
        for ("123") |key| zlg_test_text_key(native(window), key, 0);
        zlg_test_text_key(native(window), 0xff0d, 0);
        try std.testing.expectEqualStrings("xéģ", host.text[0..host.length]);
        try std.testing.expect(zlg_test_retired_text_signals(retired_system.?) != 0);
        try std.testing.expectEqualStrings("xéģ", host.text[0..host.length]);
        host.action = .switch_text;
        const retired_simple = zlg_test_text_context_hold(native(window));
        defer g_object_unref(retired_simple);
        const before = host.length;
        zlg_test_text_key(native(window), 'q', 0);
        try std.testing.expectEqual(before + 1, host.length);
        try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
        try std.testing.expect(zlg_test_retired_text_signals(retired_simple) != 0);
        try std.testing.expect(zlg_test_retired_text_signals(retired_system.?) != 0);
    }
    try host.check();
    _ = try window.setTextInputMode(.system);
    if (builtin.os.tag == .windows) {
        const context = c.ImmGetContext(window.nativeHandle()) orelse return error.DefaultContextUnavailable;
        try std.testing.expect(c.ImmReleaseContext(window.nativeHandle(), context) != 0);
    } else try std.testing.expect(zlg_test_text_mode_simple(native(window)) == 0);
    // Match the existing message-level IME fixture: this explicit context is
    // owned by the test, so synthetic START has cancellable native storage.
    // The framework itself only restores the window's default association.
    const owned_context: ?*anyopaque = if (builtin.os.tag == .windows) c.ImmCreateContext() orelse return error.InputContextUnavailable else null;
    const previous_context: ?*anyopaque = if (builtin.os.tag == .windows) c.ImmAssociateContext(window.nativeHandle(), owned_context) else null;
    defer if (builtin.os.tag == .windows) {
        if (!window.isClosed()) _ = c.ImmAssociateContext(window.nativeHandle(), previous_context);
        std.debug.assert(c.ImmDestroyContext(owned_context) != 0);
    };
    start(window);
    host.expect_transition = true;
    host.action = .restart;
    const before_cancel = host.cancellations;
    try std.testing.expectEqual(z.TextInputModeResult.superseded, try window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(before_cancel + 1, host.cancellations);
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    host.action = .none;
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
    _ = try window.setTextInputMode(.system);
    start(window);
    host.action = .close;
    try std.testing.expectEqual(z.TextInputModeResult.superseded, try window.setTextInputMode(.keyboard_compose));
    try std.testing.expect(window.isClosed());
    try app.dispatch();
    try host.check();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try check(gpa.allocator());
    if (builtin.os.tag == .windows) try @import("text_input_mode_windows.zig").check(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("text-input-mode: native association/context, keyboard/compose, retired signals, callback restart/close, resources=0\n", .{});
}
