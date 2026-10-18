const std = @import("std");
const d = @import("ziggurat_document");
const diff = @import("root.zig");

const Inputs = struct {
    a: *d.Document,
    b: *d.Document,
    sa: *d.Snapshot,
    sb: *d.Snapshot,
    ra: d.Reader,
    rb: d.Reader,
    fn init(a: []const u8, b: []const u8) !Inputs {
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
        return .{ .a = da, .b = db, .sa = sa, .sb = sb, .ra = ra, .rb = rb };
    }
    fn deinit(self: Inputs) void {
        self.rb.release() catch unreachable;
        self.ra.release() catch unreachable;
        self.sb.close() catch unreachable;
        self.sa.close() catch unreachable;
        self.b.close() catch unreachable;
        self.a.close() catch unreachable;
    }
};
fn reconstruct(allocator: std.mem.Allocator, a: []const u8, b: []const u8, hunks: []const diff.Hunk) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var previous_a: usize = 0;
    var previous_b: usize = 0;
    for (hunks) |hunk| {
        try std.testing.expect(hunk.a.bytes.start >= previous_a and hunk.b.bytes.start >= previous_b);
        try std.testing.expectEqualStrings(a[previous_a..hunk.a.bytes.start], b[previous_b..hunk.b.bytes.start]);
        try output.appendSlice(allocator, a[previous_a..hunk.a.bytes.start]);
        try output.appendSlice(allocator, b[hunk.b.bytes.start..hunk.b.bytes.end]);
        previous_a = hunk.a.bytes.end;
        previous_b = hunk.b.bytes.end;
    }
    try std.testing.expectEqualStrings(a[previous_a..], b[previous_b..]);
    try output.appendSlice(allocator, a[previous_a..]);
    try std.testing.expectEqualStrings(b, output.items);
}

test "diff exact line endings, empty documents, Unicode and byte coordinates" {
    const cases = [_][2][]const u8{
        .{ "", "" },                               .{ "", "a\n" },                  .{ "a\n", "" },    .{ "same", "same" },
        .{ "a", "a\n" },                           .{ "a\r\n", "a\n" },             .{ "\n\n", "\n" }, .{ "前\n😀\n後", "前\n新😀\n後\n" },
        .{ "a\nb\nc\nd\ne\n", "a\nx\nc\ny\ne\n" }, .{ "a\na\nb\na", "b\na\na\na" },
    };
    for (cases) |pair| {
        const inputs = try Inputs.init(pair[0], pair[1]);
        defer inputs.deinit();
        var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
        defer result.deinit();
        try reconstruct(std.testing.allocator, pair[0], pair[1], result.hunks);
        try std.testing.expectEqual(pair[0].len, result.a.bytes);
        try std.testing.expectEqual(pair[1].len, result.b.bytes);
    }
}
fn sequence(number: usize, output: *[8]u8) []const u8 {
    var n = number + 1;
    var length: usize = 0;
    while (n > 1) : (n /= 2) {
        output[length] = if (n % 2 == 0) 'a' else 'b';
        output[length + 1] = '\n';
        length += 2;
    }
    return output[0..length];
}
fn oracle(a: []const u8, b: []const u8) usize {
    var table: [5][5]usize = @splat(@splat(0));
    const n = a.len / 2;
    const m = b.len / 2;
    for (0..n + 1) |i| table[i][0] = i;
    for (0..m + 1) |j| table[0][j] = j;
    for (0..n) |i| for (0..m) |j| {
        table[i + 1][j + 1] = if (a[i * 2] == b[j * 2]) table[i][j] else @min(table[i][j + 1], table[i + 1][j]) + 1;
    };
    return table[n][m];
}
test "diff exhaustive binary sequences reconstruct and have minimal edit distance" {
    var bytes_a: [8]u8 = undefined;
    var bytes_b: [8]u8 = undefined;
    for (0..31) |i| for (0..31) |j| {
        const a = sequence(i, &bytes_a);
        const b = sequence(j, &bytes_b);
        const inputs = try Inputs.init(a, b);
        defer inputs.deinit();
        var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
        defer result.deinit();
        try reconstruct(std.testing.allocator, a, b, result.hunks);
        try std.testing.expectEqual(oracle(a, b), result.stats.distance);
        var distance: usize = 0;
        for (result.hunks) |hunk| distance += hunk.a.lines.end - hunk.a.lines.start + hunk.b.lines.end - hunk.b.lines.start;
        try std.testing.expectEqual(distance, result.stats.distance);
    };
}
fn allocationProbe(allocator: std.mem.Allocator, inputs: Inputs) !void {
    var result = try diff.compare(allocator, inputs.ra, inputs.rb, .{});
    defer result.deinit();
    try std.testing.expectEqual(2, result.stats.distance);
}
test "diff candidate allocation failures preserve both inputs and release every allocation" {
    const inputs = try Inputs.init("a\nb\nc", "a\nx\nc");
    defer inputs.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{inputs});
    try std.testing.expectEqual(0, try inputs.a.version());
    try std.testing.expectEqual(0, try inputs.b.version());
}
test "diff explicit aggregate memory, work, distance, lines and cancellation" {
    const inputs = try Inputs.init("a\nb\nc", "a\nx\nc");
    defer inputs.deinit();
    var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
    defer result.deinit();
    const stats = result.stats;
    var exact = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .bytes = stats.peak_bytes, .work = stats.work, .distance = stats.distance, .lines = 3 } });
    defer exact.deinit();
    // Distance changes the trace reservation; compare the memory bound using
    // the original distance limit to keep allocation sizes identical.
    try std.testing.expectError(error.CapacityExceeded, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .bytes = stats.peak_bytes - 1 } }));
    try std.testing.expectError(error.WorkLimitExceeded, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .work = stats.work - 1 } }));
    try std.testing.expectError(error.DistanceLimitExceeded, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .distance = 1 } }));
    try std.testing.expectError(error.LineLimitExceeded, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .lines = 2 } }));
    var cancel: diff.Cancellation = .{};
    cancel.request();
    try std.testing.expectError(error.Cancelled, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .cancellation = &cancel }));
    try std.testing.expectError(error.InvalidLimits, diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .work = 0 } }));
}
test "diff result survives Readers and captures original versions while owner edits" {
    const inputs = try Inputs.init("a\nb", "a\nc");
    var result = diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{}) catch |err| {
        inputs.deinit();
        return err;
    };
    defer result.deinit();
    try inputs.b.replace(.{ .start = 0, .end = 1 }, "new");
    try std.testing.expectEqual(0, result.b.text_version);
    try std.testing.expectEqual(1, try inputs.b.committedTextVersion());
    inputs.deinit();
    try reconstruct(std.testing.allocator, "a\nb", "a\nc", result.hunks);
}
test "diff equal inputs require no edit distance and line limit includes real terminated records" {
    const inputs = try Inputs.init("a\n", "a\n");
    defer inputs.deinit();
    var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{ .limits = .{ .lines = 1, .distance = 0 } });
    defer result.deinit();
    try std.testing.expectEqual(0, result.hunks.len);
    try std.testing.expectEqual(1, result.stats.lines_a);
    try std.testing.expectEqual(0, result.stats.distance);
}

