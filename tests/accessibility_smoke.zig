const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const access = ui.accessibility;
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zua_get_object(*anyopaque, usize, isize) isize;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
    @cInclude("oleauto.h");
});
const detach_message = c.WM_APP + 61;
var subclass_state: ?*State = null;
var original_proc: c.WNDPROC = null;
fn subclass(hwnd: c.HWND, message: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (message == detach_message) {
        const state = subclass_state.?;
        if (c.InSendMessageEx(null) & c.ISMEX_SEND == 0) return 0;
        State.detachBridge(state);
        state.app.dispatch() catch |err| {
            state.err = err;
            return 0;
        };
        state.cleanup_deferred_inside_send = state.app.cleanup_head != null and access.resourceCounts().states == 1;
        return @intFromBool(state.cleanup_deferred_inside_send);
    }
    return c.CallWindowProcW(@ptrCast(original_proc), hwnd, message, wp, lp);
}

const State = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    bridge: access.Bridge = undefined,
    tree: access.Tree = .{},
    buffer: ui.text_buffer.TextBuffer,
    invocations: usize = 0,
    err: ?anyerror = null,
    client_err: ?anyerror = null,
    bridge_detached: bool = false,
    cleanup_deferred_inside_send: bool = false,
    fn publish(self: *State) !void {
        try self.tree.reset("Accessibility smoke", .{ .x = 0, .y = 0, .width = 300, .height = 160 });
        try self.tree.add(.{ .id = 1, .role = .button, .name = "Apply", .bounds = .{ .x = 10, .y = 10, .width = 100, .height = 40 } });
        const selected = self.buffer.selection();
        try self.tree.add(.{ .id = 2, .role = .text_box, .name = "Document", .value = self.buffer.text(), .bounds = .{ .x = 10, .y = 60, .width = 260, .height = 60 }, .selection_start = selected.anchor, .selection_end = selected.caret });
        try self.bridge.publish(&self.tree);
    }
    fn action(ptr: *anyopaque, _: z.Window, action_value: access.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        self.apply(action_value) catch |err| {
            self.err = err;
        };
    }
    fn apply(self: *State, action_value: access.Action) !void {
        switch (action_value) {
            .invoke => |id| {
                try std.testing.expectEqual(@as(u64, 1), id);
                self.invocations += 1;
            },
            .set_focus => {},
            .set_value => |value| {
                try std.testing.expectEqual(@as(u64, 2), value.id);
                _ = try self.buffer.replaceRange(.{ .start = 0, .end = self.buffer.text().len }, value.text);
                _ = try self.buffer.selectAll();
            },
            .select_text => |selected| {
                try std.testing.expectEqual(@as(u64, 2), selected.id);
                _ = try self.buffer.setSelection(.{ .anchor = try self.buffer.byteOffsetFromUtf16(selected.start_utf16), .caret = try self.buffer.byteOffsetFromUtf16(selected.end_utf16) });
            },
            .set_range => return error.UnexpectedAction,
        }
        try self.publish();
    }
    fn object(ptr: *anyopaque, window: z.Window, wp: usize, lp: isize) ?isize {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.bridge.getObject(window, wp, lp);
    }
    fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
    fn detach(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.bridge.detach();
    }
    fn detachBridge(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.bridge.detach();
        self.bridge_detached = true;
    }
    fn finish(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn worker(self: *State, hwnd: c.HWND) void {
        self.client(hwnd) catch |err| {
            self.client_err = err;
            std.debug.print("UI Automation client failed: {s}\n", .{@errorName(err)});
        };
        self.app.post(.{ .context = self, .call = finish }) catch {};
    }
    fn client(_: *State, hwnd: c.HWND) !void {
        try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var automation: ?*c.IUIAutomation = null;
        try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&automation)));
        const client_api = automation.?;
        defer _ = client_api.lpVtbl.*.Release.?(client_api);
        var automation2: ?*c.IUIAutomation2 = null;
        try check(client_api.lpVtbl.*.QueryInterface.?(client_api, &c.IID_IUIAutomation2, @ptrCast(&automation2)));
        defer _ = automation2.?.lpVtbl.*.Release.?(automation2.?);
        try check(automation2.?.lpVtbl.*.put_ConnectionTimeout.?(automation2.?, 2000));
        try check(automation2.?.lpVtbl.*.put_TransactionTimeout.?(automation2.?, 2000));
        var root: ?*c.IUIAutomationElement = null;
        try check(client_api.lpVtbl.*.ElementFromHandle.?(client_api, hwnd, &root));
        defer _ = root.?.lpVtbl.*.Release.?(root.?);
        try expectName(root.?, "Accessibility smoke");
        var condition: ?*c.IUIAutomationCondition = null;
        try check(client_api.lpVtbl.*.CreateTrueCondition.?(client_api, &condition));
        defer _ = condition.?.lpVtbl.*.Release.?(condition.?);
        var children: ?*c.IUIAutomationElementArray = null;
        try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &children));
        defer _ = children.?.lpVtbl.*.Release.?(children.?);
        var length: c_int = 0;
        try check(children.?.lpVtbl.*.get_Length.?(children.?, &length));
        var button: ?*c.IUIAutomationElement = null;
        var input: ?*c.IUIAutomationElement = null;
        defer {
            if (button) |element| _ = element.lpVtbl.*.Release.?(element);
        }
        defer {
            if (input) |element| _ = element.lpVtbl.*.Release.?(element);
        }
        var index: c_int = 0;
        while (index < length) : (index += 1) {
            var candidate: ?*c.IUIAutomationElement = null;
            try check(children.?.lpVtbl.*.GetElement.?(children.?, index, &candidate));
            var name: c.BSTR = null;
            try check(candidate.?.lpVtbl.*.get_CurrentName.?(candidate.?, &name));
            defer c.SysFreeString(name);
            if (wideEqual(name, "Apply")) button = candidate else if (wideEqual(name, "Document")) input = candidate else _ = candidate.?.lpVtbl.*.Release.?(candidate.?);
        }
        try std.testing.expect(button != null and input != null);
        var role: c.CONTROLTYPEID = 0;
        try check(button.?.lpVtbl.*.get_CurrentControlType.?(button.?, &role));
        try std.testing.expectEqual(c.UIA_ButtonControlTypeId, role);
        try check(input.?.lpVtbl.*.get_CurrentControlType.?(input.?, &role));
        try std.testing.expectEqual(c.UIA_EditControlTypeId, role);

        var invoke: ?*c.IUIAutomationInvokePattern = null;
        try check(button.?.lpVtbl.*.GetCurrentPatternAs.?(button.?, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&invoke)));
        defer _ = invoke.?.lpVtbl.*.Release.?(invoke.?);
        try check(invoke.?.lpVtbl.*.Invoke.?(invoke.?));
        var value: ?*c.IUIAutomationValuePattern = null;
        try check(input.?.lpVtbl.*.GetCurrentPatternAs.?(input.?, c.UIA_ValuePatternId, &c.IID_IUIAutomationValuePattern, @ptrCast(&value)));
        defer _ = value.?.lpVtbl.*.Release.?(value.?);
        const new_value = c.SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("中文😀"));
        if (new_value == null) return error.OutOfMemory;
        defer c.SysFreeString(new_value);
        try check(value.?.lpVtbl.*.SetValue.?(value.?, new_value));
        var actual: c.BSTR = null;
        try check(value.?.lpVtbl.*.get_CurrentValue.?(value.?, &actual));
        try std.testing.expect(wideEqual(actual, "中文😀"));
        c.SysFreeString(actual);

        var text: ?*c.IUIAutomationTextPattern = null;
        try check(input.?.lpVtbl.*.GetCurrentPatternAs.?(input.?, c.UIA_TextPatternId, &c.IID_IUIAutomationTextPattern, @ptrCast(&text)));
        defer _ = text.?.lpVtbl.*.Release.?(text.?);
        var document: ?*c.IUIAutomationTextRange = null;
        try check(text.?.lpVtbl.*.get_DocumentRange.?(text.?, &document));
        defer _ = document.?.lpVtbl.*.Release.?(document.?);
        try check(document.?.lpVtbl.*.GetText.?(document.?, -1, &actual));
        try std.testing.expect(wideEqual(actual, "中文😀"));
        c.SysFreeString(actual);
        var moved: c_int = 0;
        try check(document.?.lpVtbl.*.MoveEndpointByUnit.?(document.?, c.TextPatternRangeEndpoint_Start, c.TextUnit_Character, 1, &moved));
        try std.testing.expectEqual(@as(c_int, 1), moved);
        try check(document.?.lpVtbl.*.Select.?(document.?));
        var ranges: ?*c.IUIAutomationTextRangeArray = null;
        try check(text.?.lpVtbl.*.GetSelection.?(text.?, &ranges));
        defer _ = ranges.?.lpVtbl.*.Release.?(ranges.?);
        var selected: ?*c.IUIAutomationTextRange = null;
        try check(ranges.?.lpVtbl.*.GetElement.?(ranges.?, 0, &selected));
        defer _ = selected.?.lpVtbl.*.Release.?(selected.?);
        try check(selected.?.lpVtbl.*.GetText.?(selected.?, -1, &actual));
        try std.testing.expect(wideEqual(actual, "文😀"));
        c.SysFreeString(actual);

        try std.testing.expectEqual(@as(c.LRESULT, 1), c.SendMessageW(hwnd, detach_message, 0, 0));
        actual = null;
        const stale_value = value.?.lpVtbl.*.get_CurrentValue.?(value.?, &actual);
        const stale_value_length = c.SysStringLen(actual);
        c.SysFreeString(actual);
        actual = null;
        const stale_range = selected.?.lpVtbl.*.GetText.?(selected.?, -1, &actual);
        const stale_range_length = c.SysStringLen(actual);
        c.SysFreeString(actual);
        const stale_invoke = invoke.?.lpVtbl.*.Invoke.?(invoke.?);
        // The client property API maps an unavailable Value to its empty
        // default; action and range calls retain the provider's native error.
        try std.testing.expectEqual(@as(c.HRESULT, 0), stale_value);
        try std.testing.expectEqual(@as(c_uint, 0), stale_value_length);
        try std.testing.expectEqual(@as(u32, c.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(stale_range)));
        try std.testing.expectEqual(@as(c_uint, 0), stale_range_length);
        try std.testing.expectEqual(@as(u32, c.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(stale_invoke)));
    }
};

fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("UI Automation HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
fn wideEqual(text: c.BSTR, comptime expected: []const u8) bool {
    const wanted = std.unicode.utf8ToUtf16LeStringLiteral(expected);
    return text != null and std.mem.eql(u16, text[0..c.SysStringLen(text)], wanted[0..wanted.len]);
}
fn expectName(element: *c.IUIAutomationElement, comptime expected: []const u8) !void {
    var name: c.BSTR = null;
    try check(element.lpVtbl.*.get_CurrentName.?(element, &name));
    defer c.SysFreeString(name);
    try std.testing.expect(wideEqual(name, expected));
}

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    var state: State = .{ .buffer = try ui.text_buffer.TextBuffer.init(allocator.allocator(), .{ .max_bytes = 128, .undo_entries = 8, .undo_bytes = 256, .composition_bytes = 32 }, "Initial") };
    defer state.buffer.deinit();
    var diagnostics: z.diagnostics.Recorder(16) = .{};
    state.bridge = access.Bridge.init(&state, State.action);
    var retained: ?*c.IValueProvider = null;
    var retained_native_state: ?*anyopaque = null;
    defer {
        if (retained) |provider| _ = provider.lpVtbl.*.Release.?(provider);
    }
    {
        state.app = try z.App.initWithOptions(allocator.allocator(), .{ .diagnostics_sink = diagnostics.sink() });
        defer state.app.deinit();
        state.window = try state.app.createWindow(.{ .title = "Accessibility smoke" });
        subclass_state = &state;
        defer subclass_state = null;
        const previous = c.SetWindowLongPtrW(state.window.nativeHandle(), c.GWLP_WNDPROC, @bitCast(@intFromPtr(&subclass)));
        if (previous == 0) return error.SubclassFailed;
        original_proc = @ptrFromInt(@as(usize, @bitCast(previous)));
        try state.bridge.attach(state.window);
        retained_native_state = state.bridge.native;
        errdefer state.bridge.detach();
        try state.window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach, .accessibility = State.object });
        try state.publish();
        const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try state.bridge.retainProvider(2)));
        defer _ = simple.lpVtbl.*.Release.?(simple);
        try check(simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IValueProvider, @ptrCast(&retained)));
        var watchdog: Watchdog = .{ .app = state.app };
        try watchdog.start();
        defer watchdog.stop();
        const worker = try std.Thread.spawn(.{}, State.worker, .{ &state, @as(c.HWND, @ptrCast(state.window.nativeHandle())) });
        try state.app.run();
        watchdog.stop();
        worker.join();
        try std.testing.expect(!watchdog.expired);
        try std.testing.expect(state.err == null);
        try std.testing.expect(state.client_err == null);
        try std.testing.expect(state.bridge_detached and state.cleanup_deferred_inside_send);
        try std.testing.expectEqual(1, state.invocations);
        try std.testing.expectEqualStrings("中文😀", state.buffer.text());
        try std.testing.expectEqual(ui.text_buffer.Selection{ .anchor = 3, .caret = 10 }, state.buffer.selection());
    }
    // App and the attached Zig/native context have gone. The independently
    // retained provider must reject a late COM getter without visiting either.
    try std.testing.expectEqual(@as(isize, 0), zua_get_object(retained_native_state.?, 0, -25));
    var stale: c.BSTR = null;
    const late = retained.?.lpVtbl.*.get_Value.?(retained.?, &stale);
    c.SysFreeString(stale);
    try std.testing.expectEqual(@as(u32, c.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(late)));
    _ = retained.?.lpVtbl.*.Release.?(retained.?);
    retained = null;
    const counts = access.resourceCounts();
    var diagnostic_items: [16]z.diagnostics.Diagnostic = undefined;
    const snapshot = diagnostics.snapshot(&diagnostic_items);
    for (diagnostic_items[0..snapshot.count]) |item| if (item.err) |err| {
        if (err == error.AccessibilityDisconnectFailed) std.debug.print("UIA disconnect diagnostic: {any}\n", .{item});
        try std.testing.expect(err != error.AccessibilityDisconnectFailed);
    };
    if (counts.states != 0 or counts.providers != 0 or counts.ranges != 0 or counts.actions != 0) std.debug.print("UIA native resources after teardown: {any}\n", .{counts});
    try std.testing.expectEqual(access.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, counts);
    std.debug.print("accessibility smoke passed: real MTA UI Automation Name/Role/Invoke/Value/TextSelection, detached references unavailable, native resources=0\n", .{});
}
