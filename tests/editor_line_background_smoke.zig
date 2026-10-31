const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;

const bounds: ui.Rect = .{ .x = 8, .y = 8, .width = 112, .height = 168 };
const source = "office אבג e\u{301} 👩‍👩‍👧‍👦 long wrapped paragraph\r\n\nZ\n";
const Host = struct {
    adapter: *editing.Adapter,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    scale: f32 = 1,
    failure: ?anyerror = null,
    paints: usize = 0,
    expected: usize = 0,
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.checked(frame) catch |err| {
            self.failure = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn checked(self: *Host, frame: *ui.Frame) !void {
        self.paints += 1;
        frame.clear(0xffffff);
        try self.adapter.draw(frame, bounds, .{});
        var marks: [16]editing.LineBackgroundMark = undefined;
        const visible = try self.adapter.preparedLineBackgrounds(bounds, &marks);
        try std.testing.expectEqual(self.expected, visible.len);
        var at: usize = 0;
        var saw_text = false;
        for (frame.context.command_buffer.commands()) |command| switch (command) {
            .fill => |fill| {
                if (fill.color == 0xffffff) continue;
                if (at < visible.len) {
                    try std.testing.expect(!saw_text);
                    try std.testing.expectEqual(visible[at].color, fill.color);
                    try sameRect(visible[at].rect, fill.bounds);
                    at += 1;
                }
            },
            .prepared_text => saw_text = true,
            else => {},
        };
        try std.testing.expectEqual(visible.len, at);
        try std.testing.expect(saw_text);
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn paint(self: *Host) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const native = self.window.app.windows.get(self.window.key).?.native.native.?;
            zlg_test_paint(native, @intFromFloat(144 * self.scale), @intFromFloat(192 * self.scale));
        }
        if (self.failure) |err| return err;
        try std.testing.expect(self.paints != 0);
    }
};
fn sameRect(expected: ui.Rect, actual: ui.Rect) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| try std.testing.expectApproxEqAbs(@field(expected, field), @field(actual, field), 0.001);
}
fn records(document: *d.Document, destination: []editing.LineBackground) ![]const editing.LineBackground {
    const count = try document.lineCount();
    if (destination.len < count) return error.TestCapacity;
    for (0..count) |line| destination[line] = .{ .paragraph = (try document.line(line)).start, .color = @as(u32, @intCast(0xd00000 + line * 0x101)) };
    return destination[0..count];
}
fn geometry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), source, .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{});
    defer adapter.close() catch unreachable;
    var definitions: [16]editing.LineBackground = undefined;
    const items = try records(document, &definitions);
    const stamp = try document.committedTextVersion();
    try std.testing.expect((try adapter.setLineBackgrounds(stamp, items)).current);
    var parameters: editing.Parameters = .{ .font = .{ .size = 18, .wrap = .word_character } };
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        parameters.scale = scale;
        _ = try adapter.prepare(bounds, parameters);
        var native_options = parameters.font;
        native_options.width = bounds.width;
        const native = try engine.layout(source, native_options);
        defer native.close() catch unreachable;
        const metrics = try native.metrics();
        var marks: [16]editing.LineBackgroundMark = undefined;
        const visible = try adapter.preparedLineBackgrounds(bounds, &marks);
        var expected: usize = 0;
        for (items, 0..) |item, index| {
            const top = (try native.caret(.{ .byte_offset = item.paragraph })).y;
            const bottom = if (index + 1 < items.len) (try native.caret(.{ .byte_offset = items[index + 1].paragraph })).y else metrics.bounds.y + metrics.bounds.height;
            const rect = ui.layout.intersect(bounds, .{ .x = bounds.x, .y = bounds.y + top, .width = bounds.width, .height = bottom - top });
            if (rect.height <= 0) continue;
            try std.testing.expectEqual(item.paragraph, visible[expected].paragraph);
            try std.testing.expectEqual(item.color, visible[expected].color);
            try sameRect(rect, visible[expected].rect);
            expected += 1;
        }
        try std.testing.expectEqual(expected, visible.len);
        try std.testing.expect(visible.len >= 2);
        try std.testing.expectError(error.BufferTooSmall, adapter.preparedLineBackgrounds(bounds, &.{}));
        const previous = try adapter.stats();
        _ = try adapter.setSelection(.{ .anchor = 1, .caret = 1 }, .downstream);
        _ = try adapter.prepare(bounds, parameters);
        try std.testing.expect(!(try adapter.status()).line_backgrounds_required);
        try std.testing.expectEqual(previous.shaped_batches, (try adapter.stats()).shaped_batches);
    }
    // A projected gap belongs to layout policy, not to a paragraph's text.
    const plan = try editing.ProjectionPlan.create(allocator, document, &.{.{ .line = 1, .gap_before = 13, .minimum_height = 40 }}, .{});
    defer plan.close() catch unreachable;
    try adapter.setProjection(plan);
    defer adapter.setProjection(null) catch unreachable;
    _ = try adapter.prepare(bounds, parameters);
    var projected: [16]editing.LineBackgroundMark = undefined;
    const projected_marks = try adapter.preparedLineBackgrounds(bounds, &projected);
    try std.testing.expect(projected_marks.len >= 2);
    try std.testing.expect(projected_marks[1].rect.y >= projected_marks[0].rect.y + projected_marks[0].rect.height + 12.99);
    try adapter.setProjection(null);
    try adapter.setFolds(try document.version(), &.{.{ .id = 1, .header = 0, .end = items[2].paragraph, .collapsed = true }});
    _ = try adapter.prepare(bounds, parameters);
    const folded = try adapter.preparedLineBackgrounds(bounds, &projected);
    for (folded) |mark| try std.testing.expect(mark.paragraph != items[1].paragraph);
    try adapter.setFolds(try document.version(), &.{});
    _ = try adapter.prepare(bounds, parameters);
    // Composition has a separate display coordinate system; no committed mark
    // is silently mapped onto that temporary text.
    try document.setComposition("TEMP\n", .{});
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &projected)).len);
    try std.testing.expectError(error.CompositionActive, adapter.setLineBackgrounds(stamp, items));
    _ = try document.cancelComposition();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.preparedLineBackgrounds(bounds, &projected)).len != 0);
    _ = try adapter.replace(.{ .start = 0, .end = 1 }, "Z");
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.status()).line_backgrounds_required);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &projected)).len);
    try std.testing.expectError(error.StaleRevision, adapter.setLineBackgrounds(stamp, items));
    _ = try adapter.undo();
    _ = try adapter.prepare(bounds, parameters);
    try std.testing.expect((try adapter.status()).line_backgrounds_required);
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &projected)).len);
    try std.testing.expect((try adapter.setLineBackgrounds(try document.committedTextVersion(), items)).current);
    _ = try adapter.prepare(bounds, parameters);
    var host: Host = .{ .adapter = adapter };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer app.deinit();
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.window = try app.createWindow(.{ .width = 144, .height = 192 });
    defer _ = host.window.destroy() catch unreachable;
    host.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(host.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(host.window.nativeHandle().?));
    parameters.scale = host.scale;
    _ = try adapter.prepare(bounds, parameters);
    host.expected = (try adapter.preparedLineBackgrounds(bounds, &projected)).len;
    try host.context.attach(host.window);
    try adapter.bind(host.window);
    defer {
        _ = host.window.destroy() catch unreachable;
        adapter.unbind() catch unreachable;
    }
    const before = try adapter.stats();
    failing.fail_index = failing.alloc_index;
    try host.paint();
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(before.owned_bytes, (try adapter.stats()).owned_bytes);
    try std.testing.expectEqual(before.shaped_batches, (try adapter.stats()).shaped_batches);
}

