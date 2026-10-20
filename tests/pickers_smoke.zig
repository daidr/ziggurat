const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const i18n = @import("ziggurat_i18n");
const pickers = @import("ziggurat_view_pickers");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;

const width = 480;
const height = 640;

fn nativePaint(window: z.Window) void {
    if (builtin.os.tag == .windows) {
        const hwnd: c.HWND = window.nativeHandle();
        _ = c.InvalidateRect(hwnd, null, 0);
        _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    } else {
        const scope = window.beginCallback().?;
        defer scope.end();
        zlg_test_paint(scope.record.native.native.?, width, height);
    }
}

const State = struct {
    region: pickers.Region,
    date: pickers.Date = .{ .year = 2024, .month = 3, .day = 15 },
    date_state: pickers.DateInput = .{},
    time: pickers.TimeOfDay = .{ .hour = 9, .minute = 30 },
    time_state: pickers.TimeInput = .{},
    amount: f64 = 2,
    amount_state: pickers.NumberInput = .{},
    fill: pickers.Rgba = pickers.Rgba.rgb(0x3b82f6),
    fill_state: pickers.ColorWell = .{},

    fn build(self: *State, v: *view.View) anyerror!void {
        try v.column(.{ .gap = 8, .padding = .{ .top = 12, .left = 12 }, .alignment = .start });
        _ = try pickers.dateInput(v, &self.date_state, &self.date, .{ .calendar = .{ .region = self.region }, .style = .{ .name = "Due" } });
        _ = try pickers.timeInput(v, &self.time_state, &self.time, .{ .region = self.region, .style = .{ .name = "Start" } });
        _ = try pickers.numberInput(v, &self.amount_state, &self.amount, .{ .minimum = 0, .maximum = 10, .step = 0.5 }, .{ .region = self.region, .style = .{ .name = "Amount" } });
        _ = try pickers.colorWell(v, &self.fill_state, &self.fill, .{ .style = .{ .name = "Fill" } });
        try v.end();
    }
};

fn find(host: *const view.Host, kind: view.Kind, nth: usize) !view.Node {
    var seen: usize = 0;
    for (host.view.nodes()) |node| if (node.kind == kind) {
        if (seen == nth) return node;
        seen += 1;
    };
    return error.MissingNode;
}

fn paint(host: *view.Host, window: z.Window) !void {
    const before = host.frames;
    nativePaint(window);
    if (host.last_error) |err| return err;
    try std.testing.expectEqual(before + 1, host.frames);
}

/// A key through the window's Context, then the frame and the posted focus
/// a window would see next.
fn key(host: *view.Host, app: *z.App, window: z.Window, code: z.KeyCode) !void {
    _ = host.context.handleKeyInput(window, .{ .key = code });
    if (host.last_error) |err| return err;
    try paint(host, window);
    try app.dispatch();
    try paint(host, window);
}

fn focused(host: *const view.Host) ?u64 {
    return host.context.input_state.focused;
}

fn run(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var state: State = .{ .region = .{ .locale = try i18n.Locale.parse("en-US") } };
    var storage: view.Storage(128, 1024) = .{};
    var host = view.Host.init(&state, State.build, storage.buffers(), .{});
    host.context.render_mode = .gdi;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try host.attach(window);
    try paint(&host, window);

    // Enter on the date field opens the calendar with focus on its days;
    // the arrows move without choosing and Enter chooses, closing it with
    // focus back on the field.
    const field = try find(&host, .popup_button, 0);
    host.context.input_state.setFocused(field.id);
    try key(&host, app, window, .enter);
    try std.testing.expect(state.date_state.open);
    const grid = state.date_state.calendar.grid.id;
    try std.testing.expectEqual(@as(?u64, grid), focused(&host));
    try key(&host, app, window, .right);
    try key(&host, app, window, .down);
    try std.testing.expectEqual(pickers.Date{ .year = 2024, .month = 3, .day = 15 }, state.date);
    try key(&host, app, window, .enter);
    try std.testing.expectEqual(pickers.Date{ .year = 2024, .month = 3, .day = 23 }, state.date);
    try std.testing.expect(!state.date_state.open);
    try std.testing.expectEqual(@as(?u64, field.id), focused(&host));
    try std.testing.expectEqualStrings("3/23/24", (try find(&host, .popup_button, 0)).text);

    // The time field steps its hours and takes typed minutes.
    host.context.input_state.setFocused(state.time_state.leaf.id);
    try key(&host, app, window, .up);
    try std.testing.expectEqual(@as(u5, 10), state.time.hour);
    try key(&host, app, window, .right);
    try key(&host, app, window, .digit4);
    try key(&host, app, window, .digit5);
    try std.testing.expectEqual(@as(u6, 45), state.time.minute);

    // The number field steps through the Context and applies typed text.
    host.context.input_state.setFocused(state.amount_state.leaf.id);
    try key(&host, app, window, .up);
    try std.testing.expectEqual(@as(f64, 2.5), state.amount);
    try key(&host, app, window, .digit7);
    try std.testing.expectEqual(@as(f64, 7), state.amount);

    // The color well opens its picker with focus in it; the square's keys
    // change the color and Escape closes it with focus back on the well.
    const well = try find(&host, .embed, 2);
    host.context.input_state.setFocused(well.id);
    try key(&host, app, window, .space);
    try std.testing.expect(state.fill_state.open);
    try std.testing.expectEqual(@as(?u64, state.fill_state.picker.square.id), focused(&host));
    const before = state.fill;
    try key(&host, app, window, .down);
    try std.testing.expect(!before.eql(state.fill));
    try key(&host, app, window, .escape);
    try std.testing.expect(!state.fill_state.open);
    try std.testing.expectEqual(@as(?u64, well.id), focused(&host));

    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expect(host.context.window == null);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    try run(gpa.allocator());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("pickers native: date popover focus and choice, time segments, number stepping and typing, color well popover passed\n", .{});
}
