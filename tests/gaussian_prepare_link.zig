const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
pub fn main() !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    const gpu = try ui.gpu_offscreen.Surface.createGaussian(domain, std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4, .scale = 1 } }, .{ .source_size = .{ .width = 4, .height = 4 }, .max_radius = 3 });
    defer gpu.close() catch unreachable;
}
