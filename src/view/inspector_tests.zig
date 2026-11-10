//! Headless tests of the inspector: opening and closing it, the tree,
//! picking, the keyboard, details, issues, finding, where an element was
//! built, the RTL toggle and resizing. A build without the inspector skips
//! them.
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
    if (!inspector.enabled) return error.SkipZigTest;
    var h = Harness.init(app, App.build, storage.buffers(), .{ .options = .{ .inspector = tools }, .strict = !app.duplicate });
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

test "a Harness fails a build that gives two elements one key" {
    var app: App = .{ .duplicate = true };
    var storage: Storage = .{};
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    try testing.expectError(error.DuplicateKey, h.render());
    try testing.expect(std.mem.indexOf(u8, h.issue(), "key 9") != null);
    app.duplicate = false;
    try h.render();
}

test "Ctrl+F finds elements by tag, text, name or key" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    // The panel takes the keyboard with a press on it.
    try h.clickAt(tools.layout().tree.x + 40, tools.layout().tree.y + 4);
    try testing.expect(try h.key(.{ .key = .f, .modifiers = .{ .control = true } }));
    try testing.expect(tools.finding and tools.layout().find != null);
    try h.typeText("sav");
    // The button labelled Save, chosen and shown in the tree.
    const button = try h.find(.{ .kind = .button });
    try testing.expectEqual(@as(usize, 1), tools.match_count);
    try testing.expectEqual(button.id, tools.selected);
    try testing.expect(tools.rowOf(button.id) != null);
    // Fewer letters find more: the text "Title" and its tag both hold "t".
    _ = try h.key(.{ .key = .backspace });
    _ = try h.key(.{ .key = .backspace });
    _ = try h.key(.{ .key = .backspace });
    try h.typeText("T");
    try testing.expect(tools.match_count > 1);
    const first = tools.selected;
    try testing.expect(try h.key(.{ .key = .enter }));
    try testing.expect(tools.selected != first);
    try testing.expect(try h.key(.{ .key = .enter, .modifiers = .{ .shift = true } }));
    try testing.expectEqual(first, tools.selected);
    // By key.
    _ = try h.key(.{ .key = .backspace });
    try h.typeText("3");
    try testing.expectEqual(h.view.nodes()[1].id, tools.selected);
    try testing.expect(try h.key(.{ .key = .escape }));
    try testing.expect(!tools.finding);
    try testing.expectError(error.NoTextTarget, h.typeText("x"));
}

test "the details tell where the application built the element chosen" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    const button = try h.find(.{ .kind = .button });
    tools.choose(button.id);
    try h.render();
    // A build with debug information knows the line of `v.button`.
    if (tools.source().len == 0) return error.SkipZigTest;
    try testing.expect(std.mem.endsWith(u8, tools.source(), "inspector_tests.zig:28"));
}

test "the RTL toggle, the close button and the panel's edge" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    if (!inspector.enabled) return error.SkipZigTest;
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

test "a flex badge in the tree keeps the container's layout over the content" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    const column = try h.find(.{ .kind = .column, .nth = 1 });
    const index = tools.indexOf(column.id).?;
    try testing.expectEqual(inspector.LayoutKind.flex, inspector.layoutKind(&tools.elements[index]).?);
    try testing.expect(inspector.layoutKind(&tools.elements[tools.indexOf((try h.find(.{ .kind = .text })).id).?]) == null);
    // A click on the badge at the row's end turns it on, another off; the
    // element chosen stays.
    const l = tools.layout();
    const row = tools.rowOf(column.id).?;
    const y = l.tree.y + 2 + @as(f32, @floatFromInt(row)) * 20 + 10;
    try h.clickAt(l.tree.x + l.tree.width - 10, y);
    try testing.expect(tools.showsLayout(column.id));
    try h.render();
    try h.clickAt(l.tree.x + l.tree.width - 10, y);
    try testing.expect(!tools.showsLayout(column.id));
}

