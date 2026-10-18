const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 260 };
const a_text = "top\nxe\u{301}y 👩‍👩‍👧‍👧 end\nabc אבג def\ninsert HERE\nline\r\n";
const b_text = "top\nxe\u{308}y 👩‍👩‍👦‍👦 end\naXג def\ninsert XHERE\nline\n";
const marker_capacity = 1031;
const Trap = struct {
    source: std.mem.Allocator,
    reject_marks: bool = false,
    close_on_marks_free: ?z.Window = null,
    fn allocator(self: *Trap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Trap = @ptrCast(@alignCast(ptr));
        if (self.reject_marks and size == marker_capacity * @sizeOf(viewing.editable.IntralineMark)) return null;
        return self.source.rawAlloc(size, alignment, ret);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *Trap = @ptrCast(@alignCast(ptr));
        return self.source.rawResize(bytes, alignment, size, ret);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *Trap = @ptrCast(@alignCast(ptr));
        return self.source.rawRemap(bytes, alignment, size, ret);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Trap = @ptrCast(@alignCast(ptr));
        if (bytes.len == marker_capacity * @sizeOf(viewing.editable.IntralineMark)) if (self.close_on_marks_free) |window| {
            self.close_on_marks_free = null;
            _ = window.destroy() catch unreachable;
        };
        self.source.rawFree(bytes, alignment, ret);
    }
};

fn contains(marks: []const viewing.editable.IntralineMark, side: viewing.Side, rectangle: t.Rect) bool {
    for (marks) |mark| if (mark.side == side and std.meta.eql(mark.rect, ui.Rect{ .x = rectangle.x, .y = rectangle.y, .width = rectangle.width, .height = rectangle.height })) return true;
    return false;
}
fn verify(comptime Surface: type, state: *@import("document_diff_editable_smoke.zig").Harness(Surface)) !void {
    var storage: [1024]viewing.editable.IntralineMark = undefined;
    const marks = try state.view.intralineRects(&storage);
    try std.testing.expect(marks.len > 5);
    var rows: [96]viewing.editable.Row = undefined;
    const visible = try state.view.rowInfo(&rows);
    const borrow = try state.inbox.borrow();
    defer borrow.end();
    const display = (try borrow.display()).?;
    const details = &display.details.?;
    var empty = false;
    var islands = false;
    var combining = false;
    var emoji = false;
    var expected_count: usize = 0;
    var scratch: [1024]t.Rect = undefined;
    for (state.adapters, 0..) |adapter, side| for (visible) |row| {
        const line = (if (side == 0) row.a else row.b) orelse continue;
        for (details.spans) |span| {
            if ((if (side == 0) span.line_a else span.line_b) != line) continue;
            const range = if (side == 0) span.a else span.b;
            const revision = try (if (side == 0) state.inbox.pair.a else state.inbox.pair.b).version();
            const rectangles = try adapter.rangeRects(revision, range, &scratch);
            if (rectangles.len > 1 and line == 2) islands = true;
            for (rectangles) |rectangle| {
                try std.testing.expect(contains(marks, @enumFromInt(side), rectangle));
                expected_count += 1;
            }
            if (rectangles.len == 0) if (try adapter.positionRect(revision, range.start, .downstream)) |rectangle| {
                try std.testing.expect(contains(marks, @enumFromInt(side), rectangle));
                expected_count += 1;
                if (range.start == range.end) empty = true;
            };
            if (line == 1 and range.start == 6 and range.end == 8) {
                var full: [32]t.Rect = undefined;
                const expanded = try adapter.rangeRects(revision, .{ .start = 5, .end = 8 }, &full);
                try std.testing.expectEqualSlices(t.Rect, rectangles, expanded);
                combining = true;
            }
            if (line == 1 and range.start >= 10 and range.end <= 35) {
                var full: [32]t.Rect = undefined;
                const expanded = try adapter.rangeRects(revision, .{ .start = 10, .end = 35 }, &full);
                try std.testing.expectEqualSlices(t.Rect, rectangles, expanded);
                emoji = true;
            }
        }
    };
    try std.testing.expectEqual(expected_count, marks.len);
    try std.testing.expect(empty and islands and combining and emoji);
    // Sample exact interior background pixels, independently of glyph ink and
    // fractional outer edges. These are the real retained native surfaces.
    var sampled: [2]bool = @splat(false);
    for (marks) |mark| {
        const side = @intFromEnum(mark.side);
        if (sampled[side] or mark.rect.width < 4 or mark.rect.height < 4) continue;
        const colors: viewing.Colors = .{};
        const expected = if (side == 0) colors.deleted_detail else colors.added_detail;
        const y = mark.rect.y + mark.rect.height - 2;
        var x = mark.rect.x + 1;
        while (x < mark.rect.x + mark.rect.width - 1) : (x += 1 / state.parameters.scale) {
            if (try state.pixel(x, y) == expected) {
                sampled[side] = true;
                break;
            }
        }
    }
    try std.testing.expect(sampled[0] and sampled[1]);
}

