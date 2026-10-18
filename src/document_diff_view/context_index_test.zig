const std = @import("std");
const diff = @import("ziggurat_document_diff");
const aligned = @import("index.zig");
const unified = @import("unified_index.zig");
const context = @import("context_index.zig");
fn result() diff.Result {
    return .{ .allocator = std.testing.allocator, .storage = &.{}, .hunks = &.{
        .{ .a = .{ .lines = .{ .start = 10, .end = 12 }, .bytes = .{ .start = 0, .end = 0 } }, .b = .{ .lines = .{ .start = 10, .end = 13 }, .bytes = .{ .start = 0, .end = 0 } } },
        .{ .a = .{ .lines = .{ .start = 52, .end = 53 }, .bytes = .{ .start = 0, .end = 0 } }, .b = .{ .lines = .{ .start = 53, .end = 55 }, .bytes = .{ .start = 0, .end = 0 } } },
    }, .a = .{ .revision = 7, .text_version = 3, .bytes = 0 }, .b = .{ .revision = 8, .text_version = 4, .bytes = 0 }, .stats = .{ .lines_a = 100, .lines_b = 102 } };
}
fn baseIndex(model: *const diff.Result, mode: context.Mode, allocator: std.mem.Allocator) !aligned.Index {
    return if (mode == .split) aligned.Index.create(allocator, model, 200000, 8 * 1024 * 1024, 20) else unified.create(allocator, model, 200000, 8 * 1024 * 1024, 20);
}
test "context regions hide only common interiors and preserve stable source/header identities" {
    var model = result();
    for ([_]context.Mode{ .split, .unified }) |mode| {
        var index = try context.Index.create(std.testing.allocator, &model, mode, .{ .context_lines = 2, .minimum_hidden = 2 });
        defer index.close();
        try std.testing.expectEqual(@as(usize, 3), index.regions.len);
        try std.testing.expectEqualDeep(diff.LineRange{ .start = 2, .end = 8 }, index.regions[0].a);
        try std.testing.expectEqualDeep(diff.LineRange{ .start = 14, .end = 50 }, index.regions[1].a);
        try std.testing.expectEqualDeep(diff.LineRange{ .start = 15, .end = 51 }, index.regions[1].b);
        try std.testing.expectEqual(@as(usize, if (mode == .split) 102 else 105), index.raw_rows);
        try std.testing.expectEqual(@as(usize, if (mode == .split) 17 else 20), index.visible_rows);
        for (index.regions) |region| {
            try std.testing.expect((try index.rawToVisible(region.first - 1)) != null);
            try std.testing.expect(try index.rawToVisible(region.first) == null);
            try std.testing.expect((try index.rawToVisible(region.end)) != null);
        }
        var changed = try context.Index.create(std.testing.allocator, &model, mode, .{ .context_lines = 5 });
        defer changed.close();
        try std.testing.expectEqual(@as(usize, 2), changed.regions.len);
        try std.testing.expectEqual(@as(u64, 2), changed.regions[0].id);
    }
}
test "random toggles and reveals match a separate linear visibility/height/source oracle" {
    var model = result();
    var random = std.Random.DefaultPrng.init(0xc9072);
    for ([_]context.Mode{ .split, .unified }) |mode| {
        var index = try context.Index.create(std.testing.allocator, &model, mode, .{ .context_lines = 2 });
        defer index.close();
        var base = try baseIndex(&model, mode, std.testing.allocator);
        defer base.close();
        for (base.heights, 0..) |_, at| base.set(at, random.random().uintLessThan(u64, 10000) + 1);
        for (0..250) |_| {
            const at = random.random().uintLessThan(usize, index.regions.len);
            if (random.random().boolean()) {
                _ = try index.setCollapsed(index.regions[at].id, random.random().boolean());
            } else _ = try index.reveal(index.regions[at].first);
            var hidden: [200]bool = @splat(false);
            for (index.regions) |region| if (region.collapsed) @memset(hidden[region.first..region.end], true);
            var projected = try index.project(std.testing.allocator, &base, 8 * 1024 * 1024);
            defer projected.close();
            var visible: usize = 0;
            var ticks: u64 = 0;
            for (0..index.raw_rows) |raw| {
                if (hidden[raw]) {
                    try std.testing.expect(try index.rawToVisible(raw) == null);
                    try std.testing.expect((try index.containing(raw)) != null);
                } else {
                    try std.testing.expectEqual(visible, (try index.rawToVisible(raw)).?);
                    try std.testing.expectEqual(raw, try index.visibleToRaw(visible));
                    try std.testing.expectEqualDeep(base.row(raw), projected.row(visible));
                    try std.testing.expectEqual(ticks, projected.prefix(visible));
                    try std.testing.expectEqual(base.heights[raw], projected.heights[visible]);
                    ticks += base.heights[raw];
                    visible += 1;
                }
            }
            try std.testing.expectEqual(visible, index.visible_rows);
            try std.testing.expectEqual(ticks, projected.prefix(visible));
            for (0..model.hunks.len) |hunk| try std.testing.expect(projected.hunkRow(hunk) != null);
        }
    }
}
fn allocations(allocator: std.mem.Allocator) !void {
    var model = result();
    var context_index = try context.Index.create(allocator, &model, .split, .{});
    defer context_index.close();
    var copy = try context_index.clone(allocator);
    defer copy.close();
    _ = try copy.setCollapsed(copy.regions[0].id, false);
    var base = try baseIndex(&model, .split, allocator);
    defer base.close();
    var projected = try copy.project(allocator, &base, 8 * 1024 * 1024);
    defer projected.close();
    try std.testing.expect(context_index.visible_rows < copy.visible_rows);
}
test "every context/clone/height candidate allocation failure and explicit budget boundary" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocations, .{});
    var model = result();
    var index = try context.Index.create(std.testing.allocator, &model, .split, .{});
    defer index.close();
    try std.testing.expectError(error.CapacityExceeded, context.Index.create(std.testing.allocator, &model, .split, .{ .bytes = index.bytes - 1 }));
    try std.testing.expectError(error.FoldCapacityExceeded, context.Index.create(std.testing.allocator, &model, .split, .{ .regions = 1 }));
    try std.testing.expectError(error.RowCapacityExceeded, context.Index.create(std.testing.allocator, &model, .split, .{ .rows = 100 }));
    try std.testing.expectError(error.InvalidLimits, context.Index.create(std.testing.allocator, &model, .split, .{ .context_lines = 0 }));
    var base = try baseIndex(&model, .split, std.testing.allocator);
    defer base.close();
    try std.testing.expectError(error.CapacityExceeded, index.project(std.testing.allocator, &base, base.bytes));
    try std.testing.expectError(error.FoldNotFound, index.setCollapsed(999, true));
    try std.testing.expectError(error.InvalidRow, index.visibleToRaw(index.visible_rows));
    try std.testing.expectError(error.InvalidRow, index.rawToVisible(index.raw_rows));
}
test "empty and 100k common rows have bounded context metadata and no fake EOF record" {
    var model = result();
    model.hunks = &.{};
    model.stats.lines_a = 100000;
    model.stats.lines_b = 100000;
    var index = try context.Index.create(std.testing.allocator, &model, .unified, .{});
    defer index.close();
    try std.testing.expectEqual(@as(usize, 6), index.visible_rows);
    try std.testing.expectEqual(@as(usize, 99997), try index.visibleToRaw(3));
    try std.testing.expect(index.bytes < 256);
    model.stats.lines_a = 0;
    model.stats.lines_b = 0;
    var empty = try context.Index.create(std.testing.allocator, &model, .split, .{});
    defer empty.close();
    try std.testing.expectEqual(@as(usize, 0), empty.raw_rows);
    try std.testing.expectEqual(@as(usize, 0), empty.visible_rows);
    try std.testing.expectError(error.InvalidRow, empty.visibleToRaw(0));
    empty.close();
    try std.testing.expectError(error.Closed, empty.clone(std.testing.allocator));
    model.owned = false;
    try std.testing.expectError(error.ResultMoved, context.Index.create(std.testing.allocator, &model, .split, .{}));
}
