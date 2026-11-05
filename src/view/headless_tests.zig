//! Headless tests of controls without a look (menus, accordion headers and
//! checkboxes the application draws), of `Style.access_hidden`, of the
//! wheel passing under a tooltip and of `presentColumn`'s ways in and out.
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

const Accounts = struct {
    open: bool = false,
    user: usize = 0,
    profile: usize = 0,
    highlighted: ?usize = null,
    labels: [3]bool = .{ false, false, false },
    fn build(self: *Accounts, v: *View) anyerror!void {
        try v.menuButtonBase(.{ .key = 1, .gap = 6, .padding = .all(4), .radius = 99 });
        try v.text("Account", .{});
        try v.end();
        if (try v.popoverMenuBase(.{ .padding = .all(4), .radius = 10, .background = 0xffffff })) {
            self.highlighted = null;
            for ([_][]const u8{ "Ada", "Grace", "Linus" }, 0..) |name, i| {
                const item = try v.menuItemBase(.{ .checked = self.user == i, .radio = true }, .{ .key = 10 + i, .gap = 8, .background = if (self.highlighted == i) 0xeeeeee else null });
                try v.text(name, .{});
                try v.end();
                if (item.highlighted) self.highlighted = i;
                if (item.clicked) self.user = i;
            }
            _ = try v.submenuItemBase(.{ .key = 20 });
            try v.text("Settings", .{});
            try v.end();
            if (try v.submenuBase(.{ .padding = .all(4) })) {
                const item = try v.menuItemBase(.{}, .{ .key = 21 });
                try v.text("Profile", .{});
                try v.end();
                if (item.clicked) self.profile += 1;
            }
            try v.end();
        }
        try v.end();
        try v.column(.{ .key = 2, .height = 60, .self_align = .stretch });
        try v.text("Note", .{});
        try v.end();
        if (try v.popoverMenuBase(.{ .name = "Labels" })) {
            for ([_][]const u8{ "Red", "Green", "Blue" }, 0..) |name, i| {
                const item = try v.menuItemBase(.{ .checked = self.labels[i] }, .{ .key = 30 + i });
                try v.text(name, .{});
                try v.end();
                if (item.clicked) self.labels[i] = !self.labels[i];
            }
        }
        try v.end();
    }
};

test "a menu without a look opens from its button, takes the keys and chooses" {
    var storage: Storage = .{};
    var app: Accounts = .{};
    var h = Harness.init(&app, Accounts.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    const button = try h.find(.{ .key = 1 });
    try testing.expect(button.plain and button.isContainer());
    try testing.expectEqual(@as(u32, 1), button.child_count);
    try testing.expect(!button.checked);
    // A press on the button opens the menu on its first item.
    try h.click(.{ .key = 1 });
    try h.render();
    try testing.expect((try h.find(.{ .key = 1 })).checked);
    const first = try h.find(.{ .key = 10 });
    try testing.expect(first.highlighted);
    try testing.expectEqual(first.id, h.focused().?.id);
    try testing.expectEqual(@as(?usize, 0), app.highlighted);
    // The panel is what its style draws: no padding or width of its own.
    const panel = try h.find(.{ .kind = .menu, .nth = 0 });
    try testing.expect(panel.plain);
    try testing.expectApproxEqAbs(panel.measured.preferred.width, panel.bounds.width, 1e-3);
    // Keys move the highlight; a letter moves to the item it starts.
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 11 })).id, h.focused().?.id);
    try testing.expect(try h.key(.{ .key = .l }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 12 })).id, h.focused().?.id);
    try testing.expectEqual(@as(?usize, 2), app.highlighted);
    try testing.expect(try h.key(.{ .key = .enter }));
    try h.render();
    try testing.expectEqual(@as(usize, 2), app.user);
    // The menu closed and the focus went back to the button.
    try testing.expectEqual(@as(usize, 0), h.count(.{ .key = 10 }));
    try testing.expectEqual((try h.find(.{ .key = 1 })).id, h.focused().?.id);

    // Down on the button opens it again; Right opens the submenu.
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expect(try h.key(.{ .key = .end }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 20 })).id, h.focused().?.id);
    try testing.expect(try h.key(.{ .key = .right }));
    try h.render();
    try testing.expect((try h.find(.{ .key = 20 })).expanded.?);
    try testing.expectEqual((try h.find(.{ .key = 21 })).id, h.focused().?.id);
    const submenu = try h.find(.{ .kind = .menu, .nth = 1 });
    try testing.expectEqualStrings("Settings", submenu.style.name);
    try testing.expect(try h.key(.{ .key = .enter }));
    try h.render();
    try testing.expectEqual(@as(usize, 1), app.profile);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .key = 21 }));
}

