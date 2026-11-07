//! Headless tests of the controls without a look added for tabs, list
//! boxes, selects, trees and menus: `tabBase`, `listItemBase`,
//! `selectBase` with `selectListBase` and `selectOptionBase` (and a caller
//! owning whether it is open), `noSuggestions`, `treeItemBase` and
//! `menuGroupBase`.
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
const Storage = view.Storage(160, 4096);

const Tabs = struct {
    tab: usize = 0,
    fruit: usize = 0,
    fn build(self: *Tabs, v: *View) anyerror!void {
        try v.tabs(.{ .key = 1, .name = "Sections", .gap = 4 });
        for ([_][]const u8{ "General", "Network", "Privacy" }, 0..) |name, i| {
            _ = try v.tabBase(usize, &self.tab, i, .{ .key = 10 + i, .padding = .all(6), .enabled = i != 1, .background = if (self.tab == i) 0xdddddd else null });
            try v.text(name, .{});
            try v.end();
        }
        try v.end();
        try v.listBox(.{ .key = 2, .name = "Fruit" });
        for ([_][]const u8{ "Apple", "Pear" }, 0..) |name, i| {
            _ = try v.listItemBase(usize, &self.fruit, i, .{ .key = 20 + i });
            try v.text(name, .{});
            try v.end();
        }
        try v.end();
    }
};

