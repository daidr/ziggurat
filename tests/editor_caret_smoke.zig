const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const shaped = @import("ziggurat_shaped_editor");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const caret = shaped.caret_visual;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 112, .height = 88 };
const GeometryHook = struct {
    child: std.mem.Allocator,
    editor: *ui.editor.Editor,
    target: usize = 0,
    mode: enum { edit, selection, composition } = .edit,
    hits: usize = 0,
    adapter: ?*shaped.Adapter = null,
    pin_armed: bool = false,
    held: ?*ui.drawing.Lease = null,
    fn allocator(self: *GeometryHook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *GeometryHook = @ptrCast(@alignCast(ptr));
        const allocated = self.child.rawAlloc(len, alignment, ra);
        if (allocated != null and self.pin_armed) {
            self.pin_armed = false;
            const view = self.adapter.?.snapshot.?.prepared.view() catch unreachable;
            view.lease.acquire() catch unreachable;
            self.held = view.lease;
            self.hits += 1;
        }
        return allocated;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *GeometryHook = @ptrCast(@alignCast(ptr));
        if (self.target != 0 and @intFromPtr(bytes.ptr) == self.target) {
            self.target = 0;
            self.hits += 1;
            switch (self.mode) {
                .edit => {
                    _ = self.editor.buffer.replaceRange(.{ .start = 0, .end = 1 }, "Z") catch unreachable;
                    _ = self.editor.buffer.setSelection(.{ .anchor = 1, .caret = 1 }) catch unreachable;
                    self.editor.refresh();
                },
                .selection => _ = self.editor.buffer.setSelection(.{}) catch unreachable,
                .composition => {
                    _ = self.editor.buffer.setComposition("Z", .{}) catch unreachable;
                    self.editor.refresh();
                },
            }
            _ = self.editor.displayText();
        }
        self.child.rawFree(bytes, alignment, ra);
    }
};
fn geometryPin(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .autofocus = true }, "ab");
    defer editor.deinit();
    var hook: GeometryHook = .{ .child = allocator, .editor = &editor };
    var adapter = try shaped.Adapter.init(hook.allocator(), &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    hook.adapter = &adapter;
    var options: shaped.Parameters = .{ .font = .{ .size = 18 } };
    _ = try adapter.prepare(bounds, options);
    options.caret_cells = true;
    hook.pin_armed = true;
    const result = adapter.prepare(bounds, options);
    const held = hook.held orelse return error.MissingAllocatorPin;
    held.release();
    hook.held = null;
    try std.testing.expectError(error.ResourceInUse, result);
    try std.testing.expect(!adapter.snapshot.?.geometry.cells_enabled);
    _ = try adapter.prepare(bounds, options);
}
fn geometryReentry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    for ([_]@FieldType(GeometryHook, "mode"){ .edit, .selection, .composition }) |mode| for ([_]bool{ false, true }) |rebuild| {
        var editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, "ab");
        defer editor.deinit();
        _ = try editor.buffer.setSelection(.{ .anchor = 0, .caret = 1 });
        var hook: GeometryHook = .{ .child = allocator, .editor = &editor, .mode = mode };
        var adapter = try shaped.Adapter.init(hook.allocator(), &editor, engine, .{});
        defer adapter.deinit() catch unreachable;
        var options: shaped.Parameters = .{ .font = .{ .size = 18 } };
        _ = try adapter.prepare(bounds, options);
        hook.target = @intFromPtr(adapter.snapshot.?.geometry.selection.ptr);
        _ = try editor.buffer.setSelection(.{ .anchor = 1, .caret = 1 });
        if (rebuild) options.font.size = 19;
        const result = adapter.prepare(bounds, options);
        if (result) |_| {
            var probe: Collector = .{};
            defer probe.reset();
            const drawn = if (adapter.draw(bounds, 1, probe.surface())) |_| true else |_| false;
            std.debug.print("caret reentry RED mode={s} rebuild={} editor={s} layout={s} reported_revision={d} actual_revision={d} draw_accepted={}\n", .{ @tagName(mode), rebuild, editor.displayText(), try adapter.snapshot.?.layout.text(), adapter.snapshot.?.revision, editor.display_revision, drawn });
        } else |_| {}
        try std.testing.expectError(error.LayoutRequired, result);
        try std.testing.expectEqual(@as(usize, 1), hook.hits);
        var collector: Collector = .{};
        defer collector.reset();
        try std.testing.expectError(error.LayoutRequired, adapter.draw(bounds, 1, collector.surface()));
        _ = try adapter.prepare(bounds, options);
        try std.testing.expectEqualStrings(editor.displayText(), try adapter.snapshot.?.layout.text());
    };
}
const Collector = struct {
    buffer: ui.commands.Buffer = .{},
    marks: [1024]caret.Paint = undefined,
    count: usize = 0,
    text_at: usize = 0,
    fn paint(ptr: *anyopaque, command: shaped.PaintCommand) !void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        switch (command) {
            .text => |value| {
                self.text_at = self.count;
                try self.buffer.preparedText(.{ .x = value.origin.x, .y = value.origin.y }, try value.prepared.view(), ui.Color.rgb(0x202020));
            },
            .selection => |rect| try self.buffer.fill(rect, 0xc7ddff),
            .composition => |rect| try self.buffer.fill(rect, 0x385ca8),
            .caret => |rect| try self.buffer.fill(rect, 0x202020),
        }
    }
    fn paintCaret(ptr: *anyopaque, value: caret.Paint) !void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        if (self.count == self.marks.len) return error.TestCapacity;
        self.marks[self.count] = value;
        self.count += 1;
        var color = ui.Color.rgb(0x2050c0);
        color.a = value.alpha;
        try self.buffer.roundedRect(toRect(value.rect), 0, color);
    }
    fn surface(self: *Collector) shaped.Surface {
        return .{ .context = self, .paint = paint, .paint_caret = paintCaret };
    }
    fn reset(self: *Collector) void {
        self.buffer.reset();
        self.count = 0;
        self.text_at = 0;
    }
};
fn toRect(value: anytype) ui.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}
fn sameRect(expected: anytype, actual: anytype) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| try std.testing.expectApproxEqAbs(@as(f32, @field(expected, field)), @as(f32, @field(actual, field)), 0.0001);
}
fn shapedGeometry(allocator: std.mem.Allocator, engine: *t.Engine, scale: f32) !void {
    const source = "a\u{301} office אבג 👩‍👩‍👧‍👦\r\n\nXYZ";
    var editor = try ui.editor.Editor.init(allocator, .{ .multiline = true, .autofocus = true }, source);
    defer editor.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var adapter = try shaped.Adapter.init(failing.allocator(), &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    const options: shaped.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character }, .scale = scale };
    _ = try adapter.prepare(bounds, options);
    const identity = adapter.snapshot.?.layout;
    const prepared = adapter.snapshot.?.prepared;
    const build = try identity.buildStats();
    const version = editor.buffer.revision;
    var collector: Collector = .{};
    defer collector.reset();
    try std.testing.expectError(error.CaretCellsRequired, adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block }));
    try std.testing.expectEqual(@as(usize, 0), collector.buffer.len);
    var rich = options;
    rich.caret_cells = true;
    _ = try adapter.prepare(bounds, rich);
    try std.testing.expectEqual(identity, adapter.snapshot.?.layout);
    try std.testing.expectEqual(prepared, adapter.snapshot.?.prepared);
    try std.testing.expectEqual(build, try identity.buildStats());
    try std.testing.expectEqual(version, editor.buffer.revision);
    const lines = try identity.lines();
    const count = try identity.graphemeCount();
    var expected: [256]t.Rect = undefined;
    for (0..count + 1) |gi| for ([_]t.Affinity{ .downstream, .upstream }) |affinity| {
        const byte = try identity.graphemeByte(gi);
        _ = try editor.buffer.setSelection(.{ .anchor = byte, .caret = byte });
        editor.reveal_caret = false;
        adapter.affinity = affinity;
        _ = try adapter.prepare(bounds, rich);
        const service = try adapter.caretRect(bounds, scale);
        const native = try identity.caret(.{ .byte_offset = byte, .affinity = affinity });
        const cells = if (gi < count) try identity.selectionRects(.{ .start = byte, .end = try identity.graphemeByte(gi + 1) }, &expected) else expected[0..0];
        // Independent selection API plus explicit line containment; no visual
        // neighbour arithmetic and no caret-width/average-character estimate.
        var line: usize = 0;
        while (line + 1 < lines.len and native.y + native.height * 0.5 >= lines[line].y + lines[line].height) : (line += 1) {}
        var touches = false;
        var native_count: usize = 0;
        for (cells) |cell| {
            const y = cell.y + cell.height * 0.5;
            if (cell.width <= 0 or y < lines[line].y or y >= lines[line].y + lines[line].height) continue;
            native_count += 1;
            if (native.x >= cell.x and native.x <= cell.x + cell.width) touches = true;
        }
        failing.fail_index = failing.alloc_index;
        try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block, .terminal_width = 7 });
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(collector.count > 0 and collector.text_at == collector.count);
        if (!touches or native_count == 0) {
            try std.testing.expectEqual(@as(usize, 1), collector.count);
            try sameRect(.{ .x = service.x, .y = service.y, .width = @as(f32, 7), .height = service.height }, collector.marks[0].rect);
        } else {
            // Selection may join exactly adjacent cells. Check their complete
            // horizontal coverage rather than demanding identical partitioning.
            var expected_width: f32 = 0;
            var actual_width: f32 = 0;
            for (cells) |cell| if (cell.width > 0 and cell.y + cell.height * 0.5 >= lines[line].y and cell.y + cell.height * 0.5 < lines[line].y + lines[line].height) {
                expected_width += cell.width;
            };
            for (collector.marks[0..collector.count]) |mark| actual_width += mark.rect.width;
            try std.testing.expectApproxEqAbs(expected_width, actual_width, 0.0001);
            for (collector.marks[0..collector.count]) |mark| {
                const x = mark.rect.x - bounds.x + editor.scroll.offset.x;
                const y = mark.rect.y - bounds.y + editor.scroll.offset.y;
                var contained = false;
                for (cells) |cell| if (x >= cell.x - 0.0001 and x + mark.rect.width <= cell.x + cell.width + 0.0001 and @abs(y - cell.y) < 0.0001 and @abs(mark.rect.height - cell.height) < 0.0001) {
                    contained = true;
                };
                try std.testing.expect(contained);
            }
        }
        try sameRect(service, try adapter.caretRect(bounds, scale));
        collector.reset();
        try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .underline, .thickness = 2 });
        try std.testing.expect(collector.count > 0 and collector.text_at == 0);
        for (collector.marks[0..collector.count]) |mark| try std.testing.expect(mark.rect.height <= 2);
        collector.reset();
    };
    // Draw-time controls never rebuild rows or own a second selection.
    const stats = try identity.buildStats();
    try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block, .enabled = false });
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    collector.reset();
    editor.focused = false;
    try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block, .unfocused = .outline, .terminal_width = 7 });
    try std.testing.expect(collector.count > 0 and collector.text_at == 0);
    collector.reset();
    _ = try editor.buffer.setSelection(.{ .anchor = 0, .caret = 3 });
    _ = try adapter.prepare(bounds, rich);
    try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block, .unfocused = .outline });
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    collector.reset();
    editor.focused = true;
    try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block });
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(@as(f32, 1), collector.marks[0].rect.width);
    collector.reset();
    try std.testing.expectEqual(stats, try identity.buildStats());
    _ = try editor.buffer.setSelection(.{});
    _ = try editor.buffer.setComposition("e\u{301}", .{ .anchor = 3, .caret = 3 });
    editor.refresh();
    _ = try adapter.prepare(bounds, rich);
    try adapter.drawStyled(bounds, scale, collector.surface(), .{ .shape = .block });
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(@as(f32, 1), collector.marks[0].rect.width);
    try std.testing.expectEqual(@as(u8, 255), collector.marks[0].alpha);
    collector.reset();
    _ = editor.cancelComposition();
    _ = try adapter.prepare(bounds, rich);
    try std.testing.expectError(error.InvalidCaretStyle, adapter.drawStyled(bounds, scale, collector.surface(), .{ .thickness = std.math.nan(f32) }));
    try std.testing.expectEqual(@as(usize, 0), collector.buffer.len);
    try std.testing.expectError(error.MissingCaretPainter, adapter.drawStyled(bounds, scale, .{ .context = &collector, .paint = Collector.paint }, .{}));
    // A failed opt-in geometry transaction keeps the owning cache and can be
    // retried. The old shaped layout and raster never need reconstruction.
    _ = try adapter.prepare(bounds, options);
    const old_geometry = adapter.snapshot.?.geometry;
    adapter.limits.caret_work = 0;
    try std.testing.expectError(error.CaretWorkCapacityExceeded, adapter.prepare(bounds, rich));
    try std.testing.expectEqual(old_geometry.cells_enabled, adapter.snapshot.?.geometry.cells_enabled);
    const active_identity = adapter.snapshot.?.layout;
    adapter.limits.caret_work = 1024 * 1024;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = failing.alloc_index + fail_at;
        const result = adapter.prepare(bounds, rich);
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| break else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expect(!adapter.snapshot.?.geometry.cells_enabled);
            try std.testing.expectEqual(active_identity, adapter.snapshot.?.layout);
        }
        if (fail_at > 100) return error.MissingSuccessfulAllocationSweep;
    }
}
fn emptyGeometry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .autofocus = true }, "");
    defer editor.deinit();
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    const options: shaped.Parameters = .{ .font = .{ .size = 18 }, .caret_cells = true };
    _ = try adapter.prepare(bounds, options);
    const service = try adapter.caretRect(bounds, 1);
    var collector: Collector = .{};
    defer collector.reset();
    try adapter.drawStyled(bounds, 1, collector.surface(), .{ .shape = .block, .terminal_width = 9 });
    try sameRect(.{ .x = service.x, .y = service.y, .width = @as(f32, 9), .height = service.height }, collector.marks[0].rect);
    collector.reset();
    adapter.limits.rectangles = 3;
    var plain = options;
    plain.caret_cells = false;
    _ = try adapter.prepare(bounds, plain);
    try std.testing.expectError(error.RectangleCapacityExceeded, adapter.prepare(bounds, options));
    try std.testing.expect(!adapter.snapshot.?.geometry.cells_enabled);
}

