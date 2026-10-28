// Prepared-GPU cases. The oracle uses separate XYZ matrices and physical
// sample enumeration; it does not import the production analytic kernel.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const b = ui.commands.brushes;
const drawing = ui.drawing;
const reference = @import("gradient_interpolation_oracle.zig");
const c = @import("ziggurat_c_win32");
const width = 48;
const height = 32;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
const shaped: ui.Rect = .{ .x = 2.203125, .y = 3.296875, .width = 41.40625, .height = 25.21875 };
const radius = 5.015625;
const stroke = 2.03125;
const palettes = [3][4]b.Stop{
    .{
        .{ .offset = 0, .color = .rgb(0xff0020) },
        .{ .offset = 0.25, .color = .rgb(0x00ff00) },
        .{ .offset = 0.75, .color = .rgb(0x0000ff) },
        .{ .offset = 1, .color = .rgb(0xff0020) },
    },
    .{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 0.25, .color = .{ .r = 0, .g = 255, .b = 0, .a = 1 } },
        .{ .offset = 0.75, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
        .{ .offset = 1, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
    },
    .{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 40, .a = 31 } },
        .{ .offset = 0.25, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } },
        .{ .offset = 0.75, .color = .{ .r = 0, .g = 0, .b = 255, .a = 231 } },
        .{ .offset = 1, .color = .{ .r = 255, .g = 0, .b = 40, .a = 31 } },
    },
};
const hard = [_]b.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 231 } },
    .{ .offset = 1, .color = .rgb(0xffffff) },
};
fn descriptor(space: b.InterpolationSpace, kind: usize, values: []const b.Stop) b.Gradient {
    return switch (kind) {
        0 => .{ .linear = .{ .start = .{ .x = 2, .y = 4 }, .end = .{ .x = 42, .y = 20 }, .stops = values, .interpolation = space } },
        1 => .{ .radial = .{ .center = .{ .x = 24.5, .y = 16.5 }, .radius = .{ .x = 18, .y = 12 }, .stops = values, .interpolation = space } },
        2 => .{ .conic = .{ .center = .{ .x = 24.5, .y = 16.5 }, .direction = .counter_clockwise, .stops = values, .interpolation = space } },
        else => .{ .linear = .{ .start = .{ .x = 0.5 }, .end = .{ .x = 32.5 }, .stops = values, .interpolation = space } },
    };
}
fn parameter(kind: usize, x: f64, y: f64) f64 {
    if (kind == 0) return ((x - 2) * 40 + (y - 4) * 16) / (40 * 40 + 16 * 16);
    if (kind == 3) return (x - 0.5) / 32;
    const dx = x - 24.5;
    const dy = y - 16.5;
    if (kind == 1) return @sqrt(dx * dx / (18 * 18) + dy * dy / (12 * 12));
    if (dx == 0 and dy == 0) return 0;
    const angle = std.math.acos(std.math.clamp(dx / @sqrt(dx * dx + dy * dy), -1, 1));
    const turns = (if (dy < 0) angle else -angle) / (2 * std.math.pi);
    return turns - @floor(turns);
}
fn inside(x: f64, y: f64, rect: ui.Rect, r: f64) bool {
    const xx = @abs(x - rect.x - @as(f64, rect.width) / 2) - @as(f64, rect.width) / 2 + r;
    const yy = @abs(y - rect.y - @as(f64, rect.height) / 2) - @as(f64, rect.height) / 2 + r;
    return @sqrt(@max(0, xx) * @max(0, xx) + @max(0, yy) * @max(0, yy)) + @min(0, @max(xx, yy)) <= r;
}
fn coverage(shape: usize, scale: f32, x: usize, y: usize) f64 {
    if (shape == 0) return 1;
    var count: u32 = 0;
    const hole: ui.Rect = .{ .x = shaped.x + stroke, .y = shaped.y + stroke, .width = shaped.width - 2 * stroke, .height = shaped.height - 2 * stroke };
    for (0..4) |sy| for (0..4) |sx| {
        const xx = (@as(f64, @floatFromInt(x)) + 0.125 + @as(f64, @floatFromInt(sx)) / 4) / scale;
        const yy = (@as(f64, @floatFromInt(y)) + 0.125 + @as(f64, @floatFromInt(sy)) / 4) / scale;
        count += @intFromBool(inside(xx, yy, shaped, radius) and (shape != 2 or !inside(xx, yy, hole, radius - stroke)));
    };
    return @as(f64, @floatFromInt(count)) / 16;
}
fn packSample(color: [4]f128, amount: f64) u32 {
    var value: u32 = 0;
    for (color, [_]u5{ 16, 8, 0, 24 }) |channel, shift| value |= @as(u32, @intFromFloat(@round(std.math.clamp(channel * amount * 255, 0, 255)))) << shift;
    return value;
}
fn near(want: u32, actual: u32, limit: u8, kind: usize, x: usize, y: usize) !void {
    for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > limit) {
        std.debug.print("unified prepared gradient kind={d} at={d},{d} expected={x} actual={x} limit={d}\n", .{ kind, x, y, want, actual, limit });
        return error.PreparedGradientPixelMismatch;
    };
}
fn sourcePlane(palette: *const reference.Palette, kind: usize, size: z.Size, shape: usize, pixels: []const u32) !void {
    for (0..size.height) |y| for (0..size.width) |x| {
        const xx = (@as(f64, @floatFromInt(x)) + 0.5) / size.scale;
        const yy = (@as(f64, @floatFromInt(y)) + 0.5) / size.scale;
        // Literal source phases put the hard boundary on a pixel center at
        // 1x and 1.5x while both endpoint projections stay on the proven grid.
        const t = if (kind == 3) (xx - @as(f64, if (size.scale == 1.5) 1 else 0.5)) / 32 else parameter(kind, xx, yy);
        try near(packSample(palette.at(t), coverage(shape, size.scale, x, y)), pixels[y * size.width + x], 1, kind, x, y);
    };
}
pub fn run(app: *z.App, driver: ui.gpu_resources.Driver, scale: f32) !void {
    const allocator = std.heap.page_allocator;
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const size: z.Size = .{ .width = @intFromFloat(width * scale), .height = @intFromFloat(height * scale), .scale = scale };
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = size, .transform_source = .{ .width = width, .height = height }, .max_depth = 3 });
    defer surface.close() catch unreachable;
    try surface.prepareGradientInterpolation();
    const pixels = try allocator.alloc(u32, @as(usize, size.width) * size.height);
    defer allocator.free(pixels);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var planes: usize = 0;
    const ready = try surface.gradientInterpolationStats();
    const creations = (try surface.stats()).layers.native_creations;
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
        for (0..3) |kind| for (palettes) |values| for (0..3) |shape| {
            buffer.reset();
            const value = descriptor(space, kind, &values);
            if (shape == 2) try buffer.gradientStrokeRect(shaped, radius, stroke, value) else try buffer.gradientRect(if (shape == 0) bounds else shaped, if (shape == 0) 0 else radius, value);
            surface.render(&buffer) catch |err| {
                std.debug.print("unified render rejected {s} space={s} dpi={d} kind={d} shape={d} palette_first_alpha={d}\n", .{ @errorName(err), @tagName(space), scale, kind, shape, values[0].color.a });
                return err;
            };
            try surface.readFrontForTest(pixels);
            const palette = reference.Palette.init(@backingInt(space), &values);
            try sourcePlane(&palette, kind, size, shape, pixels);
            planes += 1;
        };
        buffer.reset();
        var hard_value = descriptor(space, 3, &hard);
        if (scale == 1.5) {
            hard_value.linear.start.x = 1;
            hard_value.linear.end.x = 33;
        }
        std.debug.print("unified hard {s} dpi={d} physical_start={d} physical_end={d} physical_boundary={d}\n", .{ @tagName(space), scale, hard_value.linear.start.x * scale, hard_value.linear.end.x * scale, (hard_value.linear.start.x + 16) * scale });
        try buffer.gradientRect(bounds, 0, hard_value);
        try surface.render(&buffer);
        try surface.readFrontForTest(pixels);
        const hard_palette = reference.Palette.init(@backingInt(space), &hard);
        try sourcePlane(&hard_palette, 3, size, 0, pixels);
        planes += 1;
        try composed(surface, &buffer, pixels, size, space);
        planes += 2;
    }
    const warmed = try surface.gradientInterpolationStats();
    try std.testing.expectEqual(ready.effect_creations, warmed.effect_creations);
    try std.testing.expectEqual(ready.draws + @as(u32, @intCast(planes)), warmed.draws);
    // Prepared planes and the program stay warm; readback is test-only work.
    try std.testing.expectEqual(creations, (try surface.stats()).layers.native_creations);
    buffer.reset();
    std.debug.print("unified gradient {s} dpi={d}: {d} XYZ planes, alpha/hard/rounded/stroke/mask/fractional clip/reflection; warm objects unchanged\n", .{ @tagName(driver), scale, planes });
}

