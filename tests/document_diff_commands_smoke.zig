const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const viewing = @import("ziggurat_document_diff_view");
const State = @import("document_diff_editable_smoke.zig").Harness(viewing.EditableSplit);
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn zlg_resource_count() c_uint;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 260 };
const sources = [_][]const u8{ "header\nold 😀 text\r\nshared\nlast", "header\nnew 文 text\r\nshared\nlast" };
const Scenario = enum { normal, document_disable, document_ime, adapter_edit, adapter_post_edit, presentation_oom, presentation_target_edit, presentation_peer_edit, presentation_close, document_close, document_quit, native_pre_disable, native_post_disable, native_post_quit };
const AllocationFailure = struct { domain: enum { document, adapter, presentation }, offset: usize };

const Life = struct {
    state: *State,
    live: bool = true,
    release_on_close: bool = false,
    engine: *text.Engine = undefined,
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Life = @ptrCast(@alignCast(ptr));
        if (!self.release_on_close) return;
        self.state.view.close() catch unreachable;
        for (self.state.adapters) |adapter| adapter.close() catch unreachable;
        self.engine.close() catch unreachable;
        self.live = false;
    }
};

const GateAllocator = struct {
    child: std.mem.Allocator,
    state: ?*State = null,
    document: ?*d.Document = null,
    peer: ?*d.Document = null,
    busy_adapter: ?*editing.Adapter = null,
    action: enum { none, disable, ime, edit, peer_edit, post_edit, close, quit, fail, post_disable, post_quit } = .none,
    revision: u64 = 0,
    wait_for_commit: bool = false,
    triggered: bool = false,
    allocations: usize = 0,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn trigger(self: *@This()) void {
        const action = self.action;
        self.action = .none;
        self.triggered = true;
        const state = self.state.?;
        var empty: [0]d.Selection = .{};
        var marker: u8 = 0;
        if (self.busy_adapter) |adapter| {
            std.testing.expectError(error.Busy, adapter.runCommand(.undo, .{ .expected_revision = self.revision, .context = &marker, .validate = noPolicy }, &empty)) catch unreachable;
        } else std.testing.expectError(error.Busy, state.view.run(.undo, &empty)) catch unreachable;
        switch (action) {
            .disable, .post_disable => state.window.perform(.disable) catch unreachable,
            .ime => self.peer.?.setComposition("候", .{ .anchor = 0, .caret = 0 }) catch unreachable,
            .edit, .post_edit => self.document.?.replace(.{ .start = 0, .end = 0 }, "external:") catch unreachable,
            .peer_edit => self.peer.?.replace(.{ .start = 0, .end = 0 }, "external:") catch unreachable,
            .close => _ = state.window.destroy() catch unreachable,
            .quit, .post_quit => state.window.app.quit(),
            .none, .fail => unreachable,
        }
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.allocations += 1;
        if (self.action != .none and self.action != .post_edit and self.action != .post_disable and self.action != .post_quit) {
            const eligible = if (self.wait_for_commit) (self.document.?.version() catch self.revision) != self.revision else true;
            if (eligible) {
                if (self.action == .fail) {
                    self.action = .none;
                    self.triggered = true;
                    return null;
                }
                self.trigger();
            }
        }
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.action == .post_edit or self.action == .post_disable or self.action == .post_quit) {
            const revision = self.document.?.version() catch self.revision;
            if (revision != self.revision) self.trigger();
        }
        self.child.rawFree(bytes, alignment, ra);
    }
};

fn expectText(document: *d.Document, expected: []const u8) !void {
    var bytes: [1024]u8 = undefined;
    const count = try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes);
    try std.testing.expectEqualStrings(expected, bytes[0..count]);
}
fn noPolicy(_: *anyopaque) !void {}

