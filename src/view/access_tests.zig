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
