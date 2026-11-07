//! Headless tests of menus that a secondary press or the menu key opens.
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
const Storage = view.Storage(128, 4096);

const Editor = struct {
    copied: usize = 0,
    wrap: bool = false,
    size: u8 = 1,
    exported: bool = false,
    paste_enabled: bool = false,
    inner: usize = 0,
    fn build(self: *Editor, v: *View) anyerror!void {
        _ = try v.button("Before", .{});
        try v.column(.{ .height = 200, .padding = .all(10), .gap = 8, .self_align = .stretch });
        _ = try v.button("Inside", .{});
        try v.column(.{ .height = 40 });
        try v.text("Nested area", .{});
        try v.end();
        if (try v.popoverMenu(.{ .name = "Inner" })) {
            if (try v.menuItem("Inner action", .{}, .{})) self.inner += 1;
        }
        try v.end();
        try v.end();
        if (try v.popoverMenu(.{ .name = "Edit" })) {
            if (try v.menuItem("Copy", .{ .shortcut = "Ctrl+C" }, .{})) self.copied += 1;
            _ = try v.menuItem("Paste", .{}, .{ .enabled = self.paste_enabled });
            try v.menuSeparator();
            if (try v.menuItem("Wrap lines", .{ .checked = self.wrap }, .{})) self.wrap = !self.wrap;
            if (try v.submenu("Size", .{})) {
                for ([_][]const u8{ "Small", "Medium", "Large" }, 0..) |label, i| {
                    if (try v.menuItem(label, .{ .checked = self.size == i, .radio = true }, .{ .key = i })) self.size = @intCast(i);
                }
            }
            try v.end();
            if (try v.menuItem("Export", .{ .tooltip = "Saves a copy as PDF" }, .{})) self.exported = true;
        }
        try v.end();
    }
};

fn open(h: *Harness) !void {
    const area = try h.boundsOf(.{ .text = "Inside" });
    // In the anchor's padding, beside the button.
    try testing.expect(try h.clickButtonAt(area.x + 4, area.y - 5, .secondary, .{}));
}

test "a secondary press opens the menu at the pointer, and a press on an item chooses it" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{});
    try h.render();
    try testing.expect(h.visible(try h.find(.{ .kind = .menu, .nth = 1 })) == null);
    const area = try h.boundsOf(.{ .text = "Inside" });
    const x = area.x + 40;
    const y = area.y - 5;
    try testing.expect(try h.clickButtonAt(x, y, .secondary, .{}));
    const panel = try h.boundsOf(.{ .kind = .menu, .nth = 1 });
    try testing.expectApproxEqAbs(x, panel.x, 0.01);
    try testing.expectApproxEqAbs(y, panel.y, 0.01);
    try testing.expect(panel.width >= 160);
    // The submenu stays shut until it is reached.
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Small" }));
    try h.click(.{ .text = "Copy" });
    try testing.expectEqual(@as(usize, 1), app.copied);
    try testing.expectError(error.NotFound, h.find(.{ .text = "Copy" }));
}

test "an item's tooltip shows as the pointer rests on it" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{ .options = .{ .tooltip_delay = 1 } });
    try h.render();
    try open(&h);
    try h.hover(.{ .text = "Copy" });
    try h.advance(std.time.ns_per_s);
    try testing.expect(h.tooltip() == null);
    try h.hover(.{ .text = "Export" });
    try h.advance(std.time.ns_per_s);
    try testing.expectEqualStrings("Saves a copy as PDF", h.tooltip().?);
}

const WithIcons = struct {
    icon: bool = false,
    fn build(self: *WithIcons, v: *View) anyerror!void {
        try v.column(.{ .height = 200, .padding = .all(10), .self_align = .stretch });
        _ = try v.button("Inside", .{});
        try v.end();
        if (try v.popoverMenu(.{ .name = "File" })) {
            _ = try v.menuItem("Open", .{}, .{});
            _ = try v.menuItem("Share", .{ .icon = if (self.icon) .external_link else null }, .{});
        }
        try v.end();
    }
};

test "an item's icon gives every item of its panel the icon's column" {
    var storage: Storage = .{};
    var app: WithIcons = .{};
    var h = Harness.init(&app, WithIcons.build, storage.buffers(), .{});
    try h.render();
    try open(&h);
    const plain = (try h.boundsOf(.{ .kind = .menu_item, .text = "Open" })).width;
    try testing.expect(!(try h.find(.{ .kind = .menu_item, .text = "Open" })).menu_icons);
    app.icon = true;
    try h.render();
    const open_item = try h.find(.{ .kind = .menu_item, .text = "Open" });
    const share = try h.find(.{ .kind = .menu_item, .text = "Share" });
    try testing.expect(open_item.menu_icons and share.menu_icons);
    try testing.expect(open_item.menu_icon == null and share.menu_icon == .external_link);
    try testing.expect((try h.boundsOf(.{ .kind = .menu_item, .text = "Open" })).width >= plain);
}

