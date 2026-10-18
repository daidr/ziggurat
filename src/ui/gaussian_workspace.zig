const std = @import("std");
const kernel = @import("gaussian_kernel.zig");
const scope = @import("gaussian_scope.zig");
const layers = @import("layers.zig");
pub const Frame = struct { capture: scope.Capture, kernel: kernel.Kernel };
/// Optional native layer payload. No kernel pointer survives beginGaussian.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    capacity: scope.Capacity,
    scratch: []u32,
    frames: [layers.max_depth]Frame = undefined,
    active: u8 = 0,
    visits: u64 = 0,
    pub fn create(allocator: std.mem.Allocator, plan: scope.Plan) !*Owner {
        const result = try allocator.create(Owner);
        errdefer allocator.destroy(result);
        const scratch = try allocator.alloc(u32, plan.scratch_bytes / 4);
        result.* = .{ .allocator = allocator, .capacity = plan.capacity, .scratch = scratch };
        return result;
    }
    pub fn close(self: *Owner) void {
        const allocator = self.allocator;
        const scratch = self.scratch;
        allocator.free(scratch);
        allocator.destroy(self);
    }
    pub fn begin(self: *Owner, depth: usize, capture: scope.Capture, value: *const kernel.Kernel) !void {
        try capture.check(self.capacity);
        const visits = std.math.add(u64, self.visits, capture.samples()) catch return error.GaussianWorkExceeded;
        if (visits > self.capacity.filter_samples) return error.GaussianWorkExceeded;
        self.frames[depth] = .{ .capture = capture, .kernel = value.* };
        self.visits = visits;
        self.active |= @as(u8, 1) << @intCast(depth);
    }
};
