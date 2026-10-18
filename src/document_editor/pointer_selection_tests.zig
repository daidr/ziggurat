const std = @import("std");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("root.zig");

// The test backend supplies raw operations, not hand-made public claims. Text
// Layout construction and word queries still use the real platform text SDK.
const Host = struct {
    app: *z.App = undefined,
    app_allocator: ?std.mem.Allocator = null,
    window: z.Window = undefined,
    document: *d.Document = undefined,
    engine: *t.Engine = undefined,
    adapter: *editing.Adapter = undefined,
    bounds: editing.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 150 },
    parameters: editing.Parameters = .{ .font = .{ .word_ranges = true, .size = 16 } },
    result: editing.PointerResult = .{ .handled = false },
    failure: ?anyerror = null,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    armed_duplicate: bool = false,
    duplicate: ?editing.PointerResult = null,
    qualified: bool = true,
    modifiers: z.KeyModifiers = .{},
    own_cancel: bool = true,

    fn init(self: *Host, text: []const u8, batch_rows: usize, enabled: bool) !void {
        self.engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
        errdefer self.engine.close() catch unreachable;
        self.document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), text, .{});
        errdefer self.document.close() catch unreachable;
        self.adapter = try editing.Adapter.create(std.testing.allocator, self.document, self.engine, .{ .batch_rows = batch_rows });
        errdefer self.adapter.close() catch unreachable;
        _ = try self.adapter.prepare(self.bounds, self.parameters);
        self.app = try z.App.init(self.app_allocator orelse std.testing.allocator);
        errdefer self.app.deinit();
        self.window = try self.app.createWindow(.{ .native_pointer_clicks = enabled });
        try self.window.setContent(.{ .context = self, .event = event, .detach = detach });
        try self.adapter.bind(self.window);
    }
    fn deinit(self: *Host) void {
        _ = self.window.destroy() catch unreachable;
        self.app.dispatch() catch unreachable;
        self.adapter.close() catch unreachable;
        self.app.deinit();
        self.document.close() catch unreachable;
        self.engine.close() catch unreachable;
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.receive(window, value) catch |err| {
            self.failure = err;
        };
    }
    fn detach(_: *anyopaque) void {}
    fn receive(self: *Host, window: z.Window, value: z.Event) !void {
        switch (value) {
            .pointer_down, .pointer_up, .pointer_move => {
                self.result = try self.adapter.handlePointerEvent(window, value, self.bounds, self.parameters);
                if (self.armed_duplicate and value == .pointer_down) {
                    self.armed_duplicate = false;
                    self.duplicate = try self.adapter.handlePointerEvent(window, value, self.bounds, self.parameters);
                }
            },
            else => _ = try self.adapter.handleEvent(window, value, self.bounds, self.parameters),
        }
    }
    fn point(self: *Host, text: []const u8, byte: usize) !z.Point {
        var font = self.parameters.font;
        if (font.wrap != .none) font.width = self.bounds.width;
        const layout = try self.engine.layout(text, font);
        defer layout.close() catch unreachable;
        const rect = try layout.caret(.{ .byte_offset = byte });
        return .{ .x = self.bounds.x + rect.x - self.scroll_x, .y = self.bounds.y + rect.y + rect.height * 0.5 - self.scroll_y };
    }
    fn down(self: *Host, point_value: z.Point, tick: u32) !void {
        const record = self.app.windows.get(self.window.key).?;
        const op = record.native.pointer_operation.advance();
        const timing: z.PointerClickTiming = .{ .tick_ms = tick, .position = .{ .x = point_value.x, .y = point_value.y, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -4, .max_x = 4, .min_y = -4, .max_y = 4 } };
        const down_value = record.pointerBeginDown(op, .primary, if (self.qualified) timing else null).?;
        record.emitPointer(op, down_value.press.sequence, .down, .{ .position = point_value, .modifiers = self.modifiers });
        _ = record.pointerFinish(op, down_value.press.sequence, .primary, .down, .delivered);
        if (self.failure) |err| return err;
    }
    fn up(self: *Host, point_value: z.Point) !void {
        const record = self.app.windows.get(self.window.key).?;
        const op = record.native.pointer_operation.advance();
        const up_value = record.pointerBeginUp(op, .primary).?;
        record.emitPointer(op, up_value.press.sequence, .up, .{ .position = point_value, .modifiers = self.modifiers });
        if (self.own_cancel) record.emitPointerCancel(op, up_value.press.sequence, .primary);
        _ = record.pointerFinish(op, up_value.press.sequence, .primary, .up, .delivered);
        if (self.failure) |err| return err;
    }
    fn secondaryPair(self: *Host, point_value: z.Point, route_down: bool) !void {
        const record = self.app.windows.get(self.window.key).?;
        const down_op = record.native.pointer_operation.advance();
        const down_value = record.pointerBeginDown(down_op, .secondary, null).?;
        if (route_down) record.emitPointer(down_op, down_value.press.sequence, .down, .{ .position = point_value, .button = .secondary });
        // Either the editor or its host sees this genuine other-button down.
        // Its later up remains an authentic per-button native transition.
        _ = record.pointerFinish(down_op, down_value.press.sequence, .secondary, .down, if (route_down) .delivered else .consumed);
        const up_op = record.native.pointer_operation.advance();
        const up_value = record.pointerBeginUp(up_op, .secondary).?;
        record.emitPointer(up_op, up_value.press.sequence, .up, .{ .position = point_value, .button = .secondary });
        _ = record.pointerFinish(up_op, up_value.press.sequence, .secondary, .up, .delivered);
        if (self.failure) |err| return err;
    }
    fn move(self: *Host, point_value: z.Point) !void {
        const record = self.app.windows.get(self.window.key).?;
        record.pointerMotion(record.pointerOperation(), .{ .x = point_value.x, .y = point_value.y, .domain = 1 });
        record.emit(.{ .pointer_move = point_value });
        if (self.failure) |err| return err;
    }
    fn pair(self: *Host, point_value: z.Point, tick: u32) !void {
        try self.down(point_value, tick);
        try self.accepted();
        try self.up(point_value);
        try self.accepted();
    }
    fn accepted(self: *Host) !void {
        if (self.result.input_error) |err| return err;
        if (self.result.presentation_error) |err| return err;
        try std.testing.expect(self.result.handled and self.result.selection_committed);
    }
    fn selected(self: *Host, anchor: usize, caret: usize) !void {
        try std.testing.expectEqualDeep(d.Selection{ .anchor = anchor, .caret = caret }, try self.document.selection());
    }
};

