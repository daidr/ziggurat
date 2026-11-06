//! Headless tests of presses inside areas, cancelled presses, the button
//! of a press and drags let go over no target.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Harness = view.Harness;
const testing = std.testing;
const Storage = view.Storage(64, 4096);

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

const Cell = struct {
    outer: view.PointerArea = .{ .id = 0 },
    inner: view.PointerArea = .{ .id = 0 },
    inside_presses: usize = 0,
    inside_alt: usize = 0,
    outer_inside: usize = 0,
    button_presses: usize = 0,
    canceled: usize = 0,
    fn build(self: *Cell, v: *View) anyerror!void {
        const outer = try v.pointerArea(.{}, .{ .name = "Outer", .width = 300, .height = 120, .padding = view.Insets.all(10) });
        const inner = try v.pointerArea(.{}, .{ .width = 200, .height = 80, .padding = view.Insets.all(10) });
        if (try v.button("Choose", .{})) self.button_presses += 1;
        try v.end();
        try v.end();
        self.outer = outer;
        self.inner = inner;
        if (inner.pressed_inside) {
            self.inside_presses += 1;
            if (inner.modifiers.alt) self.inside_alt += 1;
        }
        if (outer.pressed_inside) self.outer_inside += 1;
        if (outer.press_canceled or inner.press_canceled) self.canceled += 1;
    }
};

test "an area learns of a press inside it that a control takes" {
    var storage: Storage = .{};
    var app: Cell = .{};
    var h = Harness.init(&app, Cell.build, storage.buffers(), .{});
    try h.render();
    const button = h.visible(try h.find(.{ .text = "Choose" })).?;
    const x = button.x + button.width / 2;
    const y = button.y + button.height / 2;
    try h.press(x, y, .{ .alt = true });
    // The button keeps the press; the areas around it still learn of it.
    try testing.expectEqual(@as(usize, 1), app.inside_presses);
    try testing.expectEqual(@as(usize, 1), app.inside_alt);
    try testing.expectEqual(@as(usize, 1), app.outer_inside);
    try testing.expect(!app.inner.pressed);
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 1), app.button_presses);
    // Once only, in the first pass after the press.
    try testing.expect(!app.inner.pressed_inside);
    try testing.expectEqual(@as(usize, 1), app.inside_presses);

    // A press outside the inner area is not inside it.
    const outer = (try h.find(.{ .name = "Outer" })).bounds;
    try h.press(outer.x + outer.width - 5, outer.y + outer.height - 5, .{});
    try testing.expectEqual(@as(usize, 2), app.outer_inside);
    try testing.expect(app.outer.pressed);
    try testing.expectEqual(@as(usize, 1), app.inside_presses);
    try h.release(outer.x + outer.width - 5, outer.y + outer.height - 5);
}

test "a cancelled press clicks nothing and says so; pressed follows the primary button" {
    var storage: Storage = .{};
    var app: Cell = .{};
    var h = Harness.init(&app, Cell.build, storage.buffers(), .{});
    try h.render();
    const outer = (try h.find(.{ .name = "Outer" })).bounds;
    const x = outer.x + outer.width - 5;
    const y = outer.y + outer.height - 5;
    try h.press(x, y, .{});
    try testing.expect(app.outer.pressed);
    try testing.expectEqual(view.PointerButton.primary, app.outer.pressed_button.?);
    try h.cancelPointer();
    try testing.expectEqual(@as(usize, 1), app.canceled);
    try testing.expect(!app.outer.pressed);
    try h.render();
    try testing.expect(!app.outer.press_canceled);
    try testing.expect(app.outer.pressed_button == null);
    // Nothing pressed: a cancel does nothing.
    try h.cancelPointer();
    try testing.expectEqual(@as(usize, 1), app.canceled);

    // A secondary press is no `pressed`, but tells its button.
    const point: view.Point = .{ .x = x, .y = y };
    _ = h.view.pointerMoved(point);
    const event = h.view.areaPress(point, .secondary, .{}, h.clock).?;
    try h.send(event);
    try testing.expect(!app.outer.pressed);
    try testing.expectEqual(view.PointerButton.secondary, app.outer.pressed_button.?);
    try h.render();
    try testing.expectEqual(view.PointerButton.secondary, app.outer.pressed_button.?);
    if (h.view.areaRelease(point, .secondary)) |up| try h.send(up);
    try testing.expect(app.outer.pressed_button == null);
}

