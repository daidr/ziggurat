const std = @import("std");
const d = @import("root.zig");
const a = std.testing.allocator;
test "reader leases are bounded generational and close only after atomic release" {
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), "a😀中\r\nb", .{ .readers_per_snapshot = 1 });
    defer doc.close() catch unreachable;
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const old = try saved.borrowReader();
    try std.testing.expectError(error.ReadersFull, saved.borrowReader());
    try std.testing.expectError(error.ReadersAlive, saved.close());
    try std.testing.expectEqual(try saved.byteLength(), try old.byteLength());
    try std.testing.expectEqual(try saved.utf16Length(), try old.utf16Length());
    for ([_]usize{ 0, 1, 5, 8, 9, 10, 11 }) |byte| {
        try std.testing.expectEqual(try saved.utf16Offset(byte), try old.utf16Offset(byte));
        try std.testing.expectEqual(byte, try old.byteOffsetFromUtf16(try old.utf16Offset(byte)));
        try std.testing.expectEqual(try saved.lineAt(byte), try old.lineAt(byte));
    }
    try std.testing.expectError(error.InvalidBoundary, old.byteOffsetFromUtf16(2));
    try std.testing.expectError(error.InvalidBoundary, old.cursor(.{ .start = 2, .end = 5 }));
    try old.release();
    const next = try saved.borrowReader();
    try std.testing.expectError(error.ReaderClosed, old.byteLength());
    try std.testing.expectError(error.ReaderClosed, old.release());
    try std.testing.expectError(error.ReadersAlive, saved.close());
    var cursor = try next.cursor(.{ .start = 1, .end = 8 });
    try std.testing.expectEqualStrings("😀中", (try cursor.next()).?.bytes);
    try next.release();
    try std.testing.expectError(error.ReaderClosed, cursor.next());
    try std.testing.expectError(error.ReaderClosed, next.release());
}
test "snapshot reader runs concurrently with owner edits and outlives document without root destruction on worker" {
    const source = "abc 😀 中\r\n" ** 2048;
    const doc = try d.Document.create(a, std.Thread.getCurrentId(), source, .{ .history_entries = 8 });
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const Worker = struct {
        reader: d.Reader,
        expected: u64,
        halfway: std.Thread.ResetEvent = .{},
        continue_reads: std.Thread.ResetEvent = .{},
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.checked() catch |err| {
                self.failure = err;
                self.halfway.set();
            };
        }
        fn checked(self: *@This()) !void {
            defer self.reader.release() catch unreachable;
            for (0..300) |iteration| {
                if (iteration == 150) {
                    self.halfway.set();
                    self.continue_reads.wait();
                }
                var cursor = try self.reader.cursor(.{ .start = 0, .end = try self.reader.byteLength() });
                var hash: std.hash.Wyhash = .init(0);
                var offset: usize = 0;
                while (try cursor.next()) |segment| {
                    try std.testing.expectEqual(offset, segment.start);
                    hash.update(segment.bytes);
                    offset += segment.bytes.len;
                }
                try std.testing.expectEqual(self.expected, hash.final());
                try std.testing.expectEqual(@as(usize, 2049), try self.reader.lineCount());
                const last = try self.reader.line(2048);
                try std.testing.expectEqual(last.start, last.end);
            }
        }
    };
    var worker: Worker = .{ .reader = try saved.borrowReader(), .expected = std.hash.Wyhash.hash(0, source) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    for (0..300) |iteration| try doc.replace(.{ .start = 0, .end = 1 }, if (iteration % 2 == 0) "X" else "Y");
    worker.halfway.wait();
    try doc.close();
    try std.testing.expectError(error.ReadersAlive, saved.close());
    worker.continue_reads.set();
    thread.join();
    if (worker.failure) |err| return err;
    try std.testing.expectEqual(source.len, try saved.byteLength());
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    const doc = try d.Document.create(allocator, std.Thread.getCurrentId(), "a😀b\n" ** 100, .{});
    defer doc.close() catch unreachable;
    const saved = try doc.snapshot();
    defer saved.close() catch unreachable;
    const before = try doc.stats();
    const reader = saved.borrowReader() catch |err| {
        try std.testing.expectEqual(before.owned_bytes, (try doc.stats()).owned_bytes);
        return err;
    };
    defer reader.release() catch unreachable;
    var buffer: [128]u8 = undefined;
    _ = try reader.read(.{ .start = 1, .end = 5 }, &buffer);
}
test "reader slot allocation failure leaves snapshot closable and root pinned" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}