fn normal(state: *State, documents: [2]*d.Document, unified: ?*viewing.EditableUnified, doc_allocator: *GateAllocator, adapter_allocator: *GateAllocator) !void {
    var scratch: [16]d.Selection = undefined;
    const side: viewing.Side = if (unified == null) .a else .b;
    const at = @intFromEnum(side);
    try state.view.focus(side);
    var rows: [96]viewing.editable.Row = undefined;
    const presentation = try state.view.copyPresentation(&rows);
    try state.view.blurPresented(presentation.epoch);
    try std.testing.expect(state.window.textClientToken() == null);
    const selected = try state.view.run(.{ .set_selection = .{ .anchor = 0, .caret = 0 } }, &scratch);
    try std.testing.expect(selected.side == side and selected.selection_changed and !selected.text_changed and selected.changed);
    try std.testing.expect(state.window.textClientToken() == null and try state.view.activeSide() == side);
    const before = try documents[at].version();
    const inserted = if (unified) |surface| try surface.run(.{ .replace_selections = "!" }, &scratch) else try state.view.run(.{ .replace_selections = "!" }, &scratch);
    try std.testing.expect(inserted.text_changed and inserted.selection_changed and inserted.changed and !inserted.stale_after_commit);
    try std.testing.expectEqual(@as(?u64, before + 1), inserted.committed_revision);
    try std.testing.expect(inserted.presentation_error == null);
    try expectText(documents[at], if (side == .a) "!" ++ sources[0] else "!" ++ sources[1]);
    try expectText(documents[1 - at], sources[1 - at]);
    const undone = try state.view.run(.undo, &scratch);
    try std.testing.expect(undone.text_changed and undone.changed);
    try expectText(documents[at], sources[at]);
    _ = try state.view.run(.redo, &scratch);
    _ = try state.view.run(.undo, &scratch);
    const all = try state.view.run(.select_all, &scratch);
    try std.testing.expect(all.selection_changed and !all.text_changed);
    try std.testing.expectEqual(d.Selection{ .anchor = 0, .caret = try documents[at].byteLength() }, try documents[at].selection());
    const same = try state.view.run(.select_all, &scratch);
    try std.testing.expect(!same.changed and same.committed_revision == null);
    // The command keeps Document's multiple selections and one text history.
    _ = try documents[at].setSelections(&.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 7, .caret = 7 } }, 1);
    const revision = try documents[at].version();
    const attempts = doc_allocator.allocations + adapter_allocator.allocations;
    try std.testing.expectError(error.SelectionCapacityExceeded, state.view.run(.undo, scratch[0..3]));
    try std.testing.expectEqual(attempts, doc_allocator.allocations + adapter_allocator.allocations);
    try std.testing.expectEqual(revision, try documents[at].version());
    const multi = try state.view.run(.{ .replace_selections = "X" }, &scratch);
    try std.testing.expect(multi.text_changed and multi.selection_changed and multi.committed_revision.? == revision + 1);
    _ = try state.view.run(.undo, &scratch);
    try expectText(documents[at], sources[at]);
    var selections: [4]d.Selection = undefined;
    const restored = try documents[at].selections(&selections);
    try std.testing.expectEqual(@as(usize, 2), restored.items.len);
    try std.testing.expectEqual(@as(usize, 1), restored.primary);
    try std.testing.expectEqual(d.Selection{ .anchor = 7, .caret = 7 }, restored.items[1]);
    const line = try documents[at].line(1);
    const scalar = line.start + (if (side == .a) @as(usize, 8) else 7);
    const reverse = try state.view.run(.{ .set_selection = .{ .anchor = line.end, .caret = scalar } }, &scratch);
    try std.testing.expect(reverse.selection_changed and !reverse.text_changed);
    const cursor = try state.view.cursor();
    try std.testing.expectEqual(try documents[at].utf16Offset(scalar) - try documents[at].utf16Offset(line.start), cursor.utf16_column);
    try std.testing.expectEqual(line.end, (try documents[at].selection()).anchor);
    try std.testing.expectError(error.InvalidRange, state.view.run(.{ .set_selection = .{ .anchor = 0, .caret = try documents[at].byteLength() + 1 } }, &scratch));
    try documents[1 - at].setComposition("候", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.CompositionActive, state.view.run(.undo, &scratch));
    _ = try documents[1 - at].cancelComposition();
    try state.window.perform(.disable);
    try std.testing.expectError(error.Disabled, state.view.run(.undo, &scratch));
    try state.window.perform(.enable);
    try state.refresh();
    try state.view.focus(side);
    // An existing native input gate composes with the command's owner gate,
    // rather than trying to install a second Document CommitGuard.
    var input = try state.adapters[at].beginNativeInput(state.window);
    var marker: u8 = 0;
    const nested = try state.adapters[at].runCommand(.{ .set_selection = .{ .anchor = 0, .caret = 0 } }, .{ .expected_revision = try documents[at].version(), .context = &marker, .validate = noPolicy }, &scratch);
    try std.testing.expect(nested.selection_changed and !nested.text_changed);
    input.end();
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    if (unified != null) {
        try std.testing.expectError(error.ReadOnlySource, state.view.focus(.a));
        try std.testing.expectEqual(viewing.Side.b, try state.view.activeSide());
    }
    try state.inbox.stop();
    try std.testing.expectError(error.Closed, state.view.run(.undo, &scratch));
}

