const std = @import("std");
const doc = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");

fn measure(allocator: std.mem.Allocator, records: usize, changed: bool) !void {
    const row = "record value 00\n";
    const bytes = try allocator.alloc(u8, row.len * records);
    defer allocator.free(bytes);
    for (0..records) |index| @memcpy(bytes[index * row.len ..][0..row.len], row);
    const a = try doc.Document.create(allocator, std.Thread.getCurrentId(), bytes, .{});
    defer a.close() catch unreachable;
    const b = try doc.Document.create(allocator, std.Thread.getCurrentId(), bytes, .{});
    defer b.close() catch unreachable;
    if (changed) {
        const at = records / 2 * row.len + 13;
        try b.replace(.{ .start = at, .end = at + 1 }, "1");
    }
    const sa = try a.snapshot();
    defer sa.close() catch unreachable;
    const sb = try b.snapshot();
    defer sb.close() catch unreachable;
    const ra = try sa.borrowReader();
    defer ra.release() catch unreachable;
    const rb = try sb.borrowReader();
    defer rb.release() catch unreachable;
    var samples: [7]u64 = undefined;
    var stats: diff.Stats = undefined;
    for (&samples) |*sample| {
        var timer = try std.time.Timer.start();
        var result = try diff.compare(allocator, ra, rb, .{});
        sample.* = timer.read();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, if (changed) 2 else 0), result.stats.distance);
        try std.testing.expectEqual(@as(usize, @intFromBool(changed)), result.hunks.len);
        stats = result.stats;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("document-diff records={d} bytes_per_side={d} changed={} median_ns={d} p95_ns={d} peak_bytes={d} work={d} frontier_steps={d}\n", .{ records, bytes.len, changed, samples[3], samples[6], stats.peak_bytes, stats.work, stats.frontier_steps });
}

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    for ([_]usize{ 10000, 100000 }) |records| {
        try measure(allocations.allocator(), records, false);
        try measure(allocations.allocator(), records, true);
    }
}
