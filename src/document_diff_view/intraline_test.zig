const std = @import("std");
const d = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");
const model = @import("intraline.zig");
const Fixture = struct {
    documents: [2]*d.Document,
    snapshots: [2]*d.Snapshot,
    readers: [2]d.Reader,
    lines: diff.Result,
    fn create(a: []const u8, b: []const u8) !Fixture {
        const allocator = std.testing.allocator;
        const da = try d.Document.create(allocator, std.Thread.getCurrentId(), a, .{});
        errdefer da.close() catch unreachable;
        const db = try d.Document.create(allocator, std.Thread.getCurrentId(), b, .{});
        errdefer db.close() catch unreachable;
        const sa = try da.snapshot();
        errdefer sa.close() catch unreachable;
        const sb = try db.snapshot();
        errdefer sb.close() catch unreachable;
        const ra = try sa.borrowReader();
        errdefer ra.release() catch unreachable;
        const rb = try sb.borrowReader();
        errdefer rb.release() catch unreachable;
        return .{ .documents = .{ da, db }, .snapshots = .{ sa, sb }, .readers = .{ ra, rb }, .lines = try diff.compare(allocator, ra, rb, .{}) };
    }
    fn close(self: *Fixture) void {
        self.lines.deinit();
        for (self.readers) |reader| reader.release() catch unreachable;
        for (self.snapshots) |snapshot| snapshot.close() catch unreachable;
        for (self.documents) |document| document.close() catch unreachable;
    }
    fn compare(self: *Fixture, options: model.Options) !model.Result {
        return model.compare(std.testing.allocator, self.readers[0], self.readers[1], &self.lines, options);
    }
};

fn expectReconstruction(a: []const u8, b: []const u8, result: *const model.Result) !void {
    var previous_a: usize = 0;
    var previous_b: usize = 0;
    for (result.spans) |span| {
        try std.testing.expectEqualStrings(a[previous_a..span.a.start], b[previous_b..span.b.start]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(a[span.a.start..span.a.end]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(b[span.b.start..span.b.end]));
        previous_a = span.a.end;
        previous_b = span.b.end;
    }
    try std.testing.expectEqualStrings(a[previous_a..], b[previous_b..]);
}
test "scalar edits retain original UTF8 ranges, combining marks, emoji, bidi, NUL and exact CRLF" {
    const cases = [_][2][]const u8{
        .{ "prefix e\u{301} 😀 אב suffix\r\n", "prefix e\u{308} 😃 אג suffix\n" },
        .{ "a\x00b", "a\x00文b" },
        .{ "aaaaXaaaa", "aaaaYaaaa" },
        .{ "one\npaired\nleft only", "ONE\nPAIRED\nright only" },
        .{ "line\n", "line" },
    };
    for (cases) |pair| {
        var fixture = try Fixture.create(pair[0], pair[1]);
        defer fixture.close();
        var details = try fixture.compare(.{});
        defer details.deinit();
        try std.testing.expect(details.spans.len != 0);
        try expectReconstruction(pair[0], pair[1], &details);
    }
    var fixture = try Fixture.create("xe\u{301}y", "xe\u{308}y");
    defer fixture.close();
    var details = try fixture.compare(.{});
    defer details.deinit();
    try std.testing.expectEqualDeep(d.Range{ .start = 2, .end = 4 }, details.spans[0].a);
    try std.testing.expectEqual(@as(usize, 2), details.stats.scalar_edits);
}

test "long shared prefix and suffix pay only the middle DP cells; cumulative work is bounded" {
    var a: [7000]u8 = @splat('a');
    var b = a;
    a[3500] = 'X';
    b[3500] = 'Y';
    var fixture = try Fixture.create(&a, &b);
    defer fixture.close();
    var details = try fixture.compare(.{ .limits = .{ .cells = 4 } });
    defer details.deinit();
    try std.testing.expectEqual(@as(usize, 4), details.stats.cells);
    try std.testing.expectEqual(@as(usize, 3500), details.spans[0].a.start);
    try std.testing.expectError(error.CellLimitExceeded, fixture.compare(.{ .limits = .{ .cells = 3 } }));
    try std.testing.expectError(error.CapacityExceeded, fixture.compare(.{ .limits = .{ .line_bytes = 6999 } }));
    try std.testing.expectError(error.CapacityExceeded, fixture.compare(.{ .limits = .{ .line_scalars = 6999 } }));
    try std.testing.expectError(error.WorkLimitExceeded, fixture.compare(.{ .limits = .{ .work = 10 } }));
    var multi = try Fixture.create("a\nb\n", "x\ny\n");
    defer multi.close();
    try std.testing.expectError(error.CellLimitExceeded, multi.compare(.{ .limits = .{ .cells = 7 } }));
    try std.testing.expectError(error.CapacityExceeded, multi.compare(.{ .limits = .{ .pairs = 1 } }));
    try std.testing.expectError(error.CapacityExceeded, multi.compare(.{ .limits = .{ .spans = 1 } }));
    var cancelled: diff.Cancellation = .{};
    cancelled.request();
    try std.testing.expectError(error.Cancelled, multi.compare(.{ .cancellation = &cancelled }));
}

test "ordinal pairing leaves unmatched rows whole; empty detailed results still have move ownership" {
    var fixture = try Fixture.create("only left\n", "");
    defer fixture.close();
    var details = try fixture.compare(.{});
    try std.testing.expectEqual(@as(usize, 0), details.spans.len);
    var moved = try details.take();
    defer moved.deinit();
    details.deinit();
    try std.testing.expect(!details.isOwned());
    try std.testing.expectError(error.ResultMoved, details.take());
    try std.testing.expect(moved.isOwned());
}

fn allocationProbe(allocator: std.mem.Allocator, fixture: *Fixture) !void {
    var details = try model.compare(allocator, fixture.readers[0], fixture.readers[1], &fixture.lines, .{});
    defer details.deinit();
    try std.testing.expect(details.stats.peak_bytes >= details.storage.len * @sizeOf(model.Span));
}
test "every details allocation failure releases scratch and output; peak bytes include growing output" {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    for (0..25) |at| {
        var bytes: [4]u8 = undefined;
        const count = try std.unicode.utf8Encode(@intCast(0x100 + at), &bytes);
        try a.appendSlice(std.testing.allocator, bytes[0..count]);
        try b.appendSlice(std.testing.allocator, bytes[0..count]);
        try a.append(std.testing.allocator, 'a');
        try b.append(std.testing.allocator, 'b');
    }
    var fixture = try Fixture.create(a.items, b.items);
    defer fixture.close();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{&fixture});
    var details = try fixture.compare(.{});
    defer details.deinit();
    try std.testing.expect(details.storage.len > 8);
    try std.testing.expectError(error.CapacityExceeded, fixture.compare(.{ .limits = .{ .bytes = details.stats.peak_bytes - 1 } }));
    var exact = try fixture.compare(.{ .limits = .{ .bytes = details.stats.peak_bytes } });
    exact.deinit();
}

