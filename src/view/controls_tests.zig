//! Headless tests of the dialog, checkbox group, sidebar, editable text
//! and find bar controls.
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
const Storage = view.Storage(128, 4096);

fn press(key: z.KeyCode) z.KeyInput {
    return .{ .key = key };
}
fn shifted(key: z.KeyCode) z.KeyInput {
    return .{ .key = key, .modifiers = .{ .shift = true } };
}

/// A focusable leaf standing in for a text field.
const FakeInput = struct {
    empty: bool = false,
    composing: bool = false,
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 40, .height = 24 }, .preferred = .{ .width = 120, .height = 24 } };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn status(ptr: *anyopaque) view.EmbedStatus {
        const self: *FakeInput = @ptrCast(@alignCast(ptr));
        return .{ .empty = self.empty, .composing = self.composing };
    }
    fn embed(self: *FakeInput) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .status = status, .focusable = true };
    }
};

fn focusedText(h: *const Harness) []const u8 {
    const node = h.focused() orelse return "";
    return node.text;
}

const DialogApp = struct {
    open: bool = false,
    alert_open: bool = false,
    state: view.DialogState = .closed,
    dismissals: usize = 0,
    response: ?usize = null,
    behind: usize = 0,
    fn build(self: *DialogApp, v: *View) anyerror!void {
        if (try v.button("Open", .{})) self.open = true;
        if (try v.button("Behind", .{})) self.behind += 1;
        if (try v.button("Alert", .{})) self.alert_open = true;
        self.state = try v.dialog(&self.open, .{ .description = "Choose how files open." }, .{ .name = "Settings" });
        if (self.state == .dismissed) self.dismissals += 1;
        if (self.state == .open) {
            try v.text("Settings", .{});
            if (try v.button("OK", .{})) self.open = false;
            _ = try v.button("Other", .{});
        }
        try v.end();
        if (try v.alertDialog(&self.alert_open, .{ .title = "Delete file?", .message = "This cannot be undone.", .buttons = &.{ "Cancel", "Delete" }, .default = 1, .cancel = 0 }, .{})) |index| self.response = index;
    }
};

test "a dialog traps focus, makes the window inert and returns focus to its opener" {
    var storage: Storage = .{};
    var app: DialogApp = .{};
    var h = Harness.init(&app, DialogApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "OK" }));

    try h.click(.{ .text = "Open" });
    try testing.expect(app.open);
    // Focus moves to the dialog's first control.
    try testing.expectEqualStrings("OK", focusedText(&h));
    const panel = try h.find(.{ .kind = .dialog, .nth = 0 });
    try testing.expect(panel.checked);
    try testing.expect(panel.bounds.width >= view.dialog_min_width);
    // What is behind it takes no input.
    try testing.expectError(error.Inert, h.click(.{ .text = "Behind" }));
    // Tab and Shift+Tab stay within the dialog.
    try testing.expect(try h.key(press(.tab)));
    try testing.expectEqualStrings("Other", focusedText(&h));
    try testing.expect(try h.key(press(.tab)));
    try testing.expectEqualStrings("OK", focusedText(&h));
    try testing.expect(try h.key(shifted(.tab)));
    try testing.expectEqualStrings("Other", focusedText(&h));

    // Escape dismisses it and focus returns to the opener.
    try testing.expect(try h.key(press(.escape)));
    try testing.expect(!app.open);
    try testing.expectEqual(@as(usize, 1), app.dismissals);
    try testing.expectEqualStrings("Open", focusedText(&h));
    try h.click(.{ .text = "Behind" });
    try testing.expectEqual(@as(usize, 1), app.behind);

    // A press on the scrim dismisses it; one on the panel does not.
    try h.click(.{ .text = "Open" });
    const rect = (try h.find(.{ .kind = .dialog, .nth = 0 })).bounds;
    try testing.expectError(error.NotFound, h.clickAt(rect.x + 4, rect.y + 4));
    try testing.expect(app.open);
    try h.clickAt(2, 2);
    try testing.expect(!app.open);
    try testing.expectEqual(@as(usize, 2), app.dismissals);
    try testing.expectEqualStrings("Open", focusedText(&h));
    try testing.expectEqual(@as(usize, 1), app.behind);

    // Closing from inside also hands focus back.
    try h.click(.{ .text = "Open" });
    try h.click(.{ .text = "OK" });
    try testing.expect(!app.open);
    try testing.expectEqual(@as(usize, 2), app.dismissals);
    try testing.expectEqualStrings("Open", focusedText(&h));
}

