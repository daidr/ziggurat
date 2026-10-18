const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 116, .height = 170 };
const source = "office אבג e\u{301} 👩‍👩‍👧‍👦 wrapped long text\r\nsecond\nthird\n";
const background: u32 = 0xe1f2d3;
const underline: u32 = 0xa94e12;
const Host = struct {
    adapter: *editing.Adapter,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    scale: f32 = 1,
    paints: usize = 0,
    failure: ?anyerror = null,
    prepared: ?*const anyopaque = null,
    expect_same_prepared: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.checked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn checked(self: *Host, frame: *ui.Frame) !void {
        var storage: [128]editing.RangeMarkerMark = undefined;
        const prepared = try self.adapter.preparedRangeMarkers(bounds, &storage);
        frame.clear(0xffffff);
        try self.adapter.draw(frame, bounds, .{});
        var seen_text = false;
        var seen: usize = 0;
        for (frame.context.command_buffer.commands()) |command| switch (command) {
            .fill => |fill| {
                if (fill.color != background and fill.color != underline) continue;
                const kind: editing.RangeMarkerKind = if (fill.color == background) .background else .underline;
                try std.testing.expectEqual(kind == .underline, seen_text);
                var match = false;
                for (prepared.items) |item| if (item.kind == kind and item.color == fill.color and same(item.rect, fill.bounds)) {
                    match = true;
                    break;
                };
                try std.testing.expect(match);
                seen += 1;
            },
            .prepared_text => seen_text = true,
            else => {},
        };
        try std.testing.expect(seen_text and seen == prepared.items.len);
        const resources = frame.context.command_buffer.preparedTextResources();
        try std.testing.expect(resources.len != 0);
        const identity: *const anyopaque = @ptrCast(resources[0].lease);
        if (self.expect_same_prepared) try std.testing.expect(self.prepared.? == identity);
        self.prepared = identity;
        self.paints += 1;
    }
    fn paint(self: *Host) !void {
        const before = self.paints;
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_paint(native, @intFromFloat(144 * self.scale), @intFromFloat(192 * self.scale));
        }
        if (self.failure) |err| return err;
        try std.testing.expect(self.paints > before);
    }
};
fn same(a: ui.Rect, b: ui.Rect) bool {
    inline for (.{ "x", "y", "width", "height" }) |field| if (@abs(@field(a, field) - @field(b, field)) > 0.001) return false;
    return true;
}
fn snap(layout: *const t.Layout, byte: usize, up: bool) !usize {
    var low: usize = 0;
    var high = try layout.graphemeCount();
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try layout.graphemeByte(middle) < byte) low = middle + 1 else high = middle;
    }
    const after = try layout.graphemeByte(low);
    return if (after == byte or up) after else try layout.graphemeByte(low - 1);
}
fn compare(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const accent = std.mem.indexOf(u8, source, "e\u{301}").?;
    const emoji = std.mem.indexOf(u8, source, "👩").?;
    const markers = [_]editing.RangeMarker{
        .{ .range = .{ .start = 0, .end = source.len }, .color = background },
        .{ .range = .{ .start = 1, .end = emoji + "👩".len }, .kind = .underline, .color = underline, .thickness = 2.5 },
        .{ .range = .{ .start = accent + 1, .end = accent + 3 }, .color = background },
    };
    const installed = try adapter.setRangeMarkers(try document.committedTextVersion(), &markers);
    try std.testing.expect(installed.current);
    var parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character } };
    var output: [128]editing.RangeMarkerMark = undefined;
    var scratch: [128]t.Rect = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        parameters.scale = scale;
        _ = try adapter.prepare(bounds, parameters);
        const prepared = try adapter.preparedRangeMarkers(bounds, &output);
        try std.testing.expectEqual(installed.version, prepared.version);
        try std.testing.expectEqual(try document.committedTextVersion(), prepared.text_version);
        try std.testing.expectEqual(try adapter.viewVersion(), prepared.view_version);
        try std.testing.expectEqual(try adapter.projectionVersion(), prepared.projection_version);
        try std.testing.expect(prepared.items.len > markers.len);
        try std.testing.expectError(error.BufferTooSmall, adapter.preparedRangeMarkers(bounds, &.{}));
        var native_options = parameters.font;
        native_options.width = bounds.width;
        const native = try engine.layout(source, native_options);
        defer native.close() catch unreachable;
        // Both generic range queries and marker preparation expand the same
        // UTF-8 boundary inside the combining grapheme to complete cells.
        for (markers, 0..) |marker, index| {
            const rects = try adapter.rangeRects(try document.version(), marker.range, &scratch);
            var original: [128]t.Rect = undefined;
            const native_rects = try native.selectionRects(.{ .start = try snap(native, marker.range.start, false), .end = try snap(native, marker.range.end, true) }, &original);
            var expected_rects: [128]ui.Rect = undefined;
            var expected_count: usize = 0;
            for (native_rects) |rect| {
                var expected: ui.Rect = .{ .x = bounds.x + rect.x, .y = bounds.y + rect.y, .width = rect.width, .height = rect.height };
                if (marker.kind == .underline) {
                    expected.height = @min(expected.height, marker.thickness);
                    expected.y += rect.height - expected.height;
                }
                expected = ui.layout.intersect(expected, bounds);
                if (expected.width == 0 or expected.height == 0) continue;
                expected_rects[expected_count] = expected;
                expected_count += 1;
            }
            var actual: usize = 0;
            for (prepared.items) |item| if (item.marker == index) {
                try std.testing.expect(std.meta.eql(marker.range, item.range));
                actual += 1;
                var found = false;
                for (expected_rects[0..expected_count]) |expected| if (same(expected, item.rect)) {
                    found = true;
                    break;
                };
                try std.testing.expect(found);
            };
            try std.testing.expect(actual != 0);
            try std.testing.expectEqual(expected_count, actual);
            if (marker.kind == .background) try std.testing.expectEqual(rects.len, actual);
        }
        const projection_version = prepared.projection_version;
        const stats = try adapter.stats();
        _ = try adapter.setSelection(.{ .anchor = accent, .caret = accent }, .downstream);
        _ = try adapter.prepare(bounds, parameters);
        try std.testing.expectEqual(projection_version, try adapter.projectionVersion());
        try std.testing.expectEqual(stats.shaped_batches, (try adapter.stats()).shaped_batches);
        try std.testing.expect(!(try adapter.status()).range_markers_required);
    }
    const line1 = (try document.line(1)).start;
    const line2 = (try document.line(2)).start;
    const plan = try editing.ProjectionPlan.create(allocator, document, &.{.{ .line = 1, .gap_before = 13, .minimum_height = 38 }}, .{});
    defer plan.close() catch unreachable;
    try adapter.setProjection(plan);
    _ = try adapter.prepare(bounds, parameters);
    const projected = try adapter.preparedRangeMarkers(bounds, &output);
    try std.testing.expect(projected.items.len != 0);
    // A range wholly inside a paragraph uses exactly the existing query's
    // projected run and cannot paint the gap/minimum-height policy padding.
    var query: [128]t.Rect = undefined;
    const projected_rects = try adapter.rangeRects(try document.version(), .{ .start = line1, .end = line2 }, &query);
    try std.testing.expect(projected_rects.len != 0);
    for (projected_rects) |rect| try std.testing.expect(rect.height < 38);
    try adapter.setProjection(null);
    try adapter.setFolds(try document.version(), &.{.{ .id = 1, .header = 0, .end = line2, .collapsed = true }});
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.rangeRects(try document.version(), .{ .start = line1, .end = line2 }, &query)).len);
    try adapter.setFolds(try document.version(), &.{});
    try document.setComposition("TEMP\n", .{});
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
    try std.testing.expectError(error.CompositionActive, adapter.setRangeMarkers(try document.committedTextVersion(), &markers));
    _ = try document.cancelComposition();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.preparedRangeMarkers(bounds, &output)).items.len != 0);
    const stamp = try document.committedTextVersion();
    _ = try adapter.replace(.{ .start = 0, .end = 1 }, "Z");
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.status()).range_markers_required);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
    try std.testing.expectError(error.StaleRevision, adapter.setRangeMarkers(stamp, &markers));
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.status()).range_markers_required);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
}

