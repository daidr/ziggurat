const std = @import("std");
const text = @import("ziggurat_text_layout");

// Records caller-owned storage only. SDK caches/allocations and elapsed time
// are intentionally outside these deterministic construction records.
const Memory = struct {
    child: std.mem.Allocator,
    requests: [64]usize = undefined,
    count: usize = 0,
    live: usize = 0,
    peak: usize = 0,
    fn allocator(self: *Memory) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        if (self.count == self.requests.len) return null;
        const value = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.requests[self.count] = len;
        self.count += 1;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return value;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Memory = @ptrCast(@alignCast(ptr));
        self.live -= bytes.len;
        self.child.rawFree(bytes, alignment, ret);
    }
    fn print(self: *const Memory) void {
        for (self.requests[0..self.count], 0..) |length, i| std.debug.print("{s}{d}", .{ if (i == 0) "" else ",", length });
    }
};
fn run(engine: *text.Engine, allocator: std.mem.Allocator, value: []const u8, index: usize, words: bool) !void {
    var memory: Memory = .{ .child = allocator };
    var options: text.Options = .{ .size = 19.1, .locale = "en" };
    if (comptime @hasField(text.Options, "word_ranges")) options.word_ranges = words else if (words) return error.WordQueryUnavailable;
    const layout = try engine.layoutAllocated(memory.allocator(), value, options);
    const stats = try layout.buildStats();
    const layout_allocations = memory.count;
    const prepared = try layout.prepare(1.5, .{});
    _ = try prepared.view();
    try prepared.close();
    try layout.close();
    try std.testing.expectEqual(@as(usize, 0), memory.live);
    std.debug.print("word-cost case={d} enabled={} options={d} layout_state_request={d} layout_allocations={d} total_allocations={d} allocator_peak={d} owned={d} layout_peak={d} graphemes={d} native_calls={d} requests=[", .{
        index, words, @sizeOf(text.Options), memory.requests[0], layout_allocations, memory.count, memory.peak, stats.owned_bytes, stats.peak_owned_bytes, stats.graphemes, stats.native_calls,
    });
    memory.print();
    std.debug.print("]\n", .{});
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var memory: Memory = .{ .child = gpa.allocator() };
    const engine = try text.Engine.create(memory.allocator(), std.Thread.getCurrentId(), .{});
    for ([_][]const u8{ "", "alpha,  beta!", "e\u{301}lan אבג\r\n", "a👩‍👩‍👧‍👦b" }, 0..) |value, index| {
        try run(engine, gpa.allocator(), value, index, false);
        if (comptime @hasField(text.Options, "word_ranges")) try run(engine, gpa.allocator(), value, index, true);
    }
    try engine.close();
    try std.testing.expectEqual(@as(usize, 0), memory.live);
    const counts = text.resourceCounts();
    try std.testing.expectEqualDeep(text.ResourceCounts{}, counts);
    std.debug.print("word-cost engine_state_request={d} engine_allocations={d} references=0; SDK storage/time unmeasured\n", .{ memory.requests[0], memory.count });
}
