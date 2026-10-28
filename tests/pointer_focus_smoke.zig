const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = @import("ziggurat_c_win32");

const Mode = enum { startup, foreign_loss, foreign_aba, all };
const position: c.LPARAM = (10 << 16) | 10;
const State = struct {
    enabled: bool,
    mode: Mode,
    window: ?z.Window = null,
    other: ?z.Window = null,
    failure: ?anyerror = null,
    armed: bool = false,
    interventions: usize = 0,
    clicks: usize = 0,
    downs: usize = 0,
    ups: usize = 0,
    focus_losses: usize = 0,
    cancels: usize = 0,
    self_echoes: usize = 0,
    native_losses: usize = 0,
    closed: usize = 0,
    before_foreign: u64 = 0,
    after_foreign: u64 = 0,
    after_return: u64 = 0,

    fn fail(self: *State, err: anyerror) void {
        self.failure = self.failure orelse err;
        std.debug.print("first-focus failure enabled={} mode={s} error={s}\n", .{ self.enabled, @tagName(self.mode), @errorName(err) });
    }
    fn check(self: *const State) !void {
        if (self.failure) |err| return err;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.fail(value.err orelse error.UnexpectedDiagnostic);
    }
    fn draw(_: *anyopaque, frame: *ui.Frame) void {
        frame.clear(0xffffff);
        frame.pushClip(.{ .x = 0, .y = 0, .width = 80, .height = 60 }) catch unreachable;
        frame.button(7, .{ .x = 0, .y = 0, .width = 120, .height = 60 }, "Test") catch unreachable;
        frame.popClip() catch unreachable;
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (id != 7) return self.fail(error.UnexpectedAction);
        self.clicks += 1;
        std.debug.print("first-focus action enabled={} mode={s} clicks={d}\n", .{ self.enabled, @tagName(self.mode), self.clicks });
    }
    fn input(ptr: *anyopaque, context: *ui.Context, value: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .pointer_down => |button| {
                self.downs += 1;
                self.observePress(context.window.?, button.press, .down);
            },
            .pointer_up => |button| {
                self.ups += 1;
                // The deliberately rejected down has no matching raw up
                // receipt. It remains an ordinary pointer-up delivery.
                if (button.press.sequence != 0 or !self.enabled) self.observePress(context.window.?, button.press, .up);
            },
            .focus => |focused| if (!focused) {
                self.focus_losses += 1;
            },
            .cancel_input => self.cancels += 1,
            else => {},
        }
        std.debug.print("first-focus input enabled={} mode={s} tag={s} active={?d} clicks={d} focus=0x{x} capture=0x{x}\n", .{ self.enabled, @tagName(self.mode), @tagName(value), context.input_state.active, self.clicks, address(c.GetFocus()), address(c.GetCapture()) });
        return false;
    }
    fn observePress(self: *State, window: z.Window, press: z.PointerPress, phase: z.PointerPhase) void {
        if (self.enabled) {
            if (press.sequence == 0) return self.fail(error.MissingRawReceipt);
            const snapshot = window.pointerPressSnapshot(press, phase) catch |err| return self.fail(err);
            if (snapshot.button != .primary) return self.fail(error.WrongRawButton);
        } else {
            if (press.sequence != 0) return self.fail(error.DefaultRawReceipt);
            std.testing.expectError(error.UnsupportedCapability, window.pointerPressSnapshot(press, phase)) catch |err| self.fail(err);
        }
    }
    fn message(ptr: *anyopaque, window: z.Window, message_value: u32, wp: usize, _: isize) ?isize {
        const self: *State = @ptrCast(@alignCast(ptr));
        const origin = self.window orelse return null;
        const is_origin = std.meta.eql(window.key, origin.key);
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        const focus = c.GetFocus();
        if (message_value == c.WM_KILLFOCUS and is_origin) {
            const echo = wp == address(hwnd) and focus == hwnd;
            if (echo) self.self_echoes += 1 else self.native_losses += 1;
            std.debug.print("first-focus actual-kill enabled={} mode={s} echo={} op={d} wp=0x{x} hwnd=0x{x} focus=0x{x}\n", .{ self.enabled, @tagName(self.mode), echo, operation(window), wp, address(hwnd), address(focus) });
        }
        if (message_value == c.WM_SETFOCUS) std.debug.print("first-focus actual-set enabled={} mode={s} origin={} op={d} wp=0x{x} hwnd=0x{x} focus=0x{x}\n", .{ self.enabled, @tagName(self.mode), is_origin, operation(window), wp, address(hwnd), address(focus) });
        if (!is_origin or message_value != c.WM_LBUTTONDOWN or !self.armed) return null;
        self.armed = false; // Consume before real SetFocus can reenter services.
        self.interventions += 1;
        self.before_foreign = operation(origin);
        const other: c.HWND = @ptrCast(self.other.?.nativeHandle());
        // These are actual focus operations on this fixture's two framework
        // windows, not fabricated WM_KILLFOCUS/SETFOCUS notifications.
        _ = c.SetFocus(other);
        if (c.GetFocus() != other) {
            self.fail(error.ForeignThreadFocusUnavailable);
            return null;
        }
        self.after_foreign = operation(origin);
        if (self.after_foreign == self.before_foreign) self.fail(error.ForeignFocusDidNotRevoke);
        if (self.mode == .foreign_aba) {
            _ = c.SetFocus(hwnd);
            if (c.GetFocus() != hwnd) self.fail(error.ReturnThreadFocusUnavailable);
        }
        self.after_return = operation(origin);
        if (self.after_return == self.before_foreign) self.fail(error.ForeignFocusWasRebased);
        std.debug.print("first-focus actual-foreign enabled={} mode={s} before={d} away={d} returned={d} final_focus=0x{x}\n", .{ self.enabled, @tagName(self.mode), self.before_foreign, self.after_foreign, self.after_return, address(c.GetFocus()) });
        // Never consume the outer down. Its original native operation must be
        // rejected by the adapter's guard, even for ABA's final self focus.
        return null;
    }
    fn destroying(_: *anyopaque) void {}
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }
    fn close(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        _ = self.window.?.destroy() catch unreachable;
        _ = self.other.?.destroy() catch unreachable;
    }
    fn pair(self: *State) void {
        const hwnd: c.HWND = @ptrCast(self.window.?.nativeHandle());
        // Preserve the original smoke's exact client coordinates and wp0.
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONDOWN, 0, position);
        _ = c.SendMessageW(hwnd, c.WM_LBUTTONUP, 0, position);
    }
};

