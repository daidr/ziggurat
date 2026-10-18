const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const b = ui.commands.brushes;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_patterns() u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;
const width = 96;
const height = 64;
const rectangle: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
const periodic = [_]b.Stop{
    .{ .offset = 0, .color = .rgb(0xff0000) },
    .{ .offset = 0.25, .color = .rgb(0x00ff00) },
    .{ .offset = 0.5, .color = .rgb(0x0000ff) },
    .{ .offset = 0.75, .color = .rgb(0xffffff) },
    .{ .offset = 1, .color = .rgb(0xff0000) },
};
const alpha = [_]b.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    .{ .offset = 1, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
};
const hard = [_]b.Stop{
    .{ .offset = 0, .color = .rgb(0xff0000) },
    .{ .offset = 0.5, .color = .rgb(0xff0000) },
    .{ .offset = 0.5, .color = .rgb(0x0000ff) },
    .{ .offset = 1, .color = .rgb(0xff0000) },
};
const steep = [_]b.Stop{
    .{ .offset = 0, .color = .rgb(0xff0000) },
    .{ .offset = 0.5, .color = .rgb(0xff0000) },
    .{ .offset = 0.500001, .color = .rgb(0x0000ff) },
    .{ .offset = 1, .color = .rgb(0xff0000) },
};
const seam = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
const invisible = [_]b.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 255, .a = 0 } } };
fn descriptor(index: usize) b.Gradient {
    return .{ .conic = .{
        .center = if (index == 6) .{ .x = 1e30, .y = -1e30 } else if (index == 1) .{ .x = 16.5, .y = 12.5 } else .{ .x = 48.5, .y = 32.5 },
        .start_angle_radians = if (index == 1) 0.25 else 0,
        .direction = if (index == 1) .counter_clockwise else .clockwise,
        .stops = switch (index) {
            2 => &alpha,
            3 => &hard,
            4 => &steep,
            5 => &seam,
            7 => &invisible,
            else => &periodic,
        },
    } };
}
// Independent oracle: acos + quadrant instead of production atan2; linear stop
// traversal and explicit channel arithmetic instead of the cached sampler.
fn oracle(gradient: b.Gradient, x: f64, y: f64) u32 {
    const value = gradient.conic;
    const dx = x - value.center.x;
    const dy = y - value.center.y;
    var t: f64 = 0;
    if (dx != 0 or dy != 0) {
        const angle = std.math.acos(std.math.clamp(dx / @sqrt(dx * dx + dy * dy), -1, 1));
        const signed = if (dy < 0) -angle else angle;
        const turn = (signed - value.start_angle_radians) / (2 * std.math.pi) * @as(f64, if (value.direction == .clockwise) 1 else -1);
        t = turn - @floor(turn);
        if (t >= 1) t = std.math.nextAfter(f64, 1, 0);
    }
    var lower: usize = 0;
    while (lower < value.stops.len and value.stops[lower].offset <= t) : (lower += 1) {}
    const a = value.stops[if (lower == 0) 0 else lower - 1];
    const next = value.stops[if (lower == value.stops.len) lower - 1 else lower];
    const weight: f64 = if (lower == 0 or lower == value.stops.len) 0 else (t - a.offset) / (@as(f64, next.offset) - a.offset);
    const aa = @as(f64, @floatFromInt(a.color.a)) / 255;
    const ba = @as(f64, @floatFromInt(next.color.a)) / 255;
    const out_alpha = aa + (ba - aa) * weight;
    var result: u32 = 0xff000000;
    for ([_]u8{ a.color.r, a.color.g, a.color.b }, [_]u8{ next.color.r, next.color.g, next.color.b }, [_]u5{ 16, 8, 0 }) |ac, bc, shift| {
        const av = @as(f64, @floatFromInt(ac)) * aa;
        const bv = @as(f64, @floatFromInt(bc)) * ba;
        result |= @as(u32, @intFromFloat(@round(std.math.clamp(av + (bv - av) * weight + 255 * (1 - out_alpha), 0, 255)))) << shift;
    }
    return result;
}
fn near(want: u32, actual: u32, label: []const u8, index: usize, scale: f32, x: u32, y: u32) !void {
    for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > 3) {
        std.debug.print("conic {s} case={d} scale={d} at={d},{d} expected={x} actual={x}\n", .{ label, index, scale, x, y, want, actual });
        return error.PixelMismatch;
    };
}
fn record(buffer: *ui.commands.Buffer, index: usize, clipped: bool) !void {
    buffer.reset();
    try buffer.fill(rectangle, 0xffffff);
    if (clipped) try buffer.pushClip(.{ .x = 12, .y = 8, .width = 64, .height = 40 });
    try buffer.gradientRect(rectangle, 0, descriptor(index));
    if (clipped) try buffer.popClip();
    try buffer.finish();
}
fn expected(index: usize, clipped: bool, scale: f32, x: u32, y: u32) u32 {
    const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
    const py = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
    if (clipped and (px < 12 or px >= 76 or py < 8 or py >= 48)) return 0xffffffff;
    return oracle(descriptor(index), px, py);
}
// Odd 1/64 outer coordinates, even 1/64 dimensions/stroke, and an odd
// radius avoid placing a sample exactly on a contour at 1/1.5/2 DPI.
const shaped: ui.Rect = .{ .x = 17.203125, .y = 11.296875, .width = 62.40625, .height = 40.21875 };
const shape_radius: f64 = 8.015625;
const shape_stroke: f64 = 4.03125;
fn recordShape(buffer: *ui.commands.Buffer, stroke: bool) !void {
    buffer.reset();
    try buffer.fill(rectangle, 0xffffff);
    try buffer.pushClip(.{ .x = 12, .y = 8, .width = 64, .height = 40 });
    if (stroke) try buffer.gradientStrokeRect(shaped, shape_radius, shape_stroke, descriptor(2)) else try buffer.gradientRect(shaped, shape_radius, descriptor(2));
    try buffer.popClip();
    try buffer.finish();
}
fn roundDistance(x: f64, y: f64, bounds: ui.Rect, radius: f64) f64 {
    const half_x = @as(f64, bounds.width) / 2;
    const half_y = @as(f64, bounds.height) / 2;
    const qx = @abs(x - bounds.x - half_x) - half_x + radius;
    const qy = @abs(y - bounds.y - half_y) - half_y + radius;
    return @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}
