const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const line = "abc 😀 אבג e\u{301}\r\n";
const prefix_length = 100000 * line.len;
const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 280, .height = 120 };
const State = struct {
    window: z.Window = undefined,
    adapter: *editing.Adapter,
    context: ui.Context = undefined,
    parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = 280 }, .estimated_height = 1 },
    failure: ?anyerror = null,
    expected_diagnostic: ?anyerror = null,
    paints: usize = 0,
    failed_frame: bool = false,
    close_frame: bool = false,
    fold_clicks: usize = 0,
    fold_input: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (value.err) |actual| {
            if (self.expected_diagnostic) |expected| {
                if (actual != expected) self.failure = actual;
            } else self.failure = actual;
        } else if (self.expected_diagnostic != null) self.failure = error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        self.paints += 1;
        frame.clear(0xffffff);
        try self.adapter.draw(frame, bounds, .{});
        // Recorded drawing resources stay pinned until the whole Frame exits.
        try std.testing.expectError(error.ResourceInUse, self.adapter.prepare(bounds, self.parameters));
        if (self.failed_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_frame) {
            _ = try self.window.destroy();
            try std.testing.expectError(error.ClientAttached, self.adapter.close());
        }
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.fold_input and event == .pointer_down) {
            var headers: [32]editing.FoldHeaderMark = undefined;
            const marks = self.adapter.foldHeaders(&headers) catch |err| {
                self.failure = err;
                return true;
            };
            for (marks) |mark| if (mark.rect.contains(.{ .x = event.pointer_down.position.x, .y = event.pointer_down.position.y })) {
                _ = self.adapter.setFoldCollapsed(mark.id, !mark.collapsed) catch |err| {
                    self.failure = err;
                    return true;
                };
                _ = self.adapter.prepare(bounds, self.parameters) catch |err| {
                    self.failure = err;
                    return true;
                };
                self.fold_clicks += 1;
                self.window.invalidate();
                return true;
            };
        }
        return self.adapter.handleEvent(self.window, event, bounds, self.parameters) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else zlg_test_paint(self.native(), @intFromFloat(320 * self.parameters.scale), @intFromFloat(160 * self.parameters.scale));
        if (self.failure) |err| return err;
    }
    fn commit(self: *State, scalar: u32, utf8: [*:0]const u8) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_UNICHAR, scalar, 0) else zlg_test_commit(self.native(), utf8);
        if (self.failure) |err| return err;
    }
};
fn expectTail(document: *d.Document, expected: []const u8) !void {
    var bytes: [64]u8 = undefined;
    const length = try document.read(.{ .start = prefix_length, .end = try document.byteLength() }, &bytes);
    try std.testing.expectEqualStrings(expected, bytes[0..length]);
}
fn transactions(allocator: std.mem.Allocator) !void {
    var document_failing = std.testing.FailingAllocator.init(allocator, .{});
    const document = try d.Document.create(document_failing.allocator(), std.Thread.getCurrentId(), "a\r\nb\n", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    try std.testing.expectError(error.ClientAttached, document.close());
    _ = try adapter.prepare(bounds, .{});
    const old_extent = (try adapter.stats()).estimated_extent;
    try std.testing.expect(!(try adapter.prepare(bounds, .{ .estimated_height = 500 })).changed);
    try std.testing.expectEqual(old_extent, (try adapter.stats()).estimated_extent);
    const revision = try document.version();
    const old = try adapter.stats();
    document_failing.fail_index = document_failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.replace(.{ .start = 0, .end = 1 }, "changed\n"));
    try std.testing.expectEqual(revision, try document.version());
    try std.testing.expectEqual(old.nodes, (try adapter.stats()).nodes);
    try std.testing.expectEqual(old.owned_bytes, (try adapter.stats()).owned_bytes);
    document_failing.fail_index = std.math.maxInt(usize);
    _ = try adapter.replace(.{ .start = 0, .end = 1 }, "changed\n");
    try std.testing.expect((try adapter.stats()).estimated_extent > 900);
    // The document owns undo: missing metadata must not turn a completed undo
    // into a failed document edit, even if the following rebuild cannot allocate.
    failing.fail_index = failing.alloc_index;
    const undone = try adapter.undo();
    try std.testing.expect(undone.changed and undone.index_required);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("a\r\nb\n", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    const after_undo = try document.version();
    try std.testing.expectError(error.OutOfMemory, adapter.prepare(bounds, .{}));
    try std.testing.expectEqual(after_undo, try document.version());
    try std.testing.expect((try adapter.status()).index_required);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect((try adapter.prepare(bounds, .{})).index_rebuilt);
    try std.testing.expect((try adapter.redo()).changed);
    _ = try adapter.prepare(bounds, .{});
    try std.testing.expectEqualStrings("changed\n\r\nb\n", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    const ThreadCheck = struct {
        fn call(value: *editing.Adapter) void {
            std.debug.assert(if (value.stats()) |_| false else |err| err == error.WrongThread);
            std.debug.assert(if (value.close()) |_| false else |err| err == error.WrongThread);
        }
    };
    const thread = try std.Thread.spawn(.{}, ThreadCheck.call, .{adapter});
    thread.join();
    const bounded = try editing.Adapter.create(allocator, document, engine, .{ .bytes = 16384 });
    defer bounded.close() catch unreachable;
    const owned = (try bounded.stats()).owned_bytes;
    try document.replace(.{ .start = 0, .end = try document.byteLength() }, "x\n" ** 10000);
    try std.testing.expectError(error.CapacityExceeded, bounded.reindex());
    try std.testing.expectEqual(owned, (try bounded.stats()).owned_bytes);
    try std.testing.expect((try bounded.status()).index_required);
}
fn paragraphKeys(allocator: std.mem.Allocator) !void {
    const source = "aa\r\n" ** 100 ++ "end";
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = window.destroy() catch unreachable;
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = bounds.width } };
    _ = try adapter.setSelection(.{ .anchor = 200, .caret = 200 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    try std.testing.expect(try adapter.handleKey(window, .{ .key = .backspace }, bounds, parameters));
    var output: [source.len]u8 = undefined;
    try std.testing.expectEqualStrings(source[0..198] ++ source[200..], output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    _ = try adapter.undo();
    _ = try adapter.setSelection(.{ .anchor = 200, .caret = 200 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect(try adapter.handleKey(window, .{ .key = .up }, bounds, parameters));
    try std.testing.expectEqual(@as(usize, 196), (try document.selection()).caret);
    _ = try adapter.setSelection(.{ .anchor = 200, .caret = 200 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    const before_left = try adapter.caretRect(bounds, 1);
    try std.testing.expect(try adapter.handleKey(window, .{ .key = .left }, bounds, parameters));
    // At a hard CRLF, the preceding edge is before the separator.
    try std.testing.expectEqual(@as(usize, 198), (try document.selection()).caret);
    const after_left = try adapter.caretRect(bounds, 1);
    try std.testing.expect(after_left.y < before_left.y and after_left.x > before_left.x);
    _ = try adapter.setSelection(.{ .anchor = 198, .caret = 198 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect(try adapter.handleKey(window, .{ .key = .delete }, bounds, parameters));
    try std.testing.expectEqualStrings(source[0..198] ++ source[200..], output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
}
fn compositionAnchors(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "x", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = window.destroy() catch unreachable;
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = bounds.width } };
    _ = try adapter.prepare(bounds, parameters);
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    const many = "a\n" ** 80 ++ "z";
    _ = try adapter.handleEvent(window, .{ .text_preedit = .{ .text = many, .selection_start = many.len, .selection_end = many.len } }, bounds, parameters);
    _ = try adapter.handleEvent(window, .{ .text_preedit = .{ .text = "q", .selection_start = 1, .selection_end = 1 } }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1), (try adapter.stats()).paragraphs);
    _ = try adapter.handleEvent(window, .text_preedit_cancel, bounds, parameters);
    _ = try adapter.handleEvent(window, .{ .text_preedit = .{ .text = many, .selection_start = many.len, .selection_end = many.len } }, bounds, parameters);
    _ = try adapter.handleEvent(window, .{ .text_input = .{ .text = "committed", .producer = .application } }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1), (try adapter.stats()).paragraphs);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("xcommitted", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    _ = try adapter.handleEvent(window, .{ .text_preedit = .{ .text = many, .selection_start = many.len, .selection_end = many.len } }, bounds, parameters);
    _ = try adapter.handleEvent(window, .text_preedit_cancel, bounds, parameters);
    _ = try adapter.handleEvent(window, .{ .text_preedit = .{ .text = many, .selection_start = many.len, .selection_end = many.len } }, bounds, parameters);
    try adapter.unbind();
    try std.testing.expect(try document.composition() == null);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.undo()).changed);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqualStrings("x", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
}
fn horizontalReveal(allocator: std.mem.Allocator) !void {
    const source = "a" ** 2000;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .none } };
    _ = try adapter.prepare(bounds, parameters);
    const before = (try adapter.stats()).shaped_batches;
    try adapter.revealCaret();
    _ = try adapter.prepare(bounds, parameters);
    var caret = try adapter.caretRect(bounds, 1);
    try std.testing.expect(caret.x >= bounds.x and caret.x + caret.width <= bounds.x + bounds.width);
    try std.testing.expectEqual(before, (try adapter.stats()).shaped_batches);
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    caret = try adapter.caretRect(bounds, 1);
    try std.testing.expectEqual(bounds.x, caret.x);
    try std.testing.expectEqual(before, (try adapter.stats()).shaped_batches);
}
fn oracle(allocator: std.mem.Allocator) !void {
    const source = "a e\u{301} 😀\r\nאבג abc\nمرحبا لا\nहिन्दी क्ष\n👩‍👩‍👧‍👦 x\nlong words that wrap through several rows end\n";
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const font: t.Options = .{ .size = 18, .wrap = .word_character, .width = 97 };
    const reference = try engine.layout(source, font);
    defer reference.close() catch unreachable;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{ .history_entries = 0 });
    defer document.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{ .batch_rows = 1 });
    defer adapter.close() catch unreachable;
    const viewport: ui.Rect = .{ .x = 0, .y = 0, .width = 97, .height = 1024 };
    const parameters: editing.Parameters = .{ .font = font };
    _ = try adapter.prepare(viewport, parameters);
    const initial = try adapter.stats();
    const count = try reference.graphemeCount();
    for (0..count + 1) |at| for ([_]t.Affinity{ .upstream, .downstream }) |affinity| {
        const byte = try reference.graphemeByte(at);
        _ = try adapter.setSelection(.{ .anchor = byte, .caret = byte }, affinity);
        // Keep the differential viewport at the document origin. Some native
        // bidi caret edges extend past wrap width; reveal is checked separately.
        _ = try adapter.scrollBy(.{ .x = 1, .y = 0 });
        _ = try adapter.scrollBy(.{ .x = -1000000, .y = 0 });
        const prepared = try adapter.prepare(viewport, parameters);
        try std.testing.expectEqual(@as(usize, 0), prepared.shaped_batches);
        const actual = try adapter.caretRect(viewport, 1);
        const expected = try reference.caret(.{ .byte_offset = byte, .affinity = affinity });
        try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.0001);
        try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.0001);
        try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.0001);
        const point: ui.layout.Point = .{ .x = expected.x + 0.25, .y = expected.y + expected.height * 0.5 };
        const expected_hit = try reference.hitTest(.{ .x = point.x, .y = point.y });
        const actual_hit = try adapter.hitTest(viewport, point);
        try std.testing.expectEqualDeep(expected_hit.caret, actual_hit);
    };
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = source.len }, .downstream);
    _ = try adapter.prepare(viewport, parameters);
    var actual_storage: [512]ui.Rect = undefined;
    const actual = try adapter.selectionRects(&actual_storage);
    var expected_storage: [512]t.Rect = undefined;
    const expected = try reference.selectionRects(.{ .start = 0, .end = source.len }, &expected_storage);
    var at: usize = 0;
    for (expected) |rectangle| {
        const clipped = ui.layout.intersect(.{ .x = rectangle.x, .y = rectangle.y, .width = rectangle.width, .height = rectangle.height }, viewport);
        if (clipped.width <= 0 or clipped.height <= 0) continue;
        try std.testing.expect(at < actual.len);
        try std.testing.expectApproxEqAbs(clipped.x, actual[at].x, 0.0001);
        try std.testing.expectApproxEqAbs(clipped.y, actual[at].y, 0.0001);
        try std.testing.expectApproxEqAbs(clipped.width, actual[at].width, 0.0001);
        try std.testing.expectApproxEqAbs(clipped.height, actual[at].height, 0.0001);
        at += 1;
    }
    try std.testing.expectEqual(at, actual.len);
    try std.testing.expectEqual(initial.shaped_batches, (try adapter.stats()).shaped_batches);
}
fn multiNavigation(allocator: std.mem.Allocator) !void {
    const source = "abc\r\n" ** 3 ++ "abc";
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = window.destroy() catch unreachable;
    const viewport: ui.Rect = .{ .x = 8, .y = 8, .width = 280, .height = 48 };
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = 280 } };
    _ = try adapter.setSelections(&.{ .{ .anchor = 5, .caret = 5 }, .{ .anchor = 15, .caret = 15 } }, 1);
    _ = try adapter.prepare(viewport, parameters);
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    var selections: [4]d.Selection = undefined;
    _ = try adapter.handleKey(window, .{ .key = .left }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 3, .caret = 3 }, .{ .anchor = 13, .caret = 13 } }, (try document.selections(&selections)).items);
    _ = try adapter.handleKey(window, .{ .key = .left }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 2, .caret = 2 }, .{ .anchor = 12, .caret = 12 } }, (try document.selections(&selections)).items);
    _ = try adapter.handleKey(window, .{ .key = .home }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 10, .caret = 10 } }, (try document.selections(&selections)).items);
    _ = try adapter.handleKey(window, .{ .key = .end }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 3, .caret = 3 }, .{ .anchor = 13, .caret = 13 } }, (try document.selections(&selections)).items);
    _ = try adapter.handleKey(window, .{ .key = .delete }, viewport, parameters);
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abcabc\r\nabcabc", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    _ = try adapter.undo();
    _ = try adapter.prepare(viewport, parameters);
    _ = try adapter.handleKey(window, .{ .key = .down }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 8, .caret = 8 }, .{ .anchor = 18, .caret = 18 } }, (try document.selections(&selections)).items);
    _ = try adapter.handleKey(window, .{ .key = .up }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 3, .caret = 3 }, .{ .anchor = 13, .caret = 13 } }, (try document.selections(&selections)).items);
    _ = try adapter.setSelections(&.{ .{ .anchor = 5, .caret = 5 }, .{ .anchor = 15, .caret = 15 } }, 1);
    _ = try adapter.prepare(viewport, parameters);
    _ = try adapter.handleKey(window, .{ .key = .page_up }, viewport, parameters);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 10, .caret = 10 } }, (try document.selections(&selections)).items);
    _ = try adapter.setSelections(&.{ .{ .anchor = 5, .caret = 5 }, .{ .anchor = 15, .caret = 15 } }, 1);
    _ = try adapter.prepare(viewport, parameters);
    _ = try adapter.handleKey(window, .{ .key = .home, .modifiers = .{ .control = true, .shift = true } }, viewport, parameters);
    try std.testing.expectEqual(d.Selection{ .anchor = 15, .caret = 0 }, try document.selection());
}
fn multiEditor(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "aa 😀\r\nbb 中", .{});
    defer document.close() catch unreachable;
    var engine_failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try t.Engine.create(engine_failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    var state: State = .{ .adapter = adapter };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    _ = try adapter.setSelections(&.{ .{ .anchor = 0, .caret = 2 }, .{ .anchor = 11, .caret = 9 } }, 1);
    _ = try adapter.prepare(bounds, state.parameters);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    var carets: [4]editing.CaretMark = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try adapter.caretRects(&carets)).len);
    try state.paint();
    const revision = try document.version();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.replaceSelections("x"));
    try std.testing.expectEqual(revision, try document.version());
    failing.fail_index = std.math.maxInt(usize);
    engine_failing.fail_index = engine_failing.alloc_index;
    if (builtin.os.tag == .windows) _ = c.SendMessageW(state.window.nativeHandle(), c.WM_UNICHAR, 0x6587, 0) else zlg_test_commit(state.native(), "文");
    try std.testing.expectEqual(error.LayoutRequired, state.failure.?);
    var bytes: [128]u8 = undefined;
    try std.testing.expectEqualStrings("文 😀\r\n文 中", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    engine_failing.fail_index = std.math.maxInt(usize);
    state.failure = null;
    _ = try adapter.prepare(bounds, state.parameters);
    try state.paint();
    try std.testing.expectEqual(@as(usize, 2), (try adapter.caretRects(&carets)).len);
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, state.parameters);
    try std.testing.expectEqualStrings("aa 😀\r\nbb 中", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    _ = try adapter.handleEvent(state.window, .{ .text_preedit = .{ .text = "中文", .selection_start = 6, .selection_end = 6 } }, bounds, state.parameters);
    try state.paint();
    try state.commit(0x4e2d, "中");
    try std.testing.expectEqualStrings("中 😀\r\n中 中", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    _ = try adapter.handleKey(state.window, .{ .key = .backspace }, bounds, state.parameters);
    try std.testing.expectEqualStrings(" 😀\r\n 中", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, state.parameters);
    try std.testing.expectEqualStrings("中 😀\r\n中 中", bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try adapter.unbind();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn run(allocator: std.mem.Allocator) !void {
    const input = try allocator.alloc(u8, prefix_length + "a😀中bc".len);
    defer allocator.free(input);
    for (0..100000) |i| @memcpy(input[i * line.len ..][0..line.len], line);
    @memcpy(input[prefix_length..], "a😀中bc");
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), input, .{ .history_entries = 16 });
    defer document.close() catch unreachable;
    var engine_failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try t.Engine.create(engine_failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var adapter_failing = std.testing.FailingAllocator.init(allocator, .{});
    var timer = try std.time.Timer.start();
    const adapter = try editing.Adapter.create(adapter_failing.allocator(), document, engine, .{});
    const construct_ns = timer.lap();
    defer adapter.close() catch unreachable;
    const construct_stats = try adapter.stats();
    const construct_allocations = adapter_failing.alloc_index;
    _ = try adapter.replace(.{ .start = 0, .end = 1 }, "X\n");
    const edit_ns = timer.lap();
    const edit_stats = try adapter.stats();
    const edit_allocations = adapter_failing.alloc_index - construct_allocations;
    _ = try adapter.undo();
    std.debug.print("document-editor index: construct_ns={d} owned={d} nodes={d} allocations={d}; prefix_edit_ns={d} visited={d} scanned_rows={d} reclaimed={d} allocations={d}\n", .{ construct_ns, construct_stats.owned_bytes, construct_stats.nodes, construct_allocations, edit_ns, edit_stats.visited_nodes - construct_stats.visited_nodes, edit_stats.scanned_rows - construct_stats.scanned_rows, edit_stats.reclaimed_nodes - construct_stats.reclaimed_nodes, edit_allocations });
    var state: State = .{ .adapter = adapter };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    timer.reset();
    const initial = try adapter.prepare(bounds, state.parameters);
    std.debug.print("document-editor prepare: ns={d} owned={d} peak_reserved={d} shaped_batches={d} shaped_bytes={d}\n", .{ timer.read(), (try adapter.stats()).owned_bytes, (try adapter.stats()).reserved_peak_bytes, initial.shaped_batches, initial.shaped_bytes });
    try std.testing.expect(initial.shaped_bytes < 16384 and initial.shaped_batches < 5);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    try state.paint();
    const before = try adapter.stats();
    adapter_failing.fail_index = adapter_failing.alloc_index;
    try state.paint();
    const painted = try adapter.stats();
    try std.testing.expectEqual(before.shaped_batches, painted.shaped_batches);
    try std.testing.expectEqual(before.shaped_bytes, painted.shaped_bytes);
    try std.testing.expect(state.paints >= 2);
    const version_before = try document.version();
    try std.testing.expectError(error.OutOfMemory, adapter.replace(.{ .start = prefix_length, .end = prefix_length + 1 }, "X"));
    try std.testing.expectEqual(version_before, try document.version());
    try expectTail(document, "a😀中bc");
    adapter_failing.fail_index = std.math.maxInt(usize);
    // External changes are explicit: old views must be rejected before drawing.
    _ = try document.setSelection(.{ .anchor = prefix_length + 1, .caret = prefix_length + 8 });
    try std.testing.expect((try adapter.status()).index_required);
    try std.testing.expectError(error.IndexRequired, adapter.hitTest(bounds, .{ .x = 10, .y = 10 }));
    _ = try adapter.prepare(bounds, state.parameters);
    try adapter.revealCaret();
    _ = try adapter.prepare(bounds, state.parameters);
    const revealed = try adapter.caretRect(bounds, state.parameters.scale);
    try std.testing.expect(revealed.y >= bounds.y and revealed.y + revealed.height <= bounds.y + bounds.height);
    if (builtin.os.tag == .windows) {
        const needed = c.SendMessageW(state.window.nativeHandle(), c.WM_IME_REQUEST, c.IMR_DOCUMENTFEED, 0);
        try std.testing.expect(needed > 0);
    } else {
        var bytes: [12288]u8 = undefined;
        var length: usize = 0;
        var cursor: usize = 0;
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_surrounding(state.native(), &bytes, bytes.len, &length, &cursor));
        try std.testing.expect(length < prefix_length and cursor < length);
    }
    const version_before_layout_failure = try document.version();
    engine_failing.fail_index = engine_failing.alloc_index;
    if (builtin.os.tag == .windows) _ = c.SendMessageW(state.window.nativeHandle(), c.WM_UNICHAR, 0x6587, 0) else zlg_test_commit(state.native(), "文");
    try std.testing.expectEqual(error.LayoutRequired, state.failure.?);
    try std.testing.expectEqual(version_before_layout_failure + 1, try document.version());
    try std.testing.expectEqual(error.OutOfMemory, (try adapter.status()).last_layout_error.?);
    try expectTail(document, "a文bc");
    try std.testing.expectError(error.LayoutRequired, adapter.hitTest(bounds, .{ .x = 10, .y = 10 }));
    state.failure = null;
    engine_failing.fail_index = std.math.maxInt(usize);
    _ = try adapter.prepare(bounds, state.parameters);
    try expectTail(document, "a文bc");
    const caret = try adapter.caretRect(bounds, state.parameters.scale);
    try std.testing.expect(caret.y >= bounds.y and caret.y + caret.height <= bounds.y + bounds.height);
    try state.paint();
    try std.testing.expect((try adapter.undo()).changed);
    _ = try adapter.prepare(bounds, state.parameters);
    try expectTail(document, "a😀中bc");
    try std.testing.expect((try adapter.redo()).changed);
    _ = try adapter.prepare(bounds, state.parameters);
    try expectTail(document, "a文bc");
    // Newline edits preserve original LF/CRLF source mapping and one undo.
    _ = try adapter.replace(.{ .start = prefix_length + 1, .end = prefix_length + 4 }, "x\r\ny😀");
    _ = try adapter.prepare(bounds, state.parameters);
    try expectTail(document, "ax\r\ny😀bc");
    try std.testing.expect((try adapter.undo()).changed);
    _ = try adapter.prepare(bounds, state.parameters);
    try expectTail(document, "a文bc");
    _ = try adapter.handleKey(state.window, .{ .key = .left, .modifiers = .{ .shift = true } }, bounds, state.parameters);
    try std.testing.expectEqual(d.Range{ .start = prefix_length + 1, .end = prefix_length + 4 }, (try document.selection()).range());
    _ = try adapter.handleEvent(state.window, .{ .text_preedit = .{ .text = "中文", .selection_start = 0, .selection_end = 6 } }, bounds, state.parameters);
    try expectTail(document, "a文bc");
    try state.commit(0x4e2d, "中");
    try expectTail(document, "a中bc");
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(c_int, 1), zlg_test_delete_surrounding(state.native(), -1, 1));
        try expectTail(document, "abc");
        try std.testing.expect((try adapter.undo()).changed);
        _ = try adapter.prepare(bounds, state.parameters);
        try expectTail(document, "a中bc");
    }
    try state.paint();
    _ = try adapter.scrollBy(.{ .x = 0, .y = -100 });
    const scrolled = try adapter.prepare(bounds, state.parameters);
    try std.testing.expect(scrolled.shaped_bytes < 32768);
    try state.paint();
    // A failed Frame must release every prepared-text lease without publishing
    // a successful frame. A later prepare can close/replace the same resources.
    state.failed_frame = true;
    state.expected_diagnostic = error.InvalidGeometry;
    const frames = state.context.frames;
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    state.failed_frame = false;
    state.expected_diagnostic = null;
    _ = try adapter.prepare(bounds, state.parameters);
    try state.paint();
    _ = try adapter.handleEvent(state.window, .{ .text_preedit = .{ .text = "late", .selection_start = 4, .selection_end = 4 } }, bounds, state.parameters);
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try adapter.unbind();
    try std.testing.expect(try document.composition() == null);
    try expectTail(document, "a中bc");
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
fn clickFold(state: *State) !void {
    var headers: [4]editing.FoldHeaderMark = undefined;
    const header = (try state.adapter.foldHeaders(&headers))[0];
    const x = header.rect.x + 2;
    const y = header.rect.y + header.rect.height * 0.5;
    if (builtin.os.tag == .windows) {
        const xx: u32 = @intFromFloat(x * state.parameters.scale);
        const yy: u32 = @intFromFloat(y * state.parameters.scale);
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, @intCast(xx | (yy << 16)));
        _ = c.SendMessageW(state.window.nativeHandle(), c.WM_LBUTTONUP, 0, @intCast(xx | (yy << 16)));
    } else {
        const widget = gtk_bin_get_child(state.window.nativeHandle().?).?;
        for ([_]bool{ true, false }) |down| {
            const event = gdk_event_new(if (down) 4 else 7) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = if (down) 4 else 7, .window = if (gtk_widget_get_window(widget)) |value| g_object_ref(value) else null, .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = x, .y_root = y };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (down) @as([*:0]const u8, "button-press-event") else @as([*:0]const u8, "button-release-event"), native, &handled);
        }
    }
    if (state.failure) |err| return err;
}
fn foldedEditor(allocator: std.mem.Allocator) !void {
    const source = "h\n" ++ "x\n" ** 10000 ++ "tail";
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    var state: State = .{ .adapter = adapter, .fold_input = true };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    const definitions = [_]editing.Fold{ .{ .id = 1, .header = 0, .end = 20002, .collapsed = true }, .{ .id = 2, .header = 200, .end = 18000, .collapsed = true } };
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try adapter.setFolds(try document.version(), &definitions);
    try std.testing.expectEqual(@as(usize, 2), (try adapter.stats()).visible_paragraphs);
    const prepared = try adapter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 6), prepared.shaped_bytes);
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try adapter.bind(state.window);
    try state.paint();
    try clickFold(&state);
    try std.testing.expectEqual(@as(usize, 1), state.fold_clicks);
    var folds: [4]editing.Fold = undefined;
    const opened = try adapter.folds(&folds);
    try std.testing.expect(!opened[0].collapsed and opened[1].collapsed);
    try state.paint();
    try clickFold(&state);
    try std.testing.expectEqual(@as(usize, 2), state.fold_clicks);
    try std.testing.expectEqual(@as(usize, 2), (try adapter.stats()).visible_paragraphs);
    // Hidden native pointer focus can revoke the client; the host rebinds explicitly.
    try adapter.unbind();
    try adapter.bind(state.window);
    const before_move = try adapter.stats();
    try std.testing.expect(try adapter.handleKey(state.window, .{ .key = .down }, bounds, state.parameters));
    try std.testing.expectEqual(@as(usize, 20002), (try document.selection()).caret);
    try std.testing.expectEqual(before_move.shaped_bytes, (try adapter.stats()).shaped_bytes);
    _ = try adapter.setSelection(.{ .anchor = 400, .caret = 400 }, .downstream);
    const version = (try adapter.status()).fold_version;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.prepare(bounds, state.parameters));
    try std.testing.expectEqual(version, (try adapter.status()).fold_version);
    try std.testing.expectEqual(@as(usize, 2), (try adapter.stats()).visible_paragraphs);
    failing.fail_index = std.math.maxInt(usize);
    _ = try adapter.prepare(bounds, state.parameters);
    const expanded = try adapter.folds(&folds);
    try std.testing.expect(!expanded[0].collapsed and !expanded[1].collapsed);
    const caret = try adapter.caretRect(bounds, state.parameters.scale);
    try std.testing.expect(caret.y >= bounds.y and caret.y + caret.height <= bounds.y + bounds.height);
    const selected_revision = try document.version();
    try std.testing.expectError(error.CaretInsideFold, adapter.setFoldCollapsed(2, true));
    try std.testing.expectEqual(selected_revision, try document.version());
    _ = try adapter.replace(.{ .start = 402, .end = 402 }, "z\n");
    try std.testing.expectEqual(@as(usize, 20004), (try adapter.folds(&folds))[0].end);
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    _ = try adapter.prepare(bounds, state.parameters);
    _ = try adapter.setFoldCollapsed(2, true);
    _ = try adapter.setFoldCollapsed(1, true);
    _ = try adapter.prepare(bounds, state.parameters);
    failing.fail_index = failing.alloc_index;
    const undone = try adapter.undo();
    try std.testing.expect(undone.changed and !undone.index_required);
    const undo_revision = try document.version();
    try std.testing.expectError(error.OutOfMemory, adapter.prepare(bounds, state.parameters));
    try std.testing.expectEqual(undo_revision, try document.version());
    try std.testing.expect((try adapter.status()).folds_required);
    failing.fail_index = std.math.maxInt(usize);
    _ = try adapter.prepare(bounds, state.parameters);
    const restored = try adapter.folds(&folds);
    try std.testing.expectEqual(@as(usize, 20002), restored[0].end);
    try std.testing.expect(!restored[0].collapsed and !restored[1].collapsed);
    _ = try adapter.redo();
    _ = try adapter.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 20004), (try adapter.folds(&folds))[0].end);
    _ = try adapter.handleEvent(state.window, .{ .text_preedit = .{ .text = "a\nb\n", .selection_start = 4, .selection_end = 4 } }, bounds, state.parameters);
    _ = try adapter.handleEvent(state.window, .{ .text_preedit = .{ .text = "q", .selection_start = 1, .selection_end = 1 } }, bounds, state.parameters);
    _ = try adapter.handleEvent(state.window, .text_preedit_cancel, bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 20004), (try adapter.folds(&folds))[0].end);
    try state.paint();
    try document.replace(.{ .start = 0, .end = 0 }, "external\n");
    try std.testing.expectError(error.FoldIndexRequired, adapter.prepare(bounds, state.parameters));
    try adapter.setFolds(try document.version(), &.{});
    _ = try adapter.prepare(bounds, state.parameters);
    state.failed_frame = true;
    state.expected_diagnostic = error.InvalidGeometry;
    try state.paint();
    state.failed_frame = false;
    state.expected_diagnostic = null;
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try adapter.unbind();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