fn composed(surface: *ui.gpu_offscreen.Surface, buffer: *ui.commands.Buffer, pixels: []u32, size: z.Size, space: b.InterpolationSpace) !void {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const raw = [_]u8{ 255, 64, 128, 255, 192, 0, 224, 255, 64 };
    const view: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 3, .height = 3, .stride = 3, .origin_x = -1, .origin_y = 2, .scale = size.scale } };
    try surface.uploadCoverage(view);
    defer {
        buffer.reset();
        _ = surface.releaseCoverage(view.identity) catch unreachable;
        lease.ensureUnused() catch unreachable;
    }
    const origin: drawing.Point = .{ .x = 10 + 0.75 / size.scale, .y = 9 + 0.25 / size.scale };
    const clip: ui.Rect = .{ .x = 10.125, .y = 9.75, .width = 5.5, .height = 5.25 };
    const palette = reference.Palette.init(@backingInt(space), &palettes[2]);
    var table: ui.commands.TransformStorage = .{ .scale = size.scale };
    for ([_]bool{ false, true }) |reflect| {
        buffer.reset();
        try buffer.bindTransformStorage(&table);
        if (reflect) try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = width }, .{ .width = width, .height = height }, size.scale));
        try buffer.pushClip(clip);
        try buffer.beginGroup(bounds, .{ .opacity = 153 });
        try buffer.gradientCoverage(origin, view, descriptor(space, 0, &palettes[2]));
        try buffer.endGroup();
        try buffer.popClip();
        if (reflect) try buffer.endTransform();
        try surface.render(buffer);
        try surface.readFrontForTest(pixels);
        for (0..size.height) |y| for (0..size.width) |x| {
            const source_x = if (reflect) size.width - 1 - x else x;
            const px: f64 = @floatFromInt(source_x);
            const py: f64 = @floatFromInt(y);
            var mask: f64 = 0;
            for (0..3) |row| for (0..3) |column| {
                const dx = px - @as(f64, origin.x) * size.scale + 1 - @as(f64, @floatFromInt(column));
                const dy = py - @as(f64, origin.y) * size.scale - 2 - @as(f64, @floatFromInt(row));
                mask += @as(f64, @floatFromInt(raw[row * 3 + column])) * @max(0, 1 - @abs(dx)) * @max(0, 1 - @abs(dy)) / 255;
            };
            const xx = (px + 0.5) / size.scale;
            const yy = (py + 0.5) / size.scale;
            const child = packSample(palette.at(parameter(0, xx, yy)), 1);
            // Resolve the A8 child to BGRA8 before outer opacity and clip.
            var wanted: u32 = 0;
            const clip_mask = @max(0, @min(px + 1, (@as(f64, clip.x) + clip.width) * size.scale) - @max(px, @as(f64, clip.x) * size.scale)) * @max(0, @min(py + 1, (@as(f64, clip.y) + clip.height) * size.scale) - @max(py, @as(f64, clip.y) * size.scale));
            for ([_]u5{ 0, 8, 16, 24 }) |shift| {
                const channel: f64 = @floatFromInt((child >> shift) & 255);
                const grouped = @round(channel * mask);
                wanted |= @as(u32, @intFromFloat(@round(grouped * (153.0 / 255.0) * clip_mask))) << shift;
            }
            try near(wanted, pixels[y * size.width + x], 3, 4 + @as(usize, @intFromBool(reflect)), x, y);
        };
    }
}