test "an alert dialog ignores the scrim, focuses its default and answers Escape with cancel" {
    var storage: Storage = .{};
    var app: DialogApp = .{};
    var h = Harness.init(&app, DialogApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.click(.{ .text = "Alert" });
    try testing.expectEqualStrings("Delete", focusedText(&h));
    try testing.expectEqualStrings("Delete file?", (try h.find(.{ .kind = .dialog, .nth = 1 })).style.name);
    try h.clickAt(2, 2);
    try testing.expect(app.alert_open);
    try testing.expectEqual(@as(?usize, null), app.response);
    try testing.expect(try h.key(press(.escape)));
    try testing.expect(!app.alert_open);
    try testing.expectEqual(@as(?usize, 0), app.response);
    try testing.expectEqualStrings("Alert", focusedText(&h));

    app.response = null;
    try h.click(.{ .text = "Alert" });
    try h.click(.{ .text = "Delete" });
    try testing.expectEqual(@as(?usize, 1), app.response);
    try testing.expect(!app.alert_open);
}

test "a sheet sits at the top edge and a dialog cannot open inside a popover" {
    const App = struct {
        open: bool = true,
        fn build(self: *@This(), v: *View) anyerror!void {
            _ = try v.button("Anchor", .{});
            if (try v.sheet(&self.open, .{}, .{ .name = "Export" }) == .open) _ = try v.button("Save", .{});
            try v.end();
        }
    };
    var storage: Storage = .{};
    var app: App = .{};
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    try h.render();
    const panel = try h.find(.{ .kind = .dialog });
    try testing.expectEqual(@as(f32, 0), panel.bounds.y);

    const Nested = struct {
        open: bool = true,
        inner: bool = true,
        fn build(self: *@This(), v: *View) anyerror!void {
            _ = try v.button("Anchor", .{});
            _ = try v.popover(&self.open, .{}, .{});
            _ = try v.dialog(&self.inner, .{}, .{});
            try v.end();
            try v.end();
        }
    };
    var nested_storage: Storage = .{};
    var nested: Nested = .{};
    var n = Harness.init(&nested, Nested.build, nested_storage.buffers(), .{});
    try testing.expectError(error.NotContainer, n.render());
}

const GroupApp = struct {
    values: [3]bool = .{ true, false, false },
    state: view.CheckState = .mixed,
    changes: usize = 0,
    fn build(self: *GroupApp, v: *View) anyerror!void {
        const items = [_]view.CheckboxItem{
            .{ .value = &self.values[0], .label = "Red" },
            .{ .value = &self.values[1], .label = "Green" },
            .{ .value = &self.values[2], .label = "Blue" },
        };
        if (try v.checkboxGroup("All colors", &items, .{})) self.changes += 1;
        _ = try v.checkboxState(&self.state, "Tri", .{});
    }
};

test "a checkbox group derives a mixed head and sets every box" {
    var storage: Storage = .{};
    var app: GroupApp = .{};
    var h = Harness.init(&app, GroupApp.build, storage.buffers(), .{});
    try h.render();
    var head = try h.find(.{ .text = "All colors" });
    try testing.expect(head.mixed and !head.checked);
    try h.click(.{ .text = "All colors" });
    try testing.expectEqual([3]bool{ true, true, true }, app.values);
    head = try h.find(.{ .text = "All colors" });
    try testing.expect(head.checked and !head.mixed);
    try h.click(.{ .text = "All colors" });
    try testing.expectEqual([3]bool{ false, false, false }, app.values);
    try testing.expectEqual(@as(usize, 2), app.changes);
    try h.click(.{ .text = "Green" });
    head = try h.find(.{ .text = "All colors" });
    try testing.expect(head.mixed);
    try testing.expectEqual(view.CheckState.mixed, view.CheckState.of(&app.values));

    // A mixed box checks on activation, then unchecks.
    try testing.expect((try h.find(.{ .text = "Tri" })).mixed);
    try h.click(.{ .text = "Tri" });
    try testing.expectEqual(view.CheckState.checked, app.state);
    try h.click(.{ .text = "Tri" });
    try testing.expectEqual(view.CheckState.unchecked, app.state);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try h.write(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "checkbox \"All colors\" mixed") != null);
}

const SidebarApp = struct {
    storage: [1]u64 = undefined,
    selection: view.Selection = undefined,
    library: bool = true,
    tags: bool = true,
    chosen: ?u64 = null,
    fn init(self: *SidebarApp) void {
        self.selection = view.Selection.init(.single, &self.storage);
    }
    fn build(self: *SidebarApp, v: *View) anyerror!void {
        try v.sidebar(&self.selection, .{ .name = "Places" });
        if (try v.sidebarSection(100, "Library", &self.library, .{})) {
            if (try v.sidebarItem(1, "Inbox", .{ .badge = "3" }, .{})) self.chosen = 1;
            if (try v.sidebarItem(2, "Drafts", .{}, .{})) self.chosen = 2;
        }
        try v.end();
        if (try v.sidebarSection(200, "Tags", &self.tags, .{})) {
            if (try v.sidebarItem(3, "Work", .{}, .{})) self.chosen = 3;
            if (try v.sidebarItem(4, "Ideas", .{}, .{})) self.chosen = 4;
        }
        try v.end();
        try v.end();
        _ = try v.button("Elsewhere", .{});
    }
};

