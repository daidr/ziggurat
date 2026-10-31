//! Headless tests of hidden nodes (`Style.hidden`) and of the wheel passing
//! between embedded leaves.
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

const Details = struct {
    show: bool = false,
    notes: bool = false,
    scroll: view.ScrollModel = .{},
    open: bool = true,
    fn build(self: *Details, v: *View) anyerror!void {
        try v.row(.{ .gap = 10 });
        _ = try v.button("First", .{});
        try v.column(.{ .hidden = !self.show, .gap = 4 });
        _ = try v.checkbox(&self.notes, "Notes", .{});
        try v.scroll(&self.scroll, .{ .height = 40 });
        for (0..6) |i| try v.textf("Line {d}", .{i}, .{ .key = i });
        try v.end();
        try v.end();
        _ = try v.button("Last", .{});
        try v.end();
        _ = try v.button("Anchor", .{ .hidden = !self.show });
        if (try v.popover(&self.open, .{}, .{ .name = "Panel" })) _ = try v.button("Inside", .{});
        try v.end();
    }
};

test "a hidden node takes no room and no gap, and draws and takes nothing" {
    var storage: Storage = .{};
    var app: Details = .{};
    var h = Harness.init(&app, Details.build, storage.buffers(), .{});
    try h.render();
    const first = try h.boundsOf(.{ .text = "First" });
    const last = try h.boundsOf(.{ .text = "Last" });
    // The siblings close up: one gap between them, none for the hidden column.
    try testing.expectApproxEqAbs(first.x + first.width + 10, last.x, 0.01);
    // Still built, but neither visible nor clickable.
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Notes" }));
    try testing.expect(h.visible(try h.find(.{ .text = "Notes" })) == null);
    try testing.expectError(error.Hidden, h.click(.{ .text = "Notes" }));
    // What floats from a hidden anchor hides with it, though it is open.
    try testing.expect(h.visible(try h.find(.{ .text = "Inside" })) == null);

    app.show = true;
    try h.render();
    const shown = try h.boundsOf(.{ .text = "Notes" });
    try testing.expect(shown.width > 0 and shown.height > 0);
    try testing.expect((try h.boundsOf(.{ .text = "Last" })).x > shown.x + shown.width);
    try h.click(.{ .text = "Notes" });
    try testing.expect(app.notes);
    try testing.expect(h.visible(try h.find(.{ .text = "Inside" })) != null);
}

test "what is inside a hidden node keeps its state, and focus leaves it" {
    var storage: Storage = .{};
    var app: Details = .{ .show = true, .open = false };
    var h = Harness.init(&app, Details.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 30 });
    const offset = app.scroll.offset.y;
    try testing.expect(offset > 0);
    try h.focus(.{ .text = "Notes" });
    try testing.expectEqualStrings("Notes", h.focused().?.text);

    app.show = false;
    try h.render();
    try h.render();
    // Its scroll offset is not clamped to a box it no longer has.
    try testing.expectEqual(offset, app.scroll.offset.y);
    try testing.expect(h.focused() == null);
    try testing.expectError(error.Hidden, h.scroll(.{ .kind = .scroll }, .{ .x = 0, .y = 10 }));

    app.show = true;
    try h.render();
    try testing.expectEqual(offset, app.scroll.offset.y);
}

const Hidden = struct {
    open: bool = true,
    fn build(self: *Hidden, v: *View) anyerror!void {
        _ = try v.button("Behind", .{});
        try v.column(.{ .hidden = true });
        if (try v.dialog(&self.open, .{}, .{ .name = "Hidden dialog" }) == .open) _ = try v.button("In dialog", .{});
        try v.end();
        try v.end();
    }
};

test "a hidden dialog leaves the window as it is" {
    var storage: Storage = .{};
    var app: Hidden = .{};
    var h = Harness.init(&app, Hidden.build, storage.buffers(), .{});
    try h.render();
    try testing.expect(!h.view.inert(try h.find(.{ .text = "Behind" })));
    try h.click(.{ .text = "Behind" });
}

