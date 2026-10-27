//! Flyouts from a small window of native UI: a list of colors, a note to
//! edit and an About box. They take the keyboard, and close as the user
//! clicks elsewhere or presses Escape. They extend beyond the window, and
//! flip or slide to stay on the screen.
//!
//! Each flyout is a `system.Flyout` with a `view.Host` of its own, opened
//! beside the button that asked for it. The buttons' edges come from two
//! zero-size leaves around each button, whose `place` learns where the
//! layout put them.
//!
//! Run it with `zig build run-flyout`.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const text = @import("ziggurat_view_text");

const Color = struct { name: []const u8, rgb: u32 };
const colors = [_]Color{
    .{ .name = "Red", .rgb = 0xff3b30 },
    .{ .name = "Orange", .rgb = 0xff9500 },
    .{ .name = "Yellow", .rgb = 0xffcc00 },
    .{ .name = "Green", .rgb = 0x34c759 },
    .{ .name = "Blue", .rgb = 0x007aff },
    .{ .name = "Purple", .rgb = 0xaf52de },
};
const row_height = 28;
const muted: u32 = 0x5f6b7a;

const key_down = 1;
const key_up = 2;
const key_enter = 3;

/// A zero-size leaf that remembers where the layout placed it: on both
/// sides of a control in a row without gaps, two of them give the
/// control's edges.
const Marker = struct {
    rect: view.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    fn measure(_: *anyopaque, _: ui.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 0, .height = 0 }, .preferred = .{ .width = 0, .height = 0 } };
    }
    fn place(ptr: *anyopaque, _: u64, rect: view.Rect) void {
        const self: *Marker = @ptrCast(@alignCast(ptr));
        self.rect = rect;
    }
    fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: view.Rect) anyerror!void {}
    fn embed(self: *Marker) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint };
    }
};

/// A button between two markers, in a row of its own.
const Anchored = struct {
    start: Marker = .{},
    end: Marker = .{},

    fn button(self: *Anchored, v: *view.View, label: []const u8, key: u64) !bool {
        try v.row(.{ .key = key, .alignment = .stretch });
        try v.embed(self.start.embed(), .{});
        const clicked = try v.button(label, .{});
        try v.embed(self.end.embed(), .{});
        try v.end();
        return clicked;
    }
    /// The button's box in the window, once a frame placed it.
    fn rect(self: *const Anchored) z.Rect {
        const r = self.start.rect;
        return .{ .x = r.x, .y = r.y, .width = @max(1, self.end.rect.x - r.x), .height = @max(1, r.height) };
    }
};

/// One flyout's window and the view inside it.
const Panel = struct {
    flyout: system.Flyout = .{},
    storage: view.Storage(48, 1024) = .{},
    host: view.Host = undefined,

    fn isOpen(self: *const Panel) bool {
        return self.flyout.isOpen();
    }
    fn close(self: *Panel) void {
        if (self.isOpen()) _ = self.flyout.close() catch {};
    }
};