test "a context menu without a look opens at a secondary press" {
    var storage: Storage = .{};
    var app: Accounts = .{};
    var h = Harness.init(&app, Accounts.build, storage.buffers(), .{});
    try h.render();
    const note = try h.boundsOf(.{ .key = 2 });
    try testing.expect(try h.clickButtonAt(note.x + 10, note.y + 10, .secondary, .{}));
    try h.click(.{ .key = 31 });
    try testing.expect(app.labels[1]);
    try testing.expectEqual(@as(usize, 0), h.count(.{ .key = 31 }));
}

test "a plain control is named by the text inside it that assistive technology sees" {
    var storage: Storage = .{};
    const Named = struct {
        fn build(_: *@This(), v: *View) anyerror!void {
            var on = false;
            _ = try v.checkboxBase(&on, .{ .key = 1 });
            try v.text("Send", .{});
            try v.text("copy", .{ .access_hidden = true });
            try v.text("receipts", .{});
            try v.end();
        }
    };
    var app: Named = .{};
    var h = Harness.init(&app, Named.build, storage.buffers(), .{});
    try h.render();
    var buffer: [view.max_plain_name]u8 = undefined;
    try testing.expectEqualStrings("Send receipts", h.view.plainName(try h.find(.{ .key = 1 }), &buffer));
}

const Selection = struct {
    rows: [3]bool = .{ true, false, false },
    alone: bool = false,
    fn build(self: *Selection, v: *View) anyerror!void {
        var all = view.CheckState.of(&self.rows);
        if (try v.checkboxStateBase(&all, .{ .key = 1, .gap = 6 })) {
            for (&self.rows) |*row| row.* = all == .checked;
        }
        try v.text("Select all", .{});
        try v.end();
        _ = try v.checkboxBase(&self.alone, .{ .key = 2 });
        try v.text("Alone", .{});
        try v.end();
    }
};

test "a mixed checkbox without a look checks as it is pressed" {
    var storage: Storage = .{};
    var app: Selection = .{};
    var h = Harness.init(&app, Selection.build, storage.buffers(), .{});
    try h.render();
    const all = try h.find(.{ .key = 1 });
    try testing.expect(all.mixed and !all.checked);
    try h.click(.{ .key = 1 });
    try testing.expectEqualSlices(bool, &.{ true, true, true }, &app.rows);
    try testing.expect((try h.find(.{ .key = 1 })).checked);
    try h.click(.{ .key = 1 });
    try testing.expectEqualSlices(bool, &.{ false, false, false }, &app.rows);
    try h.click(.{ .key = 2 });
    try testing.expect(app.alone);
}

const Sections = struct {
    open: [3]bool = .{ false, true, false },
    choice: ?u8 = null,
    fn build(self: *Sections, v: *View) anyerror!void {
        try v.accordion(.{ .clip = true });
        for (&self.open, 0..) |*open, i| {
            _ = try v.accordionItem(open, .{ .key = 10 + i, .focus_ring_offset = -4 });
            try v.textf("Section {d}", .{i}, .{});
            try v.end();
            if (open.*) try v.textf("Body {d}", .{i}, .{ .key = 20 + i });
        }
        _ = try v.section(u8, &self.choice, 7, "Styled", .{});
        try v.end();
    }
};

test "accordion headers without a look toggle and pass the focus with the arrows" {
    var storage: Storage = .{};
    var app: Sections = .{};
    var h = Harness.init(&app, Sections.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try testing.expectEqual(@as(usize, 1), h.count(.{ .key = 21 }));
    try h.click(.{ .key = 10 });
    try testing.expect(app.open[0] and app.open[1]);
    try testing.expectEqual((try h.find(.{ .key = 10 })).id, h.focused().?.id);
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 11 })).id, h.focused().?.id);
    try testing.expect(try h.key(.{ .key = .end }));
    try h.render();
    try testing.expectEqualStrings("Styled", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .down }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 10 })).id, h.focused().?.id);
    try testing.expect(try h.key(.{ .key = .up }));
    try h.render();
    try testing.expectEqualStrings("Styled", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .home }));
    try h.render();
    try testing.expectEqual((try h.find(.{ .key = 10 })).id, h.focused().?.id);
    // Space closes the focused section.
    try testing.expect(try h.key(.{ .key = .space }));
    try h.render();
    try testing.expect(!app.open[0]);
    try testing.expectEqual(@as(f32, -4), (try h.find(.{ .key = 10 })).style.focus_ring_offset.?);
}