const Tabs = struct {
    const tab_kind = 0x746162;
    missed: ?view.Point = null,
    rows_missed: ?view.DragMiss = null,
    dropped: usize = 0,
    fn build(self: *Tabs, v: *View) anyerror!void {
        try v.row(.{ .gap = 20 });
        const tab = try v.dragSourceState(.{ .kind = tab_kind, .value = 1 }, .{ .width = 80, .height = 30 });
        try v.text("Tab", .{});
        try v.end();
        if (tab.missed) |at| self.missed = at;
        switch (try v.dropTarget(.{ .kind = tab_kind }, .{ .width = 80, .height = 30 })) {
            .dropped => self.dropped += 1,
            else => {},
        }
        try v.text("Bar", .{});
        try v.end();
        try v.column(.{ .key = 9, .name = "Rows" });
        if (try v.dragRows(tab_kind)) |miss| self.rows_missed = miss;
        try v.text("Row", .{ .height = 30 });
        try v.end();
        try v.end();
    }
};

test "a drag let go over no target tells its source where" {
    var storage: Storage = .{};
    var app: Tabs = .{};
    var h = Harness.init(&app, Tabs.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const tab = (try h.find(.{ .text = "Tab" })).bounds;
    const bar = (try h.find(.{ .text = "Bar" })).bounds;
    // Dropped on a target: not missed.
    try h.drag(tab.x + 4, tab.y + 4, bar.x + 4, bar.y + 4, 3);
    try testing.expectEqual(@as(usize, 1), app.dropped);
    try testing.expect(app.missed == null);
    // Let go past the window's edge.
    try h.drag(tab.x + 4, tab.y + 4, -40, -30, 3);
    try testing.expectEqual(@as(f32, -40), app.missed.?.x);
    try testing.expectEqual(@as(f32, -30), app.missed.?.y);
    // Given up with Escape: not missed.
    app.missed = null;
    try h.press(tab.x + 4, tab.y + 4, .{});
    try h.moveTo(tab.x + 40, tab.y + 300);
    try testing.expect(try h.key(.{ .key = .escape }));
    try h.release(tab.x + 40, tab.y + 300);
    try testing.expect(app.missed == null);
    // A row dragged out of its container and let go over nothing.
    const row = (try h.find(.{ .text = "Row" })).bounds;
    try h.drag(row.x + 4, row.y + 4, row.x + 4, row.y + 400, 3);
    try testing.expectEqual(@as(u64, 0), app.rows_missed.?.payload.value);
    try testing.expectEqual(@as(f32, row.y + 400), app.rows_missed.?.position.y);
}

const Pad = struct {
    last: view.PointerArea = .{ .id = 0 },
    pens: usize = 0,
    fn build(self: *Pad, v: *View) anyerror!void {
        self.last = try v.pointerArea(.{}, .{ .width = 200, .height = 200 });
        try v.end();
        if (self.last.pointer) |sample| if (sample.device == .pen) {
            self.pens += 1;
        };
    }
};

test "an area tells what presses it and how hard" {
    var storage: Storage = .{};
    var app: Pad = .{};
    var h = Harness.init(&app, Pad.build, storage.buffers(), .{});
    try h.render();
    const pad = (try h.find(.{ .kind = .pointer_area })).bounds;
    try h.press(pad.x + 10, pad.y + 10, .{});
    try testing.expectEqual(z.PointerSample{ .device = .mouse, .pressure = 0.5 }, app.last.pointer.?);
    try h.release(pad.x + 10, pad.y + 10);
    try testing.expect(app.last.pointer == null);
    h.usePointer(.pen, 0.6);
    try h.press(pad.x + 10, pad.y + 10, .{});
    try testing.expectEqual(z.PointerSample{ .device = .pen, .pressure = 0.6 }, app.last.pointer.?);
    h.usePointer(.pen, 0.9);
    try h.moveTo(pad.x + 20, pad.y + 10);
    try h.render();
    try testing.expectEqual(@as(f32, 0.9), app.last.pointer.?.pressure);
    try h.release(pad.x + 20, pad.y + 10);
    try testing.expect(app.pens >= 2);
}

const Touch = struct {
    size: f32 = 0,
    hover_tip: bool = false,
    fn build(self: *Touch, v: *View) anyerror!void {
        const p = v.preferences;
        self.size = if (p.pointer == .coarse) 44 else 28;
        self.hover_tip = p.hover();
        _ = try v.button("x", .{ .width = self.size, .height = self.size, .name = "Delete" });
    }
};

test "a tester starts with the desktop's preferences, the pointer's among them" {
    var storage: Storage = .{};
    var app: Touch = .{};
    var h = Harness.init(&app, Touch.build, storage.buffers(), .{ .preferences = .{ .pointer = .coarse, .any_pointer = .coarse, .no_hover = true, .no_any_hover = true } });
    try h.render();
    try testing.expectEqual(@as(f32, 44), app.size);
    try testing.expect(!app.hover_tip);
    try h.setPreferences(.{});
    try testing.expectEqual(@as(f32, 28), app.size);
    try testing.expect(app.hover_tip);
}
