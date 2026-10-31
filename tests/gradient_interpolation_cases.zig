const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const b = ui.commands.brushes;
const reference = @import("gradient_interpolation_oracle.zig");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_patterns() u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;
const width = 48;
const height = 32;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
const shaped: ui.Rect = .{ .x = 2.203125, .y = 3.296875, .width = 41.40625, .height = 25.21875 };
const radius = 5.015625;
const stroke = 2.03125;
const stops_bw = [_]b.Stop{ .{ .offset = 0, .color = .rgb(0) }, .{ .offset = 1, .color = .rgb(0xffffff) } };
const stops_hidden = [_]b.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
const stops_alpha = [_]b.Stop{ .{ .offset = 0.125, .color = .{ .r = 255, .g = 0, .b = 40, .a = 31 } }, .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } }, .{ .offset = 0.875, .color = .{ .r = 0, .g = 0, .b = 255, .a = 231 } } };
const stops_full: [16]b.Stop = blk: {
    var result: [16]b.Stop = undefined;
    for (&result, 0..) |*stop, index| stop.* = .{ .offset = @as(f32, @floatFromInt(index / 2)) / 7, .color = .{ .r = @intCast((index * 137) % 256), .g = @intCast((index * 73) % 256), .b = @intCast((index * 211) % 256), .a = @intCast((index * 43) % 256) } };
    break :blk result;
};
fn stops(index: usize) []const b.Stop {
    return switch (index) {
        0 => &stops_bw,
        1 => &stops_hidden,
        2 => &stops_alpha,
        else => &stops_full,
    };
}
fn descriptor(space: b.InterpolationSpace, kind: usize, index: usize) b.Gradient {
    return switch (kind) {
        0 => .{ .linear = .{ .start = .{ .x = 2, .y = 4 }, .end = .{ .x = 42, .y = 20 }, .stops = stops(index), .interpolation = space } },
        1 => .{ .radial = .{ .center = .{ .x = 24.5, .y = 16.5 }, .radius = .{ .x = 18, .y = 12 }, .stops = stops(index), .interpolation = space } },
        else => .{ .conic = .{ .center = .{ .x = 24.5, .y = 16.5 }, .start_angle_radians = 0.25, .direction = .counter_clockwise, .stops = stops(index), .interpolation = space } },
    };
}
fn parameter(kind: usize, x: f64, y: f64) f64 {
    if (kind == 0) return ((x - 2) * 40 + (y - 4) * 16) / (40 * 40 + 16 * 16);
    const dx = x - 24.5;
    const dy = y - 16.5;
    if (kind == 1) return @sqrt(dx * dx / (18 * 18) + dy * dy / (12 * 12));
    if (dx == 0 and dy == 0) return 0;
    const angle = std.math.acos(std.math.clamp(dx / @sqrt(dx * dx + dy * dy), -1, 1));
    const signed = if (dy < 0) -angle else angle;
    const turn = (0.25 - signed) / (2 * std.math.pi);
    const result = turn - @floor(turn);
    return if (result >= 1) std.math.nextAfter(f64, 1, 0) else result;
}
fn inside(x: f64, y: f64, rect: ui.Rect, r: f64) bool {
    const xx = @abs(x - rect.x - @as(f64, rect.width) / 2) - @as(f64, rect.width) / 2 + r;
    const yy = @abs(y - rect.y - @as(f64, rect.height) / 2) - @as(f64, rect.height) / 2 + r;
    return @sqrt(@max(0, xx) * @max(0, xx) + @max(0, yy) * @max(0, yy)) + @min(0, @max(xx, yy)) <= r;
}
fn coverage(shape: usize, scale: f32, x: usize, y: usize) u8 {
    if (shape == 0) return 255;
    const px: f64 = @floatFromInt(x);
    const py: f64 = @floatFromInt(y);
    var count: u32 = 0;
    for (0..4) |sy| for (0..4) |sx| {
        const xx = (px + 0.125 + @as(f64, @floatFromInt(sx)) / 4) / scale;
        const yy = (py + 0.125 + @as(f64, @floatFromInt(sy)) / 4) / scale;
        const hole: ui.Rect = .{ .x = shaped.x + stroke, .y = shaped.y + stroke, .width = shaped.width - 2 * stroke, .height = shaped.height - 2 * stroke };
        count += @intFromBool(inside(xx, yy, shaped, radius) and (shape != 2 or !inside(xx, yy, hole, radius - stroke)));
    };
    const mask: f64 = @floatFromInt((count * 255 + 8) / 16);
    const clip = @max(0, @min(px + 1, 45.75 * scale) - @max(px, 1.25 * scale)) * @max(0, @min(py + 1, 29.75 * scale) - @max(py, 2.5 * scale));
    return @intFromFloat(@round(mask * clip));
}
fn near(expected: u32, actual: u32, label: []const u8, space: b.InterpolationSpace, kind: usize, index: usize, scale: f32, x: usize, y: usize) !void {
    for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((expected >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > 1) {
        std.debug.print("interpolation {s} {s} kind={d} palette={d} DPI={d} at={d},{d}: want={x} actual={x}\n", .{ label, @tagName(space), kind, index, scale, x, y, expected, actual });
        return error.PixelMismatch;
    };
}
fn record(buffer: *ui.commands.Buffer, space: b.InterpolationSpace, kind: usize, index: usize, shape: usize) !void {
    buffer.reset();
    try buffer.fill(bounds, 0xffffff);
    if (shape != 0) try buffer.pushClip(.{ .x = 1.25, .y = 2.5, .width = 44.5, .height = 27.25 });
    const value = descriptor(space, kind, index);
    if (shape == 2) try buffer.gradientStrokeRect(shaped, radius, stroke, value) else try buffer.gradientRect(if (shape == 0) bounds else shaped, if (shape == 0) 0 else radius, value);
    if (shape != 0) try buffer.popClip();
    try buffer.finish();
}
fn software(context: *anyopaque, window: ?*anyopaque) !void {
    var max_full: u32 = 0;
    var max_edge: u32 = 0;
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const w: u32 = @intFromFloat(width * scale);
        const h: u32 = @intFromFloat(height * scale);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } };
        try renderer.begin(paint);
        for ([_]b.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| for (0..3) |kind| for (0..4) |index| {
            const palette = reference.Palette.init(@backingInt(space), stops(index));
            for (0..3) |shape| {
                try record(&buffer, space, kind, index, shape);
                try renderer.replayBuffer(&buffer);
                if (builtin.os.tag == .windows) _ = c.GdiFlush();
                for (0..h) |y| for (0..w) |x| {
                    const mask = coverage(shape, scale, x, y);
                    const want = reference.over(palette.at(parameter(kind, (@as(f64, @floatFromInt(x)) + 0.5) / scale, (@as(f64, @floatFromInt(y)) + 0.5) / scale)), 0xffffffff, mask);
                    const actual = if (builtin.os.tag == .windows) renderer.pixels.?[y * w + x] else zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
                    for ([_]u5{ 0, 8, 16 }) |shift| {
                        const error_value: u32 = @intCast(@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))));
                        if ((mask == 255 and error_value > max_full) or (mask != 255 and error_value > max_edge)) {
                            std.debug.print("interpolation new {s} maximum={d}: {s} kind={d} palette={d} shape={d} DPI={d} pixel={d},{d} channel={d} want={x} actual={x}\n", .{ if (mask == 255) "full" else "edge", error_value, @tagName(space), kind, index, shape, scale, x, y, shift, want, actual | 0xff000000 });
                            if (mask == 255) max_full = error_value else max_edge = error_value;
                        }
                    }
                    try near(want, actual | 0xff000000, "software XYZ", space, kind, index, scale, x, y);
                };
            }
        };
        try renderer.endChecked(paint);
    }
    std.debug.print("interpolation software max-channel-error: fully-covered={d}, shape/clip-edge={d}; limit=1\n", .{ max_full, max_edge });
}
fn bufferContracts() !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]b.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| try buffer.gradientRect(bounds, 0, descriptor(space, 0, 0));
    try std.testing.expectEqual(@as(usize, 3), buffer.brush_len);
    try buffer.gradientRect(bounds, 0, descriptor(.oklab, 0, 0));
    try std.testing.expectEqual(@as(usize, 3), buffer.brush_len);
    buffer.reset();
    for (0..32) |index| {
        var value = descriptor(.oklab, 0, 0);
        value.linear.end.x += @floatFromInt(index);
        try buffer.gradientRect(bounds, 0, value);
    }
    const count = buffer.len;
    try std.testing.expectError(error.BrushesFull, buffer.gradientRect(bounds, 0, descriptor(.srgb_linear, 0, 0)));
    try std.testing.expectEqual(count, buffer.len);
    try std.testing.expectEqual(@as(usize, 32), buffer.brush_len);
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(b.Stored));
    var random = std.Random.DefaultPrng.init(0xd656d1a0);
    for (0..256) |_| {
        var pair: [2]b.Stop = undefined;
        for (&pair, 0..) |*stop, index| stop.* = .{ .offset = @floatFromInt(index), .color = .{ .r = random.random().int(u8), .g = random.random().int(u8), .b = random.random().int(u8), .a = random.random().int(u8) } };
        for ([_]b.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
            const palette = reference.Palette.init(@backingInt(space), &pair);
            const stored = try b.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = &pair, .interpolation = space } });
            for (1..16) |step| {
                const t = @as(f64, @floatFromInt(step)) / 16;
                const value = stored.sample(t, 0);
                const expected = palette.at(t);
                for ([_]f64{ value.r, value.g, value.b, value.a * 255 }, expected) |actual, channel| try std.testing.expectApproxEqAbs(@as(f64, @floatCast(channel * 255)), actual, 0.001);
            }
        }
    }
}
fn offscreen(app: *z.App) !void {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
        const size: z.Size = .{ .width = @intFromFloat(16 * scale), .height = @intFromFloat(16 * scale), .scale = scale };
        const surface = try ui.offscreen.Surface.create(app, failing.allocator(), .{ .size = size, .max_depth = 2, .transform_source = .{ .width = 16, .height = 16 } });
        defer surface.close() catch unreachable;
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        var table: ui.commands.TransformStorage = .{};
        for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| {
            buffer.reset();
            table.scale = scale;
            try buffer.bindTransformStorage(&table);
            const rect: ui.Rect = .{ .x = 0, .y = 0, .width = 16, .height = 16 };
            try buffer.fill(rect, 0xffffff);
            try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = 16 }, .{ .width = 16, .height = 16 }, scale));
            try buffer.pushClip(.{ .x = 2, .y = 2, .width = 12, .height = 12 });
            try buffer.beginGroup(rect, .{ .opacity = 128 });
            try buffer.gradientRect(rect, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 16 }, .stops = &stops_alpha, .interpolation = space } });
            try buffer.endGroup();
            try buffer.popClip();
            try buffer.endTransform();
            const snapshot = try surface.render(&buffer);
            defer snapshot.close() catch unreachable;
            const view = try snapshot.view();
            const layer = view.levels[0];
            const palette = reference.Palette.init(@backingInt(space), &stops_alpha);
            const before = try surface.stats();
            failing.fail_index = failing.alloc_index;
            try std.testing.expectError(error.OutOfMemory, surface.render(&buffer));
            try std.testing.expectEqual(before.renders, (try surface.stats()).renders);
            failing.fail_index = std.math.maxInt(usize);
            buffer.reset();
            for (0..size.height) |y| for (0..size.width) |x| {
                const sx = 16 - (@as(f64, @floatFromInt(x)) + 0.5) / scale;
                const sy = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
                var want: u32 = 0xffffffff;
                if (sx >= 2 and sx < 14 and sy >= 2 and sy < 14) {
                    const source = reference.over(palette.at(sx / 16), 0, 255);
                    const alpha = ((source >> 24) * 128 + 127) / 255;
                    want = 0xff000000;
                    for ([_]u5{ 0, 8, 16 }) |shift| want |= @as(u32, @min(255, ((((source >> shift) & 255) * 128 + 127) / 255) + 255 - alpha)) << shift;
                }
                const actual = std.mem.readInt(u32, layer.pixels[y * layer.stride + x * 4 ..][0..4], .little);
                try near(want, actual, "owned capture/group/reflection/failed output", space, 0, 2, scale, x, y);
            };
        }
    }
}
fn gpuReject(context: *anyopaque, window: *anyopaque, driver: ui.d3d11.Driver) !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = width, .height = height, .scale = 1 } };
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| for (0..3) |kind| {
        try renderer.begin(paint);
        defer renderer.abort();
        const stats = renderer.gradientStats();
        buffer.reset();
        try buffer.fill(bounds, 0x00ff00);
        try buffer.gradientRect(bounds, 0, descriptor(.srgb, 0, 0));
        try buffer.gradientRect(bounds, 0, descriptor(space, kind, 0));
        try std.testing.expectError(error.UnsupportedGradientPrecision, renderer.replayBuffer(&buffer));
        try std.testing.expectEqual(@as(i32, 0), renderer.last_hresult);
        try std.testing.expectEqualDeep(stats, renderer.gradientStats());
        try std.testing.expect(!renderer.active);
    };
}
fn gpuFrontReject(app: *z.App, driver: ui.gpu_resources.Driver) !void {
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
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| for ([_]bool{ false, true }) |with_texture| {
        buffer.reset();
        try buffer.fill(bounds, 0x00ff00);
        if (with_texture) try buffer.texture(bounds, try texture.view(), .{});
        try buffer.gradientRect(bounds, 0, descriptor(space, 0, 0));
        try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(&buffer));
        try std.testing.expectEqual(stats.renders, (try surface.stats()).renders);
        try std.testing.expectEqualDeep(stats.layers, (try surface.stats()).layers);
        try surface.readFrontForTest(&after);
        try std.testing.expectEqualSlices(u32, &before, &after);
    };
    buffer.reset();
}
const Fallback = struct {
    space: b.InterpolationSpace = .srgb,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0xffffff);
        frame.gradientRect(bounds, 0, descriptor(self.space, 0, 0));
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn contextFallback(app: *z.App, mode: ui.RenderMode) !void {
    var state: Fallback = .{};
    var context = ui.Context.init(&state, Fallback.draw, Fallback.action);
    context.render_mode = mode;
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    try context.attach(window);
    try std.testing.expect(!context.gpu_unavailable);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    const old_draws = context.gpu_renderer.gradientStats().draws;
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }, 0..) |space, index| {
        state.space = space;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(index + 2, state.draws);
        try std.testing.expectEqual(index + 1, context.gdi_frames);
        try std.testing.expectEqual(index + 1, context.fallbacks);
        try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
        try std.testing.expectEqual(old_draws, context.gpu_renderer.gradientStats().draws);
        const palette = reference.Palette.init(@backingInt(space), &stops_bw);
        _ = c.GdiFlush();
        for (0..context.renderer.width) |x| {
            const px = (@as(f64, @floatFromInt(x)) + 0.5) / context.renderer.scale;
            const py = 0.5 / @as(f64, context.renderer.scale);
            const want = if (px >= width or py >= height) 0xffffffff else reference.over(palette.at(parameter(0, px, py)), 0xffffffff, 255);
            try near(want, context.renderer.pixels.?[x] | 0xff000000, "same-buffer fallback", space, 0, 0, context.renderer.scale, x, 0);
        }
    }
    state.space = .srgb;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 4), state.draws);
    try std.testing.expectEqual(@as(usize, 2), context.gpu_frames);
}
pub fn run() !void {
    try bufferContracts();
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    var diagnostics: z.diagnostics.Recorder(8) = .{};
    const app = try z.App.initWithOptions(debug.allocator(), .{ .diagnostics_sink = diagnostics.sink() });
    defer app.deinit();
    if (builtin.os.tag == .windows) {
        const window = try app.createWindow(.{});
        defer _ = window.destroy() catch unreachable;
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        const dc = c.GetDC(hwnd) orelse return error.GetDCFailed;
        defer _ = c.ReleaseDC(hwnd, dc);
        const baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
        try software(dc, hwnd);
        try offscreen(app);
        if (ui.capabilities.gpu) {
            try gpuReject(dc, hwnd.?, .hardware);
            try gpuReject(dc, hwnd.?, .warp);
            try gpuFrontReject(app, .hardware);
            try gpuFrontReject(app, .warp);
            try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
        }
        try std.testing.expectEqual(baseline, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        if (ui.capabilities.gpu) {
            try contextFallback(app, .hardware);
            try contextFallback(app, .warp);
            var entries: [8]z.diagnostics.Diagnostic = undefined;
            try std.testing.expectEqual(@as(usize, 4), diagnostics.snapshot(&entries).count);
            for (entries[0..4]) |entry| {
                try std.testing.expectEqual(error.UnsupportedGradientPrecision, entry.err.?);
                try std.testing.expectEqual(null, entry.code);
            }
        }
    } else {
        const surface = cairo_image_surface_create(0, width * 2, height * 2) orelse return error.SurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.ContextFailed;
        defer cairo_destroy(context);
        try software(context, null);
        try offscreen(app);
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_patterns());
        try std.testing.expectEqual(@as(u32, 0), zlc_layer_live_objects());
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
    std.debug.print("gradient interpolation: XYZ/f128 matrix/interpolation + f64 transfer pow, 324 full-pixel software cases, owned capture/reflection/groups/OOM and explicit GPU rejection; resources0\n", .{});
}
