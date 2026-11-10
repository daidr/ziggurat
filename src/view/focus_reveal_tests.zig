//! Headless tests of the focus the build moves scrolling into view, and of
//! the functions nodes run as they go.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("root.zig");

const View = view.View;
const Harness = view.Harness;
const testing = std.testing;
const Storage = view.Storage(128, 8192);

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

/// Fifty rows 30 DIP high in a scroll view 200 DIP high; the build moves
/// the focus to row `target` in every pass that names one.
const Rows = struct {
    model: view.ScrollModel = .{},
    target: ?usize = null,
    leaf: ?usize = null,
    lined_up: bool = false,
    fn build(self: *Rows, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 200, .self_align = .stretch });
        try v.column(.{});
        for (0..50) |i| {
            var buffer: [16]u8 = undefined;
            _ = try v.button(try std.fmt.bufPrint(&buffer, "Row {d}", .{i}), .{ .key = i + 10, .height = 30 });
            if (self.target == i) {
                v.restore = v.lastNode().id;
                if (self.lined_up) v.scrollIntoViewWith(v.lastNode().id, .{ .block = .start });
            }
            if (self.leaf == i) v.focusLeaf(v.lastNode().id);
        }
        try v.end();
        try v.end();
    }
};

fn rowShows(h: *Harness, i: usize) !bool {
    const node = try h.find(.{ .key = i + 10 });
    const scroll = try h.find(.{ .kind = .scroll });
    return node.bounds.y >= scroll.bounds.y and node.bounds.y + node.bounds.height <= scroll.bounds.y + scroll.bounds.height;
}

test "the focus the build moves scrolls the node into view, as little as shows it" {
    var storage: Storage = .{};
    var app: Rows = .{};
    var h = Harness.init(&app, Rows.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try testing.expect(!try rowShows(&h, 40));
    app.target = 40;
    try h.render();
    try h.render();
    try testing.expectEqualStrings("Row 40", h.focused().?.text);
    try testing.expect(try rowShows(&h, 40));
    // As little as shows it: its bottom at the view's.
    const scroll = try h.find(.{ .kind = .scroll });
    const row = try h.find(.{ .key = 50 });
    try testing.expectApproxEqAbs(scroll.bounds.y + scroll.bounds.height, row.bounds.y + row.bounds.height, 0.5);

    // Asked again in every pass, it leaves the reader's scrolling alone.
    app.model.offset.y = 0;
    try h.render();
    try h.render();
    try testing.expect(!try rowShows(&h, 40));

    // Moved to another node, it scrolls again; a leaf the build focuses too.
    app.target = null;
    app.leaf = 45;
    try h.render();
    try h.render();
    try testing.expectEqualStrings("Row 45", h.focused().?.text);
    try testing.expect(try rowShows(&h, 45));
}

test "a pass that lines the node up otherwise keeps its own scroll" {
    var storage: Storage = .{};
    var app: Rows = .{ .lined_up = true };
    var h = Harness.init(&app, Rows.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    app.target = 30;
    try h.render();
    try h.render();
    const scroll = try h.find(.{ .kind = .scroll });
    const row = try h.find(.{ .key = 40 });
    try testing.expectApproxEqAbs(scroll.bounds.y, row.bounds.y, 0.5);
}

/// Rows whose press moves the focus to row 40, as a grip that focuses the
/// line it moves.
const Grip = struct {
    model: view.ScrollModel = .{},
    pressed: bool = false,
    fn build(self: *Grip, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .height = 200, .self_align = .stretch });
        try v.column(.{});
        const area = try v.pointerArea(.{}, .{ .name = "Grip", .height = 30 });
        try v.end();
        if (area.pressed_inside or area.pressed) self.pressed = true;
        for (0..50) |i| {
            var buffer: [16]u8 = undefined;
            _ = try v.button(try std.fmt.bufPrint(&buffer, "Row {d}", .{i}), .{ .key = i + 10, .height = 30 });
            if (self.pressed and i == 40) v.restore = v.lastNode().id;
        }
        try v.end();
        try v.end();
    }
};

