const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
extern fn zlg_accessibility_host_available(*anyopaque) c_int;
extern fn zlg_resource_count() u32;

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    {
        defer app.deinit();
        const plain = try app.createWindow(.{});
        if (builtin.os.tag == .linux) {
            try std.testing.expectEqual(@as(c_int, 0), zlg_accessibility_host_available(app.windows.get(plain.key).?.native.native.?));
            const selected = try app.createWindow(.{ .accessibility_host = .children });
            try std.testing.expectEqual(@as(c_int, 1), zlg_accessibility_host_available(app.windows.get(selected.key).?.native.native.?));
            _ = try selected.destroy();
        } else {
            const before = app.resourceStats();
            const unreadable: [*]const u8 = @ptrFromInt(4096);
            try std.testing.expectError(error.UnsupportedCapability, app.createWindow(.{ .accessibility_host = .children, .title = unreadable[0..1] }));
            try std.testing.expectEqualDeep(before, app.resourceStats());
        }
        _ = try plain.destroy();
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().live_windows);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("accessibility host construction: default plain area, explicit native capability, close records/resources=0; generic host only\n", .{});
}
