const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 260 };

fn source(allocator: std.mem.Allocator, changed: bool) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    for (0..240) |line| {
        var buffer: [64]u8 = undefined;
        try bytes.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{s} {d}\n", .{ if (changed and line == 120) @as([]const u8, "changed") else "common", line }));
    }
    return bytes.toOwnedSlice(allocator);
}
fn focus(comptime Surface: type, state: anytype) !void {
    if (Surface == viewing.EditableUnified) try state.view.focus() else try state.view.focus(.b);
}
fn reveal(comptime Surface: type, state: anytype, position: usize) !void {
    if (Surface == viewing.EditableUnified) try state.view.reveal(position) else try state.view.reveal(.b, position);
}
fn firstRegion(state: anytype) !viewing.editable.ContextRegion {
    var storage: [96]viewing.editable.ContextRegion = undefined;
    const regions = try state.view.contextRegions(&storage);
    try std.testing.expect(regions.len != 0);
    return regions[0];
}
fn runMode(allocator: std.mem.Allocator, comptime Surface: type, limited: bool) !void {
    const Harness = @import("document_diff_editable_smoke.zig").Harness(Surface);
    const original = try source(allocator, false);
    defer allocator.free(original);
    const changed = try source(allocator, true);
    defer allocator.free(changed);
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), changed, .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    var adapter_allocators: [2]std.testing.FailingAllocator = @splat(.init(allocator, .{}));
    const adapters: [2]*editing.Adapter = .{ try editing.Adapter.create(adapter_allocators[0].allocator(), a, engine, .{}), try editing.Adapter.create(adapter_allocators[1].allocator(), b, engine, .{}) };
    defer for (adapters) |adapter| adapter.close() catch unreachable;
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var state: Harness = .{ .inbox = inbox, .adapters = adapters, .detailed = !limited };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = Harness.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = state.window.destroy() catch unreachable;
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.view = try Surface.create(failing.allocator(), inbox, adapters[0], adapters[1], state.window, .{ .intraline_rects = if (limited) 1 else 1024 });
    defer state.view.close() catch unreachable;
    try state.view.setContext(.{});
    try state.refresh();
    state.context = ui.Context.init(&state, Harness.draw, Harness.action);
    state.context.render_mode = .gdi;
    state.context.on_input = Harness.input;
    try state.context.attach(state.window);
    try state.paint();
    if (limited) {
        const old: [2]editing.Stats = .{ try adapters[0].stats(), try adapters[1].stats() };
        const anchors: [2]editing.ProjectionAnchor = .{ try adapters[0].viewportAnchor(), try adapters[1].viewportAnchor() };
        const plans: [2]?*editing.ProjectionPlan = .{ try adapters[0].projectionPlan(), try adapters[1].projectionPlan() };
        state.detailed = true;
        try std.testing.expectError(error.IntralineRectangleCapacityExceeded, state.refresh());
        for (adapters, old, anchors, plans) |adapter, stats, anchor, plan| {
            try std.testing.expectEqual(stats.fold_version, (try adapter.stats()).fold_version);
            try std.testing.expectEqual(anchor, try adapter.viewportAnchor());
            try std.testing.expectEqual(plan, try adapter.projectionPlan());
        }
        // The new comparison was received, but none of the failed candidate
        // folds, geometry, Plans or markers acquired publication ownership.
        try std.testing.expectError(error.LayoutRequired, state.view.info());
        state.detailed = false;
        try state.refresh();
        try state.paint();
        _ = try state.window.destroy();
        try app.dispatch();
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        return;
    }
    const compact = try state.view.info();
    try std.testing.expect(compact.total_rows < 20);
    for (adapters) |adapter| {
        const stats = try adapter.stats();
        try std.testing.expect(stats.visible_paragraphs < 20 and stats.paragraphs == 241);
        try std.testing.expect(try adapter.projectionPlan() != null);
    }
    const versions = [2]u64{ try a.version(), try b.version() };
    var region = try firstRegion(&state);
    const key = region.key;
    const header = region.headers[1].?;
    try std.testing.expect(region.collapsed);
    // The header is real retained source text. Its gutter is painted from
    // prepared metadata; native pointer input expands both owned fold layers.
    const colors: viewing.Colors = .{};
    try std.testing.expectEqual(@as(u32, colors.header), try state.pixel(header.x + 1, header.y + 1));
    try state.click(header.x + 1, header.y + 1);
    region = try firstRegion(&state);
    try std.testing.expect(!region.collapsed);
    try std.testing.expect((try state.view.info()).total_rows > 100);
    try std.testing.expectEqual(versions[0], try a.version());
    try std.testing.expectEqual(versions[1], try b.version());
    try state.click(region.headers[1].?.x + 1, region.headers[1].?.y + 1);
    try std.testing.expectEqual(compact.total_rows, (try state.view.info()).total_rows);
    const hidden = (try b.line(20)).start;
    try std.testing.expectError(error.CaretInsideFold, adapters[1].setSelection(.{ .anchor = hidden, .caret = hidden }, .downstream));
    try std.testing.expectEqual(versions[1], try b.version());
    try reveal(Surface, &state, hidden);
    try std.testing.expectEqual(versions[1], try b.version());
    _ = try adapters[1].setSelection(.{ .anchor = hidden, .caret = hidden }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    const after_select = try b.version();
    try std.testing.expectError(error.CaretInsideFold, state.view.setContextCollapsed(key, true));
    try std.testing.expectEqual(after_select, try b.version());
    try state.view.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 20), try b.lineAt((try b.selection()).caret));
    _ = try adapters[1].setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.setContextCollapsed(key, true);
    _ = try state.view.scrollBy(-1000000);
    try state.view.prepare(bounds, state.parameters);

    // Failures on either native-layout side must not publish the fold roots,
    // paired Plans or viewport. Coordinator allocations are tested separately.
    for (0..3) |source_index| for (0..32) |offset| {
        const old = .{ try adapters[0].stats(), try adapters[1].stats() };
        const anchors = .{ try adapters[0].viewportAnchor(), try adapters[1].viewportAnchor() };
        const target = if (source_index == 2) &failing else &adapter_allocators[source_index];
        target.fail_index = target.alloc_index + offset;
        if (state.view.setContextCollapsed(key, false)) |_| {
            target.fail_index = std.math.maxInt(usize);
            _ = try state.view.setContextCollapsed(key, true);
        } else |err| {
            target.fail_index = std.math.maxInt(usize);
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(old[0].fold_version, (try adapters[0].stats()).fold_version);
            try std.testing.expectEqual(old[1].fold_version, (try adapters[1].stats()).fold_version);
            try std.testing.expectEqual(anchors[0], try adapters[0].viewportAnchor());
            try std.testing.expectEqual(anchors[1], try adapters[1].viewportAnchor());
            try state.view.prepare(bounds, state.parameters);
            try std.testing.expect((try firstRegion(&state)).collapsed);
        }
    };
    try focus(Surface, &state);
    const before_hidden = (try b.line(2)).start;
    _ = try adapters[1].setSelection(.{ .anchor = before_hidden, .caret = before_hidden }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    if (builtin.os.tag == .windows) {
        // This helper requests a plain key even when this thread has an
        // unrelated modifier state. It must also restore the original table.
        var previous: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&previous) != 0);
        defer _ = c.SetKeyboardState(&previous);
        var control: [256]u8 = @splat(0);
        control[c.VK_CONTROL] = 0x80;
        control[c.VK_LCONTROL] = 0x80;
        try std.testing.expect(c.SetKeyboardState(&control) != 0);
        try state.key(0x28, 0xff54);
        var restored: [256]u8 = undefined;
        try std.testing.expect(c.GetKeyboardState(&restored) != 0);
        try std.testing.expectEqualSlices(u8, &control, &restored);
    } else try state.key(0x28, 0xff54);
    try std.testing.expectEqual(@as(usize, 117), try b.lineAt((try b.selection()).caret));
    _ = try adapters[1].setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.handleEvent(.{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 0 } }, bounds, state.parameters);
    try std.testing.expect((try state.view.info()).composition_identity);
    for (adapters) |adapter| try std.testing.expectEqual((try adapter.stats()).paragraphs, (try adapter.stats()).visible_paragraphs);
    var headers: [96]viewing.editable.ContextRegion = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try state.view.contextRegions(&headers)).len);
    try state.paint();
    _ = try state.view.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    try std.testing.expect(!(try state.view.info()).composition_identity);
    try std.testing.expect((try firstRegion(&state)).collapsed);
    try state.paint();
    // The displayed composition can be much shorter than the committed
    // selection it temporarily replaces. Queries must use overlay coordinates.
    _ = try adapters[1].setSelection(.{ .anchor = 0, .caret = try b.byteLength() }, .downstream);
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.handleEvent(.{ .text_preedit = .{ .text = "短", .selection_start = 0, .selection_end = 3 } }, bounds, state.parameters);
    try std.testing.expect((try state.view.info()).composition_identity);
    try state.paint();
    _ = try state.view.handleEvent(.text_preedit_cancel, bounds, state.parameters);
    _ = try adapters[1].setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
    _ = try state.view.scrollBy(-1000000);
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.handleEvent(.{ .text_input = .{ .text = "x", .producer = .application } }, bounds, state.parameters);
    try std.testing.expect((try state.view.info()).comparison_required);
    for (adapters) |adapter| try std.testing.expectEqual((try adapter.stats()).paragraphs, (try adapter.stats()).visible_paragraphs);
    _ = try adapters[1].undo();
    try state.refresh();
    try std.testing.expect((try firstRegion(&state)).collapsed);
    try std.testing.expectError(error.StaleContext, state.view.setContextCollapsed(key, false));
    try state.view.prepare(bounds, state.parameters);
    try @import("document_diff_context_native.zig").run(Surface, &state);
    try state.view.setContext(null);
    try state.view.prepare(bounds, state.parameters);
    for (adapters, [_]*d.Document{ a, b }) |adapter, document| {
        try std.testing.expectEqual(@as(usize, 0), (try adapter.stats()).folds);
        try adapter.setFolds(try document.version(), &.{});
    }
    try state.view.prepare(bounds, state.parameters);
    try adapters[0].setFolds(try a.version(), &.{.{ .id = 10, .header = 0, .end = (try a.line(10)).start, .collapsed = true }});
    const application_version = (try adapters[0].stats()).fold_version;
    try state.view.setContext(.{});
    try std.testing.expectError(error.FoldOwnerConflict, state.view.prepare(bounds, state.parameters));
    try std.testing.expectEqual(application_version, (try adapters[0].stats()).fold_version);
    try state.view.setContext(null);
    try adapters[0].setFolds(try a.version(), &.{});
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    const frames = state.context.frames;
    try state.paint();
    try std.testing.expectEqual(frames, state.context.frames);
    state.fail_frame = false;
    state.expected = null;
    _ = try state.window.destroy();
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn run(allocator: std.mem.Allocator) !void {
    const before = t.resourceCounts();
    try runMode(allocator, viewing.EditableSplit, false);
    try runMode(allocator, viewing.EditableUnified, false);
    try runMode(allocator, viewing.EditableSplit, true);
    try runMode(allocator, viewing.EditableUnified, true);
    try std.testing.expectEqual(before, t.resourceCounts());
    std.debug.print("context diff native passed: paired fold/layout publication, gutter input/pixels, hidden caret/reveal, candidate OOM, IME identity/cancel, edit/undo/stale serial, revoke/failed Frame resources=0\n", .{});
}