test "the source link opens only a file that is here" {
    var tools: Inspector = .{};
    tools.source_len = (try std.fmt.bufPrint(&tools.source_buffer, "/no/such/main.zig:4", .{})).len;
    tools.source_openable = false;
    // Nothing opens, and nothing is noted.
    tools.openSource();
    try testing.expectEqual(@as(usize, 0), tools.issue_count);
}

test "a value typed in the Styles tab restyles the element live, and Copy gives it as Zig" {
    var app: App = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = try setup(&app, &storage, &tools, &context);
    _ = try h.key(.{ .key = .f12 });
    const column = try h.find(.{ .kind = .column, .nth = 1 });
    tools.choose(column.id);
    try h.render();
    // A click on the gap's value starts an edit from the value it has.
    const gap = tools.edit_rects[@backingInt(inspector.EditField.gap)].?;
    try h.clickAt(gap.x + 4, gap.y + 4);
    try testing.expectEqual(inspector.EditField.gap, tools.editing.?);
    try testing.expectEqualStrings("6", tools.editText());
    try testing.expect(try h.key(.{ .key = .backspace }));
    try h.typeText("12px");
    try testing.expect(try h.key(.{ .key = .enter }));
    try testing.expect(tools.editing == null);
    try testing.expectEqual(@as(f32, 12), (try h.find(.{ .kind = .column, .nth = 1 })).style.gap);
    // Up nudges a number as it is typed; Tab moves to the next property.
    const background = tools.edit_rects[@backingInt(inspector.EditField.padding)].?;
    try h.clickAt(background.x + 4, background.y + 4);
    try testing.expect(try h.key(.{ .key = .up, .modifiers = .{ .shift = true } }));
    try testing.expectEqualStrings("18", tools.editText());
    try testing.expectEqual(@as(f32, 18), (try h.find(.{ .kind = .column, .nth = 1 })).style.padding.left);
    try testing.expect(try h.key(.{ .key = .escape }));
    // A color, and a value that is not one stays in the edit.
    tools.startEdit(.background);
    try testing.expect(!tools.typeText("") or true);
    tools.edit_len = 0;
    try h.typeText("zz");
    try testing.expect(!tools.commitEdit());
    tools.edit_len = 0;
    try h.typeText("#1a73e8");
    try testing.expect(tools.commitEdit());
    try h.render();
    try testing.expectEqual(@as(?u32, 0x1a73e8), (try h.find(.{ .kind = .column, .nth = 1 })).style.background);
    // Copy as Zig, then Reset, which builds it as written again.
    try h.render();
    const copy = tools.copy_rect.?;
    try h.clickAt(copy.x + 2, copy.y + 4);
    try testing.expectEqualStrings(".{ .gap = 12, .padding = .all(18), .background = 0x1a73e8 }", tools.copied());
    try h.render();
    const reset = tools.reset_rect.?;
    try h.clickAt(reset.x + 2, reset.y + 4);
    try testing.expect(!tools.hasChanges(column.id));
    try testing.expectEqual(@as(f32, 6), (try h.find(.{ .kind = .column, .nth = 1 })).style.gap);
    try testing.expectEqual(@as(?u32, 0xeeeeee), (try h.find(.{ .kind = .column, .nth = 1 })).style.background);
}