const Stack = struct {
    fn build(_: *Stack, v: *View) anyerror!void {
        try v.column(.{ .key = 1, .access_hidden = true });
        _ = try v.button("Behind", .{});
        _ = try v.button("Anchor", .{});
        var open = true;
        if (try v.popover(&open, .{}, .{ .key = 3 })) try v.text("Tip", .{});
        try v.end();
        try v.end();
        _ = try v.button("Front", .{ .key = 2 });
    }
};

test "access_hidden reaches what is inside and what floats from it, and leaves input alone" {
    var storage: Storage = .{};
    var app: Stack = .{};
    var h = Harness.init(&app, Stack.build, storage.buffers(), .{});
    try h.render();
    try testing.expect((try h.find(.{ .text = "Behind" })).access_hidden);
    try testing.expect((try h.find(.{ .key = 3 })).access_hidden);
    try testing.expect((try h.find(.{ .text = "Tip" })).access_hidden);
    try testing.expect(!(try h.find(.{ .key = 2 })).access_hidden);
    // The pointer and the keys still reach it.
    try h.click(.{ .text = "Behind" });
}

const TipOverList = struct {
    model: view.ScrollModel = .{},
    fn build(self: *TipOverList, v: *View) anyerror!void {
        try v.scroll(&self.model, .{ .key = 1, .height = 200, .self_align = .stretch });
        try v.column(.{ .gap = 4 });
        _ = try v.button("Hint", .{});
        try v.tooltip("A long hint over the lines below");
        for (0..40) |i| try v.textf("Line {d}", .{i}, .{ .key = 100 + i });
        try v.end();
        try v.end();
    }
};

test "the wheel over a tooltip scrolls what lies under it" {
    var storage: Storage = .{};
    var app: TipOverList = .{};
    var h = Harness.init(&app, TipOverList.build, storage.buffers(), .{ .options = .{ .tooltip_delay = 1 } });
    try h.render();
    try h.hover(.{ .text = "Hint" });
    try h.advance(std.time.ns_per_s);
    try testing.expect(h.tooltip() != null);
    const tip = h.view.tip_rect;
    const id = h.view.scrollAt(.{ .x = tip.x + tip.width / 2, .y = tip.y + tip.height / 2 });
    try testing.expectEqual((try h.find(.{ .key = 1 })).id, id.?);
}

const Pages = struct {
    step: u8 = 0,
    back: bool = false,
    presences: [3]view.Presence = .{ .{}, .{}, .{} },
    one_at_a_time: bool = false,
    fn build(self: *Pages, v: *View) anyerror!void {
        const way: f32 = if (self.back) -1 else 1;
        try v.column(.{ .key = 9, .child_exit = .{ .pose = .{ .x_percent = -50 * way }, .blur = 2 } });
        for (&self.presences, 0..) |*presence, i| {
            const transition: view.Transition = .{
                .hidden = .{ .x_percent = 50 * way },
                .hidden_blur = 4,
                .exit_to = .{ .pose = .{ .x = -40 * way } },
                .enter = .{ .tween = .{ .duration_ns = 100, .easing = .linear } },
                .exit = .{ .tween = .{ .duration_ns = 100, .easing = .linear } },
                .after_exits = self.one_at_a_time,
            };
            if (try v.presentColumn(presence, self.step == i, transition, .{ .key = i, .width = 200, .height = 100 })) {
                _ = try v.button("Next", .{ .key = 50 + i });
                try v.end();
            }
        }
        try v.end();
    }
};

fn pageNode(h: *const Harness, key: u64) ?*const view.Node {
    for (h.nodes()) |*node| if (node.kind == .column and node.style.key != null and node.style.key.? == key and node.parent != 0) return node;
    return null;
}