pub fn wide(app: *z.App, driver: ui.gpu_resources.Driver) !void {
    const allocator = std.heap.page_allocator;
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = .{ .width = 4096, .height = 4, .scale = 1 } });
    defer surface.close() catch unreachable;
    try surface.prepareGradientInterpolation();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const values = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
    const pixels = try allocator.alloc(u32, 4096 * 4);
    defer allocator.free(pixels);
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
        buffer.reset();
        try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 4096, .height = 4 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 4096 }, .stops = &values, .interpolation = space } });
        try surface.render(&buffer);
        try surface.readFrontForTest(pixels);
        const palette = reference.Palette.init(@backingInt(space), &values);
        for (0..4) |y| for (0..4096) |x| try near(packSample(palette.at((@as(f64, @floatFromInt(x)) + 0.5) / 4096), 1), pixels[y * 4096 + x], 1, 6, x, y);
    }
}

/// A narrowly conditioned gradient in a wide source plane. Only the corner
/// color is evaluated with the independent palette; readback remains batched.
/// Kept separate from the common-range collection to preserve a real RED.
pub fn conditioning(app: *z.App, driver: ui.gpu_resources.Driver) !void {
    const allocator = std.heap.page_allocator;
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = .{ .width = 4096, .height = 512, .scale = 1 }, .max_depth = 1, .resident_bytes = 0, .legacy_text = .disabled, .render_work = 32 * 1024 * 1024 });
    defer surface.close() catch unreachable;
    try surface.prepareGradientInterpolation();
    const allocated = try surface.stats();
    std.debug.print("gradient conditioning {s}: prepared_workspace_reserved={d} actual={d} metadata={d} raster_limit={d} render_work_limit=33554432\n", .{ @tagName(driver), allocated.workspace_reserved, allocated.workspace_actual, allocated.metadata_reserved, allocated.raster_limit });
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const rectangle: ui.Rect = .{ .x = 0, .y = 0, .width = 4096, .height = 512 };
    const background: u32 = 0xff183048;
    try buffer.fill(rectangle, background & 0xffffff);
    try surface.render(&buffer);
    const texture = try surface.snapshot();
    defer {
        buffer.reset();
        texture.close() catch unreachable;
    }
    const pixels = try allocator.alloc(u32, 4096 * 512);
    defer allocator.free(pixels);
    const steep = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.125, .color = .rgb(0xffffff) }, .{ .offset = 1, .color = .rgb(0) } };
    const rejected_values = [_]b.Gradient{
        conditionedDescriptor(1),
        .{ .radial = .{ .center = .{ .x = 24.5, .y = 16.5 }, .radius = .{ .x = 18, .y = 12 }, .stops = &steep, .interpolation = .oklab } },
        .{ .conic = .{ .center = .{ .x = 24.5, .y = 16.5 }, .stops = &steep, .interpolation = .oklab } },
    };
    for (rejected_values, 0..) |value, kind| for ([_]bool{ false, true }) |with_texture| {
        buffer.reset();
        // A valid prefix and an already committed Texture cannot be partially
        // drawn when a later gradient fails the common preflight.
        try buffer.fill(rectangle, 0x00ff00);
        if (with_texture) try buffer.texture(rectangle, try texture.view(), .{});
        try buffer.gradientRect(rectangle, 0, value);
        const old = try surface.stats();
        const old_program = try surface.gradientInterpolationStats();
        const old_domain = try domain.stats();
        try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(&buffer));
        try std.testing.expectEqualDeep(old, try surface.stats());
        try std.testing.expectEqualDeep(old_program, try surface.gradientInterpolationStats());
        try std.testing.expectEqualDeep(old_domain, try domain.stats());
        try surface.readFrontForTest(pixels);
        for (pixels) |pixel| try std.testing.expectEqual(background, pixel);
        std.debug.print("gradient conditioning {s}: kind={d} texture={any} typed-before-clear/front/work/program/domain-stats unchanged\n", .{ @tagName(driver), kind, with_texture });
    };
    buffer.reset();
    try conditioningContext(app, driver);
    try budgetEdges(app, driver);
}

