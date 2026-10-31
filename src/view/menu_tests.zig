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
            if (try v.menuItem("Export", .{}, .{})) self.exported = true;
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
