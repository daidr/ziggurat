const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn zlg_resource_count() u32;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 440, .height = 240 };

const Gate = struct {
    child: std.mem.Allocator,
    deny: bool = false,
    attempts: usize = 0,
    probe: bool = false,
    view: ?*viewing.EditableSplit = null,
    busy_calls: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn busy(self: *@This()) void {
        const view = self.view orelse return;
        std.testing.expectError(error.Busy, view.activeSide()) catch unreachable;
        std.testing.expectError(error.Busy, view.cursor()) catch unreachable;
        std.testing.expectError(error.Busy, view.currentHunk()) catch unreachable;
        self.busy_calls += 1;
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.attempts += 1;
        if (self.probe) self.busy();
        if (self.deny) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.probe) self.busy();
        self.child.rawFree(bytes, alignment, ra);
    }
};

const Fixture = struct {
    allocator: std.mem.Allocator,
    view: *viewing.EditableSplit,
    inbox: *viewing.Inbox,
    documents: [2]*d.Document,
    adapters: [2]*editing.Adapter,
    parameters: viewing.Parameters,
    fn refresh(self: *@This()) !void {
        const job = try self.inbox.begin();
        var result = diff.compare(self.allocator, job.a, job.b, .{}) catch |err| {
            try job.release();
            _ = try self.inbox.finish(job.ticket);
            return err;
        };
        defer result.deinit();
        try job.release();
        defer _ = self.inbox.finish(job.ticket) catch unreachable;
        try self.inbox.publish(job.ticket, &result);
        try self.view.prepare(bounds, self.parameters);
    }
    fn sources(self: *@This(), a: []const u8, b: []const u8) !void {
        for (self.documents, self.adapters, [_][]const u8{ a, b }) |document, adapter, source| {
            try document.replace(.{ .start = 0, .end = try document.byteLength() }, source);
            try adapter.reindex();
        }
        try self.refresh();
    }
    fn expected(self: *@This()) !void {
        const position = try self.view.cursor();
        const document = self.documents[@backingInt(position.side)];
        const selected = try document.selection();
        try std.testing.expectEqual(selected.caret, position.byte_offset);
        try std.testing.expectEqual(try document.version(), position.revision);
        try std.testing.expectEqual(try document.committedTextVersion(), position.text_version);
        const borrow = try self.inbox.borrow();
        var expected_index: ?usize = null;
        var expected_inside = false;
        const display = (try borrow.display()).?;
        const serial = display.serial;
        // Independent linear oracle: ask the original Document to map each
        // insertion byte boundary, rather than using query normalization.
        for (display.result.hunks, 0..) |hunk, at| {
            const source = if (position.side == .a) hunk.a else hunk.b;
            const first = if (source.lines.start == source.lines.end) try document.lineAt(source.bytes.start) else source.lines.start;
            if (first <= position.line) {
                expected_index = at;
                expected_inside = if (source.lines.start == source.lines.end) position.line == first else position.line < source.lines.end;
            }
        }
        borrow.end();
        const located = try self.view.currentHunk();
        try std.testing.expectEqual(serial, located.serial);
        try std.testing.expectEqual(position.side, located.side);
        try std.testing.expectEqual(expected_index, located.index);
        try std.testing.expectEqual(expected_inside, located.inside);
    }
};

