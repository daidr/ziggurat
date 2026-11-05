//! Headless tests of the checks `Harness.click`, `clickWith` and
//! `rightClick` make before sending any input: the target must show some of
//! itself in the window, and the center of what shows must reach it.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Harness = view.Harness;
const testing = std.testing;
const Storage = view.Storage(64, 4096);

const Fixture = enum { plain, below, clipped, partial, scrolled, ignored, inset, popover };

const Clicks = struct {
    fixture: Fixture = .plain,
    open: bool = true,
    target: usize = 0,
    cover: usize = 0,
    list: view.ScrollModel = .{},
    fn build(self: *Clicks, v: *View) anyerror!void {
        switch (self.fixture) {
            .plain => {
                if (try v.button("Target", .{ .width = 100, .height = 40 })) self.target += 1;
            },
            .below => {
                try v.spacer(.{ .height = 300 });
                if (try v.button("Target", .{ .width = 100, .height = 40 })) self.target += 1;
            },
            .clipped, .partial => {
                // A clip 40 high: the button below a 60 high block is cut
                // away, the one below a 20 high block shows its top half.
                try v.column(.{ .height = 40, .clip = true });
                try v.spacer(.{ .height = if (self.fixture == .clipped) 60 else 20 });
                if (try v.button("Target", .{ .width = 100, .height = 40 })) self.target += 1;
                try v.end();
            },
            .scrolled => {
                try v.scroll(&self.list, .{ .height = 40 });
                try v.spacer(.{ .height = 60 });
                if (try v.button("Target", .{ .width = 100, .height = 40 })) self.target += 1;
                try v.end();
            },
            .ignored => {
                if (try v.button("Target", .{ .width = 100, .height = 40, .ignore_input = true })) self.target += 1;
            },
            .inset => {
                // The inset cuts the whole box away.
                if (try v.button("Target", .{ .width = 100, .height = 40, .clip_inset = .{ .top = 20, .bottom = 20 } })) self.target += 1;
            },
            .popover => {
                if (try v.button("Anchor", .{ .width = 100, .height = 30 })) self.cover += 1;
                if (try v.popover(&self.open, .{ .gap = 0 }, .{})) {
                    try v.spacer(.{ .width = 200, .height = 120 });
                }
                try v.end();
                if (try v.button("Target", .{ .width = 100, .height = 40 })) self.target += 1;
            },
        }
    }
};

fn harness(app: *Clicks, storage: *Storage) !Harness {
    var h = Harness.init(app, Clicks.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 200, .height = 200 } });
    try h.render();
    return h;
}

test "a named click reaches a target the window shows, part of it too" {
    for ([_]Fixture{ .plain, .partial }) |fixture| {
        var storage: Storage = .{};
        var app: Clicks = .{ .fixture = fixture };
        var h = try harness(&app, &storage);
        try h.click(.{ .text = "Target" });
        try testing.expectEqual(@as(usize, 1), app.target);
    }
}

test "a named click on a target the window does not show, or that something covers, sends nothing" {
    const cases = [_]struct { fixture: Fixture, err: anyerror }{
        .{ .fixture = .below, .err = error.Hidden },
        .{ .fixture = .clipped, .err = error.Hidden },
        .{ .fixture = .scrolled, .err = error.Hidden },
        .{ .fixture = .inset, .err = error.Hidden },
        .{ .fixture = .ignored, .err = error.Covered },
        .{ .fixture = .popover, .err = error.Covered },
    };
    for (cases) |case| {
        var storage: Storage = .{};
        var app: Clicks = .{ .fixture = case.fixture };
        var h = try harness(&app, &storage);
        // `find` still finds it.
        _ = try h.find(.{ .text = "Target" });
        const frames = h.frames;
        const focus = h.focused();
        try testing.expectError(case.err, h.click(.{ .text = "Target" }));
        try testing.expectError(case.err, h.rightClick(.{ .text = "Target" }));
        try testing.expectEqual(@as(usize, 0), app.target);
        try testing.expectEqual(@as(usize, 0), app.cover);
        // Nothing was sent: no frame was rendered and the focus stayed.
        try testing.expectEqual(frames, h.frames);
        try testing.expectEqual(focus, h.focused());
    }
}

test "a covered target is refused, while clickAt presses where it is told" {
    var storage: Storage = .{};
    var app: Clicks = .{ .fixture = .popover };
    var h = try harness(&app, &storage);
    const target = try h.boundsOf(.{ .text = "Target" });
    try testing.expectError(error.Covered, h.click(.{ .text = "Target" }));
    try testing.expectEqual(@as(usize, 0), app.target);
    // A press at a point is sent wherever it lands.
    try h.clickAt(target.x + target.width / 2, target.y + target.height / 2);
    try testing.expectEqual(@as(usize, 1), app.target);
    // Once the popover closes the target is clicked.
    app.open = false;
    try h.render();
    try h.click(.{ .text = "Target" });
    try testing.expectEqual(@as(usize, 2), app.target);
}

const Menus = struct {
    inner: usize = 0,
    outer: usize = 0,
    fn build(self: *Menus, v: *View) anyerror!void {
        try v.column(.{ .name = "Outer", .height = 100, .width = 160 });
        try v.column(.{ .name = "Inner", .grow = 1, .self_align = .stretch });
        try v.text("Inside", .{});
        try v.end();
        if (try v.popoverMenu(.{ .name = "Inner menu" })) {
            if (try v.menuItem("Inner action", .{}, .{})) self.inner += 1;
        }
        try v.end();
        try v.end();
        if (try v.popoverMenu(.{ .name = "Outer menu" })) {
            if (try v.menuItem("Outer action", .{}, .{})) self.outer += 1;
        }
        try v.end();
        try v.text("Elsewhere", .{});
    }
};

test "a named secondary click opens the target's own menu, or none other" {
    var storage: Storage = .{};
    var app: Menus = .{};
    var h = Harness.init(&app, Menus.build, storage.buffers(), .{});
    try h.render();
    // The text's nearest menu is the inner one, which the press opens.
    try testing.expect(try h.rightClick(.{ .text = "Inside" }));
    try h.click(.{ .text = "Inner action" });
    try testing.expectEqual(@as(usize, 1), app.inner);
    // The outer group's center lies in the inner group, whose menu would open.
    try testing.expectError(error.Covered, h.rightClick(.{ .name = "Outer" }));
    try testing.expectEqual(@as(usize, 0), h.count(.{ .text = "Outer action" }));
    // No menu here or around: the click goes, and nothing takes it.
    try testing.expect(!try h.rightClick(.{ .text = "Elsewhere" }));
}
