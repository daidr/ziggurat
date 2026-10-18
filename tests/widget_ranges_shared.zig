const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
pub const scalar_spec: ui.Range = .{ .minimum = 0, .maximum = 100, .step = 5, .page_step = 20 };
pub const step_spec: ui.Range = .{ .minimum = 0, .maximum = 10, .step = 1, .page_step = 4 };
pub const editor_bounds: ui.Rect = .{ .x = 0, .y = 240, .width = 200, .height = 32 };
fn bounds(y: f32) ui.Rect {
    return .{ .x = 0, .y = y, .width = 200, .height = 32 };
}
pub const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    editor: ui.editor.Editor,
    frame: ?*ui.Frame = null,
    value: f64 = 20,
    pair: ui.widgets.RangeSliderOptions = .{},
    low: f64 = 25,
    high: f64 = 75,
    step: f64 = 2,
    vertical: f64 = 25,
    value_calls: usize = 0,
    text_events: usize = 0,
    actions: [40]usize = @splat(0),
    slider_enabled: bool = true,
    include_slider: bool = true,
    fail_frame: bool = false,
    close_on_value: bool = false,
    close_on_input: bool = false,
    consume_cancel: bool = false,
    cancels_seen: usize = 0,
    pinned: bool = false,
    closed: usize = 0,
    after_closed: ?z.Task = null,
    err: ?anyerror = null,
    fn measure(_: *anyopaque, text: []const u8) !f32 {
        return @as(f32, @floatFromInt(try std.unicode.utf8CountCodepoints(text))) * 10;
    }
    fn paintEditor(ptr: *anyopaque, command: ui.editor.PaintCommand) !void {
        const self: *State = @ptrCast(@alignCast(ptr));
        const frame = self.frame orelse return error.NoFrame;
        switch (command) {
            .text => |text| frame.label(text.bounds, text.text, 0x182430),
            .selection => |rect| frame.rect(rect, 0xccccff),
            .composition, .caret => |rect| frame.rect(rect, 0x000000),
        }
    }
    pub fn surface(self: *State) ui.editor.Surface {
        return .{ .context = self, .line_height = 20, .measure = measure, .paint = paintEditor };
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (event == .text_input) self.text_events += 1;
        if (event == .cancel_input) {
            self.cancels_seen += 1;
            if (self.consume_cancel) return true;
        }
        if (event == .pointer_down and self.close_on_input) {
            _ = self.window.destroy() catch |err| {
                self.err = err;
            };
            return false;
        }
        return self.editor.handleEvent(event, editor_bounds, self.surface()) catch |err| {
            // Failed editing input was still consumed. It must not become an
            // application shortcut merely because clipboard/measurement failed.
            self.err = err;
            return true;
        };
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.frame = frame;
        defer self.frame = null;
        self.drawChecked(frame) catch |err| {
            self.err = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.include_slider) try frame.slider(20, bounds(0), self.value, scalar_spec, .{ .control = .{ .name = "Volume", .enabled = self.slider_enabled } });
        try frame.rangeSlider(.{ .group = 23, .low = 21, .high = 22 }, bounds(40), .{ .low = self.low, .high = self.high }, scalar_spec, self.pair);
        try frame.stepper(24, bounds(80), self.step, step_spec, .{ .name = "Count" });
        try frame.slider(25, .{ .x = 240, .y = 0, .width = 32, .height = 160 }, self.vertical, scalar_spec, .{ .vertical = true, .control = .{ .name = "Vertical" } });
        try frame.slider(26, bounds(120), 50, scalar_spec, .{ .control = .{ .name = "Disabled range", .enabled = false } });
        try frame.buttonWithOptions(30, .{ .x = 0, .y = 160, .width = 80, .height = 32 }, "Save", .{ .shortcut = .{ .key = .s, .modifiers = .{ .control = true } } });
        try frame.buttonWithOptions(31, .{ .x = 100, .y = 160, .width = 80, .height = 32 }, "Quiet", .{ .shortcut = .{ .key = .q } });
        try frame.buttonWithOptions(32, .{ .x = 200, .y = 160, .width = 80, .height = 32 }, "Disabled", .{ .enabled = false, .shortcut = .{ .key = .f2 } });
        try frame.buttonWithOptions(33, .{ .x = 0, .y = 200, .width = 80, .height = 32 }, "Copy", .{ .shortcut = .{ .key = .c, .modifiers = .{ .control = true } } });
        try frame.buttonWithOptions(34, .{ .x = 100, .y = 200, .width = 80, .height = 32 }, "Left", .{ .shortcut = .{ .key = .left } });
        try frame.buttonWithOptions(35, .{ .x = 200, .y = 200, .width = 80, .height = 32 }, "Help", .{ .shortcut = .{ .key = .f3 } });
        try self.editor.draw(editor_bounds, self.surface());
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn action(ptr: *anyopaque, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (id < 30 or id >= self.actions.len) {
            self.err = error.UnexpectedAction;
            return;
        }
        self.actions[@intCast(id)] += 1;
    }
    fn valueChanged(ptr: *anyopaque, id: u64, change: ui.ValueChange) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.apply(id, change) catch |err| {
            self.err = err;
        };
        self.value_calls += 1;
        if (self.close_on_value) {
            _ = self.window.destroy() catch |err| {
                self.err = err;
                return;
            };
            self.pinned = self.context.window != null and self.window.isClosed();
        }
    }
    fn apply(self: *State, id: u64, change: ui.ValueChange) !void {
        self.window.app.assertOwner();
        switch (id) {
            20 => self.value = try scalar_spec.apply(self.value, change),
            21, 22 => {
                const values: ui.RangeValues = .{ .low = self.low, .high = self.high };
                const updated = if (id == 21) try scalar_spec.applyLow(values, change) else try scalar_spec.applyHigh(values, change);
                self.low = updated.low;
                self.high = updated.high;
            },
            24 => self.step = try step_spec.apply(self.step, change),
            25 => self.vertical = try scalar_spec.apply(self.vertical, change),
            else => return error.UnexpectedValue,
        }
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
        std.debug.assert(self.context.window == null);
        if (self.after_closed) |task| task.call(task.context);
    }
    pub fn attach(self: *State, app: *z.App) !void {
        self.window = try app.createWindow(.{ .width = 320, .height = 300, .on_closed = .{ .context = self, .notify = onClosed } });
        self.context = ui.Context.init(self, draw, action);
        self.context.render_mode = .gdi;
        self.context.on_input = input;
        self.context.on_value = valueChanged;
        try self.context.attach(self.window);
    }
};
fn equal(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
}

