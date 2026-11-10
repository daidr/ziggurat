//! Headless tests of menus that a secondary press or the menu key opens.
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

const TippedMenus = struct {
    const Kind = enum { menu_button, popover, context_menu };
    kind: Kind,
    open: bool = false,
    fn build(self: *TippedMenus, v: *View) anyerror!void {
        try v.column(.{ .padding = .all(60), .gap = 20 });
        _ = try v.button("First", .{});
        switch (self.kind) {
            .menu_button => {
                if (try v.popoverMenuButton("More", .{})) _ = try v.menuItem("Duplicate", .{}, .{});
                try v.end();
            },
            .popover => {
                if (try v.button("More", .{})) self.open = !self.open;
                if (try v.popover(&self.open, .{}, .{})) try v.text("Duplicate", .{});
                try v.end();
            },
            .context_menu => {
                _ = try v.button("More", .{});
                if (try v.popoverMenu(.{ .name = "Actions" })) _ = try v.menuItem("Duplicate", .{}, .{});
                try v.end();
            },
        }
        try v.tooltip("More actions");
        try v.end();
    }
};

test "a button's tip goes as its menu or popover opens and stays hidden while it shows and as it closes" {
    for ([_]TippedMenus.Kind{ .menu_button, .popover, .context_menu }) |kind| {
        var storage: Storage = .{};
        var app: TippedMenus = .{ .kind = kind };
        var h = Harness.init(&app, TippedMenus.build, storage.buffers(), .{ .options = .{ .tooltip_delay = 1 } });
        var dummy: u8 = 0;
        var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
        try h.attachInput(&context);
        try h.render();
        const more = try h.boundsOf(.{ .text = "More" });
        const x = more.x + more.width / 2;
        const y = more.y + more.height / 2;
        try h.hoverAt(x, y);
        try h.advance(std.time.ns_per_s);
        try testing.expectEqualStrings("More actions", h.tooltip().?);
        if (kind == .context_menu) {
            try testing.expect(try h.clickButtonAt(x, y, .secondary, .{}));
        } else try h.clickAt(x, y);
        try h.advance(16 * std.time.ns_per_ms);
        try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Duplicate" }));
        try testing.expect(h.tooltip() == null);
        // The pointer goes onto the menu, and back to the button.
        try h.hover(.{ .text = "Duplicate" });
        try h.advance(100 * std.time.ns_per_ms);
        try h.hoverAt(x + 2, y);
        try h.advance(std.time.ns_per_s);
        try testing.expect(h.tooltip() == null);
        // The menu closes, the pointer on the button.
        try testing.expect(try h.key(.{ .key = .escape }));
        app.open = false;
        try h.advance(std.time.ns_per_s);
        try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Duplicate" }));
        try testing.expect(h.tooltip() == null);
        // Once the pointer and the focus have left, the tip shows again.
        try h.focus(.{ .text = "First" });
        try h.leave();
        try h.advance(std.time.ns_per_s);
        try h.hoverAt(x, y);
        try h.advance(std.time.ns_per_s);
        try testing.expectEqualStrings("More actions", h.tooltip().?);
    }
}