test "the innermost anchor under the press opens its menu" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{});
    try h.render();
    const nested = try h.boundsOf(.{ .text = "Nested area" });
    try testing.expect(try h.clickButtonAt(nested.x + 2, nested.y + 2, .secondary, .{}));
    try h.click(.{ .text = "Inner action" });
    try testing.expectEqual(@as(usize, 1), app.inner);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Copy" }));
}

test "a press outside the menu closes it and reaches what lies there" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{});
    try h.render();
    try open(&h);
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Copy" }));
    const before = try h.boundsOf(.{ .text = "Before" });
    try h.clickAt(before.x + 4, before.y + 4);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Copy" }));
    // A disabled item takes no press and leaves the menu open.
    try open(&h);
    try testing.expectError(error.Disabled, h.click(.{ .text = "Paste" }));
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Copy" }));
}

test "keys move the highlight, open submenus and choose, and focus goes back" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.focus(.{ .text = "Inside" });
    // The menu key opens the menu of the innermost anchor around focus.
    try testing.expect(try h.key(.{ .key = .context_menu }));
    try h.render();
    const copy = try h.find(.{ .text = "Copy" });
    try testing.expect(copy.highlighted);
    try testing.expectEqual(copy.id, h.focused().?.id);
    // Below the anchor, at its start.
    const anchor = h.view.nodes()[(try h.find(.{ .kind = .menu, .nth = 1 })).anchor].bounds;
    const panel = try h.boundsOf(.{ .kind = .menu, .nth = 1 });
    try testing.expectApproxEqAbs(anchor.y + anchor.height, panel.y, 0.01);
    // Down skips the disabled item and the separator.
    try testing.expect(try h.key(.{ .key = .down }));
    try testing.expectEqualStrings("Wrap lines", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .down }));
    try testing.expectEqualStrings("Size", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .right }));
    try h.render();
    try testing.expectEqualStrings("Small", h.focused().?.text);
    try testing.expect((try h.find(.{ .text = "Size" })).expanded.?);
    try testing.expect(try h.key(.{ .key = .end }));
    try testing.expectEqualStrings("Large", h.focused().?.text);
    // Left closes the submenu and goes back to its item.
    try testing.expect(try h.key(.{ .key = .left }));
    try h.render();
    try testing.expectEqualStrings("Size", h.focused().?.text);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Large" }));
    try testing.expect(try h.key(.{ .key = .enter }));
    try h.render();
    try testing.expect(try h.key(.{ .key = .down }));
    try testing.expect(try h.key(.{ .key = .enter }));
    try testing.expectEqual(@as(u8, 1), app.size);
    try testing.expectEqualStrings("Inside", h.focused().?.text);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Copy" }));

    // A letter moves to the next item starting with it; Escape closes the
    // menu and gives focus back.
    try testing.expect(try h.key(.{ .key = .f10, .modifiers = .{ .shift = true } }));
    try h.render();
    try testing.expect(try h.key(.{ .key = .e }));
    try testing.expectEqualStrings("Export", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.render();
    try testing.expectEqualStrings("Inside", h.focused().?.text);
    try testing.expect(!app.exported);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Copy" }));
}

test "hovering an item highlights it and shows its submenu beside it" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 } });
    try h.render();
    try open(&h);
    try h.hover(.{ .text = "Size" });
    const size = try h.find(.{ .text = "Size" });
    try testing.expect(size.highlighted and size.expanded.?);
    const item = try h.boundsOf(.{ .text = "Size" });
    const sub = try h.boundsOf(.{ .kind = .menu, .nth = 2 });
    try testing.expect(sub.x >= item.x + item.width);
    try testing.expectApproxEqAbs(item.y - 4, sub.y, 0.01);
    try h.click(.{ .text = "Large" });
    try testing.expectEqual(@as(u8, 2), app.size);
    // Hovering a plain item closes the submenu.
    try open(&h);
    try h.hover(.{ .text = "Size" });
    try h.hover(.{ .text = "Copy" });
    try testing.expect(!(try h.find(.{ .text = "Size" })).expanded.?);
    try h.click(.{ .text = "Wrap lines" });
    try testing.expect(app.wrap);
}

