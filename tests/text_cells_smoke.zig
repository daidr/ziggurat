const std = @import("std");
const text = @import("ziggurat_text_layout");
const outlines = @import("ziggurat_text_outlines");
extern fn ztc_single_cell(*anyopaque, u32, *[4]f64) c_int;

fn candidate(allocator: std.mem.Allocator, layout: *text.Layout) !void {
    const shape = try outlines.fromLayout(layout, allocator, .{ .include_cells = true });
    defer shape.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, (try layout.metrics()).glyphs), (try shape.cells()).len);
}

fn verify(allocator: std.mem.Allocator) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    for ([_][]const u8{ "O", "j", " " }) |source| for ([_]bool{ false, true }) |italic| {
        const layout = try engine.layout(source, .{ .size = 24, .italic = italic });
        defer layout.close() catch unreachable;
        const prepared = try layout.prepare(1, .{});
        defer prepared.close() catch unreachable;
        const snapshot = try layout.outline(allocator, .{ .include_cells = true });
        defer snapshot.close() catch unreachable;
        const cells = try snapshot.cells();
        try std.testing.expectEqual(@as(usize, 1), cells.len);
        var expected: [4]f64 = undefined;
        try std.testing.expectEqual(@as(c_int, 0), ztc_single_cell((try prepared.view()).native_layout, source[0], &expected));
        inline for (.{ "x", "y", "width", "height" }, 0..) |field, index| try std.testing.expectApproxEqAbs(expected[index], @field(cells[0], field), 1e-4);
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_cells = true });
        const geometry = try shape.takeGeometry();
        defer geometry.path.close() catch unreachable;
        defer geometry.path.allocator.free(geometry.cells);
        try std.testing.expectEqual(@as(usize, 1), geometry.cells.len);
        const ink = try geometry.path.bounds(.{}, null);
        if (source[0] == ' ') {
            try std.testing.expect(ink == null);
            try std.testing.expect(geometry.cells[0].width > 0 and geometry.cells[0].height > 0);
        } else try std.testing.expect(geometry.cells[0].height > ink.?.height);
    };
    for ([_][]const u8{ "Office A O", "العربية", "ABC אבג 123", "क्षि", "a\u{301} 😀", "A\nB" }) |source| {
        const layout = try engine.layout(source, .{ .size = 24 });
        const metrics = try layout.metrics();
        const plain = try layout.outline(allocator, .{});
        try std.testing.expectEqual(@as(usize, 0), (try plain.cells()).len);
        try plain.close();
        const shape = try outlines.fromLayout(layout, allocator, .{ .include_cells = true });
        const values = try shape.cells();
        try std.testing.expectEqual(@as(usize, metrics.glyphs), values.len);
        for (values) |cell| {
            try std.testing.expect(std.math.isFinite(cell.x) and std.math.isFinite(cell.y) and cell.width >= 0 and cell.height > 0);
        }
        const peak = (try shape.stats()).peak_owned_bytes;
        try std.testing.expectError(error.CapacityExceeded, outlines.fromLayout(layout, allocator, .{ .include_cells = true, .limits = .{ .bytes = peak - 1 } }));
        try std.testing.checkAllAllocationFailures(allocator, candidate, .{layout});
        try layout.close();
        // The complete cell array remains owned after native layout teardown.
        try std.testing.expectEqual(values.len, (try shape.cells()).len);
        try shape.close();
    }
    const empty = try engine.layout("", .{});
    defer empty.close() catch unreachable;
    const snapshot = try empty.outline(allocator, .{ .include_cells = true });
    defer snapshot.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), (try snapshot.cells()).len);
    const cell_size = @sizeOf(text.outlines.GlyphCell);
    try std.testing.expectEqual(@as(usize, 32), cell_size);
}

pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    try verify(heap.allocator());
    const counts = text.resourceCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.references);
    try std.testing.expectEqual(@as(u32, 0), counts.layouts);
    std.debug.print("glyph cells passed: independent font metric oracle, whitespace/italic/complex runs, explicit ownership/budgets/OOM and refs=0\n", .{});
}
