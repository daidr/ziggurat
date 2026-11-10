//! Headless tests of what assistive technology reads of a view
//! (`Harness.accessible`): `Style.access_disabled`, `Style.role` and the
//! live text inside it, `View.labelledBy`, `View.controls` and the ARIA
//! properties a style gives; of `Style.tab_stop`; and of the keys a window
//! holds (`View.keyDown`, `View.codeDown`) and shortcut auto-repeat.
const std = @import("std");
const z = @import("ziggurat");
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

const Form = struct {
    agree: bool = false,
    saves: usize = 0,
    caption: u64 = 0,
    checkbox: u64 = 0,
    panel: u64 = 0,
    fn build(self: *Form, v: *View) anyerror!void {
        try v.column(.{ .key = 1, .role = .region, .name = "Settings", .gap = 8 });
        if (try v.button("Save", .{ .key = 2, .access_disabled = true, .key_shortcuts = "Control+S", .role_description = "action" })) self.saves += 1;
        _ = try v.button("Skip", .{ .key = 3, .tab_stop = false });
        _ = try v.button("Next", .{ .key = 4, .current = .step, .popup = .menu, .busy = true });
        try v.text("I agree to the terms", .{ .key = 5 });
        self.caption = v.lastNode().id;
        _ = try v.checkbox(&self.agree, "", .{ .key = 6 });
        self.checkbox = v.lastNode().id;
        try v.labelledBy(self.checkbox, self.caption);
        try v.column(.{ .key = 7, .role = .log, .name = "Chat" });
        self.panel = v.lastNode().id;
        try v.text("Hello", .{ .key = 8 });
        try v.end();
        try v.controls(self.checkbox, self.panel);
        try v.text("Title", .{ .key = 9, .role = .heading, .font = view.Font.heading2 });
        try v.end();
    }
};

