const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const text = "zero\none\ntwo\nthree\nfour\nfive\n";
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

const Trap = struct {
    source: std.mem.Allocator,
    window: ?z.Window = null,
    adapters: [2]*editing.Adapter = undefined,
    triggered: bool = false,
    mutate_on_alloc: ?*d.Document = null,
    fn allocator(self: *Trap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Trap = @ptrCast(@alignCast(ptr));
        const allocation = self.source.rawAlloc(size, alignment, ret) orelse return null;
        if (self.mutate_on_alloc) |document| {
            self.mutate_on_alloc = null;
            _ = document.replace(.{ .start = 0, .end = tryLength(document) }, "a much longer single line whose caret cannot be projected through the previous short paragraph root without checking its revision first") catch unreachable;
        }
        return allocation;
    }
    fn tryLength(document: *d.Document) usize {
        return document.byteLength() catch unreachable;
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
        const Entry = struct { fold: editing.Fold, first: usize, end: usize, parent: ?usize };
        if (bytes.len == @sizeOf(Entry)) if (self.window) |window| {
            self.window = null;
            self.triggered = true;
            for (self.adapters) |adapter| std.testing.expectError(error.Busy, adapter.status()) catch unreachable;
            _ = window.destroy() catch unreachable;
        };
        self.source.rawFree(bytes, alignment, ret);
    }
};
const Prepared = struct {
    adapters: [2]*editing.Adapter,
    revisions: [2]u64,
    range: d.Range,
    rectangles: [2][32]t.Rect = undefined,
    counts: [2]usize = @splat(0),
    positions: [2]?t.Rect = @splat(null),
    reject: bool = false,
    close_window: ?z.Window = null,
    compose: ?*d.Document = null,
    authority: bool = true,
    validations: usize = 0,
    fn validate(ptr: *anyopaque) !void {
        const self: *Prepared = @ptrCast(@alignCast(ptr));
        for (self.adapters) |adapter| try std.testing.expectError(error.Busy, adapter.status());
        self.validations += 1;
        if (!self.authority) return error.InputAuthorityLost;
    }
    fn build(_: *anyopaque, _: [2]*editing.LayoutProbe) !editing.PairProjection {
        return .{ .plans = @splat(null) };
    }
    fn complete(ptr: *anyopaque, probes: [2]*editing.PreparedProbe) !void {
        const self: *Prepared = @ptrCast(@alignCast(ptr));
        for (self.adapters, probes, self.revisions, &self.rectangles, &self.counts, &self.positions) |adapter, probe, revision, *rectangles, *count, *position| {
            try std.testing.expectError(error.Busy, adapter.status());
            count.* = (try probe.rangeRects(revision, self.range, rectangles)).len;
            position.* = try probe.positionRect(revision, 0, .downstream);
        }
        if (self.reject) return error.RejectedCandidate;
        if (self.compose) |document| {
            self.compose = null;
            try document.setComposition("short\noverlay", .{ .anchor = 0, .caret = 0 });
        }
        if (self.close_window) |window| {
            self.close_window = null;
            _ = try window.destroy();
        }
    }
};
pub fn run(allocator: std.mem.Allocator) !void {
    const before = t.resourceCounts();
    try transaction(allocator);
    try std.testing.expectEqual(before, t.resourceCounts());
}
fn transaction(allocator: std.mem.Allocator) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var trap: Trap = .{ .source = allocator };
    var failing: [2]std.testing.FailingAllocator = .{ .init(trap.allocator(), .{}), .init(allocator, .{}) };
    const adapters: [2]*editing.Adapter = .{ try editing.Adapter.create(failing[0].allocator(), a, engine, .{}), try editing.Adapter.create(failing[1].allocator(), b, engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    trap.adapters = adapters;
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = window.destroy() catch unreachable;
    const old_revision = try a.version();
    trap.mutate_on_alloc = a;
    try std.testing.expectError(error.StaleRevision, adapters[0].setFolds(old_revision, &.{.{ .id = 1, .header = 0, .end = (try a.line(5)).start }}));
    _ = try a.undo();
    try adapters[0].reindex();
    var tokens: [2]editing.FoldToken = .{ try adapters[0].reserveFolds(), try adapters[1].reserveFolds() };
    defer {
        for (adapters, tokens) |adapter, token| _ = adapter.releaseFolds(token) catch unreachable;
    }
    try std.testing.expectError(error.FoldOwnerAttached, adapters[0].close());
    try std.testing.expectError(error.FoldOwnerConflict, adapters[0].setFolds(try a.version(), &.{}));
    try std.testing.expectError(error.FoldOwnerConflict, adapters[1].setFoldCollapsed(1, true));
    const definitions: [2][1]editing.Fold = @splat(.{.{ .id = 1, .header = 0, .end = (try a.line(5)).start, .collapsed = true }});
    var bad = definitions;
    bad[1][0].end = bad[1][0].header;
    var versions = [2]u64{ try a.version(), try b.version() };
    const initial = .{ try adapters[0].stats(), try adapters[1].stats() };
    try std.testing.expectError(error.InvalidFold, editing.setFoldsPair(window, tokens, versions, .{ &bad[0], &bad[1] }));
    try std.testing.expectEqual(initial[0].fold_version, (try adapters[0].stats()).fold_version);
    try std.testing.expectEqual(initial[1].fold_version, (try adapters[1].stats()).fold_version);
    trap.mutate_on_alloc = a;
    try std.testing.expectError(error.StaleRevision, editing.setFoldsPair(window, tokens, versions, .{ &definitions[0], &definitions[1] }));
    try std.testing.expectEqual(initial[0].fold_version, (try adapters[0].stats()).fold_version);
    try std.testing.expectEqual(initial[1].fold_version, (try adapters[1].stats()).fold_version);
    _ = try a.undo();
    try adapters[0].reindex();
    versions = .{ try a.version(), try b.version() };
    try std.testing.expect((try editing.setFoldsPair(window, tokens, versions, .{ &definitions[0], &definitions[1] })).current);
    for (adapters) |adapter| try std.testing.expectEqual(@as(usize, 3), (try adapter.stats()).visible_paragraphs);
    const hidden = (try a.line(2)).start;
    try std.testing.expectError(error.CaretInsideFold, adapters[0].setSelection(.{ .anchor = hidden, .caret = hidden }, .downstream));
    try std.testing.expectError(error.CaretInsideFold, adapters[0].setSelections(&.{ .{ .anchor = hidden, .caret = hidden }, .{ .anchor = 0, .caret = 0 } }, 0));
    try std.testing.expectEqual(versions[0], try a.version());
    const scale: f32 = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?));
    const bounds: [2]editing.Rect = .{ .{ .x = 4, .y = 4, .width = 200, .height = 260 }, .{ .x = 220, .y = 4, .width = 200, .height = 260 } };
    const parameters: [2]editing.Parameters = @splat(.{ .font = .{ .size = 16 }, .scale = scale });
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    var prepared: Prepared = .{ .adapters = adapters, .revisions = versions, .range = .{ .start = 0, .end = try a.byteLength() }, .reject = true };
    const planner: editing.PairPlanner = .{ .context = &prepared, .build = Prepared.build, .validate = Prepared.validate, .prepared = Prepared.complete };
    var fold_pair: editing.PairFolds = .{ .tokens = tokens, .revisions = versions, .definitions = .{ &definitions[0], &definitions[1] } };
    const before_prepared: [2]editing.Stats = .{ try adapters[0].stats(), try adapters[1].stats() };
    const before_anchors: [2]editing.ProjectionAnchor = .{ try adapters[0].viewportAnchor(), try adapters[1].viewportAnchor() };
    try std.testing.expectError(error.RejectedCandidate, editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair));
    for (adapters, before_prepared, before_anchors) |adapter, old, anchor| {
        try std.testing.expectEqual(old.fold_version, (try adapter.stats()).fold_version);
        try std.testing.expectEqual(anchor, try adapter.viewportAnchor());
    }
    prepared.reject = false;
    prepared.compose = a;
    const text_revision = try a.committedTextVersion();
    try std.testing.expectError(error.StaleRevision, editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair));
    try std.testing.expectEqual(text_revision, try a.committedTextVersion());
    for (adapters, before_prepared) |adapter, old| try std.testing.expectEqual(old.fold_version, (try adapter.stats()).fold_version);
    _ = try a.cancelComposition();
    _ = try adapters[0].clearOwnedFolds(tokens[0]);
    try adapters[0].reindex();
    versions = .{ try a.version(), try b.version() };
    prepared.revisions = versions;
    fold_pair.revisions = versions;
    try std.testing.expect((try editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair)).current);
    for (adapters, versions, prepared.rectangles, prepared.counts, prepared.positions) |adapter, revision, rectangles, count, position| {
        var output: [32]t.Rect = undefined;
        try std.testing.expectEqualSlices(t.Rect, rectangles[0..count], try adapter.rangeRects(revision, prepared.range, &output));
        try std.testing.expectEqual(position, try adapter.positionRect(revision, 0, .downstream));
    }
    // The same final owner gate runs in every projectPair branch. Composition
    // suspends projection/probes, but it does not bypass owner authorization.
    prepared.authority = false;
    const authority_versions = [2]u64{ try adapters[0].viewVersion(), try adapters[1].viewVersion() };
    for ([_]bool{ false, true }) |with_folds| {
        const before_calls = prepared.validations;
        const result = if (with_folds) editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair) else editing.projectPair(window, adapters[0], adapters[1], bounds, parameters, planner);
        try std.testing.expectError(error.InputAuthorityLost, result);
        try std.testing.expectEqual(before_calls + 1, prepared.validations);
        for (adapters, authority_versions) |adapter, version| try std.testing.expectEqual(version, try adapter.viewVersion());
    }
    try a.setComposition("same native composition", .{ .anchor = 0, .caret = 0 });
    _ = try adapters[0].clearOwnedFolds(tokens[0]);
    try adapters[0].reindex();
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    fold_pair.revisions = .{ try a.version(), try b.version() };
    fold_pair.definitions = .{ &.{}, &.{} };
    for ([_]bool{ false, true }) |with_folds| {
        const before_calls = prepared.validations;
        const result = if (with_folds) editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair) else editing.projectPair(window, adapters[0], adapters[1], bounds, parameters, planner);
        try std.testing.expectError(error.InputAuthorityLost, result);
        try std.testing.expectEqual(before_calls + 1, prepared.validations);
    }
    prepared.authority = true;
    try std.testing.expect((try editing.projectPair(window, adapters[0], adapters[1], bounds, parameters, planner)).projection_suspended);
    try std.testing.expect((try editing.projectPairWithFolds(window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair)).projection_suspended);
    _ = try a.cancelComposition();
    _ = try adapters[0].clearOwnedFolds(tokens[0]);
    try adapters[0].reindex();
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    prepared.revisions = .{ try a.version(), try b.version() };
    versions = prepared.revisions;
    fold_pair.revisions = prepared.revisions;
    fold_pair.definitions = .{ &definitions[0], &definitions[1] };
    const callback_window = try app.createWindow(.{ .width = 430, .height = 270 });
    prepared.close_window = callback_window;
    try std.testing.expectError(error.Closed, editing.projectPairWithFolds(callback_window, adapters[0], adapters[1], bounds, parameters, planner, fold_pair));
    try std.testing.expect(callback_window.isClosed());
    // A failing side cannot install either fold candidate.
    for (0..2) |side| for (0..16) |offset| {
        var changed = definitions;
        changed[0][0].end = (try a.line(4)).start;
        changed[1][0].end = changed[0][0].end;
        const old = .{ try adapters[0].stats(), try adapters[1].stats() };
        failing[side].fail_index = failing[side].alloc_index + offset;
        if (editing.setFoldsPair(window, tokens, versions, .{ &changed[0], &changed[1] })) |output| {
            try std.testing.expect(output.current);
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expectEqual(old[0].fold_version, (try adapters[0].stats()).fold_version);
            try std.testing.expectEqual(old[1].fold_version, (try adapters[1].stats()).fold_version);
            try std.testing.expectEqual(old[0].visible_paragraphs, (try adapters[0].stats()).visible_paragraphs);
            try std.testing.expectEqual(old[1].visible_paragraphs, (try adapters[1].stats()).visible_paragraphs);
        }
        failing[side].fail_index = std.math.maxInt(usize);
        _ = try editing.setFoldsPair(window, tokens, versions, .{ &definitions[0], &definitions[1] });
    };
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    try adapters[0].bind(window);
    _ = try adapters[0].handleEvent(window, .{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 0 } }, bounds[0], parameters[0]);
    const composed = [2]u64{ try a.version(), try b.version() };
    try std.testing.expect((try editing.setFoldsPair(window, tokens, composed, .{ &.{}, &.{} })).current);
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    _ = try adapters[0].handleEvent(window, .text_preedit_cancel, bounds[0], parameters[0]);
    try adapters[0].unbind();
    var current = [2]u64{ try a.version(), try b.version() };
    _ = try editing.setFoldsPair(window, tokens, current, .{ &definitions[0], &definitions[1] });
    // Text commits and undo stop reusing an old stamped derived fold layer.
    _ = try adapters[0].replaceSelections("x");
    try std.testing.expectEqual((try adapters[0].stats()).paragraphs, (try adapters[0].stats()).visible_paragraphs);
    _ = try adapters[0].undo();
    _ = try editing.preparePair(window, adapters[0], adapters[1], bounds, parameters);
    try std.testing.expectEqual((try adapters[0].stats()).paragraphs, (try adapters[0].stats()).visible_paragraphs);
    current = .{ try a.version(), try b.version() };
    _ = try editing.setFoldsPair(window, tokens, current, .{ &definitions[0], &definitions[1] });
    // Revoke needs no successful allocation and stale copies cannot release a
    // replacement owner. Ordinary prepare explicitly repairs its stale index.
    const stale = tokens[0];
    failing[0].fail_index = failing[0].alloc_index;
    try std.testing.expect(try adapters[0].releaseFolds(stale));
    try std.testing.expect((try adapters[0].status()).index_required);
    failing[0].fail_index = std.math.maxInt(usize);
    try adapters[0].reindex();
    tokens[0] = try adapters[0].reserveFolds();
    try std.testing.expect(!try adapters[0].releaseFolds(stale));
    var wrong = tokens;
    wrong[0] = stale;
    try std.testing.expectError(error.StaleFoldToken, editing.setFoldsPair(window, wrong, current, .{ &definitions[0], &definitions[1] }));
    _ = try editing.setFoldsPair(window, tokens, current, .{ &definitions[0], &definitions[1] });
    // Old FoldSet disposal closes the real native host after pure publication.
    trap.window = window;
    const output = try editing.setFoldsPair(window, tokens, current, .{ &.{}, &.{} });
    try std.testing.expect(trap.triggered and !output.current);
    if (output.post_publish_error) |err| try std.testing.expectEqual(error.Closed, err) else return error.MissingPostPublishError;
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("paired folds native passed: empty-slot tokens, atomic candidates/OOM/caret reject, IME/edit/undo invalidation, no-allocation revoke, stale owner, close-after-publish resources=0\n", .{});
}
