const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const b = ui.commands.brushes;
const oracle = @import("gradient_interpolation_oracle.zig");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;
const width = 32;
const height = 20;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
const background: u32 = 0xff183048;
const colors = [_]b.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 192, .a = 0 } },
    .{ .offset = 0.25, .color = .{ .r = 16, .g = 240, .b = 48, .a = 192 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    .{ .offset = 0.5, .color = .{ .r = 255, .g = 0, .b = 0, .a = 224 } },
    .{ .offset = 1, .color = .{ .r = 32, .g = 64, .b = 255, .a = 255 } },
};
fn descriptor(spread: b.Spread, space: b.InterpolationSpace, kind: usize) b.Gradient {
    return if (kind == 0)
        .{ .linear = .{ .start = .{ .x = 12, .y = 7 }, .end = .{ .x = 18, .y = 11 }, .stops = &colors, .interpolation = space, .spread = spread } }
    else
        .{ .radial = .{ .center = .{ .x = 14.5, .y = 9.5 }, .radius = .{ .x = 6, .y = 3 }, .stops = &colors, .interpolation = space, .spread = spread } };
}
fn parameter(kind: usize, x: f128, y: f128, spread: b.Spread) f64 {
    const t: f128 = if (kind == 0)
        ((@as(f128, x) - 12) * 6 + (@as(f128, y) - 7) * 4) / 52
    else
        @sqrt(((@as(f128, x) - 14.5) / 6) * ((@as(f128, x) - 14.5) / 6) + ((@as(f128, y) - 9.5) / 3) * ((@as(f128, y) - 9.5) / 3));
    if (spread == .pad) return @floatCast(t);
    const cycle = @mod(t, if (spread == .repeat) @as(f128, 1) else 2);
    return @floatCast(if (spread == .reflect and cycle > 1) 2 - cycle else cycle);
}
fn inside(x: f64, y: f64, rect: ui.Rect, radius: f64, interior: bool) bool {
    const dx = @max(0, @abs(x - rect.x - @as(f64, rect.width) / 2) - @as(f64, rect.width) / 2 + radius);
    const dy = @max(0, @abs(y - rect.y - @as(f64, rect.height) / 2) - @as(f64, rect.height) / 2 + radius);
    if (interior) return x > rect.x and y > rect.y and x < @as(f64, rect.x) + rect.width and y < @as(f64, rect.y) + rect.height and (radius == 0 or dx * dx + dy * dy < radius * radius);
    return x >= rect.x and y >= rect.y and x <= @as(f64, rect.x) + rect.width and y <= @as(f64, rect.y) + rect.height and dx * dx + dy * dy <= radius * radius;
}
const shaped: ui.Rect = .{ .x = 1.25, .y = 1.5, .width = 29.5, .height = 17 };
fn coverage(shape: usize, x: usize, y: usize, scale: f32) u8 {
    if (shape == 0) return 255;
    var samples: u32 = 0;
    for (0..4) |sy| for (0..4) |sx| {
        // Preserve the existing geometry contract's center-plus-jitter sample
        // coordinates. The circle test is independent of its SDF predicate.
        const inverse = 1 / @as(f64, scale);
        const px = (@as(f64, @floatFromInt(x)) + 0.5) * inverse + (@as(f64, @floatFromInt(sx)) / 4 - 0.375) * inverse;
        const py = (@as(f64, @floatFromInt(y)) + 0.5) * inverse + (@as(f64, @floatFromInt(sy)) / 4 - 0.375) * inverse;
        const inner: ui.Rect = .{ .x = shaped.x + 1, .y = shaped.y + 1, .width = shaped.width - 2, .height = shaped.height - 2 };
        // The inner contour belongs to the stroke; only its strict interior
        // is removed. This also matches the original pad geometry policy.
        samples += @intFromBool(inside(px, py, shaped, 3, false) and (shape != 2 or !inside(px, py, inner, 2, true)));
    };
    const clip = @max(0, @min(@as(f64, @floatFromInt(x + 1)), 30.5 * scale) - @max(@as(f64, @floatFromInt(x)), 1.5 * scale)) * @max(0, @min(@as(f64, @floatFromInt(y + 1)), 18.25 * scale) - @max(@as(f64, @floatFromInt(y)), 1.25 * scale));
    return @intFromFloat(@round(@as(f64, @floatFromInt((samples * 255 + 8) / 16)) * clip));
}
fn near(expected: u32, actual: u32, limit: u32, label: []const u8, x: usize, y: usize) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((expected >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > limit) {
        std.debug.print("gradient spread {s} at={d},{d} expected={x} actual={x} limit={d}\n", .{ label, x, y, expected, actual, limit });
        return error.SpreadPixelMismatch;
    };
}
fn pixel(level: ui.drawing.ImageLevel, x: usize, y: usize) u32 {
    const raw = level.pixels[y * level.stride + x * 4 ..][0..4];
    return @as(u32, raw[3]) << 24 | @as(u32, raw[2]) << 16 | @as(u32, raw[1]) << 8 | raw[0];
}
fn composition(surface: *ui.offscreen.Surface, size: z.Size, buffer: *ui.commands.Buffer) !void {
    var lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const raw: [8 * 8]u8 = @splat(128);
    const view: ui.drawing.CoverageView = .{ .lease = &lease, .identity = try ui.drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 8, .height = 8, .stride = 8, .origin_x = 0, .origin_y = 0, .scale = size.scale } };
    try surface.uploadCoverage(view);
    defer {
        buffer.reset();
        _ = surface.releaseCoverage(view.identity) catch unreachable;
        lease.ensureUnused() catch unreachable;
    }
    buffer.reset();
    var transforms: ui.commands.TransformStorage = .{ .scale = size.scale };
    defer buffer.reset();
    try buffer.bindTransformStorage(&transforms);
    try buffer.fill(bounds, background & 0xffffff);
    try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = width }, .{ .width = width, .height = height }, size.scale));
    try buffer.pushClip(.{ .x = 4.25 / size.scale, .y = 4.5 / size.scale, .width = 7.5 / size.scale, .height = 7 / size.scale });
    try buffer.beginGroup(bounds, .{ .opacity = 128 });
    try buffer.gradientCoverage(.{ .x = 4 / size.scale, .y = 4 / size.scale }, view, descriptor(.reflect, .oklab, 0));
    try buffer.endGroup();
    try buffer.popClip();
    try buffer.endTransform();
    const palette = oracle.Palette.init(@backingInt(b.InterpolationSpace.oklab), &colors);
    const before = try surface.stats();
    for (0..2) |_| {
        const snapshot = try surface.render(buffer);
        defer snapshot.close() catch unreachable;
        const level = (try snapshot.view()).levels[0];
        for (0..size.height) |y| for (0..size.width) |x| {
            const source_x = size.width - 1 - x;
            const px = (@as(f128, @floatFromInt(source_x)) + 0.5) / size.scale;
            const py = (@as(f128, @floatFromInt(y)) + 0.5) / size.scale;
            var value = palette.at(parameter(0, px, py, .reflect));
            const clip = @max(0, @min(@as(f64, @floatFromInt(source_x + 1)), 11.75) - @max(@as(f64, @floatFromInt(source_x)), 4.25)) * @max(0, @min(@as(f64, @floatFromInt(y + 1)), 11.5) - @max(@as(f64, @floatFromInt(y)), 4.5));
            const active = source_x >= 4 and source_x < 12 and y >= 4 and y < 12;
            const opacity: f128 = if (active) @as(f128, clip) * 128 * 128 / (255 * 255) else 0;
            for (&value) |*channel| channel.* *= opacity;
            // The two byte group intermediates bound rounding by two bytes.
            try near(oracle.over(value, background, 255), pixel(level, x, y), 2, "A8/group/reflection", x, y);
        };
        try std.testing.expectEqual(before.layers.native_creations, (try surface.stats()).layers.native_creations);
    }
}
fn software(app: *z.App, allocator: std.mem.Allocator) !void {
    var planes: usize = 0;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const size: z.Size = .{ .width = @intFromFloat(width * scale), .height = @intFromFloat(height * scale), .scale = scale };
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        const surface = try ui.offscreen.Surface.create(app, failing.allocator(), .{ .size = size, .max_depth = 3, .transform_source = .{ .width = width, .height = height } });
        defer surface.close() catch unreachable;
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        for ([_]b.Spread{ .repeat, .reflect }) |spread| for ([_]b.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| for (0..2) |kind| {
            const palette = oracle.Palette.init(@backingInt(space), &colors);
            for (0..3) |shape| {
                buffer.reset();
                try buffer.fill(bounds, background & 0xffffff);
                if (shape != 0) try buffer.pushClip(.{ .x = 1.5, .y = 1.25, .width = 29, .height = 17 });
                const brush = descriptor(spread, space, kind);
                if (shape == 2) try buffer.gradientStrokeRect(shaped, 3, 1, brush) else try buffer.gradientRect(if (shape == 0) bounds else shaped, if (shape == 0) 0 else 3, brush);
                if (shape != 0) try buffer.popClip();
                const snapshot = try surface.render(&buffer);
                defer snapshot.close() catch unreachable;
                const level = (try snapshot.view()).levels[0];
                for (0..size.height) |y| for (0..size.width) |x| {
                    const px = (@as(f128, @floatFromInt(x)) + 0.5) / scale;
                    const py = (@as(f128, @floatFromInt(y)) + 0.5) / scale;
                    near(oracle.over(palette.at(parameter(kind, px, py, spread)), background, coverage(shape, x, y, scale)), pixel(level, x, y), 1, "XYZ software", x, y) catch |err| {
                        const dx = (@as(f64, @floatFromInt(x)) + 0.5) * (1 / @as(f64, scale)) - (if (kind == 0) @as(f64, 12) else 14.5);
                        const dy = (@as(f64, @floatFromInt(y)) + 0.5) * (1 / @as(f64, scale)) - (if (kind == 0) @as(f64, 7) else 9.5);
                        const t = if (kind == 0) (dx * 6 + dy * 4) / 52 else @sqrt((dx / 6) * (dx / 6) + (dy / 3) * (dy / 3));
                        std.debug.print("spread diagnostic spread={s} space={s} kind={d} shape={d} scale={d} x={d} y={d} reciprocal_t={d:.18} phase={d:.18} oracle_phase={d:.18}\n", .{ @tagName(spread), @tagName(space), kind, shape, scale, x, y, t, b.spreadParameter(spread, t), parameter(kind, px, py, spread) });
                        return err;
                    };
                };
                planes += 1;
            }
        };
        try composition(surface, size, &buffer);
        buffer.reset();
        try buffer.gradientRect(bounds, 0, descriptor(.reflect, .oklab, 0));
        const old = try surface.render(&buffer);
        defer old.close() catch unreachable;
        const old_view = try old.view();
        const old_hash = std.hash.Wyhash.hash(0, old_view.levels[0].pixels[0..old_view.levels[0].byte_len]);
        const before = try surface.stats();
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, surface.render(&buffer));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqual(before.renders, (try surface.stats()).renders);
        try std.testing.expectEqual(old_hash, std.hash.Wyhash.hash(0, old_view.levels[0].pixels[0..old_view.levels[0].byte_len]));
    }
    std.debug.print("gradient spread software XYZ planes={d} repeat/reflect linear/radial three spaces/DPI/shape+clip; old snapshot OOM preserved\n", .{planes});
}

