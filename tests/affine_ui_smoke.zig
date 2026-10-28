const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shared = @import("affine_ui_shared.zig");
const Watchdog = @import("watchdog.zig").Watchdog;
const c = @import("ziggurat_c_win32");
const Native = struct {
    pub fn paint(window: z.Window) void {
        const hwnd: c.HWND = window.nativeHandle();
        _ = c.InvalidateRect(hwnd, null, 0);
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    }
    pub fn pointer(window: z.Window, phase: enum { down, move, up }, point: z.Point) !void {
        const hwnd: c.HWND = window.nativeHandle();
        const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
        const x: u16 = @bitCast(@as(i16, @intFromFloat(@round(point.x * scale))));
        const y: u16 = @bitCast(@as(i16, @intFromFloat(@round(point.y * scale))));
        _ = c.SendMessageW(hwnd, switch (phase) {
            .down => c.WM_LBUTTONDOWN,
            .move => c.WM_MOUSEMOVE,
            .up => c.WM_LBUTTONUP,
        }, if (phase == .move) c.MK_LBUTTON else 0, @intCast(@as(u32, x) | (@as(u32, y) << 16)));
    }
    pub fn click(window: z.Window, point: z.Point) !void {
        try pointer(window, .down, point);
        try pointer(window, .up, point);
    }
    pub fn key(window: z.Window, code: z.KeyCode) void {
        _ = c.SendMessageW(window.nativeHandle(), c.WM_KEYDOWN, if (code == .space) c.VK_SPACE else c.VK_TAB, 0);
    }
    pub fn text(window: z.Window) void {
        _ = c.SendMessageW(window.nativeHandle(), c.WM_UNICHAR, 0x4e2d, 0);
    }
    pub fn focus(window: z.Window) void {
        _ = c.SendMessageW(window.nativeHandle(), c.WM_SETFOCUS, 0, 0);
    }
    pub fn pixel(context: *ui.Context) !u32 {
        return c.GetPixel(context.renderer.dc, 0, 0);
    }
    pub fn checkCaret(window: z.Window, token: ui.SpaceToken, caret: ui.Rect) !void {
        const hwnd: c.HWND = window.nativeHandle();
        const input = c.ImmCreateContext() orelse return error.InputContextUnavailable;
        const previous = c.ImmAssociateContext(hwnd, input);
        defer {
            _ = c.ImmAssociateContext(hwnd, previous);
            std.debug.assert(c.ImmDestroyContext(input) != 0);
        }
        try token.setTextCaret(caret);
        const expected = try token.windowBounds(caret);
        var composition = std.mem.zeroes(c.COMPOSITIONFORM);
        try std.testing.expect(c.ImmGetCompositionWindow(input, &composition) != 0);
        const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
        try std.testing.expectEqual(@as(c.LONG, @intFromFloat(@as(f64, expected.x) * scale)), composition.ptCurrentPos.x);
        try std.testing.expectEqual(@as(c.LONG, @intFromFloat(@as(f64, expected.y) * scale)) + @as(c.LONG, @intFromFloat(@as(f64, expected.height) * scale)), composition.ptCurrentPos.y);
    }
};
const State = shared.Suite(Native);
fn check(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("affine UI HRESULT=0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.NativeFailure;
    }
}
fn rootProvider(state: *State) !*c.IRawElementProviderFragmentRoot {
    const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try state.context.?.accessibility_bridge.retainProvider(0)));
    defer _ = simple.lpVtbl.*.Release.?(simple);
    var root: ?*c.IRawElementProviderFragmentRoot = null;
    try check(simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IRawElementProviderFragmentRoot, @ptrCast(&root)));
    return root.?;
}
fn screenPoint(window: z.Window, local: z.Point) !ui.affine.Point {
    const hwnd: c.HWND = window.nativeHandle();
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    if (c.ClientToScreen(hwnd, &origin) == 0) return error.NoWindowOrigin;
    const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
    return .{ .x = @as(f64, @floatFromInt(origin.x)) + @as(f64, local.x) * scale, .y = @as(f64, @floatFromInt(origin.y)) + @as(f64, local.y) * scale };
}
fn pointId(root: *c.IRawElementProviderFragmentRoot, point: ui.affine.Point) !u64 {
    var element: ?*c.IRawElementProviderFragment = null;
    try check(root.lpVtbl.*.ElementProviderFromPoint.?(root, point.x, point.y, &element));
    defer _ = element.?.lpVtbl.*.Release.?(element.?);
    var runtime: ?*c.SAFEARRAY = null;
    try check(element.?.lpVtbl.*.GetRuntimeId.?(element.?, &runtime));
    if (runtime == null) return 0;
    defer _ = c.SafeArrayDestroy(runtime);
    var index: c.LONG = 1;
    var low: c.LONG = 0;
    try check(c.SafeArrayGetElement(runtime, &index, &low));
    index = 2;
    var high: c.LONG = 0;
    try check(c.SafeArrayGetElement(runtime, &index, &high));
    return @as(u32, @bitCast(low)) | (@as(u64, @as(u32, @bitCast(high))) << 32);
}
fn client(hwnd: c.HWND) !void {
    try check(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
    defer c.CoUninitialize();
    var automation: ?*c.IUIAutomation = null;
    try check(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&automation)));
    defer _ = automation.?.lpVtbl.*.Release.?(automation.?);
    var root: ?*c.IUIAutomationElement = null;
    try check(automation.?.lpVtbl.*.ElementFromHandle.?(automation.?, hwnd, &root));
    defer _ = root.?.lpVtbl.*.Release.?(root.?);
    var condition: ?*c.IUIAutomationCondition = null;
    try check(automation.?.lpVtbl.*.CreateTrueCondition.?(automation.?, &condition));
    defer _ = condition.?.lpVtbl.*.Release.?(condition.?);
    var children: ?*c.IUIAutomationElementArray = null;
    try check(root.?.lpVtbl.*.FindAll.?(root.?, c.TreeScope_Descendants, condition.?, &children));
    defer _ = children.?.lpVtbl.*.Release.?(children.?);
    var length: c_int = 0;
    try check(children.?.lpVtbl.*.get_Length.?(children.?, &length));
    var found = false;
    var index: c_int = 0;
    while (index < length) : (index += 1) {
        var element: ?*c.IUIAutomationElement = null;
        try check(children.?.lpVtbl.*.GetElement.?(children.?, index, &element));
        defer _ = element.?.lpVtbl.*.Release.?(element.?);
        var name: c.BSTR = null;
        try check(element.?.lpVtbl.*.get_CurrentName.?(element.?, &name));
        defer c.SysFreeString(name);
        if (name == null) continue;
        if (!std.mem.eql(u16, name[0..c.SysStringLen(name)], std.unicode.utf8ToUtf16LeStringLiteral("Transformed action"))) continue;
        found = true;
        var bounds: c.RECT = undefined;
        try check(element.?.lpVtbl.*.get_CurrentBoundingRectangle.?(element.?, &bounds));
        try std.testing.expect(bounds.right > bounds.left and bounds.bottom > bounds.top);
        var invoke: ?*c.IUIAutomationInvokePattern = null;
        try check(element.?.lpVtbl.*.GetCurrentPatternAs.?(element.?, c.UIA_InvokePatternId, &c.IID_IUIAutomationInvokePattern, @ptrCast(&invoke)));
        defer _ = invoke.?.lpVtbl.*.Release.?(invoke.?);
        try check(invoke.?.lpVtbl.*.Invoke.?(invoke.?));
    }
    try std.testing.expect(found);
}
fn worker(state: *State, hwnd: c.HWND) void {
    client(hwnd) catch |err| {
        state.client_failed = err;
    };
    state.app.post(.{ .context = state, .call = State.finish }) catch {};
}
pub fn main() !void {
    if (!ui.capabilities.accessibility) return error.AccessibilityRequired;
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{};
    try state.init(app, allocator.allocator());
    defer state.editor.deinit();
    defer {
        if (!state.window.isClosed()) _ = state.window.destroy() catch {};
    }
    try state.exercise();
    try State.reentry(app, allocator.allocator());
    const root = try rootProvider(&state);
    var root_owned = true;
    defer if (root_owned) {
        _ = root.lpVtbl.*.Release.?(root);
    };
    const center = try State.point(.{ .x = 40, .y = 22 });
    try std.testing.expectEqual(@as(u64, 1), try pointId(root, try screenPoint(state.window, center)));
    const bounds = try (try shared.matrix.narrowed()).mapBounds(ui.affine.Rect.from(shared.button));
    const corner: z.Point = .{ .x = @floatCast(bounds.x + bounds.width - 1), .y = @floatCast(bounds.y + 1) };
    try std.testing.expectEqual(@as(u64, 0), try pointId(root, try screenPoint(state.window, corner)));
    const frames = state.context.?.frames;
    const hwnd: c.HWND = state.window.nativeHandle();
    var rectangle: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &rectangle) != 0);
    try std.testing.expect(c.SetWindowPos(hwnd, null, rectangle.left + 31, rectangle.top + 17, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    try std.testing.expectEqual(frames, state.context.?.frames);
    try std.testing.expectEqual(@as(u64, 1), try pointId(root, try screenPoint(state.window, center)));
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const thread = try std.Thread.spawn(.{}, worker, .{ &state, hwnd });
    try app.run();
    thread.join();
    if (state.client_failed) |err| return err;
    if (state.failed) |err| return err;
    try std.testing.expect(!watchdog.expired);
    try std.testing.expectEqual(@as(usize, 3), state.actions);
    try std.testing.expectEqual(@as(usize, 1), state.closed);
    try std.testing.expect(state.context == null);
    var unavailable: ?*c.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(c.HRESULT, @bitCast(@as(u32, c.UIA_E_ELEMENTNOTAVAILABLE))), root.lpVtbl.*.ElementProviderFromPoint.?(root, 0, 0, &unavailable));
    try std.testing.expect(unavailable == null);
    _ = root.lpVtbl.*.Release.?(root);
    root_owned = false;
    try std.testing.expectEqualDeep(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
    try std.testing.expectEqual(@as(u32, 0), ui.accessibility.geometryResourceCount());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("affine UI passed: committed controls/editor/IMM caret, failed frame/release, MTA client and exact native hit/move, immediate Context free; geometry refs=0\n", .{});
}