fn failures(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "aé\nb", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{ .range_markers = 2 });
    defer adapter.close() catch unreachable;
    const construction_peak = (try adapter.stats()).reserved_peak_bytes;
    const definitions = [_]editing.RangeMarker{
        .{ .range = .{ .start = 0, .end = 3 }, .color = background },
        .{ .range = .{ .start = 0, .end = 3 }, .kind = .underline, .color = underline },
    };
    const stamp = try document.committedTextVersion();
    const installed = try adapter.setRangeMarkers(stamp, &definitions);
    _ = try adapter.prepare(bounds, .{});
    var output: [16]editing.RangeMarkerMark = undefined;
    try std.testing.expectError(error.InvalidBoundary, adapter.setRangeMarkers(stamp, &.{.{ .range = .{ .start = 2, .end = 3 }, .color = 0 }}));
    try std.testing.expectError(error.InvalidRange, adapter.setRangeMarkers(stamp, &.{.{ .range = .{ .start = 0, .end = 6 }, .color = 0 }}));
    try std.testing.expectError(error.RangeMarkerCapacityExceeded, adapter.setRangeMarkers(stamp, &.{ definitions[0], definitions[1], definitions[0] }));
    const old = try adapter.preparedRangeMarkers(bounds, &output);
    const bytes = (try adapter.stats()).owned_bytes;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.setRangeMarkers(stamp, &definitions));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(bytes, (try adapter.stats()).owned_bytes);
    try std.testing.expectEqual(installed.version, (try adapter.preparedRangeMarkers(bounds, &output)).version);
    var completed = false;
    var failures_seen: usize = 0;
    for (0..64) |offset| {
        const next = try adapter.setRangeMarkers(stamp, &definitions);
        try std.testing.expectError(error.LayoutRequired, adapter.preparedRangeMarkers(bounds, &output));
        failing.fail_index = failing.alloc_index + offset;
        const result = adapter.prepare(bounds, .{});
        failing.fail_index = std.math.maxInt(usize);
        if (result) |prepared| {
            try std.testing.expectEqual(@as(usize, 0), prepared.shaped_batches);
            try std.testing.expectEqual(next.version, (try adapter.preparedRangeMarkers(bounds, &output)).version);
            completed = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures_seen += 1;
            _ = try adapter.prepare(bounds, .{});
            try std.testing.expectEqual(old.items.len, (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
        }
    }
    try std.testing.expect(completed and failures_seen != 0);
    const disabled = try editing.Adapter.create(failing.allocator(), document, engine, .{ .range_markers = 0, .range_marker_work = 0 });
    defer disabled.close() catch unreachable;
    _ = try disabled.prepare(bounds, .{});
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    try std.testing.expect((try disabled.setRangeMarkers(stamp, &.{})).current);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.RangeMarkerCapacityExceeded, disabled.setRangeMarkers(stamp, &definitions));
    const no_work = try editing.Adapter.create(allocator, document, engine, .{ .range_marker_work = 0 });
    defer no_work.close() catch unreachable;
    _ = try no_work.setRangeMarkers(stamp, &definitions);
    try std.testing.expectError(error.RangeMarkerWorkExceeded, no_work.prepare(bounds, .{}));
    _ = try no_work.setRangeMarkers(stamp, &.{});
    _ = try no_work.prepare(bounds, .{});
    const no_rects = try editing.Adapter.create(allocator, document, engine, .{ .rectangles = 0 });
    defer no_rects.close() catch unreachable;
    _ = try no_rects.setRangeMarkers(stamp, &definitions);
    try std.testing.expectError(error.RectangleCapacityExceeded, no_rects.prepare(bounds, .{}));
    const constrained = try editing.Adapter.create(allocator, document, engine, .{ .bytes = construction_peak });
    defer constrained.close() catch unreachable;
    const many = [_]editing.RangeMarker{definitions[0]} ** 1024;
    try std.testing.expectError(error.CapacityExceeded, constrained.setRangeMarkers(stamp, &many));
}

