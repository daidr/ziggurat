const std = @import("std");
const z = @import("ziggurat");
const c = @import("ziggurat_c_win32");
const Probe = struct {
    next: ?z.TextInputMode = null,
    read_switch: bool = false,
    disable_on_text: bool = false,
    reenter_high: bool = false,
    reenter_on_cancel: bool = false,
    bytes: [64]u8 = undefined,
    length: usize = 0,
    commits: usize = 0,
    preedits: usize = 0,
    failure: ?anyerror = null,
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (value == .text_preedit_cancel and self.reenter_on_cancel) {
            self.reenter_on_cancel = false;
            _ = c.SendMessageW(window.nativeHandle(), c.WM_CHAR, 0xd802, 0);
        }
        if (value == .text_preedit) self.preedits += 1;
        if (value != .text_input) return;
        self.commits += 1;
        const text = value.text_input.text;
        if (text.len > self.bytes.len - self.length) {
            self.failure = error.CapacityExceeded;
            return;
        }
        @memcpy(self.bytes[self.length..][0..text.len], text);
        self.length += text.len;
        if (self.reenter_high) {
            self.reenter_high = false;
            _ = c.SendMessageW(window.nativeHandle(), c.WM_CHAR, 0xd802, 0);
        }
        if (self.disable_on_text) {
            self.disable_on_text = false;
            window.perform(.disable) catch |err| {
                self.failure = err;
            };
        }
        if (self.next) |mode| {
            self.next = null;
            const result = window.setTextInputMode(mode) catch |err| {
                self.failure = err;
                return;
            };
            if (result != .applied) self.failure = error.UnexpectedSuperseded;
        }
    }
    fn detach(_: *anyopaque) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn read(ptr: *anyopaque, window: z.Window, storage: []u8) !z.text.Snapshot {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (self.read_switch) {
            self.read_switch = false;
            try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
        }
        if (storage.len < 1) return error.CapacityExceeded;
        storage[0] = 'x';
        return .{ .range = .{ .start = 0, .end = 1 }, .selection = .{ .anchor = 0, .caret = 0 }, .revision = 1, .bytes = 1 };
    }
    fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
        return .applied;
    }
    fn check(self: *Probe) !void {
        if (self.failure) |err| return err;
    }
};
pub fn check(allocator: std.mem.Allocator) !void {
    var probe: Probe = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &probe, .emit = Probe.diagnostic } });
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    const hwnd = window.nativeHandle();
    _ = c.SetFocus(hwnd);
    try std.testing.expect(c.GetFocus() == hwnd);
    const record = app.windows.get(window.key).?;
    _ = try window.setTextInputMode(.keyboard_compose);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd800, 0);
    probe.next = .system;
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd801, 0);
    try std.testing.expect(record.native.text.high_surrogate == null);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xdc00, 0);
    try probe.check();
    try std.testing.expectEqualStrings("��", probe.bytes[0..probe.length]);
    probe.length = 0;
    _ = try window.setTextInputMode(.keyboard_compose);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xd800, 0);
    probe.next = .system;
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'X', 0);
    try std.testing.expectEqualStrings("�", probe.bytes[0..probe.length]);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 'Y', 0);
    try std.testing.expectEqualStrings("�Y", probe.bytes[0..probe.length]);
    try probe.check();

    // Result + preedit may share one message when authority remains current.
    // Empty native strings are sufficient to test that exact continuation.
    const owned_context = c.ImmCreateContext() orelse return error.InputContextUnavailable;
    const previous_context = c.ImmAssociateContext(hwnd, owned_context);
    defer {
        if (!window.isClosed()) _ = c.ImmAssociateContext(hwnd, previous_context);
        std.debug.assert(c.ImmDestroyContext(owned_context) != 0);
    }
    probe.commits = 0;
    probe.preedits = 0;
    probe.length = 0;
    _ = c.SendMessageW(hwnd, c.WM_IME_COMPOSITION, 0, c.GCS_RESULTSTR | c.GCS_COMPSTR);
    try probe.check();
    try std.testing.expectEqual(@as(usize, 1), probe.commits);
    try std.testing.expectEqual(@as(usize, 1), probe.preedits);
    probe.commits = 0;
    probe.preedits = 0;
    probe.next = .keyboard_compose;
    _ = c.SendMessageW(hwnd, c.WM_IME_COMPOSITION, 0, c.GCS_RESULTSTR | c.GCS_COMPSTR);
    try probe.check();
    try std.testing.expectEqual(@as(usize, 1), probe.commits);
    try std.testing.expectEqual(@as(usize, 0), probe.preedits);
    try std.testing.expect(!record.native.text.composing);

    _ = try window.setTextInputMode(.system);
    _ = c.ImmAssociateContext(hwnd, owned_context);
    probe.commits = 0;
    probe.preedits = 0;
    probe.length = 0;
    probe.reenter_high = true;
    _ = c.SendMessageW(hwnd, c.WM_IME_COMPOSITION, 0, c.GCS_RESULTSTR | c.GCS_COMPSTR);
    try probe.check();
    try std.testing.expectEqual(@as(usize, 1), probe.commits);
    try std.testing.expectEqual(@as(usize, 0), probe.preedits);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xdc00, 0);
    try std.testing.expectEqualStrings("\u{10800}", probe.bytes[0..probe.length]);
    _ = c.SendMessageW(hwnd, c.WM_IME_STARTCOMPOSITION, 0, 0);
    probe.reenter_on_cancel = true;
    try std.testing.expectEqual(z.TextInputModeResult.superseded, try window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    try std.testing.expectEqual(@as(?u16, 0xd802), record.native.text.high_surrogate);
    _ = c.SendMessageW(hwnd, c.WM_CHAR, 0xdc00, 0);
    try probe.check();

    _ = try window.setTextInputMode(.system);
    _ = try window.setTextClient(.{ .context = &probe, .owner = app.owner, .read = Probe.read, .change = Probe.change });
    probe.read_switch = true;
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0));
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, try window.textInputMode());
    try std.testing.expect(record.native.text.reconversion == null);
    _ = try window.setTextInputMode(.system);
    var reconversion = std.mem.zeroes(c.RECONVERTSTRING);
    reconversion.dwSize = @sizeOf(c.RECONVERTSTRING);
    probe.read_switch = true;
    try std.testing.expectEqual(@as(c.LRESULT, 0), c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(&reconversion))));
    try std.testing.expect(record.native.text.reconversion == null);
    try std.testing.expectEqual(@as(c.DWORD, @sizeOf(c.RECONVERTSTRING)), reconversion.dwSize);
    try probe.check();
    // No focus loss or bound TextClient can incidentally clear this decoder.
    // Permission changes in an observer revoke the same native message tail.
    const hidden = try app.createWindow(.{ .text_input_mode = .keyboard_compose });
    defer _ = hidden.destroy() catch unreachable;
    try hidden.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    const hidden_hwnd = hidden.nativeHandle();
    try std.testing.expect(c.GetFocus() != hidden_hwnd);
    try std.testing.expect(!try hidden.hasTextClient());
    const hidden_record = app.windows.get(hidden.key).?;
    probe.length = 0;
    probe.commits = 0;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xd800, 0);
    probe.disable_on_text = true;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xd801, 0);
    try probe.check();
    try std.testing.expect(hidden_record.native.text.high_surrogate == null);
    try std.testing.expectEqualStrings("�", probe.bytes[0..probe.length]);
    try hidden.perform(.enable);
    probe.length = 0;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xd800, 0);
    probe.disable_on_text = true;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 'X', 0);
    try probe.check();
    try std.testing.expect(hidden_record.native.text.high_surrogate == null);
    try std.testing.expectEqualStrings("�", probe.bytes[0..probe.length]);
    try hidden.perform(.enable);
    probe.length = 0;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xd800, 0);
    probe.reenter_high = true;
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xd801, 0);
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xdc00, 0);
    try probe.check();
    try std.testing.expectEqualStrings("�\u{10800}", probe.bytes[0..probe.length]);
    probe.length = 0;
    probe.reenter_high = true;
    _ = c.SendMessageW(hidden_hwnd, c.WM_UNICHAR, 'Q', 0);
    _ = c.SendMessageW(hidden_hwnd, c.WM_CHAR, 0xdc00, 0);
    try std.testing.expectEqualStrings("Q\u{10800}", probe.bytes[0..probe.length]);
    std.debug.print("text-input-mode Windows: whole-message surrogate/result+preedit/request authority verified\n", .{});
}