test "diff confirms equal line bytes across unequal persistent tree leaf boundaries" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, d.leaf_bytes * 5 + 37);
    defer allocator.free(bytes);
    @memset(bytes, 'a');
    bytes[bytes.len / 2] = '\n';
    const inputs = try Inputs.init(bytes, bytes);
    defer inputs.deinit();
    // Rebuild identical bytes through a different splice history. The Reader
    // still sees the original roots and leaf segmentation is never assumed.
    try inputs.a.replace(.{ .start = 11, .end = 12 }, "a");
    const changed = try inputs.a.snapshot();
    defer changed.close() catch unreachable;
    const reader = try changed.borrowReader();
    defer reader.release() catch unreachable;
    var result = try diff.compare(allocator, reader, inputs.rb, .{});
    defer result.deinit();
    try std.testing.expectEqual(0, result.hunks.len);
    try std.testing.expectEqual(bytes.len, result.stats.compared_bytes);
    try std.testing.expectEqual(bytes.len * 2, result.stats.hash_bytes);
}

const Worker = struct {
    a: d.Reader,
    b: d.Reader,
    started: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
    result: ?diff.Result = null,
    failure: ?anyerror = null,
    fn run(self: *Worker) void {
        self.started.store(true, .release);
        while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
        self.result = diff.compare(std.testing.allocator, self.a, self.b, .{}) catch |err| {
            self.failure = err;
            return;
        };
    }
};
test "diff explicit worker reads original snapshots while owner publishes new text" {
    const inputs = try Inputs.init("first\nold\nlast\n", "first\nnew\nlast\n");
    defer inputs.deinit();
    var worker: Worker = .{ .a = inputs.ra, .b = inputs.rb };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.acquire)) std.atomic.spinLoopHint();
    worker.proceed.store(true, .release);
    // Main-thread mutations never touch the immutable snapshot roots.
    for (0..64) |_| try inputs.b.replace(.{ .start = 0, .end = 1 }, "F");
    thread.join();
    if (worker.failure) |err| return err;
    var result = worker.result.?;
    defer result.deinit();
    try reconstruct(std.testing.allocator, "first\nold\nlast\n", "first\nnew\nlast\n", result.hunks);
    try std.testing.expectEqual(0, result.b.text_version);
    try std.testing.expectEqual(64, try inputs.b.committedTextVersion());
}