test "Document primary down selects caret word logical CRLF row then caret across batch sizes" {
    const source = "alpha beta!\r\n\nlast";
    for ([_]usize{ 1, 32 }) |rows| {
        var host: Host = .{};
        try host.init(source, rows, true);
        defer host.deinit();
        try host.adapter.preparePointerSelection(host.window);
        const point = try host.point(source, 2);
        for ([_]d.Selection{ .{ .anchor = 2, .caret = 2 }, .{ .anchor = 0, .caret = 5 }, .{ .anchor = 0, .caret = 13 }, .{ .anchor = 2, .caret = 2 } }, 0..) |expected, at| {
            try host.down(point, @intCast(20 * at));
            try host.accepted();
            try std.testing.expectEqualDeep(expected, try host.document.selection());
            try host.up(point);
            try host.accepted();
            try std.testing.expectEqualDeep(expected, try host.document.selection());
        }
    }
}
test "Document word and logical row use complete text and word gaps clamp at paragraph content" {
    const source = "alpha beta gamma delta\r\n \r\n\nlast";
    for ([_]usize{ 1, 32 }) |rows| {
        var host: Host = .{ .bounds = .{ .x = 8, .y = 8, .width = 55, .height = 180 }, .parameters = .{ .font = .{ .word_ranges = true, .size = 16, .wrap = .word_character, .width = 55 } } };
        try host.init(source, rows, true);
        defer host.deinit();
        try host.adapter.preparePointerSelection(host.window);
        const point = try host.point(source, 2);
        try host.pair(point, 0);
        try host.pair(point, 20);
        try host.selected(0, 5);
        try host.pair(point, 40);
        try host.selected(0, 24);
        try host.adapter.clearPointerSelection();
        try host.adapter.preparePointerSelection(host.window);
        const space = try host.point(source, 24);
        try host.pair(space, 100);
        try host.pair(space, 120);
        try host.selected(24, 25);
        const empty = try host.point(source, 27);
        try host.pair(empty, 5000);
        try host.pair(empty, 5020);
        try host.selected(27, 27);
    }
}
test "Document double word drag reverses complete units and Shift extends the original anchor" {
    const source = "alpha beta!\r\nlast";
    var host: Host = .{};
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const beta = try host.point(source, 8);
    try host.pair(beta, 0);
    try host.down(beta, 20);
    try host.selected(6, 10);
    try host.move(try host.point(source, 2));
    try host.accepted();
    try host.selected(10, 0);
    try host.move(beta);
    try host.selected(6, 10);
    try host.up(beta);
    try host.accepted();
    host.modifiers.shift = true;
    try host.down(try host.point(source, 3), 40);
    try host.accepted();
    try host.selected(6, 3);
    try host.up(try host.point(source, 3));
    try host.accepted();
}
test "Document cleared old release is denied then fresh ordinary and reinstall never borrow a held pair" {
    const source = "alpha beta";
    var host: Host = .{};
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const point = try host.point(source, 2);
    try host.down(point, 0);
    try host.adapter.clearPointerSelection();
    try host.up(point);
    try std.testing.expect(host.result.handled and !host.result.selection_committed);
    try std.testing.expectEqual(error.StalePointerInput, host.result.input_error.?);
    try host.down(try host.point(source, 8), 20);
    try host.accepted();
    try host.selected(8, 8);
    try host.adapter.preparePointerSelection(host.window);
    try host.up(point);
    try std.testing.expect(!host.result.selection_committed);
    try host.pair(point, 40);
    try host.selected(2, 2);
    try host.pair(point, 60);
    try host.selected(0, 5);
}
test "Document duplicate receipt and unsupported new words parameters never fall back" {
    const source = "alpha beta";
    var host: Host = .{};
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    host.armed_duplicate = true;
    const point = try host.point(source, 2);
    try host.down(point, 0);
    try host.accepted();
    try std.testing.expectEqual(error.AlreadyClaimed, host.duplicate.?.input_error.?);
    try std.testing.expect(!host.duplicate.?.selection_committed);
    try host.up(point);
    host.parameters.font.word_ranges = false;
    try host.down(point, 20);
    try std.testing.expectEqual(error.WordRangesNotEnabled, host.result.input_error.?);
    try std.testing.expect(host.result.handled and !host.result.selection_committed);
    try host.selected(2, 2);
    host.parameters.font.word_ranges = true;
    try host.up(point);
    try std.testing.expect(!host.result.selection_committed);
    host.qualified = false;
    try host.pair(point, 40);
    try host.selected(2, 2);
}
test "Document explicit words and raw capability are checked without owner allocation" {
    var host: Host = .{};
    try host.init("alpha beta", 32, false);
    defer host.deinit();
    const before = try host.adapter.stats();
    try std.testing.expectError(error.UnsupportedCapability, host.adapter.preparePointerSelection(host.window));
    try std.testing.expectEqual(before.owned_bytes, (try host.adapter.stats()).owned_bytes);
    var plain = host.parameters;
    plain.font.word_ranges = false;
    _ = try host.adapter.prepare(host.bounds, plain);
    try std.testing.expectError(error.WordRangesNotEnabled, host.adapter.preparePointerSelection(host.window));
}