fn sparse(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const text = "a\n" ** 4096;
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
    defer document.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{ .range_marker_work = 32 });
    defer adapter.close() catch unreachable;
    var definitions: [2048]editing.RangeMarker = undefined;
    for (&definitions, 0..) |*item, index| item.* = .{ .range = .{ .start = (2048 + index) * 2, .end = (2048 + index) * 2 + 1 }, .color = background };
    _ = try adapter.setRangeMarkers(try document.committedTextVersion(), &definitions);
    _ = try adapter.prepare(bounds, .{});
    var output: [1]editing.RangeMarkerMark = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
}
fn clipping(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "ab\ncd", .{});
    defer document.close() catch unreachable;
    const adapter = try editing.Adapter.create(allocator, document, engine, .{});
    defer adapter.close() catch unreachable;
    const clipped: ui.Rect = .{ .x = 4, .y = 4, .width = 100, .height = 5 };
    _ = try adapter.setRangeMarkers(try document.committedTextVersion(), &.{
        .{ .range = .{ .start = 0, .end = 2 }, .color = background },
        .{ .range = .{ .start = 0, .end = 2 }, .kind = .underline, .color = underline, .thickness = 2 },
    });
    _ = try adapter.prepare(clipped, .{ .font = .{ .size = 18 } });
    var output: [4]editing.RangeMarkerMark = undefined;
    const prepared = try adapter.preparedRangeMarkers(clipped, &output);
    try std.testing.expectEqual(@as(usize, 1), prepared.items.len);
    try std.testing.expectEqual(editing.RangeMarkerKind.background, prepared.items[0].kind);
    try std.testing.expectEqual(clipped.height, prepared.items[0].rect.height);
}

