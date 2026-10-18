//! Common CPU final composite. Parent coverage is absent from both passes.
const std = @import("std");
const drawing = @import("ziggurat_drawing_resources");
const layers = @import("layers.zig");
const scope = @import("gaussian_scope.zig");
const surface = @import("cpu_gradient.zig").Surface;
const composite = @import("composite.zig");
pub const Result = struct { bounds: [4]u32, visits: u64 };
pub fn draw(source: surface, destination: surface, capture: scope.Capture, group: layers.Group) !Result {
    if (source.width != capture.pixelWidth() or source.height != capture.pixelHeight() or source.scale != capture.scale or destination.scale != capture.scale or source.stride < source.width or destination.stride < destination.width or source.pixels == destination.pixels) return error.InvalidGaussianSurface;
    for (destination.origin) |origin| if (!std.math.isFinite(origin) or @floor(origin) != origin) return error.InvalidGaussianBounds;
    const origin = capture.origin();
    const left = @as(f64, @floatFromInt(capture.left)) - @as(f64, @floatFromInt(capture.radius)) + destination.origin[0];
    const top = @as(f64, @floatFromInt(capture.top)) - @as(f64, @floatFromInt(capture.radius)) + destination.origin[1];
    const region = [4]f64{ @max(left, destination.clip[0]), @max(top, destination.clip[1]), @min(left + @as(f64, @floatFromInt(source.width)), destination.clip[2]), @min(top + @as(f64, @floatFromInt(source.height)), destination.clip[3]) };
    const x0: u32 = @intFromFloat(std.math.clamp(@floor(region[0]), 0, @as(f64, @floatFromInt(destination.width))));
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(region[1]), 0, @as(f64, @floatFromInt(destination.height))));
    const x1: u32 = @intFromFloat(@max(@as(f64, @floatFromInt(x0)), @min(@ceil(region[2]), @as(f64, @floatFromInt(destination.width)))));
    const y1: u32 = @intFromFloat(@max(@as(f64, @floatFromInt(y0)), @min(@ceil(region[3]), @as(f64, @floatFromInt(destination.height)))));
    for (y0..y1) |y| for (x0..x1) |x| {
        const fx: f64 = @floatFromInt(x);
        const fy: f64 = @floatFromInt(y);
        const sx: usize = @intFromFloat(fx - destination.origin[0] + origin[0]);
        const sy: usize = @intFromFloat(fy - destination.origin[1] + origin[1]);
        var amount = @as(f64, @floatFromInt(group.opacity)) / 255 * @max(0, @min(fx + 1, region[2]) - @max(fx, region[0])) * @max(0, @min(fy + 1, region[3]) - @max(fy, region[1]));
        if (group.mask) |view| {
            amount *= composite.sample(view.coverage, fx - destination.origin[0] - @as(f64, group.mask_origin.x) * capture.scale - @as(f64, @floatFromInt(view.coverage.origin_x)), fy - destination.origin[1] - @as(f64, group.mask_origin.y) * capture.scale - @as(f64, @floatFromInt(view.coverage.origin_y))) / 255;
        }
        const at = y * destination.stride + x;
        destination.pixels[at] = composite.over(source.pixels[sy * source.stride + sx], destination.pixels[at], amount);
    };
    return .{ .bounds = .{ x0, y0, x1, y1 }, .visits = @as(u64, x1 - x0) * (y1 - y0) };
}

test "Gaussian parent clip opacity and mask apply once after outside-parent influence" {
    const kernel = try @import("gaussian_kernel.zig").Kernel.prepare(.{ .sigma = 0.5 });
    const capture = try scope.Capture.init(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, &kernel);
    var source = [_]u32{0} ** 36;
    var scratch = [_]u32{0} ** 36;
    source[2 * 6 + 2] = 0x80800000;
    var visits: u64 = 0;
    try @import("gaussian_kernel.zig").apply(&kernel, .{ .pixels = &source, .width = 6, .height = 6, .stride = 6 }, .{ .pixels = &scratch, .width = 6, .height = 6, .stride = 6 }, .{ .pixels = &source, .width = 6, .height = 6, .stride = 6 }, 360, null, &visits);
    var destination = [_]u32{0xffffffff} ** 16;
    const result = try draw(.{ .pixels = &source, .width = 6, .height = 6, .stride = 6, .scale = 1, .origin = capture.origin(), .clip = .{ 0, 0, 6, 6 } }, .{ .pixels = &destination, .width = 4, .height = 4, .stride = 4, .scale = 1, .clip = .{ 1.25, 0, 2, 2 } }, capture, .{ .opacity = 128 });
    try std.testing.expectEqualDeep([4]u32{ 1, 0, 2, 2 }, result.bounds);
    try std.testing.expectEqual(composite.over(source[2 * 6 + 3], 0xffffffff, @as(f64, 128) / 255 * 0.75), destination[1]);
    try std.testing.expect(destination[1] != 0xffffffff);
    try std.testing.expectEqual(@as(u32, 0xffffffff), destination[0]);
}
