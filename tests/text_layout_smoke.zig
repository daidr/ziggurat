const std = @import("std");
const t = @import("ziggurat_text_layout");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn roundTrips(layout: *t.Layout) !void {
    const build_before = try layout.buildStats();
    const source = try layout.text();
    const spans = try layout.advanceSpans();
    const lines = try layout.lines();
    for (spans, 0..) |span, index| {
        try expect(span.start < span.end and span.end <= source.len);
        _ = try layout.utf16FromByte(span.start);
        _ = try layout.utf16FromByte(span.end);
        try expect(span.line < lines.len);
        if (index > 0) try expect(span.line > spans[index - 1].line or (span.line == spans[index - 1].line and span.rect.x >= spans[index - 1].rect.x));
        var cells: [32]t.Rect = undefined;
        const selected = try layout.selectionRects(.{ .start = span.start, .end = span.end }, &cells);
        // Native zero-width advance cells remain useful metadata while the
        // selection API deliberately omits them from filled rectangles.
        var included = span.rect.width == 0;
        for (selected) |rect| {
            if (rect.x <= span.rect.x and rect.y == span.rect.y and rect.x + rect.width >= span.rect.x + span.rect.width and rect.height == span.rect.height) included = true;
        }
        try expect(included);
    }
    const again_spans = try layout.advanceSpans();
    try equal(@intFromPtr(spans.ptr), @intFromPtr(again_spans.ptr));
    try equal(build_before, try layout.buildStats());
    const count = try layout.graphemeCount();
    for (0..count + 1) |index| {
        const byte = try layout.graphemeByte(index);
        try equal(byte, try layout.byteFromUtf16(try layout.utf16FromByte(byte)));
        for ([_]t.Affinity{ .upstream, .downstream }) |affinity| {
            const rect = try layout.caret(.{ .byte_offset = byte, .affinity = affinity });
            try expect(std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and rect.height > 0);
            const hit = try layout.hitTest(.{ .x = rect.x, .y = rect.y + rect.height * 0.5 });
            const again = try layout.caret(hit.caret);
            // Ambiguous bidi/wrap aliases may choose another logical edge at
            // the same visual position, while the geometry must round-trip.
            try std.testing.expectApproxEqAbs(rect.x, again.x, 0.05);
            try std.testing.expectApproxEqAbs(rect.y, again.y, 0.05);
        }
    }
    try expectError(error.InvalidPoint, layout.hitTest(.{ .x = std.math.nan(f32) }));
}
fn segmentation(engine: *t.Engine) !void {
    const cases = [_]struct { text: []const u8, count: usize }{
        .{ .text = "", .count = 0 },
        .{ .text = "a\u{0301}b", .count = 2 },
        .{ .text = "👩‍👩‍👧‍👦X", .count = 2 },
        .{ .text = "🇨🇳👍🏽Z", .count = 3 },
        .{ .text = "A\r\nB", .count = 3 },
        .{ .text = "中文", .count = 2 },
    };
    for (cases) |case| {
        const layout = try engine.layout(case.text, .{});
        defer layout.close() catch unreachable;
        try equal(case.count, try layout.graphemeCount());
        try roundTrips(layout);
        const metrics = try layout.metrics();
        if (case.text.len > 0) try expect(metrics.glyphs > 0);
    }
    const layout = try engine.layout("a\u{0301}😀", .{});
    defer layout.close() catch unreachable;
    try expectError(error.InvalidCaret, layout.caret(.{ .byte_offset = 1 }));
    try expectError(error.InvalidTextBoundary, layout.utf16FromByte(2));
    try expectError(error.InvalidTextBoundary, layout.byteFromUtf16(3));
}
fn bidiAndSelection(engine: *t.Engine) !void {
    for ([_]t.Direction{ .ltr, .rtl }) |direction| {
        const text = "abc אבג 123 مرحبا بالعالم xyz";
        const layout = try engine.layout(text, .{ .direction = direction, .width = 120, .wrap = .word_character });
        defer layout.close() catch unreachable;
        try expect((try layout.lines()).len > 1);
        try roundTrips(layout);
        var rects: [128]t.Rect = undefined;
        const selected = try layout.selectionRects(.{ .start = 0, .end = text.len }, &rects);
        try expect(selected.len > 1);
        for (selected) |rect| try expect(rect.width > 0 and rect.height > 0);
        var sentinel = [_]t.Rect{.{ .x = 777, .y = 888, .width = 1, .height = 2 }};
        try expectError(error.OutputTooSmall, layout.selectionRects(.{ .start = 0, .end = text.len }, &sentinel));
        try equal(@as(f32, 777), sentinel[0].x);
        try expectError(error.InvalidRange, layout.selectionRectCount(.{ .start = 4, .end = 1 }));
        try equal(0, try layout.selectionRectCount(.{ .start = 0, .end = 0 }));
        const stats = try layout.buildStats();
        std.debug.print("text layout {s}: lines={d} graphemes={d} glyphs={d} missing={d} calls={d} owned={d} peak={d} build_ns={?d}\n", .{ @tagName(direction), (try layout.lines()).len, stats.graphemes, (try layout.metrics()).glyphs, (try layout.metrics()).missing_glyphs, stats.native_calls, stats.owned_bytes, stats.peak_owned_bytes, stats.elapsed_ns });
        try expect(stats.native_calls <= stats.graphemes * 4 + 8);
    }
    const rtl = try engine.layout("אבג", .{ .direction = .rtl });
    defer rtl.close() catch unreachable;
    try expect((try rtl.caret(.{ .byte_offset = 0 })).x > (try rtl.caret(.{ .byte_offset = "אבג".len })).x);
    try roundTrips(rtl);
    const rtl_line = (try rtl.lines())[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0), rtl_line.x, 0.05);
    try std.testing.expectApproxEqAbs((try rtl.metrics()).bounds.width, rtl_line.width, 0.05);
    const wrap = try engine.layout("one two three four five six", .{ .width = 55, .wrap = .word_character });
    defer wrap.close() catch unreachable;
    const lines = try wrap.lines();
    try expect(lines.len > 1);
    const offset = lines[1].start;
    const upstream = try wrap.caret(.{ .byte_offset = offset, .affinity = .upstream });
    const downstream = try wrap.caret(.{ .byte_offset = offset, .affinity = .downstream });
    try expect(upstream.y < downstream.y);
}
fn multiScalarSelection(engine: *t.Engine) !void {
    // Spacing marks and broken/unsupported shaping clusters can have several
    // logical cells in one grapheme. Selecting only its first scalar loses area.
    const cases = [_][]const u8{ "ক্ষি", "กำ", "က္က", "क्‍ष", "👩‍👩‍👧‍👦", "🇨🇳", "a\u{0301}" };
    for (cases) |text| {
        for ([_]t.Direction{ .ltr, .rtl }) |direction| {
            const layout = try engine.layout(text, .{ .direction = direction, .width = 200, .wrap = .word_character });
            defer layout.close() catch unreachable;
            try roundTrips(layout);
            var rects: [32]t.Rect = undefined;
            const result = try layout.selectionRects(.{ .start = 0, .end = text.len }, &rects);
            try expect(result.len > 0);
            var left = std.math.inf(f32);
            var right = -std.math.inf(f32);
            for (result) |rect| {
                left = @min(left, rect.x);
                right = @max(right, rect.x + rect.width);
            }
            const bounds = (try layout.metrics()).bounds;
            if (@abs(bounds.x - left) > 0.05 or @abs(bounds.width - (right - left)) > 0.05) std.debug.print("multi-scalar selection mismatch text={s} direction={s} glyphs={d} graphemes={d} bounds={any} selected={any}\n", .{ text, @tagName(direction), (try layout.metrics()).glyphs, try layout.graphemeCount(), bounds, result });
            try std.testing.expectApproxEqAbs(bounds.x, left, 0.05);
            try std.testing.expectApproxEqAbs(bounds.width, right - left, 0.05);
            const line = (try layout.lines())[0];
            try std.testing.expectApproxEqAbs(left, line.x, 0.05);
            try std.testing.expectApproxEqAbs(right - left, line.width, 0.05);
        }
    }
}
fn paragraphs(engine: *t.Engine) !void {
    for ([_][]const u8{ "", "\n", "\n\n", "\r\n\r\n", "a\n", "\nאבג\n\n", "مرحبا\nabc\n" }) |text| {
        for ([_]t.Direction{ .ltr, .rtl }) |direction| {
            const layout = try engine.layout(text, .{ .direction = direction });
            defer layout.close() catch unreachable;
            try roundTrips(layout);
            const lines = try layout.lines();
            try equal((try layout.metrics()).lines, lines.len);
            var previous_y: f32 = -1;
            for (lines) |line| {
                try expect(line.y > previous_y);
                try expect(line.start <= line.end and line.end <= line.next_start and line.next_start <= text.len);
                previous_y = line.y;
            }
            var output: [64]t.Rect = undefined;
            _ = try layout.selectionRects(.{ .start = 0, .end = text.len }, &output);
        }
    }
}
fn preparations(engine: *t.Engine) !void {
    const layout = try engine.layout("abc אבג مرحبا a\u{0301} 👩‍👩‍👧‍👦", .{ .width = 100, .wrap = .word_character });
    defer layout.close() catch unreachable;
    const before = try layout.buildStats();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const prepared = try layout.prepare(scale, .{});
        const view = try prepared.view();
        try view.validate();
        try equal(scale, view.coverage.scale);
        var ink: usize = 0;
        for (view.coverage.pixels) |alpha| if (alpha != 0) {
            ink += 1;
        };
        try expect(ink > 0);
        try expectError(error.PreparedAlive, layout.close());
        try view.lease.acquire();
        try expect(try prepared.inUse());
        try expectError(error.ResourceInUse, prepared.close());
        try expectError(error.ResourceInUse, prepared.ensureUnused());
        view.lease.release();
        try expect(!try prepared.inUse());
        try prepared.close();
        try equal(before, try layout.buildStats());
    }
    try expectError(error.InvalidPrepareScale, layout.prepare(1e30, .{}));
    try expectError(error.InvalidPrepareScale, layout.prepare(std.math.nan(f32), .{}));
    try expectError(error.PreparedCapacityExceeded, layout.prepare(1, .{ .limits = .{ .pixels = 1 } }));
    try expectError(error.PreparedCapacityExceeded, layout.prepare(1, .{ .limits = .{ .bytes = 1 } }));
    try expectError(error.InvalidPrepareViewport, layout.prepare(1, .{ .viewport = .{ .x = std.math.inf(f32), .width = 10, .height = 10 } }));
    try expectError(error.PreparedCapacityExceeded, layout.prepare(16, .{ .viewport = .{ .width = 100000, .height = 100000 } }));
    const viewport = try layout.prepare(2, .{ .viewport = .{ .x = 20, .y = 2, .width = 30, .height = 20 } });
    defer viewport.close() catch unreachable;
    try equal(@as(u32, 60), (try viewport.view()).coverage.width);
    try equal(@as(i32, 40), (try viewport.view()).coverage.origin_x);
    const long = try engine.layout("i\n" ** 2000, .{ .size = 18 });
    defer long.close() catch unreachable;
    try equal(2001, (try long.lines()).len);
    try roundTrips(long);
    try expectError(error.PreparedCapacityExceeded, long.prepare(1, .{}));
    const cropped = try long.prepare(1, .{ .viewport = .{ .width = 240, .height = 80 } });
    defer cropped.close() catch unreachable;
    try equal(@as(u32, 80), (try cropped.view()).coverage.height);
    std.debug.print("text prepare: scales=1,1.5,2 native ink coverage, viewport, budgets, prepared/layout leases verified\n", .{});
}
fn ownership(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    var source = [_]u8{ 't', 'e', 'x', 't' };
    var family = [_]u8{ 'S', 'a', 'n', 's' };
    const layout = try engine.layout(&source, .{ .family = &family, .locale = "en" });
    defer layout.close() catch unreachable;
    source[0] = 'X';
    family[0] = 'X';
    try std.testing.expectEqualStrings("text", try layout.text());
    try std.testing.expectEqualStrings("Sans", (try layout.options()).family);
    try expectError(error.LayoutsAlive, engine.close());
    const Worker = struct {
        fn run(owner: std.Thread.Id, alloc: std.mem.Allocator, e: *t.Engine, l: *t.Layout) void {
            expectError(error.WrongThread, t.Engine.create(alloc, owner, .{})) catch @panic("worker engine");
            expectError(error.WrongThread, e.layout("worker", .{})) catch @panic("worker layout");
            expectError(error.WrongThread, l.metrics()) catch @panic("worker metrics");
            expectError(error.WrongThread, l.caret(.{ .byte_offset = 0 })) catch @panic("worker caret");
            expectError(error.WrongThread, l.close()) catch @panic("worker close");
            expectError(error.WrongThread, e.close()) catch @panic("worker engine close");
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ std.Thread.getCurrentId(), allocator, engine, layout });
    worker.join();
}
fn limits(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .text_bytes = 100, .graphemes = 3, .lines = 2, .span_rects = 3, .live_layouts = 1 });
    defer engine.close() catch unreachable;
    try expectError(error.TextCapacityExceeded, engine.layout("a" ** 101, .{}));
    try expectError(error.InvalidUtf8, engine.layout("\xff", .{}));
    try expectError(error.EmbeddedNul, engine.layout("a\x00b", .{}));
    try expectError(error.InvalidOptions, engine.layout("x", .{ .size = std.math.inf(f32) }));
    try expectError(error.NativeCapacityExceeded, engine.layout("abcd", .{}));
    try expectError(error.NativeCapacityExceeded, engine.layout("a\nb\nc", .{}));
    const layout = try engine.layout("abc", .{});
    defer layout.close() catch unreachable;
    try expectError(error.LayoutCapacityExceeded, engine.layout("x", .{}));
}
fn allocationBudgets(allocator: std.mem.Allocator) !void {
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = 1024 });
    defer engine.close() catch unreachable;
    const before = t.resourceCounts();
    try expectError(error.LayoutByteCapacityExceeded, engine.layout("x" ** 2048, .{}));
    try equal(before, t.resourceCounts());
    const limited = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .span_rects = 1 });
    defer limited.close() catch unreachable;
    try expectError(error.NativeCapacityExceeded, limited.layout("ab", .{}));
    const good = try limited.layout("a", .{});
    defer good.close() catch unreachable;
    try equal(1, try good.graphemeCount());
}
fn allocationFailure(allocator: std.mem.Allocator) !void {
    const Scenario = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const engine = try t.Engine.create(alloc, std.Thread.getCurrentId(), .{});
            defer engine.close() catch unreachable;
            const layout = try engine.layout("abc אבג a\u{0301} 👩‍👩‍👧‍👦", .{ .family = "Sans", .locale = "en" });
            defer layout.close() catch unreachable;
            const prepared = try layout.prepare(1.5, .{});
            defer prepared.close() catch unreachable;
            _ = try layout.metrics();
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scenario.run, .{});
    try equal(t.ResourceCounts{}, t.resourceCounts());
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try t.Engine.create(failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("abc אבג a\u{0301} 👩‍👩‍👧‍👦", .{});
    defer layout.close() catch unreachable;
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    const before = try layout.buildStats();
    for (0..100) |_| {
        try roundTrips(layout);
        _ = try layout.text();
        _ = try layout.options();
        _ = try layout.metrics();
        _ = try layout.lines();
        var rects: [64]t.Rect = undefined;
        _ = try layout.selectionRects(.{ .start = 0, .end = (try layout.text()).len }, &rects);
    }
    try equal(allocations, failing.alloc_index);
    try expect(!failing.has_induced_failure);
    try equal(before, try layout.buildStats());
}
fn constructionSample(engine: *t.Engine, source: []const u8, reference: bool) !t.BuildStats {
    var times: [3]u64 = undefined;
    var result: t.BuildStats = undefined;
    for (&times) |*time| {
        const layout = if (reference) try engine.layoutReference(source, .{}) else try engine.layout(source, .{});
        defer layout.close() catch unreachable;
        result = try layout.buildStats();
        time.* = result.elapsed_ns orelse 0;
    }
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    result.elapsed_ns = if (times[1] > 0) times[1] else null;
    return result;
}
fn constructionCost(engine: *t.Engine) !void {
    const fixtures = [_][]const u8{ ("a" ** 8192)[0..1024], ("a" ** 8192)[0..2048], ("a" ** 8192)[0..4096], "a" ** 8192, "abc\n" ** 1024, "abc אבג العربية a\u{0301} 👩‍👩‍👧‍👦\n" ** 128 };
    for (fixtures, 0..) |source, fixture| {
        const fast = try constructionSample(engine, source, false);
        const reference = try constructionSample(engine, source, true);
        try equal(reference.graphemes, fast.graphemes);
        try expect(fast.native_calls <= 4 * fast.graphemes + 8);
        std.debug.print("text construction median3: fixture={d} bytes={d} graphemes={d} fast_ns={?d} reference_ns={?d} owned={d} peak={d} reference_peak={d} C_calls={d}/{d}\n", .{ fixture, source.len, fast.graphemes, fast.elapsed_ns, reference.elapsed_ns, fast.owned_bytes, fast.peak_owned_bytes, reference.peak_owned_bytes, fast.native_calls, reference.native_calls });
        std.debug.print("text native queries fast={any} reference={any}\n", .{ fast.native_queries, reference.native_queries });
        if (@import("builtin").os.tag == .windows and fixture < 4) {
            try equal(source.len, fast.native_queries.bulk_cells);
            try equal(0, fast.native_queries.fallback_cells);
            try equal(2, fast.native_queries.position_queries);
            try equal(2, fast.native_queries.range_queries);
            try equal(2, fast.native_queries.cluster_queries);
            try equal(2 * source.len + 2, reference.native_queries.position_queries);
            try equal(source.len, reference.native_queries.range_queries);
        }
    }
}
fn snapshotBudget(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    if (@import("builtin").os.tag != .windows) return;
    const text = "abc" ** 512;
    const stats = try constructionSample(engine, text, false);
    const limited = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{ .layout_bytes = stats.peak_owned_bytes - 1 });
    defer limited.close() catch unreachable;
    const before = t.resourceCounts();
    try expectError(error.LayoutByteCapacityExceeded, limited.layout(text, .{}));
    try equal(before, t.resourceCounts());
    const reference = try limited.layoutReference(text, .{});
    defer reference.close() catch unreachable;
    try equal(text.len, try reference.graphemeCount());
}
fn compareRect(expected: t.Rect, actual: t.Rect) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| try std.testing.expectApproxEqAbs(@field(expected, field), @field(actual, field), 0.001);
}
fn compareSelection(fast: *t.Layout, reference: *t.Layout, first: usize, last: usize) !void {
    const range: t.ByteRange = .{ .start = first, .end = last };
    var a: [4096]t.Rect = undefined;
    var b: [4096]t.Rect = undefined;
    const expected = try reference.selectionRects(range, &a);
    const actual = try fast.selectionRects(range, &b);
    if (expected.len != actual.len) std.debug.print("snapshot selection count mismatch text={s} options={any} range={any}\nold={any}\nnew={any}\nqueries={any}\n", .{ (try fast.text())[0..@min(96, (try fast.text()).len)], try fast.options(), range, expected, actual, (try fast.buildStats()).native_queries });
    try equal(expected.len, actual.len);
    for (expected, actual) |old, new| try compareRect(old, new);
}
fn compareLayouts(engine: *t.Engine, source: []const u8, options: t.Options) !void {
    const fast = try engine.layout(source, options);
    defer fast.close() catch unreachable;
    const reference = try engine.layoutReference(source, options);
    defer reference.close() catch unreachable;
    const count = try reference.graphemeCount();
    try equal(count, try fast.graphemeCount());
    try equal(try reference.metrics(), try fast.metrics());
    const old_lines = try reference.lines();
    const new_lines = try fast.lines();
    try equal(old_lines.len, new_lines.len);
    for (old_lines, new_lines) |old, new| {
        try equal(old.start, new.start);
        try equal(old.end, new.end);
        try equal(old.next_start, new.next_start);
        compareRect(.{ .x = old.x, .y = old.y, .width = old.width, .height = old.height }, .{ .x = new.x, .y = new.y, .width = new.width, .height = new.height }) catch |err| {
            std.debug.print("snapshot line mismatch text={s} options={any}\nold={any}\nnew={any}\nqueries={any}\n", .{ source[0..@min(96, source.len)], options, old, new, (try fast.buildStats()).native_queries });
            return err;
        };
        try std.testing.expectApproxEqAbs(old.baseline, new.baseline, 0.001);
    }
    for (0..count + 1) |index| {
        const byte = try reference.graphemeByte(index);
        try equal(byte, try fast.graphemeByte(index));
        for ([_]t.Affinity{ .upstream, .downstream }) |affinity| {
            const caret: t.Caret = .{ .byte_offset = byte, .affinity = affinity };
            const expected = try reference.caret(caret);
            const actual = try fast.caret(caret);
            compareRect(expected, actual) catch |err| {
                std.debug.print("snapshot caret mismatch text={s} font={s}/{d} byte={d} affinity={s} old={any} new={any}\n", .{ source[0..@min(96, source.len)], options.family, options.size, byte, @tagName(affinity), expected, actual });
                return err;
            };
            const point: t.Point = .{ .x = expected.x, .y = expected.y + expected.height * 0.5 };
            const old_hit = try reference.hitTest(point);
            const new_hit = try fast.hitTest(point);
            try compareRect(try reference.caret(old_hit.caret), try fast.caret(new_hit.caret));
        }
        if (index < count) {
            try compareSelection(fast, reference, byte, try reference.graphemeByte(index + 1));
            if (count <= 128 or index % 127 == 0) try compareSelection(fast, reference, byte, try reference.graphemeByte(@min(count, index + 5)));
        }
    }
    try compareSelection(fast, reference, 0, source.len);
    if (source.len < 256) {
        const a = try fast.prepare(1.5, .{ .viewport = .{ .width = 180, .height = 120 } });
        defer a.close() catch unreachable;
        const b = try reference.prepare(1.5, .{ .viewport = .{ .width = 180, .height = 120 } });
        defer b.close() catch unreachable;
        try expect(std.mem.eql(u8, (try a.view()).coverage.pixels, (try b.view()).coverage.pixels));
    }
}
fn differential(engine: *t.Engine) !void {
    const cases = [_][]const u8{ "", "\n\n", "A\r\n\r\nB\n", "a\u{0301}b", "👩‍👩‍👧‍👦 🇨🇳 👍🏽", "abc אבג 123 مرحبا بالعالم xyz", "office affinity fi ffi AV To", "ক্ষি กำ က္က क्‍ष", "中文日本語한국어", "ab\tcd\u{00ad}ef\u{200b}gh", "x\u{202b}אבג\u{202c} y", "مرحبا\nabc\n", "  \t \r\n\t  ", "\u{200d}\u{200c}\u{202a}\u{202c}\u{2066}\u{2069}", "Latin中文العربية한글 אבג" };
    for (cases) |source| for ([_]t.Direction{ .ltr, .rtl }) |direction| for ([_]t.Wrap{ .none, .word_character }) |wrap| {
        try compareLayouts(engine, source, .{ .size = 17.3, .direction = direction, .width = if (wrap == .none) 0 else 65, .wrap = wrap });
    };
    for ([_][]const u8{ "Calibri", "Times New Roman", "Consolas" }) |family| try compareLayouts(engine, "office fi ffi AV x\u{0301} אבג", .{ .family = family, .size = 19.1 });
    for ([_]usize{ 1024, 2048, 4096, 8192 }) |length| {
        const source = "a" ** 8192;
        try compareLayouts(engine, source[0..length], .{});
    }
    try compareLayouts(engine, "abc\n" ** 1024, .{});
    try compareLayouts(engine, "i\n" ** 2000, .{ .size = 18 });
    try compareLayouts(engine, "\r\n" ** 1024, .{ .size = 21.3 });
    try compareLayouts(engine, " \t" ** 2048, .{ .size = 19.7 });
    try compareLayouts(engine, "abc אבג العربية a\u{0301} 👩‍👩‍👧‍👦\n" ** 128, .{});
    std.debug.print("snapshot differential passed: reference carets/affinities, islands/selections, line geometry, native coverage and long documents\n", .{});
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try equal(t.ResourceCounts{}, t.resourceCounts());
    {
        const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
        defer engine.close() catch unreachable;
        try segmentation(engine);
        try bidiAndSelection(engine);
        try multiScalarSelection(engine);
        try paragraphs(engine);
        try preparations(engine);
        try ownership(allocator, engine);
        try differential(engine);
        try constructionCost(engine);
        try snapshotBudget(allocator, engine);
    }
    try limits(allocator);
    try allocationBudgets(allocator);
    try allocationFailure(allocator);
    try equal(t.ResourceCounts{}, t.resourceCounts());
    std.debug.print("text layout smoke passed: native shaping/bidi/wrap/graphemes/UTF8-UTF16/caret/hit/selection, budgets/owner/snapshots, resources=0\n", .{});
}
