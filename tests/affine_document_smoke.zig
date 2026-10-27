const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const code = @import("ziggurat_code_editor");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
extern fn zlg_test_surrounding(*anyopaque, [*]u8, usize, *usize, *usize) c_int;
extern fn zlg_test_delete_surrounding(*anyopaque, c_int, c_int) c_int;
extern fn zlg_resource_count() u32;

const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 90 };
const source: ui.layout.Size = .{ .width = 200, .height = 110 };
const ReentrantAllocator = struct {
    backing: std.mem.Allocator,
    state: ?*State = null,
    armed: bool = false,
    fired: bool = false,
    close_window: bool = false,
    quit_app: bool = false,
    mutate_document: ?*d.Document = null,
    free_document: ?*d.Document = null,
    free_after: u64 = 0,
    free_fired: bool = false,
    fn allocator(self: *ReentrantAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *ReentrantAllocator = @ptrCast(@alignCast(ptr));
        if (self.armed) {
            self.armed = false;
            self.fired = true;
            const state = self.state.?;
            if (self.mutate_document) |document| {
                document.replace(.{ .start = 0, .end = 0 }, "R") catch @panic("reentrant document edit failed");
            } else if (self.quit_app) {
                state.window.app.quit();
                std.debug.assert(!state.window.isClosed());
            } else if (self.close_window) {
                std.debug.assert((state.window.destroy() catch unreachable) == .deferred);
            } else {
                state.plain = true;
                state.paint() catch @panic("reentrant plain frame failed");
            }
        }
        return self.backing.rawAlloc(len, alignment, address);
    }
    fn resize(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *ReentrantAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.rawResize(bytes, alignment, len, address);
    }
    fn remap(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *ReentrantAllocator = @ptrCast(@alignCast(ptr));
        return self.backing.rawRemap(bytes, alignment, len, address);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *ReentrantAllocator = @ptrCast(@alignCast(ptr));
        self.backing.rawFree(bytes, alignment, address);
        if (self.free_document) |document| if ((document.version() catch unreachable) > self.free_after) {
            self.free_document = null;
            self.free_fired = true;
            document.replace(.{ .start = 0, .end = 0 }, "F") catch @panic("post-commit document edit failed");
        };
    }
};
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    adapter: *editing.Adapter,
    presenter: ?*code.Presenter = null,
    parameters: editing.Parameters = .{ .font = .{ .size = 18, .width = bounds.width } },
    transform: ui.affine.Affine = .{ .xx = 0.8, .yx = 0.6, .xy = -0.6, .yy = 0.8, .x0 = 85, .y0 = 12 },
    fail_frame: bool = false,
    plain: bool = false,
    omit_space: bool = false,
    binding_ready: bool = false,
    failure: ?anyerror = null,
    paint_error: ?anyerror = null,
    closed: usize = 0,
    phases: [2]usize = .{ 0, 0 },
    unbound: usize = 0,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.operation == .paint) self.paint_error = value.err;
    }
    fn query(_: *anyopaque, _: z.Window, _: usize, _: isize) ?isize {
        return null;
    }
    fn phase(ptr: *anyopaque, _: z.Window, value: ui.AccessibilityPhase) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.phases[@backingInt(value)] += 1;
        if (value == .committed and self.binding_ready and !self.plain and !self.omit_space) self.adapter.syncNativeCaret() catch |err| {
            self.failure = err;
        };
    }
    fn released(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.unbound += 1;
    }
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.closed += 1;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        if (self.plain) return;
        try frame.beginTransform(source, self.transform);
        if (!self.omit_space) try frame.captureSpace(90, bounds);
        if (self.presenter) |presenter| try presenter.draw(frame, bounds, .{}) else try self.adapter.draw(frame, bounds, .{});
        try frame.endTransform();
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (event) {
            .text_input, .key_input, .text_preedit, .text_preedit_cancel => {},
            else => return false,
        }
        const token = self.context.committedSpace(90) catch |err| {
            self.failure = err;
            return true;
        };
        const mapped = token.mapEvent(event, .{}) catch |err| {
            self.failure = err;
            return true;
        };
        return if (self.presenter) |presenter| presenter.handleEvent(mapped, bounds, self.parameters) catch |err| {
            self.failure = err;
            return true;
        } else self.adapter.handleEvent(self.window, mapped, bounds, self.parameters) catch |err| {
            self.failure = err;
            return true;
        };
    }
    fn native(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn prepare(self: *State) !void {
        if (self.presenter) |presenter| try presenter.prepare(bounds, self.parameters) else _ = try self.adapter.prepare(bounds, self.parameters);
    }
    fn paint(self: *State) !void {
        self.paint_error = null;
        if (builtin.os.tag == .windows) {
            _ = c.InvalidateRect(self.window.nativeHandle(), null, 0);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const size = try self.window.contentSize();
            // GTK allocations use logical pixels; contentSize is physical.
            const factor: u32 = @intFromFloat(size.scale);
            std.debug.assert(factor != 0 and size.width % factor == 0 and size.height % factor == 0);
            zlg_test_paint(self.native(), size.width / factor, size.height / factor);
        }
        if (self.failure) |err| return err;
        if (!self.fail_frame) if (self.paint_error) |err| return err;
    }
    fn nativeProbe(self: *State) !void {
        if (builtin.os.tag == .windows) {
            const hwnd: c.HWND = self.window.nativeHandle();
            const im = c.ImmCreateContext() orelse return error.InputContextUnavailable;
            const previous = c.ImmAssociateContext(hwnd, im);
            defer {
                _ = c.ImmAssociateContext(hwnd, previous);
                std.debug.assert(c.ImmDestroyContext(im) != 0);
            }
            try self.adapter.syncNativeCaret();
            const token = try self.context.committedSpace(90);
            const caret = try self.adapter.caretRect(bounds, self.parameters.scale);
            const expected = try token.windowBounds(caret);
            var composition = std.mem.zeroes(c.COMPOSITIONFORM);
            try std.testing.expect(c.ImmGetCompositionWindow(im, &composition) != 0);
            const scale = self.parameters.scale;
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(expected.x * scale)), composition.ptCurrentPos.x);
            try std.testing.expectEqual(@as(c.LONG, @intFromFloat(expected.y * scale)) + @as(c.LONG, @intFromFloat(expected.height * scale)), composition.ptCurrentPos.y);
            const needed = c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, 0);
            try std.testing.expect(needed >= @sizeOf(c.RECONVERTSTRING));
            var storage: [2048]u8 align(4) = @splat(0);
            const reconvert: *c.RECONVERTSTRING = @ptrCast(@alignCast(&storage));
            reconvert.dwSize = storage.len;
            try std.testing.expectEqual(needed, c.SendMessageW(hwnd, c.WM_IME_REQUEST, c.IMR_RECONVERTSTRING, @bitCast(@intFromPtr(reconvert))));
            try std.testing.expect(reconvert.dwStrLen > 0);
        } else {
            var text: [2048]u8 = undefined;
            var length: usize = 0;
            var cursor: usize = 0;
            try std.testing.expect(zlg_test_surrounding(self.native(), &text, text.len, &length, &cursor) != 0);
            try std.testing.expect(length > 0 and cursor <= length);
            try self.adapter.syncNativeCaret();
        }
    }
};
fn run(allocator: std.mem.Allocator, use_code: bool, quit_app: bool) !void {
    var document_reentrant: ReentrantAllocator = .{ .backing = allocator };
    const document = try d.Document.create(document_reentrant.allocator(), std.Thread.getCurrentId(), "abc 😀\nsecond", .{});
    defer document.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var reentrant: ReentrantAllocator = .{ .backing = allocator };
    const adapter = try editing.Adapter.create(reentrant.allocator(), document, engine, .{ .metadata_history = 0 });
    defer adapter.close() catch unreachable;
    const broker = try code.Broker.create(allocator, document, .{});
    defer broker.close() catch unreachable;
    var state: State = .{ .adapter = adapter };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    reentrant.state = &state;
    document_reentrant.state = &state;
    state.window = try app.createWindow(.{ .width = 300, .height = 230, .on_closed = .{ .context = &state, .notify = State.onClosed } });
    defer {
        _ = state.window.destroy() catch {};
        app.dispatch() catch unreachable;
    }
    state.parameters.scale = (try state.window.contentSize()).scale;
    const presenter = if (use_code) try code.Presenter.create(allocator, broker, adapter, engine, state.window, .{}) else null;
    defer if (presenter) |value| value.close() catch unreachable;
    state.presenter = presenter;
    _ = try adapter.setSelection(.{ .anchor = 1, .caret = 1 }, .downstream);
    try state.prepare();
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    const options: ui.layers.TransformOptions = .{ .layers = .{ .size = try state.window.contentSize(), .max_depth = 4 }, .source_size = source };
    try state.context.prepareTransforms(allocator, options);
    try adapter.bind(state.window);
    defer adapter.unbind() catch unreachable;
    _ = try state.context.installAccessibilitySource(.{ .context = &state, .query = State.query, .phase = State.phase, .unbound = State.released });
    try state.paint();
    const original = try state.context.committedSpace(90);
    try adapter.setCommittedSpace(original);
    state.binding_ready = true;
    try std.testing.expect(try adapter.hasCommittedSpace());
    try state.nativeProbe();
    const batch_edits = [_]d.Replacement{.{ .range = .{ .start = 0, .end = 1 }, .text = "XX" }};
    const final_selected = [_]d.Selection{.{ .anchor = 1, .caret = 2 }};
    const batch_revision = try document.version();
    const batch_before = try adapter.stats();
    var allocation_checks: usize = 0;
    while (allocation_checks < 64) : (allocation_checks += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = allocation_checks });
        reentrant.backing = failing.allocator();
        const result = adapter.replaceManyWithSelections(batch_revision, &batch_edits, &final_selected, 0);
        reentrant.backing = allocator;
        if (result) |changed| {
            try std.testing.expect(changed.changed and !changed.index_required);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(batch_revision, try document.version());
            try std.testing.expectEqual(batch_before.owned_bytes, (try adapter.stats()).owned_bytes);
        }
    }
    try std.testing.expect(allocation_checks > 0 and allocation_checks < 64);
    try std.testing.expectEqualDeep(final_selected[0], try document.selection());
    _ = try adapter.undo();
    try std.testing.expectEqualDeep(d.Selection{ .anchor = 1, .caret = 1 }, try document.selection());
    _ = try adapter.redo();
    try std.testing.expectEqualDeep(final_selected[0], try document.selection());
    _ = try adapter.undo();
    try state.prepare();
    const stale_revision = try document.version();
    reentrant.mutate_document = document;
    reentrant.armed = true;
    try std.testing.expectError(error.StaleRevision, adapter.replaceManyWithSelections(stale_revision, &batch_edits, &final_selected, 0));
    reentrant.mutate_document = null;
    try std.testing.expectEqual(stale_revision + 1, try document.version());
    _ = try adapter.undo();
    try state.prepare();
    try state.paint();
    for ([_]bool{ false, true }) |batch| {
        const before_cleanup = try document.version();
        reentrant.free_after = before_cleanup;
        reentrant.free_fired = false;
        reentrant.free_document = document;
        const changed = if (batch) try adapter.replaceManyWithSelections(before_cleanup, &batch_edits, &final_selected, 0) else try adapter.replace(.{ .start = 0, .end = 1 }, "XX");
        try std.testing.expect(reentrant.free_fired and changed.changed and changed.index_required);
        try std.testing.expectEqual(before_cleanup + 2, try document.version());
        try std.testing.expect((try adapter.status()).index_required);
        _ = try adapter.undo();
        _ = try adapter.undo();
        try state.prepare();
        try state.paint();
    }
    const before_reentry = try document.version();
    const selected_reentry = try document.selection();
    reentrant.armed = true;
    try std.testing.expectError(error.SpaceNotFound, state.window.changeTextClient(state.window.textClientToken().?, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "Q" } }));
    try std.testing.expect(reentrant.fired);
    try std.testing.expectEqual(before_reentry, try document.version());
    try std.testing.expectEqualDeep(selected_reentry, try document.selection());
    state.plain = false;
    try state.paint();
    if (builtin.os.tag == .windows) _ = c.SendMessageW(state.window.nativeHandle(), c.WM_UNICHAR, 0x4e2d, 0) else zlg_test_commit(state.native(), "中");
    if (state.failure) |err| return err;
    var text: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a中bc 😀\nsecond", text[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &text)]);
    try state.paint();
    try std.testing.expectError(error.StaleSpace, adapter.setCommittedSpace(original));
    try state.nativeProbe();
    const text_token = state.window.textClientToken().?;
    _ = try state.window.changeTextClient(text_token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "Z" } });
    try state.prepare();
    try state.paint();
    const accepted = try state.context.committedSpace(90);
    const old_bounds = try accepted.windowBounds(bounds);
    const commits = state.phases[1];
    state.fail_frame = true;
    state.transform.x0 += 15;
    try state.paint();
    try std.testing.expectEqual(commits, state.phases[1]);
    try state.nativeProbe();
    try std.testing.expectEqualDeep(old_bounds, try (try state.context.committedSpace(90)).windowBounds(bounds));
    state.fail_frame = false;
    try state.paint();
    try state.nativeProbe();
    state.omit_space = true;
    try state.paint();
    const revision = try document.version();
    const selection = try document.selection();
    try std.testing.expectError(error.SpaceNotFound, state.window.readTextClient(text_token, &text));
    try std.testing.expectError(error.SpaceNotFound, state.window.changeTextClient(text_token, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expectEqual(revision, try document.version());
    try std.testing.expectEqualDeep(selection, try document.selection());
    state.plain = true;
    try state.paint();
    try state.context.releaseTransforms();
    state.binding_ready = false;
    try state.context.prepareTransforms(allocator, options);
    state.plain = false;
    state.omit_space = false;
    try state.paint();
    try std.testing.expectError(error.StaleSpace, state.window.changeTextClient(text_token, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expectEqual(revision, try document.version());
    try adapter.setCommittedSpace(try state.context.committedSpace(90));
    try state.nativeProbe();
    document_reentrant.armed = true;
    const before_document_candidate = try document.version();
    const selected_document_candidate = try document.selection();
    try std.testing.expectError(error.SpaceNotFound, state.window.changeTextClient(text_token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "Q" } }));
    try std.testing.expect(document_reentrant.fired);
    try std.testing.expectEqual(before_document_candidate, try document.version());
    try std.testing.expectEqualDeep(selected_document_candidate, try document.selection());
    state.plain = false;
    try state.paint();
    {
        var input_scope = try adapter.beginNativeInput(state.window);
        defer input_scope.end();
        var nested = try adapter.beginNativeInput(state.window);
        nested.end();
        nested.end();
        document_reentrant.armed = true;
        document_reentrant.fired = false;
        try std.testing.expectError(error.SpaceNotFound, adapter.replaceManyWithSelections(before_document_candidate, &batch_edits, &final_selected, 0));
        try std.testing.expect(document_reentrant.fired);
        try std.testing.expectEqual(before_document_candidate, try document.version());
        try std.testing.expectEqualDeep(selected_document_candidate, try document.selection());
        try std.testing.expectError(error.SpaceNotFound, adapter.beginNativeInput(state.window));
        try adapter.clearCommittedSpace();
        try std.testing.expectError(error.StaleSpace, adapter.beginNativeInput(state.window));
        try std.testing.expectError(error.StaleSpace, adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream));
        try std.testing.expectEqual(before_document_candidate, try document.version());
    }
    state.plain = false;
    state.binding_ready = false;
    try state.paint();
    try adapter.setCommittedSpace(try state.context.committedSpace(90));
    state.binding_ready = true;
    const closing_allocator = if (use_code) &document_reentrant else &reentrant;
    closing_allocator.armed = true;
    closing_allocator.fired = false;
    closing_allocator.close_window = !quit_app;
    closing_allocator.quit_app = quit_app;
    try std.testing.expectError(error.Closed, state.window.changeTextClient(text_token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "Q" } }));
    try std.testing.expect(closing_allocator.fired);
    try std.testing.expectEqual(revision, try document.version());
    if (quit_app) {
        try std.testing.expectError(error.Closed, adapter.beginNativeInput(state.window));
        try app.finishShutdown();
    } else try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), state.closed);
    try std.testing.expectEqual(@as(usize, 1), state.unbound);
    try std.testing.expect(!(try adapter.hasCommittedSpace()) and !(try adapter.isBound()));
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const before = t.resourceCounts();
    try run(allocator.allocator(), false, false);
    try run(allocator.allocator(), true, false);
    try run(allocator.allocator(), true, true);
    try std.testing.expectEqualDeep(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("affine Document/CodeEditor passed: retained text read/change gates, native commit/reconversion or GTK surrounding, committed caret phases, failed frame/missing ID/recreated workspace/close; resources=0\n", .{});
}
