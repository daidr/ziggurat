const std = @import("std");
const zio = @import("ziggurat_io");
const sampler = @import("sampler");
const Matrix = @typeInfo(@TypeOf(sampler.draw)).@"fn".params[2].type.?;
const Surface = extern struct { pixels: [*]u32, width: u32, height: u32, stride: u32, scale: f32, clip: [4]f64, origin: [2]f64 };
const Transform = extern struct { xx: f64 = 1, yx: f64 = 0, xy: f64 = 0, yy: f64 = 1, x0: f64 = 0, y0: f64 = 0, source_width: f32, source_height: f32, pixel_width: u32, pixel_height: u32 };
extern fn bench_create(u32, u32, f32) ?*anyopaque;
extern fn bench_begin(*anyopaque, *const Transform, u32, u32) c_int;
extern fn bench_flush(*anyopaque) c_int;
extern fn bench_old_end(*anyopaque) c_int;
extern fn bench_counts(*anyopaque, *u64, *u32) void;
extern fn bench_drop(*anyopaque) u32;
extern fn zlc_layer_transform_planes(*anyopaque, *Surface, *Surface, *Transform) c_int;
extern fn zlc_layer_finish_transform(*anyopaque, u64, u32, u32, u32, u32) c_int;
const max_samples = 101;
const Case = enum { identity, integer, quarter, halfscale, double, oblique, shear2 };
const Options = struct { pilot: bool = false, matrix: ?Case = null, samples: usize = 21, warmup: usize = 4 };
const Metrics = struct { old: [max_samples]u64 = undefined, flush: [max_samples]u64 = undefined, borrow: [max_samples]u64 = undefined, draw: [max_samples]u64 = undefined, finish: [max_samples]u64 = undefined, total: [max_samples]u64 = undefined };
fn quantile(a: []const u64, index: usize) u64 {
    var b: [max_samples]u64 = undefined;
    @memcpy(b[0..a.len], a);
    std.mem.sort(u64, b[0..a.len], {}, std.sort.asc(u64));
    return b[index];
}
fn usage() void {
    std.debug.print(
        \\benchmark-affine-cairo [--pilot] [--matrix NAME] [--samples 3..101] [--warmup 0..64]
        \\Default: 378 cases, 4 warmup pairs and 21 measured pairs per case.
        \\--pilot: 640x360 physical pixels, scale 1, depth 1, both source alphas.
        \\NAME: identity, integer, quarter, halfscale, double, oblique, shear2.
        \\Times are nanoseconds. Construction and source preparation are excluded.
        \\This test-only native baseline is never used by the runtime renderer.
        \\
    , .{});
}
fn options() !?Options {
    var args = try init.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    var result: Options = .{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return null;
        } else if (std.mem.eql(u8, arg, "--pilot")) {
            result.pilot = true;
        } else if (std.mem.eql(u8, arg, "--matrix")) {
            result.matrix = std.meta.stringToEnum(Case, args.next() orelse return error.MissingArgument) orelse return error.InvalidMatrix;
        } else if (std.mem.eql(u8, arg, "--samples")) {
            result.samples = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
            if (result.samples < 3 or result.samples > max_samples) return error.InvalidSamples;
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            result.warmup = try std.fmt.parseInt(usize, args.next() orelse return error.MissingArgument, 10);
            if (result.warmup > 64) return error.InvalidWarmup;
        } else return error.UnknownArgument;
    }
    return result;
}
pub fn main(init: std.process.Init.Minimal) !void {
    const config = (options() catch |err| {
        usage();
        return err;
    }) orelse return;
    const cases = [_]struct { name: Case, m: Matrix }{
        .{ .name = .identity, .m = .{} },                        .{ .name = .integer, .m = .{ .x0 = 8, .y0 = 4 } },
        .{ .name = .quarter, .m = .{ .x0 = 0.25, .y0 = 0.25 } }, .{ .name = .halfscale, .m = .{ .xx = 0.5, .yy = 0.5 } },
        .{ .name = .double, .m = .{ .xx = 2, .yy = 2 } },        .{ .name = .oblique, .m = .{ .xx = 0.8, .xy = 0.25, .yy = 1.1, .x0 = 1.2, .y0 = 0.7 } },
        .{ .name = .shear2, .m = .{ .xy = 2, .x0 = -8 } },
    };
    const full_sizes = [_][2]u32{ .{ 64, 64 }, .{ 512, 512 }, .{ 1920, 1080 } };
    const pilot_sizes = [_][2]u32{.{ 640, 360 }};
    const sizes: []const [2]u32 = if (config.pilot) &pilot_sizes else &full_sizes;
    const scales: []const f32 = if (config.pilot) &.{1} else &.{ 1, 1.5, 2 };
    const depths: []const u32 = if (config.pilot) &.{1} else &.{ 1, 2, 4 };
    const median = config.samples / 2;
    const p95 = (config.samples * 95 + 99) / 100 - 1;
    std.debug.print("samples={d} warmup={d} pilot={} display_latency=false\n", .{ config.samples, config.warmup, config.pilot });
    var timer = try zio.Timer.start();
    for (sizes) |size| for (scales) |scale| for (cases) |case| for (depths) |depth| for ([_]u32{ 255, 128 }) |alpha| {
        if (config.matrix) |selected| if (case.name != selected) continue;
        const renderer = bench_create(size[0], size[1], scale) orelse return error.Create;
        var renderer_open = true;
        defer {
            if (renderer_open) _ = bench_drop(renderer);
        }
        var value: Transform = .{ .xx = case.m.xx, .xy = case.m.xy, .yx = case.m.yx, .yy = case.m.yy, .x0 = case.m.x0, .y0 = case.m.y0, .source_width = @as(f32, @floatFromInt(size[0])) / scale, .source_height = @as(f32, @floatFromInt(size[1])) / scale, .pixel_width = size[0], .pixel_height = size[1] };
        inline for (.{ "xx", "xy", "yx", "yy", "x0", "y0" }) |field| @field(value, field) = @as(f32, @floatCast(@field(value, field)));
        value.pixel_width = @intFromFloat(@ceil(@as(f64, value.source_width) * scale));
        value.pixel_height = @intFromFloat(@ceil(@as(f64, value.source_height) * scale));
        var metrics: Metrics = .{};
        var visits: u64 = 0;
        var creations: u64 = 0;
        var objects: u32 = 0;
        bench_counts(renderer, &creations, &objects);
        for (0..config.samples + config.warmup) |iteration| {
            if (bench_begin(renderer, &value, depth, alpha) != 0) return error.Begin;
            timer.reset();
            for (0..depth) |_| if (bench_old_end(renderer) != 0) return error.Native;
            const old_ns = timer.read();
            if (bench_begin(renderer, &value, depth, alpha) != 0) return error.Begin;
            var flush_ns: u64 = 0;
            var borrow_ns: u64 = 0;
            var draw_ns: u64 = 0;
            var finish_ns: u64 = 0;
            visits = 0;
            for (0..depth) |_| {
                timer.reset();
                if (bench_flush(renderer) != 0) return error.Flush;
                flush_ns += timer.read();
                var src: Surface = undefined;
                var dst: Surface = undefined;
                var descriptor: Transform = undefined;
                timer.reset();
                if (zlc_layer_transform_planes(renderer, &src, &dst, &descriptor) != 0) return error.Borrow;
                borrow_ns += timer.read();
                timer.reset();
                const result = try sampler.drawWithBounds(.{ .pixels = src.pixels, .width = src.width, .height = src.height, .stride = src.stride }, .{ .pixels = dst.pixels, .width = dst.width, .height = dst.height, .stride = dst.stride }, .{ .xx = descriptor.xx, .xy = descriptor.xy, .yx = descriptor.yx, .yy = descriptor.yy, .x0 = descriptor.x0, .y0 = descriptor.y0 }, dst.scale, dst.origin, dst.clip);
                draw_ns += timer.read();
                visits += result.visits;
                const box = result.bounds;
                timer.reset();
                if (zlc_layer_finish_transform(renderer, result.visits, box[0], box[1], box[2] - box[0], box[3] - box[1]) != 0) return error.Finish;
                finish_ns += timer.read();
            }
            if (iteration >= config.warmup) {
                const i = iteration - config.warmup;
                metrics.old[i] = old_ns;
                metrics.flush[i] = flush_ns;
                metrics.borrow[i] = borrow_ns;
                metrics.draw[i] = draw_ns;
                metrics.finish[i] = finish_ns;
                metrics.total[i] = flush_ns + borrow_ns + draw_ns + finish_ns;
            }
        }
        var final_creations: u64 = 0;
        var final_objects: u32 = 0;
        bench_counts(renderer, &final_creations, &final_objects);
        if (creations != final_creations or objects != final_objects) return error.HotCreation;
        renderer_open = false;
        if (bench_drop(renderer) != 0) return error.Leak;
        const cpu_ns = quantile(metrics.total[0..config.samples], median);
        const native_ns = quantile(metrics.old[0..config.samples], median);
        std.debug.print("size={d}x{d} dpi={d} matrix={s} depth={d} alpha={d} visits={d} native_median={d} native_p95={d} cpu_median={d} cpu_p95={d} flush={d} borrow={d} draw={d} finish={d} ratio={d:.2} resources=0 hot_creations=0\n", .{ size[0], size[1], scale, @tagName(case.name), depth, alpha, visits, native_ns, quantile(metrics.old[0..config.samples], p95), cpu_ns, quantile(metrics.total[0..config.samples], p95), quantile(metrics.flush[0..config.samples], median), quantile(metrics.borrow[0..config.samples], median), quantile(metrics.draw[0..config.samples], median), quantile(metrics.finish[0..config.samples], median), @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(native_ns)) });
    };
}