fn address(value: c.HWND) usize {
    return if (value) |pointer| @intFromPtr(pointer) else 0;
}
fn operation(window: z.Window) u64 {
    const record = window.app.windows.get(window.key) orelse return 0;
    return record.pointerOperation();
}

fn scenario(allocator: std.mem.Allocator, enabled: bool, mode: Mode) !void {
    var state: State = .{ .enabled = enabled, .mode = mode };
    var content = ui.Context.init(&state, State.draw, State.action);
    content.render_mode = .gdi;
    content.on_input = State.input;
    const app = try z.App.initWithOptions(allocator, .{ .icon_policy = .disabled, .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    defer {
        if (state.window) |window| if (!window.isClosed()) {
            _ = window.destroy() catch unreachable;
        };
        if (state.other) |window| if (!window.isClosed()) {
            _ = window.destroy() catch unreachable;
        };
        app.dispatch() catch unreachable;
        const resources = app.resourceStats();
        std.debug.print("first-focus final enabled={} mode={s} closed={d} records={d} live={d} pending={d}\n", .{ enabled, @tagName(mode), state.closed, resources.allocated_records, resources.live_windows, resources.pending_destroys });
        std.debug.assert(resources.allocated_records == 0 and resources.live_windows == 0 and resources.pending_destroys == 0);
        if (comptime ui.capabilities.accessibility) {
            const access = ui.accessibility.resourceCounts();
            std.debug.print("first-focus accessibility final={any}\n", .{access});
            std.debug.assert(access.states == 0 and access.providers == 0 and access.ranges == 0 and access.actions == 0);
        }
    }
    state.window = try app.createWindow(.{ .native_pointer_clicks = enabled, .width = 320, .height = 200, .on_closed = .{ .context = &state, .notify = State.onClosed } });
    state.other = try app.createWindow(.{ .native_pointer_clicks = enabled, .width = 160, .height = 100, .on_closed = .{ .context = &state, .notify = State.onClosed } });
    try content.attach(state.window.?);
    try state.window.?.setService(.{ .context = &state, .message = State.message, .native_destroying = State.destroying });
    try state.other.?.setService(.{ .context = &state, .message = State.message, .native_destroying = State.destroying });
    const hwnd: c.HWND = @ptrCast(state.window.?.nativeHandle());
    // No ShowWindow or SetFocus setup precedes the original first two pairs.
    // Initial focus and any genuine self echo are observations, not synthetic
    // messages or assumptions required of every OS configuration.
    std.debug.print("first-focus begin enabled={} mode={s} initial_focus=0x{x} hwnd=0x{x} other=0x{x}\n", .{ enabled, @tagName(mode), address(c.GetFocus()), address(hwnd), address(@ptrCast(state.other.?.nativeHandle())) });
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try std.testing.expect(content.frames > 0);
    const outside_x: c_int = @intFromFloat(110 * content.renderer.scale);
    const outside_y: c_int = @intFromFloat(10 * content.renderer.scale);
    try std.testing.expectEqual(@as(c.COLORREF, 0xffffff), c.GetPixel(content.renderer.dc, outside_x, outside_y));
    const frames = content.frames;
    state.pair();
    try state.check();
    try std.testing.expectEqual(@as(usize, 1), state.clicks);
    state.pair();
    try state.check();
    try std.testing.expectEqual(@as(usize, 2), state.clicks);
    try std.testing.expectEqual(@as(usize, 2), state.downs);
    try std.testing.expectEqual(@as(usize, 2), state.ups);
    try std.testing.expectEqual(frames, content.frames);
    try std.testing.expect(c.GetCapture() == null);
    std.debug.print("first-focus startup enabled={} mode={s} actual_self_echoes={d} actual_losses={d} actions={d}; echo occurrence is not mandatory\n", .{ enabled, @tagName(mode), state.self_echoes, state.native_losses, state.clicks });

    if (mode != .startup) {
        try std.testing.expect(c.GetFocus() == hwnd);
        const losses = state.native_losses;
        const delivered_losses = state.focus_losses;
        const downs = state.downs;
        const ups = state.ups;
        state.armed = true;
        state.pair();
        try state.check();
        try std.testing.expectEqual(@as(usize, 1), state.interventions);
        try std.testing.expect(state.native_losses > losses and state.focus_losses > delivered_losses);
        try std.testing.expect(state.after_foreign != state.before_foreign and state.after_return != state.before_foreign);
        try std.testing.expectEqual(downs, state.downs);
        try std.testing.expectEqual(ups + 1, state.ups);
        try std.testing.expectEqual(@as(usize, 2), state.clicks);
        try std.testing.expect(content.input_state.active == null);
        try std.testing.expect(c.GetCapture() == null);
        if (mode == .foreign_aba) try std.testing.expect(c.GetFocus() == hwnd);
        if (mode == .foreign_loss) try std.testing.expect(c.GetFocus() == @as(c.HWND, @ptrCast(state.other.?.nativeHandle())));
        // A fresh operation after genuine loss/ABA remains usable. The loss
        // case also reacquires focus through the normal down path, without a
        // test SetFocus back to the origin.
        state.pair();
        try state.check();
        try std.testing.expectEqual(downs + 1, state.downs);
        try std.testing.expectEqual(ups + 2, state.ups);
        try std.testing.expectEqual(@as(usize, 3), state.clicks);
        try std.testing.expect(c.GetCapture() == null);
    }
    std.debug.print("first-focus passed enabled={} mode={s} down={d} up={d} clicks={d} self_echoes={d} true_losses={d} focus_false={d} cancel={d}\n", .{ enabled, @tagName(mode), state.downs, state.ups, state.clicks, state.self_echoes, state.native_losses, state.focus_losses, state.cancels });
    try app.post(.{ .context = &state, .call = State.close });
    try app.run();
    try state.check();
    try std.testing.expect(state.window.?.isClosed() and state.other.?.isClosed() and content.window == null and state.closed == 2);
}

fn isolatedWindows(mode: Mode) !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.FirstFocus.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    const suffix: []const u16 = switch (mode) {
        .startup => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child startup"),
        .foreign_loss => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child foreign_loss"),
        .foreign_aba => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child foreign_aba"),
        .all => std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child all"),
    };
    if (count + 1 + suffix.len >= command.len) return error.CommandTooLong;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    // Parent-process test deadline only. The child uses the real App queue;
    // it never blocks a UI callback or pumps a nested event loop.
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) {
        std.debug.print("first-focus private-desktop child exit=0x{x}\n", .{exit_code});
        return error.TestProcessFailed;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (args.len == 1) return isolatedWindows(.all);
    if (args.len == 2) return isolatedWindows(std.meta.stringToEnum(Mode, args[1]) orelse return error.InvalidArgument);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse return error.InvalidArgument;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    for ([_]bool{ false, true }) |enabled| {
        if (mode == .all) {
            for ([_]Mode{ .startup, .foreign_loss, .foreign_aba }) |selected| try scenario(debug.allocator(), enabled, selected);
        } else try scenario(debug.allocator(), enabled, mode);
    }
    std.debug.print("first-focus mode={s} passed false/true: real native facts, no pre-focus/show, no assumed self-echo occurrence\n", .{@tagName(mode)});
}