const Flyouts = struct {
    allocator: std.mem.Allocator = undefined,
    window: ?z.Window = null,
    /// The chosen color.
    color: usize = 0,
    /// The color the keys move to in the list.
    hover: usize = 0,
    note: [256]u8 = undefined,
    note_len: usize = 0,
    color_button: Anchored = .{},
    note_button: Anchored = .{},
    about_button: Anchored = .{},
    list: Panel = .{},
    editor: Panel = .{},
    about: Panel = .{},
    /// The note's text, and its field while the editor is open.
    document: ?*d.Document = null,
    engine: ?*t.Engine = null,
    field: ?*editing.Field = null,
    input: text.TextField = undefined,
    focus_note: bool = false,

    fn noteText(self: *const Flyouts) []const u8 {
        return self.note[0..self.note_len];
    }

    fn build(self: *Flyouts, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .alignment = .center, .justify = .center, .gap = 12 });
        try v.row(.{ .gap = 8, .alignment = .center });
        try v.row(.{ .width = 14, .height = 14, .radius = 7, .background = colors[self.color].rgb });
        try v.end();
        var label: [32]u8 = undefined;
        if (try self.color_button.button(v, try std.fmt.bufPrint(&label, "{s} ▾", .{colors[self.color].name}), 1)) self.toggleList();
        try v.end();
        if (try self.note_button.button(v, "Edit note…", 2)) self.openEditor();
        if (try self.about_button.button(v, "About", 3)) self.openAbout();
        try v.text(if (self.note_len == 0) "No note" else self.noteText(), .{ .color = muted, .font = .{ .size = 12 } });
        try v.end();
    }

    /// Opens `panel` with a Host of its own; the Host of an earlier flyout
    /// detached with its window.
    fn open(self: *Flyouts, panel: *Panel, comptime build_fn: fn (*Flyouts, *view.View) anyerror!void, options: system.flyout.Options) !void {
        const window = self.window orelse return error.NotAttached;
        var settings = options;
        settings.focusable = true;
        settings.shadow = true;
        settings.hidden = true;
        settings.on_closed = .{ .context = self, .notify = panelClosed };
        const flyout_window = try panel.flyout.open(window.app, settings);
        errdefer _ = flyout_window.destroy() catch {};
        panel.host = view.Host.init(self, build_fn, panel.storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) } });
        try panel.host.attach(flyout_window);
        if (panel == &self.editor) try panel.host.context.prepareTextFields(self.allocator, .{});
        panel.flyout.show();
        window.invalidate();
    }

    fn panelClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *Flyouts = @ptrCast(@alignCast(ptr));
        if (!self.editor.isOpen()) self.closeField();
        if (self.window) |window| window.invalidate();
    }

    fn report(err: anyerror) void {
        std.log.err("flyout: {s}", .{@errorName(err)});
    }

    /// Opens the list of colors below the button, or closes it.
    fn toggleList(self: *Flyouts) void {
        if (self.list.isOpen()) return self.list.close();
        const window = self.window orelse return;
        self.hover = self.color;
        self.open(&self.list, listView, .{
            .anchor = .{ .window = .{ .owner = window, .rect = self.color_button.rect() } },
            .gap = 4,
            .width = 180,
            .height = colors.len * row_height + 20,
        }) catch |err| report(err);
    }

    fn listView(self: *Flyouts, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(6), .radius = 10, .border = 0xc9d1dc, .background = 0xffffff });
        try v.bindKey(.{ .key = .down, .allow_repeat = true }, true, key_down);
        try v.bindKey(.{ .key = .up, .allow_repeat = true }, true, key_up);
        try v.bindKey(.{ .key = .enter }, true, key_enter);
        if (v.takeEvent(key_down) != null) self.hover = (self.hover + 1) % colors.len;
        if (v.takeEvent(key_up) != null) self.hover = (self.hover + colors.len - 1) % colors.len;
        if (v.takeEvent(key_enter) != null) self.choose(self.hover);
        try v.listBox(.{ .name = "Color", .self_align = .stretch, .grow = 1 });
        for (colors, 0..) |color, i| {
            var chosen = self.hover;
            // A click chooses; the keys above move the highlight.
            if (try v.listItem(usize, &chosen, i, color.name, .{ .key = 100 + i, .height = row_height, .self_align = .stretch })) self.choose(i);
        }
        try v.end();
        try v.end();
    }

    fn choose(self: *Flyouts, index: usize) void {
        self.color = index;
        self.hover = index;
        self.list.close();
        if (self.window) |window| window.invalidate();
    }

    /// Opens the note editor to the right of the button; it takes the
    /// keyboard.
    fn openEditor(self: *Flyouts) void {
        if (self.editor.isOpen()) return;
        const window = self.window orelse return;
        self.openField() catch |err| return report(err);
        self.focus_note = true;
        self.open(&self.editor, editorView, .{
            .anchor = .{ .window = .{ .owner = window, .rect = self.note_button.rect() } },
            .placement = .right_start,
            .gap = 8,
            .width = 260,
            .height = 96,
        }) catch |err| {
            self.closeField();
            report(err);
        };
    }

    /// A Field for one opening of the editor: it registers with the
    /// Context of the flyout's window, which closes with the flyout.
    fn openField(self: *Flyouts) !void {
        const document = self.document orelse return error.NotAttached;
        const engine = self.engine orelse return error.NotAttached;
        const field = try editing.Field.create(self.allocator, document, engine, .{ .value_bytes = self.note.len, .context = self, .changed = changed, .submit = submitted });
        self.field = field;
        self.input = text.TextField.init(field, &self.editor.host, .{ .font = .{ .size = 14 }, .scale = (self.window.?.contentSize() catch return error.NotAttached).scale }, .{ .name = "Note", .width = 236 });
    }

    fn closeField(self: *Flyouts) void {
        const field = self.field orelse return;
        self.input.detach();
        field.close() catch |err| return report(err);
        self.field = null;
    }

    fn editorView(self: *Flyouts, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(12), .gap = 8, .radius = 10, .border = 0xc9d1dc, .background = 0xffffff });
        try v.text("Note", .{ .font = .{ .size = 14, .weight = .bold } });
        if (self.field != null) {
            try v.embed(self.input.embed(), .{ .self_align = .stretch, .key = 20 });
            if (self.focus_note) {
                self.focus_note = false;
                v.focusLeaf(v.lastNode().id);
            }
        }
        try v.end();
    }

    /// The note follows the field as the user types.
    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Flyouts = @ptrCast(@alignCast(ptr.?));
        const field = self.field orelse return;
        const length = field.document.byteLength() catch return;
        var end = field.document.read(.{ .start = 0, .end = @min(length, self.note.len) }, &self.note) catch return;
        // Whole characters only.
        while (end > 0 and end < length and self.note[end] & 0xc0 == 0x80) end -= 1;
        self.note_len = end;
        if (self.window) |window| window.invalidate();
    }

    /// Enter keeps the note and closes the editor.
    fn submitted(ptr: ?*anyopaque, _: z.Window) void {
        const self: *Flyouts = @ptrCast(@alignCast(ptr.?));
        self.editor.close();
    }

    /// Opens the About box above the button.
    fn openAbout(self: *Flyouts) void {
        if (self.about.isOpen()) return;
        const window = self.window orelse return;
        self.open(&self.about, aboutView, .{
            .anchor = .{ .window = .{ .owner = window, .rect = self.about_button.rect() } },
            .placement = .top,
            .gap = 6,
            .width = 240,
            .height = 84,
        }) catch |err| report(err);
    }

    fn aboutView(_: *Flyouts, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(12), .gap = 2, .radius = 10, .border = 0xc9d1dc, .background = 0xffffff });
        try v.text("Flyout", .{ .font = .{ .size = 14, .weight = .bold } });
        // View text does not wrap: the lines break here.
        try v.text("Windows owned by their parent,", .{ .color = muted, .font = .{ .size = 12 } });
        try v.text("placed next to an anchor.", .{ .color = muted, .font = .{ .size = 12 } });
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var flyouts: Flyouts = .{ .allocator = allocator };
    var storage: view.Storage(48, 1024) = .{};
    var host = view.Host.init(&flyouts, Flyouts.build, storage.buffers(), .{ .root = .{ .padding = view.Insets.all(16) } });

    const app = try z.App.init(allocator);
    defer app.deinit();
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch {};
    flyouts.engine = engine;
    flyouts.document = document;

    const window = try app.createWindow(.{ .title = "Flyout", .width = 300, .height = 240 });
    flyouts.window = window;
    try host.attach(window);
    window.show();
    try app.run();
    flyouts.closeField();
}

