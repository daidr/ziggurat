const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shared = @import("widget_ranges_shared.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("range UIA HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
fn expected(hr: c.HRESULT, actual: c.HRESULT) !void {
    try std.testing.expectEqual(hr, actual);
}
fn paint(window: z.Window) void {
    _ = c.InvalidateRect(window.nativeHandle(), null, 0);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
}
const Client = struct {
    app: *z.App,
    state: *shared.State,
    hwnd: c.HWND,
    fence: c.HANDLE,
    stage: enum { publish, disable, remove, close } = .publish,
    err: ?anyerror = null,
    retained: [3]*c.IRangeValueProvider,
    fn synchronize(self: *Client, stage: @FieldType(Client, "stage")) !void {
        self.stage = stage;
        _ = c.ResetEvent(self.fence);
        try self.app.post(.{ .context = self, .call = update });
        if (c.WaitForSingleObject(self.fence, 5000) != c.WAIT_OBJECT_0) return error.FenceTimeout;
    }
    fn update(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        switch (self.stage) {
            .publish => {},
            .disable => self.state.slider_enabled = false,
            .remove => self.state.include_slider = false,
            .close => {
                _ = self.state.window.destroy() catch unreachable;
                return;
            },
        }
        if (self.stage != .close) paint(self.state.window);
        _ = c.SetEvent(self.fence);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.app.quit();
    }
    fn signalClosed(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        _ = c.SetEvent(self.fence);
    }
    fn worker(self: *Client) void {
        self.run() catch |err| {
            self.err = err;
        };
        self.app.post(.{ .context = self, .call = finish }) catch {};
    }
    fn run(self: *Client) !void {
        try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var api: ?*c.IUIAutomation = null;
        try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&api)));
        defer _ = api.?.lpVtbl.*.Release.?(api.?);
        var root: ?*c.IUIAutomationElement = null;
        try check(api.?.lpVtbl.*.ElementFromHandle.?(api.?, self.hwnd, &root));
        defer _ = root.?.lpVtbl.*.Release.?(root.?);
        var condition: ?*c.IUIAutomationCondition = null;
        try check(api.?.lpVtbl.*.CreateTrueCondition.?(api.?, &condition));
        defer _ = condition.?.lpVtbl.*.Release.?(condition.?);
        var elements: ?*c.IUIAutomationElementArray = null;
        try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &elements));
        defer _ = elements.?.lpVtbl.*.Release.?(elements.?);
        var length: c_int = 0;
        try check(elements.?.lpVtbl.*.get_Length.?(elements.?, &length));
        var patterns: [27]?*c.IUIAutomationRangeValuePattern = @splat(null);
        defer for (patterns) |maybe| {
            if (maybe) |value| _ = value.lpVtbl.*.Release.?(value);
        };
        var index: c_int = 0;
        while (index < length) : (index += 1) {
            var element: ?*c.IUIAutomationElement = null;
            try check(elements.?.lpVtbl.*.GetElement.?(elements.?, index, &element));
            defer _ = element.?.lpVtbl.*.Release.?(element.?);
            var identity: c.BSTR = null;
            try check(element.?.lpVtbl.*.get_CurrentAutomationId.?(element.?, &identity));
            defer c.SysFreeString(identity);
            if (c.SysStringLen(identity) != 2 or identity[0] != '2' or identity[1] < '0' or identity[1] > '6' or identity[1] == '3') continue;
            const id: usize = 20 + identity[1] - '0';
            var role: c.CONTROLTYPEID = 0;
            try check(element.?.lpVtbl.*.get_CurrentControlType.?(element.?, &role));
            try std.testing.expectEqual(@as(c.CONTROLTYPEID, if (id == 24) c.UIA_SpinnerControlTypeId else c.UIA_SliderControlTypeId), role);
            try check(element.?.lpVtbl.*.GetCurrentPatternAs.?(element.?, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&patterns[id])));
        }
        for ([_]usize{ 20, 21, 22, 24, 25, 26 }) |id| try std.testing.expect(patterns[id] != null);
        const slider = patterns[20].?;
        const low = patterns[21].?;
        const high = patterns[22].?;
        const stepper = patterns[24].?;
        var value: f64 = 0;
        var readonly: c.BOOL = 1;
        try check(slider.lpVtbl.*.get_CurrentMinimum.?(slider, &value));
        try std.testing.expectEqual(@as(f64, 0), value);
        try check(slider.lpVtbl.*.get_CurrentMaximum.?(slider, &value));
        try std.testing.expectEqual(@as(f64, 100), value);
        try check(slider.lpVtbl.*.get_CurrentSmallChange.?(slider, &value));
        try std.testing.expectEqual(@as(f64, 5), value);
        try check(slider.lpVtbl.*.get_CurrentLargeChange.?(slider, &value));
        try std.testing.expectEqual(@as(f64, 20), value);
        try check(slider.lpVtbl.*.get_CurrentIsReadOnly.?(slider, &readonly));
        try std.testing.expectEqual(@as(c.BOOL, 0), readonly);
        try expected(@bitCast(c.UIA_E_ELEMENTNOTENABLED), patterns[26].?.lpVtbl.*.SetValue.?(patterns[26].?, 50));
        try expected(c.E_INVALIDARG, low.lpVtbl.*.SetValue.?(low, 80));
        try check(slider.lpVtbl.*.SetValue.?(slider, 63));
        try check(stepper.lpVtbl.*.SetValue.?(stepper, 7));
        try check(low.lpVtbl.*.SetValue.?(low, 60));
        try self.synchronize(.publish);
        try check(slider.lpVtbl.*.get_CurrentValue.?(slider, &value));
        try std.testing.expectEqual(@as(f64, 65), value);
        try check(stepper.lpVtbl.*.get_CurrentValue.?(stepper, &value));
        try std.testing.expectEqual(@as(f64, 7), value);
        try check(high.lpVtbl.*.get_CurrentMinimum.?(high, &value));
        try std.testing.expectEqual(@as(f64, 60), value);
        try expected(c.E_INVALIDARG, high.lpVtbl.*.SetValue.?(high, 55));
        try self.synchronize(.disable);
        try expected(@bitCast(c.UIA_E_ELEMENTNOTENABLED), slider.lpVtbl.*.SetValue.?(slider, 50));
        try self.synchronize(.remove);
        unavailable(self.retained[0]) catch |err| {
            std.debug.print("removed range provider remained available\n", .{});
            return err;
        };
        try self.synchronize(.close);
        for (self.retained) |provider| unavailable(provider) catch |err| {
            std.debug.print("closed range provider remained available\n", .{});
            return err;
        };
    }
};
fn unavailable(provider: *c.IRangeValueProvider) !void {
    var again: ?*c.IRangeValueProvider = null;
    try check(provider.lpVtbl.*.QueryInterface.?(provider, &c.IID_IRangeValueProvider, @ptrCast(&again)));
    defer _ = again.?.lpVtbl.*.Release.?(again.?);
    var value: f64 = 0;
    try expected(@bitCast(c.UIA_E_ELEMENTNOTAVAILABLE), provider.lpVtbl.*.get_Value.?(provider, &value));
    try expected(@bitCast(c.UIA_E_ELEMENTNOTAVAILABLE), provider.lpVtbl.*.SetValue.?(provider, 50));
}
pub fn run(allocator: std.mem.Allocator) !void {
    if (!ui.capabilities.accessibility) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: shared.State = .{ .editor = try ui.editor.Editor.init(allocator, .{}, "AB") };
    defer state.editor.deinit();
    try state.attach(app);
    paint(state.window);
    var retained: [3]*c.IRangeValueProvider = undefined;
    var count: usize = 0;
    defer for (retained[0..count]) |provider| {
        _ = provider.lpVtbl.*.Release.?(provider);
    };
    for ([_]u64{ 20, 21, 24 }) |id| {
        const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try state.context.accessibility_bridge.retainProvider(id)));
        defer _ = simple.lpVtbl.*.Release.?(simple);
        var pattern: ?*c.IRangeValueProvider = null;
        try check(simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IRangeValueProvider, @ptrCast(&pattern)));
        retained[count] = pattern.?;
        count += 1;
    }
    const fence = c.CreateEventW(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = c.CloseHandle(fence);
    var client: Client = .{ .app = app, .state = &state, .hwnd = state.window.nativeHandle(), .fence = fence, .retained = retained };
    state.after_closed = .{ .context = &client, .call = Client.signalClosed };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, Client.worker, .{&client});
    defer thread.join();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (client.err) |err| return err;
    if (state.err) |err| return err;
    try std.testing.expectEqual(@as(f64, 65), state.value);
    try std.testing.expectEqual(@as(f64, 60), state.low);
    try std.testing.expectEqual(@as(f64, 7), state.step);
    for (retained[0..count]) |provider| _ = provider.lpVtbl.*.Release.?(provider);
    count = 0;
    try app.dispatch();
    try std.testing.expectEqual(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
    std.debug.print("range widgets UIA smoke passed: real client slider/spinner RangeValue, paired constraints, disable/remove/close and immutable QI\n", .{});
}