test "content leaves the way its container says as it goes, and that way stays" {
    var storage: Storage = .{};
    var app: Pages = .{};
    var h = Harness.init(&app, Pages.build, storage.buffers(), .{});
    try h.render();
    // It comes in from half its own width, blurred.
    var page = pageNode(&h, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 50), page.style.pose.?.x_percent, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4), page.style.blur, 1e-4);
    try h.advance(50);
    page = pageNode(&h, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 25), page.style.pose.?.x_percent, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2), page.style.blur, 1e-3);
    try h.advance(100);
    try testing.expect(pageNode(&h, 0).?.style.pose == null);
    // Stepping back: the page leaves as the container says in that build.
    app.back = true;
    app.step = 1;
    try h.render();
    try h.advance(50);
    page = pageNode(&h, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 25), page.style.pose.?.x_percent, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), page.style.pose.?.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1), page.style.blur, 1e-3);
    // While it goes it ignores input and assistive technology.
    try testing.expect(page.passthrough and page.access_hidden);
    // A later build turning the other way does not turn a page on its way.
    app.back = false;
    try h.advance(25);
    page = pageNode(&h, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 37.5), page.style.pose.?.x_percent, 1e-3);
    try h.advance(100);
    try testing.expect(pageNode(&h, 0) == null);
}

test "content appearing after exits waits unseen until they are gone" {
    var storage: Storage = .{};
    var app: Pages = .{ .one_at_a_time = true };
    var h = Harness.init(&app, Pages.build, storage.buffers(), .{});
    try h.render();
    // Its first build waits a frame, unseen in its place.
    try testing.expect(pageNode(&h, 0).?.unseen);
    try h.advance(view.loading_frame_interval);
    try testing.expect(!pageNode(&h, 0).?.unseen);
    try h.advance(200);
    app.step = 1;
    try h.render();
    try testing.expect(pageNode(&h, 1).?.unseen);
    try testing.expect(!pageNode(&h, 0).?.unseen);
    try h.advance(60);
    try testing.expect(pageNode(&h, 1).?.unseen);
    try testing.expect(h.deadline() != null);
    // Once the page before is gone the next comes in.
    try h.advance(60);
    try testing.expect(pageNode(&h, 0) == null);
    try h.advance(view.loading_frame_interval);
    const next = pageNode(&h, 1).?;
    try testing.expect(!next.unseen);
    // From where it is hidden, not where it last went.
    try testing.expectApproxEqAbs(@as(f32, 50), next.style.pose.?.x_percent, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), next.style.pose.?.x, 1e-4);
    // Taken out while it waited, it leaves nothing behind.
    app.step = 2;
    try h.render();
    try testing.expect(pageNode(&h, 2).?.unseen);
    app.step = 0;
    try h.render();
    try h.advance(view.loading_frame_interval);
    try testing.expect(pageNode(&h, 2) == null);
}

test "colors mix in Oklab for shared elements that ask" {
    const yellow: u32 = 0xffff00;
    const blue: u32 = 0x0000ff;
    const lab = view.matched.Look.mixIn(.{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .background = yellow }, .{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .background = blue }, 0.5, true);
    try testing.expectEqual(view.matched.mixRgbOklab(yellow, blue, 0.5), lab.background.?);
    try testing.expect(lab.background.? != view.matched.mixRgb(yellow, blue, 0.5));
}

const Ticker = struct {
    ask: bool = true,
    builds: usize = 0,
    hidden: bool = false,
    fn build(self: *Ticker, v: *View) anyerror!void {
        self.builds += 1;
        if (self.ask) self.hidden = v.windowHidden();
        try v.text(if (self.hidden) "paused" else "ticking", .{});
    }
};

test "a view that asks whether the window is hidden builds again as it hides and shows" {
    var storage: Storage = .{};
    var app: Ticker = .{};
    var h = Harness.init(&app, Ticker.build, storage.buffers(), .{});
    try h.render();
    try testing.expect(!app.hidden);
    const before = app.builds;
    try h.windowHidden(true);
    try testing.expect(app.hidden);
    try testing.expectEqual(before + 1, app.builds);
    // The same state again builds nothing.
    try h.windowHidden(true);
    try testing.expectEqual(before + 1, app.builds);
    try h.windowHidden(false);
    try testing.expect(!app.hidden);
    try testing.expectEqual(before + 2, app.builds);

    // A view that never asked builds nothing as the window hides.
    var quiet_storage: Storage = .{};
    var quiet: Ticker = .{ .ask = false };
    var q = Harness.init(&quiet, Ticker.build, quiet_storage.buffers(), .{});
    try q.render();
    const quiet_builds = quiet.builds;
    try q.windowHidden(true);
    try testing.expectEqual(quiet_builds, quiet.builds);
}