test "cancellation after DP scratch allocation unwinds all ownership" {
    const CancelAllocator = struct {
        cancellation: diff.Cancellation = .{},
        count: usize = 0,
        fn alloc(ptr: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const allocation = std.testing.allocator.rawAlloc(size, alignment, ret) orelse return null;
            self.count += 1;
            if (self.count == 5) self.cancellation.request();
            return allocation;
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ret);
        }
    };
    var fixture = try Fixture.create("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb");
    defer fixture.close();
    var cancelling: CancelAllocator = .{};
    const allocator: std.mem.Allocator = .{ .ptr = &cancelling, .vtable = &.{ .alloc = CancelAllocator.alloc, .resize = CancelAllocator.resize, .remap = std.mem.Allocator.noRemap, .free = CancelAllocator.free } };
    try std.testing.expectError(error.Cancelled, model.compare(allocator, fixture.readers[0], fixture.readers[1], &fixture.lines, .{ .cancellation = &cancelling.cancellation }));
    try std.testing.expectEqual(@as(usize, 5), cancelling.count);
}

test "512 random scalar sequences match independent prefix DP distance and byte reconstruction" {
    var random = std.Random.DefaultPrng.init(0x928b61);
    const alphabet = [_][]const u8{ "a", "b", "文", "😀", "\u{301}", "א", "\x00" };
    for (0..512) |_| {
        var strings: [2]std.ArrayList(u8) = @splat(.empty);
        defer for (&strings) |*string| string.deinit(std.testing.allocator);
        var scalars: [2][12]u8 = undefined;
        var lengths: [2]usize = undefined;
        for (&strings, &scalars, &lengths) |*string, *values, *length| {
            try string.appendSlice(std.testing.allocator, "@");
            length.* = random.random().uintLessThan(usize, 11);
            for (values[0..length.*]) |*value| {
                value.* = random.random().uintLessThan(u8, alphabet.len);
                try string.appendSlice(std.testing.allocator, alphabet[value.*]);
            }
            try string.appendSlice(std.testing.allocator, "!");
        }
        var table: [13][13]u8 = @splat(@splat(0));
        for (0..lengths[0]) |a| for (0..lengths[1]) |b| {
            table[a + 1][b + 1] = if (scalars[0][a] == scalars[1][b]) table[a][b] + 1 else @max(table[a][b + 1], table[a + 1][b]);
        };
        var fixture = try Fixture.create(strings[0].items, strings[1].items);
        defer fixture.close();
        var details = try fixture.compare(.{});
        defer details.deinit();
        try std.testing.expectEqual(lengths[0] + lengths[1] - 2 * @as(usize, table[lengths[0]][lengths[1]]), details.stats.scalar_edits);
        try expectReconstruction(strings[0].items, strings[1].items, &details);
    }
}