test "Document words use complete hit coordinates after fractional horizontal scrolling" {
    const source = "alpha beta gamma delta";
    var host: Host = .{ .bounds = .{ .x = 8.25, .y = 8.375, .width = 75, .height = 40 } };
    try host.init(source, 32, true);
    defer host.deinit();
    _ = try host.adapter.scrollBy(.{ .x = 30.375, .y = 0 });
    host.scroll_x = 30.375;
    _ = try host.adapter.prepare(host.bounds, host.parameters);
    try host.adapter.preparePointerSelection(host.window);
    const point = try host.point(source, 8);
    try host.pair(point, 0);
    try host.selected(8, 8);
    try host.pair(point, 20);
    try host.selected(6, 10);
    _ = try host.adapter.scrollBy(.{ .x = 1, .y = 0 });
    _ = try host.adapter.prepare(host.bounds, host.parameters);
    host.scroll_x += 1;
    try host.pair(try host.point(source, 8), 40);
    try host.selected(8, 8);
}
test "Document rejects a foreign Window before changing its current gesture" {
    const source = "alpha beta";
    var host: Host = .{};
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const point = try host.point(source, 2);
    try host.pair(point, 0);
    const other = try host.app.createWindow(.{});
    try std.testing.expectError(error.WrongWindow, host.adapter.handleEvent(other, .{ .focus = false }, host.bounds, host.parameters));
    _ = try other.destroy();
    try host.app.dispatch();
    try host.pair(point, 20);
    try host.selected(0, 5);
}
test "Document native issuer retirement does not lend an old App floor to a new binding" {
    const storage = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const source = "alpha beta";
    var host: Host = .{ .app_allocator = fixed.allocator() };
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const point = try host.point(source, 2);
    try host.pair(point, 0);
    const previous_address = @intFromPtr(host.app);
    const previous_key = host.window.key;
    _ = try host.window.destroy();
    try host.app.dispatch();
    try std.testing.expect(!(try host.adapter.isBound()));
    host.app.deinit();
    fixed.reset();
    host.app = try z.App.init(fixed.allocator());
    try std.testing.expectEqual(previous_address, @intFromPtr(host.app));
    host.window = try host.app.createWindow(.{ .native_pointer_clicks = true });
    try std.testing.expectEqualDeep(previous_key, host.window.key);
    try host.window.setContent(.{ .context = &host, .event = Host.event, .detach = Host.detach });
    try host.adapter.bind(host.window);
    try host.adapter.preparePointerSelection(host.window);
    try host.pair(point, 20);
    try host.selected(2, 2);
}
test "Document optional pointer owner is one bounded budget allocation retained through clear" {
    var host: Host = .{};
    try host.init("alpha beta", 32, true);
    defer host.deinit();
    const before = try host.adapter.stats();
    try host.adapter.preparePointerSelection(host.window);
    const allocated = try host.adapter.stats();
    const added = allocated.owned_bytes - before.owned_bytes;
    try std.testing.expect(added > 0 and added <= 4096);
    try host.adapter.clearPointerSelection();
    try std.testing.expectEqual(allocated.owned_bytes, (try host.adapter.stats()).owned_bytes);
    try host.adapter.preparePointerSelection(host.window);
    try std.testing.expectEqual(allocated.owned_bytes, (try host.adapter.stats()).owned_bytes);
    std.debug.print("Document pointer optional owner bytes={d} charged=one allocation; clear/reinstall retained\n", .{added});
}

