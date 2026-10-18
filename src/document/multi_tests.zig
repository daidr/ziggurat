const std = @import("std");
const d = @import("root.zig");
const a = std.testing.allocator;

test "explicit post edit selections commit once and survive undo redo" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc def", .{});
    defer doc.close() catch unreachable;
    const original: d.Selection = .{ .anchor = 3, .caret = 0 };
    _ = try doc.setSelection(original);
    const revision = try doc.version();
    const edits = [_]d.Replacement{ .{ .range = .{ .start = 0, .end = 3 }, .text = "猫" }, .{ .range = .{ .start = 4, .end = 7 }, .text = "😀" } };
    const selected = [_]d.Selection{ .{ .anchor = 3, .caret = 0 }, .{ .anchor = 4, .caret = 8 } };
    try doc.replaceManyWithSelections(revision, &edits, &selected, 1);
    try std.testing.expectEqual(revision + 1, try doc.version());
    try expectText(doc, "猫 😀");
    try std.testing.expectEqual(selected[1], try doc.selection());
    try std.testing.expect(try doc.undo());
    try expectText(doc, "abc def");
    try std.testing.expectEqual(original, try doc.selection());
    try std.testing.expect(try doc.redo());
    var output: [2]d.Selection = undefined;
    const actual = try doc.selections(&output);
    try std.testing.expectEqualSlices(d.Selection, &selected, actual.items);
    try std.testing.expectEqual(@as(usize, 1), actual.primary);
}
fn explicitCandidate(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "abc def", .{});
    defer doc.close() catch unreachable;
    const revision = try doc.version();
    doc.replaceManyWithSelections(revision, &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "猫😀" }}, &.{ .{ .anchor = 0, .caret = 3 }, .{ .anchor = 3, .caret = 7 } }, 1) catch |err| {
        try std.testing.expectEqual(revision, try doc.version());
        try expectText(doc, "abc def");
        try std.testing.expect(!try doc.canUndo());
        return err;
    };
    try expectText(doc, "猫😀 def");
}
test "explicit post edit selections validate candidates transactionally including OOM" {
    try std.testing.checkAllAllocationFailures(a, explicitCandidate, .{});
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc", .{});
    defer doc.close() catch unreachable;
    const revision = try doc.version();
    const edits = [_]d.Replacement{.{ .range = .{ .start = 0, .end = 3 }, .text = "猫😀" }};
    try std.testing.expectError(error.InvalidBoundary, doc.replaceManyWithSelections(revision, &edits, &.{.{ .anchor = 1, .caret = 7 }}, 0));
    try std.testing.expectError(error.InvalidRange, doc.replaceManyWithSelections(revision, &edits, &.{.{ .anchor = 0, .caret = 8 }}, 0));
    try std.testing.expectError(error.InvalidSelections, doc.replaceManyWithSelections(revision, &edits, &.{}, 0));
    try std.testing.expectError(error.EmptyEdits, doc.replaceManyWithSelections(revision, &.{}, &.{.{}}, 0));
    try std.testing.expectEqual(revision, try doc.version());
    try expectText(doc, "abc");
    try std.testing.expect(!try doc.canUndo());
    try doc.setComposition("x", .{});
    try std.testing.expectError(error.CompositionActive, doc.replaceManyWithSelections(try doc.version(), &edits, &.{.{}}, 0));
}
fn expectText(document: *d.Document, text: []const u8) !void {
    const storage = try a.alloc(u8, try document.byteLength());
    defer a.free(storage);
    try std.testing.expectEqualStrings(text, storage[0..try document.read(.{ .start = 0, .end = storage.len }, storage)]);
}
test "multi selection normalization primary direction and one undo version" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abc def ghi", .{});
    defer doc.close() catch unreachable;
    const selected = [_]d.Selection{ .{ .anchor = 11, .caret = 8 }, .{ .anchor = 3, .caret = 0 }, .{ .anchor = 1, .caret = 1 }, .{ .anchor = 4, .caret = 7 } };
    _ = try doc.setSelections(&selected, 0);
    try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
    try std.testing.expectEqual(selected[0], try doc.selection());
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const version = try doc.version();
    try doc.replaceSelections("中");
    try expectText(doc, "中 中 中");
    try std.testing.expectEqual(version + 1, try doc.version());
    try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
    var output: [8]d.Selection = undefined;
    const after = try doc.selections(&output);
    try std.testing.expectEqual(@as(usize, 2), after.primary);
    try std.testing.expectEqualSlices(d.Selection, &.{ .{ .anchor = 3, .caret = 3 }, .{ .anchor = 7, .caret = 7 }, .{ .anchor = 11, .caret = 11 } }, after.items);
    try std.testing.expect(try doc.undo());
    try expectText(doc, "abc def ghi");
    try std.testing.expectEqual(selected[0], try doc.selection());
    try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
    try std.testing.expect(try doc.redo());
    try expectText(doc, "中 中 中");
    try doc.restore(saved);
    try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
    _ = try doc.setSelection(.{});
    try std.testing.expectEqual(@as(usize, 1), try doc.selectionCount());
    try std.testing.expectEqual(@as(usize, 3), try saved.selectionCount());
}
test "batch edits are strict original coordinates and stale revision preserves redo" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "0123456789", .{});
    defer doc.close() catch unreachable;
    _ = try doc.setSelections(&.{ .{ .anchor = 1, .caret = 4 }, .{ .anchor = 9, .caret = 7 } }, 1);
    const revision = try doc.version();
    try doc.replaceMany(revision, &.{ .{ .range = .{ .start = 0, .end = 2 }, .text = "A" }, .{ .range = .{ .start = 5, .end = 8 }, .text = "XYZ" } });
    try expectText(doc, "A234XYZ89");
    try std.testing.expect(try doc.undo());
    const before = try doc.version();
    try std.testing.expectError(error.StaleRevision, doc.replaceMany(revision, &.{}));
    const invalid = [_][]const d.Replacement{
        &.{ .{ .range = .{ .start = 2, .end = 2 }, .text = "a" }, .{ .range = .{ .start = 2, .end = 2 }, .text = "b" } },
        &.{ .{ .range = .{ .start = 0, .end = 3 }, .text = "" }, .{ .range = .{ .start = 2, .end = 4 }, .text = "" } },
        &.{ .{ .range = .{ .start = 0, .end = 3 }, .text = "" }, .{ .range = .{ .start = 3, .end = 3 }, .text = "" } },
        &.{ .{ .range = .{ .start = 3, .end = 5 }, .text = "" }, .{ .range = .{ .start = 1, .end = 2 }, .text = "" } },
    };
    for (invalid) |edits| try std.testing.expectError(error.OverlappingEdits, doc.replaceMany(before, edits));
    try std.testing.expectEqual(before, try doc.version());
    try std.testing.expect(try doc.canRedo());
    try expectText(doc, "0123456789");
}
test "adjacent multi deletions deduplicate result carets and preserve primary" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "abcd", .{});
    defer doc.close() catch unreachable;
    _ = try doc.setSelections(&.{ .{ .anchor = 0, .caret = 2 }, .{ .anchor = 4, .caret = 2 } }, 1);
    try doc.replaceSelections("");
    try expectText(doc, "");
    try std.testing.expectEqual(@as(usize, 1), try doc.selectionCount());
    try std.testing.expect(try doc.undo());
    try std.testing.expectEqual(d.Selection{ .anchor = 4, .caret = 2 }, try doc.selection());
    try std.testing.expectEqual(@as(usize, 2), try doc.selectionCount());
}
test "multi preedit is temporary at primary and one commit replaces all original selections" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "aa bb", .{});
    defer doc.close() catch unreachable;
    _ = try doc.setSelections(&.{ .{ .anchor = 0, .caret = 2 }, .{ .anchor = 5, .caret = 3 } }, 1);
    const selected = try doc.selection();
    try doc.setComposition("中文", .{ .anchor = 6, .caret = 6 });
    try std.testing.expectEqual(d.Range{ .start = 3, .end = 5 }, (try doc.composition()).?.range);
    try expectText(doc, "aa bb");
    _ = try doc.cancelComposition();
    try std.testing.expectEqual(selected, try doc.selection());
    try doc.setComposition("中文", .{ .anchor = 6, .caret = 6 });
    try doc.commitComposition("文");
    try expectText(doc, "文 文");
    try std.testing.expect(try doc.undo());
    try expectText(doc, "aa bb");
    try std.testing.expectEqual(selected, try doc.selection());
    try std.testing.expect(!try doc.canUndo());
}
fn failures(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "abcdef ghi jkl", .{});
    defer doc.close() catch unreachable;
    _ = try doc.setSelections(&.{ .{ .anchor = 6, .caret = 0 }, .{ .anchor = 7, .caret = 10 }, .{ .anchor = 14, .caret = 11 } }, 0);
    try doc.replaceSelections("z");
    _ = try doc.undo();
    const revision = try doc.version();
    const before = try doc.stats();
    doc.replaceSelections("😀longer") catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(revision, try doc.version());
        try std.testing.expectEqual(@as(usize, 3), try doc.selectionCount());
        try std.testing.expectEqual(before.owned_bytes, (try doc.stats()).owned_bytes);
        try std.testing.expect(try doc.canRedo());
        try expectText(doc, "abcdef ghi jkl");
        return err;
    };
    try expectText(doc, "😀longer 😀longer 😀longer");
}
test "multi edit allocation failures preserve all state and redo" {
    try std.testing.checkAllAllocationFailures(a, failures, .{});
}