test "a menu near the window's edges flips toward the room it has" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 500, .height = 260 } });
    try h.render();
    const area = try h.boundsOf(.{ .text = "Inside" });
    const x: f32 = 470;
    const y = area.y + 150;
    try testing.expect(try h.clickButtonAt(x, y, .secondary, .{}));
    const panel = try h.boundsOf(.{ .kind = .menu, .nth = 1 });
    try testing.expectApproxEqAbs(x, panel.x + panel.width, 0.01);
    try testing.expect(panel.y + panel.height <= 260);
    try h.hover(.{ .text = "Size" });
    const sub = try h.boundsOf(.{ .kind = .menu, .nth = 2 });
    try testing.expect(sub.x + sub.width <= panel.x + 0.01);
}

test "right to left, a menu opens toward the left and Left opens a submenu" {
    var storage: Storage = .{};
    var app: Editor = .{};
    var h = Harness.init(&app, Editor.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.setDirection(.rtl);
    try h.focus(.{ .text = "Inside" });
    try testing.expect(try h.key(.{ .key = .context_menu }));
    try h.render();
    const menu = try h.find(.{ .kind = .menu, .nth = 1 });
    const anchor = h.view.nodes()[menu.anchor].bounds;
    const panel = try h.boundsOf(.{ .kind = .menu, .nth = 1 });
    try testing.expectApproxEqAbs(anchor.x + anchor.width, panel.x + panel.width, 0.01);
    try testing.expect(try h.key(.{ .key = .up }));
    try testing.expect(try h.key(.{ .key = .up }));
    try testing.expectEqualStrings("Size", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .left }));
    try h.render();
    try testing.expectEqualStrings("Small", h.focused().?.text);
    const item = try h.boundsOf(.{ .text = "Size" });
    const sub = try h.boundsOf(.{ .kind = .menu, .nth = 2 });
    try testing.expect(sub.x + sub.width <= item.x);
    try testing.expect(try h.key(.{ .key = .right }));
    try h.render();
    try testing.expectEqualStrings("Size", h.focused().?.text);
}

test "a menu whose anchor is gone or disabled closes" {
    var storage: Storage = .{};
    var app: Toggle = .{};
    var h = Harness.init(&app, Toggle.build, storage.buffers(), .{});
    try h.render();
    const area = try h.boundsOf(.{ .text = "Target" });
    try testing.expect(try h.clickButtonAt(area.x + 2, area.y + 2, .secondary, .{}));
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Rename" }));
    app.enabled = false;
    try h.render();
    app.enabled = true;
    try h.render();
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Rename" }));
    try testing.expect(!try h.clickButtonAt(area.x + 2, area.y + 2, .middle, .{}));
}

const Toggle = struct {
    enabled: bool = true,
    fn build(self: *Toggle, v: *View) anyerror!void {
        try v.text("Target", .{ .enabled = self.enabled });
        if (try v.popoverMenu(.{})) _ = try v.menuItem("Rename", .{}, .{});
        try v.end();
    }
};

const Toolbar = struct {
    renamed: usize = 0,
    deleted: usize = 0,
    pinned: bool = false,
    bottom: bool = false,
    fn build(self: *Toolbar, v: *View) anyerror!void {
        if (self.bottom) try v.spacer(.{});
        try v.row(.{ .gap = 8 });
        _ = try v.button("Save", .{});
        if (try v.popoverMenuButton("More", .{})) {
            if (try v.menuItem("Rename", .{}, .{})) self.renamed += 1;
            if (try v.menuItem("Delete", .{}, .{})) self.deleted += 1;
            if (try v.menuItem("Pin", .{ .checked = self.pinned, .keep_open = true }, .{})) self.pinned = !self.pinned;
        }
        try v.end();
        try v.end();
    }
};

