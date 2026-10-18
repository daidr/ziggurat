const std = @import("std");
const svg = @import("root.zig");
const v = @import("ziggurat_vector");
const Mock = @import("text_adjust_test.zig").Mock;
const Mode = @TypeOf((svg.PrepareOptions{ .main_thread = 0, .width = 1, .height = 1 }).compositing);
const Tracker = struct {
    const Allocation = struct { bytes: [*]u8, live: bool = true };
    child: std.mem.Allocator,
    allocations: [1024]Allocation = undefined,
    count: usize = 0,
    freed: [1024]usize = undefined,
    frees: usize = 0,
    cancel_on: ?usize = null,
    cancellation: v.Cancellation = .{},
    fn allocator(self: *Tracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Tracker = @ptrCast(@alignCast(context));
        const bytes = self.child.rawAlloc(len, alignment, ret) orelse return null;
        std.debug.assert(self.count < self.allocations.len);
        self.allocations[self.count] = .{ .bytes = bytes };
        self.count += 1;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Tracker = @ptrCast(@alignCast(context));
        for (self.allocations[0..self.count], 0..) |*allocation, i| if (allocation.live and allocation.bytes == bytes.ptr) {
            allocation.live = false;
            self.freed[self.frees] = i;
            self.frees += 1;
            if (self.cancel_on) |target| if (target == i) {
                self.cancellation.request();
            };
            self.child.rawFree(bytes, alignment, ret);
            return;
        };
        unreachable;
    }
    fn empty(self: *const Tracker) !void {
        for (self.allocations[0..self.count]) |value| try std.testing.expect(!value.live);
    }
};
test "last foreign scene scratch release still cancels before Prepared publication" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "<svg><style>text{fill:blue}</style><text x='4' y='12' rotate='20'>fiX</text></svg>",
        "<svg><style>text{fill:blue}</style><text x='4' y='12' rotate='20' textLength='20'>fiX</text></svg>",
        "<svg><defs><path id='p' d='M4 12H9V22'/></defs><text fill='red'><textPath href='#p'>fi<tspan fill='blue'>X</tspan></textPath></text></svg>",
        "<svg><defs><pattern id='p' patternUnits='userSpaceOnUse' x='.5' width='16' height='24'><rect width='16' height='24' fill='red'/></pattern></defs><rect width='32' height='24' fill='url(#p)'/></svg>",
        @import("pattern_test.zig").expanded_source,
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 12H24' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs><marker id='m' markerWidth='2' markerHeight='2' refX='1' refY='1'><rect width='2' height='2' fill='red'/></marker></defs><path d='M8 12H20' fill='none' stroke-width='2' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 12H12V20H20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><polygon points='8,8 24,8 24,16 8,16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8Q24 8 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8C8 8 24 8 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8A16 8 0 0 1 24 16' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4' fill='none' marker-mid='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 4Q12 0 12 8C12 16 16 16 24 16A8 8 0 0 1 28 20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 8H12Q12 16 20 16H28' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 4Q12 0 12 8C12 16 16 16 24 16H28' fill='none' marker-mid='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8C16 8 24 8 24 16H8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8H24V16Q16 24 8 16Z' fill='none' marker-mid='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12A8 8 0 0 1 12 20H4C0 20 0 4 4 4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M20 4C28 4 4 20 4 12A8 8 0 0 1 12 4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 12H12H12H12V20' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 12H12H12H12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 12C20 12 12 4 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 12A4 4 0 0 1 16 12A4 4 0 0 1 8 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 20H2V8H12H12H12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 12H12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M4 8Q12 8 12 16Q12 16 12 16C12 16 12 16 12 16Q12 16 20 16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 12C12 12 12 12 12 12' fill='none' marker-start='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 20C2 20 2 8 12 8Q12 8 12 8C12 8 12 8 12 8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 8H12C20 8 12 0 12 8Q12 8 12 8Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 12Q12 12 12 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12H28' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4H12A8 8 0 0 1 20 12C20 12 20 12 20 12' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12H20A8 8 0 0 1 12 20C12 20 12 20 12 20H4' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 0A8 8 0 0 1 20 8Q20 8 20 8H4Q4 8 4 8V0Q4 0 4 0Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M20 12A8 8 0 0 1 4 12Q4 12 4 12A8 8 0 0 1 20 12C20 12 20 12 20 12Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4Q12 4 12 4A8 8 0 0 1 20 12H4Z' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8H16A7 7 0 0 1 16 8V16' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M12 4A8 8 0 0 1 20 12Q20 12 20 12A7 7 0 0 1 20 12H28' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        "<svg><defs>" ++ @import("marker_test.zig").definition ++ "</defs><path d='M8 8Q8 8 8 8A7 7 0 0 1 8 8C8 8 8 8 8 8' fill='none' marker-start='url(#m)' marker-mid='url(#m)' marker-end='url(#m)'/></svg>",
        @import("marker_test.zig").unified_source,
        @import("marker_test.zig").host_unit_positive,
    }) |source| {
        const document = try svg.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        for ([_]Mode{ .pixel, .sample_color }) |mode| {
            var baseline: Tracker = .{ .child = allocator };
            var provider: Mock = .{};
            var options: svg.PrepareOptions = .{ .main_thread = std.Thread.getCurrentId(), .width = 32, .height = 24, .text_provider = provider.provider(), .compositing = mode };
            const output = try document.prepare(baseline.allocator(), options);
            const scratch_frees = baseline.frees;
            try std.testing.expect(scratch_frees > 0);
            try output.close();
            try baseline.empty();
            // The final one proves the old late-defer hole; earlier ones cover
            // mapping metadata/path/quads and temporary scene cleanup separately.
            for (baseline.freed[0..scratch_frees]) |target| {
                provider = .{};
                var trial: Tracker = .{ .child = allocator, .cancel_on = target };
                options.cancellation = &trial.cancellation;
                if (document.prepare(trial.allocator(), options)) |unexpected| {
                    try unexpected.close();
                    return error.CancellationIgnoredAfterSceneScratchFree;
                } else |err| try std.testing.expectEqual(error.Cancelled, err);
                try std.testing.expect(trial.cancellation.requested.load(.acquire));
                try trial.empty();
            }
        }
    }
}