fn runMode(allocator: std.mem.Allocator, comptime Surface: type) !void {
    const Harness = @import("document_diff_editable_smoke.zig").Harness(Surface);
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), a_text, .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), b_text, .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapters: [2]*editing.Adapter = .{ try editing.Adapter.create(allocator, a, engine, .{}), try editing.Adapter.create(allocator, b, engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var state: Harness = .{ .inbox = inbox, .adapters = adapters, .detailed = true };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = Harness.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    var trap: Trap = .{ .source = allocator };
    var failing = std.testing.FailingAllocator.init(trap.allocator(), .{});
    state.view = try Surface.create(failing.allocator(), inbox, adapters[0], adapters[1], state.window, .{ .intraline_rects = marker_capacity });
    defer state.view.close() catch unreachable;
    try state.refresh();
    state.context = ui.Context.init(&state, Harness.draw, Harness.action);
    state.context.render_mode = .gdi;
    state.context.on_input = Harness.input;
    try state.context.attach(state.window);
    try state.paint();
    try verify(Surface, &state);
    const initial_stats = try state.view.stats();
    const shaped = .{ try adapters[0].stats(), try adapters[1].stats() };
    try state.paint();
    try std.testing.expectEqual(initial_stats.intraline_queries, (try state.view.stats()).intraline_queries);
    try std.testing.expectEqual(shaped[0].shaped_batches, (try adapters[0].stats()).shaped_batches);
    try std.testing.expectEqual(shaped[1].shaped_batches, (try adapters[1].stats()).shaped_batches);
    _ = try adapters[1].setSelection(.{ .anchor = 1, .caret = 1 }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    try std.testing.expectEqual(initial_stats.intraline_queries, (try state.view.stats()).intraline_queries);
    if (Surface == viewing.EditableUnified) try state.view.focus() else try state.view.focus(.b);
    _ = try state.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 3 } }, bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 0), (try state.view.stats()).intraline_rectangles);
    try state.paint();
    _ = try state.view.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try state.paint();
    try verify(Surface, &state);
    // Every failure may leave paired layout publication committed. The owner
    // must still close those Plans and refuse stale marks until prepare works.
    var narrower = bounds;
    narrower.width -= 17;
    trap.reject_marks = true;
    try std.testing.expectError(error.OutOfMemory, state.view.prepare(narrower, state.parameters));
    try std.testing.expect(try adapters[0].projectionPlan() != null and try adapters[1].projectionPlan() != null);
    try std.testing.expectError(error.LayoutRequired, state.view.info());
    try std.testing.expect((try state.view.stats()).intraline_rectangles > 0);
    trap.reject_marks = false;
    try state.view.prepare(bounds, state.parameters);
    for (0..12) |offset| {
        failing.fail_index = failing.alloc_index + offset;
        if (state.view.prepare(narrower, state.parameters)) |_| {} else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            var buffer: [1024]viewing.editable.IntralineMark = undefined;
            try std.testing.expectError(error.LayoutRequired, state.view.intralineRects(&buffer));
        }
        failing.fail_index = std.math.maxInt(usize);
        try state.view.prepare(bounds, state.parameters);
    }
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    const frames = state.context.frames;
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    state.fail_frame = false;
    state.expected = null;
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.handleEvent(.{ .text_input = .{ .text = "x", .producer = .application } }, bounds, state.parameters);
    try std.testing.expect((try state.view.info()).comparison_required);
    try std.testing.expectEqual(@as(usize, 0), (try state.view.stats()).intraline_rectangles);
    _ = try adapters[1].undo();
    try state.refresh();
    try state.paint();
    trap.close_on_marks_free = state.window;
    try std.testing.expectError(error.Closed, state.view.prepare(narrower, state.parameters));
    try std.testing.expect(trap.close_on_marks_free == null);
    try app.dispatch();
    try std.testing.expect(state.window.isClosed());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

pub fn run(allocator: std.mem.Allocator) !void {
    const counts = t.resourceCounts();
    try runMode(allocator, viewing.EditableSplit);
    try runMode(allocator, viewing.EditableUnified);
    try capacity(allocator);
    try std.testing.expectEqual(counts, t.resourceCounts());
    std.debug.print("intraline native passed: scalar/grapheme expansion, bidi islands, empty caret, split/unified pixels, retained marks, IME/undo/OOM/failed Frame/close resources=0\n", .{});
}

fn capacity(allocator: std.mem.Allocator) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc אבג def", .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), "aXג def", .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapters: [2]*editing.Adapter = .{ try editing.Adapter.create(allocator, a, engine, .{}), try editing.Adapter.create(allocator, b, engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = window.destroy() catch unreachable;
    const view = try viewing.EditableSplit.create(allocator, inbox, adapters[0], adapters[1], window, .{ .intraline_rects = 1 });
    defer view.close() catch unreachable;
    const job = try inbox.begin();
    var released = false;
    defer {
        if (!released) job.release() catch unreachable;
        _ = inbox.finish(job.ticket) catch unreachable;
    }
    const diff = @import("ziggurat_document_diff");
    var lines = try diff.compare(allocator, job.a, job.b, .{});
    defer lines.deinit();
    var details = try viewing.intraline.compare(allocator, job.a, job.b, &lines, .{});
    defer details.deinit();
    try job.release();
    released = true;
    try inbox.publishDetailed(job.ticket, &lines, &details);
    var parameters: viewing.Parameters = .{};
    parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?));
    try std.testing.expectError(error.RectangleCapacityExceeded, view.prepare(bounds, parameters));
    try std.testing.expectError(error.LayoutRequired, view.info());
    try std.testing.expect(try adapters[0].projectionPlan() != null and try adapters[1].projectionPlan() != null);
}
