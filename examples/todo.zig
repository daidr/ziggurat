//! A todo list: type into the text field and press Enter (or Add) to add an
//! item, tick its checkbox to complete it, filter by All / Active /
//! Completed, delete items one by one or clear the completed ones.
//!
//! It shows a `ziggurat_view_text.TextField` over an app-owned Document,
//! keyed list rows whose identity survives insertion and deletion, and
//! fixed-capacity storage with no allocation after start-up. Reading and
//! clearing the field happens in a posted task, outside the field's own
//! input callback.
//!
//! Run it with `zig build run-todo`.
const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const view = @import("ziggurat_view");
const text = @import("ziggurat_view_text");

const Filter = enum { all, active, completed };

const Item = struct {
    id: u64,
    done: bool = false,
    bytes: [120]u8 = undefined,
    len: usize = 0,
    fn label(self: *const Item) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Todo = struct {
    /// Each row records two controls; the frame holds 128 per window.
    const capacity = 32;
    items: [capacity]Item = undefined,
    count: usize = 0,
    next_id: u64 = 1,
    filter: Filter = .all,
    list: view.ScrollModel = .{},
    /// The entry field; null in headless tests.
    input: ?*text.TextField = null,
    add_queued: bool = false,

    fn add(self: *Todo, raw: []const u8) bool {
        const value = std.mem.trim(u8, raw, " \t");
        if (value.len == 0 or self.count == capacity) return false;
        var item: Item = .{ .id = self.next_id };
        // Keep whole UTF-8 sequences when a long entry is cut short.
        var len = @min(value.len, item.bytes.len);
        while (len < value.len and len > 0 and value[len] & 0xc0 == 0x80) len -= 1;
        @memcpy(item.bytes[0..len], value[0..len]);
        item.len = len;
        self.items[self.count] = item;
        self.count += 1;
        self.next_id += 1;
        return true;
    }

    fn remove(self: *Todo, index: usize) void {
        std.mem.copyForwards(Item, self.items[index .. self.count - 1], self.items[index + 1 .. self.count]);
        self.count -= 1;
    }

    fn clearCompleted(self: *Todo) void {
        var kept: usize = 0;
        for (self.items[0..self.count]) |item| if (!item.done) {
            self.items[kept] = item;
            kept += 1;
        };
        self.count = kept;
    }

    fn left(self: *const Todo) usize {
        var n: usize = 0;
        for (self.items[0..self.count]) |item| n += @intFromBool(!item.done);
        return n;
    }

    /// Queue the move of the entry text into the list. Both the Add button
    /// and Enter run inside input handling, so the work is posted.
    fn requestAdd(self: *Todo) void {
        if (self.add_queued) return;
        const input = self.input orelse return;
        const window = input.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = addFromInput }) catch return;
        self.add_queued = true;
    }

    fn addFromInput(ptr: *anyopaque) void {
        const self: *Todo = @ptrCast(@alignCast(ptr));
        self.add_queued = false;
        const input = self.input orelse return;
        const document = input.field.document;
        var bytes: [512]u8 = undefined;
        const length = document.byteLength() catch return;
        const count = document.read(.{ .start = 0, .end = @min(length, bytes.len) }, &bytes) catch return;
        if (!self.add(bytes[0..count])) return;
        _ = input.field.setValue("") catch {};
        if (input.host.context.window) |window| window.invalidate();
    }

    fn submitted(ptr: ?*anyopaque, _: z.Window) void {
        const self: *Todo = @ptrCast(@alignCast(ptr.?));
        self.requestAdd();
    }

    fn build(self: *Todo, v: *view.View) anyerror!void {
        try v.text("Todo", .{ .font = view.Font.heading2 });

        try v.row(.{ .gap = 8, .alignment = .center, .self_align = .stretch });
        if (self.input) |input| try v.embed(input.embed(), .{ .grow = 1, .key = 1 });
        if (try v.button("Add", .{ .key = 2, .enabled = self.count < capacity })) self.requestAdd();
        try v.end();

        try v.segmented(.{ .name = "Show" });
        _ = try v.segment(Filter, &self.filter, .all, "All", .{});
        _ = try v.segment(Filter, &self.filter, .active, "Active", .{});
        _ = try v.segment(Filter, &self.filter, .completed, "Completed", .{});
        try v.end();

        try v.scroll(&self.list, .{ .grow = 1, .self_align = .stretch, .gap = 4 });
        var removed: ?usize = null;
        var shown: usize = 0;
        for (self.items[0..self.count], 0..) |*item, index| {
            const visible = switch (self.filter) {
                .all => true,
                .active => !item.done,
                .completed => item.done,
            };
            if (!visible) continue;
            shown += 1;
            // The key keeps each row's controls, and their focus, attached
            // to the same item as rows above it come and go.
            try v.row(.{ .key = item.id, .gap = 8, .alignment = .center, .self_align = .stretch });
            _ = try v.checkbox(&item.done, item.label(), .{ .grow = 1 });
            if (try v.button("Delete", .{ .name = item.label() })) removed = index;
            try v.end();
        }
        if (shown == 0) try v.text(if (self.count == 0) "Nothing to do yet." else "No items match this filter.", .{ .color = 0x6b7785 });
        try v.end();
        if (removed) |index| self.remove(index);

        try v.row(.{ .gap = 12, .alignment = .center, .self_align = .stretch });
        const remaining = self.left();
        try v.textf("{d} item{s} left", .{ remaining, if (remaining == 1) "" else "s" }, .{});
        try v.spacer(.{});
        if (try v.button("Clear completed", .{ .enabled = remaining != self.count })) self.clearCompleted();
        try v.end();
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var todo: Todo = .{};
    _ = todo.add("Read the view guide");
    _ = todo.add("Write a build function");
    var storage: view.Storage(192, 8192) = .{};
    var host = view.Host.init(&todo, Todo.build, storage.buffers(), .{});

    const app = try z.App.init(allocator);
    defer app.deinit();
    // The text engine and the entry's Document outlive the editor Field.
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch {};
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "", .{});
    defer document.close() catch {};

    const window = try app.createWindow(.{ .title = "Todo", .width = 480, .height = 560, .min_width = 320, .min_height = 320 });
    try host.attach(window);
    try host.context.prepareTextFields(allocator, .{});

    const editor = try editing.Field.create(allocator, document, engine, .{ .context = &todo, .submit = Todo.submitted });
    var entry = text.TextField.init(editor, &host, .{ .font = .{ .size = 16 }, .scale = (try window.contentSize()).scale }, .{ .name = "New item" });
    todo.input = &entry;

    window.show();
    try app.run();

    // The window is gone; stop deferred work, then close the Field before
    // its Document and Engine.
    todo.input = null;
    entry.detach();
    try editor.close();
}

test "add, complete, filter and clear" {
    var todo: Todo = .{};
    var storage: view.Storage(192, 8192) = .{};
    var h = view.Harness.init(&todo, Todo.build, storage.buffers(), .{});
    try std.testing.expect(todo.add("milk"));
    try std.testing.expect(todo.add("  bread "));
    try std.testing.expect(!todo.add("   "));
    try h.render();
    try std.testing.expectEqualStrings("bread", todo.items[1].label());

    try h.click(.{ .text = "milk" });
    try std.testing.expect(todo.items[0].done);
    _ = try h.find(.{ .text = "1 item left" });

    try h.click(.{ .text = "Active" });
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .text = "milk" }));

    try h.click(.{ .text = "All" });
    try h.click(.{ .text = "Clear completed" });
    try std.testing.expectEqual(@as(usize, 1), todo.count);
    try h.click(.{ .text = "Delete" });
    try std.testing.expectEqual(@as(usize, 0), todo.count);
}
