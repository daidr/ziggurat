//! Headless tests of pointer areas, pointer shapes, wrapping text, bounds
//! between frames and the application's key handler.
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
const Storage = view.Storage(64, 4096);

const AreaApp = struct {
    last: view.PointerArea = .{ .id = 0 },
    clicks: usize = 0,
    doubles: usize = 0,
    rights: usize = 0,
    middles: usize = 0,
    button_presses: usize = 0,
    presses: usize = 0,
    pressed_button: ?view.PointerButton = null,
    click_count: u8 = 0,
    modifiers: z.KeyModifiers = .{},
    track: bool = false,
    fn build(self: *AreaApp, v: *View) anyerror!void {
        const area = try v.pointerArea(.{ .track = self.track }, .{ .width = 200, .height = 100, .padding = view.Insets.all(10) });
        if (try v.button("Inside", .{})) self.button_presses += 1;
        try v.end();
        self.last = area;
        if (area.pressed_now) |button| {
            self.presses += 1;
            self.pressed_button = button;
        }
        if (area.clicked) {
            self.clicks += 1;
            self.click_count = area.clicks;
            self.modifiers = area.modifiers;
        }
        if (area.double_clicked) self.doubles += 1;
        if (area.right_clicked) self.rights += 1;
        if (area.middle_clicked) self.middles += 1;
    }
};

test "a pointer area reports clicks, double clicks, secondary and middle clicks" {
    var storage: Storage = .{};
    var app: AreaApp = .{};
    var h = Harness.init(&app, AreaApp.build, storage.buffers(), .{});
    try h.render();
    const bounds = (try h.find(.{ .kind = .pointer_area })).bounds;
    const x = bounds.x + bounds.width - 10;
    const y = bounds.y + bounds.height - 10;

    try h.press(x, y, .{ .shift = true });
    // While held over it, it is pressed.
    try testing.expect(app.last.pressed);
    try testing.expectEqual(view.PointerButton.primary, app.pressed_button.?);
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 1), app.clicks);
    try testing.expectEqual(@as(u8, 1), app.click_count);
    try testing.expect(app.modifiers.shift);
    try testing.expect(!app.last.pressed);

    // A second press soon after, near the first, is a double click.
    try h.press(x, y, .{});
    try testing.expectEqual(@as(usize, 1), app.doubles);
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 2), app.clicks);
    try testing.expectEqual(@as(u8, 2), app.click_count);

    // Later, it counts from one again.
    h.clock += view.double_press_time + 1;
    try h.press(x, y, .{});
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 1), app.doubles);
    try testing.expectEqual(@as(u8, 1), app.click_count);

    // A release away from the area is no click.
    try h.press(x, y, .{});
    try h.release(bounds.x + bounds.width + 50, y);
    try testing.expectEqual(@as(usize, 3), app.clicks);

    try testing.expect(try h.clickButtonAt(x, y, .secondary, .{}));
    try testing.expectEqual(@as(usize, 1), app.rights);
    try testing.expect(try h.clickButtonAt(x, y, .middle, .{}));
    try testing.expectEqual(@as(usize, 1), app.middles);
    try testing.expectEqual(view.PointerButton.middle, app.pressed_button.?);
    try testing.expectEqual(@as(usize, 3), app.clicks);

    // A lost press clicks nothing.
    try h.press(x, y, .{});
    try h.cancelPointer();
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 3), app.clicks);
}

test "a control inside a pointer area keeps its press" {
    var storage: Storage = .{};
    var app: AreaApp = .{};
    var h = Harness.init(&app, AreaApp.build, storage.buffers(), .{});
    try h.render();
    const button = h.visible(try h.find(.{ .text = "Inside" })).?;
    const x = button.x + button.width / 2;
    const y = button.y + button.height / 2;
    try h.press(x, y, .{});
    try h.release(x, y);
    try testing.expectEqual(@as(usize, 1), app.button_presses);
    try testing.expectEqual(@as(usize, 0), app.clicks);
    try testing.expect(!try h.clickButtonAt(x, y, .secondary, .{}));
    try testing.expectEqual(@as(usize, 0), app.rights);
}

