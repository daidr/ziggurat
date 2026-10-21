//! Headless tests of the inspector: opening and closing it, the tree,
//! picking, the keyboard, details, issues, the RTL toggle and resizing.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");
const inspector = @import("inspector.zig");

const View = view.View;
const Harness = view.Harness;
const Inspector = view.Inspector;
const testing = std.testing;

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};
const Storage = view.Storage(64, 4096);

const App = struct {
    presses: usize = 0,
    duplicate: bool = false,
    fn build(self: *App, v: *View) anyerror!void {
        try v.column(.{ .gap = 6, .padding = view.Insets.all(8), .background = 0xeeeeee, .key = 3 });
        try v.text("Title", .{});
        if (try v.button("Save", .{})) self.presses += 1;
        try v.end();
        if (self.duplicate) {
            try v.row(.{ .key = 9 });
            try v.end();
            try v.row(.{ .key = 9 });
            try v.end();
        }
    }
};

const ctrl_shift: z.KeyModifiers = .{ .control = true, .shift = true };

fn setup(app: *App, storage: *Storage, tools: *Inspector, context: *ui.Context) !Harness {
    var h = Harness.init(app, App.build, storage.buffers(), .{ .options = .{ .inspector = tools } });
    try h.attachInput(context);
    return h;
}

test "F12 and Ctrl+Shift+I open and close the panel beside a narrower content" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    try testing.expectEqual(@as(f32, 640), h.view.root().bounds.width);
    try testing.expect(try h.key(.{ .key = .f12 }));
    try testing.expect(tools.open);
    // The content gets the window less the panel.
    try testing.expectEqual(@as(f32, 640 - inspector.default_width), h.view.root().bounds.width);
    try testing.expect(tools.len == h.view.nodes().len);
    try testing.expect(try h.key(.{ .key = .i, .modifiers = ctrl_shift }));
    try testing.expect(!tools.open);
    try testing.expectEqual(@as(f32, 640), h.view.root().bounds.width);
    // Without developer tools the keys reach the view.
    tools.enabled = false;
    try testing.expect(!try h.key(.{ .key = .f12 }));
    try testing.expect(!tools.open);
}

test "picking chooses the element under the pointer without clicking it" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    try testing.expect(try h.key(.{ .key = .c, .modifiers = ctrl_shift }));
    try testing.expect(tools.open and tools.picking);
    const button = try h.find(.{ .kind = .button });
    const b = button.bounds;
    try h.hoverAt(b.x + 4, b.y + 4);
    try testing.expectEqual(button.id, tools.hovered);
    try testing.expectEqual(view.Cursor.crosshair, h.cursor());
    try h.clickAt(b.x + 4, b.y + 4);
    try testing.expectEqual(@as(usize, 0), app.presses);
    try testing.expect(!tools.picking);
    try testing.expectEqual(button.id, tools.selected);
    // The tree shows it, with the elements around it open.
    try testing.expect(tools.rowOf(button.id) != null);
    // Escape stops picking.
    try testing.expect(try h.key(.{ .key = .c, .modifiers = ctrl_shift }));
    try testing.expect(try h.key(.{ .key = .escape }));
    try testing.expect(!tools.picking);
    // Once picking stops, the content takes clicks again.
    try h.clickAt(b.x + 4, b.y + 4);
    try testing.expectEqual(@as(usize, 1), app.presses);
}

test "the tree's rows, arrows and keys" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    // Root, column, text, button, then the column's and the root's closing
    // tags.
    try testing.expectEqual(@as(usize, 6), tools.row_count);
    const l = tools.layout();
    // A click on the first row chooses the root and gives the panel the
    // keyboard.
    try h.clickAt(l.tree.x + 60, l.tree.y + 2 + 5);
    try testing.expectEqual(h.view.root().id, tools.selected);
    try testing.expect(tools.focused);
    const column = try h.find(.{ .kind = .column, .nth = 1 });
    try testing.expect(try h.key(.{ .key = .down }));
    try testing.expectEqual(column.id, tools.selected);
    // Left closes the column, then goes to its parent; Right opens it, then
    // goes into it.
    try testing.expect(try h.key(.{ .key = .left }));
    try testing.expectEqual(@as(usize, 3), tools.row_count);
    try testing.expect(try h.key(.{ .key = .right }));
    try testing.expectEqual(@as(usize, 6), tools.row_count);
    try testing.expect(try h.key(.{ .key = .right }));
    try testing.expectEqual((try h.find(.{ .kind = .text })).id, tools.selected);
    try testing.expect(try h.key(.{ .key = .end }));
    try testing.expectEqual((try h.find(.{ .kind = .button })).id, tools.selected);
    // The arrow of the column's row closes it.
    const row = tools.rowOf(column.id).?;
    const y = l.tree.y + 2 + @as(f32, @floatFromInt(row)) * 20 + 5;
    try h.clickAt(l.tree.x + 14 + 4 + 3, y);
    try testing.expectEqual(@as(usize, 3), tools.row_count);
    // A press in the content takes the keyboard back for the view.
    try h.press(5, 400, .{});
    try h.release(5, 400);
    try testing.expect(!tools.focused);
    try testing.expect(!try h.key(.{ .key = .down }));
}

