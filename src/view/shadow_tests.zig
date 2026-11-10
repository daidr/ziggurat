//! Headless tests of the shadows boxes cast, and of the text size the
//! theme gives text that sets no font.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Harness = view.Harness;
const testing = std.testing;
const Storage = view.Storage(64, 4096);

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

fn paint(h: *Harness, context: *ui.Context) ![]const ui.commands.Command {
    context.command_buffer.reset();
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = context, .size = .{ .width = 400, .height = 300, .scale = 1 } };
    try h.view.paint(&frame);
    if (frame.failure) |err| return err;
    context.input_state.commitFrame();
    return context.command_buffer.commands();
}

/// The index of the first shape in `color` (0xRRGGBB), and the shape.
fn shapeOf(commands: []const ui.commands.Command, color: u32) ?struct { index: usize, bounds: ui.Rect, radius: f32, alpha: u8 } {
    for (commands, 0..) |command, index| if (command == .shape and command.shape.color.hex() == color) {
        return .{ .index = index, .bounds = command.shape.bounds, .radius = command.shape.radius, .alpha = command.shape.color.a };
    };
    return null;
}

const Card = struct {
    shadows: []const view.BoxShadow = &.{},
    background: ?u32 = 0xffffff,
    fn build(self: *Card, v: *View) anyerror!void {
        try v.column(.{ .padding = .all(40) });
        try v.column(.{ .key = 7, .width = 100, .height = 60, .radius = 8, .background = self.background, .shadows = self.shadows });
        try v.end();
        try v.end();
    }
};

test "a box casts its shadows under its background, the first on top" {
    var storage: Storage = .{};
    const shadows = [_]view.BoxShadow{
        .{ .x = 0, .y = 4, .spread = 2, .color = .{ .r = 1, .g = 2, .b = 3, .a = 100 } },
        .{ .x = 6, .y = 6, .spread = -2, .color = .{ .r = 4, .g = 5, .b = 6, .a = 50 } },
    };
    var app: Card = .{ .shadows = &shadows };
    var h = Harness.init(&app, Card.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const commands = try paint(&h, &context);
    const top = shapeOf(commands, 0x010203).?;
    const under = shapeOf(commands, 0x040506).?;
    const card = shapeOf(commands, 0xffffff).?;
    try testing.expect(under.index < top.index and top.index < card.index);
    // Offset, grown by the spread with its corners, in its own alpha.
    const b = card.bounds;
    try testing.expectEqual(ui.Rect{ .x = b.x - 2, .y = b.y + 2, .width = b.width + 4, .height = b.height + 4 }, top.bounds);
    try testing.expectEqual(@as(f32, 10), top.radius);
    try testing.expectEqual(@as(u8, 100), top.alpha);
    try testing.expectEqual(ui.Rect{ .x = b.x + 8, .y = b.y + 8, .width = b.width - 4, .height = b.height - 4 }, under.bounds);
    try testing.expectEqual(@as(f32, 6), under.radius);
}

test "a translucent box leaves itself out of its shadow, and shadows are checked" {
    var storage: Storage = .{};
    const shadows = [_]view.BoxShadow{.{ .y = 4, .blur = 10, .color = .{ .r = 1, .g = 2, .b = 3, .a = 100 } }};
    var app: Card = .{ .shadows = &shadows, .background = null };
    var h = Harness.init(&app, Card.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const commands = try paint(&h, &context);
    const shadow = shapeOf(commands, 0x010203).?;
    var clipped = false;
    for (commands[0..shadow.index]) |command| if (command == .push_clip or command == .push_mask_clip) {
        clipped = true;
    };
    try testing.expect(clipped);
    // Without shader effects the shadow is sharp.
    const b = (try h.find(.{ .key = 7 })).bounds;
    try testing.expectEqual(ui.Rect{ .x = b.x, .y = b.y + 4, .width = b.width, .height = b.height }, shadow.bounds);

    const bad = [_]view.BoxShadow{.{ .blur = -1 }};
    app.shadows = &bad;
    try testing.expectError(error.InvalidValue, h.render());
    const many: [view.max_shadows + 1]view.BoxShadow = @splat(.{});
    app.shadows = &many;
    try testing.expectError(error.InvalidValue, h.render());
}

const Words = struct {
    fn build(_: *Words, v: *View) anyerror!void {
        try v.column(.{});
        try v.text("Words", .{});
        try v.text("Small", .{ .font = .{ .size = 12 } });
        _ = try v.button("Press", .{});
        try v.end();
    }
};

test "text and labels without a font take the theme's size" {
    var storage: Storage = .{};
    var app: Words = .{};
    var h = Harness.init(&app, Words.build, storage.buffers(), .{});
    try h.render();
    const words = (try h.find(.{ .text = "Words" })).measured.preferred;
    const small = (try h.find(.{ .text = "Small" })).measured.preferred;
    const press = (try h.find(.{ .text = "Press" })).measured.preferred;
    var larger: Storage = .{};
    var theme = ui.Theme.light().withPreferences(.{ .text_scale = 1.5 });
    try testing.expectEqual(@as(f32, 24), theme.font_size);
    var big = Harness.init(&app, Words.build, larger.buffers(), .{ .theme = theme });
    try big.render();
    const big_words = try big.find(.{ .text = "Words" });
    try testing.expect(big_words.measured.preferred.width > words.width * 1.4 and big_words.measured.preferred.height > words.height);
    try testing.expectEqual(@as(f32, 24), big_words.style.font.?.size);
    // A font of the text's own keeps its size.
    try testing.expectEqual(small.width, (try big.find(.{ .text = "Small" })).measured.preferred.width);
    try testing.expect((try big.find(.{ .text = "Press" })).measured.preferred.width > press.width);
    theme.font_size = ui.Theme.default_font_size;
    big.config.theme = theme;
    try big.render();
    try testing.expectEqual(words.width, (try big.find(.{ .text = "Words" })).measured.preferred.width);
}