test "a menu button opens its menu below it on a press and closes it on another" {
    var storage: Storage = .{};
    var app: Toolbar = .{};
    var h = Harness.init(&app, Toolbar.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Rename" }));
    try h.click(.{ .text = "More" });
    const button = try h.find(.{ .text = "More" });
    try testing.expect(button.checked);
    const below = try h.boundsOf(.{ .text = "More" });
    const panel = try h.boundsOf(.{ .kind = .menu });
    try testing.expectApproxEqAbs(below.y + below.height, panel.y, 0.01);
    try testing.expectApproxEqAbs(below.x, panel.x, 0.01);
    // It opens on its first item, which holds focus.
    try testing.expectEqualStrings("Rename", h.focused().?.text);
    // A press on the button closes it, with focus back on the button.
    try h.clickAt(below.x + 4, below.y + below.height / 2);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Rename" }));
    try testing.expect(!(try h.find(.{ .text = "More" })).checked);
    try testing.expectEqualStrings("More", h.focused().?.text);
    // Down opens it from the keyboard; Enter chooses.
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expect(try h.key(.{ .key = .down }));
    try testing.expectEqualStrings("Delete", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .enter }));
    try testing.expectEqual(@as(usize, 1), app.deleted);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Rename" }));
    try testing.expectEqualStrings("More", h.focused().?.text);
    // Up opens it on its last item, which keeps it open as it is chosen.
    try testing.expect(try h.key(.{ .key = .up }));
    try h.render();
    try testing.expectEqualStrings("Pin", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .enter }));
    try testing.expect(app.pinned);
    try h.render();
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Rename" }));
    try testing.expectEqualStrings("Pin", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .escape }));
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Rename" }));
}

test "a menu button at the window's bottom opens its menu above it" {
    var storage: Storage = .{};
    var app: Toolbar = .{ .bottom = true };
    var h = Harness.init(&app, Toolbar.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 200 } });
    try h.render();
    try h.click(.{ .text = "More" });
    const button = try h.boundsOf(.{ .text = "More" });
    const panel = try h.boundsOf(.{ .kind = .menu });
    try testing.expectApproxEqAbs(button.y, panel.y + panel.height, 0.01);
}

const Scrolled = struct {
    model: view.ScrollModel = .{},
    opened: usize = 0,
    fn build(self: *Scrolled, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 300, .self_align = .stretch });
        try v.column(.{ .gap = 10 });
        for (0..60) |i| try v.textf("Line {d}", .{i}, .{ .key = i });
        try v.end();
        if (try v.popoverMenu(.{})) {
            if (try v.menuItem("Open", .{}, .{})) self.opened += 1;
        }
        try v.end();
        try v.end();
    }
};

test "a menu opens at the pointer on an anchor scrolled partly out of view" {
    var storage: Storage = .{};
    var app: Scrolled = .{};
    var h = Harness.init(&app, Scrolled.build, storage.buffers(), .{});
    try h.render();
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 400 });
    const area = try h.boundsOf(.{ .kind = .scroll });
    const x = area.x + 100;
    const y = area.y + 150;
    try testing.expect(try h.clickButtonAt(x, y, .secondary, .{}));
    const panel = try h.boundsOf(.{ .kind = .menu });
    try testing.expectApproxEqAbs(x, panel.x, 0.01);
    try testing.expectApproxEqAbs(y, panel.y, 0.01);
}

const Rich = struct {
    open: bool = false,
    preview: ?usize = null,
    chosen: ?usize = null,
    deleted: usize = 0,
    narrow: bool = false,
    fn build(self: *Rich, v: *View) anyerror!void {
        try v.row(.{ .gap = 8, .self_align = .stretch });
        try v.spacer(.{});
        const options: view.MenuButtonOptions = .{ .placement = .{ .alignment = .end, .gap = 0 }, .open = &self.open, .max_width = if (self.narrow) 200 else std.math.inf(f32) };
        if (try v.popoverMenuButtonWith("More", options, .{})) {
            self.preview = null;
            for ([_][]const u8{ "Light", "Dark" }, 0..) |label, i| {
                const state = try v.menuItemState(label, .{}, .{ .key = i + 1 });
                if (state.highlighted) self.preview = i;
                if (state.clicked) self.chosen = i;
            }
            _ = try v.menuItem("Back Up Now", .{ .subtitle = "Last backup: 3 minutes ago" }, .{});
            _ = try v.menuItem("A very long file name that goes on and on.png", .{ .trailing = "2.4 MB" }, .{});
            try v.menuSeparator();
            if (try v.menuItem("Delete…", .{ .danger = true }, .{})) self.deleted += 1;
        }
        try v.end();
        try v.end();
    }
};