fn componentOver(source: u8, destination: u8, alpha: u8) u8 {
    return @intFromFloat(@round((@as(f64, @floatFromInt(source)) * @as(f64, @floatFromInt(alpha)) + @as(f64, @floatFromInt(destination)) * (255 - @as(f64, @floatFromInt(alpha)))) / 255));
}
fn readPixels(renderer: anytype, size: z.Size, pixels: []u32) !void {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) try renderer.readLayerPixels(false, pixels) else if (builtin.os.tag == .windows) {
        if (c.GdiFlush() == 0) return error.GdiFlush;
        @memcpy(pixels, renderer.layer_workspace.?.current().pixels.?[0..pixels.len]);
    } else for (0..size.height) |y| for (0..size.width) |x| {
        pixels[y * size.width + x] = zlc_layer_test_pixel(renderer.native.?, 0, @intCast(x), @intCast(y));
    };
}
fn finishPixels(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn pixelOracle(renderer: anytype, allocator: std.mem.Allocator, engine: *t.Engine, paint: z.Paint, transformed: bool) !void {
    var editor = try ui.editor.Editor.init(allocator, .{ .autofocus = true }, "WW");
    defer editor.deinit();
    _ = try editor.buffer.setSelection(.{});
    var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
    defer adapter.deinit() catch unreachable;
    _ = try adapter.prepare(bounds, .{ .font = .{ .size = 32 }, .scale = paint.size.scale, .caret_cells = true });
    const layout = adapter.snapshot.?.layout;
    const prepared = try adapter.snapshot.?.prepared.view();
    const cell = adapter.snapshot.?.geometry.cells[0];
    const build = try layout.buildStats();
    var collected: Collector = .{};
    defer collected.reset();
    var actual_transforms: ui.commands.TransformStorage = .{ .scale = paint.size.scale };
    if (transformed) try collected.buffer.bindTransformStorage(&actual_transforms);
    const transform = try ui.layers.NativeTransform.init(.{ .xx = 0, .yx = 1, .xy = -1, .yy = 0, .x0 = 120 }, .{ .width = 128, .height = 112 }, paint.size.scale);
    try collected.buffer.fill(.{ .x = 0, .y = 0, .width = 128, .height = 112 }, 0xffffff);
    if (transformed) {
        try collected.buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 126.5, .height = 110.5 });
        try collected.buffer.beginTransform(transform);
    }
    try collected.buffer.pushClip(.{ .x = 8.25, .y = 8.25, .width = 110.5, .height = 86.5 });
    try adapter.drawStyled(bounds, paint.size.scale, collected.surface(), .{ .shape = .block });
    try collected.buffer.popClip();
    if (transformed) {
        try collected.buffer.endTransform();
        try collected.buffer.popClip();
    }
    try collected.buffer.finish();
    var reference: ui.commands.Buffer = .{};
    defer reference.reset();
    var reference_transforms: ui.commands.TransformStorage = .{ .scale = paint.size.scale };
    if (transformed) try reference.bindTransformStorage(&reference_transforms);
    try reference.fill(.{ .x = 0, .y = 0, .width = 128, .height = 112 }, 0xffffff);
    if (transformed) {
        try reference.pushClip(.{ .x = 0.25, .y = 0.25, .width = 126.5, .height = 110.5 });
        try reference.beginTransform(transform);
    }
    try reference.pushClip(.{ .x = 8.25, .y = 8.25, .width = 110.5, .height = 86.5 });
    var reference_cells: [64]t.Rect = undefined;
    for (try layout.selectionRects(.{ .start = 0, .end = try layout.graphemeByte(1) }, &reference_cells)) |native| {
        try reference.roundedRect(.{ .x = bounds.x + native.x, .y = bounds.y + native.y, .width = native.width, .height = native.height }, 0, .{ .r = 0x20, .g = 0x50, .b = 0xc0, .a = 96 });
    }
    try reference.preparedText(.{ .x = bounds.x, .y = bounds.y }, prepared, ui.Color.rgb(0x202020));
    try reference.popClip();
    if (transformed) {
        try reference.endTransform();
        try reference.popClip();
    }
    try reference.finish();
    const pixels = try allocator.alloc(u32, @as(usize, paint.size.width) * paint.size.height);
    defer allocator.free(pixels);
    const origin_x: i32 = @intFromFloat(bounds.x * paint.size.scale);
    const origin_y: i32 = @intFromFloat(bounds.y * paint.size.scale);
    for (0..2) |_| {
        try renderer.begin(paint);
        try renderer.replayBuffer(&collected.buffer);
        try readPixels(renderer, paint.size, pixels);
        var verified: usize = 0;
        var ink: usize = 0;
        for (0..paint.size.height) |y| for (0..paint.size.width) |x| {
            const dx = @as(f64, @floatFromInt(x)) / paint.size.scale - bounds.x;
            const dy = @as(f64, @floatFromInt(y)) / paint.size.scale - bounds.y;
            // Whole physical pixels inside the cell and fractional parent
            // clip: this oracle tests source-over ordering, not edge AA.
            if (dx < cell.x + 1 or dx + 1 / paint.size.scale > cell.x + cell.width - 1 or dy < cell.y + 1 or dy + 1 / paint.size.scale > cell.y + cell.height - 1) continue;
            const mx = @as(i64, @intCast(x)) - origin_x - prepared.coverage.origin_x;
            const my = @as(i64, @intCast(y)) - origin_y - prepared.coverage.origin_y;
            const alpha: u8 = if (mx >= 0 and mx < prepared.coverage.width and my >= 0 and my < prepared.coverage.height) prepared.coverage.pixels[@as(usize, @intCast(my)) * prepared.coverage.stride + @as(usize, @intCast(mx))] else 0;
            const actual = pixels[y * paint.size.width + x];
            inline for ([_]u5{ 16, 8, 0 }, [_]u8{ 0x20, 0x50, 0xc0 }) |shift, channel| {
                const expected = componentOver(0x20, componentOver(channel, 255, 96), alpha);
                const got: u8 = @truncate(actual >> shift);
                if (!transformed and @TypeOf(renderer.*) == ui.SoftwareRenderer and @abs(@as(i32, expected) - @as(i32, got)) > 1) {
                    std.debug.print("caret pixel backend={s} scale={d} x={d} y={d} alpha={d} shift={d} expected={d} actual={x}\n", .{ @typeName(@TypeOf(renderer.*)), paint.size.scale, x, y, alpha, shift, expected, actual });
                    return error.CaretPixelMismatch;
                }
            }
            verified += 1;
            if (alpha > 200) ink += 1;
        };
        try std.testing.expect(verified > 20 and ink > 5);
        try finishPixels(renderer, paint);
        // Native font rasterization is backend-specific. Compare GPU output
        // with independently authored native commands for the same layout,
        // rather than treating the software A8 raster as GPU coverage.
        if (transformed or @TypeOf(renderer.*) != ui.SoftwareRenderer) {
            const native_reference = try allocator.alloc(u32, pixels.len);
            defer allocator.free(native_reference);
            try renderer.begin(paint);
            try renderer.replayBuffer(&reference);
            try readPixels(renderer, paint.size, native_reference);
            try std.testing.expectEqualSlices(u32, pixels, native_reference);
            try finishPixels(renderer, paint);
        }
    }
    try std.testing.expectEqual(build, try layout.buildStats());
}
fn nativePixels(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 128, .height = 112 });
    defer _ = window.destroy() catch unreachable;
    var dc: ?*anyopaque = null;
    var cairo_surface: ?*anyopaque = null;
    if (builtin.os.tag == .windows) dc = c.GetDC(window.nativeHandle()) orelse return error.NoSurface else {
        cairo_surface = cairo_image_surface_create(0, 256, 224) orelse return error.NoSurface;
        dc = cairo_create(cairo_surface.?) orelse return error.NoSurface;
    }
    defer if (builtin.os.tag == .windows) {
        _ = c.ReleaseDC(window.nativeHandle(), dc);
    } else {
        cairo_destroy(dc.?);
        cairo_surface_destroy(cairo_surface.?);
    };
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const size: z.Size = .{ .width = @intFromFloat(128 * scale), .height = @intFromFloat(112 * scale), .scale = scale };
        const paint: z.Paint = .{ .native_context = dc.?, .native_window = if (builtin.os.tag == .windows) window.nativeHandle() else null, .size = size };
        {
            var renderer: ui.SoftwareRenderer = .{};
            defer renderer.deinit();
            try renderer.prepareTransforms(allocator, .{ .layers = .{ .size = size, .max_depth = 1 }, .source_size = .{ .width = 128, .height = 112 } });
            for ([_]bool{ false, true }) |transformed| try pixelOracle(&renderer, allocator, engine, paint, transformed);
        }
        if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
            var renderer: ui.d3d11.Renderer = .{};
            try renderer.init(.{ .driver = driver });
            defer renderer.deinit();
            try renderer.prepareTransforms(allocator, .{ .layers = .{ .size = size, .max_depth = 1 }, .source_size = .{ .width = 128, .height = 112 } });
            for ([_]bool{ false, true }) |transformed| try pixelOracle(&renderer, allocator, engine, paint, transformed);
        };
    }
}