test "diff result clears ownership before a reentrant allocator free" {
    const Allocator = struct {
        result: ?*diff.Result = null,
        target: usize = 0,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(_: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(size, alignment, ret);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (@intFromPtr(memory.ptr) == self.target) {
                self.frees += 1;
                if (self.frees != 1) return;
                self.result.?.deinit();
            }
            std.testing.allocator.rawFree(memory, alignment, ret);
        }
    };
    const inputs = try Inputs.init("a", "b");
    defer inputs.deinit();
    var allocator: Allocator = .{};
    var result = try diff.compare(allocator.allocator(), inputs.ra, inputs.rb, .{});
    allocator.result = &result;
    allocator.target = @intFromPtr(result.storage.ptr);
    result.deinit();
    try std.testing.expectEqual(1, allocator.frees);
    try std.testing.expectEqual(0, result.hunks.len);
    try std.testing.expectEqual(0, result.storage.len);
}

fn randomText(random: std.Random, buffer: *[128]u8) []const u8 {
    const words = [_][]const u8{ "a", "b", "😀", "中", "", "\x00" };
    const count = random.uintLessThan(usize, 9);
    var used: usize = 0;
    for (0..count) |index| {
        const word = words[random.uintLessThan(usize, words.len)];
        @memcpy(buffer[used..][0..word.len], word);
        used += word.len;
        if (index + 1 != count or random.boolean()) {
            if (random.boolean()) {
                buffer[used] = '\r';
                used += 1;
            }
            buffer[used] = '\n';
            used += 1;
        }
    }
    return buffer[0..used];
}
fn splitRecords(bytes: []const u8, output: *[8][]const u8) []const []const u8 {
    var start: usize = 0;
    var count: usize = 0;
    for (bytes, 0..) |byte, at| if (byte == '\n') {
        output[count] = bytes[start .. at + 1];
        count += 1;
        start = at + 1;
    };
    if (start != bytes.len) {
        output[count] = bytes[start..];
        count += 1;
    }
    return output[0..count];
}
test "diff deterministic randomized Unicode and mixed endings match independent distance oracle" {
    var generator = std.Random.DefaultPrng.init(0x8b51a37dc29e1604);
    const random = generator.random();
    var bytes_a: [128]u8 = undefined;
    var bytes_b: [128]u8 = undefined;
    var records_a: [8][]const u8 = undefined;
    var records_b: [8][]const u8 = undefined;
    for (0..512) |_| {
        const a = randomText(random, &bytes_a);
        const b = randomText(random, &bytes_b);
        const lines_a = splitRecords(a, &records_a);
        const lines_b = splitRecords(b, &records_b);
        var table: [9][9]usize = @splat(@splat(0));
        for (0..lines_a.len + 1) |i| table[i][0] = i;
        for (0..lines_b.len + 1) |j| table[0][j] = j;
        for (lines_a, 0..) |left, i| for (lines_b, 0..) |right, j| {
            table[i + 1][j + 1] = if (std.mem.eql(u8, left, right)) table[i][j] else @min(table[i][j + 1], table[i + 1][j]) + 1;
        };
        const inputs = try Inputs.init(a, b);
        defer inputs.deinit();
        var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
        defer result.deinit();
        try reconstruct(std.testing.allocator, a, b, result.hunks);
        try std.testing.expectEqual(table[lines_a.len][lines_b.len], result.stats.distance);
    }
}

test "diff common repeated context anchors a middle replacement to that line" {
    const inputs = try Inputs.init("a\na\na\na\na\n", "a\na\nb\na\na\n");
    defer inputs.deinit();
    var result = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
    defer result.deinit();
    try std.testing.expectEqual(2, result.stats.distance);
    try std.testing.expectEqual(1, result.hunks.len);
    try std.testing.expectEqualDeep(diff.LineRange{ .start = 2, .end = 3 }, result.hunks[0].a.lines);
    try std.testing.expectEqualDeep(diff.LineRange{ .start = 2, .end = 3 }, result.hunks[0].b.lines);
    try reconstruct(std.testing.allocator, "a\na\na\na\na\n", "a\na\nb\na\na\n", result.hunks);
}

test "diff explicit result move is distinguishable even for zero-hunk results" {
    for ([_][]const u8{ "a", "b" }) |right| {
        const inputs = try Inputs.init("a", right);
        defer inputs.deinit();
        var source = try diff.compare(std.testing.allocator, inputs.ra, inputs.rb, .{});
        defer source.deinit();
        try std.testing.expect(source.isOwned());
        var destination = try source.take();
        defer destination.deinit();
        try std.testing.expect(!source.isOwned() and destination.isOwned());
        try std.testing.expectError(error.ResultMoved, source.take());
        try reconstruct(std.testing.allocator, "a", right, destination.hunks);
        destination.deinit();
        try std.testing.expect(!destination.isOwned());
        try std.testing.expectError(error.ResultMoved, destination.take());
    }
}
