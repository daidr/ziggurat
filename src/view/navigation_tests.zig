//! Headless tests of routers and history buttons, pictures and icons, and
//! right-to-left layout.
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

fn press(key: z.KeyCode) z.KeyInput {
    return .{ .key = key };
}
fn alt(key: z.KeyCode) z.KeyInput {
    return .{ .key = key, .modifiers = .{ .alt = true } };
}
fn focusedText(h: *const Harness) []const u8 {
    const node = h.focused() orelse return "";
    return node.text;
}

const NotesApp = struct {
    history: [8]view.RouteEntry = undefined,
    router: view.Router = undefined,
    went_back: usize = 0,
    page_id: u64 = 0,

    fn init(self: *NotesApp) !void {
        self.router = try view.Router.init(&self.history, "/notes");
    }
    fn build(self: *NotesApp, v: *View) anyerror!void {
        try v.toolbar(.{ .name = "Navigation", .gap = 4 });
        if (try v.backButton(&self.router, .{})) self.went_back += 1;
        _ = try v.forwardButton(&self.router, .{});
        try v.text(self.router.title(), .{ .key = 1 });
        try v.end();
        try v.row(.{ .gap = 8, .grow = 1 });
        try v.column(.{ .width = 120 });
        if (try v.button("All notes", .{})) try self.router.push("/notes");
        if (try v.button("Settings", .{})) try self.router.push("/settings");
        try v.end();
        const route = try v.route(&self.router, .{});
        defer self.page_id = v.buffers.nodes[route.node].id;
        if (route.match("/notes")) {
            route.title("Notes");
            if (try v.button("Open 42", .{})) try self.router.push("/notes/42");
            _ = try v.button("Other", .{});
        } else if (route.match("/notes/{id}")) {
            route.title("Note");
            try v.textf("Note {s}", .{route.param("id")}, .{});
            if (try v.button("Edit", .{})) try self.router.push("?mode=edit");
        } else if (route.match("/settings/{section...}")) {
            route.title("Settings");
            if (try v.button("Fonts", .{})) try self.router.push("/settings/fonts");
            try v.textf("Section {s}", .{route.param("section")}, .{});
        } else {
            try v.text("Not found", .{});
        }
        try v.end();
        try v.end();
    }
};

test "a router builds the page shown and moves through its history" {
    var storage: Storage = .{};
    var app: NotesApp = .{};
    try app.init();
    var h = Harness.init(&app, NotesApp.build, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);

    // At the start of the history both buttons are disabled.
    const back = try h.find(.{ .kind = .nav_button, .name = "Back" });
    try testing.expect(!back.style.enabled);
    try testing.expectError(error.Disabled, h.click(.{ .name = "Back" }));
    try testing.expectError(error.Disabled, h.click(.{ .name = "Forward" }));
    try testing.expectEqualStrings("Notes", (try h.find(.{ .kind = .route })).style.name);
    const notes_page = app.page_id;

    // A push from inside the page moves the focus into the new page.
    try h.click(.{ .text = "Open 42" });
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Note 42" }));
    try testing.expectEqualStrings("Edit", focusedText(&h));
    try testing.expect(app.page_id != notes_page);
    try testing.expect((try h.find(.{ .name = "Back" })).style.enabled);
    try testing.expectEqualStrings("Note", app.router.title());

    // A query keeps the page, its node identity and the focus.
    const note_page = app.page_id;
    try h.click(.{ .text = "Edit" });
    try testing.expectEqualStrings("/notes/42?mode=edit", app.router.location());
    try testing.expectEqual(note_page, app.page_id);
    try testing.expectEqualStrings("Edit", focusedText(&h));

    // Alt+Left goes back, and the focus returns where it was on that page.
    try testing.expect(try h.key(alt(.left)));
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expect(try h.key(alt(.left)));
    try testing.expectEqualStrings("/notes", app.router.location());
    try testing.expectEqual(notes_page, app.page_id);
    try testing.expectEqualStrings("Open 42", focusedText(&h));
    try testing.expect(try h.key(alt(.right)));
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expectEqualStrings("Edit", focusedText(&h));

    // The keyboard's Back key and a mouse's back button go back too;
    // Backspace does not.
    try testing.expect(!try h.key(press(.backspace)));
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expect(try h.mouseButton(.back));
    try testing.expectEqualStrings("/notes", app.router.location());
    try testing.expect(try h.key(press(.browser_forward)));
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expect(try h.mouseButton(.forward));
    try testing.expectEqualStrings("/notes/42?mode=edit", app.router.location());
    try testing.expect(!try h.mouseButton(.forward));

    // From outside the page, the focus stays and the title is announced.
    try h.click(.{ .text = "Settings" });
    try testing.expectEqualStrings("/settings", app.router.location());
    try testing.expectEqualStrings("Settings", focusedText(&h));
    try testing.expectEqualStrings("Settings", h.announcement().?);
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Section " }));

    // A layout keeps its node identity as the rest of its path changes.
    const layout = app.page_id;
    try h.click(.{ .text = "Fonts" });
    try testing.expectEqualStrings("/settings/fonts", app.router.location());
    try testing.expectEqual(layout, app.page_id);
    try testing.expectEqualStrings("Fonts", focusedText(&h));
    try testing.expectEqual(@as(usize, 1), h.count(.{ .text = "Section fonts" }));

    // The Back button goes back, and pushing forgets the pages after.
    try h.click(.{ .name = "Back" });
    try testing.expectEqual(@as(usize, 1), app.went_back);
    try testing.expectEqualStrings("/settings", app.router.location());
    try testing.expect(app.router.canGoForward());
    try h.click(.{ .text = "All notes" });
    try testing.expect(!app.router.canGoForward());
    try testing.expectEqualStrings("/settings", app.router.entryAt(-1).?.location());
    try testing.expectEqualStrings("Settings", app.router.entryAt(-1).?.title());
}