test "the tip the focus brought to a menu button goes as the keys open its menu and stays hidden as it closes" {
    var storage: Storage = .{};
    var app: TippedMenus = .{ .kind = .menu_button };
    var h = Harness.init(&app, TippedMenus.build, storage.buffers(), .{ .options = .{ .tooltip_delay = 1 } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    for ([_]z.KeyCode{ .down, .enter, .space }) |opener| {
        try h.focus(.{ .text = "First" });
        try h.advance(std.time.ns_per_s);
        try h.focus(.{ .text = "More" });
        try h.advance(std.time.ns_per_s);
        try testing.expectEqualStrings("More actions", h.tooltip().?);
        try testing.expect(try h.key(.{ .key = opener }));
        try h.advance(16 * std.time.ns_per_ms);
        try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Duplicate" }));
        try testing.expect(h.tooltip() == null);
        try testing.expect(try h.key(.{ .key = .escape }));
        try h.advance(std.time.ns_per_s);
        try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Duplicate" }));
        try testing.expectEqualStrings("More", h.focused().?.text);
        try testing.expect(h.tooltip() == null);
    }
}

const Saver = struct {
    saves: usize = 0,
    saved_as: usize = 0,
    dirty: bool = true,
    enabled: bool = true,
    fn build(self: *Saver, v: *View) anyerror!void {
        try v.column(.{ .padding = .all(20), .gap = 8 });
        _ = try v.button("Before", .{});
        const save = try v.splitButton("Save", .{ .button_enabled = self.dirty }, .{ .enabled = self.enabled });
        if (save.shown) {
            if (try v.menuItem("Save As…", .{}, .{})) self.saved_as += 1;
            _ = try v.menuItem("Save a Copy…", .{}, .{});
        }
        try v.end();
        if (save.clicked) self.saves += 1;
        _ = try v.button("After", .{});
        try v.end();
    }
};

test "a split button joins a button to an arrow opening a menu of related actions" {
    var storage: Storage = .{};
    var app: Saver = .{};
    var h = Harness.init(&app, Saver.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    // The segments sit edge to edge, as high as a button.
    const button = try h.boundsOf(.{ .text = "Save" });
    const arrow = try h.boundsOf(.{ .name = "More options" });
    try testing.expectApproxEqAbs(button.x + button.width, arrow.x, 0.01);
    try testing.expectApproxEqAbs(button.height, arrow.height, 0.01);
    try testing.expectApproxEqAbs((try h.boundsOf(.{ .text = "Before" })).height, button.height, 0.01);
    // A click on the button does the action; one on the arrow opens the menu.
    try h.click(.{ .text = "Save" });
    try testing.expectEqual(@as(usize, 1), app.saves);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Save As…" }));
    try h.click(.{ .name = "More options" });
    try testing.expect((try h.find(.{ .name = "More options" })).checked);
    try h.click(.{ .text = "Save As…" });
    try testing.expectEqual(@as(usize, 1), app.saved_as);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Save As…" }));
    try testing.expectEqual(@as(usize, 1), app.saves);

    // One stop of Tab; Left and Right move between the segments.
    try h.focus(.{ .text = "Before" });
    try testing.expect(try h.key(.{ .key = .tab }));
    try h.render();
    try testing.expectEqualStrings("Save", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .right }));
    try h.render();
    try testing.expectEqualStrings("More options", h.focused().?.style.name);
    try testing.expect(try h.key(.{ .key = .left }));
    try h.render();
    try testing.expectEqualStrings("Save", h.focused().?.text);
    // Enter clicks the button; Alt+Down opens the menu from it.
    try testing.expect(try h.key(.{ .key = .enter }));
    try h.render();
    try testing.expectEqual(@as(usize, 2), app.saves);
    try testing.expect(try h.key(.{ .key = .down, .modifiers = .{ .alt = true } }));
    try h.render();
    try testing.expectEqualStrings("Save As…", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.render();
    try testing.expectEqualStrings("More options", h.focused().?.style.name);
    // Down on the arrow opens the menu too.
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expectEqualStrings("Save As…", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.render();

    // Without changes to save, the arrow still opens the menu.
    app.dirty = false;
    try h.render();
    try testing.expectError(error.Disabled, h.click(.{ .text = "Save" }));
    try h.click(.{ .name = "More options" });
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Save As…" }));
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.render();
    // Disabled whole, neither segment takes a click.
    app.enabled = false;
    try h.render();
    try testing.expectError(error.Disabled, h.click(.{ .name = "More options" }));
}

test "a split button's arrow is named in the view's language" {
    try testing.expectEqualStrings("More options", view.menu.moreOptions(""));
    try testing.expectEqualStrings("More options", view.menu.moreOptions("de-DE"));
    try testing.expectEqualStrings("その他のオプション", view.menu.moreOptions("ja-JP"));
    try testing.expectEqualStrings("更多选项", view.menu.moreOptions("zh-Hans-CN"));
    try testing.expectEqualStrings("更多选项", view.menu.moreOptions("zh"));
    try testing.expectEqualStrings("更多選項", view.menu.moreOptions("zh-Hant"));
    try testing.expectEqualStrings("更多選項", view.menu.moreOptions("zh-TW"));
}

test "a split button runs right to left with its arrow at its start" {
    var storage: Storage = .{};
    var app: Saver = .{};
    var h = Harness.init(&app, Saver.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.setDirection(.rtl);
    const button = try h.boundsOf(.{ .text = "Save" });
    const arrow = try h.boundsOf(.{ .name = "More options" });
    try testing.expectApproxEqAbs(arrow.x + arrow.width, button.x, 0.01);
    try h.focus(.{ .text = "Save" });
    // Left goes to the arrow, at the left.
    try testing.expect(try h.key(.{ .key = .left }));
    try h.render();
    try testing.expectEqualStrings("More options", h.focused().?.style.name);
    try testing.expect(try h.key(.{ .key = .right }));
    try h.render();
    try testing.expectEqualStrings("Save", h.focused().?.text);
}

/// A leaf standing in for a text editor, which a secondary press tells
/// where it is before its context menu opens.
const Secondary = struct {
    at: ?view.Point = null,
    chosen: usize = 0,
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 40, .height = 24 }, .preferred = .{ .width = 200, .height = 80 } };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn input(_: *anyopaque, _: u64, _: view.EmbedInput) bool {
        return false;
    }
    fn secondary(ptr: *anyopaque, _: u64, point: view.Point) bool {
        const self: *Secondary = @ptrCast(@alignCast(ptr));
        self.at = point;
        return true;
    }
    fn build(self: *Secondary, v: *View) anyerror!void {
        _ = try v.button("Before", .{});
        try v.embed(.{ .context = self, .measure = measure, .paint = paint, .input = input, .secondary_press = secondary, .focusable = true }, .{ .name = "Editor" });
        if (try v.popoverMenu(.{ .name = "Edit" })) {
            if (try v.menuItem("Select All", .{}, .{})) self.chosen += 1;
        }
        try v.end();
    }
};

test "a secondary press tells the leaf under it where, which takes the focus the menu gives back" {
    var storage: Storage = .{};
    var app: Secondary = .{};
    var h = Harness.init(&app, Secondary.build, storage.buffers(), .{});
    try h.render();
    try h.focus(.{ .text = "Before" });
    const area = try h.boundsOf(.{ .kind = .embed });
    try testing.expect(try h.clickButtonAt(area.x + 30, area.y + 12, .secondary, .{}));
    try testing.expectApproxEqAbs(@as(f32, 30), app.at.?.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 12), app.at.?.y, 0.01);
    try h.click(.{ .text = "Select All" });
    try testing.expectEqual(@as(usize, 1), app.chosen);
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
}

const Styled = struct {
    open: bool = false,
    panel: ?view.MenuPanel = .{ .background = 0x1e1e2e, .border = 0x45475a, .border_width = 1, .radius = 12, .padding = .all(10) },
    fn build(self: *Styled, v: *View) anyerror!void {
        if (try v.popoverMenuButtonWith("More", .{ .open = &self.open, .panel = self.panel }, .{})) {
            _ = try v.menuItem("Rename", .{}, .{});
            if (try v.submenu("Share", .{})) {
                _ = try v.menuItem("Copy link", .{}, .{});
            }
            try v.end();
        }
        try v.end();
    }
};

fn paintMenus(h: *Harness, context: *ui.Context) ![]const ui.commands.Command {
    context.command_buffer.reset();
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = context, .size = .{ .width = 640, .height = 480, .scale = 1 } };
    try h.view.paint(&frame);
    if (frame.failure) |err| return err;
    context.input_state.commitFrame();
    return context.command_buffer.commands();
}