test "a sidebar selects items by id, steps over headings and collapses sections" {
    var storage: Storage = .{};
    var app: SidebarApp = .{};
    app.init();
    var h = Harness.init(&app, SidebarApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const inbox = try h.find(.{ .text = "Inbox" });
    try testing.expectEqualStrings("3", inbox.badge);
    try testing.expectEqual(@as(u16, 1), inbox.level);

    try h.click(.{ .text = "Inbox" });
    try testing.expectEqual(@as(?u64, 1), app.chosen);
    try testing.expect(app.selection.contains(1));
    try testing.expectEqualStrings("Inbox", focusedText(&h));
    try testing.expect(try h.key(press(.down)));
    try testing.expectEqual(@as(?u64, 2), app.chosen);
    // The next heading takes the cursor without being selected.
    try testing.expect(try h.key(press(.down)));
    try testing.expectEqualStrings("Tags", focusedText(&h));
    try testing.expect(app.selection.contains(2) and !app.selection.contains(200));
    // Space toggles the section; its items go.
    try testing.expect(try h.key(press(.space)));
    try testing.expect(!app.tags);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Work" }));
    try testing.expect(try h.key(press(.enter)));
    try testing.expect(app.tags);
    // Type-ahead moves to the next row starting with the letter.
    try testing.expect(try h.key(press(.i)));
    try testing.expectEqualStrings("Ideas", focusedText(&h));
    try testing.expectEqual(@as(?u64, 4), app.chosen);
    try testing.expect(try h.key(press(.i)));
    try testing.expectEqualStrings("Inbox", focusedText(&h));
    // Left goes from an item to its heading; a press on the heading
    // collapses the section.
    try testing.expect(try h.key(press(.left)));
    try testing.expectEqualStrings("Library", focusedText(&h));
    try h.click(.{ .text = "Library" });
    try testing.expect(!app.library);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Inbox" }));
    // Tab leaves the sidebar from its one stop.
    try testing.expect(try h.key(press(.tab)));
    try testing.expectEqualStrings("Elsewhere", focusedText(&h));
}

const EditApp = struct {
    input: FakeInput = .{},
    state: view.EditableText = .{},
    name: []const u8 = "Report",
    edits: [4]?view.Edit = .{ null, null, null, null },
    count: usize = 0,
    fn build(self: *EditApp, v: *View) anyerror!void {
        if (try v.editableText(&self.state, self.name, self.input.embed(), .{ .hint = "Press Enter to rename" }, .{ .name = "Name" })) |edit| {
            self.edits[self.count % self.edits.len] = edit;
            self.count += 1;
            if (edit == .commit) self.name = "Renamed";
        }
        _ = try v.button("Other", .{});
    }
};

test "editable text begins on Enter or F2, commits on Enter or blur and reverts on Escape" {
    var storage: Storage = .{};
    var app: EditApp = .{};
    var h = Harness.init(&app, EditApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.focus(.{ .text = "Report" });
    try testing.expect(try h.key(press(.enter)));
    try testing.expect(app.state.editing);
    try testing.expectEqual(@as(?view.Edit, .begin), app.edits[0]);
    // The input takes the label's place and focus.
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
    try testing.expect(try h.key(press(.escape)));
    try testing.expectEqual(@as(?view.Edit, .cancel), app.edits[1]);
    try testing.expectEqualStrings("Report", focusedText(&h));

    // While the input method composes, Enter is not taken.
    try testing.expect(try h.key(press(.f2)));
    try testing.expectEqual(@as(?view.Edit, .begin), app.edits[2]);
    app.input.composing = true;
    h.view.focus = h.focused().?.id;
    try testing.expect(h.view.routeKey(press(.enter)) == .ignored);
    try testing.expect(app.state.editing);
    app.input.composing = false;
    try testing.expect(try h.key(press(.enter)));
    try testing.expectEqual(@as(?view.Edit, .commit), app.edits[3]);
    try testing.expectEqualStrings("Renamed", focusedText(&h));

    // Focus leaving the input commits.
    try h.click(.{ .text = "Renamed" });
    try testing.expect(app.state.editing);
    // A window repaints when focus moves into the input.
    try h.render();
    try h.focus(.{ .text = "Other" });
    try h.render();
    try testing.expect(!app.state.editing);
    try testing.expectEqual(@as(?view.Edit, .commit), app.edits[1]);
    try testing.expectEqualStrings("Other", focusedText(&h));
}

const FindApp = struct {
    input: FakeInput = .{},
    bar: view.FindBar = .{},
    matches: view.FindMatches = .{ .count = 3 },
    last: ?view.FindEvent = null,
    events: usize = 0,
    fn build(self: *FindApp, v: *View) anyerror!void {
        _ = try v.button("Content", .{});
        if (try v.findBar(&self.bar, self.input.embed(), self.matches, .{}, .{})) |event| {
            self.last = event;
            self.events += 1;
            switch (event) {
                .next, .previous => self.matches.current = self.matches.step(event == .next),
                else => {},
            }
        }
    }
};

test "a find bar steps through the application's matches and closes on Escape" {
    var storage: Storage = .{};
    var app: FindApp = .{};
    var h = Harness.init(&app, FindApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .toolbar }));
    try h.focus(.{ .text = "Content" });
    // F3 opens the bar and focuses its input.
    try testing.expect(try h.key(press(.f3)));
    try testing.expect(app.bar.open);
    try testing.expectEqual(@as(?view.FindEvent, .opened), app.last);
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
    try testing.expectEqualStrings("Find", (try h.find(.{ .kind = .toolbar })).style.name);
    try testing.expectEqualStrings("3", (try h.find(.{ .key = 2 })).text);

    try testing.expect(try h.key(press(.enter)));
    try testing.expectEqual(@as(?usize, 0), app.matches.current);
    try testing.expectEqualStrings("1 of 3", (try h.find(.{ .key = 2 })).text);
    try testing.expectEqualStrings("1 of 3", h.announcement().?);
    try testing.expect(try h.key(shifted(.enter)));
    try testing.expectEqual(@as(?usize, 2), app.matches.current);
    try testing.expect(try h.key(press(.f3)));
    try testing.expectEqual(@as(?usize, 0), app.matches.current);
    try testing.expect(try h.key(shifted(.f3)));
    try testing.expectEqualStrings("3 of 3", (try h.find(.{ .key = 2 })).text);
    try h.click(.{ .name = "Next match" });
    try testing.expectEqualStrings("1 of 3", (try h.find(.{ .key = 2 })).text);

    try h.click(.{ .text = "Match case" });
    try testing.expect(app.bar.case_sensitive);
    try testing.expectEqual(@as(?view.FindEvent, .options), app.last);
    try h.click(.{ .text = "Whole word" });
    try testing.expect(app.bar.whole_word);

    // No matches: the buttons are disabled and the status says so.
    app.matches = .{};
    try h.render();
    try testing.expectEqualStrings("No results", (try h.find(.{ .key = 2 })).text);
    try testing.expect(!(try h.find(.{ .name = "Next match" })).style.enabled);
    app.input.empty = true;
    try h.render();
    try testing.expectEqualStrings("", (try h.find(.{ .key = 2 })).text);

    // Escape within the bar closes it and focus returns to the opener.
    try testing.expect(try h.key(press(.escape)));
    try testing.expect(!app.bar.open);
    try testing.expectEqual(@as(?view.FindEvent, .closed), app.last);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .toolbar }));
    try testing.expectEqualStrings("Content", focusedText(&h));
}

