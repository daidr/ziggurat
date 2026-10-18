const std = @import("std");
const r = @import("byte_range.zig");

fn single(text: []const u8, expected: r.Spec) !void {
    try std.testing.expectEqualDeep(r.Parsed{ .single = expected }, try r.parse(text));
}
test "bounded syntax and empty members retain one actual range" {
    try single("bytes=0-1", .{ .closed = .{ .first = 0, .last = 1 } });
    try single("\tBYTES=,0-1, \t", .{ .closed = .{ .first = 0, .last = 1 } });
    try single("bytes=,,,,0-1,,,,", .{ .closed = .{ .first = 0, .last = 1 } });
    try single("bytes=00042-", .{ .from = 42 });
    try single("bytes=-00042", .{ .suffix = 42 });
    try single("bytes=-0", .{ .suffix = 0 });
    try std.testing.expectError(error.TooManyEmptyItems, r.parse("bytes=,,,,,0-1,,,,"));
    const malformed = [_][]const u8{ "", "bytes", "=0-1", "bytes=", "bytes=,,,", "bytes =0-1", "bytes=0 -1", "bytes=1- 2", "bytes=2-1", "bytes=--1", "bytes=-", "bytes=1", "bytes=1-2-3", "bytes=0-1\r", "bytes=0-1\n", "bytes=0-1\x00", "by\x80tes=0-1" };
    for (malformed) |value| try std.testing.expectError(error.InvalidRange, r.parse(value));
    try std.testing.expectEqual(r.Parsed.unknown_unit, try r.parse("widgets=anything,0-1"));
    try std.testing.expectError(error.InvalidRange, r.parse("widgets=hello\nworld"));
}
test "full tail validated before multiple or decimal limit is returned" {
    try std.testing.expectEqual(r.Parsed.multiple, try r.parse("bytes=0-1, 3-, -7"));
    try std.testing.expectEqual(r.Parsed.numeric_limit, try r.parse("bytes=18446744073709551616-"));
    try std.testing.expectEqual(r.Parsed.numeric_limit, try r.parse("bytes=0-1,18446744073709551616-18446744073709551617"));
    const bad = [_][]const u8{ "bytes=0-1,x", "bytes=0-1,2-1", "bytes=0-1,-3junk", "bytes=18446744073709551616-,x", "bytes=18446744073709551616q-", "bytes=18446744073709551617-18446744073709551616", "bytes=18446744073709551616-18446744073709551617,0-x", "bytes=0-1,\n" };
    for (bad) |value| try std.testing.expectError(error.InvalidRange, r.parse(value));
    try single("bytes=00000000000000000000000000000000000000000000000000000000000000000001-02", .{ .closed = .{ .first = 1, .last = 2 } });
    var exact: [r.value_capacity]u8 = @splat('0');
    @memcpy(exact[0..6], "bytes=");
    exact[exact.len - 1] = '-';
    try single(&exact, .{ .from = 0 });
    var longer: [r.value_capacity + 1]u8 = @splat('0');
    @memcpy(longer[0..6], "bytes=");
    longer[longer.len - 1] = '-';
    try std.testing.expectError(error.TooLong, r.parse(&longer));
}