fn runScenario(allocator: std.mem.Allocator, mode: viewing.editable.Mode, scenario: Scenario) !void {
    _ = runScenarioFailure(allocator, mode, scenario, null) catch |err| {
        std.debug.print("Diff command scenario {s}/{s} failed\n", .{ @tagName(mode), @tagName(scenario) });
        return err;
    };
}
fn runScenarioFailure(allocator: std.mem.Allocator, mode: viewing.editable.Mode, scenario: Scenario, failure: ?AllocationFailure) !bool {
    var document_failure = std.testing.FailingAllocator.init(allocator, .{});
    var adapter_failure = std.testing.FailingAllocator.init(allocator, .{});
    var document_allocator: GateAllocator = .{ .child = document_failure.allocator() };
    var adapter_allocator: GateAllocator = .{ .child = adapter_failure.allocator() };
    const a = try d.Document.create(document_allocator.allocator(), std.Thread.getCurrentId(), sources[0], .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(document_allocator.allocator(), std.Thread.getCurrentId(), sources[1], .{});
    defer b.close() catch unreachable;
    const documents = [2]*d.Document{ a, b };
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    var live = true;
    defer if (live) engine.close() catch unreachable;
    const native_case = scenario == .native_pre_disable or scenario == .native_post_disable or scenario == .native_post_quit;
    // No metadata receipts retain the old index in these direct cases, so the
    // committed operation must reclaim an old root before its final gate.
    const adapter_limits: editing.Limits = if (native_case) .{ .metadata_history = 0 } else .{};
    const adapter_a = try editing.Adapter.create(adapter_allocator.allocator(), a, engine, adapter_limits);
    defer if (live) adapter_a.close() catch unreachable;
    const adapter_b = try editing.Adapter.create(adapter_allocator.allocator(), b, engine, adapter_limits);
    defer if (live) adapter_b.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var state: State = .{ .inbox = inbox, .adapters = .{ adapter_a, adapter_b } };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    var life: Life = .{ .state = &state, .engine = engine, .release_on_close = scenario == .document_close or scenario == .presentation_close };
    state.window = try app.createWindow(.{ .width = 430, .height = 270, .on_closed = .{ .context = &life, .notify = Life.closed } });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .linux) @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?)) else @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var presentation_allocator: GateAllocator = .{ .child = failing.allocator(), .wait_for_commit = true };
    const unified = if (mode == .unified) try viewing.EditableUnified.create(presentation_allocator.allocator(), inbox, adapter_a, adapter_b, state.window, .{}) else null;
    state.view = if (unified) |surface| surface.coordinator() else try viewing.EditableSplit.create(presentation_allocator.allocator(), inbox, adapter_a, adapter_b, state.window, .{});
    defer if (life.live) state.view.close() catch unreachable;
    // on_closed may release all three native-text owners. The later defers only
    // inspect this independent flag and never touch the released objects.
    defer live = life.live;
    // Failure diagnostics must not skip native revocation. In particular quit
    // seals ordinary clearTextClient calls until finishShutdown owns teardown.
    defer {
        document_allocator.action = .none;
        adapter_allocator.action = .none;
        presentation_allocator.action = .none;
        if (app.phase == .stopping) app.finishShutdown() catch unreachable else {
            _ = state.window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
        }
    }
    try state.refresh();
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try state.paint();
    document_allocator.state = &state;
    document_allocator.document = b;
    document_allocator.peer = a;
    adapter_allocator.state = &state;
    adapter_allocator.document = b;
    presentation_allocator.state = &state;
    presentation_allocator.document = b;
    presentation_allocator.peer = a;
    var failed = false;
    if (failure) |injection| {
        try state.view.focus(.b);
        const original_selections = [_]d.Selection{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 7, .caret = 7 } };
        _ = try b.setSelections(&original_selections, 1);
        try state.view.prepare(bounds, state.parameters);
        var scratch: [4]d.Selection = undefined;
        const before = try b.version();
        const bytes_before = (try b.stats()).owned_bytes;
        const allocator_failure = switch (injection.domain) {
            .document => &document_failure,
            .adapter => &adapter_failure,
            .presentation => &failing,
        };
        allocator_failure.fail_index = allocator_failure.alloc_index + injection.offset;
        const result = state.view.run(if (injection.domain == .presentation) .select_all else .{ .replace_selections = "X" }, &scratch);
        failed = allocator_failure.has_induced_failure;
        allocator_failure.fail_index = std.math.maxInt(usize);
        if (result) |outcome| {
            try std.testing.expect(outcome.changed and outcome.committed_revision.? == before + 1);
            if (outcome.presentation_error) |err| try std.testing.expectEqual(error.OutOfMemory, err);
            if (injection.domain == .presentation) {
                try std.testing.expect(outcome.selection_changed and !outcome.text_changed);
                _ = try b.setSelections(&original_selections, 1);
            } else {
                try std.testing.expect(outcome.text_changed);
                _ = try state.view.run(.undo, &scratch);
            }
            try expectText(b, sources[1]);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(before, try b.version());
            try std.testing.expectEqual(bytes_before, (try b.stats()).owned_bytes);
            try expectText(b, sources[1]);
        }
        const selected = try b.selections(&scratch);
        try std.testing.expectEqual(@as(usize, 1), selected.primary);
        try std.testing.expectEqualSlices(d.Selection, &original_selections, selected.items);
    } else if (scenario == .native_pre_disable or scenario == .native_post_disable or scenario == .native_post_quit) {
        try state.view.focus(.b);
        var scratch: [4]d.Selection = undefined;
        _ = try state.view.run(.{ .set_selection = .{ .anchor = 0, .caret = 0 } }, &scratch);
        const before = try b.version();
        var input = try adapter_b.beginNativeInput(state.window);
        defer input.end();
        var marker: u8 = 0;
        document_allocator.busy_adapter = adapter_b;
        adapter_allocator.busy_adapter = adapter_b;
        document_allocator.action = if (scenario == .native_pre_disable) .disable else .none;
        adapter_allocator.revision = before;
        adapter_allocator.action = switch (scenario) {
            .native_post_disable => .post_disable,
            .native_post_quit => .post_quit,
            else => .none,
        };
        const result = adapter_b.runCommand(.{ .replace_selections = "command:" }, .{ .expected_revision = before, .context = &marker, .validate = noPolicy }, &scratch);
        document_allocator.action = .none;
        adapter_allocator.action = .none;
        if (scenario == .native_pre_disable) {
            try std.testing.expect(document_allocator.triggered);
            try std.testing.expectError(error.StaleTextClient, result);
            try std.testing.expectEqual(before, try b.version());
            try expectText(b, sources[1]);
        } else {
            const outcome = try result;
            try std.testing.expect(adapter_allocator.triggered and outcome.text_changed and outcome.stale_after_commit);
            try std.testing.expectEqual(@as(?u64, before + 1), outcome.committed_revision);
            const failure_value = outcome.post_commit_error orelse return error.ExpectedNativePostCommitFailure;
            try std.testing.expectEqual(if (scenario == .native_post_quit) error.Closed else error.StaleTextClient, failure_value);
            try std.testing.expectEqual((try adapter_b.status()).index_required, outcome.index_required);
            try expectText(b, "command:" ++ sources[1]);
        }
        if (scenario != .native_post_quit) try state.window.perform(.enable);
        input.end();
    } else if (scenario == .normal) {
        try normal(&state, documents, unified, &document_allocator, &adapter_allocator);
    } else {
        try state.view.focus(.b);
        var scratch: [4]d.Selection = undefined;
        _ = try state.view.run(.{ .set_selection = .{ .anchor = 0, .caret = 0 } }, &scratch);
        const before = try b.version();
        document_allocator.action = switch (scenario) {
            .document_disable => .disable,
            .document_ime => .ime,
            .document_close => .close,
            .document_quit => .quit,
            else => .none,
        };
        adapter_allocator.action = switch (scenario) {
            .adapter_edit => .edit,
            .adapter_post_edit => .post_edit,
            .presentation_target_edit => .edit,
            .presentation_peer_edit => .peer_edit,
            .presentation_close => .close,
            .presentation_oom => .fail,
            else => .none,
        };
        adapter_allocator.wait_for_commit = switch (scenario) {
            .presentation_oom, .presentation_target_edit, .presentation_peer_edit, .presentation_close => true,
            else => false,
        };
        adapter_allocator.peer = a;
        adapter_allocator.revision = before;
        const attempt = state.view.run(.{ .replace_selections = "command:" }, &scratch);
        document_allocator.action = .none;
        adapter_allocator.action = .none;
        presentation_allocator.action = .none;
        failing.fail_index = std.math.maxInt(usize);
        // Callback-scope exit schedules native teardown at the dispatcher safe
        // point. The closed notification can immediately free all text owners.
        if (scenario == .presentation_close or scenario == .document_close) try app.dispatch();
        switch (scenario) {
            .normal => unreachable,
            .adapter_post_edit, .presentation_oom, .presentation_target_edit, .presentation_peer_edit, .presentation_close => {
                const result = try attempt;
                try std.testing.expect(result.text_changed and result.changed and result.committed_revision.? == before + 1);
                if (scenario == .adapter_post_edit) {
                    try std.testing.expect(adapter_allocator.triggered and result.stale_after_commit and result.index_required and result.observed_revision == before + 2);
                    try expectText(b, "external:command:" ++ sources[1]);
                } else if (scenario == .presentation_oom) {
                    try std.testing.expect(adapter_allocator.triggered);
                    const error_value = result.presentation_error orelse return error.ExpectedPresentationFailure;
                    try std.testing.expectEqual(error.OutOfMemory, error_value);
                    try expectText(b, "command:" ++ sources[1]);
                } else {
                    try std.testing.expect(adapter_allocator.triggered and result.stale_after_commit);
                    if (scenario == .presentation_target_edit) {
                        try std.testing.expect(result.index_required and result.observed_revision == before + 2);
                        try expectText(b, "external:command:" ++ sources[1]);
                    } else if (scenario == .presentation_peer_edit) {
                        try std.testing.expectEqual(before + 1, result.observed_revision);
                        try expectText(a, "external:" ++ sources[0]);
                    } else {
                        try std.testing.expect(!life.live);
                        const error_value = result.presentation_error orelse return error.ExpectedPresentationFailure;
                        try std.testing.expectEqual(error.Closed, error_value);
                    }
                }
            },
            else => {
                const expected = switch (scenario) {
                    .document_disable => error.Disabled,
                    .document_ime, .adapter_edit => error.StaleRevision,
                    .document_close, .document_quit => error.Closed,
                    else => unreachable,
                };
                try std.testing.expectError(expected, attempt);
                if (scenario == .adapter_edit) {
                    try std.testing.expect(adapter_allocator.triggered);
                    try expectText(b, "external:" ++ sources[1]);
                } else {
                    try std.testing.expect(document_allocator.triggered);
                    try std.testing.expectEqual(before, try b.version());
                    try expectText(b, sources[1]);
                }
            },
        }
        if (scenario == .document_disable) try state.window.perform(.enable);
        if (scenario == .document_ime) _ = try a.cancelComposition();
        if (scenario == .document_close) try std.testing.expect(!life.live);
    }
    if (app.phase == .stopping) try app.finishShutdown() else {
        _ = try state.window.destroy();
        try app.dispatch();
    }
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    return failed;
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const counts = text.resourceCounts();
    try runScenario(debug.allocator(), .split, .normal);
    const gdi = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else 0;
    const user = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS) else 0;
    try runScenario(debug.allocator(), .unified, .normal);
    for ([_]Scenario{ .document_disable, .document_ime, .adapter_edit, .adapter_post_edit, .presentation_oom, .presentation_target_edit, .presentation_peer_edit, .presentation_close, .document_close, .document_quit, .native_pre_disable, .native_post_disable, .native_post_quit }) |scenario| try runScenario(debug.allocator(), .split, scenario);
    var allocation_failures: usize = 0;
    for (std.enums.values(@FieldType(AllocationFailure, "domain"))) |domain| {
        var offset: usize = 0;
        while (try runScenarioFailure(debug.allocator(), .split, .normal, .{ .domain = domain, .offset = offset })) : (offset += 1) {
            allocation_failures += 1;
            if (offset == 1024) return error.AllocationFailureSweepLimit;
        }
        try std.testing.expect(offset != 0);
    }
    try std.testing.expectEqualDeep(counts, text.resourceCounts());
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(gdi, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        try std.testing.expectEqual(user, c.GetGuiResources(c.GetCurrentProcess(), c.GR_USEROBJECTS));
    }
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(c_uint, 0), zlg_resource_count());
    std.debug.print("Diff commands: typed active source, exact text/selection outcomes, toolbar/unified/one undo/native gate, precommit reentry rejection and postcommit presentation/foreign-edit outcomes, allocation_failures={d}, resources=0\n", .{allocation_failures});
}