test "random original-coordinate batches agree with independent concatenation oracle" {
    var random_source: std.Random.DefaultPrng = .init(0x19ac62);
    const random = random_source.random();
    for (0..160) |_| {
        var initial: [240]u8 = undefined;
        for (&initial) |*byte| byte.* = 'a' + random.uintLessThan(u8, 26);
        const doc = try d.Document.create(a, std.Thread.getCurrentId(), &initial, .{});
        defer doc.close() catch unreachable;
        _ = try doc.setSelections(&.{ .{ .anchor = 2, .caret = 13 }, .{ .anchor = 201, .caret = 190 } }, 1);
        var edits: [8]d.Replacement = undefined;
        for (&edits, 0..) |*edit, index| {
            const start = index * 30 + random.uintLessThan(usize, 10);
            edit.* = .{ .range = .{ .start = start, .end = start + random.uintLessThan(usize, 15) }, .text = if (random.boolean()) "中文" else "Z" };
        }
        var oracle: std.ArrayList(u8) = .empty;
        defer oracle.deinit(a);
        var at: usize = 0;
        for (edits) |edit| {
            try oracle.appendSlice(a, initial[at..edit.range.start]);
            try oracle.appendSlice(a, edit.text);
            at = edit.range.end;
        }
        try oracle.appendSlice(a, initial[at..]);
        try doc.replaceMany(try doc.version(), &edits);
        try expectText(doc, oracle.items);
        try std.testing.expect(try doc.undo());
        try expectText(doc, &initial);
        try std.testing.expectEqual(d.Selection{ .anchor = 201, .caret = 190 }, try doc.selection());
    }
}