test "a menu button tells it opens a menu; the app's own popup wins" {
    var storage: Storage = .{};
    var app: Toolbar = .{};
    var h = Harness.init(&app, Toolbar.build, storage.buffers(), .{});
    try h.render();
    const button = try h.find(.{ .text = "More" });
    try testing.expectEqual(ui.accessibility.Popup.menu, button.style.popup.?);
    const Own = struct {
        fn build(_: *Toolbar, v: *View) anyerror!void {
            try v.menuButtonBase(.{ .name = "Account", .popup = .dialog });
            try v.text("Me", .{});
            try v.end();
            if (try v.popoverMenuBase(.{})) {}
            try v.end();
        }
    };
    var other = Harness.init(&app, Own.build, storage.buffers(), .{});
    try other.render();
    try testing.expectEqual(ui.accessibility.Popup.dialog, (try other.find(.{ .kind = .popup_button })).style.popup.?);
}

test "a menu button's menu goes where its options say, and the app holds whether it shows" {
    var storage: Storage = .{};
    var app: Rich = .{};
    var h = Harness.init(&app, Rich.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.click(.{ .text = "More" });
    try testing.expect(app.open);
    const button = try h.boundsOf(.{ .text = "More" });
    const panel = try h.boundsOf(.{ .kind = .menu });
    // Lined up with the button's end, below it.
    try testing.expectApproxEqAbs(button.x + button.width, panel.x + panel.width, 0.01);
    try testing.expectApproxEqAbs(button.y + button.height, panel.y, 0.01);
    // The first item is highlighted as the button opens it: the build sees it.
    try testing.expectEqual(@as(?usize, 0), app.preview);
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expectEqual(@as(?usize, 1), app.preview);
    // Escape closes it, which the app learns.
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.render();
    try testing.expect(!app.open);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Light" }));
    // The app opens it: focus goes to the menu, and it shows.
    app.open = true;
    try h.render();
    try h.render();
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Light" }));
    try testing.expectEqualStrings("Light", h.focused().?.text);
    // And closes it, focus going back.
    app.open = false;
    try h.render();
    try h.render();
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Light" }));
    try testing.expect(!app.open);
}

test "drawn menu items show a subtitle, a trailing value and a danger look, and a menu keeps to its most width" {
    var storage: Storage = .{};
    var app: Rich = .{ .open = true };
    var h = Harness.init(&app, Rich.build, storage.buffers(), .{});
    try h.render();
    try h.render();
    const plain = try h.boundsOf(.{ .text = "Light" });
    const subtitled = try h.boundsOf(.{ .text = "Back Up Now" });
    try testing.expect(subtitled.height > plain.height);
    const delete = try h.find(.{ .text = "Delete…" });
    try testing.expect(delete.danger);
    const wide = try h.boundsOf(.{ .kind = .menu });
    try testing.expect(wide.width > 200);
    app.narrow = true;
    try h.render();
    try h.render();
    const narrow = try h.boundsOf(.{ .kind = .menu });
    try testing.expectApproxEqAbs(@as(f32, 200), narrow.width, 0.01);
    // The items keep to the panel; their labels end with an ellipsis.
    const long = try h.boundsOf(.{ .text = "A very long file name that goes on and on.png" });
    try testing.expect(long.x + long.width <= narrow.x + narrow.width + 0.01);
}

const Download = struct {
    started: usize = 0,
    highlighted: bool = false,
    fn build(self: *Download, v: *View) anyerror!void {
        try v.column(.{ .height = 200, .self_align = .stretch });
        try v.text("Area", .{});
        try v.end();
        if (try v.popoverMenu(.{ .name = "Files" })) {
            _ = try v.menuItem("Open", .{}, .{});
            const state = try v.menuItemContent("Download", .{ .trailing = "40%" }, .{});
            try v.text("Downloading report.pdf", .{});
            try v.progress(0.4, .{ .self_align = .stretch });
            try v.end();
            self.highlighted = state.highlighted;
            if (state.clicked) self.started += 1;
        }
        try v.end();
    }
};

test "a menu item shows content of the application's own and is chosen by a press on it" {
    var storage: Storage = .{};
    var app: Download = .{};
    var h = Harness.init(&app, Download.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const area = try h.boundsOf(.{ .text = "Area" });
    try testing.expect(try h.clickButtonAt(area.x + 4, area.y + 4, .secondary, .{}));
    const item = try h.boundsOf(.{ .text = "Download" });
    const text = try h.boundsOf(.{ .text = "Downloading report.pdf" });
    // The content sits inside the item, after the mark's room.
    try testing.expect(text.x >= item.x + ui.widgets.menu_mark_width);
    try testing.expect(text.y >= item.y and text.y + text.height <= item.y + item.height);
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expect(app.highlighted);
    try h.clickAt(text.x + 2, text.y + text.height / 2);
    try testing.expectEqual(@as(usize, 1), app.started);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Download" }));
}
