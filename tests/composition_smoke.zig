const std = @import("std");
const z = @import("ziggurat");
const c = z.composition;
const Probe = struct {
    attaches: usize = 0,
    updates: usize = 0,
    detaches: usize = 0,
    fn attach(context: *anyopaque, region: c.Region) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        const snapshot = try region.snapshot();
        try std.testing.expect(std.math.isFinite(snapshot.size.scale) and snapshot.size.scale > 0);
        try std.testing.expect(snapshot.window.nativeHandle() != null);
        self.attaches += 1;
    }
    fn update(context: *anyopaque, region: c.Region, viewport: c.Viewport) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        try std.testing.expect(!std.meta.eql((try region.snapshot()).viewport, viewport));
        self.updates += 1;
    }
    fn detach(context: *anyopaque, region: c.Region) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        std.testing.expectError(error.Closed, region.snapshot()) catch unreachable;
        self.detaches += 1;
    }
    fn participant(self: *Probe) c.Participant {
        return .{ .context = self, .attach = attach, .update = update, .detach = detach };
    }
};

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    const app = try z.App.init(allocations.allocator());
    defer app.deinit();
    var probe: Probe = .{};
    for (0..10) |_| {
        const window = try app.createWindow(.{ .width = 640, .height = 480 });
        var failing = std.testing.FailingAllocator.init(allocations.allocator(), .{});
        const owner = try c.Owner.create(failing.allocator(), window, .{ .capacity = 2 });
        defer owner.close() catch unreachable;
        failing.fail_index = failing.alloc_index;
        const allocation_count = failing.alloc_index;
        const viewport: c.Viewport = .{ .bounds = .{ .x = 20, .y = 30, .width = 200, .height = 100 } };
        var stale: ?c.Region = null;
        for (0..100) |_| {
            const region = try owner.reserve(viewport);
            if (stale) |old| {
                try std.testing.expectEqual(old.index, region.index);
                try std.testing.expect(old.generation != region.generation);
                try std.testing.expect(old.beginCallback() == null);
                try std.testing.expectError(error.Closed, old.update(viewport));
            }
            try region.attach(probe.participant());
            var changed = viewport;
            changed.bounds.x = 21;
            try region.update(changed);
            try region.update(changed);
            const scope = region.beginCallback().?;
            const count = probe.detaches;
            try std.testing.expect(try region.remove());
            try std.testing.expect(region.beginCallback() == null);
            try std.testing.expectEqual(count, probe.detaches);
            scope.end();
            try std.testing.expectEqual(count + 1, probe.detaches);
            stale = region;
        }
        const final = try owner.reserve(viewport);
        try final.attach(probe.participant());
        const scope = final.beginCallback().?;
        const count = probe.detaches;
        _ = try window.destroy();
        try std.testing.expect(final.beginCallback() == null);
        try std.testing.expectEqual(count, probe.detaches);
        scope.end();
        try app.dispatch();
        try std.testing.expectEqual(count + 1, probe.detaches);
        try std.testing.expectEqual(allocation_count, failing.alloc_index);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
    try std.testing.expectEqual(@as(usize, 1010), probe.attaches);
    try std.testing.expectEqual(@as(usize, 1000), probe.updates);
    try std.testing.expectEqual(probe.attaches, probe.detaches);
    std.debug.print("composition: 1000 region reuse/update/remove cycles without owner allocation, 10 pinned native closes; attaches={d} updates={d} detaches={d}, records=0\n", .{ probe.attaches, probe.updates, probe.detaches });
}
