const std = @import("std");
const d = @import("ziggurat_document");
const model = @import("model.zig");

fn image(allocator: std.mem.Allocator, text: []const u8, limits: model.Limits) !model.Text {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), text, .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    return model.Text.create(allocator, reader, limits);
}
test "full committed text preserves UTF16, hidden-capable ranges, scalar and actual paragraph boundaries" {
    var text = try image(std.testing.allocator, "a\r\n😀e\u{301}\x00\n", .{});
    defer text.deinit();
    try std.testing.expectEqualSlices(u16, &.{ 'a', '\r', '\n', 0xd83d, 0xde00, 'e', 0x301, 0, '\n' }, text.utf16);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 5, 6, 7, 8, 9 }, text.scalars);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 9, 9 }, text.paragraphs);
    try text.validateRange(.{ .start = 0, .end = 9 });
    try std.testing.expectError(error.InvalidBoundary, text.validateRange(.{ .start = 4, .end = 5 }));
    try std.testing.expectError(error.InvalidRange, text.validateRange(.{ .start = 9, .end = 8 }));
    var empty = try image(std.testing.allocator, "", .{});
    defer empty.deinit();
    try std.testing.expectEqualSlices(u32, &.{0}, empty.scalars);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, empty.paragraphs);
    var moved = try empty.take();
    defer moved.deinit();
    try std.testing.expect(!empty.isOwned());
    try std.testing.expectError(error.TextMoved, empty.take());
    empty.deinit();
}
test "candidate counts capacity before allocating and rejects all allocation failures without retaining Readers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var text = try image(allocator, "hello😀\nthere", .{});
            text.deinit();
        }
    }.run, .{});
    var text = try image(std.testing.allocator, "hello😀\nthere", .{});
    defer text.deinit();
    try std.testing.expectError(error.CapacityExceeded, image(std.testing.allocator, "hello😀\nthere", .{ .bytes = text.owned_bytes - 1 }));
    try std.testing.expectError(error.CapacityExceeded, image(std.testing.allocator, "hello😀\nthere", .{ .utf16_units = text.utf16.len - 1 }));
    try std.testing.expectError(error.CapacityExceeded, image(std.testing.allocator, "hello😀\nthere", .{ .scalar_boundaries = text.scalars.len - 1 }));
    try std.testing.expectError(error.CapacityExceeded, image(std.testing.allocator, "hello\nthere", .{ .paragraphs = 2 }));
    try std.testing.expectError(error.CapacityExceeded, model.footprint(std.math.maxInt(usize), 0, 0));
}
test "cross-leaf conversion is a full immutable text stamp and does not expose composition as document text" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (0..2200) |_| try bytes.appendSlice(std.testing.allocator, "😀é\r\n");
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), bytes.items, .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    var text = try model.Text.create(std.testing.allocator, reader, .{});
    defer text.deinit();
    var oracle: [12000]u16 = undefined;
    const expected = try std.unicode.utf8ToUtf16Le(&oracle, bytes.items);
    try std.testing.expectEqualSlices(u16, oracle[0..expected], text.utf16);
    const original_text_stamp = text.stamp.text_version;
    _ = try document.setSelection(.{ .anchor = 0, .caret = 4 });
    try document.setComposition("short", .{ .anchor = 0, .caret = 5 });
    try std.testing.expectEqual(original_text_stamp, try document.committedTextVersion());
    try std.testing.expect(try document.version() != text.stamp.revision);
    try std.testing.expectEqualSlices(u16, oracle[0..expected], text.utf16);
}