const Hook = struct {
    allocator: std.mem.Allocator,
    document: *d.Document,
    target: usize = 0,
    on_alloc: bool = false,
    hits: usize = 0,
    close_window: ?z.Window = null,
    record_size: bool = false,
    last_size: usize = 0,
    track_size: usize = 0,
    last_pointer: ?[*]u8 = null,
    retire_pointer: ?[*]u8 = null,
    fn get(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn change(self: *Hook) void {
        self.target = 0;
        self.retire_pointer = null;
        self.hits += 1;
        if (self.close_window) |window| {
            _ = window.destroy() catch unreachable;
        } else self.document.replace(.{ .start = 0, .end = 1 }, if (self.hits == 1) "X" else "Y") catch unreachable;
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        const storage = self.allocator.rawAlloc(size, alignment, ra);
        if (storage != null and self.record_size) self.last_size = size;
        if (storage != null and self.track_size == size) self.last_pointer = storage;
        if (self.on_alloc and storage != null and self.target == size) self.change();
        return storage;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        if (self.retire_pointer == bytes.ptr or (!self.on_alloc and self.target == bytes.len)) self.change();
        self.allocator.rawFree(bytes, alignment, ra);
    }
};
fn reentry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const definitions = [_]editing.RangeMarker{
        .{ .range = .{ .start = 0, .end = 2 }, .color = background },
        .{ .range = .{ .start = 0, .end = 2 }, .kind = .underline, .color = underline },
    };
    for ([_]bool{ true, false }) |on_alloc| {
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "ab\n", .{});
        defer document.close() catch unreachable;
        var hook: Hook = .{ .allocator = allocator, .document = document, .on_alloc = on_alloc };
        const adapter = try editing.Adapter.create(hook.get(), document, engine, .{});
        defer adapter.close() catch unreachable;
        const stamp = try document.committedTextVersion();
        hook.record_size = true;
        _ = try adapter.setRangeMarkers(stamp, &definitions);
        hook.record_size = false;
        _ = try adapter.prepare(bounds, .{});
        hook.target = hook.last_size;
        if (on_alloc) {
            try std.testing.expectError(error.StaleRevision, adapter.setRangeMarkers(stamp, &definitions));
        } else try std.testing.expect(!(try adapter.setRangeMarkers(stamp, &definitions)).current);
        try std.testing.expectEqual(@as(usize, 1), hook.hits);
        _ = try adapter.prepare(bounds, .{});
        var output: [8]editing.RangeMarkerMark = undefined;
        try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
    }
    for ([_]bool{ true, false }) |on_alloc| {
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "ab\n", .{});
        defer document.close() catch unreachable;
        var hook: Hook = .{ .allocator = allocator, .document = document, .on_alloc = on_alloc };
        const adapter = try editing.Adapter.create(hook.get(), document, engine, .{});
        defer adapter.close() catch unreachable;
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        _ = try adapter.prepare(bounds, .{});
        try adapter.bind(window);
        defer adapter.unbind() catch unreachable;
        const stamp = try document.committedTextVersion();
        hook.record_size = true;
        _ = try adapter.setRangeMarkers(stamp, &definitions);
        hook.record_size = false;
        hook.close_window = window;
        hook.target = hook.last_size;
        if (on_alloc) {
            try std.testing.expectError(error.Closed, adapter.setRangeMarkers(stamp, &definitions));
        } else try std.testing.expect(!(try adapter.setRangeMarkers(stamp, &definitions)).current);
        try std.testing.expect(window.isClosed() and hook.hits == 1);
        try app.dispatch();
    }
    // Arm the exact old geometry allocation, rather than a same-sized scratch
    // free. This callback runs only after the new candidate has been published.
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "ab\n", .{});
    defer document.close() catch unreachable;
    var hook: Hook = .{ .allocator = allocator, .document = document, .track_size = 2 * @sizeOf(editing.RangeMarkerMark) };
    const adapter = try editing.Adapter.create(hook.get(), document, engine, .{});
    defer adapter.close() catch unreachable;
    _ = try adapter.setRangeMarkers(try document.committedTextVersion(), &definitions);
    _ = try adapter.prepare(bounds, .{});
    try std.testing.expect(hook.last_pointer != null);
    hook.retire_pointer = hook.last_pointer;
    _ = try adapter.setSelection(.{ .anchor = 1, .caret = 1 }, .downstream);
    try std.testing.expectError(error.IndexRequired, adapter.prepare(bounds, .{}));
    try std.testing.expect(hook.hits == 1 and (try adapter.status()).range_markers_required);
    _ = try adapter.prepare(bounds, .{});
    var output: [8]editing.RangeMarkerMark = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedRangeMarkers(bounds, &output)).items.len);
}
fn drawing(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "office אבג e\u{301}\n", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    var host: Host = .{ .adapter = adapter };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    host.window = try app.createWindow(.{ .width = 144, .height = 192 });
    defer _ = host.window.destroy() catch unreachable;
    host.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(host.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(host.window.nativeHandle().?));
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    try host.context.attach(host.window);
    const parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character }, .scale = host.scale };
    _ = try adapter.prepare(bounds, parameters);
    const projection_version = try adapter.projectionVersion();
    try host.paint();
    host.expect_same_prepared = true;
    const markers = [_]editing.RangeMarker{
        .{ .range = .{ .start = 0, .end = 6 }, .color = background },
        .{ .range = .{ .start = 0, .end = 6 }, .kind = .underline, .color = underline, .thickness = 2 },
    };
    const installed = try adapter.setRangeMarkers(try document.committedTextVersion(), &markers);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(projection_version, try adapter.projectionVersion());
    const before = try adapter.stats();
    failing.fail_index = failing.alloc_index;
    try host.paint();
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(before.owned_bytes, (try adapter.stats()).owned_bytes);
    const changed = try adapter.setRangeMarkers(try document.committedTextVersion(), &markers);
    try std.testing.expect(changed.version > installed.version);
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(projection_version, try adapter.projectionVersion());
    try host.paint();
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();
    const before = t.resourceCounts();
    {
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        try failures(allocator, engine);
        try sparse(allocator, engine);
        try clipping(allocator, engine);
        try compare(allocator, engine);
        try reentry(allocator, engine);
        try drawing(allocator, engine);
    }
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("range markers: UTF8/combining/bidi/wrap, shared prepared queries, fold/projection/IME/stale, OOM/budgets/reentry, unchanged Prepared and zero draw allocation resources=0\n", .{});
}
