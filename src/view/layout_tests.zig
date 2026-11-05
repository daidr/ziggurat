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