const conditioned_a: f32 = 0.49985000491142273;
const conditioned_b: f32 = 6.156704425811768;
const conditioned_stops = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.015625, .color = .rgb(0xffffff) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
fn conditionedDescriptor(scale: f32) b.Gradient {
    return .{ .linear = .{ .start = .{ .x = conditioned_a / scale, .y = conditioned_a / scale }, .end = .{ .x = conditioned_b / scale, .y = conditioned_b / scale }, .stops = &conditioned_stops, .interpolation = .srgb_linear } };
}
const ConditioningContext = struct {
    scale: f32,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0x00ff00);
        frame.gradientRect(.{ .x = 0, .y = 0, .width = 4096 / self.scale, .height = 512 / self.scale }, 0, conditionedDescriptor(self.scale));
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn conditioningContext(app: *z.App, driver: ui.gpu_resources.Driver) !void {
    const window = try app.createWindow(.{ .width = 64, .height = 32 });
    defer _ = window.destroy() catch unreachable;
    const physical = try window.contentSize();
    var state: ConditioningContext = .{ .scale = physical.scale };
    var context = ui.Context.init(&state, ConditioningContext.draw, ConditioningContext.action);
    context.render_mode = if (driver == .warp) .warp else .hardware;
    try context.attach(window);
    try context.prepareGradientInterpolation();
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), state.draws);
    try std.testing.expectEqual(@as(usize, 0), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 1), context.gdi_frames);
    try std.testing.expectEqual(@as(usize, 1), context.fallbacks);
    try std.testing.expectEqual(@as(u32, 0), (try context.gpu_renderer.gradientInterpolationStats()).draws);
    if (c.GdiFlush() == 0) return error.FlushFailed;
    const value = conditionedDescriptor(physical.scale).linear;
    // This is the same independent corner oracle as the actual GPU RED. DIP
    // recording compensates only the real window DPI, not the color result.
    const at = 0.5 / @as(f64, physical.scale);
    const delta = @as(f64, value.end.x) - value.start.x;
    const parameter_value = ((at - @as(f64, value.start.x)) * delta * 2) / (delta * delta * 2);
    const palette = reference.Palette.init(1, &conditioned_stops);
    const wanted = packSample(palette.at(parameter_value), 1);
    try std.testing.expectEqual(@as(u32, 0xff060606), wanted);
    const actual = context.renderer.pixels.?[0] | 0xff000000;
    try near(wanted, actual, 1, 7, 0, 0);
    std.debug.print("gradient conditioning Context {s}: physical={d}x{d} scale={d} same-buffer draw1/gpu0/gdi1/fallback1 corner_expected={x} actual={x}\n", .{ @tagName(driver), physical.width, physical.height, physical.scale, wanted, actual });
    _ = try window.destroy();
}
fn budgetEdges(app: *z.App, driver: ui.gpu_resources.Driver) !void {
    const allocator = std.heap.page_allocator;
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = .{ .width = width, .height = height, .scale = 1 } });
    defer surface.close() catch unreachable;
    try surface.prepareGradientInterpolation();
    const values = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 0.1875, .color = .rgb(0xffffff) }, .{ .offset = 1, .color = .rgb(0) } };
    const palette = reference.Palette.init(2, &values);
    var output: [width * height]u32 = undefined;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]usize{ 1, 2 }) |kind| {
        buffer.reset();
        try buffer.gradientRect(bounds, 0, descriptor(.oklab, kind, &values));
        try surface.render(&buffer);
        try surface.readFrontForTest(&output);
        try sourcePlane(&palette, kind, .{ .width = width, .height = height, .scale = 1 }, 0, &output);
    }
    std.debug.print("gradient conditioning {s}: radial/conic boundary gap0.1875 accepted with independent XYZ planes\n", .{@tagName(driver)});
}
