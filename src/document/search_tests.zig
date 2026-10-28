const std = @import("std");
const d = @import("root.zig");
const a = std.testing.allocator;
fn compare(text: []const u8, pattern: []const u8, overlapping: bool) !void {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), text, .{});
    defer doc.close() catch unreachable;
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const reader = try saved.borrowReader();
    defer reader.release() catch unreachable;
    const prefix = try a.alloc(usize, pattern.len);
    defer a.free(prefix);
    var search = try d.search.Iterator.init(reader, .{ .start = 0, .end = text.len }, pattern, prefix, .{ .overlapping = overlapping });
    var expected_at: usize = 0;
    var previous_bytes: usize = 0;
    var calls: usize = 0;
    while (true) {
        const before = search.progress();
        const result = try search.step(1);
        const progress = search.progress();
        try std.testing.expect(progress.comparisons - before.comparisons <= 1);
        try std.testing.expect(progress.scanned_bytes >= previous_bytes);
        previous_bytes = progress.scanned_bytes;
        calls += 1;
        try std.testing.expect(calls < text.len * 4 + 16);
        switch (result) {
            .yielded => {},
            .match => |range| {
                const found = std.mem.indexOfPos(u8, text, expected_at, pattern).?;
                try std.testing.expectEqual(d.Range{ .start = found, .end = found + pattern.len }, range);
                expected_at = found + (if (overlapping) @as(usize, 1) else pattern.len);
            },
            .done => {
                try std.testing.expect(std.mem.indexOfPos(u8, text, expected_at, pattern) == null);
                break;
            },
        }
    }
}
test "stream search one-comparison steps agree with contiguous oracle across native chunks" {
    try compare(&@as([4095]u8, @splat('x')) ++ "😀abc" ++ &@as([8190]u8, @splat('x')) ++ "😀abc", "😀abc", false);
    try compare("aaaaaa", "aaa", true);
    try compare("aaaaaa", "aaa", false);
    try compare("abababababb", "abababb", false);
    try compare("", "a", false);
    var source: std.Random.DefaultPrng = .init(0x773bcd);
    const random = source.random();
    var text: [512]u8 = undefined;
    var pattern: [24]u8 = undefined;
    for (0..120) |_| {
        for (&text) |*byte| byte.* = 'a' + random.uintLessThan(u8, 4);
        for (&pattern) |*byte| byte.* = 'a' + random.uintLessThan(u8, 4);
        try compare(&text, pattern[0 .. 1 + random.uintLessThan(usize, pattern.len)], random.boolean());
    }
}
test "ASCII folding cancellation lease revoke and replacement revision are explicit" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "One one ONE", .{});
    defer doc.close() catch unreachable;
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const reader = try saved.borrowReader();
    var prefix: [3]usize = undefined;
    var cancellation: d.search.Cancellation = .{};
    var search = try d.search.Iterator.init(reader, .{ .start = 0, .end = 11 }, "one", &prefix, .{ .case = .ascii_insensitive, .cancellation = &cancellation });
    var matches: [3]d.Range = undefined;
    var count: usize = 0;
    while (true) switch (try search.step(2)) {
        .yielded => {},
        .done => break,
        .match => |range| {
            matches[count] = range;
            count += 1;
        },
    };
    try std.testing.expectEqual(@as(usize, 3), count);
    var edits: [3]d.Replacement = undefined;
    try d.search.replaceMatches(doc, search.revision, &matches, "文", &edits);
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("文 文 文", out[0..try doc.read(.{ .start = 0, .end = try doc.byteLength() }, &out)]);
    try std.testing.expect(try doc.undo());
    try std.testing.expectError(error.StaleRevision, d.search.replaceMatches(doc, search.revision, &matches, "文", &edits));
    try std.testing.expect(try doc.canRedo());
    try std.testing.expectError(error.CapacityExceeded, d.search.replaceMatches(doc, try doc.version(), &matches, "文", edits[0..2]));
    cancellation.request();
    try std.testing.expectError(error.Cancelled, search.step(1));
    try reader.release();
    try std.testing.expectError(error.ReaderClosed, search.step(1));
    try std.testing.expectError(error.EmptyPattern, d.search.Iterator.init(reader, .{ .start = 0, .end = 0 }, "", &prefix, .{}));
}

test "search restart keeps prefix and cumulative scan comparisons without partial failure" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "😀aaa\r\naaa", .{});
    defer doc.close() catch unreachable;
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const reader = try saved.borrowReader();
    defer reader.release() catch unreachable;
    var prefix: [2]usize = undefined;
    var cancel: d.search.Cancellation = .{};
    var search = try d.search.Iterator.init(reader, .{ .start = 4, .end = 7 }, "aa", &prefix, .{ .overlapping = true, .cancellation = &cancel });
    try std.testing.expectEqualDeep(d.search.Result{ .match = .{ .start = 4, .end = 6 } }, try search.step(2));
    const before = search.progress();
    const table = prefix;
    try search.restart(.{ .start = 9, .end = 12 });
    try std.testing.expectEqualSlices(usize, &table, &prefix);
    try std.testing.expectEqual(before.comparisons, search.progress().comparisons);
    try std.testing.expectEqual(before.scanned_bytes, search.progress().scanned_bytes);
    try std.testing.expectEqualDeep(d.search.Result{ .match = .{ .start = 9, .end = 11 } }, try search.step(2));
    try std.testing.expectEqual(@as(u64, 4), search.progress().comparisons);
    try std.testing.expectEqual(@as(usize, 4), search.progress().scanned_bytes);
    const captured = search.progress();
    try std.testing.expectError(error.InvalidBoundary, search.restart(.{ .start = 1, .end = 4 }));
    try std.testing.expectEqualDeep(captured, search.progress());
    cancel.request();
    try std.testing.expectError(error.Cancelled, search.restart(.{ .start = 0, .end = 12 }));
    try std.testing.expectEqualDeep(captured, search.progress());
}
