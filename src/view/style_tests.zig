//! Headless tests of node styles: gradients, themed subtrees, nodes that
//! ignore input, hidden scroll indicators and placeholders handed to the
//! text input inside a search, token field or editable combo box.
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
const Storage = view.Storage(64, 2048);

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

const glow = [_]view.GradientStop{ .{ .color = ui.Color.rgb(0xa5b4fc), .at = 0 }, .{ .color = ui.Color.rgb(0x312e81), .at = 1 } };

const Painted = struct {
    border: bool = false,
    fn build(self: *Painted, v: *View) anyerror!void {
        try v.column(.{ .width = 240, .height = 140, .radius = 16, .gradient = .{ .radial = .{ .center = .{ .x = 0.3, .y = 0.2 }, .stops = &glow, .oklab = true } }, .border_gradient = if (self.border) .{ .conic = .{ .stops = &glow } } else null, .border_width = 3 });
        try v.end();
    }
};

test "a gradient fills a node's box in place of its background, and another strokes its border" {
    var storage: Storage = .{};
    var app: Painted = .{};
    var h = Harness.init(&app, Painted.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    var commands = try paintAgain(&h, &context);
    var fills: usize = 0;
    var box: view.Rect = undefined;
    for (commands) |command| if (command == .gradient) {
        fills += 1;
        box = command.gradient.bounds;
        try testing.expectEqual(@as(f32, 16), command.gradient.radius);
        try testing.expectEqual(@as(f32, 0), command.gradient.stroke_width);
        try testing.expectEqual(@as(f32, 240), command.gradient.bounds.width);
    };
    try testing.expectEqual(@as(usize, 1), fills);
    const brush = context.command_buffer.brushResources()[0];
    try testing.expectEqual(ui.commands.brushes.Kind.radial, brush.kind);
    // The center sits at 30% and 20% of the box.
    try testing.expectApproxEqAbs(box.x + 72, brush.a.x, 0.01);
    try testing.expectApproxEqAbs(box.y + 28, brush.a.y, 0.01);
    try testing.expectEqual(ui.commands.brushes.InterpolationSpace.oklab, brush.interpolation);

    app.border = true;
    try h.render();
    commands = try paintAgain(&h, &context);
    var strokes: usize = 0;
    for (commands) |command| if (command == .gradient and command.gradient.stroke_width == 3) {
        strokes += 1;
    };
    try testing.expectEqual(@as(usize, 1), strokes);
}

const dark: view.Theme = blk: {
    var theme: view.Theme = .{};
    theme.palette.background = 0x1e1e2e;
    theme.palette.text = 0xf5f5f5;
    theme.metrics.content_inset = 20;
    break :blk theme;
};

const Themed = struct {
    fn build(_: *Themed, v: *View) anyerror!void {
        try v.text("Window", .{});
        _ = try v.button("Plain", .{});
        try v.themed(&dark, .{ .padding = view.Insets.all(4) });
        try testing.expectEqual(@as(?*const view.Theme, &dark), v.scopeTheme());
        try v.text("Card", .{});
        _ = try v.button("Inside", .{});
        try v.end();
        try testing.expectEqual(@as(?*const view.Theme, null), v.scopeTheme());
    }
};

test "a themed subtree measures with its theme's metrics and paints with its colors" {
    var storage: Storage = .{};
    var app: Themed = .{};
    var h = Harness.init(&app, Themed.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const plain = try h.boundsOf(.{ .text = "Plain" });
    const inside = try h.boundsOf(.{ .text = "Inside" });
    // The wider content inset of the inner theme pads its button more.
    try testing.expect(inside.width > plain.width);
    const commands = try paintAgain(&h, &context);
    const bytes = context.command_buffer.textBytes();
    var window_text: ?u32 = null;
    var card_text: ?u32 = null;
    var filled = false;
    for (commands) |command| switch (command) {
        .text => |text| {
            const label = bytes[text.offset..][0..text.len];
            if (std.mem.eql(u8, label, "Window")) window_text = text.color;
            if (std.mem.eql(u8, label, "Card")) card_text = text.color;
        },
        .fill => |fill| filled = filled or fill.color == dark.palette.background,
        .shape => |shape| filled = filled or shape.color.hex() == dark.palette.background,
        else => {},
    };
    try testing.expectEqual(@as(?u32, (view.Theme{}).palette.text), window_text);
    try testing.expectEqual(@as(?u32, dark.palette.text), card_text);
    try testing.expect(filled);
}

const Hover = struct {
    pressed: usize = 0,
    behind: usize = 0,
    fn build(self: *Hover, v: *View) anyerror!void {
        try v.row(.{ .gap = 8 });
        _ = try v.button("Before", .{});
        try v.column(.{ .ignore_input = true, .opacity = 0 });
        if (try v.button("Delete", .{})) self.pressed += 1;
        try v.end();
        try v.end();
    }
};

test "a node ignoring input lets the pointer and focus pass, and assistive technology still presses it" {
    var storage: Storage = .{};
    var app: Hover = .{};
    var h = Harness.init(&app, Hover.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const node = try h.find(.{ .text = "Delete" });
    try testing.expect(node.passthrough);
    const rect = try h.boundsOf(.{ .text = "Delete" });
    // The pointer finds nothing there, and the frame registers no hit.
    try testing.expectError(error.NotFound, h.clickAt(rect.x + rect.width / 2, rect.y + rect.height / 2));
    try testing.expectEqual(@as(usize, 0), app.pressed);
    try testing.expect(context.input_state.hitControl(.{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 }) == null);
    try testing.expectError(error.IgnoresInput, h.focus(.{ .text = "Delete" }));
    try testing.expect(!context.input_state.available(node.id));
    // A screen reader's press acts as a click.
    try h.click(.{ .text = "Delete" });
    try testing.expectEqual(@as(usize, 1), app.pressed);
    // Its neighbour is unaffected.
    try h.focus(.{ .text = "Before" });
    try testing.expectEqualStrings("Before", h.focused().?.text);
}

const Scrolling = struct {
    model: view.ScrollModel = .{},
    bars: bool = true,
    fn build(self: *Scrolling, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 60, .scrollbars = self.bars });
        for (0..12) |i| try v.textf("Line {d}", .{i}, .{ .key = i });
        try v.end();
    }
};

test "a scroll container without scrollbars draws no indicator and still scrolls" {
    var storage: Storage = .{};
    var app: Scrolling = .{};
    var h = Harness.init(&app, Scrolling.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const track = (view.Theme{}).palette.track;
    const thumbs = struct {
        fn count(commands: []const ui.commands.Command) usize {
            var n: usize = 0;
            for (commands) |command| switch (command) {
                .fill => |fill| n += @intFromBool(fill.color == track),
                .shape => |shape| n += @intFromBool(shape.color.hex() == track),
                else => {},
            };
            return n;
        }
    };
    try testing.expectEqual(@as(usize, 1), thumbs.count(try paintAgain(&h, &context)));
    app.bars = false;
    try h.render();
    try testing.expectEqual(@as(usize, 0), thumbs.count(try paintAgain(&h, &context)));
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 30 });
    try testing.expect(app.model.offset.y > 0);
}

const Probe = struct {
    seen: view.Annotation = .{},
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 80, .height = 24 }, .preferred = .{ .width = 120, .height = 24 } };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn annotate(ptr: *anyopaque, about: view.Annotation) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.seen = about;
    }
    fn embed(self: *Probe) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .annotate = annotate };
    }
};

const Searching = struct {
    search: Probe = .{},
    plain: Probe = .{},
    fn build(self: *Searching, v: *View) anyerror!void {
        try v.search(.{ .name = "Find", .placeholder = "Search mail", .placeholder_color = 0xaa0000 });
        try v.embed(self.search.embed(), .{});
        try v.end();
        try v.embed(self.plain.embed(), .{});
    }
};

test "a search hands its placeholder and its color to the text input inside it" {
    var storage: Storage = .{};
    var app: Searching = .{};
    var h = Harness.init(&app, Searching.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    _ = try paintAgain(&h, &context);
    try testing.expectEqualStrings("Search mail", app.search.seen.placeholder);
    try testing.expectEqual(@as(?u32, 0xaa0000), app.search.seen.placeholder_color);
    try testing.expectEqualStrings("", app.plain.seen.placeholder);
}
