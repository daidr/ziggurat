const std = @import("std");
const Budget = @import("budget.zig").Budget;

test "scene budget counts capacity candidates and distinguishes actual allocation failure" {
    var budget: Budget = .{ .child = std.testing.allocator, .limit = 64, .live = 8, .peak = 8 };
    const allocator = budget.allocator();
    const first = try allocator.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 40), budget.live);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 25));
    try std.testing.expectEqual(error.CapacityExceeded, budget.failure(error.OutOfMemory));
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 8), budget.live);
    const second = try allocator.alloc(u8, 56);
    try std.testing.expectEqual(@as(usize, 64), budget.peak);
    budget.transfer(second.len);
    std.testing.allocator.free(second);
    try std.testing.expectEqual(@as(usize, 8), budget.live);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var native: Budget = .{ .child = failing.allocator(), .limit = 64, .live = 0, .peak = 0 };
    try std.testing.expectError(error.OutOfMemory, native.allocator().alloc(u8, 1));
    try std.testing.expectEqual(error.OutOfMemory, native.failure(error.OutOfMemory));
    try std.testing.expectEqual(@as(usize, 0), native.live);
}