test "tabs and options without a look choose, and the arrows pass over a disabled tab" {
    var storage: Storage = .{};
    var app: Tabs = .{};
    var h = Harness.init(&app, Tabs.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const general = try h.find(.{ .key = 10 });
    try testing.expect(general.plain and general.checked);
    try h.click(.{ .key = 12 });
    try testing.expectEqual(@as(usize, 2), app.tab);
    try h.focus(.{ .key = 12 });
    _ = try h.key(.{ .key = .left });
    try testing.expectEqual(@as(usize, 0), app.tab);
    try h.click(.{ .key = 21 });
    try testing.expectEqual(@as(usize, 1), app.fruit);
    try testing.expectError(error.Disabled, h.click(.{ .key = 11 }));
}

const Select = struct {
    open: bool = false,
    size: usize = 1,
    fn build(self: *Select, v: *View) anyerror!void {
        try v.selectBase(.{ .key = 1, .name = "Size", .padding = .all(4) });
        try v.text(([_][]const u8{ "Small", "Medium", "Large" })[self.size], .{});
        try v.end();
        if (try v.selectListBase(&self.open, .{ .padding = .all(2), .background = 0xffffff })) {
            for ([_][]const u8{ "Small", "Medium", "Large" }, 0..) |name, i| {
                const option = try v.selectOptionBase(usize, &self.size, i, .{ .key = 10 + i, .enabled = i != 2 });
                try v.text(name, .{});
                try v.end();
                _ = option;
            }
            try v.noSuggestions("Nothing else", .{ .key = 19 });
        }
        try v.end();
    }
};

test "a select without a look opens from its caller's flag and from its trigger, and chooses" {
    var storage: Storage = .{};
    var app: Select = .{};
    var h = Harness.init(&app, Select.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try testing.expect(!(try h.find(.{ .key = 1 })).checked);
    // The caller opens it.
    app.open = true;
    try h.render();
    try h.render();
    try testing.expect((try h.find(.{ .key = 1 })).checked);
    try testing.expect((try h.find(.{ .key = 11 })).checked);
    // The arrows pass over the disabled option and the row of no matches.
    _ = try h.key(.{ .key = .down });
    try h.render();
    try testing.expect((try h.find(.{ .key = 10 })).highlighted);
    // Escape closes it, and the flag hears so.
    _ = try h.key(.{ .key = .escape });
    try h.render();
    try testing.expect(!app.open);
    try testing.expect(!(try h.find(.{ .key = 1 })).checked);
    // A press on the trigger opens it and sets the flag; a choice closes it.
    try h.click(.{ .key = 1 });
    try h.render();
    try testing.expect(app.open);
    try h.click(.{ .key = 10 });
    try h.render();
    try testing.expectEqual(@as(usize, 0), app.size);
    try testing.expect(!app.open);
    // The caller closes it.
    app.open = true;
    try h.render();
    try h.render();
    try testing.expect((try h.find(.{ .key = 1 })).checked);
    app.open = false;
    try h.render();
    try h.render();
    try testing.expect(!(try h.find(.{ .key = 1 })).checked);
}

const Files = struct {
    selection: view.Selection = undefined,
    storage: [4]u64 = undefined,
    open: bool = true,
    levels: [3]u16 = .{ 9, 9, 9 },
    fn build(self: *Files, v: *View) anyerror!void {
        try v.tree(&self.selection, .{ .key = 1, .name = "Files" });
        const docs = try v.treeItemBase(100, &self.open, .{ .gap = 4 });
        self.levels[0] = docs.level;
        try v.text("Docs", .{});
        try v.end();
        if (self.open) {
            const readme = try v.treeItemBase(101, null, .{});
            self.levels[1] = readme.level;
            try v.text("README", .{});
            try v.end();
            try v.end();
        }
        try v.end();
        const notes = try v.treeItemBase(102, null, .{});
        self.levels[2] = notes.level;
        try v.text("Notes", .{});
        try v.end();
        try v.end();
        try v.end();
    }
};

test "a tree of rows without a look selects, nests and opens with the keys" {
    var storage: Storage = .{};
    var app: Files = .{};
    app.selection = view.Selection.init(.single, &app.storage);
    var h = Harness.init(&app, Files.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try testing.expectEqual([3]u16{ 0, 1, 0 }, app.levels);
    try h.click(.{ .kind = .tree_row, .nth = 1 });
    try testing.expectEqualSlices(u64, &.{101}, app.selection.items());
    try h.click(.{ .kind = .tree_row, .nth = 0 });
    try testing.expectEqualSlices(u64, &.{100}, app.selection.items());
    _ = try h.key(.{ .key = .left });
    try h.render();
    try testing.expect(!app.open);
    try testing.expectEqual(@as(usize, 2), h.count(.{ .kind = .tree_row }));
    _ = try h.key(.{ .key = .down });
    try h.render();
    try testing.expectEqualSlices(u64, &.{102}, app.selection.items());
}

const Theme = struct {
    theme: usize = 0,
    other: usize = 0,
    fn build(self: *Theme, v: *View) anyerror!void {
        try v.menuButtonBase(.{ .key = 1 });
        try v.text("Account", .{});
        try v.end();
        if (try v.popoverMenuBase(.{})) {
            const profile = try v.menuItemBase(.{}, .{ .key = 10 });
            try v.text("Profile", .{});
            try v.end();
            if (profile.clicked) self.other += 1;
            try v.menuGroupBase(.{ .key = 11, .name = "Theme", .gap = 2 });
            for ([_][]const u8{ "Light", "Dark", "System" }, 0..) |name, i| {
                const item = try v.menuItemBase(.{ .checked = self.theme == i, .radio = true, .keep_open = true }, .{ .key = 20 + i });
                try v.text(name, .{});
                try v.end();
                if (item.clicked) self.theme = i;
            }
            try v.end();
            const out = try v.menuItemBase(.{}, .{ .key = 30 });
            try v.text("Sign out", .{});
            try v.end();
            if (out.clicked) self.other += 10;
        }
        try v.end();
    }
};

test "a group of menu items is one stop for Up and Down, and Left and Right move in it" {
    var storage: Storage = .{};
    var app: Theme = .{ .theme = 1 };
    var h = Harness.init(&app, Theme.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try h.click(.{ .key = 1 });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 10 })).id, h.focused().?.id);
    // Down lands on the group's checked item, Dark.
    _ = try h.key(.{ .key = .down });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 21 })).id, h.focused().?.id);
    // Right and Left move within it, round.
    _ = try h.key(.{ .key = .right });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 22 })).id, h.focused().?.id);
    _ = try h.key(.{ .key = .right });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 20 })).id, h.focused().?.id);
    // Enter chooses and the menu stays open.
    _ = try h.key(.{ .key = .enter });
    try h.render();
    try testing.expectEqual(@as(usize, 0), app.theme);
    try testing.expectEqual(@as(usize, 1), h.count(.{ .key = 20 }));
    // Down leaves the group for the next item.
    _ = try h.key(.{ .key = .down });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 30 })).id, h.focused().?.id);
    _ = try h.key(.{ .key = .up });
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 20 })).id, h.focused().?.id);
}