test "assistive technology reads roles, names and the states a style gives" {
    var storage: Storage = .{};
    var app: Form = .{};
    var h = Harness.init(&app, Form.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    h.recordSemantics(&context) catch |err| if (err == error.SkipZigTest) return error.SkipZigTest else return err;
    try h.render();
    const region = try h.accessible(.{ .key = 1 });
    try testing.expectEqual(ui.accessibility.Role.region, region.role());
    try testing.expectEqualStrings("Settings", region.name());
    // Disabled to assistive technology, still focusable and clickable.
    const save = try h.accessible(.{ .key = 2 });
    try testing.expect(!save.entry.enabled and save.entry.focusable_disabled);
    try testing.expectEqualStrings("Control+S", save.keyShortcuts());
    try testing.expectEqualStrings("action", save.roleDescription());
    try testing.expectEqual(region.entry.id, save.parent().?);
    try h.click(.{ .key = 2 });
    try testing.expectEqual(@as(usize, 1), app.saves);
    const next = try h.accessible(.{ .key = 4 });
    try testing.expect(next.entry.busy);
    try testing.expectEqual(ui.accessibility.Current.step, next.entry.current);
    try testing.expectEqual(ui.accessibility.Popup.menu, next.entry.popup);
    // The caption names the checkbox, and a click on it clicks the box.
    const agree = try h.accessibleId(app.checkbox);
    try testing.expectEqualStrings("I agree to the terms", agree.name());
    try testing.expectEqual(app.panel, agree.entry.controls);
    try h.click(.{ .key = 5 });
    try testing.expect(app.agree);
    try testing.expectEqual(app.checkbox, h.focused().?.id);
    // A log reads its texts; a heading takes its font's level.
    const log = try h.accessible(.{ .key = 7 });
    try testing.expectEqual(ui.accessibility.Role.log, log.role());
    const hello = try h.accessible(.{ .key = 8 });
    try testing.expectEqual(ui.accessibility.Role.text, hello.role());
    try testing.expectEqualStrings("Hello", hello.name());
    try testing.expectEqual(log.entry.id, hello.parent().?);
    const title = try h.accessible(.{ .key = 9 });
    try testing.expectEqual(ui.accessibility.Role.heading, title.role());
    try testing.expectEqual(@as(u32, 2), title.entry.level);
    // Every node but the window, parents before children.
    var all: [32]view.Accessible = undefined;
    const nodes = try h.accessibleAll(&all);
    try testing.expect(nodes.len >= 7);
    try testing.expectEqual(region.entry.id, nodes[0].entry.id);
    for (nodes, 0..) |node, at| {
        try testing.expect(node.role() != .window);
        if (node.parent()) |parent| if (parent != ui.accessibility.root_id) {
            var before = false;
            for (nodes[0..at]) |earlier| before = before or earlier.entry.id == parent;
            try testing.expect(before);
        };
    }
    var few: [2]view.Accessible = undefined;
    try testing.expectError(error.NoSpaceLeft, h.accessibleAll(&few));
}

test "Tab passes over a node out of its order, which a press still focuses" {
    var storage: Storage = .{};
    var app: Form = .{};
    var h = Harness.init(&app, Form.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    _ = try h.key(.{ .key = .tab });
    try testing.expectEqual((try h.find(.{ .key = 2 })).id, h.focused().?.id);
    _ = try h.key(.{ .key = .tab });
    try testing.expectEqual((try h.find(.{ .key = 4 })).id, h.focused().?.id);
    try h.click(.{ .key = 3 });
    try testing.expectEqual((try h.find(.{ .key = 3 })).id, h.focused().?.id);
}

const Keys = struct {
    intl: bool = false,
    space: bool = false,
    repeated: usize = 0,
    fired: usize = 0,
    fn build(self: *Keys, v: *View) anyerror!void {
        self.intl = v.codeDown(.intl_ro);
        self.space = v.keyDown(.space);
        try v.column(.{});
        _ = try v.button("Go", .{});
        try v.bindKey(.{ .key = .k, .modifiers = .{ .control = true }, .allow_repeat = true }, true, 77);
        if (v.takeEvent(77)) |_| {
            self.fired += 1;
            if (v.shortcutRepeated()) self.repeated += 1;
        }
        try v.end();
    }
};

test "the keys held reach the build wherever the focus is, and shortcuts tell a repeat" {
    var storage: Storage = .{};
    var app: Keys = .{};
    var h = Harness.init(&app, Keys.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    // A key the layout names nothing for counts by its position.
    _ = try h.codeDown(.{}, .intl_ro);
    try testing.expect(app.intl);
    _ = try h.codeUp(.{}, .intl_ro);
    try testing.expect(!app.intl);
    _ = try h.key(.{ .key = .space, .code = .space });
    try testing.expect(app.space);
    try h.windowFocus(false);
    try testing.expect(!app.space);
    try h.windowFocus(true);
    _ = try h.key(.{ .key = .k, .modifiers = .{ .control = true } });
    _ = try h.key(.{ .key = .k, .modifiers = .{ .control = true }, .repeat = true });
    try testing.expectEqual(@as(usize, 2), app.fired);
    try testing.expectEqual(@as(usize, 1), app.repeated);
    _ = z;
}

const Links = struct {
    followed: usize = 0,
    fn build(self: *Links, v: *View) anyerror!void {
        try v.column(.{});
        if (try v.link("Docs", .{ .key = 1 })) self.followed += 1;
        try v.end();
    }
};

test "Enter follows a focused link and Space does not" {
    var storage: Storage = .{};
    var app: Links = .{};
    var h = Harness.init(&app, Links.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.focus(.{ .key = 1 });
    _ = try h.key(.{ .key = .space });
    try testing.expectEqual(@as(usize, 0), app.followed);
    _ = try h.key(.{ .key = .enter });
    try testing.expectEqual(@as(usize, 1), app.followed);
}

const Grid = struct {
    agree: bool = false,
    box: u64 = 0,
    fn build(self: *Grid, v: *View) anyerror!void {
        try v.column(.{ .key = 1, .role = .grid, .name = "Sheet", .row_count = 1000, .column_count = 3, .multiselectable = true });
        try v.row(.{ .key = 2, .role = .row, .row_index = 41, .access_selected = true });
        try v.text("A41", .{ .key = 3, .role = .cell, .column_index = 1, .access_selected = false });
        try v.text("B41", .{ .key = 4, .role = .cell, .column_index = 2, .access_selected = true });
        try v.end();
        try v.end();
        try v.text("Old price", .{ .key = 5, .role = .deletion });
        try v.text("New price", .{ .key = 6, .role = .insertion });
        try v.column(.{ .key = 7, .role = .separator, .orientation = .horizontal, .width = 2, .height = 40 });
        try v.end();
        _ = try v.checkbox(&self.agree, "Terms", .{ .key = 8, .invalid = !self.agree });
        self.box = v.lastNode().id;
        try v.text("You must agree to continue", .{ .key = 9 });
        try v.errorMessage(self.box, v.lastNode().id);
        try v.text("Read them first", .{ .key = 10, .access_hidden = true });
        try v.describedBy(self.box, v.lastNode().id);
        try v.column(.{ .key = 11, .role = .group, .position_in_set = 5, .set_size = 50 });
        try v.end();
    }
};

const Landmarks = struct {
    fn build(_: *Landmarks, v: *View) anyerror!void {
        try v.column(.{ .key = 1, .role = .banner, .name = "Title bar" });
        try v.text("Notes", .{});
        try v.end();
        try v.column(.{ .key = 2, .role = .main });
        try v.column(.{ .key = 3, .role = .tab_panel, .name = "General" });
        try v.text("General settings", .{});
        try v.end();
        try v.end();
        try v.column(.{ .key = 4, .role = .complementary, .name = "Inspector" });
        try v.end();
        try v.column(.{ .key = 5, .role = .content_info });
        try v.text("42 words", .{});
        try v.end();
    }
};

test "a window tells its main, banner, content info and complementary landmarks and a tab's panel" {
    var storage: Storage = .{};
    var app: Landmarks = .{};
    var h = Harness.init(&app, Landmarks.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    h.recordSemantics(&context) catch |err| if (err == error.SkipZigTest) return error.SkipZigTest else return err;
    try h.render();
    try testing.expectEqual(ui.accessibility.Role.banner, (try h.accessible(.{ .key = 1 })).role());
    try testing.expectEqual(ui.accessibility.Role.main, (try h.accessible(.{ .key = 2 })).role());
    try testing.expectEqual(ui.accessibility.Role.tab_panel, (try h.accessible(.{ .key = 3 })).role());
    try testing.expectEqual(ui.accessibility.Role.complementary, (try h.accessible(.{ .key = 4 })).role());
    try testing.expectEqual(ui.accessibility.Role.content_info, (try h.accessible(.{ .key = 5 })).role());
}

test "a grid of the application's own tells its rows and columns, choices, relations and orientation" {
    var storage: Storage = .{};
    var app: Grid = .{};
    var h = Harness.init(&app, Grid.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    h.recordSemantics(&context) catch |err| if (err == error.SkipZigTest) return error.SkipZigTest else return err;
    try h.render();
    const grid = try h.accessible(.{ .key = 1 });
    try testing.expectEqual(ui.accessibility.Role.grid, grid.role());
    try testing.expectEqual(@as(u32, 1000), grid.entry.row_count);
    try testing.expectEqual(@as(u32, 3), grid.entry.column_count);
    try testing.expect(grid.entry.multiple);
    const row = try h.accessible(.{ .key = 2 });
    try testing.expectEqual(ui.accessibility.Role.table_row, row.role());
    try testing.expectEqual(@as(u32, 41), row.entry.row_index);
    try testing.expect(row.entry.checked);
    const first = try h.accessible(.{ .key = 3 });
    try testing.expectEqual(ui.accessibility.Role.cell, first.role());
    try testing.expectEqual(@as(?bool, false), first.entry.selected);
    try testing.expectEqual(@as(u32, 1), first.entry.column_index);
    try testing.expectEqual(@as(?bool, true), (try h.accessible(.{ .key = 4 })).entry.selected);
    try testing.expectEqual(ui.accessibility.Role.deletion, (try h.accessible(.{ .key = 5 })).role());
    try testing.expectEqual(ui.accessibility.Role.insertion, (try h.accessible(.{ .key = 6 })).role());
    // Told horizontal, though it stands taller than wide.
    const line = try h.accessible(.{ .key = 7 });
    try testing.expect(line.entry.horizontal and !line.entry.vertical);
    // Invalid: the message is read first, then the hint, though the hint is
    // hidden from assistive technology.
    const terms = try h.accessibleId(app.box);
    try testing.expect(terms.entry.invalid);
    try testing.expectEqualStrings("You must agree to continue. Read them first", terms.description());
    try testing.expect(terms.entry.error_message != 0 and terms.entry.described_by != 0);
    try testing.expectError(error.NotFound, h.accessible(.{ .key = 10 }));
    const item = try h.accessible(.{ .key = 11 });
    try testing.expectEqual(@as(u32, 5), item.entry.position);
    try testing.expectEqual(@as(u32, 50), item.entry.set_size);
    // Once valid, only the hint describes it.
    try h.click(.{ .key = 8 });
    const agreed = try h.accessibleId(app.box);
    try testing.expect(!agreed.entry.invalid);
    try testing.expectEqualStrings("Read them first", agreed.description());
}

const Locked = struct {
    on: bool = true,
    level: f64 = 0.5,
    fn build(self: *Locked, v: *View) anyerror!void {
        _ = try v.checkbox(&self.on, "Keep", .{ .key = 1, .read_only = true });
        _ = try v.slider(&self.level, .{ .minimum = 0, .maximum = 1 }, .{ .key = 2, .name = "Level", .read_only = true });
        try v.column(.{ .key = 3, .role = .grid, .name = "Sheet", .read_only = true });
        try v.row(.{ .key = 4, .role = .row });
        try v.text("A1", .{ .key = 5, .role = .cell, .read_only = true });
        try v.end();
        try v.end();
        // Neither a button nor a plain table's text takes it.
        _ = try v.button("Save", .{ .key = 6, .read_only = true });
        try v.column(.{ .key = 7, .role = .region, .name = "Notes", .read_only = true });
        try v.end();
        _ = try v.checkbox(&self.on, "Free", .{ .key = 8 });
    }
};

test "read only is told on the roles that take it, as aria-readonly" {
    var storage: Storage = .{};
    var app: Locked = .{};
    var h = Harness.init(&app, Locked.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    h.recordSemantics(&context) catch |err| if (err == error.SkipZigTest) return error.SkipZigTest else return err;
    try h.render();
    for ([_]u64{ 1, 2, 3, 5 }) |key| try testing.expect((try h.accessible(.{ .key = key })).entry.read_only);
    for ([_]u64{ 6, 7, 8 }) |key| try testing.expect(!(try h.accessible(.{ .key = key })).entry.read_only);
}