fn checkBytes(total: u64, spec: r.Spec) !void {
    var expected: [32]u8 = undefined;
    var count: usize = 0;
    // Independent materialized set: enumerate each byte and test membership.
    // No endpoint clamp or inclusive-length expression from select is reused.
    for (0..@intCast(total)) |i| {
        const include = switch (spec) {
            .closed => |span| i >= span.first and i <= span.last,
            .from => |first| i >= first,
            .suffix => |n| total - i <= n,
        };
        if (include) {
            expected[count] = @intCast(i);
            count += 1;
        }
    }
    const actual = try r.select(spec, total);
    if (total == 0) {
        try std.testing.expect(actual == .full);
    } else if (count == 0) {
        try std.testing.expectEqualDeep(r.Selection{ .unsatisfiable = total }, actual);
    } else {
        try std.testing.expect(actual == .partial);
        try std.testing.expectEqual(total, actual.partial.total);
        try std.testing.expectEqual(count, actual.partial.length);
        for (expected[0..count], 0..) |byte, i| try std.testing.expectEqual(byte, actual.partial.offset + i);
    }
}
test "independent byte-set oracle exhausts small windows and unsatisfied ranges" {
    for (0..33) |total| {
        for (0..37) |first| {
            try checkBytes(total, .{ .from = first });
            try checkBytes(total, .{ .suffix = first });
            for (first..37) |last| try checkBytes(total, .{ .closed = .{ .first = first, .last = last } });
        }
    }
    const body = "abcdefghijklmnopqrstuvwxyz";
    const selected = (try r.select(.{ .closed = .{ .first = 3, .last = 8 } }, body.len)).partial;
    try std.testing.expectEqualStrings("defghi", body[@intCast(selected.offset)..][0..@intCast(selected.length)]);
    const suffix = (try r.select(.{ .suffix = 3 }, body.len)).partial;
    try std.testing.expectEqualStrings("xyz", body[@intCast(suffix.offset)..][0..@intCast(suffix.length)]);
}
test "handmade specs validate on every path and u64 arithmetic stays exact" {
    const max = std.math.maxInt(u64);
    const invalid: r.Spec = .{ .closed = .{ .first = 9, .last = 8 } };
    try std.testing.expectError(error.InvalidSpec, r.select(invalid, 0));
    try std.testing.expectError(error.InvalidSpec, r.select(invalid, max));
    try std.testing.expectError(error.InvalidSpec, r.evaluate(.head, .{ .single = invalid }, 0, null, null));
    try std.testing.expectEqualDeep(r.Selection{ .partial = .{ .offset = 0, .length = max, .total = max } }, try r.select(.{ .closed = .{ .first = 0, .last = max } }, max));
    try std.testing.expectEqualDeep(r.Selection{ .partial = .{ .offset = max - 1, .length = 1, .total = max } }, try r.select(.{ .from = max - 1 }, max));
    try std.testing.expectEqualDeep(r.Selection{ .unsatisfiable = max }, try r.select(.{ .from = max }, max));
    try std.testing.expectEqualDeep(r.Selection{ .partial = .{ .offset = 0, .length = max, .total = max } }, try r.select(.{ .suffix = max }, max));
    try std.testing.expectEqualDeep(r.Selection{ .unsatisfiable = 1 }, try r.select(.{ .suffix = 0 }, 1));
    try single("bytes=18446744073709551615-18446744073709551615", .{ .closed = .{ .first = max, .last = max } });
}
test "strong validators compare exact validated bytes and reject dates or weak tags" {
    try std.testing.expect(r.ifRangeMatches("\t\"etag\" ", "\"etag\""));
    try std.testing.expect(r.ifRangeMatches("\"\"", "\"\""));
    try std.testing.expect(r.ifRangeMatches("\"\xff\"", "\"\xff\""));
    const denied = [_][]const u8{ "W/\"etag\"", "w/\"etag\"", "\"ETAG\"", "etag", "\"etag", "\"et ag\"", "\"et\tag\"", "\"et\rag\"", "\"et\x7fag\"", "\"et\"ag\"", "\"etag\",\"etag\"", "Sun, 06 Nov 1994 08:49:37 GMT" };
    for (denied) |value| try std.testing.expect(!r.ifRangeMatches(value, "\"etag\""));
    try std.testing.expect(!r.ifRangeMatches("\"etag\"", null));
    try std.testing.expect(!r.ifRangeMatches("\"etag\"", "W/\"etag\""));
    try std.testing.expect(!r.ifRangeMatches("\"etag\"", " \"etag\""));
    var too_long: [257]u8 = @splat('a');
    too_long[0] = '"';
    too_long[256] = '"';
    try std.testing.expect(!r.ifRangeMatches(&too_long, &too_long));
}
test "method fallback empty and If-Range policy do not create partial authority" {
    const parsed = try r.parse("bytes=2-4");
    try std.testing.expect((try r.evaluate(.head, parsed, 10, null, null)) == .full);
    try std.testing.expect((try r.evaluate(.get, parsed, 0, null, null)) == .full);
    try std.testing.expect((try r.evaluate(.get, null, 10, null, null)) == .full);
    try std.testing.expect((try r.evaluate(.get, parsed, 10, "W/\"a\"", "\"a\"")) == .full);
    try std.testing.expect((try r.evaluate(.get, parsed, 10, "\"b\"", "\"a\"")) == .full);
    try std.testing.expect((try r.evaluate(.get, parsed, 10, "Sun, 06 Nov 1994 08:49:37 GMT", "\"a\"")) == .full);
    try std.testing.expectEqualDeep(r.Selection{ .partial = .{ .offset = 2, .length = 3, .total = 10 } }, try r.evaluate(.get, parsed, 10, "\"a\"", "\"a\""));
    for ([_]r.Parsed{ .unknown_unit, .multiple, .numeric_limit }) |fallback| try std.testing.expect((try r.evaluate(.get, fallback, 10, null, null)) == .full);
}
test "format exact maximum and short buffers preserve all output bytes" {
    var output: [72]u8 = @splat(0xa5);
    const max = std.math.maxInt(u64);
    const widest: r.Selection = .{ .partial = .{ .offset = max - 1, .length = 1, .total = max } };
    const text = try r.formatContentRange(widest, &output);
    try std.testing.expectEqual(@as(usize, r.maximum_content_range_length), text.len);
    try std.testing.expectEqualStrings("bytes 18446744073709551614-18446744073709551614/18446744073709551615", text);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, output[68..]);
    for (0..text.len) |length| {
        @memset(&output, 0xa5);
        try std.testing.expectError(error.NoSpaceLeft, r.formatContentRange(widest, output[0..length]));
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
    try std.testing.expectEqualStrings("bytes */18446744073709551615", try r.formatContentRange(.{ .unsatisfiable = max }, &output));
    try std.testing.expectEqualStrings("bytes 3-8/26", try r.formatContentRange(.{ .partial = .{ .offset = 3, .length = 6, .total = 26 } }, &output));
}
test "handmade selections never format an invalid public shape" {
    const invalid = [_]r.Selection{ .full, .{ .unsatisfiable = 0 }, .{ .partial = .{ .offset = 0, .length = 0, .total = 1 } }, .{ .partial = .{ .offset = 0, .length = 1, .total = 0 } }, .{ .partial = .{ .offset = 1, .length = 1, .total = 1 } }, .{ .partial = .{ .offset = 0, .length = 2, .total = 1 } }, .{ .partial = .{ .offset = 1, .length = std.math.maxInt(u64), .total = std.math.maxInt(u64) } } };
    for (invalid) |selection| {
        var output: [72]u8 = @splat(0x6b);
        try std.testing.expectError(error.InvalidSelection, r.formatContentRange(selection, &output));
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0x6b), byte);
    }
}
test "byte range actual value layouts and zero allocator surface" {
    std.debug.print("Range layouts Spec={d} Parsed={d} Selection={d}; input<=256 empty<=8 output_max=68; no allocator/imported framework/native\n", .{ @sizeOf(r.Spec), @sizeOf(r.Parsed), @sizeOf(r.Selection) });
    try std.testing.expect(r.maximum_content_range_length == 68);
}