pub fn run(comptime Native: type, allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .editor = try ui.editor.Editor.init(allocator, .{}, "AB") };
    defer state.editor.deinit();
    try state.attach(app);
    Native.paint(state.window);
    try std.testing.expectEqual(@as(usize, 0), state.value_calls);
    try Native.pointer(state.window, .down, 54, 10);
    try Native.pointer(state.window, .move, 300, -20);
    try Native.pointer(state.window, .up, 300, -20);
    try equal(100, state.value);
    try std.testing.expect(state.context.input_state.active == null);
    try Native.pointer(state.window, .down, 80, 10);
    const canceled_value = state.value;
    state.consume_cancel = true;
    Native.cancel(state.window);
    state.consume_cancel = false;
    try std.testing.expect(state.cancels_seen > 0 and state.context.input_state.active == null);
    try Native.pointer(state.window, .move, 0, 10);
    try equal(canceled_value, state.value);
    try Native.pointer(state.window, .down, 80, 10);
    state.slider_enabled = false;
    Native.paint(state.window);
    const disabled_value = state.value;
    try Native.pointer(state.window, .move, 0, 10);
    try Native.pointer(state.window, .up, 0, 10);
    try equal(disabled_value, state.value);
    state.slider_enabled = true;
    Native.paint(state.window);
    try Native.pointer(state.window, .down, 80, 10);
    state.include_slider = false;
    state.fail_frame = true;
    Native.paint(state.window);
    try std.testing.expect(state.context.input_state.available(20));
    try Native.pointer(state.window, .move, 190, 10);
    try equal(100, state.value);
    state.fail_frame = false;
    Native.paint(state.window);
    const removed_value = state.value;
    try Native.pointer(state.window, .move, 0, 10);
    try Native.pointer(state.window, .up, 0, 10);
    try equal(removed_value, state.value);
    state.include_slider = true;
    Native.paint(state.window);
    try Native.pointer(state.window, .down, 50, 50);
    try Native.pointer(state.window, .move, 190, 50);
    try Native.pointer(state.window, .up, 190, 50);
    try equal(75, state.low);
    try equal(75, state.high);
    try Native.pointer(state.window, .down, 180, 50);
    try Native.pointer(state.window, .move, 0, 50);
    try Native.pointer(state.window, .up, 0, 50);
    try equal(75, state.low);
    try equal(75, state.high);
    state.low = 25;
    state.high = 75;
    Native.paint(state.window);
    const disabled_calls = state.value_calls;
    try Native.click(state.window, 50, 130);
    try std.testing.expectEqual(disabled_calls, state.value_calls);
    const before_step = state.value_calls;
    try Native.click(state.window, 100, 90);
    try Native.pointer(state.window, .down, 10, 90);
    try Native.pointer(state.window, .up, 190, 90);
    try std.testing.expectEqual(before_step, state.value_calls);
    for (0..3) |_| try Native.click(state.window, 190, 90);
    try equal(5, state.step);
    for (0..3) |_| try Native.key(state.window, .{ .key = .up });
    try equal(8, state.step);
    try Native.key(state.window, .{ .key = .page_up });
    try equal(10, state.step);
    try Native.key(state.window, .{ .key = .down });
    try equal(9, state.step);
    try Native.key(state.window, .{ .key = .home });
    try equal(0, state.step);
    try Native.key(state.window, .{ .key = .end });
    try equal(10, state.step);
    try Native.key(state.window, .{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(?u64, 22), state.context.input_state.focused);
    try Native.key(state.window, .{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(?u64, 21), state.context.input_state.focused);
    try Native.key(state.window, .{ .key = .end });
    try equal(75, state.low);
    try Native.key(state.window, .{ .key = .tab });
    try Native.key(state.window, .{ .key = .home });
    try equal(75, state.high);
    state.pair.low.enabled = false;
    Native.paint(state.window);
    try Native.click(state.window, 100, 90);
    try Native.key(state.window, .{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(?u64, 22), state.context.input_state.focused);
    try Native.key(state.window, .{ .key = .tab, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(?u64, 20), state.context.input_state.focused);
    state.pair.low.enabled = true;
    Native.paint(state.window);
    try Native.click(state.window, 256, 80);
    try Native.key(state.window, .{ .key = .end });
    try equal(100, state.vertical);
    try Native.key(state.window, .{ .key = .home });
    try equal(0, state.vertical);
    try Native.click(state.window, 10, 170);
    try Native.key(state.window, .{ .key = .right });
    try std.testing.expectEqual(@as(?u64, 31), state.context.input_state.focused);
    const save_calls = state.actions[30];
    try Native.key(state.window, .{ .key = .s, .modifiers = .{ .control = true } });
    try std.testing.expectEqual(save_calls + 1, state.actions[30]);
    try Native.key(state.window, .{ .key = .q });
    try std.testing.expectEqual(@as(usize, 1), state.actions[31]);
    try Native.key(state.window, .{ .key = .f2 });
    try std.testing.expectEqual(@as(usize, 0), state.actions[32]);
    try Native.click(state.window, 10, 250);
    _ = try state.editor.buffer.setSelection(.{ .anchor = 0, .caret = 0 });
    try Native.key(state.window, .{ .key = .left });
    try std.testing.expectEqual(@as(usize, 0), state.actions[34]);
    _ = try state.editor.buffer.selectAll();
    try Native.key(state.window, .{ .key = .c, .modifiers = .{ .control = true } });
    try std.testing.expectEqual(@as(?anyerror, error.ClipboardUnavailable), state.err);
    state.err = null;
    try std.testing.expectEqual(@as(usize, 0), state.actions[33]);
    try Native.key(state.window, .{ .key = .f3 });
    try std.testing.expectEqual(@as(usize, 1), state.actions[35]);
    try std.testing.expect(state.err == null);
    state.close_on_value = true;
    try Native.pointer(state.window, .down, 60, 10);
    try std.testing.expect(state.pinned and state.context.window != null);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), state.closed);
    try std.testing.expect(state.context.window == null and !state.context.painting);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    var input_close: State = .{ .editor = try ui.editor.Editor.init(allocator, .{}, ""), .close_on_input = true };
    defer input_close.editor.deinit();
    try input_close.attach(app);
    Native.paint(input_close.window);
    try Native.pointer(input_close.window, .down, 60, 10);
    try std.testing.expectEqual(@as(usize, 0), input_close.value_calls);
    try std.testing.expect(input_close.err == null);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), input_close.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