fn shapeExpected(stroke: bool, scale: f32, x: u32, y: u32) u32 {
    const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
    const py = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
    if (px < 12 or px >= 76 or py < 8 or py >= 48) return 0xffffffff;
    var covered: usize = 0;
    for (0..4) |sy| for (0..4) |sx| {
        const xx = px + (@as(f64, @floatFromInt(sx)) / 4 - 0.375) / scale;
        const yy = py + (@as(f64, @floatFromInt(sy)) / 4 - 0.375) / scale;
        const outer = roundDistance(xx, yy, shaped, shape_radius) <= 0;
        const inner = stroke and roundDistance(xx, yy, .{ .x = shaped.x + shape_stroke, .y = shaped.y + shape_stroke, .width = shaped.width - 2 * shape_stroke, .height = shaped.height - 2 * shape_stroke }, shape_radius - shape_stroke) < 0;
        covered += @intFromBool(outer and !inner);
    };
    const source = oracle(descriptor(2), px, py);
    var result: u32 = 0xff000000;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const v: f64 = @floatFromInt((source >> shift) & 255);
        result |= @as(u32, @intFromFloat(@round(255 + (v - 255) * @as(f64, @floatFromInt(covered)) / 16))) << shift;
    }
    return result;
}
fn software(context: *anyopaque, window: ?*anyopaque) !void {
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const w: u32 = @intFromFloat(width * scale);
        const h: u32 = @intFromFloat(height * scale);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } };
        try renderer.begin(paint);
        for (0..8) |index| for ([_]bool{ false, true }) |clipped| {
            try record(&buffer, index, clipped);
            try renderer.replayBuffer(&buffer);
            if (builtin.os.tag == .windows) _ = c.GdiFlush();
            for (0..h) |yi| for (0..w) |xi| {
                const x: u32 = @intCast(xi);
                const y: u32 = @intCast(yi);
                const actual = if (builtin.os.tag == .windows) renderer.pixels.?[yi * w + xi] else zlc_test_raw_pixel(renderer.native.?, x, y);
                // Window GDI's opaque DIB does not give meaning to fill's
                // unused high byte. Transparent offscreen checks retain RGBA.
                try near(expected(index, clipped, scale, x, y), actual | 0xff000000, "software", index, scale, x, y);
            };
        };
        for ([_]bool{ false, true }) |stroke| {
            try recordShape(&buffer, stroke);
            try renderer.replayBuffer(&buffer);
            if (builtin.os.tag == .windows) _ = c.GdiFlush();
            for (0..h) |y| for (0..w) |x| {
                const actual = if (builtin.os.tag == .windows) renderer.pixels.?[y * w + x] else zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
                try near(shapeExpected(stroke, scale, @intCast(x), @intCast(y)), actual | 0xff000000, "software round/stroke", @intFromBool(stroke), scale, @intCast(x), @intCast(y));
            };
        }
        try renderer.endChecked(paint);
    }
}
fn gpu(context: *anyopaque, window: *anyopaque, driver: ui.d3d11.Driver) !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var pixels: [width * height * 4]u32 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const w: u32 = @intFromFloat(width * scale);
        const h: u32 = @intFromFloat(height * scale);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } };
        for (0..8) |index| for ([_]bool{ false, true }) |clipped| {
            try record(&buffer, index, clipped);
            try renderer.begin(paint);
            const before = renderer.gradientStats();
            if (index >= 3 and index <= 6) {
                try std.testing.expectError(error.UnsupportedGradientPrecision, renderer.replayBuffer(&buffer));
                try std.testing.expectEqual(before.draws, renderer.gradientStats().draws);
                continue;
            }
            try renderer.replayBuffer(&buffer);
            try renderer.readPixelsForTest(w, h, pixels[0 .. w * h]);
            for (0..h) |yi| for (0..w) |xi| try near(expected(index, clipped, scale, @intCast(xi), @intCast(yi)), pixels[yi * w + xi] | 0xff000000, @tagName(driver), index, scale, @intCast(xi), @intCast(yi));
            renderer.end() catch |err| if (err != error.PresentationBusy) return err;
        };
        for ([_]bool{ false, true }) |stroke| {
            try recordShape(&buffer, stroke);
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try renderer.readPixelsForTest(w, h, pixels[0 .. w * h]);
            for (0..h) |y| for (0..w) |x| try near(shapeExpected(stroke, scale, @intCast(x), @intCast(y)), pixels[y * w + x] | 0xff000000, @tagName(driver), @intFromBool(stroke), scale, @intCast(x), @intCast(y));
            renderer.end() catch |err| if (err != error.PresentationBusy) return err;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), renderer.gradientStats().effect_creations);
    try std.testing.expectEqual(@as(u32, 24), renderer.gradientStats().draws);
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = width, .height = height, .scale = 1 } };
    try record(&buffer, 0, false);
    renderer.injectDeviceLoss();
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try std.testing.expectError(error.DeviceLost, renderer.end());
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try renderer.readPixelsForTest(width, height, pixels[0 .. width * height]);
    for (0..height) |y| for (0..width) |x| try near(expected(0, false, 1, @intCast(x), @intCast(y)), pixels[y * width + x] | 0xff000000, "restored", 0, 1, @intCast(x), @intCast(y));
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
    try std.testing.expectEqual(@as(u32, 2), renderer.gradientStats().effect_creations);
    try std.testing.expectEqual(@as(u32, 1), renderer.gradientStats().device_restores);
    renderer.deinit();
    try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
}
fn stageDescriptor() b.Gradient {
    return .{ .conic = .{ .center = .{ .x = 8.5, .y = 8.5 }, .stops = &periodic } };
}
fn stages(buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, scale: f32) !void {
    return stageVariant(buffer, table, scale, 3);
}
fn stageVariant(buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, scale: f32, mode: u2) !void {
    buffer.reset();
    table.scale = scale;
    try buffer.bindTransformStorage(table);
    const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 16, .height = 16 };
    try buffer.fill(bounds, 0xffffff);
    if (mode & 2 != 0) try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = 16 }, .{ .width = 16, .height = 16 }, scale));
    try buffer.pushClip(.{ .x = 2, .y = 2, .width = 12, .height = 12 });
    if (mode & 1 != 0) try buffer.beginGroup(bounds, .{ .opacity = 128 });
    try buffer.gradientRect(bounds, 0, stageDescriptor());
    if (mode & 1 != 0) try buffer.endGroup();
    try buffer.popClip();
    if (mode & 2 != 0) try buffer.endTransform();
    try buffer.finish();
}
fn stageExpected(scale: f32, x: u32, y: u32) u32 {
    // Reflection maps pixel centers to source pixel centers, so this independent
    // inverse needs no bilinear approximation at the three tested DPI values.
    const sx = 16 - (@as(f64, @floatFromInt(x)) + 0.5) / scale;
    const sy = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
    if (sx < 2 or sx >= 14 or sy < 2 or sy >= 14) return 0xffffffff;
    const source = oracle(stageDescriptor(), sx, sy);
    var result: u32 = 0xff000000;
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const channel = (source >> shift) & 255;
        result |= @as(u32, @intFromFloat(@round((@as(f64, @floatFromInt(channel)) * 128 + 255 * 127) / 255))) << shift;
    }
    return result;
}
fn checkStages(size: z.Size, pixels: []const u32, label: []const u8) !void {
    for (0..size.height) |y| for (0..size.width) |x| try near(stageExpected(size.scale, @intCast(x), @intCast(y)), pixels[y * size.width + x], label, 8, size.scale, @intCast(x), @intCast(y));
}
// Invert the narrowed public descriptor in f128 and interpolate independently
// generated source pixels. Parent matrices never enter the conic calculation.
fn affineExpected(scope: ui.layers.NativeTransform, scale: f32, x: usize, y: usize) u32 {
    const a: f128 = scope.xx;
    const b0: f128 = scope.xy;
    const c0: f128 = scope.yx;
    const d: f128 = scope.yy;
    const determinant = a * d - b0 * c0;
    const px = (@as(f128, @floatFromInt(x)) + 0.5) / scale - scope.x0;
    const py = (@as(f128, @floatFromInt(y)) + 0.5) / scale - scope.y0;
    const sx = (d * px - b0 * py) / determinant * scale - 0.5;
    const sy = (a * py - c0 * px) / determinant * scale - 0.5;
    const bx: i64 = @intFromFloat(@floor(sx));
    const by: i64 = @intFromFloat(@floor(sy));
    const fx = sx - @floor(sx);
    const fy = sy - @floor(sy);
    const side: i64 = @intFromFloat(16 * scale);
    var sums: [4]f128 = @splat(0);
    for (0..2) |iy| for (0..2) |ix| {
        const ax = bx + @as(i64, @intCast(ix));
        const ay = by + @as(i64, @intCast(iy));
        const p = if (ax >= 0 and ay >= 0 and ax < side and ay < side) oracle(stageDescriptor(), (@as(f64, @floatFromInt(ax)) + 0.5) / scale, (@as(f64, @floatFromInt(ay)) + 0.5) / scale) else 0;
        const weight = (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
        inline for (0..4) |channel| sums[channel] += @as(f128, @floatFromInt((p >> @as(u5, @intCast(channel * 8))) & 255)) * weight;
    };
    const alpha_value = @round(sums[3]) / 255;
    var result: u32 = 0xff000000;
    inline for (0..3) |channel| result |= @as(u32, @intFromFloat(@round(@round(sums[channel]) + 255 * (1 - alpha_value)))) << @as(u5, @intCast(channel * 8));
    return result;
}
fn affineSources(surface: anytype, buffer: *ui.commands.Buffer, table: *ui.commands.TransformStorage, size: z.Size, label: []const u8) !void {
    const matrices = [_]ui.affine.Affine{
        .{ .xy = 2, .x0 = -8 },
        .{ .xx = 1.0 / 4096.0, .yy = 1.0 / 4096.0, .x0 = 8.5 - 8.5 / 4096.0, .y0 = 8.5 - 8.5 / 4096.0 },
        .{ .x0 = 1000000, .y0 = -1000000 },
        .{ .xy = 65536, .x0 = -557056 },
        .{ .xx = 0, .yx = 1, .xy = -1, .yy = 0, .x0 = 16 },
        .{ .xx = 0.125, .yy = 0.125, .x0 = 7.4375, .y0 = 7.4375 },
        .{ .xx = 0.5, .yy = 0.5, .x0 = 4.25, .y0 = 4.25 },
    };
    for (matrices, 0..) |matrix, index| {
        buffer.reset();
        table.scale = size.scale;
        try buffer.bindTransformStorage(table);
        const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 16, .height = 16 };
        try buffer.fill(bounds, 0xffffff);
        const scope = try ui.layers.NativeTransform.init(matrix, .{ .width = 16, .height = 16 }, size.scale);
        try buffer.beginTransform(scope);
        try buffer.gradientRect(bounds, 0, stageDescriptor());
        try buffer.endTransform();
        try buffer.finish();
        var pixels: [32 * 32]u32 = undefined;
        if (@TypeOf(surface) == *ui.offscreen.Surface) {
            const image = try surface.render(buffer);
            defer image.close() catch unreachable;
            const level = (try image.view()).levels[0];
            for (0..size.height) |y| for (0..size.width) |x| {
                pixels[y * size.width + x] = std.mem.readInt(u32, level.pixels[y * level.stride + x * 4 ..][0..4], .little);
            };
        } else {
            if (index >= 1 and index <= 3) {
                const committed = (try surface.stats()).layers.committed_frames;
                var before: [32 * 32]u32 = undefined;
                try surface.readFrontForTest(before[0 .. size.width * size.height]);
                try std.testing.expectError(error.UnsupportedTransformPrecision, surface.render(buffer));
                try std.testing.expectEqual(committed, (try surface.stats()).layers.committed_frames);
                try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
                try std.testing.expectEqualSlices(u32, before[0 .. size.width * size.height], pixels[0 .. size.width * size.height]);
                continue;
            }
            try surface.render(buffer);
            try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
        }
        for (0..size.height) |y| for (0..size.width) |x| try near(affineExpected(scope, size.scale, x, y), pixels[y * size.width + x], label, index, size.scale, @intCast(x), @intCast(y));
    }
}
fn offscreenSoftware(app: *z.App, allocator: std.mem.Allocator) !void {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const size: z.Size = .{ .width = @intFromFloat(16 * scale), .height = @intFromFloat(16 * scale), .scale = scale };
        const surface = try ui.offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 4, .transform_source = .{ .width = 16, .height = 16 } });
        defer surface.close() catch unreachable;
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        var table: ui.commands.TransformStorage = .{};
        try stages(&buffer, &table, scale);
        const image = try surface.render(&buffer);
        defer image.close() catch unreachable;
        // Export owns its pixels and does not borrow a reused brush/command table.
        buffer.reset();
        const view = try image.view();
        const level = view.levels[0];
        var pixels: [32 * 32]u32 = undefined;
        for (0..size.height) |y| for (0..size.width) |x| {
            pixels[y * size.width + x] = std.mem.readInt(u32, level.pixels[y * level.stride + x * 4 ..][0..4], .little);
        };
        try checkStages(size, pixels[0 .. size.width * size.height], "software stages");
        try affineSources(surface, &buffer, &table, size, "software affine source");
    }
}
fn offscreenGpu(app: *z.App, allocator: std.mem.Allocator, driver: ui.gpu_resources.Driver) !void {
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const size: z.Size = .{ .width = @intFromFloat(16 * scale), .height = @intFromFloat(16 * scale), .scale = scale };
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const surface = try ui.gpu_offscreen.Surface.create(domain, failing.allocator(), .{ .size = size, .max_depth = 4, .transform_source = .{ .width = 16, .height = 16 }, .resident_bytes = 0 });
        defer surface.close() catch unreachable;
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        var table: ui.commands.TransformStorage = .{};
        if (scale == 1) for (0..4) |mode| {
            try stageVariant(&buffer, &table, scale, @intCast(mode));
            try surface.render(&buffer);
            var probe: [32 * 32]u32 = undefined;
            try surface.readFrontForTest(probe[0 .. size.width * size.height]);
            const x: usize = if (mode & 2 != 0) 7 else 8;
            try near(if (mode & 1 != 0) 0xffff7f7f else 0xffff0000, probe[8 * size.width + x], "exact offscreen center", mode, scale, @intCast(x), 8);
        };
        try stages(&buffer, &table, scale);
        try surface.render(&buffer);
        var pixels: [32 * 32]u32 = undefined;
        try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
        try checkStages(size, pixels[0 .. size.width * size.height], @tagName(driver));
        const warm = (try surface.stats()).layers.native_creations;
        const allocations = failing.alloc_index;
        failing.fail_index = allocations;
        for (0..8) |_| try surface.render(&buffer);
        try std.testing.expectEqual(allocations, failing.alloc_index);
        try std.testing.expectEqual(warm, (try surface.stats()).layers.native_creations);
        const committed = (try surface.stats()).layers.committed_frames;
        const before = pixels;
        buffer.reset();
        try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, 0, descriptor(3));
        try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(&buffer));
        try std.testing.expectEqual(committed, (try surface.stats()).layers.committed_frames);
        try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
        try std.testing.expectEqualSlices(u32, before[0 .. size.width * size.height], pixels[0 .. size.width * size.height]);
        try stages(&buffer, &table, scale);
        failing.fail_index = std.math.maxInt(usize);
        try surface.injectDeviceLossForTest();
        try std.testing.expectError(error.DeviceLost, surface.render(&buffer));
        try domain.recreate();
        try surface.render(&buffer);
        try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
        try checkStages(size, pixels[0 .. size.width * size.height], "restored stages");
        try affineSources(surface, &buffer, &table, size, @tagName(driver));
        // Precision eligibility applies to the complete buffer, independent of
        // its content. In particular a texture cannot pretend to be a CPU image.
        {
            const snapshot = try surface.snapshot();
            defer snapshot.close() catch unreachable;
            defer buffer.reset();
            const cpu = try ui.offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 4, .transform_source = .{ .width = 16, .height = 16 } });
            defer cpu.close() catch unreachable;
            for ([_]bool{ false, true }) |with_texture| {
                buffer.reset();
                table.scale = scale;
                try buffer.bindTransformStorage(&table);
                const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 16, .height = 16 };
                try buffer.fill(bounds, 0x00ff00);
                try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = 1.0 / 4096.0, .yy = 1.0 / 4096.0 }, .{ .width = 16, .height = 16 }, scale));
                if (with_texture) try buffer.texture(bounds, try snapshot.view(), .{}) else try buffer.fill(bounds, 0xff0000);
                try buffer.endTransform();
                try buffer.finish();
                const before_stats = try surface.stats();
                var before_pixels: [32 * 32]u32 = undefined;
                try surface.readFrontForTest(before_pixels[0 .. size.width * size.height]);
                try std.testing.expectError(error.UnsupportedTransformPrecision, surface.render(&buffer));
                const after_stats = try surface.stats();
                try std.testing.expectEqual(before_stats.renders, after_stats.renders);
                try std.testing.expectEqualDeep(before_stats.layers, after_stats.layers);
                try surface.readFrontForTest(pixels[0 .. size.width * size.height]);
                try std.testing.expectEqualSlices(u32, before_pixels[0 .. size.width * size.height], pixels[0 .. size.width * size.height]);
                if (with_texture) try std.testing.expectError(error.UnsupportedTextureBackend, cpu.render(&buffer));
            }
        }
    }
}
const Fallback = struct {
    index: usize = 0,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0xffffff);
        frame.gradientRect(rectangle, 0, descriptor(self.index));
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn contextFallback(app: *z.App, mode: ui.RenderMode) !void {
    var state: Fallback = .{};
    var context = ui.Context.init(&state, Fallback.draw, Fallback.action);
    context.render_mode = mode;
    const window = try app.createWindow(.{ .width = width, .height = height });
    try context.attach(window);
    try std.testing.expect(!context.gpu_unavailable);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), state.draws);
    try std.testing.expectEqual(@as(u64, 1), context.gpu_frames);
    const draws = context.gpu_renderer.gradientStats().draws;
    for (3..7) |index| {
        state.index = index;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(index - 1, state.draws);
        try std.testing.expectEqual(index - 2, context.gdi_frames);
        try std.testing.expectEqual(index - 2, context.fallbacks);
        // No earlier fill or analytic draw is replayed before the rejection.
        try std.testing.expectEqual(draws, context.gpu_renderer.gradientStats().draws);
        try std.testing.expectEqual(@as(u64, 1), context.gpu_frames);
        _ = c.GdiFlush();
        for ([_]u32{ 0, 16, 48, 95 }) |x| try near(expected(index, false, context.renderer.scale, x, 0), context.renderer.pixels.?[x] | 0xff000000, "Context fallback", index, context.renderer.scale, x, 0);
        try std.testing.expectEqual(@as(usize, 0), context.command_buffer.len);
    }
    state.index = 0;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 6), state.draws);
    try std.testing.expectEqual(@as(u64, 2), context.gpu_frames);
    _ = try window.destroy();
    try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
}
const TransformFallback = struct {
    rejected: bool = false,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0x00ff00);
        if (self.rejected) {
            frame.beginTransform(.{ .width = 16, .height = 16 }, .{ .xx = 1.0 / 4096.0, .yy = 1.0 / 4096.0, .x0 = 8.5 - 8.5 / 4096.0, .y0 = 8.5 - 8.5 / 4096.0 }) catch unreachable;
            frame.rect(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, 0xff0000);
            frame.endTransform() catch unreachable;
        }
    }
};
fn contextTransformFallback(app: *z.App, mode: ui.RenderMode) !void {
    var state: TransformFallback = .{};
    var context = ui.Context.init(&state, TransformFallback.draw, Fallback.action);
    context.render_mode = mode;
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    try context.attach(window);
    try context.prepareTransforms(std.heap.page_allocator, .{ .layers = .{ .size = try window.contentSize(), .max_depth = 2, .legacy_text = .disabled }, .source_size = .{ .width = 16, .height = 16 } });
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), state.draws);
    try std.testing.expectEqual(@as(u64, 1), context.gpu_frames);
    state.rejected = true;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), state.draws);
    try std.testing.expectEqual(@as(u64, 1), context.gdi_frames);
    try std.testing.expectEqual(@as(u64, 1), context.fallbacks);
    try std.testing.expectEqual(@as(u64, 1), context.gpu_frames);
    _ = c.GdiFlush();
    try std.testing.expectEqual(@as(u32, 0x00ff00), context.renderer.pixels.?[0] & 0xffffff);
    try std.testing.expectEqual(@as(usize, 0), context.command_buffer.len);
    state.rejected = false;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), state.draws);
    try std.testing.expectEqual(@as(u64, 2), context.gpu_frames);
}
pub fn run() !void {
    if (builtin.os.tag == .windows) {
        var diagnostics: z.diagnostics.Recorder(16) = .{};
        const app = try z.App.initWithOptions(std.heap.page_allocator, .{ .diagnostics_sink = diagnostics.sink() });
        defer app.deinit();
        const gui_baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
        const window = try app.createWindow(.{});
        {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            const dc = c.GetDC(hwnd) orelse return error.GetDCFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            try software(dc, hwnd);
            if (ui.capabilities.gpu) {
                try gpu(dc, hwnd.?, .hardware);
                try gpu(dc, hwnd.?, .warp);
            }
            try std.testing.expectEqual(baseline, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        }
        try offscreenSoftware(app, std.heap.page_allocator);
        if (ui.capabilities.gpu) {
            try offscreenGpu(app, std.heap.page_allocator, .hardware);
            try offscreenGpu(app, std.heap.page_allocator, .warp);
            try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
        }
        _ = try window.destroy();
        if (ui.capabilities.gpu) {
            try contextFallback(app, .hardware);
            try contextFallback(app, .warp);
            try contextTransformFallback(app, .hardware);
            try contextTransformFallback(app, .warp);
            var entries: [16]z.diagnostics.Diagnostic = undefined;
            const count = diagnostics.snapshot(&entries).count;
            try std.testing.expectEqual(@as(usize, 10), count);
            for (entries[0..count], 0..) |entry, index| {
                try std.testing.expectEqual(if (index < 8) error.UnsupportedGradientPrecision else error.UnsupportedTransformPrecision, entry.err.?);
                try std.testing.expectEqual(.renderer, entry.domain);
                try std.testing.expectEqual(null, entry.code);
            }
        }
        try std.testing.expectEqual(gui_baseline, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
    } else {
        const surface = cairo_image_surface_create(0, width * 2, height * 2) orelse return error.SurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.ContextFailed;
        defer cairo_destroy(context);
        try software(context, null);
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_patterns());
        const app = try z.App.init(std.heap.page_allocator);
        defer app.deinit();
        try offscreenSoftware(app, std.heap.page_allocator);
        try std.testing.expectEqual(@as(u32, 0), zlc_layer_live_objects());
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
    std.debug.print("conic: independent quadrant/acos oracle, premultiplied stops, software 48 cases and optional analytic GPU envelope passed\n", .{});
}