/// A leaf that counts the wheel input it sees, taking it or not.
const Wheel = struct {
    takes: bool,
    seen: usize = 0,
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        const size: view.Size = .{ .width = 100, .height = 40 };
        return .{ .minimum = size, .preferred = size };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Wheel = @ptrCast(@alignCast(ptr));
        if (event != .wheel) return false;
        self.seen += 1;
        return self.takes;
    }
    fn embed(self: *Wheel) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .input = input };
    }
};

const Layers = struct {
    under: Wheel = .{ .takes = true },
    over: Wheel = .{ .takes = false },
    scroll: view.ScrollModel = .{},
    fn build(self: *Layers, v: *View) anyerror!void {
        try v.scroll(&self.scroll, .{ .height = 120 });
        // The first leaf overflows a short column, so the second lies over
        // its lower half.
        try v.column(.{ .height = 20, .shrink = 0 });
        try v.embed(self.under.embed(), .{});
        try v.end();
        try v.embed(self.over.embed(), .{});
        for (0..8) |i| try v.textf("Row {d}", .{i}, .{ .key = i });
        try v.end();
    }
};

test "the wheel a leaf leaves goes on to the leaves under it, then to scroll containers" {
    var storage: Storage = .{};
    var app: Layers = .{};
    var h = Harness.init(&app, Layers.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 300, .height = 200 } });
    try h.render();
    const over = try h.boundsOf(.{ .kind = .embed, .nth = 1 });
    try h.wheel(over.x + 10, over.y + 10, .{ .x = 0, .y = 30 });
    try testing.expectEqual(@as(usize, 1), app.over.seen);
    try testing.expectEqual(@as(usize, 1), app.under.seen);
    try testing.expectEqual(@as(f32, 0), app.scroll.offset.y);

    // Below the first leaf, the one leaving it lets the container scroll.
    try h.wheel(over.x + 10, over.y + over.height - 2, .{ .x = 0, .y = 30 });
    try testing.expectEqual(@as(usize, 2), app.over.seen);
    try testing.expectEqual(@as(usize, 1), app.under.seen);
    try testing.expect(app.scroll.offset.y > 0);
}

/// A focusable leaf standing in for a text field.
const Input = struct {
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 40, .height = 24 }, .preferred = .{ .width = 120, .height = 24 } };
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn embed(self: *Input) view.Embed {
        return .{ .context = self, .measure = measure, .paint = paint, .focusable = true };
    }
};

const SearchBox = struct {
    input: Input = .{},
    tokens: Input = .{},
    box: u64 = 0,
    focused: bool = false,
    autofocus: bool = false,
    fn build(self: *SearchBox, v: *View) anyerror!void {
        _ = try v.button("Before", .{});
        try v.search(.{ .name = "Find" });
        self.box = v.lastNode().id;
        try v.embed(self.input.embed(), .{ .grow = 1 });
        try v.end();
        self.focused = v.hasKeyboard(self.box);
        try v.tokenField(.{ .name = "To" });
        _ = try v.token("Ada", .{ .key = 1 });
        try v.embed(self.tokens.embed(), .{ .grow = 1 });
        try v.end();
        if (self.autofocus) {
            self.autofocus = false;
            v.restore = self.box;
        }
    }
};

test "focus given to a field's box goes to its input" {
    var storage: Storage = .{};
    var app: SearchBox = .{};
    var h = Harness.init(&app, SearchBox.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.focus(.{ .kind = .search });
    try testing.expectEqual(view.Kind.embed, h.focused().?.kind);
    try testing.expect(app.focused);
    try h.focus(.{ .kind = .token_field });
    try testing.expectEqual((try h.find(.{ .kind = .embed, .nth = 1 })).id, h.focused().?.id);
    try testing.expect(!app.focused);
    // A build asking to focus the box, as it opens, focuses the input.
    app.autofocus = true;
    try h.render();
    try h.render();
    try testing.expectEqual((try h.find(.{ .kind = .embed, .nth = 0 })).id, h.focused().?.id);
    try testing.expect(app.focused);
}