fn terminalFold(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "head\nbody", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 320, .height = 160 });
    defer _ = window.destroy() catch unreachable;
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character, .width = 280 } };
    _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try adapter.setFolds(try document.version(), &.{.{ .id = 1, .header = 0, .end = 9, .collapsed = true }});
    _ = try adapter.prepare(bounds, parameters);
    try adapter.bind(window);
    defer adapter.unbind() catch unreachable;
    _ = try adapter.handleKey(window, .{ .key = .end }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 4), (try document.selection()).caret);
    _ = try adapter.handleKey(window, .{ .key = .right }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 4), (try document.selection()).caret);
    _ = try adapter.handleKey(window, .{ .key = .down }, bounds, parameters);
    try std.testing.expectEqual(@as(usize, 4), (try document.selection()).caret);
    try std.testing.expectEqual(@as(usize, 1), (try adapter.stats()).visible_paragraphs);
    const hit = try adapter.hitTest(bounds, .{ .x = 270, .y = 110 });
    try std.testing.expectEqual(@as(usize, 4), hit.byte_offset);
    _ = try adapter.handleKey(window, .{ .key = .delete }, bounds, parameters);
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("headbody", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.stats()).folds);
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1), (try adapter.stats()).folds);
    // An edit endpoint in a hidden paragraph uses a bounded explicit probe;
    // ordinary viewport preparation still never shapes hidden body rows.
    _ = try adapter.replace(.{ .start = 9, .end = 9 }, "\ntail");
    _ = try adapter.setSelection(.{ .anchor = 10, .caret = 10 }, .downstream);
    _ = try adapter.prepare(bounds, parameters);
    try adapter.setFolds(try document.version(), &.{.{ .id = 2, .header = 0, .end = 10, .collapsed = true }});
    _ = try adapter.prepare(bounds, parameters);
    _ = try adapter.handleKey(window, .{ .key = .backspace }, bounds, parameters);
    try std.testing.expectEqualStrings("head\nbodytail", output[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &output)]);
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 1), (try adapter.stats()).folds);
    try std.testing.expectEqual(@as(usize, 2), (try adapter.stats()).visible_paragraphs);
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = t.resourceCounts();
    try transactions(debug.allocator());
    try compositionAnchors(debug.allocator());
    try horizontalReveal(debug.allocator());
    try paragraphKeys(debug.allocator());
    try terminalFold(debug.allocator());
    try foldedEditor(debug.allocator());
    try multiNavigation(debug.allocator());
    try multiEditor(debug.allocator());
    try run(debug.allocator());
    try oracle(debug.allocator());
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("document editor native passed: 100k paragraphs, bounded visible shaping, native input/undo/preedit, real Frame replay, scroll and failure/close resources=0\n", .{});
}
