const std = @import("std");
const images = @import("ziggurat_images");
const prepared = @import("ziggurat_image_drawing");
const drawing = prepared.drawing;
const fixture = @embedFile("image_fixture/colors.png");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
// Requests cancellation only after both preparation allocations succeed. This
// exercises rollback after acquiring storage, rather than only the entry check.
const CancelAllocator = struct {
    child: std.mem.Allocator,
    cancellation: *images.Cancellation,
    allocations: usize = 0,
    live_bytes: usize = 0,
    fn allocator(self: *CancelAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CancelAllocator = @ptrCast(@alignCast(ptr));
        const bytes = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.live_bytes += len;
        self.allocations += 1;
        if (self.allocations == 2) self.cancellation.request();
        return bytes;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CancelAllocator = @ptrCast(@alignCast(ptr));
        self.live_bytes -= bytes.len;
        self.child.rawFree(bytes, alignment, ret);
    }
};
const Job = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    result: ?*prepared.PreparedImage = null,
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.check() catch |err| {
            self.failure = err;
        };
    }
    fn allocate(allocator: std.mem.Allocator, image: *const images.Image) !void {
        const resource = try prepared.PreparedImage.create(allocator, image, .{});
        defer resource.close() catch unreachable;
    }
    fn check(self: *Job) !void {
        var worker = try images.Worker.init(self.main_thread);
        defer worker.deinit();
        try @import("image_prepare_lifetime.zig").run(self.allocator, &worker);
        const image = try worker.decode(self.allocator, fixture, .{});
        defer image.close() catch unreachable;
        const crop = try prepared.PreparedImage.create(self.allocator, image, .{ .source = .{ .x = 1, .width = 1, .height = 3 } });
        defer crop.close() catch unreachable;
        try equal(2, (try crop.stats()).levels);
        try expectError(error.NotAdopted, crop.view());
        try expectError(error.WrongThread, crop.adopt());
        try expectError(error.InvalidSourceRectangle, prepared.PreparedImage.create(self.allocator, image, .{ .source = .{ .x = 2, .width = 1, .height = 1 } }));
        try expectError(error.CapacityExceeded, prepared.PreparedImage.create(self.allocator, image, .{ .bytes = 1 }));
        var cancel: images.Cancellation = .{};
        cancel.request();
        try expectError(error.Cancelled, prepared.PreparedImage.create(self.allocator, image, .{ .cancellation = &cancel }));
        var after_allocation: images.Cancellation = .{};
        var cancelling: CancelAllocator = .{ .child = self.allocator, .cancellation = &after_allocation };
        try expectError(error.Cancelled, prepared.PreparedImage.create(cancelling.allocator(), image, .{ .cancellation = &after_allocation }));
        try equal(2, cancelling.allocations);
        try equal(0, cancelling.live_bytes);
        try std.testing.checkAllAllocationFailures(self.allocator, allocate, .{image});
        self.result = try prepared.PreparedImage.create(self.allocator, image, .{});
    }
};

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    try @import("image_prepare_lifetime.zig").handoff(debug.allocator());
    var job: Job = .{ .allocator = debug.allocator(), .main_thread = std.Thread.getCurrentId() };
    const worker = try std.Thread.spawn(.{}, Job.run, .{&job});
    worker.join();
    if (job.failure) |err| return err;
    const resource = job.result.?;
    defer resource.close() catch unreachable;
    try equal(0, images.nativeReferences());
    try expectError(error.WrongThread, resource.view());
    try resource.adopt();
    try expectError(error.AlreadyAdopted, resource.adopt());
    const view = try resource.view();
    try view.validate();
    try equal(2, view.levels.len);
    const base = view.levels[0];
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 128, 0, 128 }, base.pixels[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, base.pixels[8..12]);
    for (0..4) |channel| {
        var sum: u32 = 0;
        for (0..6) |i| sum += base.pixels[i * 4 + channel];
        try equal(@as(u8, @intCast((sum + 3) / 6)), view.levels[1].pixels[channel]);
    }
    try view.lease.acquire();
    try expectError(error.ResourceInUse, resource.close());
    view.lease.release();
    try expect(!try resource.inUse());
    const contain = try drawing.planImage(view, .{ .width = 60, .height = 60 }, .{ .fit = .contain }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 10), contain.destination.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), contain.destination.width, 0.001);
    const cover = try drawing.planImage(view, .{ .width = 60, .height = 60 }, .{ .fit = .cover }, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cover.source.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), cover.source.height, 0.001);
    const mip = try drawing.planImage(view, .{ .width = 0.5, .height = 0.5 }, .{ .sampling = .mip_linear }, 1);
    try equal(1, mip.level);
    try expectError(error.InvalidImageOptions, drawing.planImage(view, .{ .width = 1, .height = 1 }, .{ .alignment = .{ .x = std.math.nan(f32) } }, 1));
    std.debug.print("image prepare: real worker decode/crop/premultiply/area mips, cancellation/OOM, exclusive adopt/lease/fit/LOD passed\n", .{});
}