fn filled(commands: []const ui.commands.Command, color: u32) usize {
    var count: usize = 0;
    for (commands) |command| if (command == .shape and command.shape.color.hex() == color) {
        count += 1;
    };
    return count;
}

/// The radius of the first shape in `color`.
fn radiusOf(commands: []const ui.commands.Command, color: u32) ?f32 {
    for (commands) |command| if (command == .shape and command.shape.color.hex() == color) return command.shape.radius;
    return null;
}

test "a menu button's panel, and its submenus', wear the look its options give" {
    var storage: Storage = .{};
    var app: Styled = .{};
    var h = Harness.init(&app, Styled.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    app.open = true;
    try h.render();
    try h.render();
    // The padding the panel gives keeps the items from its edge.
    const panel = try h.boundsOf(.{ .kind = .menu, .nth = 0 });
    const item = try h.boundsOf(.{ .text = "Rename" });
    try testing.expectApproxEqAbs(panel.x + 10, item.x, 0.01);
    try testing.expectApproxEqAbs(panel.y + 10, item.y, 0.01);
    var commands = try paintMenus(&h, &context);
    try testing.expectEqual(@as(usize, 1), filled(commands, 0x1e1e2e));
    try testing.expectEqual(@as(usize, 1), filled(commands, 0x45475a));
    try testing.expectEqual(@as(?f32, 12), radiusOf(commands, 0x45475a));
    try testing.expectEqual(@as(?f32, 11), radiusOf(commands, 0x1e1e2e));
    // The submenu that opens wears it too.
    try h.click(.{ .text = "Share" });
    try h.render();
    commands = try paintMenus(&h, &context);
    try testing.expectEqual(@as(usize, 2), filled(commands, 0x1e1e2e));
    // A border 0 wide draws none; without a panel the theme's look comes back.
    app.panel = .{ .background = 0x1e1e2e, .border_width = 0 };
    try h.render();
    commands = try paintMenus(&h, &context);
    try testing.expectEqual(@as(usize, 0), filled(commands, 0x45475a));
    try testing.expect(filled(commands, 0x1e1e2e) >= 1);
    app.panel = null;
    try h.render();
    commands = try paintMenus(&h, &context);
    try testing.expectEqual(@as(usize, 0), filled(commands, 0x1e1e2e));
    // A look that cannot be drawn is refused.
    app.panel = .{ .radius = -1 };
    try testing.expectError(error.InvalidValue, h.render());
}