const DocumentHost = struct {
    adapter: *editing.Adapter,
    context: ui.Context = undefined,
    window: z.Window = undefined,
    style: ?caret.Style = null,
    failure: ?anyerror = null,
    backgrounds: usize = 0,
    draw_started: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *DocumentHost = @ptrCast(@alignCast(ptr));
        self.draw_started = true;
        frame.clear(0xffffff);
        self.adapter.draw(frame, bounds, .{ .caret_style = self.style }) catch |err| {
            self.failure = err;
        };
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *DocumentHost = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn paint(self: *DocumentHost) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_paint(native, 160, 112);
        }
        if (self.failure) |err| return err;
        try std.testing.expect(self.draw_started);
    }
};
fn documentGeometry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "office אבג\r\n\nZ", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    _ = try adapter.setSelections(&.{ .{ .anchor = 0, .caret = 0 }, .{ .anchor = 7, .caret = 7 }, .{ .anchor = 16, .caret = 16 } }, 0);
    var parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character } };
    _ = try adapter.prepare(bounds, parameters);
    const before = try adapter.stats();
    const projection = try adapter.projectionVersion();
    const service = try adapter.caretRect(bounds, 1);
    const revision = try document.version();
    parameters.caret_cells = true;
    const prepared = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 0), prepared.shaped_batches);
    try std.testing.expectEqual(before.shaped_batches, (try adapter.stats()).shaped_batches);
    try std.testing.expectEqual(projection, try adapter.projectionVersion());
    try sameRect(service, try adapter.caretRect(bounds, 1));
    try std.testing.expectEqual(revision, try document.version());
    var host: DocumentHost = .{ .adapter = adapter, .style = .{ .shape = .block } };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = DocumentHost.diagnostic } });
    defer app.deinit();
    host.context = ui.Context.init(&host, DocumentHost.draw, DocumentHost.action);
    host.window = try app.createWindow(.{ .width = 160, .height = 112 });
    defer _ = host.window.destroy() catch unreachable;
    try host.context.attach(host.window);
    parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(host.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(host.window.nativeHandle().?));
    _ = try adapter.prepare(bounds, parameters);
    try adapter.bind(host.window);
    defer {
        _ = host.window.destroy() catch unreachable;
        adapter.unbind() catch unreachable;
    }
    // Allocation is disabled only after the viewport and all native text have
    // been prepared. Frame drawing must use those exact immutable resources.
    failing.fail_index = failing.alloc_index;
    try host.paint();
    failing.fail_index = std.math.maxInt(usize);
    host.style = .{ .shape = .underline, .thickness = 2 };
    try host.paint();
    host.style = .{ .shape = .block, .unfocused = .outline, .active = false };
    try host.paint();
    try std.testing.expectEqual(revision, try document.version());
    try std.testing.expectEqual(before.shaped_batches, (try adapter.stats()).shaped_batches);
    // Candidate allocation failure preserves the last fully prepared view.
    parameters.caret_cells = false;
    _ = try adapter.prepare(bounds, parameters);
    const old = try adapter.stats();
    parameters.caret_cells = true;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = failing.alloc_index + fail_at;
        const result = adapter.prepare(bounds, parameters);
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| break else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expectEqual(old.owned_bytes, (try adapter.stats()).owned_bytes);
            try std.testing.expect((try adapter.status()).layout_required);
            try std.testing.expectEqual(revision, try document.version());
        }
        if (fail_at > 100) return error.MissingSuccessfulAllocationSweep;
    }
}

