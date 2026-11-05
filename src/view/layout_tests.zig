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
