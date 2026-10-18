const std = @import("std");

pub const Key = struct { index: u32, generation: u64 };

/// Stable records, reusable slots and generations that never wrap.
pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { value: ?*T = null, generation: u64 = 1, next_free: ?u32 = null };
        slots: std.ArrayList(Slot) = .empty,
        free_head: ?u32 = null,
        count: usize = 0,

        pub fn insert(self: *Self, allocator: std.mem.Allocator, value: *T) !Key {
            const index = if (self.free_head) |index| blk: {
                self.free_head = self.slots.items[index].next_free;
                break :blk index;
            } else blk: {
                if (self.slots.items.len >= std.math.maxInt(u32)) return error.TooManyWindows;
                const index: u32 = @intCast(self.slots.items.len);
                try self.slots.append(allocator, .{});
                break :blk index;
            };
            const slot = &self.slots.items[index];
            slot.value = value;
            slot.next_free = null;
            self.count += 1;
            return .{ .index = index, .generation = slot.generation };
        }
        pub fn get(self: *const Self, key: Key) ?*T {
            if (key.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[key.index];
            return if (slot.generation == key.generation) slot.value else null;
        }
        pub fn remove(self: *Self, key: Key) ?*T {
            const value = self.get(key) orelse return null;
            const slot = &self.slots.items[key.index];
            slot.value = null;
            self.count -= 1;
            if (slot.generation != std.math.maxInt(u64)) {
                slot.generation += 1;
                slot.next_free = self.free_head;
                self.free_head = key.index;
            }
            return value;
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.count == 0);
            self.slots.deinit(allocator);
            self.* = .{};
        }
    };
}

test "reused slots reject stale handles without growing with creation history" {
    var registry: Registry(u32) = .{};
    defer registry.deinit(std.testing.allocator);
    var value: u32 = 42;
    const stale = try registry.insert(std.testing.allocator, &value);
    _ = registry.remove(stale);
    for (0..10000) |_| {
        const key = try registry.insert(std.testing.allocator, &value);
        try std.testing.expect(registry.get(stale) == null);
        try std.testing.expect(registry.get(key) == &value);
        _ = registry.remove(key);
    }
    try std.testing.expectEqual(1, registry.slots.items.len);
}

test "generation exhaustion retires a slot instead of aliasing a handle" {
    var registry: Registry(u32) = .{};
    defer registry.deinit(std.testing.allocator);
    var value: u32 = 0;
    const first = try registry.insert(std.testing.allocator, &value);
    registry.slots.items[first.index].generation = std.math.maxInt(u64);
    const exhausted: Key = .{ .index = first.index, .generation = std.math.maxInt(u64) };
    _ = registry.remove(exhausted);
    const next = try registry.insert(std.testing.allocator, &value);
    try std.testing.expect(next.index != first.index);
    try std.testing.expect(registry.get(exhausted) == null);
    _ = registry.remove(next);
}
