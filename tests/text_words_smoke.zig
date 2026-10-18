const std = @import("std");
const t = @import("ziggurat_text_layout");
const Oracle = opaque {};
const Range = extern struct { start: u32, end: u32 };
extern fn ztw_oracle_create([*]const u8, u32, [*:0]const u8, c_int, *?*Oracle) c_int;
extern fn ztw_oracle_close(*Oracle) void;
extern fn ztw_oracle_live() u32;
extern fn ztw_oracle_count(*const Oracle) u32;
extern fn ztw_oracle_range(*const Oracle, u32, *Range) c_int;
extern fn ztw_oracle_at(*const Oracle, u32, c_int, *Range) c_int;
extern fn ztw_oracle_work(*const Oracle) u64;

const has_word_query = @hasField(t.Options, "word_ranges") and @hasDecl(t.Layout, "wordRangeAt");
const oracle_work_limit = 2_097_152;
const Fixture = struct {
    text: []const u8,
    locale: [:0]const u8 = "en",
    rtl: bool = false,
    wrap: t.Wrap = .none,
    width: f32 = 0,
    size: f32 = 16,
    reference: bool = false,
    // Max-size cases keep the oracle/query work bounded. Selection scans are
    // separately covered by every endpoint in the small language fixtures.
    selection: bool = true,
};
fn oracle(fixture: Fixture) !*Oracle {
    var result: ?*Oracle = null;
    const status = ztw_oracle_create(fixture.text.ptr, @intCast(fixture.text.len), fixture.locale.ptr, @intFromBool(fixture.rtl), &result);
    if (status != 0) {
        std.debug.print("independent word oracle failed status={d} bytes={d} locale={s}\n", .{ status, fixture.text.len, fixture.locale });
        return error.WordOracleFailed;
    }
    return result orelse error.WordOracleFailed;
}
fn literal(fixture: Fixture, expected: []const Range) !void {
    const words = try oracle(fixture);
    defer ztw_oracle_close(words);
    try std.testing.expectEqual(expected.len, ztw_oracle_count(words));
    for (expected, 0..) |wanted, index| {
        var found: Range = undefined;
        try std.testing.expectEqual(@as(c_int, 0), ztw_oracle_range(words, @intCast(index), &found));
        try std.testing.expectEqualDeep(wanted, found);
    }
}
fn compare(engine: *t.Engine, fixture: Fixture) !void {
    if (comptime has_word_query) {
        var options: t.Options = .{ .locale = fixture.locale, .direction = if (fixture.rtl) .rtl else .ltr, .wrap = fixture.wrap, .width = fixture.width, .size = fixture.size };
        @field(options, "word_ranges") = true;
        const layout = if (fixture.reference) try engine.layoutReference(fixture.text, options) else try engine.layout(fixture.text, options);
        defer layout.close() catch unreachable;
        const stats = try layout.buildStats();
        const words = try oracle(fixture);
        defer ztw_oracle_close(words);
        for (0..try layout.graphemeCount() + 1) |index| {
            const byte = try layout.graphemeByte(index);
            for ([_]t.Affinity{ .upstream, .downstream }) |affinity| {
                var expected: Range = undefined;
                try std.testing.expectEqual(@as(c_int, 0), ztw_oracle_at(words, @intCast(byte), @intFromBool(affinity == .downstream), &expected));
                const actual = try layout.wordRangeAt(.{ .byte_offset = byte, .affinity = affinity });
                try std.testing.expectEqual(@as(usize, expected.start), actual.start);
                try std.testing.expectEqual(@as(usize, expected.end), actual.end);
                if (fixture.selection) _ = try layout.selectionRectCount(actual);
            }
        }
        // Check every non-caret byte with a single monotonic grapheme cursor;
        // no scalar/ASCII approximation or quadratic prefix decoding.
        var grapheme: usize = 0;
        var legal = try layout.graphemeByte(0);
        const last = try layout.graphemeCount();
        for (0..fixture.text.len) |byte| {
            if (byte == legal) {
                if (grapheme < last) {
                    grapheme += 1;
                    legal = try layout.graphemeByte(grapheme);
                }
                continue;
            }
            try std.testing.expectError(error.InvalidCaret, layout.wordRangeAt(.{ .byte_offset = byte }));
        }
        try std.testing.expectError(error.InvalidCaret, layout.wordRangeAt(.{ .byte_offset = fixture.text.len + 1 }));
        try std.testing.expectEqualDeep(stats, try layout.buildStats());
        try std.testing.expect(ztw_oracle_work(words) <= oracle_work_limit);
        std.debug.print("word compare bytes={d} graphemes={d} intervals={d} reference={} locale={s} oracle_work={d}/{d}\n", .{ fixture.text.len, last, ztw_oracle_count(words), fixture.reference, fixture.locale, ztw_oracle_work(words), oracle_work_limit });
    } else return error.WordQueryUnavailable;
}
fn auditOracle(engine: *t.Engine, fixture: Fixture) !void {
    const layout = try engine.layout(fixture.text, .{ .locale = fixture.locale, .direction = if (fixture.rtl) .rtl else .ltr });
    defer layout.close() catch unreachable;
    const words = try oracle(fixture);
    defer ztw_oracle_close(words);
    var cursor: u32 = 0;
    const count = ztw_oracle_count(words);
    try std.testing.expect((count == 0) == (fixture.text.len == 0));
    std.debug.print("independent word partition locale={s} text={s}:", .{ fixture.locale, fixture.text });
    for (0..count) |index| {
        var range: Range = undefined;
        try std.testing.expectEqual(@as(c_int, 0), ztw_oracle_range(words, @intCast(index), &range));
        try std.testing.expectEqual(cursor, range.start);
        try std.testing.expect(range.end > range.start and range.end <= fixture.text.len);
        _ = try layout.caret(.{ .byte_offset = range.start });
        _ = try layout.caret(.{ .byte_offset = range.end });
        cursor = range.end;
        std.debug.print(" [{d},{d})", .{ range.start, range.end });
    }
    std.debug.print("\n", .{});
    try std.testing.expectEqual(fixture.text.len, cursor);
    for (0..try layout.graphemeCount() + 1) |index| {
        const byte = try layout.graphemeByte(index);
        for ([_]c_int{ 0, 1 }) |downstream| {
            var range: Range = undefined;
            try std.testing.expectEqual(@as(c_int, 0), ztw_oracle_at(words, @intCast(byte), downstream, &range));
            if (fixture.text.len == 0) try std.testing.expect(range.start == 0 and range.end == 0) else {
                try std.testing.expect(range.start < range.end);
                try std.testing.expect(range.start <= byte and byte <= range.end);
                if (byte != 0 and byte != fixture.text.len) {
                    if (downstream == 1) try std.testing.expect(byte < range.end) else try std.testing.expect(range.start < byte);
                }
            }
        }
    }
    try std.testing.expect(ztw_oracle_work(words) <= oracle_work_limit);
}
fn limitsAndThread(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const disabled = try engine.layout("e\u{301}", .{});
    defer disabled.close() catch unreachable;
    // Opt-in authority precedes any offset inspection, but owner-thread wins.
    try std.testing.expectError(error.WordRangesNotEnabled, disabled.wordRangeAt(.{ .byte_offset = std.math.maxInt(usize) }));
    const layout = try engine.layout("a👩‍👩‍👧‍👦b\r\n", .{ .word_ranges = true });
    defer layout.close() catch unreachable;
    const Worker = struct {
        fn run(enabled: *t.Layout, plain: *t.Layout) void {
            std.testing.expectError(error.WrongThread, enabled.wordRangeAt(.{ .byte_offset = 0 })) catch @panic("worker enabled query");
            std.testing.expectError(error.WrongThread, plain.wordRangeAt(.{ .byte_offset = std.math.maxInt(usize) })) catch @panic("worker disabled query");
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ layout, disabled });
    worker.join();
    const never_read: [*]const u8 = @ptrFromInt(4096);
    try std.testing.expectError(error.TextCapacityExceeded, engine.layout(never_read[0..65537], .{ .word_ranges = true }));
    const bounded = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .graphemes = 3 });
    defer bounded.close() catch unreachable;
    const resources = t.resourceCounts();
    try std.testing.expectError(error.NativeCapacityExceeded, bounded.layout("four", .{ .word_ranges = true }));
    try std.testing.expectEqualDeep(resources, t.resourceCounts());
}
fn maximums(engine: *t.Engine, allocator: std.mem.Allocator) !void {
    const alternating = "a " ** 4096;
    try compare(engine, .{ .text = alternating, .locale = "", .selection = false });
    const punctuation = "!" ** 8192;
    try compare(engine, .{ .text = punctuation, .selection = false });
    // Exact text-byte ceiling with only two graphemes. This exercises scalar
    // vs UTF-16 vs byte cursors without an oracle's repeated prefix scans.
    const marks = try allocator.alloc(u8, 65536);
    defer allocator.free(marks);
    marks[0] = 'a';
    for (0..32767) |i| @memcpy(marks[1 + i * 2 ..][0..2], "\xcc\x81");
    marks[65535] = '!';
    try compare(engine, .{ .text = marks, .selection = false });
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    var oracle_only = false;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--oracle-only")) return error.InvalidArgument;
        oracle_only = true;
    }
    if (args.next() != null) return error.InvalidArgument;
    const engine = try t.Engine.create(gpa.allocator(), std.Thread.getCurrentId(), .{});
    var engine_open = true;
    defer {
        if (engine_open) engine.close() catch unreachable;
        std.debug.assert(std.meta.eql(@as(t.ResourceCounts, .{}), t.resourceCounts()));
        std.debug.assert(ztw_oracle_live() == 0);
    }
    // Ordinary old-API native construction must succeed before the capability
    // tracer reports absence. No scalar/ASCII word implementation is invented.
    const ordinary = try engine.layout("  alpha,  beta!", .{});
    try std.testing.expectEqualStrings("  alpha,  beta!", try ordinary.text());
    try ordinary.close();
    try literal(.{ .text = "" }, &.{});
    try literal(.{ .text = "  alpha,  beta!" }, &.{ .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 7 }, .{ .start = 7, .end = 10 }, .{ .start = 10, .end = 14 }, .{ .start = 14, .end = 15 } });
    try literal(.{ .text = "e\u{301}lan" }, &.{.{ .start = 0, .end = 6 }});
    try literal(.{ .text = "foo\r\nbar" }, &.{ .{ .start = 0, .end = 3 }, .{ .start = 3, .end = 5 }, .{ .start = 5, .end = 8 } });
    try literal(.{ .text = " \t\r\n!!" }, &.{.{ .start = 0, .end = 6 }});
    const fixtures = [_]Fixture{
        .{ .text = "" },
        .{ .text = "", .locale = "" },
        .{ .text = "alpha e\u{301}lan 中文", .locale = "" },
        .{ .text = "alpha beta", .locale = "zz_ZZ" },
        .{ .text = "  alpha,  beta!" },
        .{ .text = "e\u{301}lan" },
        .{ .text = "a👩‍👩‍👧‍👦b" },
        .{ .text = "foo\r\nbar" },
        .{ .text = "a\r\n" },
        .{ .text = " \t\r\n!!" },
        .{ .text = "مرحبا، عالم", .locale = "ar", .rtl = true },
        .{ .text = "中文测试", .locale = "zh" },
        .{ .text = "日本語テスト", .locale = "ja" },
        .{ .text = "한국어 단어", .locale = "ko" },
        .{ .text = "can't foo_bar 3.14" },
    };
    for (fixtures) |fixture| try auditOracle(engine, fixture);
    std.debug.print("independent SDK word oracle: 5 literal + {d} partition/grapheme cases passed; capability={any}\n", .{ fixtures.len, has_word_query });
    if (oracle_only) return;
    if (comptime !has_word_query) {
        std.debug.print("compiled capability-absence RED: old Options/Layout have no word_ranges/wordRangeAt; no old range behavior is claimed\n", .{});
        return error.WordQueryUnavailable;
    }
    if (comptime has_word_query) {
        for (fixtures) |fixture| {
            try compare(engine, fixture);
            var reference = fixture;
            reference.reference = true;
            try compare(engine, reference);
        }
        for ([_]t.Wrap{ .word, .word_character }) |wrap| try compare(engine, .{ .text = "alpha beta e\u{301}lan\r\nمرحبا 中文测试", .locale = "", .rtl = true, .size = 19.1, .width = 73.25, .wrap = wrap });
        try maximums(engine, gpa.allocator());
        try limitsAndThread(gpa.allocator());
    }
    // This helper creates its own Engine and verifies final global counts.
    try engine.close();
    engine_open = false;
    if (comptime has_word_query) try @import("text_words_lifetime.zig").run(gpa.allocator());
    std.debug.print("word query passed: {d} language/locale cases bulk+reference, wraps, max bytes/G, invalid bytes, thread/limits and lifetime/OOM\n", .{fixtures.len});
}