test "a pointer area reports hover, and its pointer position when tracking" {
    var storage: Storage = .{};
    var app: AreaApp = .{ .track = true };
    var h = Harness.init(&app, AreaApp.build, storage.buffers(), .{});
    try h.render();
    // The first frame places the area; later passes know its bounds.
    try testing.expectEqual(@as(?view.Rect, null), app.last.bounds);
    try h.render();
    try testing.expect(!app.last.hovered);
    const bounds = app.last.bounds.?;
    try h.hoverAt(bounds.x + 150, bounds.y + 80);
    try testing.expect(app.last.hovered);
    try testing.expectEqual(@as(f32, 150), app.last.position.?.x);
    try testing.expectEqual(@as(f32, 80), app.last.position.?.y);
    try testing.expect(h.view.pointerMoved(.{ .x = bounds.x + 151, .y = bounds.y + 80 }));
    try h.leave();
    try testing.expect(!app.last.hovered);
    try testing.expectEqual(@as(?view.Point, null), app.last.position);
}

test "moving within an area repaints only when it tracks the pointer" {
    var storage: Storage = .{};
    var app: AreaApp = .{};
    var h = Harness.init(&app, AreaApp.build, storage.buffers(), .{});
    try h.render();
    try h.render();
    const bounds = app.last.bounds.?;
    try testing.expect(h.view.pointerMoved(.{ .x = bounds.x + 150, .y = bounds.y + 80 }));
    try testing.expect(!h.view.pointerMoved(.{ .x = bounds.x + 151, .y = bounds.y + 80 }));
    try testing.expect(h.view.pointerMoved(null));
}

const CursorApp = struct {
    fraction: f64 = 0.5,
    fn build(self: *CursorApp, v: *View) anyerror!void {
        try v.column(.{ .cursor = .grab, .width = 300, .height = 120, .key = 1 });
        _ = try v.button("Plain", .{});
        _ = try v.link("Docs", .{});
        try v.text("Label", .{ .cursor = .crosshair });
        try v.end();
        _ = try v.split(.row, &self.fraction, .{ .minimum = 0.1, .maximum = 0.9 }, .{ .width = 300, .height = 60 });
        try v.text("Left", .{});
        try v.text("Right", .{});
        try v.end();
    }
};

test "the pointer's shape comes from the innermost node that sets one" {
    var storage: Storage = .{};
    var app: CursorApp = .{};
    var h = Harness.init(&app, CursorApp.build, storage.buffers(), .{});
    try h.render();
    const box = (try h.find(.{ .key = 1 })).bounds;
    try h.hoverAt(box.x + box.width - 5, box.y + box.height - 5);
    try testing.expectEqual(view.Cursor.grab, h.cursor());
    const plain = (try h.find(.{ .text = "Plain" })).bounds;
    try h.hoverAt(plain.x + 2, plain.y + 2);
    try testing.expectEqual(view.Cursor.default, h.cursor());
    const docs = (try h.find(.{ .text = "Docs" })).bounds;
    try h.hoverAt(docs.x + 2, docs.y + 2);
    try testing.expectEqual(view.Cursor.pointer, h.cursor());
    const label = (try h.find(.{ .text = "Label" })).bounds;
    try h.hoverAt(label.x + 2, label.y + 2);
    try testing.expectEqual(view.Cursor.crosshair, h.cursor());
    const divider = h.view.divider(try h.find(.{ .kind = .split })).?;
    try h.hoverAt(divider.x + divider.width / 2, divider.y + divider.height / 2);
    try testing.expectEqual(view.Cursor.resize_ew, h.cursor());
    const left = (try h.find(.{ .text = "Left" })).bounds;
    try h.hoverAt(left.x + 1, left.y + 1);
    try testing.expectEqual(view.Cursor.default, h.cursor());
}

const WrapApp = struct {
    text: []const u8 = "one two three four five six seven eight",
    max_lines: u16 = 0,
    fn build(self: *WrapApp, v: *View) anyerror!void {
        try v.text(self.text, .{ .wrap = true, .max_lines = self.max_lines, .key = 1 });
        try v.text("after", .{ .key = 2 });
    }
};

test "a wrapping text takes the lines its width needs" {
    var storage: Storage = .{};
    var app: WrapApp = .{};
    // The estimate measures 9 DIP per character; 24 DIP padding each side.
    var h = Harness.init(&app, WrapApp.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 48 + 9 * 14, .height = 400 } });
    try h.render();
    const line = view.Measurer.line_height;
    const node = try h.find(.{ .key = 1 });
    try testing.expect(node.bounds.width <= 9 * 14);
    // "one two three" "four five six" "seven eight"
    try testing.expectEqual(3 * line, node.bounds.height);
    const after = try h.find(.{ .key = 2 });
    try testing.expect(after.bounds.y >= node.bounds.y + 3 * line);

    // Wide enough, it is one line.
    try h.resize(.{ .x = 0, .y = 0, .width = 1000, .height = 400 });
    try testing.expectEqual(line, (try h.find(.{ .key = 1 })).bounds.height);

    // A line limit caps the height.
    app.max_lines = 2;
    try h.resize(.{ .x = 0, .y = 0, .width = 48 + 9 * 14, .height = 400 });
    try testing.expectEqual(2 * line, (try h.find(.{ .key = 1 })).bounds.height);

    // Ideographs break anywhere.
    app.max_lines = 0;
    app.text = "一二三四五六七八九十";
    try h.resize(.{ .x = 0, .y = 0, .width = 48 + 16 * 4, .height = 400 });
    try testing.expectEqual(3 * line, (try h.find(.{ .key = 1 })).bounds.height);
}