test "right to left, Alt+Right goes back and the history buttons swap their chevrons" {
    var storage: Storage = .{};
    var app: NotesApp = .{};
    try app.init();
    var h = Harness.init(&app, NotesApp.build, storage.buffers(), .{ .options = .{ .direction = .rtl } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.click(.{ .text = "Open 42" });
    try testing.expect(!try h.key(alt(.left)));
    try testing.expectEqualStrings("/notes/42", app.router.location());
    try testing.expect(try h.key(alt(.right)));
    try testing.expectEqualStrings("/notes", app.router.location());
    // The toolbar starts at the right: Back is right of Forward.
    const back = try h.find(.{ .name = "Back" });
    const forward = try h.find(.{ .name = "Forward" });
    try testing.expect(back.bounds.x > forward.bounds.x);
    try testing.expect(back.rtl);
}

const Painted = struct {
    icons: usize = 0,
    last_icon: ?view.Icon = null,
    last_mirrored: bool = false,
    last_bounds: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    svg_destination: ?view.Rect = null,
    fn paintIcon(ptr: *anyopaque, _: *ui.Frame, icon: view.Icon, bounds: view.Rect, _: ui.Color, mirrored: bool) anyerror!void {
        const self: *Painted = @ptrCast(@alignCast(ptr));
        self.icons += 1;
        self.last_icon = icon;
        self.last_mirrored = mirrored;
        self.last_bounds = bounds;
    }
    fn paintSvg(ptr: *anyopaque, _: *ui.Frame, destination: view.Rect, _: ui.Color) anyerror!void {
        const self: *Painted = @ptrCast(@alignCast(ptr));
        self.svg_destination = destination;
    }
};

const PictureApp = struct {
    painted: *Painted,
    fn build(self: *PictureApp, v: *View) anyerror!void {
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.icon(.search, .{}, .{});
        try v.icon(.chevron_right, .{ .name = "Next" }, .{});
        try v.text("Find", .{});
        try v.end();
        try v.svg(.{ .context = self.painted, .width = 40, .height = 20, .paint = Painted.paintSvg }, .{ .alt = "Logo", .fit = .contain }, .{ .width = 100, .height = 100 });
        try v.svg(.{ .context = self.painted, .width = 40, .height = 20, .paint = Painted.paintSvg }, .{ .fit = .cover, .decorative = true }, .{ .width = 30, .height = 30, .key = 9 });
    }
};

test "icons and SVG pictures lay out at their own size and paint through their painters" {
    var storage: Storage = .{};
    var painted: Painted = .{};
    var app: PictureApp = .{ .painted = &painted };
    const painter: view.IconPainter = .{ .context = &painted, .paint = Painted.paintIcon };
    var h = Harness.init(&app, PictureApp.build, storage.buffers(), .{ .options = .{ .icons = painter } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    const search = try h.find(.{ .kind = .icon, .text = "search" });
    try testing.expectEqual(@as(f32, 20), search.bounds.width);
    try testing.expectEqual(@as(f32, 20), search.bounds.height);
    try testing.expect(search.graphic.?.decorative);
    const next = try h.find(.{ .kind = .icon, .name = "Next" });
    try testing.expect(!next.graphic.?.decorative and !next.graphic.?.mirrored);
    try testing.expectEqual(@as(usize, 2), painted.icons);
    try testing.expectEqual(view.Icon.chevron_right, painted.last_icon.?);
    const logo = try h.find(.{ .kind = .svg, .name = "Logo" });
    try testing.expectEqual(@as(f32, 100), logo.bounds.width);
    // Covering keeps its proportions and crops the sides, centered; the
    // last SVG painted is the covering one.
    const cover = try h.find(.{ .kind = .svg, .key = 9 });
    const shown = painted.svg_destination.?;
    try testing.expectEqual(@as(f32, 60), shown.width);
    try testing.expectEqual(@as(f32, 30), shown.height);
    try testing.expectEqual(cover.bounds.x - 15, shown.x);
    var out: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try h.write(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "svg name=\"Logo\" contain") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "svg cover") != null);
}

test "a bitmap is its size in pixels unless styled, and fits as asked" {
    var pixels = [_]u8{0} ** (8 * 4 * 4);
    var lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const levels = [_]ui.drawing.ImageLevel{.{ .pixels = &pixels, .byte_len = pixels.len, .width = 8, .height = 4, .stride = 32 }};
    const picture: view.ImageView = .{ .lease = &lease, .identity = 1, .levels = &levels };
    const App = struct {
        picture: view.ImageView,
        fn build(self: *@This(), v: *View) anyerror!void {
            try v.image(self.picture, .{ .alt = "Map" }, .{});
            try v.image(self.picture, .{ .fit = .none }, .{ .width = 2, .height = 2 });
        }
    };
    var storage: Storage = .{};
    var app: App = .{ .picture = picture };
    var h = Harness.init(&app, App.build, storage.buffers(), .{});
    try h.render();
    const map = try h.find(.{ .kind = .image, .name = "Map" });
    try testing.expectEqual(@as(f32, 8), map.bounds.width);
    try testing.expectEqual(@as(f32, 4), map.bounds.height);
    try testing.expect(!map.graphic.?.decorative);
    const small = try h.find(.{ .kind = .image, .nth = 1 });
    try testing.expectEqual(@as(f32, 2), small.bounds.width);
    try testing.expect(small.graphic.?.decorative);
    try testing.expectEqual(view.Fit.none, small.graphic.?.fit);
}

const mirrored_tracks = [_]view.Track{ view.Track.fixed(50), view.Track.fixed(70) };
const Mirrored = struct {
    selected: u8 = 0,
    direction: view.Direction = .ltr,
    fn build(self: *Mirrored, v: *View) anyerror!void {
        try v.row(.{ .gap = 10, .padding = .{ .left = 4, .right = 20 }, .key = 1 });
        _ = try v.button("One", .{});
        _ = try v.button("Two", .{});
        try v.end();
        try v.text("Start", .{ .key = 2 });
        try v.row(.{ .gap = 10, .direction = .ltr, .key = 3 });
        _ = try v.button("Left", .{});
        _ = try v.button("Right", .{});
        try v.end();
        try v.tabs(.{ .name = "Views", .key = 4 });
        _ = try v.tab(u8, &self.selected, 0, "First", .{});
        _ = try v.tab(u8, &self.selected, 1, "Second", .{});
        _ = try v.tab(u8, &self.selected, 2, "Third", .{});
        try v.end();
        try v.grid(&mirrored_tracks, .{ .key = 5 });
        try v.text("A", .{});
        try v.text("B", .{});
        try v.end();
        try v.icon(.chevron_left, .{}, .{ .key = 6 });
        try v.icon(.check, .{}, .{ .key = 7 });
        try v.icon(.arrow_right, .{ .mirror = false }, .{ .key = 8 });
        self.direction = v.currentDirection();
    }
};

test "right to left mirrors rows, padding, alignment, grids and arrows" {
    var storage: Storage = .{};
    var app: Mirrored = .{};
    var h = Harness.init(&app, Mirrored.build, storage.buffers(), .{ .options = .{ .direction = view.Direction.of(@as(enum { ltr, rtl }, .rtl)) } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try testing.expectEqual(view.Direction.rtl, app.direction);
    const right_edge: f32 = 640 - 24;
    // The row's first child is at its right, inside the padding that was
    // on the left.
    const row = try h.find(.{ .kind = .row, .key = 1 });
    const one = try h.find(.{ .text = "One" });
    const two = try h.find(.{ .text = "Two" });
    try testing.expectEqual(row.bounds.x + row.bounds.width - 4, one.bounds.x + one.bounds.width);
    try testing.expectEqual(one.bounds.x - 10, two.bounds.x + two.bounds.width);
    // Start alignment in the root column is its right edge.
    const start = try h.find(.{ .text = "Start" });
    try testing.expectEqual(right_edge, start.bounds.x + start.bounds.width);
    try testing.expectEqual(right_edge, row.bounds.x + row.bounds.width);
    // A left-to-right row inside keeps its order, placed at the right.
    const left = try h.find(.{ .text = "Left" });
    const right = try h.find(.{ .text = "Right" });
    try testing.expect(left.bounds.x < right.bounds.x);
    try testing.expect(!left.rtl);
    // Grid columns run from the right.
    const a = try h.find(.{ .text = "A" });
    const b = try h.find(.{ .text = "B" });
    try testing.expect(a.bounds.x > b.bounds.x);
    // Directional icons mirror; others, and those told not to, do not.
    try testing.expect((try h.find(.{ .kind = .icon, .text = "chevron_left" })).graphic.?.mirrored);
    try testing.expect(!(try h.find(.{ .kind = .icon, .text = "check" })).graphic.?.mirrored);
    try testing.expect(!(try h.find(.{ .kind = .icon, .text = "arrow_right" })).graphic.?.mirrored);

    // Tabs start at the right, and Left moves to the next one.
    const first = try h.find(.{ .text = "First" });
    const second = try h.find(.{ .text = "Second" });
    try testing.expect(first.bounds.x > second.bounds.x);
    try h.focus(.{ .text = "First" });
    try testing.expect(try h.key(press(.left)));
    try testing.expectEqual(@as(u8, 1), app.selected);
    try testing.expectEqualStrings("Second", focusedText(&h));
    try testing.expect(try h.key(press(.right)));
    try testing.expectEqual(@as(u8, 0), app.selected);
    try testing.expect(try h.key(press(.right)));
    try testing.expectEqual(@as(u8, 2), app.selected);
    try testing.expectEqualStrings("Third", focusedText(&h));

    // Back to left to right, the same tree is unmirrored.
    try h.setDirection(.ltr);
    try testing.expect((try h.find(.{ .text = "One" })).bounds.x < (try h.find(.{ .text = "Two" })).bounds.x);
    try testing.expect(!(try h.find(.{ .kind = .icon, .text = "chevron_left" })).graphic.?.mirrored);
}

test "right to left, popups line up with the right edge of their anchor" {
    const App = struct {
        open: bool = true,
        fn build(self: *@This(), v: *View) anyerror!void {
            _ = try v.popupButton("Pick", self.open, .{ .width = 200 });
            if (try v.popover(&self.open, .{}, .{ .width = 80 })) try v.text("Inside", .{});
            try v.end();
        }
    };
    var storage: Storage = .{};
    var app: App = .{};
    var h = Harness.init(&app, App.build, storage.buffers(), .{ .options = .{ .direction = .rtl } });
    try h.render();
    const anchor = try h.find(.{ .kind = .popup_button });
    const panel = try h.find(.{ .kind = .popover });
    try testing.expectEqual(anchor.bounds.x + anchor.bounds.width, panel.bounds.x + panel.bounds.width);
}
