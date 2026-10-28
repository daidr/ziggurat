const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const Watchdog = @import("watchdog.zig").Watchdog;
extern fn zua_test_provider_status(*anyopaque, u64, c_int) i32;
const c = @import("ziggurat_c_win32");
fn rect(y: f32) ui.Rect {
    return .{ .x = 0, .y = y, .width = 180, .height = 32 };
}
const State = struct {
    app: *z.App,
    context: *ui.Context = undefined,
    window: z.Window = undefined,
    checked: bool = false,
    switched: bool = false,
    selected: u64 = 4,
    include_removed: bool = true,
    include_patterns: bool = true,
    fail_frame: bool = false,
    nested_paint: bool = false,
    nested_once: bool = false,
    draws: usize = 0,
    switch_enabled: bool = true,
    close_on_switch: bool = false,
    callback_pinned: bool = false,
    actions: [10]usize = @splat(0),
    err: ?anyerror = null,
    client_err: ?anyerror = null,
    fence: c.HANDLE = null,
    retained_progress: ?*c.IRangeValueProvider = null,

    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        if (self.nested_paint and !self.nested_once) {
            self.nested_once = true;
            const hwnd: c.HWND = self.window.nativeHandle();
            _ = c.InvalidateRect(hwnd, null, 0);
            _ = c.UpdateWindow(hwnd);
            // Hidden windows can suppress UpdateWindow; deliver the native
            // paint synchronously to exercise the same callback reentry.
            _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
        }
        self.drawChecked(frame) catch |err| {
            self.err = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try frame.button(1, rect(0), "Button");
        if (self.include_patterns) try frame.checkbox(2, rect(40), "Checkbox", self.checked, .{});
        try frame.checkbox(3, rect(80), "Disabled", true, .{ .enabled = false });
        if (self.include_patterns) {
            try frame.radioGroup(10, .{ .x = 0, .y = 120, .width = 180, .height = 72 }, "Mode");
            try frame.radio(4, rect(120), "First", self.selected == 4, .{ .radio_group = 10 });
            try frame.radio(5, rect(160), "Second", self.selected == 5, .{ .radio_group = 10 });
        }
        try frame.toggleSwitch(6, rect(200), "Switch", self.switched, .{ .enabled = self.switch_enabled });
        if (self.include_patterns) try frame.progress(7, rect(240), 0.35, .{ .name = "Progress" });
        try frame.pushClip(.{ .x = 0, .y = 280, .width = 180, .height = 0 });
        try frame.checkbox(8, rect(280), "Clipped", false, .{});
        try frame.popClip();
        if (self.include_removed) try frame.checkbox(9, rect(320), "Removed", false, .{});
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        if (id >= self.actions.len) {
            self.err = error.UnexpectedAction;
            return;
        }
        self.actions[@intCast(id)] += 1;
        switch (id) {
            2 => self.checked = !self.checked,
            4, 5 => self.selected = id,
            6 => {
                self.switched = !self.switched;
                if (self.close_on_switch) {
                    _ = self.window.destroy() catch |err| {
                        self.err = err;
                        return;
                    };
                    self.callback_pinned = self.window.isClosed() and self.context.window != null;
                }
            },
            1, 9 => {},
            else => self.err = error.UnexpectedAction,
        }
    }
    fn publishFence(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        paint(self.window.nativeHandle());
        _ = c.SetEvent(self.fence);
    }
    fn closeFence(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        _ = self.window.destroy() catch |err| {
            self.err = err;
        };
        _ = c.SetEvent(self.fence);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn synchronize(self: *State, close: bool) !void {
        _ = c.ResetEvent(self.fence);
        try self.app.post(.{ .context = self, .call = if (close) closeFence else publishFence });
        if (c.WaitForSingleObject(self.fence, 5000) != c.WAIT_OBJECT_0) return error.FenceTimeout;
    }
    fn worker(self: *State, hwnd: c.HWND) void {
        self.client(hwnd) catch |err| {
            self.client_err = err;
            std.debug.print("widgets UIA client failed: {s}\n", .{@errorName(err)});
        };
        self.app.post(.{ .context = self, .call = finish }) catch {};
    }
    fn client(self: *State, hwnd: c.HWND) !void {
        try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var api: ?*c.IUIAutomation = null;
        try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&api)));
        defer _ = api.?.lpVtbl.*.Release.?(api.?);
        var root: ?*c.IUIAutomationElement = null;
        try check(api.?.lpVtbl.*.ElementFromHandle.?(api.?, hwnd, &root));
        defer _ = root.?.lpVtbl.*.Release.?(root.?);
        var condition: ?*c.IUIAutomationCondition = null;
        try check(api.?.lpVtbl.*.CreateTrueCondition.?(api.?, &condition));
        defer _ = condition.?.lpVtbl.*.Release.?(condition.?);
        var elements: ?*c.IUIAutomationElementArray = null;
        try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &elements));
        defer _ = elements.?.lpVtbl.*.Release.?(elements.?);
        var length: c_int = 0;
        try check(elements.?.lpVtbl.*.get_Length.?(elements.?, &length));
        var found: [11]?*c.IUIAutomationElement = @splat(null);
        defer {
            for (found) |element| if (element) |value| {
                _ = value.lpVtbl.*.Release.?(value);
            };
        }
        var i: c_int = 0;
        while (i < length) : (i += 1) {
            var element: ?*c.IUIAutomationElement = null;
            try check(elements.?.lpVtbl.*.GetElement.?(elements.?, i, &element));
            var identity: c.BSTR = null;
            try check(element.?.lpVtbl.*.get_CurrentAutomationId.?(element.?, &identity));
            defer c.SysFreeString(identity);
            const id: usize = if (c.SysStringLen(identity) == 1 and identity[0] >= '1' and identity[0] <= '9') identity[0] - '0' else if (c.SysStringLen(identity) == 2 and identity[0] == '1' and identity[1] == '0') 10 else 0;
            if (id > 0 and id < found.len) found[id] = element else _ = element.?.lpVtbl.*.Release.?(element.?);
        }
        try std.testing.expect(found[2] != null and found[3] != null and found[5] != null and found[6] != null and found[7] != null and found[10] != null);
        try role(found[2].?, c.UIA_CheckBoxControlTypeId);
        try role(found[5].?, c.UIA_RadioButtonControlTypeId);
        try role(found[6].?, c.UIA_CheckBoxControlTypeId);
        try role(found[7].?, c.UIA_ProgressBarControlTypeId);
        var toggle: ?*c.IUIAutomationTogglePattern = null;
        try check(found[2].?.lpVtbl.*.GetCurrentPatternAs.?(found[2].?, c.UIA_TogglePatternId, &c.IID_IUIAutomationTogglePattern, @ptrCast(&toggle)));
        defer _ = toggle.?.lpVtbl.*.Release.?(toggle.?);
        try check(toggle.?.lpVtbl.*.Toggle.?(toggle.?));
        var switch_pattern: ?*c.IUIAutomationTogglePattern = null;
        try check(found[6].?.lpVtbl.*.GetCurrentPatternAs.?(found[6].?, c.UIA_TogglePatternId, &c.IID_IUIAutomationTogglePattern, @ptrCast(&switch_pattern)));
        defer _ = switch_pattern.?.lpVtbl.*.Release.?(switch_pattern.?);
        try check(switch_pattern.?.lpVtbl.*.Toggle.?(switch_pattern.?));
        var selection: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(found[5].?.lpVtbl.*.GetCurrentPatternAs.?(found[5].?, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&selection)));
        defer _ = selection.?.lpVtbl.*.Release.?(selection.?);
        try check(selection.?.lpVtbl.*.Select.?(selection.?));
        try self.synchronize(false);
        var checked: c.enum_ToggleState = 0;
        try check(toggle.?.lpVtbl.*.get_CurrentToggleState.?(toggle.?, &checked));
        try std.testing.expectEqual(@as(c.enum_ToggleState, c.ToggleState_On), checked);
        try check(switch_pattern.?.lpVtbl.*.get_CurrentToggleState.?(switch_pattern.?, &checked));
        try std.testing.expectEqual(@as(c.enum_ToggleState, c.ToggleState_On), checked);
        var selected: c.BOOL = 0;
        try check(selection.?.lpVtbl.*.get_CurrentIsSelected.?(selection.?, &selected));
        try std.testing.expect(selected != 0);
        var group: ?*c.IUIAutomationSelectionPattern = null;
        try check(found[10].?.lpVtbl.*.GetCurrentPatternAs.?(found[10].?, c.UIA_SelectionPatternId, &c.IID_IUIAutomationSelectionPattern, @ptrCast(&group)));
        defer _ = group.?.lpVtbl.*.Release.?(group.?);
        var selected_elements: ?*c.IUIAutomationElementArray = null;
        try check(group.?.lpVtbl.*.GetCurrentSelection.?(group.?, &selected_elements));
        defer _ = selected_elements.?.lpVtbl.*.Release.?(selected_elements.?);
        try check(selected_elements.?.lpVtbl.*.get_Length.?(selected_elements.?, &length));
        try std.testing.expectEqual(@as(c_int, 1), length);
        var disabled: ?*c.IUIAutomationTogglePattern = null;
        try check(found[3].?.lpVtbl.*.GetCurrentPatternAs.?(found[3].?, c.UIA_TogglePatternId, &c.IID_IUIAutomationTogglePattern, @ptrCast(&disabled)));
        defer _ = disabled.?.lpVtbl.*.Release.?(disabled.?);
        try expectHr(c.UIA_E_ELEMENTNOTENABLED, disabled.?.lpVtbl.*.Toggle.?(disabled.?));
        var progress: ?*c.IUIAutomationRangeValuePattern = null;
        try check(found[7].?.lpVtbl.*.GetCurrentPatternAs.?(found[7].?, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&progress)));
        defer _ = progress.?.lpVtbl.*.Release.?(progress.?);
        var amount: f64 = 0;
        try check(progress.?.lpVtbl.*.get_CurrentValue.?(progress.?, &amount));
        try std.testing.expectApproxEqAbs(@as(f64, 35), amount, 0.001);
        var readonly: c.BOOL = 0;
        try check(progress.?.lpVtbl.*.get_CurrentIsReadOnly.?(progress.?, &readonly));
        try std.testing.expect(readonly != 0);
        try expectHr(c.UIA_E_INVALIDOPERATION, progress.?.lpVtbl.*.SetValue.?(progress.?, 50));
        try self.synchronize(true);
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, toggle.?.lpVtbl.*.Toggle.?(toggle.?));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, selection.?.lpVtbl.*.Select.?(selection.?));
        // The client retains read-only metadata and still rejects SetValue.
        // Check the independently retained native provider for disconnection.
        try expectHr(c.UIA_E_INVALIDOPERATION, progress.?.lpVtbl.*.SetValue.?(progress.?, 50));
        const retained = self.retained_progress.?;
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, retained.lpVtbl.*.get_Value.?(retained, &amount));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, retained.lpVtbl.*.SetValue.?(retained, 50));
    }
};
fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("widget HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
fn expectHr(expected: u32, actual: c.HRESULT) !void {
    try std.testing.expectEqual(expected, @as(u32, @bitCast(actual)));
}
fn role(element: *c.IUIAutomationElement, expected: c.CONTROLTYPEID) !void {
    var actual: c.CONTROLTYPEID = 0;
    try check(element.lpVtbl.*.get_CurrentControlType.?(element, &actual));
    try std.testing.expectEqual(expected, actual);
}
fn paint(hwnd: c.HWND) void {
    _ = c.InvalidateRect(hwnd, null, 0);
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
}
fn pointer(hwnd: c.HWND, message: c.UINT, y: c_int) void {
    const dpi: c_int = @intCast(c.GetDpiForWindow(hwnd));
    const point: c.LPARAM = (@as(c.LPARAM, c.MulDiv(y + 10, dpi, 96)) << 16) | @as(c.LPARAM, c.MulDiv(10, dpi, 96));
    _ = c.SendMessageW(hwnd, message, 0, point);
}
fn click(hwnd: c.HWND, y: c_int) void {
    pointer(hwnd, c.WM_LBUTTONDOWN, y);
    pointer(hwnd, c.WM_LBUTTONUP, y);
}
fn key(hwnd: c.HWND, code: c.WPARAM) void {
    _ = c.SendMessageW(hwnd, c.WM_KEYDOWN, code, 0);
}
const RetainedPatterns = struct {
    toggle: *c.IToggleProvider,
    radio: *c.ISelectionItemProvider,
    group: *c.ISelectionProvider,
    progress: *c.IRangeValueProvider,
    fn retain(comptime Interface: type, context: *ui.Context, id: u64, iid: *const c.GUID) !*Interface {
        const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try context.accessibility_bridge.retainProvider(id)));
        defer _ = simple.lpVtbl.*.Release.?(simple);
        var result: ?*Interface = null;
        try check(simple.lpVtbl.*.QueryInterface.?(simple, iid, @ptrCast(&result)));
        return result.?;
    }
    fn init(context: *ui.Context) !RetainedPatterns {
        const toggle = try retain(c.IToggleProvider, context, 2, &c.IID_IToggleProvider);
        errdefer _ = toggle.lpVtbl.*.Release.?(toggle);
        const radio = try retain(c.ISelectionItemProvider, context, 5, &c.IID_ISelectionItemProvider);
        errdefer _ = radio.lpVtbl.*.Release.?(radio);
        const group = try retain(c.ISelectionProvider, context, 10, &c.IID_ISelectionProvider);
        errdefer _ = group.lpVtbl.*.Release.?(group);
        return .{ .toggle = toggle, .radio = radio, .group = group, .progress = try retain(c.IRangeValueProvider, context, 7, &c.IID_IRangeValueProvider) };
    }
    fn release(self: RetainedPatterns) void {
        _ = self.toggle.lpVtbl.*.Release.?(self.toggle);
        _ = self.radio.lpVtbl.*.Release.?(self.radio);
        _ = self.group.lpVtbl.*.Release.?(self.group);
        _ = self.progress.lpVtbl.*.Release.?(self.progress);
    }
    fn queryAgain(ptr: anytype, iid: *const c.GUID) !void {
        const unknown: *c.IUnknown = @ptrCast(ptr);
        var queried: ?*c.IUnknown = null;
        try check(unknown.lpVtbl.*.QueryInterface.?(unknown, iid, @ptrCast(&queried)));
        defer _ = queried.?.lpVtbl.*.Release.?(queried.?);
        try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(queried.?));
    }
    fn unavailable(self: RetainedPatterns) !void {
        try queryAgain(self.toggle, &c.IID_IToggleProvider);
        try queryAgain(self.radio, &c.IID_ISelectionItemProvider);
        try queryAgain(self.group, &c.IID_ISelectionProvider);
        try queryAgain(self.progress, &c.IID_IRangeValueProvider);
        var checked: c.enum_ToggleState = 0;
        var selected: c.BOOL = 0;
        var elements: ?*c.SAFEARRAY = null;
        var value: f64 = 0;
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.toggle.lpVtbl.*.get_ToggleState.?(self.toggle, &checked));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.toggle.lpVtbl.*.Toggle.?(self.toggle));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.radio.lpVtbl.*.get_IsSelected.?(self.radio, &selected));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.radio.lpVtbl.*.Select.?(self.radio));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.group.lpVtbl.*.GetSelection.?(self.group, &elements));
        try std.testing.expect(elements == null);
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.progress.lpVtbl.*.get_Value.?(self.progress, &value));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, self.progress.lpVtbl.*.SetValue.?(self.progress, 50));
    }
};
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = .gdi;
    state.context = &context;
    state.window = try app.createWindow(.{ .width = 220, .height = 380 });
    try context.attach(state.window);
    const hwnd: c.HWND = state.window.nativeHandle();
    paint(hwnd);
    const draws = state.draws;
    const command_count = context.command_buffer.len;
    state.nested_paint = true;
    paint(hwnd);
    try std.testing.expectEqual(draws + 1, state.draws);
    try std.testing.expectEqual(@as(usize, 9), context.input_state.len);
    try std.testing.expectEqual(command_count, context.command_buffer.len);
    try context.command_buffer.finish();
    try std.testing.expect(!context.painting and !context.repaint_pending);
    try std.testing.expect(state.err == null);
    state.nested_paint = false;
    click(hwnd, 40);
    click(hwnd, 40);
    click(hwnd, 40);
    try std.testing.expect(state.checked and state.actions[2] == 3);
    click(hwnd, 80);
    click(hwnd, 240);
    click(hwnd, 280);
    try std.testing.expectEqual(@as(usize, 0), state.actions[3] + state.actions[7] + state.actions[8]);
    click(hwnd, 40);
    key(hwnd, c.VK_TAB);
    try std.testing.expectEqual(@as(?u64, 4), context.input_state.focused);
    key(hwnd, c.VK_RIGHT);
    try std.testing.expectEqual(@as(u64, 5), state.selected);
    key(hwnd, c.VK_HOME);
    try std.testing.expectEqual(@as(u64, 4), state.selected);
    key(hwnd, c.VK_END);
    try std.testing.expectEqual(@as(u64, 5), state.selected);
    key(hwnd, c.VK_TAB);
    try std.testing.expectEqual(@as(?u64, 6), context.input_state.focused);
    key(hwnd, c.VK_SPACE);
    try std.testing.expect(state.switched);
    key(hwnd, c.VK_TAB);
    try std.testing.expectEqual(@as(?u64, 9), context.input_state.focused);
    state.include_removed = false;
    state.fail_frame = true;
    paint(hwnd);
    try std.testing.expect(context.input_state.available(9));
    state.include_removed = true;
    state.fail_frame = false;
    paint(hwnd);
    pointer(hwnd, c.WM_LBUTTONDOWN, 320);
    state.include_removed = false;
    paint(hwnd);
    pointer(hwnd, c.WM_LBUTTONUP, 320);
    key(hwnd, c.VK_SPACE);
    try std.testing.expectEqual(@as(usize, 0), state.actions[9]);
    pointer(hwnd, c.WM_LBUTTONDOWN, 200);
    state.switch_enabled = false;
    paint(hwnd);
    pointer(hwnd, c.WM_LBUTTONUP, 200);
    try std.testing.expectEqual(@as(usize, 1), state.actions[6]);
    var retained: ?RetainedPatterns = null;
    var retained_native_state: ?*anyopaque = null;
    defer if (retained) |patterns| {
        patterns.release();
    };
    if (ui.capabilities.accessibility) {
        retained = try RetainedPatterns.init(&context);
        retained_native_state = context.accessibility_bridge.native;
        const counts_before = ui.accessibility.resourceCounts();
        try check(zua_test_provider_status(retained_native_state.?, 2, 0));
        try expectHr(@as(u32, @bitCast(@as(i32, c.E_OUTOFMEMORY))), zua_test_provider_status(retained_native_state.?, 2, 1));
        try std.testing.expectEqual(counts_before, ui.accessibility.resourceCounts());
        state.include_patterns = false;
        paint(hwnd);
        try retained.?.unavailable();
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, zua_test_provider_status(retained_native_state.?, 2, 0));
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, zua_test_provider_status(retained_native_state.?, 2, 1));
    }
    state.switch_enabled = true;
    state.close_on_switch = true;
    paint(hwnd);
    click(hwnd, 200);
    try app.dispatch();
    try std.testing.expect(state.callback_pinned and context.window == null);
    try std.testing.expect(!context.painting and !context.repaint_pending);
    if (ui.capabilities.accessibility) if (retained) |patterns| {
        try patterns.unavailable();
        try expectHr(c.UIA_E_ELEMENTNOTAVAILABLE, zua_test_provider_status(retained_native_state.?, 0, 0));
        patterns.release();
        retained = null;
        try app.dispatch();
        try std.testing.expectEqual(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
    };
    try std.testing.expect(state.err == null);
    std.debug.print("widgets native smoke passed: pointer/keyboard, radio groups, disabled/clipped/removed controls and close reentry\n", .{});
    if (ui.capabilities.accessibility) {
        state = .{ .app = app };
        context = ui.Context.init(&state, State.draw, State.action);
        context.render_mode = .gdi;
        state.context = &context;
        state.window = try app.createWindow(.{ .width = 220, .height = 380 });
        try context.attach(state.window);
        paint(state.window.nativeHandle());
        const native: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try context.accessibility_bridge.retainProvider(7)));
        defer _ = native.lpVtbl.*.Release.?(native);
        try check(native.lpVtbl.*.QueryInterface.?(native, &c.IID_IRangeValueProvider, @ptrCast(&state.retained_progress)));
        defer _ = state.retained_progress.?.lpVtbl.*.Release.?(state.retained_progress.?);
        state.fence = c.CreateEventW(null, 1, 0, null) orelse return error.EventCreationFailed;
        defer _ = c.CloseHandle(state.fence);
        var watchdog: Watchdog = .{ .app = app };
        try watchdog.start();
        defer watchdog.stop();
        const thread = try std.Thread.spawn(.{}, State.worker, .{ &state, @as(c.HWND, state.window.nativeHandle()) });
        defer thread.join();
        try app.run();
        try std.testing.expect(!watchdog.expired);
        try std.testing.expect(state.client_err == null and state.err == null);
        try std.testing.expect(state.checked and state.switched and state.selected == 5);
        std.debug.print("widgets UIA smoke passed: real client Toggle/SelectionItem/Selection/RangeValue and stale provider safety\n", .{});
    }
}