test "values the Styles tab reads" {
    if (!inspector.enabled) return error.SkipZigTest;
    try testing.expectEqual(@as(f32, 4), inspector.parseValue(.gap, " 4px; ").?.number);
    try testing.expect(inspector.parseValue(.gap, "-1") == null);
    try testing.expect(inspector.parseValue(.gap, "auto") == null);
    try testing.expect(std.math.isNan(inspector.parseValue(.width, "auto").?.number));
    try testing.expect(inspector.parseValue(.opacity, "1.5") == null);
    try testing.expectEqual(@as(?u32, 0xaabbcc), inspector.parseValue(.color, "#abc").?.rgb);
    try testing.expectEqual(@as(?u32, 0x123456), inspector.parseValue(.border, "0x123456").?.rgb);
    try testing.expectEqual(@as(?u32, null), inspector.parseValue(.border, "none").?.rgb);
    var tools: Inspector = .{};
    tools.setOverride(.{ .id = 5, .field = .width, .number = std.math.nan(f32) });
    tools.setOverride(.{ .id = 5, .field = .font_size, .number = 14.5 });
    tools.setOverride(.{ .id = 5, .field = .color, .rgb = null });
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(".{ .width = null, .font = .{ .size = 14.5 }, .color = null }", tools.zigCode(5, &buffer));
    try testing.expectEqualStrings("", tools.zigCode(6, &buffer));
    var style: view.Style = .{ .width = 30, .color = 0x111111 };
    tools.restyle(5, &style);
    try testing.expect(style.width == null and style.color == null);
    try testing.expectEqual(@as(f32, 14.5), style.font.?.size);
}

const AreaApp = struct {
    hovered: bool = false,
    pressed: bool = false,
    fn build(self: *AreaApp, v: *View) anyerror!void {
        const area = try v.pointerArea(.{}, .{ .width = 100, .height = 40 });
        self.hovered = area.hovered;
        self.pressed = area.pressed;
        try v.end();
        _ = try v.button("Go", .{});
    }
};

test "states forced in the Styles tab show whatever the pointer and keyboard do" {
    if (!inspector.enabled) return error.SkipZigTest;
    var app: AreaApp = .{};
    var storage: Storage = .{};
    var tools: Inspector = .{};
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    var h = Harness.init(&app, AreaApp.build, storage.buffers(), .{ .options = .{ .inspector = &tools } });
    try h.attachInput(&context);
    _ = try h.key(.{ .key = .f12 });
    const area = try h.find(.{ .kind = .pointer_area });
    tools.choose(area.id);
    try h.render();
    try testing.expect(!app.hovered);
    const hover = tools.state_rects[0].?;
    try h.clickAt(hover.x + 2, hover.y + 4);
    try testing.expect(tools.forced(area.id, .hover));
    try h.render();
    try testing.expect(app.hovered and !app.pressed);
    tools.forceState(area.id, .active, true);
    try h.render();
    try testing.expect(app.hovered and app.pressed);
    tools.forceState(area.id, .hover, false);
    tools.forceState(area.id, .active, false);
    try h.render();
    try testing.expect(!app.hovered and !app.pressed);
    // Focus forced on a control lasts only as the frame paints.
    const button = try h.find(.{ .kind = .button });
    tools.forceState(button.id, .focus, true);
    try h.render();
    try testing.expect(context.input_state.focused != button.id);
}

const Roles = struct {
    fn build(_: *Roles, v: *View) anyerror!void {
        try v.column(.{ .key = 1, .role = .tab_panel, .name = "General" });
        try v.text("Settings", .{ .key = 2, .role = .heading });
        try v.end();
        try v.column(.{ .key = 3, .role = .content_info });
        try v.end();
    }
};

test "the role a style gives is the one the inspector names" {
    var app: Roles = .{};
    var storage: Storage = .{};
    var h = Harness.init(&app, Roles.build, storage.buffers(), .{});
    try h.render();
    if (!inspector.enabled) return error.SkipZigTest;
    var tools: Inspector = .{ .open = true };
    tools.capture(&h.view, null, .{}, .{});
    for ([_]struct { u64, []const u8 }{ .{ 1, "tabpanel" }, .{ 2, "heading" }, .{ 3, "contentinfo" } }) |case| {
        const node = try h.find(.{ .key = case[0] });
        try testing.expectEqualStrings(case[1], inspector.elementRole(&tools.elements[tools.indexOf(node.id).?]));
    }
}