fn run(child: std.mem.Allocator, mode: viewing.editable.Mode) !void {
    var gate: Gate = .{ .child = child };
    const a = gate.allocator();
    const app = try z.App.init(a);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 450, .height = 250 });
    defer _ = window.destroy() catch unreachable;
    const documents = [_]*d.Document{ try d.Document.create(a, app.owner, "head\nA-only\nshared\nX\nend", .{}), try d.Document.create(a, app.owner, "head\nshared\nY\nend", .{}) };
    defer for (documents) |document| document.close() catch unreachable;
    const engine = try text.Engine.create(a, app.owner, .{});
    defer engine.close() catch unreachable;
    const adapters = [_]*editing.Adapter{ try editing.Adapter.create(a, documents[0], engine, .{}), try editing.Adapter.create(a, documents[1], engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const inbox = try viewing.Inbox.create(a, .{ .a = documents[0], .b = documents[1] }, .{});
    defer inbox.close() catch unreachable;
    const unified = if (mode == .unified) try viewing.EditableUnified.create(a, inbox, adapters[0], adapters[1], window, .{}) else null;
    const view = if (unified) |owner| owner.coordinator() else try viewing.EditableSplit.create(a, inbox, adapters[0], adapters[1], window, .{});
    defer if (unified) |owner| owner.close() catch unreachable else view.close() catch unreachable;
    gate.view = view;
    var fixture: Fixture = .{ .allocator = a, .view = view, .inbox = inbox, .documents = documents, .adapters = adapters, .parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = 200 }, .scale = if (builtin.os.tag == .linux) @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?)) else 1 } };
    try std.testing.expectEqual(viewing.Side.b, try view.activeSide());
    _ = try view.cursor(); // No layout or comparison is needed.
    try std.testing.expectError(error.ComparisonRequired, view.currentHunk());
    try fixture.refresh();
    try view.focus(.b);
    try std.testing.expect(try adapters[1].isBound());
    if (mode == .split) {
        try view.focus(.a);
        try std.testing.expect(try adapters[0].isBound());
        var rows: [96]viewing.editable.Row = undefined;
        const snapshot = try view.copyPresentation(&rows);
        try view.blurPresented(snapshot.epoch);
        try std.testing.expect((try view.info()).focused == null);
        try std.testing.expectEqual(viewing.Side.a, try view.activeSide());
        // Invalid candidate focus cannot publish a new last-active source.
        _ = try documents[1].setSelection(.{ .anchor = 1, .caret = 1 });
        try std.testing.expectError(error.LayoutRequired, view.focus(.b));
        try std.testing.expectEqual(viewing.Side.a, try view.activeSide());
        try fixture.expected();
        try view.prepare(bounds, fixture.parameters);
    }
    try view.focus(.b);
    _ = try documents[1].setSelection(.{ .anchor = 12, .caret = 12 });
    try fixture.expected(); // Selection changed; intentionally no prepare.
    try view.prepare(bounds, fixture.parameters);
    _ = try view.navigate(false);
    try view.prepare(bounds, fixture.parameters);
    try std.testing.expectEqual(@as(?usize, 0), (try view.info()).selected_hunk);
    try std.testing.expectEqual(@as(?usize, 1), (try view.currentHunk()).index);
    if (unified) |owner| {
        try std.testing.expectEqual(viewing.Side.b, try owner.activeSide());
        try std.testing.expectEqual(try view.cursor(), try owner.cursor());
        try std.testing.expectEqual(try view.currentHunk(), try owner.currentHunk());
        var rows: [96]viewing.editable.Row = undefined;
        var ghost = false;
        for (try view.rowInfo(&rows)) |row| if (row.a != null and row.b == null and row.hunk == 0) {
            const selected = try documents[1].selection();
            _ = try view.handleEvent(.{ .pointer_down = .{ .position = .{ .x = bounds.x + 30, .y = bounds.y + row.y + 1 } } }, bounds, fixture.parameters);
            try std.testing.expectEqual(selected, try documents[1].selection());
            try std.testing.expectEqual(@as(?usize, 0), (try view.info()).selected_hunk);
            try std.testing.expectEqual(@as(?usize, 1), (try view.currentHunk()).index);
            ghost = true;
            break;
        };
        try std.testing.expect(ghost);
        try std.testing.expectError(error.ReadOnlySource, view.focus(.a));
        try std.testing.expectEqual(viewing.Side.b, try view.activeSide());
    }
    _ = try view.handleEvent(.{ .focus = false }, bounds, fixture.parameters);
    try std.testing.expectEqual(viewing.Side.b, try view.activeSide());
    try fixture.sources("same\nA-only\nsame\nA\nlast", "same\nβ😀 tail\r\nsame\nB\nlast");
    _ = try documents[1].setSelection(.{ .anchor = 14, .caret = 11 });
    const unicode = try view.cursor();
    try std.testing.expectEqual(@as(usize, 1), unicode.line);
    try std.testing.expectEqual(@as(usize, 3), unicode.utf16_column);
    try fixture.expected();
    _ = try documents[0].setSelections(&.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 9, .caret = 5 } }, 1);
    if (mode == .split) {
        try view.prepare(bounds, fixture.parameters);
        try view.focus(.a);
        try std.testing.expectEqual(@as(usize, 5), (try view.cursor()).byte_offset);
        try fixture.expected();
    }
    try documents[0].setComposition("候", .{ .anchor = 0, .caret = 0 });
    _ = try view.activeSide();
    try std.testing.expectError(error.CompositionActive, view.cursor());
    try std.testing.expectError(error.CompositionActive, view.currentHunk());
    _ = try documents[0].cancelComposition();
    try fixture.expected();
    try view.prepare(bounds, fixture.parameters);
    const before = gate.attempts;
    const resources = text.resourceCounts();
    const updates = (try view.stats()).layout_updates;
    gate.deny = true;
    for (0..1024) |_| {
        _ = try view.activeSide();
        _ = try view.cursor();
        _ = try view.currentHunk();
    }
    gate.deny = false;
    try std.testing.expectEqual(before, gate.attempts);
    try std.testing.expectEqual(resources, text.resourceCounts());
    try std.testing.expectEqual(updates, (try view.stats()).layout_updates);
    gate.probe = true;
    fixture.parameters.font.size += 1;
    try view.prepare(bounds, fixture.parameters);
    gate.probe = false;
    try std.testing.expect(gate.busy_calls > 0);
    const Worker = struct {
        fn check(owner: *viewing.EditableSplit) void {
            std.testing.expectError(error.WrongThread, owner.activeSide()) catch unreachable;
            std.testing.expectError(error.WrongThread, owner.cursor()) catch unreachable;
            std.testing.expectError(error.WrongThread, owner.currentHunk()) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.check, .{view});
    thread.join();
    {
        const common = "unchanged wrapped paragraph with enough words to occupy more than one visual line\n";
        try fixture.sources(&@as([12 * common.len]u8, @bitCast(@as([12][common.len]u8, @splat(common.*)))) ++ "A\n" ++ &@as([12 * common.len]u8, @bitCast(@as([12][common.len]u8, @splat(common.*)))), &@as([12 * common.len]u8, @bitCast(@as([12][common.len]u8, @splat(common.*)))) ++ "B\n" ++ &@as([12 * common.len]u8, @bitCast(@as([12][common.len]u8, @splat(common.*)))));
        try view.setContext(.{ .context_lines = 1, .minimum_hidden = 2 });
        try view.prepare(bounds, fixture.parameters);
        var regions: [96]viewing.editable.ContextRegion = undefined;
        const folded = try view.contextRegions(&regions);
        try std.testing.expect(folded.len != 0 and folded[0].collapsed);
        const side = try view.activeSide();
        const document = documents[@backingInt(side)];
        const hidden = if (side == .a) folded[0].a else folded[0].b;
        const byte = (try document.line(hidden.start)).start;
        _ = try document.setSelection(.{ .anchor = byte, .caret = byte });
        const hidden_cursor = try view.cursor();
        try std.testing.expectEqual(hidden.start, hidden_cursor.line);
        try fixture.expected(); // Source queries do not need a visible caret cell.
        _ = try view.scrollBy(1000);
        try std.testing.expectEqual(hidden_cursor, try view.cursor());
        try fixture.expected();
        try view.setContext(null);
        try view.prepare(bounds, fixture.parameters);
    }
    const pairs = [_]struct { a: []const u8, b: []const u8 }{
        .{ .a = "", .b = "" },                     .{ .a = "", .b = "x" },           .{ .a = "x", .b = "" },
        .{ .a = "a\nb\nc", .b = "a\nb" },          .{ .a = "a\nb", .b = "a\nb\nc" }, .{ .a = "a\nb\nc\n", .b = "a\nb\n" },
        .{ .a = "a\r\nB\r\n", .b = "a\r\nb\r\n" },
    };
    for (pairs) |pair| {
        try fixture.sources(pair.a, pair.b);
        for ([_]viewing.Side{ .a, .b }) |side| {
            if (mode == .unified and side == .a) continue;
            try view.focus(side);
            const document = documents[@backingInt(side)];
            for (0..try document.byteLength() + 1) |byte| {
                _ = try document.setSelection(.{ .anchor = byte, .caret = byte });
                try fixture.expected();
            }
            try view.prepare(bounds, fixture.parameters);
        }
    }
    try documents[1].replace(.{ .start = 0, .end = 0 }, "changed");
    _ = try view.cursor();
    try std.testing.expectError(error.ComparisonRequired, view.currentHunk());
    try inbox.stop();
    try std.testing.expectError(error.Closed, view.activeSide());
    try std.testing.expectError(error.Closed, view.cursor());
    try std.testing.expectError(error.Closed, view.currentHunk());
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expectError(error.Closed, view.cursor());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = text.resourceCounts();
    try run(debug.allocator(), .split);
    try run(debug.allocator(), .unified);
    try std.testing.expectEqual(before, text.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("diff caret: split/unified real source/primary/UTF16/EOF, last active/blur, ghost versus selected hunk, no-alloc queries, IME/stale/stop/close and resources=0 passed\n", .{});
}
