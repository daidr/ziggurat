const std = @import("std");
const builtin = @import("builtin");
const t = @import("ziggurat_text_layout");
extern fn ztl_word_test_missing(c_int) void;
extern fn ztl_word_test_counts(*u32, *u32, *u32, *u32) void;
fn counts() [4]u32 {
    var result: [4]u32 = undefined;
    ztl_word_test_counts(&result[0], &result[1], &result[2], &result[3]);
    return result;
}
fn allocationPass(allocator: std.mem.Allocator, engine: *t.Engine) !void {
    const layout = try engine.layoutAllocated(allocator, "alpha 😀 beta", .{ .word_ranges = true });
    defer layout.close() catch unreachable;
    _ = try layout.wordRangeAt(.{ .byte_offset = 0 });
    const prepared = try layout.prepare(1.25, .{});
    defer prepared.close() catch unreachable;
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const before = counts();
    ztl_word_test_missing(1);
    const engine = try t.Engine.create(gpa.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    for ([_][]const u8{ "", "alpha beta" }) |value| {
        const ordinary = try engine.layout(value, .{});
        try std.testing.expectError(error.WordRangesNotEnabled, ordinary.wordRangeAt(.{ .byte_offset = 0 }));
        try ordinary.close();
    }
    try std.testing.expectEqualDeep(before, counts());
    if (builtin.os.tag == .windows) {
        for ([_][]const u8{ "", "alpha beta" }) |value| {
            const resources = t.resourceCounts();
            try std.testing.expectError(error.UnicodeSegmentationUnavailable, engine.layout(value, .{ .word_ranges = true }));
            try std.testing.expectEqualDeep(resources, t.resourceCounts());
            const native_error = try engine.lastNativeError();
            try std.testing.expect(native_error.domain == 2 and native_error.code == 127);
        }
        const refused = counts();
        try std.testing.expect(refused[0] == before[0] + 2 and refused[1] == before[1] + 2 and refused[2] == refused[3]);
    }
    ztl_word_test_missing(0);
    const empty_before = counts();
    const empty = try engine.layout("", .{ .word_ranges = true });
    try std.testing.expectEqualDeep(@as(t.ByteRange, .{ .start = 0, .end = 0 }), try empty.wordRangeAt(.{ .byte_offset = 0 }));
    try empty.close();
    const empty_after = counts();
    try std.testing.expect(empty_after[0] == empty_before[0] + 1 and empty_after[2] == empty_before[2] and empty_after[3] == empty_before[3]);
    if (builtin.os.tag == .windows) try std.testing.expect(empty_after[1] == empty_before[1] + 1);
    const layout = try engine.layout("alpha beta", .{ .word_ranges = true });
    const ready = counts();
    for (0..128) |_| {
        try std.testing.expectEqualDeep(@as(t.ByteRange, .{ .start = 0, .end = 5 }), try layout.wordRangeAt(.{ .byte_offset = 2 }));
    }
    try std.testing.expectEqualDeep(ready, counts());
    try std.testing.expect(ready[2] == ready[3]);
    try layout.close();
    const resources = t.resourceCounts();
    try std.testing.checkAllAllocationFailures(gpa.allocator(), allocationPass, .{engine});
    try std.testing.expectEqualDeep(resources, t.resourceCounts());
    const after_oom = counts();
    try std.testing.expect(after_oom[2] == after_oom[3]);
    std.debug.print("word fault passed: missing-export affects opt-in only (Windows), enabled-empty capability/no iterator, query no native call; counters={any}\n", .{counts()});
}