fn gpuReject(app: *z.App, driver: ui.gpu_resources.Driver) !void {
    const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const surface = try ui.gpu_offscreen.Surface.create(domain, std.heap.page_allocator, .{ .size = .{ .width = width, .height = height, .scale = 1 } });
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(bounds, 0x112233);
    try surface.render(&buffer);
    const texture = try surface.snapshot();
    defer {
        buffer.reset();
        texture.close() catch unreachable;
    }
    var before: [width * height]u32 = undefined;
    var after: [width * height]u32 = undefined;
    try surface.readFrontForTest(&before);
    const stats = try surface.stats();
    for ([_]b.Spread{ .repeat, .reflect }) |spread| for ([_]b.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
        buffer.reset();
        try buffer.fill(bounds, 0x00ff00);
        try buffer.texture(bounds, try texture.view(), .{});
        try buffer.gradientRect(bounds, 0, descriptor(spread, space, 0));
        try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(&buffer));
        try std.testing.expectEqualDeep(stats, try surface.stats());
        try surface.readFrontForTest(&after);
        try std.testing.expectEqualSlices(u32, &before, &after);
    };
    buffer.reset();
}

const Fallback = struct {
    spread: b.Spread = .pad,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(background & 0xffffff);
        frame.gradientRect(bounds, 0, descriptor(self.spread, .srgb, 0));
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn fallback(app: *z.App, mode: ui.RenderMode) !void {
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    var state: Fallback = .{};
    var context = ui.Context.init(&state, Fallback.draw, Fallback.action);
    context.render_mode = mode;
    try context.attach(window);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    const gpu_draws = context.gpu_renderer.gradientStats().draws;
    const palette = oracle.Palette.init(0, &colors);
    for ([_]b.Spread{ .repeat, .reflect }, 0..) |spread, index| {
        state.spread = spread;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(index + 2, state.draws);
        try std.testing.expectEqual(index + 1, context.fallbacks);
        try std.testing.expectEqual(index + 1, context.gdi_frames);
        try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
        try std.testing.expectEqual(gpu_draws, context.gpu_renderer.gradientStats().draws);
        if (c.GdiFlush() == 0) return error.FlushFailed;
        const size = context.last_paint_size orelse return error.MissingPaint;
        for (0..size.height) |y| for (0..size.width) |x| {
            const px = (@as(f128, @floatFromInt(x)) + 0.5) / size.scale;
            const py = (@as(f128, @floatFromInt(y)) + 0.5) / size.scale;
            const expected = if (px < width and py < height) oracle.over(palette.at(parameter(0, px, py, spread)), background, 255) else background;
            // A normal window uses an opaque GDI BGRX plane. FillRect does
            // not preserve its unused X byte; transparent Surface checks
            // above still compare all four BGRA channels.
            try near(expected & 0xffffff, context.renderer.pixels.?[y * size.width + x] & 0xffffff, 1, "same Buffer fallback RGB", x, y);
        };
    }
    state.spread = .pad;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 4), state.draws);
    try std.testing.expectEqual(@as(usize, 2), context.gpu_frames);
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    try software(app, allocator.allocator());
    if (builtin.os.tag == .windows and ui.capabilities.gpu) {
        try gpuReject(app, .hardware);
        try gpuReject(app, .warp);
        try fallback(app, .hardware);
        try fallback(app, .warp);
        try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    } else if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(u32, 0), zlc_layer_live_objects());
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
    std.debug.print("gradient spread native resources0; GPU periodic mode is typed whole-Buffer software fallback\n", .{});
}