const Hook = struct {
    child: std.mem.Allocator,
    document: *d.Document,
    size: usize = 0,
    on_alloc: bool = false,
    hits: usize = 0,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn change(self: *Hook) void {
        self.size = 0;
        self.hits += 1;
        self.document.replace(.{ .start = 0, .end = 1 }, if (self.hits == 1) "X" else "Y") catch unreachable;
    }
    fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        const result = self.child.rawAlloc(size, alignment, ra);
        if (result != null and self.on_alloc and self.size == size) self.change();
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Hook = @ptrCast(@alignCast(ptr));
        if (!self.on_alloc and self.size == bytes.len) self.change();
        self.child.rawFree(bytes, alignment, ra);
    }
};
fn reentry(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    for ([_]bool{ false, true }) |on_alloc| {
        const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a\nb\n", .{});
        defer document.close() catch unreachable;
        var hook: Hook = .{ .child = allocator, .document = document, .on_alloc = on_alloc };
        const adapter = try editing.Adapter.create(hook.allocator(), document, engine, .{});
        defer adapter.close() catch unreachable;
        const definitions = [_]editing.LineBackground{ .{ .paragraph = 0, .color = 1 }, .{ .paragraph = 2, .color = 2 } };
        const stamp = try document.committedTextVersion();
        _ = try adapter.setLineBackgrounds(stamp, &definitions);
        _ = try adapter.prepare(bounds, .{});
        hook.size = @sizeOf(editing.LineBackground) * definitions.len;
        if (on_alloc) {
            try std.testing.expectError(error.StaleRevision, adapter.setLineBackgrounds(stamp, &definitions));
        } else {
            try std.testing.expect(!(try adapter.setLineBackgrounds(stamp, &definitions)).current);
        }
        try std.testing.expectEqual(@as(usize, 1), hook.hits);
        _ = try adapter.prepare(bounds, .{});
        var marks: [4]editing.LineBackgroundMark = undefined;
        try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &marks)).len);
        _ = try adapter.setLineBackgrounds(try document.committedTextVersion(), &definitions);
        _ = try adapter.prepare(bounds, .{});
        // Retired prepared geometry is a second foreign-free boundary.
        hook.on_alloc = false;
        hook.size = @sizeOf(editing.LineBackgroundMark) * 2;
        _ = try adapter.setSelection(.{ .anchor = 0, .caret = 0 }, .downstream);
        try std.testing.expectError(error.IndexRequired, adapter.prepare(bounds, .{}));
        try std.testing.expectEqual(@as(usize, 2), hook.hits);
        try std.testing.expect((try adapter.status()).line_backgrounds_required);
        _ = try adapter.prepare(bounds, .{});
        try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &marks)).len);
    }
}
fn failures(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "a\r\nb\n", .{});
    defer document.close() catch unreachable;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const adapter = try editing.Adapter.create(failing.allocator(), document, engine, .{ .line_backgrounds = 2 });
    defer adapter.close() catch unreachable;
    const stamp = try document.committedTextVersion();
    const definitions = [_]editing.LineBackground{ .{ .paragraph = 0, .color = 1 }, .{ .paragraph = 3, .color = 2 } };
    _ = try adapter.setLineBackgrounds(stamp, &definitions);
    _ = try adapter.prepare(bounds, .{});
    const version = try document.version();
    try std.testing.expectError(error.InvalidLineBackground, adapter.setLineBackgrounds(stamp, &.{.{ .paragraph = 1, .color = 0 }}));
    try std.testing.expectError(error.InvalidLineBackground, adapter.setLineBackgrounds(stamp, &.{.{ .paragraph = 2, .color = 0 }}));
    try std.testing.expectError(error.InvalidRange, adapter.setLineBackgrounds(stamp, &.{.{ .paragraph = 6, .color = 0 }}));
    try std.testing.expectError(error.LineBackgroundCapacityExceeded, adapter.setLineBackgrounds(stamp, &.{ .{ .paragraph = 0, .color = 0 }, .{ .paragraph = 3, .color = 0 }, .{ .paragraph = 5, .color = 0 } }));
    const before = try adapter.stats();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, adapter.setLineBackgrounds(stamp, &definitions));
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(before.owned_bytes, (try adapter.stats()).owned_bytes);
    var marks: [4]editing.LineBackgroundMark = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try adapter.preparedLineBackgrounds(bounds, &marks)).len);
    var observed_oom = false;
    var completed = false;
    for (0..32) |offset| {
        _ = try adapter.setLineBackgrounds(stamp, &definitions);
        failing.fail_index = failing.alloc_index + offset;
        const result = adapter.prepare(bounds, .{});
        failing.fail_index = std.math.maxInt(usize);
        if (result) |prepared| {
            try std.testing.expectEqual(@as(usize, 0), prepared.shaped_batches);
            try std.testing.expectEqual(before.shaped_batches, (try adapter.stats()).shaped_batches);
            completed = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            observed_oom = true;
            _ = try adapter.prepare(bounds, .{});
            try std.testing.expectEqual(@as(usize, 2), (try adapter.preparedLineBackgrounds(bounds, &marks)).len);
        }
    }
    try std.testing.expect(observed_oom and completed);
    try std.testing.expectEqual(version, try document.version());
    _ = try adapter.setLineBackgrounds(stamp, &.{});
    _ = try adapter.prepare(bounds, .{});
    try std.testing.expectEqual(@as(usize, 0), (try adapter.preparedLineBackgrounds(bounds, &marks)).len);
    const disabled = try editing.Adapter.create(failing.allocator(), document, engine, .{ .line_backgrounds = 0 });
    defer disabled.close() catch unreachable;
    _ = try disabled.prepare(bounds, .{});
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    try std.testing.expect((try disabled.setLineBackgrounds(stamp, &.{})).current);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.LineBackgroundCapacityExceeded, disabled.setLineBackgrounds(stamp, &definitions));
    const unicode = try d.Document.create(allocator, std.Thread.getCurrentId(), "é\n", .{});
    defer unicode.close() catch unreachable;
    const unicode_adapter = try editing.Adapter.create(allocator, unicode, engine, .{});
    defer unicode_adapter.close() catch unreachable;
    try std.testing.expectError(error.InvalidBoundary, unicode_adapter.setLineBackgrounds(try unicode.committedTextVersion(), &.{.{ .paragraph = 1, .color = 0 }}));
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
        try reentry(allocator, engine);
        try geometry(allocator, engine);
    }
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("line backgrounds: committed byte paragraphs, wrap/bidi/CRLF/EOF, projection/folds/IME, stale/undo, OOM and foreign-free publication, no draw allocations resources=0\n", .{});
}