test "key bindings are scoped to focus and to the shown dialog" {
    const App = struct {
        fired: usize = 0,
        window: usize = 0,
        open: bool = false,
        fn build(self: *@This(), v: *View) anyerror!void {
            _ = try v.button("Target", .{});
            try v.bindKey(.{ .key = .k, .modifiers = .{ .control = true } }, false, 41);
            if (v.takeEvent(41) != null) self.fired += 1;
            _ = try v.button("Plain", .{});
            try v.bindKey(.{ .key = .f6 }, true, 42);
            if (v.takeEvent(42) != null) self.window += 1;
            if (try v.dialog(&self.open, .{}, .{}) == .open) _ = try v.button("Inside", .{});
            try v.end();
        }
    };
    var storage: Storage = .{};
    var app: App = .{};
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const chord: z.KeyInput = .{ .key = .k, .modifiers = .{ .control = true } };
    try h.focus(.{ .text = "Plain" });
    try testing.expect(!try h.key(chord));
    try h.focus(.{ .text = "Target" });
    try testing.expect(try h.key(chord));
    try testing.expectEqual(@as(usize, 1), app.fired);
    try testing.expect(!try h.key(.{ .key = .k, .modifiers = .{ .control = true }, .repeat = true }));
    try testing.expect(try h.key(press(.f6)));
    try testing.expectEqual(@as(usize, 1), app.window);
    // A shown dialog keeps window bindings made outside it.
    app.open = true;
    try h.render();
    try testing.expect(!try h.key(press(.f6)));
    try testing.expectEqual(@as(usize, 1), app.window);
}
