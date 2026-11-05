//! Headless tests of paint order, sticky nodes, scroll snapping and the
//! other layout and style options of a node.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Harness = view.Harness;
const testing = std.testing;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};
const Storage = view.Storage(96, 4096);

/// The commands the view records for its last render, painted again into
/// `context`; they stay until the next call.
fn paintAgain(h: *Harness, context: *ui.Context) ![]const ui.commands.Command {
    context.command_buffer.reset();
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = context, .size = .{ .width = 640, .height = 480, .scale = 1 } };
    try h.view.paint(&frame);
    if (frame.failure) |err| return err;
    context.input_state.commitFrame();
    return context.command_buffer.commands();
}

const Stacked = struct {
    fn build(_: *Stacked, v: *View) anyerror!void {
        try v.row(.{ .gap = 4 });
        _ = try v.button("One", .{ .width = 80, .z_index = 2, .pose = .{ .x = 40 } });
        _ = try v.button("Two", .{ .width = 80 });
        _ = try v.button("Three", .{ .width = 80, .z_index = -1 });
        try v.end();
    }
};

/// The order the texts are drawn in, by their first letters.
fn textOrder(h: *Harness, context: *ui.Context, out: []u8) ![]const u8 {
    const commands = try paintAgain(h, context);
    const bytes = context.command_buffer.textBytes();
    var len: usize = 0;
    for (commands) |command| if (command == .text and len < out.len) {
        out[len] = bytes[command.text.offset];
        len += 1;
    };
    return out[0..len];
}

test "z-index paints siblings in its order, and Tab reads them as built" {
    var storage: Storage = .{};
    var app: Stacked = .{};
    var h = Harness.init(&app, Stacked.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    var order: [8]u8 = undefined;
    try testing.expectEqualStrings("TTO", try textOrder(&h, &context, &order));
    const one = (try h.find(.{ .text = "One" })).id;
    const two = (try h.find(.{ .text = "Two" })).id;
    const three = (try h.find(.{ .text = "Three" })).id;
    // The controls were recorded Three, Two, One; Tab goes as built.
    try testing.expectEqual(three, context.input_state.hits[0].id);
    context.input_state.setFocused(null);
    context.input_state.tab();
    try testing.expectEqual(one, context.input_state.focused.?);
    context.input_state.tab();
    try testing.expectEqual(two, context.input_state.focused.?);
    context.input_state.tab();
    try testing.expectEqual(three, context.input_state.focused.?);
    context.input_state.tabDirection(true);
    try testing.expectEqual(two, context.input_state.focused.?);
}

const Timeline = struct {
    model: view.ScrollModel = .{},
    fn build(self: *Timeline, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 100 });
        for ([_][]const u8{ "Monday", "Tuesday" }) |day| {
            try v.column(.{ .key = view.key(day) });
            try v.text(day, .{ .height = 20, .sticky = .{ .top = 0 }, .background = 0xffffff });
            for (0..6) |i| try v.textf("{s} event {d}", .{ day, i }, .{ .height = 20 });
            try v.end();
        }
        try v.end();
    }
};

test "a sticky heading stays at the top of its scroll container until the next section pushes it out" {
    var storage: Storage = .{};
    var app: Timeline = .{};
    var h = Harness.init(&app, Timeline.build, storage.buffers(), .{});
    try h.render();
    const top = (try h.boundsOf(.{ .kind = .scroll })).y;
    try testing.expectEqual(top, (try h.boundsOf(.{ .text = "Monday" })).y);
    // Scrolled 50 into Monday's 140: its heading stays at the top.
    app.model.offset.y = 50;
    try h.render();
    try testing.expectEqual(top, (try h.boundsOf(.{ .text = "Monday" })).y);
    try testing.expectEqual(top + 90, (try h.boundsOf(.{ .text = "Tuesday" })).y);
    // At 130, Monday's last 10 are in view: Tuesday pushes its heading up.
    app.model.offset.y = 130;
    try h.render();
    try testing.expectEqual(top - 10, (try h.boundsOf(.{ .text = "Monday" })).y);
    try testing.expectEqual(top + 10, (try h.boundsOf(.{ .text = "Tuesday" })).y);
    // Further on, Tuesday's sticks.
    app.model.offset.y = 170;
    try h.render();
    try testing.expectEqual(top, (try h.boundsOf(.{ .text = "Tuesday" })).y);
}

const Pages = struct {
    model: view.ScrollModel = .{},
    snap: view.SnapType = .mandatory,
    fn build(self: *Pages, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 100, .scroll_snap = self.snap });
        for (0..5) |i| try v.textf("Page {d}", .{i}, .{ .key = i, .height = 80, .snap_align = .start });
        try v.end();
    }
};

test "a snapping scroll container goes from place to place, or rests near one" {
    var storage: Storage = .{};
    var app: Pages = .{};
    var h = Harness.init(&app, Pages.build, storage.buffers(), .{});
    try h.render();
    try testing.expectEqual(@as(f32, 0), app.model.offset.y);
    // A small step down goes on to the next page.
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 10 });
    try testing.expectEqual(@as(f32, 80), app.model.offset.y);
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 30 });
    try testing.expectEqual(@as(f32, 160), app.model.offset.y);
    // And back up.
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = -5 });
    try testing.expectEqual(@as(f32, 80), app.model.offset.y);
    // Where the application puts it, it stays.
    app.model.offset.y = 100;
    try h.render();
    try testing.expectEqual(@as(f32, 100), app.model.offset.y);
    // Proximity rests at a page only within a third of the view of it.
    app.snap = .proximity;
    app.model.offset.y = 0;
    try h.render();
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 70 });
    try testing.expectEqual(@as(f32, 80), app.model.offset.y);
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 40 });
    try testing.expectEqual(@as(f32, 120), app.model.offset.y);
}

const Panes = struct {
    fraction: f64 = 0.5,
    fn build(self: *Panes, v: *View) anyerror!void {
        _ = try v.split(.row, &self.fraction, .{ .minimum = 0.1, .maximum = 0.9 }, .{ .width = 400, .height = 100, .split_reset = 0.25 });
        try v.text("Left", .{});
        try v.text("Right", .{});
        try v.end();
    }
};

test "a double click on a split's divider puts it back at its reset size" {
    var storage: Storage = .{};
    var app: Panes = .{ .fraction = 0.6 };
    var h = Harness.init(&app, Panes.build, storage.buffers(), .{});
    try h.render();
    const strip = h.view.divider(try h.find(.{ .kind = .split })).?;
    const x = strip.x + strip.width / 2;
    const y = strip.y + strip.height / 2;
    try h.press(x, y, .{});
    try h.release(x, y);
    try testing.expectEqual(@as(f64, 0.6), app.fraction);
    try h.advance(100 * std.time.ns_per_ms);
    try h.press(x, y, .{});
    try h.release(x, y);
    try testing.expectEqual(@as(f64, 0.25), app.fraction);
}