const Windowless = struct {
    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn action(_: *anyopaque, _: u64) void {}
};

test "the window's buttons and labels" {
    var flyouts: Flyouts = .{};
    var storage: view.Storage(48, 1024) = .{};
    var h = view.Harness.init(&flyouts, Flyouts.build, storage.buffers(), .{});
    try h.render();
    _ = try h.find(.{ .text = "Red ▾" });
    _ = try h.find(.{ .text = "No note" });
    // Without a window, the buttons open nothing.
    try h.click(.{ .text = "About" });
    try std.testing.expect(!flyouts.about.isOpen());
    flyouts.choose(4);
    @memcpy(flyouts.note[0..5], "Hello");
    flyouts.note_len = 5;
    try h.render();
    _ = try h.find(.{ .text = "Blue ▾" });
    _ = try h.find(.{ .text = "Hello" });
}

test "the list of colors moves with the keys and chooses" {
    var flyouts: Flyouts = .{};
    var storage: view.Storage(48, 1024) = .{};
    var h = view.Harness.init(&flyouts, Flyouts.listView, storage.buffers(), .{});
    var dummy: u8 = 0;
    var context = ui.Context.init(&dummy, Windowless.draw, Windowless.action);
    try h.attachInput(&context);
    try h.render();
    try std.testing.expectEqual(@as(usize, colors.len), h.count(.{ .kind = .list_item }));
    _ = try h.key(.{ .key = .down });
    _ = try h.key(.{ .key = .down });
    try std.testing.expectEqual(@as(usize, 2), flyouts.hover);
    _ = try h.key(.{ .key = .up });
    _ = try h.key(.{ .key = .enter });
    try std.testing.expectEqual(@as(usize, 1), flyouts.color);
    try h.render();
    try h.click(.{ .text = "Purple" });
    try std.testing.expectEqual(@as(usize, 5), flyouts.color);
}
