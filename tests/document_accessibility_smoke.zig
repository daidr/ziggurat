const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const e = @import("ziggurat_document_editor");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const a = @import("ziggurat_document_accessibility");
const Watchdog = @import("watchdog.zig").Watchdog;
const point_oracle = @import("document_accessibility_point_oracle.zig");
const point_cases = @import("document_accessibility_point_cases.zig");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
    @cInclude("oleauto.h");
});
extern fn zda_probe_read(*anyopaque, [*]u16, u32, *u32) i32;
extern fn zda_probe_word_text(*anyopaque, [*]const u16, u32, [*]u16, u32, *u32) i32;
extern fn zda_probe_read_mta(*anyopaque, [*]u16, u32, *u32) i32;
extern fn zda_probe_select(*anyopaque, [*]const u16, u32) i32;
extern fn zda_probe_rectangles(*anyopaque, *u32, *f64, *f64) i32;
extern fn zda_probe_match_rectangles(*anyopaque, [*]const u16, u32, *u32) i32;
extern fn zda_probe_selection(*anyopaque, [*]u16, u32, *u32) i32;
extern fn zda_probe_point(*anyopaque, f64, f64, *u32) i32;
extern fn zda_probe_caret(*anyopaque, *u32, *i32) i32;
extern fn zda_probe_bounds(*anyopaque, [*]f64, f64, f64) i32;
extern fn zda_probe_empty_visible(*anyopaque, u32) i32;
extern fn zda_probe_all_rectangles(*anyopaque, [*]f64, u32, *u32) i32;
extern fn zda_probe_release(*anyopaque) void;
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 280, .height = 100 };
const original = "a😀e\u{301} אבג\r\nsecond paragraph\nthird line\nfourth line\nfifth line\nsixth line\nlast hidden paragraph";
const State = struct {
    context: ui.Context = undefined,
    window: z.Window = undefined,
    document: *d.Document,
    adapter: *e.Adapter,
    bridge: ?*a.Bridge = null,
    parameters: e.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = 280 } },
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    fail_frame: bool = false,
    partial_clip: bool = false,
    close_frame: bool = false,
    affine_matrix: ?ui.affine.Affine = null,
    affine_clip: ?ui.Rect = null,
    draw_offset: ?ui.layout.Point = null,
    record_geometry: bool = true,
    mapping: ?ui.CoordinateMapping = null,
    paints: usize = 0,
    changes: usize = 0,
    fail_changed: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |actual| {
            if (self.expected) |wanted| {
                if (actual != wanted) self.failure = actual;
            } else self.failure = actual;
        } else self.failure = error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            if (self.expected) |wanted| {
                if (wanted != err) self.failure = err;
            } else self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.affine_clip) |clip| try frame.pushClip(clip);
        defer if (self.affine_clip != null) frame.popClip() catch unreachable;
        if (self.affine_matrix) |matrix| try frame.beginTransform(.{ .width = 320, .height = 140 }, matrix);
        defer if (self.affine_matrix != null) frame.endTransform() catch unreachable;
        if (self.draw_offset) |offset| try frame.pushOffset(offset);
        defer if (self.draw_offset != null) frame.popOffset() catch unreachable;
        if (self.partial_clip) try frame.pushClip(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width / 2, .height = bounds.height });
        defer if (self.partial_clip) frame.popClip() catch unreachable;
        try self.adapter.draw(frame, bounds, .{});
        if (self.bridge) |bridge| if (self.record_geometry) try bridge.recordGeometry(frame);
        if (self.affine_matrix != null or self.draw_offset != null) {
            if (self.affine_matrix != null) try frame.captureSpace(91, bounds);
            var mapping: ui.CoordinateMapping = undefined;
            try frame.coordinateMapping(bounds, &mapping);
            self.mapping = mapping;
        }
        self.paints += 1;
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_frame) _ = try self.window.destroy();
    }
    fn changed(ptr: *anyopaque, window: z.Window, _: usize, adapter: *e.Adapter) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        _ = try adapter.prepare(bounds, self.parameters);
        self.changes += 1;
        if (self.fail_changed) return error.PresentationFailed;
        try window.app.post(.{ .context = self, .call = prepareGeometry });
    }
    fn prepareGeometry(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (self.bridge) |bridge| bridge.prepareGeometry(&.{null}) catch |err| {
            self.failure = err;
        };
    }
    fn refresh(self: *State) !void {
        _ = try self.adapter.prepare(bounds, self.parameters);
        const snapshot = try self.document.snapshot();
        defer snapshot.close() catch unreachable;
        const reader = try snapshot.borrowReader();
        defer reader.release() catch unreachable;
        try self.bridge.?.prepareText(&.{reader});
        try self.bridge.?.prepareGeometry(&.{null});
    }
    fn paint(self: *State) !void {
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (self.failure) |err| return err;
    }
};
fn textEquals(provider: *anyopaque, expected: []const u8, mta: bool) !void {
    const Check = struct {
        provider: *anyopaque,
        output: [8192]u16 = undefined,
        len: u32 = 0,
        hr: i32 = 0,
        fn run(self: *@This()) void {
            self.hr = zda_probe_read_mta(self.provider, &self.output, self.output.len, &self.len);
        }
    };
    var check: Check = .{ .provider = provider };
    if (mta) {
        const worker = try std.Thread.spawn(.{}, Check.run, .{&check});
        worker.join();
    } else check.hr = zda_probe_read(provider, &check.output, check.output.len, &check.len);
    try std.testing.expectEqual(@as(i32, 0), check.hr);
    var utf16: [8192]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&utf16, expected);
    try std.testing.expectEqualSlices(u16, utf16[0..len], check.output[0..check.len]);
}
fn rects(provider: *anyopaque) !struct { count: u32, x: f64, y: f64 } {
    var result: struct { count: u32 = 0, x: f64 = 0, y: f64 = 0 } = .{};
    try std.testing.expectEqual(@as(i32, 0), zda_probe_rectangles(provider, &result.count, &result.x, &result.y));
    return .{ .count = result.count, .x = result.x, .y = result.y };
}
fn checkHr(hr: c.HRESULT) !void {
    if (hr < 0) {
        std.debug.print("document UIA HRESULT 0x{x}\n", .{@as(u32, @bitCast(hr))});
        return error.UiaCallFailed;
    }
}
const Client = struct {
    const PointCheck = struct { point: c.POINT, offset: c_int };
    state: *State,
    provider: *anyopaque,
    hwnd: c.HWND,
    fence: c.HANDLE,
    closed: bool = false,
    failure: ?anyerror = null,
    points: [48]PointCheck = undefined,
    point_count: usize = 0,
    caret_offset: c_int = 0,
    caret_active: bool = false,
    fn capturePoints(self: *Client) !void {
        var carets: [512]e.GeometryCaret = undefined;
        var lines: [64]e.GeometryLine = undefined;
        const exported = try self.state.adapter.preparedCarets(try self.state.document.version(), &carets, &lines, .{});
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        if (c.ClientToScreen(self.hwnd, &origin) == 0) return error.ClientOriginFailed;
        for (exported.lines[0..@min(3, exported.lines.len)]) |line| {
            for (0..16) |at| {
                const local_x = bounds.x + (bounds.width - 1) * @as(f32, @floatFromInt(at)) / 15;
                const local_y = line.rect.y + line.rect.height / 2;
                const point: c.POINT = .{ .x = origin.x + @as(c.LONG, @intFromFloat(@round(local_x * exported.scale))), .y = origin.y + @as(c.LONG, @intFromFloat(@round(local_y * exported.scale))) };
                const actual: ui.layout.Point = .{ .x = @as(f32, @floatFromInt(point.x - origin.x)) / exported.scale, .y = @as(f32, @floatFromInt(point.y - origin.y)) / exported.scale };
                const expected = try self.state.adapter.hitTest(bounds, actual);
                self.points[self.point_count] = .{ .point = point, .offset = @intCast(try self.state.document.utf16Offset(expected.byte_offset)) };
                self.point_count += 1;
            }
        }
        try std.testing.expect(self.point_count != 0);
        self.caret_offset = @intCast(try self.state.document.utf16Offset((try self.state.document.selection()).caret));
        self.caret_active = (try self.state.window.state()).focused and try self.state.adapter.isBound();
    }
    fn update(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (self.closed) {
            const emoji = [_]u16{ 0xd83d, 0xde00 };
            // Physical accepted-slot ownership survives destruction of Bridge.
            for (0..16) |_| std.debug.assert(zda_probe_select(self.provider, &emoji, emoji.len) == 0);
            self.state.bridge.?.close() catch |err| {
                self.state.failure = err;
            };
            self.state.bridge = null;
        }
        _ = c.SetEvent(self.fence);
    }
    fn finish(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.state.window.app.quit();
    }
    fn synchronize(self: *Client, closed: bool) !void {
        self.closed = closed;
        _ = c.ResetEvent(self.fence);
        try self.state.window.app.post(.{ .context = self, .call = update });
        if (c.WaitForSingleObject(self.fence, 5000) != c.WAIT_OBJECT_0) return error.ClientFenceTimeout;
    }
    fn worker(self: *Client) void {
        self.run() catch |err| {
            self.failure = err;
        };
        self.state.window.app.post(.{ .context = self, .call = finish }) catch {};
    }
    fn run(self: *Client) !void {
        try checkHr(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var automation: ?*c.IUIAutomation = null;
        try checkHr(c.CoCreateInstance(&c.CLSID_CUIAutomation8, null, c.CLSCTX_INPROC_SERVER, &c.IID_IUIAutomation, @ptrCast(&automation)));
        const api = automation.?;
        defer _ = api.lpVtbl.*.Release.?(api);
        var automation2: ?*c.IUIAutomation2 = null;
        try checkHr(api.lpVtbl.*.QueryInterface.?(api, &c.IID_IUIAutomation2, @ptrCast(&automation2)));
        defer _ = automation2.?.lpVtbl.*.Release.?(automation2.?);
        try checkHr(automation2.?.lpVtbl.*.put_ConnectionTimeout.?(automation2.?, 2000));
        try checkHr(automation2.?.lpVtbl.*.put_TransactionTimeout.?(automation2.?, 2000));
        var element: ?*c.IUIAutomationElement = null;
        try checkHr(api.lpVtbl.*.ElementFromHandle.?(api, self.hwnd, &element));
        defer _ = element.?.lpVtbl.*.Release.?(element.?);
        var pattern: ?*c.IUIAutomationTextPattern = null;
        try checkHr(element.?.lpVtbl.*.GetCurrentPatternAs.?(element.?, c.UIA_TextPatternId, &c.IID_IUIAutomationTextPattern, @ptrCast(&pattern)));
        defer _ = pattern.?.lpVtbl.*.Release.?(pattern.?);
        var range: ?*c.IUIAutomationTextRange = null;
        try checkHr(pattern.?.lpVtbl.*.get_DocumentRange.?(pattern.?, &range));
        defer _ = range.?.lpVtbl.*.Release.?(range.?);
        for (self.points[0..self.point_count]) |check| {
            var nearest: ?*c.IUIAutomationTextRange = null;
            try checkHr(pattern.?.lpVtbl.*.RangeFromPoint.?(pattern.?, check.point, &nearest));
            if (nearest == null) return error.MissingPointRange;
            defer _ = nearest.?.lpVtbl.*.Release.?(nearest.?);
            var offset: c_int = -1;
            try checkHr(nearest.?.lpVtbl.*.CompareEndpoints.?(nearest.?, c.TextPatternRangeEndpoint_Start, range.?, c.TextPatternRangeEndpoint_Start, &offset));
            try std.testing.expectEqual(check.offset, offset);
            var width: c_int = -1;
            try checkHr(nearest.?.lpVtbl.*.CompareEndpoints.?(nearest.?, c.TextPatternRangeEndpoint_End, nearest.?, c.TextPatternRangeEndpoint_Start, &width));
            try std.testing.expectEqual(@as(c_int, 0), width);
        }
        var extended: ?*c.IUIAutomationTextPattern2 = null;
        try checkHr(element.?.lpVtbl.*.GetCurrentPatternAs.?(element.?, c.UIA_TextPattern2Id, &c.IID_IUIAutomationTextPattern2, @ptrCast(&extended)));
        defer _ = extended.?.lpVtbl.*.Release.?(extended.?);
        var active: c.BOOL = 0;
        var caret: ?*c.IUIAutomationTextRange = null;
        try checkHr(extended.?.lpVtbl.*.GetCaretRange.?(extended.?, &active, &caret));
        if (caret == null) return error.MissingCaretRange;
        defer _ = caret.?.lpVtbl.*.Release.?(caret.?);
        try std.testing.expectEqual(self.caret_active, active != 0);
        var caret_offset: c_int = -1;
        try checkHr(caret.?.lpVtbl.*.CompareEndpoints.?(caret.?, c.TextPatternRangeEndpoint_Start, range.?, c.TextPatternRangeEndpoint_Start, &caret_offset));
        try std.testing.expectEqual(self.caret_offset, caret_offset);
        var text: c.BSTR = null;
        try checkHr(range.?.lpVtbl.*.GetText.?(range.?, -1, &text));
        var expected: [8192]u16 = undefined;
        const expected_len = try std.unicode.utf8ToUtf16Le(&expected, original);
        defer c.SysFreeString(text);
        try std.testing.expectEqualSlices(u16, expected[0..expected_len], text[0..c.SysStringLen(text)]);
        const needle: []const u16 = &.{ 's', 'e', 'c', 'o', 'n', 'd' };
        const query = c.SysAllocStringLen(needle.ptr, @intCast(needle.len));
        if (query == null) return error.OutOfMemory;
        defer c.SysFreeString(query);
        var selected: ?*c.IUIAutomationTextRange = null;
        try checkHr(range.?.lpVtbl.*.FindText.?(range.?, query, 0, 0, &selected));
        if (selected == null) return error.FindTextMissing;
        defer _ = selected.?.lpVtbl.*.Release.?(selected.?);
        try checkHr(selected.?.lpVtbl.*.Select.?(selected.?));
        try self.synchronize(false);
        var selections: ?*c.IUIAutomationTextRangeArray = null;
        try checkHr(pattern.?.lpVtbl.*.GetSelection.?(pattern.?, &selections));
        defer _ = selections.?.lpVtbl.*.Release.?(selections.?);
        var selected_range: ?*c.IUIAutomationTextRange = null;
        try checkHr(selections.?.lpVtbl.*.GetElement.?(selections.?, 0, &selected_range));
        defer _ = selected_range.?.lpVtbl.*.Release.?(selected_range.?);
        var selected_text: c.BSTR = null;
        try checkHr(selected_range.?.lpVtbl.*.GetText.?(selected_range.?, -1, &selected_text));
        defer c.SysFreeString(selected_text);
        try std.testing.expectEqualSlices(u16, needle, selected_text[0..c.SysStringLen(selected_text)]);
        try self.synchronize(true);
        var closed_text: c.BSTR = null;
        const hr = range.?.lpVtbl.*.GetText.?(range.?, -1, &closed_text);
        if (closed_text != null) c.SysFreeString(closed_text);
        try std.testing.expect(hr < 0);
    }
};
pub fn main() !void {
    if (builtin.os.tag != .windows) return error.UnsupportedCapability;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var renderer: ui.RenderMode = .gdi;
    if (args.next()) |flag| {
        if (!std.mem.eql(u8, flag, "--point-renderer")) return error.InvalidArguments;
        const value = args.next() orelse return error.InvalidArguments;
        renderer = if (std.mem.eql(u8, value, "gdi")) .gdi else if (std.mem.eql(u8, value, "hardware")) .hardware else if (std.mem.eql(u8, value, "warp")) .warp else return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
    }
    try primary(allocator);
    try filteredSources(allocator, false);
    try filteredSources(allocator, true);
    try capacityCase(allocator);
    try sourcePinsDuringClose(allocator);
    try stopCase(allocator);
    try closeReentry(allocator, false);
    try closeReentry(allocator, true);
    try prepareClose(allocator, false);
    try prepareClose(allocator, true);
    for ([_][]const u8{ "", "a\n", "\n", "a😀e\u{301} אבג" }) |text| try caretCase(allocator, text);
    try affineCase(allocator);
    const native_before = a.resourceCounts();
    const text_before = t.resourceCounts();
    try point_cases.run(allocator, renderer);
    try std.testing.expectEqualDeep(native_before, a.resourceCounts());
    try std.testing.expectEqualDeep(text_before, t.resourceCounts());
}
fn caretCase(allocator: std.mem.Allocator, text: []const u8) !void {
    const before = a.resourceCounts();
    var state: State = .{ .document = undefined, .adapter = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    state.document = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
    defer state.document.close() catch unreachable;
    state.adapter = try e.Adapter.create(allocator, state.document, engine, .{});
    defer state.adapter.close() catch unreachable;
    state.window = try app.createWindow(.{ .width = 320, .height = 140 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    state.parameters.scale = (try state.window.contentSize()).scale;
    _ = try state.adapter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    state.bridge = try a.Bridge.create(allocator, state.window, &.{.{ .adapter = state.adapter, .name = "Caret geometry" }}, .{});
    defer {
        state.bridge.?.close() catch unreachable;
        state.bridge = null;
        app.dispatch() catch unreachable;
        std.debug.assert(std.meta.eql(before, a.resourceCounts()));
    }
    try state.bridge.?.attachContext(&state.context);
    try state.refresh();
    try state.paint();
    const provider = try state.bridge.?.retainProvider(0);
    defer zda_probe_release(provider);
    var carets: [512]e.GeometryCaret = undefined;
    var lines: [64]e.GeometryLine = undefined;
    const exported = try state.adapter.preparedCarets(try state.document.version(), &carets, &lines, .{});
    try std.testing.expect(exported.lines.len != 0 and exported.carets.len != 0);
    if (text.len == 0) {
        try std.testing.expectEqual(@as(usize, 1), exported.lines.len);
        try std.testing.expectEqual(@as(u32, 0), (try rects(provider)).count);
        try checkHr(zda_probe_empty_visible(provider, 0));
    } else if (text[text.len - 1] == '\n') {
        const last = exported.lines[exported.lines.len - 1];
        for (exported.carets[last.first..][0..last.count]) |caret| try std.testing.expectEqual(text.len, caret.position);
    }
    for (exported.carets) |caret| try std.testing.expectEqual(@as(f32, 0), caret.rect.width);
    const saved = carets[0];
    const saved_line = lines[0];
    try std.testing.expectError(error.CaretCapacityExceeded, state.adapter.preparedCarets(try state.document.version(), carets[0..0], &lines, .{}));
    try std.testing.expectEqualDeep(saved, carets[0]);
    try std.testing.expectEqualDeep(saved_line, lines[0]);
    try std.testing.expectError(error.CaretCapacityExceeded, state.adapter.preparedCarets(try state.document.version(), &carets, lines[0..0], .{}));
    try std.testing.expectEqualDeep(saved, carets[0]);
    try std.testing.expectEqualDeep(saved_line, lines[0]);
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    if (c.ClientToScreen(state.window.nativeHandle(), &origin) == 0) return error.ClientOriginFailed;
    var element_bounds: [4]f64 = undefined;
    try checkHr(zda_probe_bounds(provider, &element_bounds, @as(f64, @floatFromInt(origin.x)) + (bounds.x + 1) * exported.scale, @as(f64, @floatFromInt(origin.y)) + (bounds.y + 1) * exported.scale));
    try std.testing.expectApproxEqAbs(@as(f64, bounds.width) * exported.scale, element_bounds[2], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, bounds.height) * exported.scale, element_bounds[3], 0.001);
    var caret_position: u32 = undefined;
    var caret_active: i32 = undefined;
    try checkHr(zda_probe_caret(provider, &caret_position, &caret_active));
    try std.testing.expectEqual(@as(u32, @intCast(try state.document.utf16Offset((try state.document.selection()).caret))), caret_position);
    try std.testing.expectEqual(@as(i32, 0), caret_active);
    for (exported.lines) |line| {
        for (0..24) |at| {
            const point: ui.layout.Point = .{ .x = bounds.x + (bounds.width - 1) * @as(f32, @floatFromInt(at)) / 23, .y = line.rect.y + line.rect.height / 2 };
            const hit = try state.adapter.hitTest(bounds, point);
            var actual: u32 = undefined;
            try checkHr(zda_probe_point(provider, @as(f64, @floatFromInt(origin.x)) + point.x * exported.scale, @as(f64, @floatFromInt(origin.y)) + point.y * exported.scale, &actual));
            try std.testing.expectEqual(@as(u32, @intCast(try state.document.utf16Offset(hit.byte_offset))), actual);
        }
    }
}
const AffineOracle = struct {
    const PointCheck = struct { x: f64, y: f64, position: u32 };
    provider: *anyopaque,
    values: [2048]f64 = undefined,
    len: usize = 0,
    points: [128]PointCheck = undefined,
    point_count: usize = 0,
    outside: ?ui.affine.Point = null,
    failure: ?anyerror = null,
    fn run(self: *@This()) void {
        self.checked() catch |err| {
            self.failure = err;
        };
    }
    fn checked(self: *@This()) !void {
        try checkHr(c.CoInitializeEx(null, c.COINIT_MULTITHREADED));
        defer c.CoUninitialize();
        var output: [2048]f64 = undefined;
        var count: u32 = 0;
        try checkHr(zda_probe_all_rectangles(self.provider, &output, output.len, &count));
        try std.testing.expectEqual(self.len, count);
        for (output[0..count], self.values[0..self.len]) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 0.002);
        for (self.points[0..self.point_count]) |point| {
            var offset: u32 = undefined;
            try checkHr(zda_probe_point(self.provider, point.x, point.y, &offset));
            if (point.position != offset) std.debug.print("affine point x={d} y={d} expected={d} actual={d}\n", .{ point.x, point.y, point.position, offset });
            try std.testing.expectEqual(point.position, offset);
        }
        if (self.outside) |point| {
            var offset: u32 = undefined;
            try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80070057))), zda_probe_point(self.provider, point.x, point.y, &offset));
        }
    }
    fn verify(self: *@This()) !void {
        const worker = try std.Thread.spawn(.{}, run, .{self});
        worker.join();
        if (self.failure) |err| return err;
    }
};
fn affineCase(allocator: std.mem.Allocator) !void {
    const baseline = a.resourceCounts();
    var state: State = .{ .document = undefined, .adapter = undefined, .affine_matrix = .{ .xy = 0.35, .x0 = 30, .y0 = 20 } };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    state.document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀e\u{301} אבג\nsecond line\n", .{});
    defer state.document.close() catch unreachable;
    state.adapter = try e.Adapter.create(allocator, state.document, engine, .{});
    defer state.adapter.close() catch unreachable;
    state.window = try app.createWindow(.{ .width = 560, .height = 360 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        state.adapter.unbind() catch unreachable;
    }
    const size = try state.window.contentSize();
    state.parameters.scale = size.scale;
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try state.context.prepareTransforms(allocator, .{ .layers = .{ .size = size, .max_depth = 2 }, .source_size = .{ .width = 320, .height = 140 } });
    _ = try state.adapter.prepare(bounds, state.parameters);
    try state.adapter.bind(state.window);
    state.bridge = try a.Bridge.create(allocator, state.window, &.{.{ .adapter = state.adapter, .name = "Affine Document" }}, .{ .cells = 512, .carets = 512, .lines = 64, .affine_geometry = true });
    defer {
        state.bridge.?.close() catch unreachable;
        state.bridge = null;
        app.dispatch() catch unreachable;
        std.debug.assert(std.meta.eql(baseline, a.resourceCounts()));
    }
    try state.bridge.?.attachContext(&state.context);
    try state.refresh();
    try state.paint();
    try state.adapter.setCommittedSpace(try state.context.committedSpace(91));
    // The retained client remains bound to its local coordinate authority.
    try state.bridge.?.prepareGeometry(&.{null});
    const provider = try state.bridge.?.retainProvider(0);
    defer zda_probe_release(provider);
    const matrices = [_]ui.affine.Affine{
        .{ .xy = 0.35, .x0 = 30, .y0 = 20 },
        .{ .xx = -0.8, .yy = 1.1, .x0 = 350, .y0 = 30 },
        try (try ui.affine.Affine.rotation(0.35)).then(.{ .xx = 0.8, .yy = 0.8, .x0 = 100, .y0 = 20 }),
    };
    var previous: ?AffineOracle = null;
    for (matrices, 0..) |matrix, iteration| {
        state.affine_matrix = matrix;
        state.affine_clip = if (iteration == 2) .{ .x = 80.25, .y = 30.5, .width = 120.25, .height = 90.25 } else null;
        try state.paint();
        var oracle: AffineOracle = .{ .provider = provider };
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        if (c.ClientToScreen(state.window.nativeHandle(), &origin) == 0) return error.ClientOriginFailed;
        const mapping = state.mapping.?;
        var geometry: ui.affine.GeometryTable(2, 4) = .{};
        const window_clip = try geometry.addClip(.identity, null, .{ .width = @as(f64, @floatFromInt(size.width)) / size.scale, .height = @as(f64, @floatFromInt(size.height)) / size.scale });
        const parent_clip = if (state.affine_clip) |clip| try geometry.addClip(.identity, window_clip, ui.affine.Rect.from(clip)) else window_clip;
        const space = try geometry.addSpace(mapping.space.to_window);
        const clip = try geometry.addClip(space, parent_clip, ui.affine.Rect.from(bounds));
        var cells: [512]e.GeometryCell = undefined;
        const exported = try state.adapter.preparedGeometry(try state.document.version(), &cells, .{});
        for (exported.cells) |cell| {
            const visible = try geometry.visibleBounds(.{ .space = space, .clip = clip }, ui.affine.Rect.from(cell.rect)) orelse continue;
            const values = [_]f64{ @as(f64, @floatFromInt(origin.x)) + visible.x * size.scale, @as(f64, @floatFromInt(origin.y)) + visible.y * size.scale, visible.width * size.scale, visible.height * size.scale };
            @memcpy(oracle.values[oracle.len..][0..4], &values);
            oracle.len += 4;
        }
        var caret_storage: [512]e.GeometryCaret = undefined;
        var line_storage: [64]e.GeometryLine = undefined;
        const positions = try state.adapter.preparedCarets(try state.document.version(), &caret_storage, &line_storage, .{});
        for (positions.lines) |line| for (0..24) |at| {
            const local: ui.affine.Point = .{ .x = bounds.x + (@as(f64, bounds.width) - 2) * @as(f64, @floatFromInt(at)) / 23 + 0.3, .y = line.rect.y + line.rect.height / 2 };
            const point = try mapping.space.windowPoint(local);
            if (!try geometry.contains(.{ .space = space, .clip = clip }, ui.affine.Rect.from(bounds), point)) continue;
            const actual = try mapping.space.localPoint(point);
            const hit = try state.adapter.hitTest(bounds, .{ .x = @floatCast(actual.x), .y = @floatCast(actual.y) });
            oracle.points[oracle.point_count] = .{ .x = @as(f64, @floatFromInt(origin.x)) + point.x * size.scale, .y = @as(f64, @floatFromInt(origin.y)) + point.y * size.scale, .position = @intCast(try state.document.utf16Offset(hit.byte_offset)) };
            oracle.point_count += 1;
        };
        try std.testing.expect(oracle.len != 0 and oracle.point_count != 0);
        try oracle.verify();
        previous = oracle;
    }
    var old = previous.?;
    state.affine_matrix.?.x0 += 20;
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try state.paint();
    try old.verify();
    state.fail_frame = false;
    state.expected = null;
    state.record_geometry = false;
    try state.paint();
    var offset: u32 = undefined;
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80040204))), zda_probe_point(provider, old.points[0].x, old.points[0].y, &offset));
    state.record_geometry = true;
    try state.paint();
    const warm = try state.bridge.?.stats();
    for (0..8) |_| try state.paint();
    const after = try state.bridge.?.stats();
    try std.testing.expectEqual(warm.requested_bytes, after.requested_bytes);
    try std.testing.expectEqual(warm.geometry_builds, after.geometry_builds);
    // The explicit provider workspace also works without renderer transforms.
    try state.adapter.clearCommittedSpace();
    state.affine_matrix = null;
    state.affine_clip = null;
    try state.paint();
    try state.context.releaseTransforms();
    try std.testing.expect(state.context.transforms == null);
    state.draw_offset = .{ .x = 12.5, .y = 5.25 };
    state.affine_clip = .{ .x = 0, .y = 0, .width = 200.25, .height = 120.25 };
    try state.paint();
    const plain = try rects(provider);
    try std.testing.expect(plain.count > 0);
    var cells: [512]e.GeometryCell = undefined;
    const local = try state.adapter.preparedGeometry(try state.document.version(), &cells, .{});
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    if (c.ClientToScreen(state.window.nativeHandle(), &origin) == 0) return error.ClientOriginFailed;
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(origin.x)) + (@as(f64, local.cells[0].rect.x) + 12.5) * size.scale, plain.x, 0.002);
    try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(origin.y)) + (@as(f64, local.cells[0].rect.y) + 5.25) * size.scale, plain.y, 0.002);
}
fn primary(allocator: std.mem.Allocator) !void {
    const baseline = a.resourceCounts();
    var state: State = .{ .document = undefined, .adapter = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    state.document = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer state.document.close() catch unreachable;
    state.adapter = try e.Adapter.create(allocator, state.document, engine, .{});
    defer state.adapter.close() catch unreachable;
    state.window = try app.createWindow(.{ .title = "Document accessibility", .width = 320, .height = 140 });
    defer {
        _ = state.window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        state.adapter.unbind() catch unreachable;
    }
    state.parameters.scale = @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96;
    try pinCreation(allocator, state.window, state.adapter, engine);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    _ = try state.adapter.prepare(bounds, state.parameters);
    try state.adapter.bind(state.window);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.bridge = try a.Bridge.create(failing.allocator(), state.window, &.{.{ .adapter = state.adapter, .name = "Full document", .changed = .{ .context = &state, .call = State.changed } }}, .{ .word_units = true });
    errdefer if (state.bridge) |bridge| {
        bridge.close() catch unreachable;
        state.bridge = null;
    };
    try state.bridge.?.attachContext(&state.context);
    try state.refresh();
    const provider = try state.bridge.?.retainProvider(0);
    var provider_owned = true;
    defer if (provider_owned) zda_probe_release(provider);
    try textEquals(provider, original, false);
    try textEquals(provider, original, true);
    const word = std.unicode.utf8ToUtf16LeStringLiteral("second");
    const expected_word = std.unicode.utf8ToUtf16LeStringLiteral("second ");
    var word_text: [32]u16 = undefined;
    var word_length: u32 = 0;
    try checkHr(zda_probe_word_text(provider, word, word.len, &word_text, word_text.len, &word_length));
    try std.testing.expectEqualSlices(u16, expected_word, word_text[0..word_length]);
    try std.testing.expectEqual(@as(u32, 0), (try rects(provider)).count);
    try state.paint();
    const front = try rects(provider);
    try std.testing.expect(front.count != 0);
    try allocationFailures(&state, &failing, provider);
    const builds = (try state.bridge.?.stats()).text_builds;
    _ = try state.adapter.setSelection(.{ .anchor = 1, .caret = 5 }, .downstream);
    _ = try state.adapter.prepare(bounds, state.parameters);
    try state.bridge.?.prepareText(&.{null});
    try state.bridge.?.prepareGeometry(&.{null});
    try std.testing.expectEqual(builds, (try state.bridge.?.stats()).text_builds);
    try state.paint();
    const emoji = [_]u16{ 0xd83d, 0xde00 };
    const changes = state.changes;
    try std.testing.expectEqual(@as(i32, 0), zda_probe_select(provider, &emoji, emoji.len));
    _ = try state.adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    const stale_revision = try state.document.version();
    state.expected = error.StaleRevision;
    try app.dispatch();
    state.expected = null;
    try std.testing.expectEqual(changes, state.changes);
    try std.testing.expectEqual(stale_revision, try state.document.version());
    try state.refresh();
    try state.paint();
    try std.testing.expectEqual(@as(i32, 0), zda_probe_select(provider, &emoji, emoji.len));
    const old_version = try state.document.version();
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), state.changes);
    try std.testing.expectEqual(old_version + 1, try state.document.version());
    try std.testing.expectEqual(d.Selection{ .anchor = 1, .caret = 5 }, try state.document.selection());
    try state.paint();
    const last_word = [_]u16{ 'l', 'a', 's', 't' };
    state.fail_changed = true;
    state.expected = error.PresentationFailed;
    try std.testing.expectEqual(@as(i32, 0), zda_probe_select(provider, &last_word, last_word.len));
    try app.dispatch();
    state.fail_changed = false;
    state.expected = null;
    var selected_text: [32]u16 = undefined;
    var selected_len: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), zda_probe_selection(provider, &selected_text, selected_text.len, &selected_len));
    try std.testing.expectEqualSlices(u16, &last_word, selected_text[0..selected_len]);
    try state.refresh();
    try state.paint();
    const saved = try rects(provider);
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try std.testing.expect(try state.adapter.scrollBy(.{ .x = 0, .y = -15 }));
    try state.refresh();
    try state.paint();
    const failed = try rects(provider);
    try std.testing.expectEqual(saved, failed);
    state.fail_frame = false;
    state.expected = null;
    try state.paint();
    try state.window.setClientBounds(.{ .position = .{ .x = 160, .y = 170 }, .width = 320, .height = 140 });
    try state.bridge.?.positionChanged();
    const moved = try rects(provider);
    try std.testing.expect(moved.x != saved.x or moved.y != saved.y);
    _ = try state.adapter.scrollBy(.{ .x = 0, .y = -1000000 });
    try state.refresh();
    try state.paint();
    const before_partial = try rects(provider);
    state.expected = error.UnsupportedGeometry;
    state.partial_clip = true;
    try state.paint();
    state.partial_clip = false;
    state.expected = null;
    try std.testing.expectEqualDeep(before_partial, try rects(provider));
    try state.paint();
    var client: Client = .{ .state = &state, .provider = provider, .hwnd = state.window.nativeHandle(), .fence = c.CreateEventW(null, 1, 0, null) };
    try client.capturePoints();
    if (client.fence == null) return error.CreateEventFailed;
    defer _ = c.CloseHandle(client.fence);
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    const worker = try std.Thread.spawn(.{}, Client.worker, .{&client});
    try app.run();
    watchdog.stop();
    worker.join();
    if (client.failure) |err| return err;
    try std.testing.expect(!watchdog.expired and state.bridge == null);
    var output: [32]u16 = undefined;
    var len: u32 = 0;
    try std.testing.expect(zda_probe_read(provider, &output, output.len, &len) < 0);
    try app.dispatch();
    try state.adapter.unbind();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    // This caller-owned ref intentionally remains until after native cleanup.
    zda_probe_release(provider);
    provider_owned = false;
    const after = a.resourceCounts();
    try std.testing.expectEqual(baseline, after);
    if (state.failure) |err| return err;
    std.debug.print("document accessibility: complete text, MTA snapshots, same Prepared geometry, selection posts, failed front, move, close resources=0\n", .{});
}
fn allocationFailures(state: *State, failing: *std.testing.FailingAllocator, provider: *anyopaque) !void {
    const saved = try rects(provider);
    for (0..2) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, state.bridge.?.prepareGeometry(&.{null}));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(saved, try rects(provider));
    }
    const end = try state.document.byteLength();
    _ = try state.adapter.replace(.{ .start = end, .end = end }, "!");
    const snapshot = try state.document.snapshot();
    const reader = try snapshot.borrowReader();
    var reader_owned = true;
    defer if (reader_owned) reader.release() catch unreachable;
    var snapshot_owned = true;
    defer if (snapshot_owned) snapshot.close() catch unreachable;
    for (0..3) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, state.bridge.?.prepareText(&.{reader}));
        failing.fail_index = std.math.maxInt(usize);
        try textEquals(provider, original, false);
        try std.testing.expectEqual(saved, try rects(provider));
    }
    try state.bridge.?.prepareText(&.{reader});
    try textEquals(provider, original ++ "!", false);
    try reader.release();
    reader_owned = false;
    try snapshot.close();
    snapshot_owned = false;
    _ = try state.adapter.undo();
    try state.refresh();
    try state.paint();
    try textEquals(provider, original, true);
    failing.fail_index = failing.alloc_index;
    const builds = (try state.bridge.?.stats()).text_builds;
    for (0..64) |at| {
        _ = try state.adapter.setSelection(.{ .anchor = at % 2, .caret = at % 2 }, .downstream);
        try state.bridge.?.updateMetadata();
    }
    try std.testing.expectEqual(builds, (try state.bridge.?.stats()).text_builds);
    failing.fail_index = std.math.maxInt(usize);
}
const PinAllocation = struct {
    source: std.mem.Allocator,
    target: *e.Adapter,
    attempted: bool = false,
    pinned: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (!self.attempted) {
            self.attempted = true;
            if (self.target.close()) |_| return null else |err| {
                self.pinned = err == error.ClientsAlive;
            }
        }
        return self.source.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ra);
    }
};
const CloseSourcePins = struct {
    source: std.mem.Allocator,
    adapters: [2]*e.Adapter,
    shell: ?*a.Bridge = null,
    armed: bool = false,
    attempted: [2]bool = .{ false, false },
    retained: [2]bool = .{ false, false },
    released: [2]bool = .{ false, false },
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            const shell = self.shell != null and @intFromPtr(bytes.ptr) == @intFromPtr(self.shell.?);
            const at: usize = if (shell) 1 else 0;
            if (!self.attempted[at]) {
                self.attempted[at] = true;
                if (self.adapters[at].close()) |_| {
                    self.released[at] = true;
                } else |err| {
                    self.retained[at] = err == error.ClientsAlive;
                }
            }
            if (shell) self.armed = false;
        }
        self.source.rawFree(bytes, alignment, ra);
    }
    fn validate(_: *anyopaque, _: z.Window, _: u64, _: a.auxiliary.Key) !void {}
    fn action(_: *anyopaque, _: z.Window, _: a.AuxiliaryAction) !void {}
};
fn sourcePinsDuringClose(allocator: std.mem.Allocator) !void {
    const baseline = a.resourceCounts();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const documents = [2]*d.Document{ try d.Document.create(allocator, std.Thread.getCurrentId(), "A", .{}), try d.Document.create(allocator, std.Thread.getCurrentId(), "B", .{}) };
    defer for (documents) |document| document.close() catch unreachable;
    var hook: CloseSourcePins = .{ .source = allocator, .adapters = .{ try e.Adapter.create(allocator, documents[0], engine, .{}), try e.Adapter.create(allocator, documents[1], engine, .{}) } };
    defer for (hook.adapters, hook.released) |adapter, released| if (!released) {
        adapter.close() catch unreachable;
    };
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    const bridge = try a.Bridge.create(hook.allocator(), window, &.{ .{ .adapter = hook.adapters[0], .name = "A" }, .{ .adapter = hook.adapters[1], .name = "B" } }, .{ .presentation_epochs = true, .auxiliary = .{ .limits = .{ .nodes = 2, .label_bytes = 32 }, .handler = .{ .context = &hook, .validate = CloseSourcePins.validate, .call = CloseSourcePins.action } } });
    hook.shell = bridge;
    hook.armed = true;
    try bridge.close();
    try app.dispatch();
    std.debug.print("document close source pins: scratch={any}/{any}, final={any}/{any}\n", .{ hook.attempted[0], hook.retained[0], hook.attempted[1], hook.retained[1] });
    try std.testing.expectEqual(baseline, a.resourceCounts());
    try std.testing.expect(hook.attempted[0] and hook.retained[0] and hook.attempted[1] and hook.retained[1]);
    for (hook.adapters, &hook.released) |adapter, *released| {
        try adapter.close();
        released.* = true;
    }
}
fn pinCreation(allocator: std.mem.Allocator, window: z.Window, main_adapter: *e.Adapter, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "read-only ghost", .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    var hook: PinAllocation = .{ .source = allocator, .target = adapter };
    const sources = [_]a.Source{ .{ .adapter = main_adapter, .name = "Modified" }, .{ .adapter = adapter, .name = "Original", .read_only = true, .selectable = false, .focusable = false } };
    const bridge = try a.Bridge.create(hook.allocator(), window, &sources, .{});
    try std.testing.expect(hook.attempted and hook.pinned);
    try bridge.close();
    try window.app.dispatch();
    for (0..3) |at| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = at });
        try std.testing.expectError(error.OutOfMemory, a.Bridge.create(failing.allocator(), window, &sources, .{ .affine_geometry = true }));
        try window.app.dispatch();
    }
}
fn stopCase(allocator: std.mem.Allocator) !void {
    const before = a.resourceCounts();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "stop participant", .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const window = try app.createWindow(.{});
    const bridge = try a.Bridge.create(allocator, window, &.{.{ .adapter = adapter, .name = "Stop" }}, .{});
    app.quit();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    try std.testing.expectError(error.Closed, bridge.stats());
    try bridge.close();
    try std.testing.expectEqual(before, a.resourceCounts());
}
const CloseAllocation = struct {
    source: std.mem.Allocator,
    window: z.Window = undefined,
    armed: bool = false,
    raw: bool,
    inside_free: bool = false,
    released: bool = false,
    closed: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.source.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.inside_free = true;
            if (self.raw) std.debug.assert(c.DestroyWindow(self.window.nativeHandle()) != 0) else _ = self.window.destroy() catch unreachable;
            std.debug.assert(!self.closed);
            self.inside_free = false;
        }
        if (bytes.len == @sizeOf(a.Bridge)) self.released = true;
        self.source.rawFree(bytes, alignment, ra);
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.released and !self.inside_free);
        self.closed = true;
    }
};
fn closeReentry(allocator: std.mem.Allocator, raw: bool) !void {
    const before = a.resourceCounts();
    var hook: CloseAllocation = .{ .source = allocator, .raw = raw };
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "close", .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    hook.window = try app.createWindow(.{ .on_closed = .{ .context = &hook, .notify = CloseAllocation.onClosed } });
    const bridge = try a.Bridge.create(hook.allocator(), hook.window, &.{.{ .adapter = adapter, .name = "Closing" }}, .{});
    hook.armed = true;
    try bridge.close();
    try std.testing.expect(hook.released and !hook.closed);
    try app.dispatch();
    try std.testing.expect(hook.closed);
    try std.testing.expectEqual(before, a.resourceCounts());
}
const Filtered = struct {
    adapters: [2]*e.Adapter,
    bridge: ?*a.Bridge = null,
    context: ui.Context = undefined,
    failure: ?anyerror = null,
    mapped: bool = false,
    skip_second: bool = false,
    columns: [2]ui.Rect = .{ .{ .x = 5, .y = 5, .width = 150, .height = 130 }, .{ .x = 170, .y = 5, .width = 150, .height = 130 } },
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *@This(), frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.mapped) try frame.beginTransform(.{ .width = 340, .height = 150 }, .{ .xy = 0.2, .x0 = 5, .y0 = 5 });
        try self.adapters[0].drawParagraphs(frame, self.columns[0], &.{ 0, 2 }, ui.Color.rgb(0x202020));
        if (self.mapped) {
            try self.bridge.?.recordSourceGeometry(frame, 0);
            try frame.endTransform();
            try frame.beginTransform(.{ .width = 340, .height = 150 }, .{ .xx = -0.8, .x0 = 320, .y0 = 5 });
        }
        try self.adapters[1].draw(frame, self.columns[1], .{});
        if (self.mapped) {
            if (!self.skip_second) try self.bridge.?.recordSourceGeometry(frame, 1);
            try frame.endTransform();
        } else try self.bridge.?.recordGeometry(frame);
    }
};
fn filteredSources(allocator: std.mem.Allocator, mapped: bool) !void {
    const baseline = a.resourceCounts();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const a_text = "ghost0\nkeepA\nghost2\nendA";
    const b_text = "unique B 😀";
    const documents = [_]*d.Document{ try d.Document.create(allocator, std.Thread.getCurrentId(), a_text, .{}), try d.Document.create(allocator, std.Thread.getCurrentId(), b_text, .{}) };
    defer for (documents) |document| document.close() catch unreachable;
    const adapters = [_]*e.Adapter{ try e.Adapter.create(allocator, documents[0], engine, .{}), try e.Adapter.create(allocator, documents[1], engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    var state: Filtered = .{ .adapters = adapters, .mapped = mapped };
    const plan = try e.ProjectionPlan.create(allocator, documents[0], &.{}, .{});
    defer plan.close() catch unreachable;
    try adapters[0].setProjection(plan);
    defer adapters[0].setProjection(null) catch unreachable;
    const window = try app.createWindow(.{ .width = 340, .height = 150 });
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    state.context = ui.Context.init(&state, Filtered.draw, Filtered.action);
    state.context.render_mode = .gdi;
    try state.context.attach(window);
    if (mapped) try state.context.prepareTransforms(allocator, .{ .layers = .{ .size = try window.contentSize(), .max_depth = 2 }, .source_size = .{ .width = 340, .height = 150 } });
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96;
    for (adapters, state.columns) |adapter, column| _ = try adapter.prepare(column, .{ .font = .{ .size = 18, .width = column.width }, .scale = scale });
    state.bridge = try a.Bridge.create(allocator, window, &.{ .{ .adapter = adapters[0], .name = "Original", .read_only = true, .selectable = false, .focusable = false }, .{ .adapter = adapters[1], .name = "Modified", .focusable = false } }, .{ .affine_geometry = mapped });
    try state.bridge.?.attachContext(&state.context);
    var snapshots: [2]*d.Snapshot = undefined;
    var readers: [2]?d.Reader = undefined;
    for (documents, 0..) |document, at| {
        snapshots[at] = try document.snapshot();
        readers[at] = try snapshots[at].borrowReader();
    }
    try state.bridge.?.prepareText(&readers);
    for (readers, snapshots) |reader, snapshot| {
        try reader.?.release();
        try snapshot.close();
    }
    try state.bridge.?.prepareGeometry(&.{ @as(?[]const usize, &.{ 0, 2 }), null });
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    if (state.failure) |err| return err;
    const original_provider = try state.bridge.?.retainProvider(0);
    const modified_provider = try state.bridge.?.retainProvider(1);
    try textEquals(original_provider, a_text, true);
    try textEquals(modified_provider, b_text, true);
    // Both source slots use their real Prepared data; the source-zero filter
    // authorizes only actual drawn lines, without truncating hit candidates.
    const size = try window.contentSize();
    for (adapters, documents, [_]*anyopaque{ original_provider, modified_provider }, 0..) |adapter, document, provider, side| {
        const matrix: ui.affine.Affine = if (!mapped) .{} else if (side == 0) .{ .xy = 0.2, .x0 = 5, .y0 = 5 } else .{ .xx = -0.8, .x0 = 320, .y0 = 5 };
        const coordinates = try point_oracle.Coordinates.init(window.nativeHandle(), scale, matrix, .{});
        var checks: point_oracle.Batch = .{ .provider = provider };
        var carets: [512]e.GeometryCaret = undefined;
        var lines: [64]e.GeometryLine = undefined;
        const selected: ?[]const usize = if (side == 0) &.{ 0, 2 } else null;
        const visible = try adapter.preparedCarets(try document.version(), &carets, &lines, .{ .paragraphs = selected });
        for (visible.lines) |line| for (0..12) |at| {
            const point: ui.affine.Point = .{ .x = state.columns[side].x + 0.25 + @as(f64, @floatFromInt(at)) * 12, .y = line.rect.y + line.rect.height / 2 };
            const window_point = coordinates.window(point);
            if (mapped and (window_point.x < 0 or window_point.y < 0 or window_point.x >= @as(f64, @floatFromInt(size.width)) / size.scale or window_point.y >= @as(f64, @floatFromInt(size.height)) / size.scale)) continue;
            try checks.append(adapter, document, state.columns[side], coordinates, point);
        };
        if (side == 0) {
            const omitted_position = (try document.line(1)).start;
            const omitted_caret = (try adapter.positionRect(try document.version(), omitted_position, .downstream)) orelse return error.OmittedParagraphNotPrepared;
            const point: ui.affine.Point = .{ .x = state.columns[side].x + 1, .y = omitted_caret.y + omitted_caret.height / 2 };
            const window_point = coordinates.window(point);
            if (!mapped or (window_point.x >= 0 and window_point.y >= 0 and window_point.x < @as(f64, @floatFromInt(size.width)) / size.scale and window_point.y < @as(f64, @floatFromInt(size.height)) / size.scale)) try checks.deny(coordinates, point, point_oracle.invalid_argument);
        }
        try std.testing.expect(checks.len != 0);
        try checks.verify();
        std.debug.print("two-source Prepared point slot={d} mapped={} owner+MTA={d}\n", .{ side, mapped, checks.len });
    }
    const omitted = [_]u16{ 'k', 'e', 'e', 'p', 'A' };
    const drawn = [_]u16{ 'g', 'h', 'o', 's', 't', '2' };
    var count: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), zda_probe_match_rectangles(original_provider, &omitted, omitted.len, &count));
    try std.testing.expectEqual(@as(u32, 0), count);
    try std.testing.expectEqual(@as(i32, 0), zda_probe_match_rectangles(original_provider, &drawn, drawn.len, &count));
    try std.testing.expect(count > 0);
    const selection = try documents[0].selection();
    try std.testing.expect(zda_probe_select(original_provider, &drawn, drawn.len) < 0);
    try app.dispatch();
    try std.testing.expectEqual(selection, try documents[0].selection());
    try std.testing.expect(zda_probe_match_rectangles(modified_provider, &omitted, omitted.len, &count) < 0);
    if (mapped) {
        state.skip_second = true;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (state.failure) |err| return err;
        try std.testing.expectEqual(@as(u32, 0), (try rects(original_provider)).count);
        try std.testing.expectEqual(@as(u32, 0), (try rects(modified_provider)).count);
        state.skip_second = false;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        if (state.failure) |err| return err;
        try std.testing.expect((try rects(original_provider)).count > 0 and (try rects(modified_provider)).count > 0);
    }
    try state.bridge.?.close();
    state.bridge = null;
    zda_probe_release(original_provider);
    zda_probe_release(modified_provider);
    try app.dispatch();
    try std.testing.expectEqual(baseline, a.resourceCounts());
}
const PrepareClose = struct {
    source: std.mem.Allocator,
    host: *State = undefined,
    window: z.Window = undefined,
    armed: bool = false,
    raw: bool,
    closed: bool = false,
    in_allocate: bool = false,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.in_allocate = true;
            if (self.raw) std.debug.assert(c.DestroyWindow(self.window.nativeHandle()) != 0) else _ = self.window.destroy() catch unreachable;
            self.window.app.dispatch() catch unreachable;
            std.debug.assert(!self.closed);
            self.in_allocate = false;
        }
        return self.source.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.source.rawFree(bytes, alignment, ra);
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(!self.in_allocate);
        self.host.bridge.?.close() catch unreachable;
        self.source.destroy(self.host);
        self.closed = true;
    }
};
fn prepareClose(allocator: std.mem.Allocator, raw: bool) !void {
    const baseline = a.resourceCounts();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    var hook: PrepareClose = .{ .source = allocator, .raw = raw };
    hook.host = try allocator.create(State);
    hook.host.* = .{ .document = document, .adapter = adapter };
    hook.window = try app.createWindow(.{ .on_closed = .{ .context = &hook, .notify = PrepareClose.onClosed } });
    hook.host.window = hook.window;
    hook.host.context = ui.Context.init(hook.host, State.draw, State.action);
    hook.host.context.render_mode = .gdi;
    try hook.host.context.attach(hook.window);
    _ = try adapter.prepare(bounds, .{});
    hook.host.bridge = try a.Bridge.create(hook.allocator(), hook.window, &.{.{ .adapter = adapter, .name = "Prepare close" }}, .{});
    try hook.host.bridge.?.attachContext(&hook.host.context);
    const snapshot = try document.snapshot();
    const reader = try snapshot.borrowReader();
    try hook.host.bridge.?.prepareText(&.{reader});
    try reader.release();
    try snapshot.close();
    const bridge = hook.host.bridge.?;
    hook.armed = true;
    try std.testing.expectError(error.Closed, bridge.prepareGeometry(&.{null}));
    try std.testing.expect(!hook.closed);
    try app.dispatch();
    try std.testing.expect(hook.closed);
    try std.testing.expectEqual(baseline, a.resourceCounts());
}
fn capacityCase(allocator: std.mem.Allocator) !void {
    const baseline = a.resourceCounts();
    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc", .{});
    defer document.close() catch unreachable;
    const adapter = try e.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    _ = try adapter.prepare(bounds, .{});
    const snapshot = try document.snapshot();
    const reader = try snapshot.borrowReader();
    defer {
        reader.release() catch unreachable;
        snapshot.close() catch unreachable;
    }
    const bridge = try a.Bridge.create(allocator, window, &.{.{ .adapter = adapter, .name = "Capacity" }}, .{ .bytes = 16 * 1024 });
    try bridge.prepareText(&.{reader});
    const provider = try bridge.retainProvider(0);
    try std.testing.expectError(error.CapacityExceeded, bridge.prepareGeometry(&.{null}));
    try textEquals(provider, "abc", false);
    const stats = try bridge.stats();
    try std.testing.expect(stats.peak_reserved_bytes <= stats.byte_limit and stats.host_staging_bytes == 0);
    const WrongThread = struct {
        fn run(value: *a.Bridge) void {
            std.testing.expectError(error.WrongThread, value.stats()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.close()) catch unreachable;
            std.testing.expectError(error.WrongThread, value.prepareText(&.{null})) catch unreachable;
        }
    };
    const worker = try std.Thread.spawn(.{}, WrongThread.run, .{bridge});
    worker.join();
    try bridge.close();
    zda_probe_release(provider);
    try app.dispatch();
    const output = try a.Bridge.create(allocator, window, &.{.{ .adapter = adapter, .name = "Output quota" }}, .{ .output_units = 2 });
    try std.testing.expectError(error.CapacityExceeded, output.prepareText(&.{reader}));
    try output.close();
    try app.dispatch();
    try std.testing.expectEqual(baseline, a.resourceCounts());
}
