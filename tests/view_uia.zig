//! Windows UI Automation check for declarative tabs, toolbars, splits,
//! segments, links and disclosures,
//! read and driven by a real client on a worker thread.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
    @cInclude("oleauto.h");
});

fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("view UIA HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
fn paint(window: z.Window) void {
    _ = c.InvalidateRect(window.nativeHandle(), null, 0);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
}
fn release(object: anytype) void {
    _ = object.lpVtbl.*.Release.?(object);
}

const State = struct {
    section: enum { general, advanced } = .general,
    pane: f64 = 0.5,
    saved: usize = 0,
    mode: enum { light, dark } = .light,
    more: bool = false,
    opened: usize = 0,
    fn build(self: *State, v: *view.View) anyerror!void {
        try v.toolbar(.{ .gap = 8, .name = "Actions" });
        if (try v.button("Save", .{})) self.saved += 1;
        try v.end();
        try v.tabs(.{ .name = "Sections" });
        _ = try v.tab(@TypeOf(self.section), &self.section, .general, "General", .{});
        _ = try v.tab(@TypeOf(self.section), &self.section, .advanced, "Advanced", .{});
        try v.end();
        _ = try v.split(.row, &self.pane, .{ .minimum = 0.2, .maximum = 0.8 }, .{ .height = 60, .self_align = .stretch, .name = "Panes" });
        try v.text(if (self.section == .general) "General pane" else "Advanced pane", .{});
        try v.text("Detail", .{});
        try v.end();
        try v.segmented(.{ .name = "Mode" });
        _ = try v.segment(@TypeOf(self.mode), &self.mode, .light, "Light", .{});
        _ = try v.segment(@TypeOf(self.mode), &self.mode, .dark, "Dark", .{});
        try v.end();
        if (try v.link("Help", .{})) self.opened += 1;
        _ = try v.disclosure(&self.more, "More", .{});
    }
};

const Client = struct {
    app: *z.App,
    window: z.Window,
    fence: c.HANDLE,
    err: ?anyerror = null,

    /// Repaint on the owner thread after earlier UIA requests, so the next
    /// read sees the published tree.
    fn synchronize(self: *Client) !void {
        _ = c.ResetEvent(self.fence);
        try self.app.post(.{ .context = self, .call = update });
        if (c.WaitForSingleObject(self.fence, 5000) != c.WAIT_OBJECT_0) return error.FenceTimeout;
    }
    fn update(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        paint(self.window);
        _ = c.SetEvent(self.fence);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        _ = self.window.destroy() catch {};
        self.app.quit();
    }
    fn worker(self: *Client) void {
        self.run() catch |err| {
            self.err = err;
        };
        self.app.post(.{ .context = self, .call = finish }) catch {};
    }

    fn named(element: *c.IUIAutomationElement, comptime name: []const u8) !bool {
        const wide = comptime std.unicode.utf8ToUtf16LeStringLiteral(name);
        var text: c.BSTR = null;
        try check(element.lpVtbl.*.get_CurrentName.?(element, &text));
        defer c.SysFreeString(text);
        const length = c.SysStringLen(text);
        return length == wide.len and std.mem.eql(u16, @as([*]const u16, @ptrCast(text))[0..length], wide);
    }
    /// The one descendant with this control type and name; the caller releases it.
    fn find(elements: *c.IUIAutomationElementArray, role: c.CONTROLTYPEID, comptime name: []const u8) !*c.IUIAutomationElement {
        var length: c_int = 0;
        try check(elements.lpVtbl.*.get_Length.?(elements, &length));
        var found: ?*c.IUIAutomationElement = null;
        errdefer if (found) |element| release(element);
        var index: c_int = 0;
        while (index < length) : (index += 1) {
            var element: ?*c.IUIAutomationElement = null;
            try check(elements.lpVtbl.*.GetElement.?(elements, index, &element));
            var actual: c.CONTROLTYPEID = 0;
            check(element.?.lpVtbl.*.get_CurrentControlType.?(element.?, &actual)) catch |err| {
                release(element.?);
                return err;
            };
            const match = actual == role and (named(element.?, name) catch |err| {
                release(element.?);
                return err;
            });
            if (!match) {
                release(element.?);
                continue;
            }
            if (found != null) {
                release(element.?);
                return error.DuplicateElement;
            }
            found = element.?;
        }
        return found orelse {
            std.debug.print("view UIA element missing: {s}\n", .{name});
            return error.MissingElement;
        };
    }
    fn parentType(walker: *c.IUIAutomationTreeWalker, element: *c.IUIAutomationElement) !c.CONTROLTYPEID {
        var parent: ?*c.IUIAutomationElement = null;
        try check(walker.lpVtbl.*.GetParentElement.?(walker, element, &parent));
        defer release(parent.?);
        var role: c.CONTROLTYPEID = 0;
        try check(parent.?.lpVtbl.*.get_CurrentControlType.?(parent.?, &role));
        return role;
    }

    fn run(self: *Client) !void {
        try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var api: ?*c.IUIAutomation = null;
        try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&api)));
        defer release(api.?);
        const hwnd: c.HWND = self.window.nativeHandle();
        var root: ?*c.IUIAutomationElement = null;
        try check(api.?.lpVtbl.*.ElementFromHandle.?(api.?, hwnd, &root));
        defer release(root.?);
        var condition: ?*c.IUIAutomationCondition = null;
        try check(api.?.lpVtbl.*.CreateTrueCondition.?(api.?, &condition));
        defer release(condition.?);
        var elements: ?*c.IUIAutomationElementArray = null;
        try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &elements));
        defer release(elements.?);
        var walker: ?*c.IUIAutomationTreeWalker = null;
        try check(api.?.lpVtbl.*.get_ControlViewWalker.?(api.?, &walker));
        defer release(walker.?);

        const toolbar = try find(elements.?, c.UIA_ToolBarControlTypeId, "Actions");
        defer release(toolbar);
        const save = try find(elements.?, c.UIA_ButtonControlTypeId, "Save");
        defer release(save);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_ToolBarControlTypeId), try parentType(walker.?, save));
        const list = try find(elements.?, c.UIA_TabControlTypeId, "Sections");
        defer release(list);
        const advanced = try find(elements.?, c.UIA_TabItemControlTypeId, "Advanced");
        defer release(advanced);
        try std.testing.expectEqual(@as(c.CONTROLTYPEID, c.UIA_TabControlTypeId), try parentType(walker.?, advanced));
        const splitter = try find(elements.?, c.UIA_ThumbControlTypeId, "Panes");
        defer release(splitter);

        // The tab list offers single selection; selecting a tab runs the same
        // activation as a click.
        var selection: ?*c.IUIAutomationSelectionPattern = null;
        try check(list.lpVtbl.*.GetCurrentPatternAs.?(list, c.UIA_SelectionPatternId, &c.IID_IUIAutomationSelectionPattern, @ptrCast(&selection)));
        defer release(selection.?);
        var multiple: c.BOOL = 1;
        try check(selection.?.lpVtbl.*.get_CurrentCanSelectMultiple.?(selection.?, &multiple));
        try std.testing.expectEqual(@as(c.BOOL, 0), multiple);
        var item: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(advanced.lpVtbl.*.GetCurrentPatternAs.?(advanced, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&item)));
        defer release(item.?);
        var selected: c.BOOL = 1;
        try check(item.?.lpVtbl.*.get_CurrentIsSelected.?(item.?, &selected));
        try std.testing.expectEqual(@as(c.BOOL, 0), selected);
        try check(item.?.lpVtbl.*.Select.?(item.?));
        try self.synchronize();
        try check(item.?.lpVtbl.*.get_CurrentIsSelected.?(item.?, &selected));
        try std.testing.expect(selected != 0);

        // The splitter reports the first pane's share within its limits.
        var range: ?*c.IUIAutomationRangeValuePattern = null;
        try check(splitter.lpVtbl.*.GetCurrentPatternAs.?(splitter, c.UIA_RangeValuePatternId, &c.IID_IUIAutomationRangeValuePattern, @ptrCast(&range)));
        defer release(range.?);
        var value: f64 = 0;
        try check(range.?.lpVtbl.*.get_CurrentMinimum.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.2), value);
        try check(range.?.lpVtbl.*.get_CurrentMaximum.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.8), value);
        try check(range.?.lpVtbl.*.get_CurrentValue.?(range.?, &value));
        try std.testing.expectEqual(@as(f64, 0.5), value);
        try std.testing.expectEqual(@as(c.HRESULT, c.E_INVALIDARG), range.?.lpVtbl.*.SetValue.?(range.?, 0.9));
        try check(range.?.lpVtbl.*.SetValue.?(range.?, 0.6));
        try self.synchronize();
        try check(range.?.lpVtbl.*.get_CurrentValue.?(range.?, &value));
        try std.testing.expectApproxEqAbs(@as(f64, 0.6), value, 1e-9);

        // Segments are radios, links invoke and disclosures expand.
        const dark = try find(elements.?, c.UIA_RadioButtonControlTypeId, "Dark");
        defer release(dark);
        var segment: ?*c.IUIAutomationSelectionItemPattern = null;
        try check(dark.lpVtbl.*.GetCurrentPatternAs.?(dark, c.UIA_SelectionItemPatternId, &c.IID_IUIAutomationSelectionItemPattern, @ptrCast(&segment)));
        defer release(segment.?);
        try check(segment.?.lpVtbl.*.Select.?(segment.?));
        const help = try find(elements.?, c.UIA_HyperlinkControlTypeId, "Help");
        defer release(help);
        var invoke: ?*c.IUIAutomationInvokePattern = null;
        try check(help.lpVtbl.*.GetCurrentPatternAs.?(help, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&invoke)));
        defer release(invoke.?);
        try check(invoke.?.lpVtbl.*.Invoke.?(invoke.?));
        const more = try find(elements.?, c.UIA_ButtonControlTypeId, "More");
        defer release(more);
        var expander: ?*c.IUIAutomationExpandCollapsePattern = null;
        try check(more.lpVtbl.*.GetCurrentPatternAs.?(more, c.UIA_ExpandCollapsePatternId, &c.IID_IUIAutomationExpandCollapsePattern, @ptrCast(&expander)));
        defer release(expander.?);
        var expansion: c.enum_ExpandCollapseState = c.ExpandCollapseState_Expanded;
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Collapsed), expansion);
        try check(expander.?.lpVtbl.*.Expand.?(expander.?));
        try self.synchronize();
        // Expanding an expanded disclosure changes nothing.
        try check(expander.?.lpVtbl.*.Expand.?(expander.?));
        try self.synchronize();
        try check(expander.?.lpVtbl.*.get_CurrentExpandCollapseState.?(expander.?, &expansion));
        try std.testing.expectEqual(@as(c.enum_ExpandCollapseState, c.ExpandCollapseState_Expanded), expansion);
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    if (!ui.capabilities.accessibility) return;
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{};
    var storage: view.Storage(32, 512) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = 360, .height = 420 });
    try host.attach(window);
    paint(window);
    if (host.last_error) |err| return err;
    const fence = c.CreateEventW(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = c.CloseHandle(fence);
    var client: Client = .{ .app = app, .window = window, .fence = fence };
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, Client.worker, .{&client});
    defer thread.join();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (client.err) |err| return err;
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(.advanced, state.section);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), state.pane, 1e-9);
    try std.testing.expectEqual(.dark, state.mode);
    try std.testing.expectEqual(@as(usize, 1), state.opened);
    try std.testing.expect(state.more);
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
    std.debug.print("view UIA smoke passed: real client tab list/tab selection, toolbar parent, splitter RangeValue, segment selection, link invoke and disclosure ExpandCollapse\n", .{});
}