test "cleared ordinary release ends dragging without a capture cancel notification" {
    const source = "alpha beta";
    var host: Host = .{ .own_cancel = false };
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    try host.adapter.clearPointerSelection();
    try host.pair(try host.point(source, 2), 0);
    try host.move(try host.point(source, 8));
    try std.testing.expect(!host.result.handled and !host.result.selection_committed);
    try host.selected(2, 2);
}

test "nonprimary release is unhandled and cannot take the current primary selection gesture" {
    const source = "alpha beta";
    var host: Host = .{};
    try host.init(source, 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const point = try host.point(source, 2);
    try host.down(point, 0);
    try host.accepted();
    try host.secondaryPair(point, false);
    try std.testing.expect(!host.result.handled and !host.result.selection_committed);
    try std.testing.expect(host.result.input_error == null and host.result.presentation_error == null);
    try host.selected(2, 2);
    try host.up(point);
    try host.accepted();
    try host.selected(2, 2);
}

test "an outside down and its matching release stay unhandled without selecting" {
    var host: Host = .{};
    try host.init("alpha beta", 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const before = try host.document.selection();
    const point: z.Point = .{ .x = -1, .y = -1 };
    try host.down(point, 0);
    try std.testing.expect(!host.result.handled and !host.result.selection_committed and host.result.input_error == null);
    try host.up(point);
    try std.testing.expect(!host.result.handled and !host.result.selection_committed and host.result.input_error == null);
    try std.testing.expectEqualDeep(before, try host.document.selection());
    try host.pair(try host.point("alpha beta", 2), 20);
    try host.selected(2, 2);
}

test "an outside primary pair remains unhandled across a routed secondary pair" {
    var host: Host = .{};
    try host.init("alpha beta", 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const before = try host.document.selection();
    const outside: z.Point = .{ .x = -1, .y = -1 };
    try host.down(outside, 0);
    try std.testing.expect(!host.result.handled and host.result.input_error == null);
    try host.secondaryPair(try host.point("alpha beta", 2), true);
    try std.testing.expect(!host.result.handled and host.result.input_error == null);
    try host.up(outside);
    try std.testing.expect(!host.result.handled and !host.result.selection_committed and host.result.input_error == null);
    try std.testing.expectEqualDeep(before, try host.document.selection());
}

test "an outside primary release remains unhandled after a programmatic selection" {
    var host: Host = .{};
    try host.init("alpha beta", 32, true);
    defer host.deinit();
    try host.adapter.preparePointerSelection(host.window);
    const outside: z.Point = .{ .x = -1, .y = -1 };
    try host.down(outside, 0);
    try std.testing.expect(!host.result.handled and host.result.input_error == null);
    _ = try host.adapter.setSelection(.{ .anchor = 1, .caret = 3 }, .downstream);
    try host.up(outside);
    try std.testing.expect(!host.result.handled and !host.result.selection_committed and host.result.input_error == null);
    try host.selected(1, 3);
    try host.pair(try host.point("alpha beta", 5), 20);
    try host.selected(5, 5);
}

test "cold pointer allocation close frees Adapter and host at the next native safe point" {
    const Observer = struct { closed: usize = 0 };
    const Heap = struct {
        source: std.mem.Allocator,
        adapter: *editing.Adapter,
        observer: *Observer,
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.observer.closed += 1;
            self.adapter.close() catch unreachable;
            const source = self.source;
            source.destroy(self);
        }
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn detach(_: *anyopaque) void {}
    };
    const Hook = struct {
        source: std.mem.Allocator,
        window: ?z.Window = null,
        armed: bool = false,
        hits: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const result = self.source.rawAlloc(len, alignment, ra);
            if (result != null and self.armed) {
                self.armed = false;
                self.hits += 1;
                _ = self.window.?.destroy() catch unreachable;
            }
            return result;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.source.rawFree(bytes, alignment, ra);
        }
    };
    var observer: Observer = .{};
    // The allocator context is independent of the heap host and covers every
    // foreign candidate free before and during the final Window scope end.
    var hook: Hook = .{ .source = std.testing.allocator };
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "alpha beta", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(std.testing.allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const adapter = try editing.Adapter.create(hook.allocator(), document, engine, .{});
    defer if (observer.closed == 0) adapter.close() catch unreachable;
    const heap = try std.testing.allocator.create(Heap);
    defer if (observer.closed == 0) std.testing.allocator.destroy(heap);
    heap.* = .{ .source = std.testing.allocator, .adapter = adapter, .observer = &observer };
    const window = try app.createWindow(.{ .native_pointer_clicks = true, .on_closed = .{ .context = heap, .notify = Heap.closed } });
    defer if (observer.closed == 0) {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    };
    try window.setContent(.{ .context = heap, .event = Heap.event, .detach = Heap.detach });
    _ = try adapter.prepare(.{ .x = 0, .y = 0, .width = 180, .height = 80 }, .{ .font = .{ .word_ranges = true } });
    try adapter.bind(window);
    hook.window = window;
    hook.armed = true;
    const result = adapter.preparePointerSelection(window);
    // The canceled allocation returns before the event-driven native safe
    // point. Its candidate is retired and no caller retries the operation.
    try std.testing.expectError(error.Closed, result);
    try std.testing.expectEqual(@as(usize, 1), hook.hits);
    try std.testing.expectEqual(@as(usize, 0), observer.closed);
    try app.dispatch();
    // on_closed immediately freed both objects; only the independent observer
    // and App may be read after dispatch has completed deferred destruction.
    try std.testing.expectEqual(@as(usize, 1), observer.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