test "the focus that follows a press keeps the scroll" {
    var storage: Storage = .{};
    var app: Grip = .{};
    var h = Harness.init(&app, Grip.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const grip = try h.boundsOf(.{ .name = "Grip" });
    try h.press(grip.x + 5, grip.y + 5, .{});
    try testing.expect(app.pressed);
    try testing.expectEqualStrings("Row 40", h.focused().?.text);
    try h.render();
    try testing.expectEqual(@as(f32, 0), app.model.offset.y);
    try h.release(grip.x + 5, grip.y + 5);
    try testing.expectEqual(@as(f32, 0), app.model.offset.y);
}

const Counter = struct {
    runs: usize = 0,
    last: u8 = 0,
    fn first(ptr: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ptr.?));
        self.runs += 1;
        self.last = 1;
    }
    fn second(ptr: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ptr.?));
        self.runs += 1;
        self.last = 2;
    }
};

const Feeds = struct {
    shown: bool = true,
    give: u8 = 1,
    take_away: bool = false,
    a: Counter = .{},
    b: Counter = .{},
    presence: view.Presence = .{},
    leaving: bool = false,
    fail: bool = false,
    fn build(self: *Feeds, v: *View) anyerror!void {
        if (self.shown) {
            try v.column(.{ .key = 1 });
            if (self.take_away) try v.onUnmount(null) else switch (self.give) {
                1 => try v.onUnmount(.{ .context = &self.a, .run = Counter.first }),
                2 => try v.onUnmount(.{ .context = &self.a, .run = Counter.second }),
                else => {},
            }
            try v.text("Feed", .{});
            try v.end();
        }
        const linear: view.Transition = .{ .enter = .{ .tween = .{ .duration_ns = 100 * std.time.ns_per_ms, .easing = .linear } }, .exit = .{ .tween = .{ .duration_ns = 100 * std.time.ns_per_ms, .easing = .linear } } };
        if (try v.presentColumn(&self.presence, !self.leaving, linear, .{ .key = 2 })) {
            try v.column(.{ .key = 3 });
            try v.onUnmount(.{ .context = &self.b, .run = Counter.first });
            try v.end();
            try v.end();
        }
        if (self.fail) return error.Failed;
    }
};

test "a node runs its function once, the last one given, as it goes" {
    var storage: Storage = .{};
    var app: Feeds = .{};
    var h = Harness.init(&app, Feeds.build, storage.buffers(), .{});
    try h.render();
    try h.render();
    try testing.expectEqual(@as(usize, 0), app.a.runs);
    // Each call replaces the function; a pass that gives none keeps it.
    app.give = 2;
    try h.render();
    app.give = 0;
    try h.render();
    // A frame that fails runs nothing.
    app.shown = false;
    app.fail = true;
    try testing.expectError(error.Failed, h.render());
    try testing.expectEqual(@as(usize, 0), app.a.runs);
    app.fail = false;
    try h.render();
    try testing.expectEqual(@as(usize, 1), app.a.runs);
    try testing.expectEqual(@as(u8, 2), app.a.last);
    try h.render();
    try testing.expectEqual(@as(usize, 1), app.a.runs);
    // Built again, it holds a function afresh; null takes it away unrun.
    app.shown = true;
    app.give = 1;
    try h.render();
    app.take_away = true;
    try h.render();
    app.shown = false;
    try h.render();
    try testing.expectEqual(@as(usize, 1), app.a.runs);

    // Content leaving runs it once its exit ended.
    try h.advance(200 * std.time.ns_per_ms);
    app.leaving = true;
    try h.render();
    try h.advance(50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 0), app.b.runs);
    try h.advance(60 * std.time.ns_per_ms);
    try h.render();
    try testing.expectEqual(@as(usize, 1), app.b.runs);

    // Closing the window runs those still built.
    app.leaving = false;
    app.shown = true;
    app.take_away = false;
    try h.advance(200 * std.time.ns_per_ms);
    try h.render();
    h.close();
    try testing.expectEqual(@as(usize, 2), app.a.runs);
    try testing.expectEqual(@as(usize, 2), app.b.runs);
    h.close();
    try testing.expectEqual(@as(usize, 2), app.a.runs);
}