const Lines = struct {
    labels: [8][64]u8 = undefined,
    lens: [8]usize = undefined,
    count: usize = 0,
    pub fn labelFont(self: *Lines, _: view.Rect, text: []const u8, _: u32, _: view.Font) void {
        @memcpy(self.labels[self.count][0..text.len], text);
        self.lens[self.count] = text.len;
        self.count += 1;
    }
    fn line(self: *const Lines, index: usize) []const u8 {
        return self.labels[index][0..self.lens[index]];
    }
};

test "the last line a limit shows ends in an ellipsis" {
    var storage: Storage = .{};
    var app: WrapApp = .{ .max_lines = 2 };
    var h = Harness.init(&app, WrapApp.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 48 + 9 * 14, .height = 400 } });
    try h.render();
    const node = try h.find(.{ .key = 1 });
    var lines: Lines = .{};
    const Wrapped = struct {
        fn paint(v: *const View, target: *Lines, n: *const view.Node) void {
            v.paintWrapped(target, n, n.bounds, 0);
        }
    };
    Wrapped.paint(&h.view, &lines, node);
    try testing.expectEqual(@as(usize, 2), lines.count);
    try testing.expectEqualStrings("one two three", lines.line(0));
    try testing.expect(std.mem.endsWith(u8, lines.line(1), "\u{2026}"));
    try testing.expect(std.mem.startsWith(u8, lines.line(1), "four"));
}

test "bounds of the last frame stay known between frames" {
    var storage: Storage = .{};
    var app: WrapApp = .{};
    var h = Harness.init(&app, WrapApp.build, storage.buffers(), .{});
    try h.render();
    const node = try h.find(.{ .key = 2 });
    const id = node.id;
    const bounds = node.bounds;
    // An event pass rebuilds the nodes without arranging them.
    try h.build.run(&h.view, h.config.options.root, null);
    try testing.expectEqual(bounds, h.view.boundsOf(id).?);
    try testing.expectEqual(bounds, try h.boundsOf(.{ .key = 2 }));
    try testing.expectEqual(@as(?view.Rect, null), h.view.boundsOf(12345));
}

const KeyApp = struct {
    pressed: [4]z.KeyCode = undefined,
    count: usize = 0,
    released: usize = 0,
    fn build(_: *KeyApp, v: *View) anyerror!void {
        _ = try v.button("One", .{});
        _ = try v.button("Two", .{});
    }
    fn key(ptr: *anyopaque, input: z.KeyInput) bool {
        const self: *KeyApp = @ptrCast(@alignCast(ptr));
        if (input.key != .a and input.key != .escape) return false;
        self.pressed[self.count] = input.key;
        self.count += 1;
        return true;
    }
    fn keyUp(ptr: *anyopaque, _: z.KeyInput) bool {
        const self: *KeyApp = @ptrCast(@alignCast(ptr));
        self.released += 1;
        return true;
    }
};

test "keys the view leaves alone reach the application, and so do releases" {
    var storage: Storage = .{};
    var app: KeyApp = .{};
    var h = Harness.init(&app, KeyApp.build, storage.buffers(), .{ .options = .{ .keys = .{ .context = &app, .key = KeyApp.key, .key_up = KeyApp.keyUp } } });
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    // Tab moves focus; the application never sees it.
    try testing.expect(try h.key(.{ .key = .tab }));
    try testing.expectEqual(@as(usize, 0), app.count);
    try testing.expectEqualStrings("One", h.focused().?.text);
    try testing.expect(try h.key(.{ .key = .a }));
    try testing.expect(try h.key(.{ .key = .escape }));
    try testing.expect(!try h.key(.{ .key = .b }));
    try testing.expectEqual(@as(usize, 2), app.count);
    try testing.expectEqual(z.KeyCode.a, app.pressed[0]);
    try testing.expect(try h.keyUp(.{ .key = .a }));
    try testing.expectEqual(@as(usize, 1), app.released);
}

test {
    _ = @import("wrap.zig");
}