test "details describe the styles, computed values and properties" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    const column = try h.find(.{ .kind = .column, .nth = 1 });
    tools.choose(column.id);
    var details: inspector.Details = .{};
    details.describe(&tools, tools.indexOf(column.id).?);
    var selector: [64]u8 = undefined;
    try testing.expectEqualStrings("Column#3 {", details.selector(&tools, tools.indexOf(column.id).?, &selector));
    try testing.expect(has(details.styles[0..details.style_count], "gap", "6px"));
    try testing.expect(has(details.styles[0..details.style_count], "padding", "8px"));
    try testing.expect(has(details.styles[0..details.style_count], "background-color", "#eeeeee"));
    try testing.expect(has(details.computed[0..details.computed_count], "display", "flex"));
    try testing.expect(has(details.computed[0..details.computed_count], "flex-direction", "column"));
    try testing.expect(has(details.properties[0..details.property_count], "type", "Column"));
    try testing.expect(has(details.properties[0..details.property_count], "key", "3"));
    const button = try h.find(.{ .kind = .button });
    details = .{};
    details.describe(&tools, tools.indexOf(button.id).?);
    try testing.expect(has(details.properties[0..details.property_count], "role", "button"));
    try testing.expect(has(details.properties[0..details.property_count], "keyboard-focusable", "true"));
    try testing.expect(has(details.properties[0..details.property_count], "name", "\"Save\""));
    // The panel paints every tab without failing.
    for ([_]inspector.Side{ .styles, .computed, .properties }) |side| {
        tools.side = side;
        tools.focused = true;
        try h.render();
    }
    tools.tab = .performance;
    try h.render();
    tools.tab = .issues;
    try h.render();
}

fn has(list: []const inspector.Decl, name: []const u8, value: []const u8) bool {
    for (list) |decl| if (std.mem.eql(u8, decl.name, name) and std.mem.eql(u8, decl.value, value)) return true;
    return false;
}

test "two elements with one key under a parent are an issue, noted once" {
    var app: App = .{ .duplicate = true };
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    try h.render();
    try testing.expectEqual(@as(usize, 1), tools.issue_count);
    try testing.expect(std.mem.indexOf(u8, tools.issue(0), "key 9") != null);
    // The toolbar's badge opens the Issues tab.
    const badge = tools.layout().badge.?;
    try h.clickAt(badge.x + 4, badge.y + 4);
    try testing.expectEqual(inspector.Tab.issues, tools.tab);
}

test "the RTL toggle, the close button and the panel's edge" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = Harness.init(&app, App.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 1000, .height = 600 }, .options = .{ .inspector = &tools } });
    try h.attachInput(&context);
    _ = try h.key(.{ .key = .f12 });
    var l = tools.layout();
    try h.clickAt(l.rtl.x + 4, l.rtl.y + 4);
    try testing.expect(h.view.root().rtl);
    try h.clickAt(l.rtl.x + 4, l.rtl.y + 4);
    try testing.expect(!h.view.root().rtl);
    // Dragging the left edge widens the panel.
    try h.hoverAt(l.edge.x + 3, 300);
    try testing.expectEqual(view.Cursor.resize_ew, h.cursor());
    try h.drag(l.edge.x + 3, 300, l.edge.x - 97, 300, 4);
    try testing.expectEqual(@as(f32, inspector.default_width + 100), tools.width);
    try testing.expectEqual(@as(f32, 1000 - inspector.default_width - 100), h.view.root().bounds.width);
    l = tools.layout();
    try h.clickAt(l.close.x + 4, l.close.y + 4);
    try testing.expect(!tools.open);
}