fn wordOptionCache(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const text = "alpha beta";
    for ([_]bool{ false, true }) |initial| {
        {
            var editor = try ui.editor.Editor.init(allocator, .{}, text);
            defer editor.deinit();
            var adapter = try shaped.Adapter.init(allocator, &editor, engine, .{});
            defer adapter.deinit() catch unreachable;
            var parameters: shaped.Parameters = .{ .font = .{ .word_ranges = initial } };
            _ = try adapter.prepare(bounds, parameters);
            const previous = adapter.snapshot.?.layout;
            try std.testing.expectEqual(initial, (try previous.options()).word_ranges);
            parameters.font.word_ranges = !initial;
            try std.testing.expect(try adapter.prepare(bounds, parameters));
            const current = adapter.snapshot.?.layout;
            try std.testing.expect(previous != current);
            try std.testing.expectEqual(!initial, (try current.options()).word_ranges);
            if (initial) {
                try std.testing.expectError(error.WordRangesNotEnabled, current.wordRangeAt(.{ .byte_offset = 1 }));
            } else {
                try std.testing.expectEqualDeep(t.ByteRange{ .start = 0, .end = 5 }, try current.wordRangeAt(.{ .byte_offset = 1 }));
            }
        }
        {
            const document = try d.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
            defer document.close() catch unreachable;
            const adapter = try editing.Adapter.create(allocator, document, engine, .{});
            defer adapter.close() catch unreachable;
            var parameters: editing.Parameters = .{ .font = .{ .word_ranges = initial } };
            _ = try adapter.prepare(bounds, parameters);
            const previous = try adapter.stats();
            const revision = try document.version();
            parameters.font.word_ranges = !initial;
            const result = try adapter.prepare(bounds, parameters);
            try std.testing.expect(result.changed);
            try std.testing.expectEqual(@as(usize, 1), result.shaped_batches);
            try std.testing.expectEqual(previous.shaped_batches + 1, (try adapter.stats()).shaped_batches);
            try std.testing.expectEqual(revision, try document.version());
        }
    }
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const before = t.resourceCounts();
    {
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        try wordOptionCache(allocator, engine);
        try geometryPin(allocator, engine);
        try geometryReentry(allocator, engine);
        try emptyGeometry(allocator, engine);
        for ([_]f32{ 1, 1.5, 2 }) |scale| try shapedGeometry(allocator, engine, scale);
        try documentGeometry(allocator, engine);
        try nativePixels(allocator, engine);
    }
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
        try std.testing.expectEqual(@as(u32, 0), zlc_layer_live_objects());
    }
    std.debug.print("editor carets: native grapheme cells, bidi/wrap/CRLF/EOF, three DPI, block/underline/blur, multicaret, cache/undo authority and allocation-free replay passed; resources=0\n", .{});
}
