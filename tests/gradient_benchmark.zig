const std = @import("std");
const zio = @import("ziggurat_io");
const ui = @import("ziggurat_ui");
const z = @import("ziggurat");
const brushes = ui.commands.brushes;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zbench_gradient_create(u32, u32, f32) ?*anyopaque;
extern fn zbench_gradient_destroy(*anyopaque) void;
extern fn zbench_gradient_draw(*anyopaque, f32, f32, f32, f32, f32, f32, *const brushes.Native) c_int;
const samples = 7;
const iterations = 3;
fn median(values: *[samples]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[samples / 2];
}
fn run(name: []const u8, value: brushes.Gradient, scale: f32) !void {
    const width: u32 = @intFromFloat(1280 * scale);
    const height: u32 = @intFromFloat(720 * scale);
    const surface = cairo_image_surface_create(0, @intCast(width), @intCast(height)) orelse return error.SurfaceFailed;
    defer cairo_surface_destroy(surface);
    const context = cairo_create(surface) orelse return error.ContextFailed;
    defer cairo_destroy(context);
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    const paint: z.Paint = .{ .native_context = context, .size = .{ .width = width, .height = height, .scale = scale } };
    try renderer.begin(paint);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 1280, .height = 720 }, 0, value);
    const stored = try brushes.Stored.init(value);
    const native = stored.native();
    const previous = zbench_gradient_create(width, height, scale) orelse return error.SurfaceFailed;
    defer zbench_gradient_destroy(previous);
    for (0..2) |_| {
        try renderer.replayBuffer(&buffer);
        if (zbench_gradient_draw(previous, 0, 0, 1280, 720, 0, 0, &native) != 0) return error.NativeDrawFailed;
    }
    var cpu_samples: [samples]u64 = undefined;
    var native_samples: [samples]u64 = undefined;
    for (0..samples) |index| {
        var timer = try zio.Timer.start();
        for (0..iterations) |_| try renderer.replayBuffer(&buffer);
        cpu_samples[index] = timer.read() / iterations;
        timer.reset();
        for (0..iterations) |_| if (zbench_gradient_draw(previous, 0, 0, 1280, 720, 0, 0, &native) != 0) return error.NativeDrawFailed;
        native_samples[index] = timer.read() / iterations;
    }
    const cpu = median(&cpu_samples);
    const previous_ns = median(&native_samples);
    std.debug.print("{{\"schema\":1,\"case\":\"{s}\",\"scale\":{d},\"physical_width\":{d},\"physical_height\":{d},\"pixels_per_draw\":{d},\"stops\":{d},\"samples\":{d},\"frames_per_sample\":{d},\"analytic_cpu_median_ns\":{d},\"previous_native_median_ns\":{d},\"ratio\":{d:.3},\"warm_replay\":true,\"display_latency\":false}}\n", .{ name, scale, width, height, @as(u64, width) * height, stored.len, samples, iterations, cpu, previous_ns, @as(f64, @floatFromInt(cpu)) / @as(f64, @floatFromInt(previous_ns)) });
}
pub fn main() !void {
    const two = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    var full: [16]brushes.Stop = undefined;
    for (&full, 0..) |*stop, index| stop.* = .{ .offset = @as(f32, @floatFromInt(index)) / 15, .color = .{ .r = @intCast(index * 17), .g = @intCast(255 - index * 17), .b = 128, .a = 255 } };
    const alpha = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    for ([_]f32{ 1, 2 }) |scale| {
        try run("linear-2", .{ .linear = .{ .start = .{}, .end = .{ .x = 1280 }, .stops = &two } }, scale);
        try run("linear-16", .{ .linear = .{ .start = .{}, .end = .{ .x = 1280 }, .stops = &full } }, scale);
        try run("vertical-2", .{ .linear = .{ .start = .{}, .end = .{ .y = 720 }, .stops = &two } }, scale);
        try run("diagonal-opaque", .{ .linear = .{ .start = .{}, .end = .{ .x = 1280, .y = 720 }, .stops = &two } }, scale);
        try run("diagonal-alpha", .{ .linear = .{ .start = .{}, .end = .{ .x = 1280, .y = 720 }, .stops = &alpha } }, scale);
        try run("radial-alpha", .{ .radial = .{ .center = .{ .x = 640, .y = 360 }, .radius = .{ .x = 640, .y = 360 }, .stops = &alpha } }, scale);
    }
}
