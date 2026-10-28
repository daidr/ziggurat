const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const bounds: ui.Rect = .{ .x = 10, .y = 12, .width = 240, .height = 80 };
const parameters: shaped.Parameters = .{ .font = .{ .size = 18 } };
const Probe = struct {
    commands: usize = 0,
    selections: usize = 0,
    compositions: usize = 0,
    prepared: ?*const text.Prepared = null,
    adapter: ?*shaped.Adapter = null,
    fn paint(ptr: *anyopaque, command: shaped.PaintCommand) !void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.commands += 1;
        switch (command) {
            .text => |value| {
                self.prepared = value.prepared;
                _ = try value.prepared.view();
            },
            .selection => self.selections += 1,
            .composition => self.compositions += 1,
            .caret => {},
        }
        if (self.adapter) |adapter| try std.testing.expectError(error.Busy, adapter.prepare(bounds, parameters));
    }
    fn surface(self: *Probe) shaped.Surface {
        return .{ .context = self, .paint = paint };
    }
};
fn key(adapter: *shaped.Adapter, code: z.KeyCode, shift: bool, control: bool, viewport: ui.Rect, options: shaped.Parameters) !void {
    try expect(try adapter.handleEvent(.{ .key_input = .{ .key = code, .modifiers = .{ .shift = shift, .control = control } } }, viewport));
    _ = try adapter.prepare(viewport, options);
}
fn editing(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, "a\u{0301}👩‍👩‍👧‍👦Z");
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try adapter.prepare(bounds, parameters);
    _ = try editor.buffer.setSelection(.{});
    _ = try adapter.prepare(bounds, parameters);
    try key(&adapter, .right, false, false, bounds, parameters);
    try equal(@as(usize, 3), editor.buffer.selection().caret);
    try key(&adapter, .delete, false, false, bounds, parameters);
    try std.testing.expectEqualStrings("a\u{0301}Z", editor.buffer.text());
    try key(&adapter, .backspace, false, false, bounds, parameters);
    try std.testing.expectEqualStrings("Z", editor.buffer.text());
    try key(&adapter, .z, false, true, bounds, parameters);
    try std.testing.expectEqualStrings("a\u{0301}Z", editor.buffer.text());
    try key(&adapter, .z, false, true, bounds, parameters);
    try std.testing.expectEqualStrings("a\u{0301}👩‍👩‍👧‍👦Z", editor.buffer.text());
    try key(&adapter, .y, false, true, bounds, parameters);
    try std.testing.expectEqualStrings("a\u{0301}Z", editor.buffer.text());
    _ = try editor.buffer.selectAll();
    _ = try adapter.prepare(bounds, parameters);
    var probe: Probe = .{};
    try adapter.draw(bounds, 1, probe.surface());
    try expect(probe.selections > 0);
    const raw = try adapter.hitTest(bounds, .{ .x = bounds.x, .y = bounds.y + 5 });
    try equal(@as(usize, 0), raw.byte_offset);
}
fn visual(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, "abc אבג xyz");
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try adapter.prepare(bounds, parameters);
    try key(&adapter, .home, false, false, bounds, parameters);
    const layout_identity = adapter.snapshot.?.layout;
    const stats = try layout_identity.buildStats();
    var previous = try adapter.caretRect(bounds, 1);
    var previous_byte = editor.buffer.selection().caret;
    var backwards_logical = false;
    for (0..40) |_| {
        try key(&adapter, .right, false, false, bounds, parameters);
        const next = try adapter.caretRect(bounds, 1);
        const byte = editor.buffer.selection().caret;
        if (byte < previous_byte) backwards_logical = true;
        try expect(next.x >= previous.x - 0.01);
        const hit = try adapter.hitTest(bounds, .{ .x = next.x, .y = next.y + next.height * 0.5 });
        const hit_rect = try layout_identity.caret(hit);
        try std.testing.expectApproxEqAbs(next.x - bounds.x + editor.scroll.offset.x, hit_rect.x, 0.05);
        try equal(layout_identity, adapter.snapshot.?.layout);
        if (next.x == previous.x and byte == previous_byte) break;
        previous = next;
        previous_byte = byte;
    }
    try expect(backwards_logical);
    try equal(stats, try layout_identity.buildStats());

    _ = try editor.buffer.selectAll();
    _ = try editor.insertText("one two three four five six seven eight nine ten eleven twelve");
    const viewport: ui.Rect = .{ .x = 10, .y = 12, .width = 70, .height = 35 };
    const wrapped: shaped.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character } };
    _ = try adapter.prepare(viewport, wrapped);
    try expect((try adapter.snapshot.?.layout.lines()).len > 3);
    try key(&adapter, .home, false, true, viewport, wrapped);
    const first = try adapter.caretRect(viewport, 1);
    try key(&adapter, .down, false, false, viewport, wrapped);
    const second = try adapter.caretRect(viewport, 1);
    try expect(second.y + editor.scroll.offset.y > first.y);
    try key(&adapter, .page_down, true, false, viewport, wrapped);
    try expect(editor.buffer.selection().anchor != editor.buffer.selection().caret);
    try expect(editor.scroll.offset.y > 0);
    try key(&adapter, .home, false, false, viewport, wrapped);
    const home = try adapter.caretRect(viewport, 1);
    try key(&adapter, .end, false, false, viewport, wrapped);
    const end = try adapter.caretRect(viewport, 1);
    try expect(end.x >= home.x);
}
fn composition(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .autofocus = true }, "ab");
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try editor.buffer.setSelection(.{ .anchor = 1, .caret = 2 });
    _ = try adapter.prepare(bounds, parameters);
    try expect(try adapter.handleEvent(.{ .text_preedit = .{ .text = "中a\u{0301}", .selection_start = 4, .selection_end = 4 } }, bounds));
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqualStrings("ab", editor.buffer.text());
    try std.testing.expectEqualStrings("a中a\u{0301}", try adapter.snapshot.?.layout.text());
    var probe: Probe = .{};
    try adapter.draw(bounds, 1, probe.surface());
    try expect(probe.compositions > 0);
    try expect(std.math.isFinite((try adapter.caretRect(bounds, 1)).x));
    try expect(try adapter.handleEvent(.{ .text_input = .{ .text = "文", .producer = .application } }, bounds));
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqualStrings("a文", editor.buffer.text());
    try key(&adapter, .z, false, true, bounds, parameters);
    try std.testing.expectEqualStrings("ab", editor.buffer.text());
    try key(&adapter, .y, false, true, bounds, parameters);
    try std.testing.expectEqualStrings("a文", editor.buffer.text());
    _ = try adapter.handleEvent(.{ .text_preedit = .{ .text = "字", .selection_start = 3, .selection_end = 3 } }, bounds);
    _ = try adapter.prepare(bounds, parameters);
    _ = try adapter.handleEvent(.{ .focus = false }, bounds);
    _ = try adapter.prepare(bounds, parameters);
    try expect(editor.buffer.composition() == null);
    try std.testing.expectEqualStrings("a文", try adapter.snapshot.?.layout.text());
}
fn failureAndCost(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .autofocus = true }, "short");
    defer editor.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var adapter = try shaped.Adapter.init(failing.allocator(), &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try adapter.prepare(bounds, parameters);
    const old = adapter.snapshot.?.layout;
    const old_prepared = adapter.snapshot.?.prepared;
    var probe: Probe = .{ .adapter = &adapter };
    failing.fail_index = failing.alloc_index;
    for (0..25) |_| {
        try adapter.draw(bounds, 1, probe.surface());
        _ = try adapter.hitTest(bounds, .{ .x = 20, .y = 20 });
        _ = try adapter.caretRect(bounds, 1);
    }
    try expect(!failing.has_induced_failure);
    try equal(failing.fail_index, failing.alloc_index);
    try expect(try editor.insertText(" changed"));
    try std.testing.expectError(error.OutOfMemory, adapter.prepare(bounds, parameters));
    try equal(old, adapter.snapshot.?.layout);
    try equal(old_prepared, adapter.snapshot.?.prepared);
    try std.testing.expectError(error.LayoutRequired, adapter.draw(bounds, 1, probe.surface()));
    failing.fail_index = std.math.maxInt(usize);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqualStrings(editor.buffer.text(), try adapter.snapshot.?.layout.text());
    const before = adapter.snapshot.?.prepared;
    try std.testing.expectError(error.InvalidOptions, adapter.prepare(bounds, .{ .font = .{ .size = std.math.nan(f32) } }));
    try equal(before, adapter.snapshot.?.prepared);
    _ = try adapter.prepare(bounds, .{ .font = parameters.font, .scale = 2 });
    try std.testing.expectError(error.LayoutRequired, adapter.draw(bounds, 1, probe.surface()));
    try adapter.draw(bounds, 2, probe.surface());
    const lease = (try adapter.snapshot.?.prepared.view()).lease;
    try lease.acquire();
    try std.testing.expectError(error.ResourceInUse, adapter.prepare(bounds, parameters));
    try std.testing.expectError(error.ResourceInUse, adapter.deinit());
    lease.release();
    _ = try adapter.prepare(bounds, parameters);
    adapter.limits.visual_stops = 2;
    _ = try editor.insertText("x");
    try std.testing.expectError(error.VisualCapacityExceeded, adapter.prepare(bounds, parameters));
    adapter.limits.visual_stops = 16386;
    _ = try adapter.prepare(bounds, parameters);
    _ = try editor.buffer.selectAll();
    adapter.limits.rectangles = 0;
    try std.testing.expectError(error.RectangleCapacityExceeded, adapter.prepare(bounds, parameters));
    adapter.limits.rectangles = 16384;
    _ = try adapter.prepare(bounds, parameters);
}
fn visiblePlane(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, &@as([2000 * "i\n".len]u8, @bitCast(@as([2000]["i\n".len]u8, @splat("i\n".*)))));
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try adapter.prepare(bounds, parameters);
    const identity = adapter.snapshot.?.layout;
    const stats = try identity.buildStats();
    try expect((try identity.metrics()).bounds.height > 32768);
    try expect(editor.scroll.offset.y > 32768);
    const view = try adapter.snapshot.?.prepared.view();
    try expect(view.coverage.width < 512 and view.coverage.height < 256);
    editor.reveal_caret = false;
    _ = try editor.scroll.setOffset(.{});
    var probe: Probe = .{};
    try std.testing.expectError(error.LayoutRequired, adapter.draw(bounds, 1, probe.surface()));
    _ = try adapter.prepare(bounds, parameters);
    try equal(identity, adapter.snapshot.?.layout);
    try equal(stats, try identity.buildStats());
    const prepared = adapter.snapshot.?.prepared;
    const offset = editor.scroll.offset;
    // Navigation requests reveal, but a failed plane must not commit scrolling.
    _ = try editor.buffer.setSelection(.{ .anchor = editor.buffer.text().len, .caret = editor.buffer.text().len });
    editor.reveal_caret = true;
    adapter.limits.prepared.pixels = 1;
    try std.testing.expectError(error.PreparedCapacityExceeded, adapter.prepare(bounds, parameters));
    try equal(offset, editor.scroll.offset);
    try expect(editor.reveal_caret);
    try equal(prepared, adapter.snapshot.?.prepared);
    try equal(identity, adapter.snapshot.?.layout);
    adapter.limits.prepared.pixels = 16 * 1024 * 1024;
    _ = try adapter.prepare(bounds, parameters);
    try expect(editor.scroll.offset.y > 32768 and !editor.reveal_caret);
    try equal(identity, adapter.snapshot.?.layout);
    _ = try adapter.prepare(bounds, .{ .font = parameters.font, .scale = 1.5 });
    try equal(identity, adapter.snapshot.?.layout);
    try equal(stats, try identity.buildStats());
}
fn wrongThread(allocator: std.mem.Allocator, engine: *text.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{}, "a");
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    const Worker = struct {
        fn run(value: *shaped.Adapter) void {
            std.testing.expectError(error.WrongThread, value.prepare(bounds, parameters)) catch unreachable;
            std.testing.expectError(error.WrongThread, value.handleEvent(.text_preedit_cancel, bounds)) catch unreachable;
            std.testing.expectError(error.WrongThread, value.deinit()) catch unreachable;
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&adapter});
    worker.join();
    try std.testing.expectEqualStrings("a", editor.buffer.text());
}
pub fn main() !void {
    _ = builtin;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const before = text.resourceCounts();
    {
        const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        try editing(allocator, engine);
        try visual(allocator, engine);
        try composition(allocator, engine);
        try failureAndCost(allocator, engine);
        try visiblePlane(allocator, engine);
        try wrongThread(allocator, engine);
    }
    try equal(before, text.resourceCounts());
    std.debug.print("shaped editor passed: grapheme edits, bidi visual navigation, wrap/scroll, virtual IME and undo, prepared cache transactions, allocation-free draw, resources=0\n", .{});
}
