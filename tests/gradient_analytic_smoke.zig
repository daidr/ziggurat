const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const brushes = ui.commands.brushes;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_patterns() u32;

const width = 192;
const height = 96;
const hard = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0xff0000) }, .{ .offset = 0.5, .color = .rgb(0xff0000) }, .{ .offset = 0.5, .color = .rgb(0x0000ff) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
const premultiplied = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 0.5, .color = .{ .r = 0, .g = 255, .b = 0, .a = 128 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };

fn fixtures() ![15]brushes.Stored {
    var steep = hard;
    steep[2].offset = 0.500001;
    var full: [brushes.max_stops]brushes.Stop = undefined;
    for (&full, 0..) |*stop, index| stop.* = .{ .offset = @as(f32, @floatFromInt(index / 2)) / 7, .color = premultiplied[index % 3].color };
    return .{
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 96.25 - 4096 }, .end = .{ .x = 96.25 + 4096 }, .stops = &hard } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 96.25 - 4096 }, .end = .{ .x = 96.25 + 4096 }, .stops = &steep } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96.25 - 4096, .y = 48 }, .radius = .{ .x = 8192, .y = 8192 }, .stops = &hard } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96.25 - 4096, .y = 48 }, .radius = .{ .x = 8192, .y = 8192 }, .stops = &steep } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = width }, .stops = &premultiplied } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96, .y = 48 }, .radius = .{ .x = 96, .y = 48 }, .stops = &premultiplied } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 96.25 + 4096 }, .end = .{ .x = 96.25 - 4096 }, .stops = &hard } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = -4000, .y = -4048 }, .end = .{ .x = 4192, .y = 4144 }, .stops = &hard } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = 96.25 - 524288 }, .end = .{ .x = 96.25 + 524288 }, .stops = &steep } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96.25 - 524288, .y = 48 }, .radius = .{ .x = 1048576, .y = 1048576 }, .stops = &steep } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = width }, .stops = &full } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96, .y = 48 }, .radius = .{ .x = 96, .y = 48 }, .stops = &full } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .y = height }, .stops = &hard } }),
        try brushes.Stored.init(.{ .linear = .{ .start = .{ .x = -1.25, .y = 3.5 }, .end = .{ .x = 191.75, .y = 89.125 }, .stops = &premultiplied } }),
        try brushes.Stored.init(.{ .radial = .{ .center = .{ .x = 96.5, .y = 48.5 }, .radius = .{ .x = 0.125, .y = 0.0009765625 }, .stops = &premultiplied } }),
    };
}
fn gradient(stored: *const brushes.Stored) brushes.Gradient {
    return switch (stored.kind) {
        .linear => .{ .linear = .{ .start = stored.a, .end = stored.b, .stops = stored.stops[0..stored.len] } },
        .radial => .{ .radial = .{ .center = stored.a, .radius = stored.b, .stops = stored.stops[0..stored.len] } },
        .conic => .{ .conic = .{ .center = stored.a, .start_angle_radians = stored.b.x, .direction = if (stored.b.y == 1) .clockwise else .counter_clockwise, .stops = stored.stops[0..stored.len] } },
    };
}
fn record(buffer: *ui.commands.Buffer, stored: *const brushes.Stored, clipped: bool) !void {
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = width, .height = height }, 0xffffff);
    if (clipped) try buffer.pushClip(.{ .x = 32, .y = 16, .width = 128, .height = 64 });
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = width, .height = height }, 0, gradient(stored));
    if (clipped) try buffer.popClip();
    try buffer.finish();
}
fn parameter(stored: *const brushes.Stored, x: f64, y: f64) f64 {
    const dx = x - stored.a.x;
    const dy = y - stored.a.y;
    if (stored.kind == .radial) return @sqrt((dx / stored.b.x) * (dx / stored.b.x) + (dy / stored.b.y) * (dy / stored.b.y));
    const vx = @as(f64, stored.b.x) - stored.a.x;
    const vy = @as(f64, stored.b.y) - stored.a.y;
    return (dx * vx + dy * vy) / (vx * vx + vy * vy);
}
fn closeColor(a: u32, b: u32) bool {
    for ([_]u5{ 0, 8, 16 }) |shift| if (@abs(@as(i32, @intCast((a >> shift) & 255)) - @as(i32, @intCast((b >> shift) & 255))) > 3) return false;
    return true;
}
fn overWhite(color: ui.Color) u32 {
    const alpha = @as(f64, @floatFromInt(color.a)) / 255;
    var result: u32 = 0;
    for ([_]u8{ color.r, color.g, color.b }, [_]u5{ 16, 8, 0 }) |channel, shift| result |= @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(channel)) * alpha + 255 * (1 - alpha)))) << shift;
    return result;
}
// Only a physical pixel whose footprint actually intersects a stop can contain
// a native boundary mixture. All neighboring pixels keep the strict oracle.
fn boundary(stored: *const brushes.Stored, x: u32, y: u32, scale: f32, actual: u32) bool {
    const left = @as(f64, @floatFromInt(x)) / scale;
    const top = @as(f64, @floatFromInt(y)) / scale;
    const right = (@as(f64, @floatFromInt(x)) + 1) / scale;
    const bottom = (@as(f64, @floatFromInt(y)) + 1) / scale;
    var low = std.math.inf(f64);
    var high: f64 = -std.math.inf(f64);
    for ([_]f64{ left, right }) |px| for ([_]f64{ top, bottom }) |py| {
        const t = parameter(stored, px, py);
        low = @min(low, t);
        high = @max(high, t);
    };
    if (stored.kind == .radial) low = @min(low, parameter(stored, @max(left, @min(right, stored.a.x)), @max(top, @min(bottom, stored.a.y))));
    var minimum: [3]u32 = @splat(255);
    var maximum: [3]u32 = @splat(0);
    var crossed = false;
    for (stored.stops[0..stored.len]) |stop| {
        if (stop.offset < low or stop.offset > high) continue;
        crossed = true;
        const color = overWhite(stop.color);
        for ([_]u5{ 0, 8, 16 }, 0..) |shift, channel| {
            const value = (color >> shift) & 255;
            minimum[channel] = @min(minimum[channel], value);
            maximum[channel] = @max(maximum[channel], value);
        }
    }
    if (!crossed) return false;
    const endpoint_colors = [_]u32{ stored.sample(left, top).over(0xffffff, 255), stored.sample(left, bottom).over(0xffffff, 255), stored.sample(right, top).over(0xffffff, 255), stored.sample(right, bottom).over(0xffffff, 255) };
    for (endpoint_colors) |color| for ([_]u5{ 0, 8, 16 }, 0..) |shift, channel| {
        minimum[channel] = @min(minimum[channel], (color >> shift) & 255);
        maximum[channel] = @max(maximum[channel], (color >> shift) & 255);
    };
    for ([_]u5{ 0, 8, 16 }, 0..) |shift, channel| {
        const value = (actual >> shift) & 255;
        if (value + 3 < minimum[channel] or value > maximum[channel] + 3) return false;
    }
    return true;
}
fn check(stored: *const brushes.Stored, clipped: bool, scale: f32, pixels: []const u32, fixture: usize) !void {
    const w: u32 = @intFromFloat(width * scale);
    const h: u32 = @intFromFloat(height * scale);
    for (0..h) |yi| for (0..w) |xi| {
        const x: u32 = @intCast(xi);
        const y: u32 = @intCast(yi);
        const px = (@as(f64, @floatFromInt(x)) + 0.5) / scale;
        const py = (@as(f64, @floatFromInt(y)) + 0.5) / scale;
        const outside = clipped and (px < 32 or px >= 160 or py < 16 or py >= 80);
        const expected = if (outside) 0xffffff else stored.sample(px, py).over(0xffffff, 255);
        const actual = pixels[yi * w + xi] & 0xffffff;
        if (closeColor(expected, actual)) continue;
        if (!outside and boundary(stored, x, y, scale, actual)) {
            continue;
        }
        std.debug.print("analytic fixture={d} clip={any} scale={d} pixel={d},{d} expected={x} actual={x}\n", .{ fixture, clipped, scale, x, y, expected, actual });
        return error.PixelMismatch;
    };
}
fn software(context: *anyopaque, window: ?*anyopaque) !void {
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const data = try fixtures();
    var pixels: [width * height * 4]u32 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const w: u32 = @intFromFloat(width * scale);
        const h: u32 = @intFromFloat(height * scale);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } };
        try renderer.begin(paint);
        for (&data, 0..) |*stored, index| for ([_]bool{ false, true }) |clipped| {
            try record(&buffer, stored, clipped);
            try renderer.replayBuffer(&buffer);
            if (builtin.os.tag == .windows) {
                _ = c.GdiFlush();
                @memcpy(pixels[0 .. w * h], renderer.pixels.?[0 .. w * h]);
            } else for (0..h) |y| for (0..w) |x| {
                pixels[y * w + x] = zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
            };
            try check(stored, clipped, scale, pixels[0 .. w * h], index);
        };
        if (builtin.os.tag == .linux) try fractionalClip(&renderer, &buffer, scale);
        renderer.end(paint);
    }
}
fn fractionalClip(renderer: *ui.SoftwareRenderer, buffer: *ui.commands.Buffer, scale: f32) !void {
    const blue = [_]brushes.Stop{ .{ .offset = 0, .color = .rgb(0x0000ff) }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
    for (0..4) |mode| {
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0xffffff);
        try buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 2, .height = 2 });
        if (mode > 0) try buffer.pushClip(.{ .x = 0.5, .y = 0.5, .width = 1.5, .height = 1.5 });
        if (mode >= 2) try buffer.popClip();
        if (mode == 3) try buffer.popClip();
        try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 4 }, .stops = &blue } });
        if (mode == 1) try buffer.popClip();
        if (mode < 3) try buffer.popClip();
        try buffer.finish();
        try renderer.replayBuffer(buffer);
        const lower: f64 = (if (mode == 3) @as(f64, 0) else if (mode == 1) @as(f64, 0.5) else @as(f64, 0.25)) * scale;
        const upper: f64 = (if (mode == 3) @as(f64, 4) else if (mode == 1) @as(f64, 2) else @as(f64, 2.25)) * scale;
        const count: u32 = @intFromFloat(4 * scale);
        for (0..count) |y| for (0..count) |x| {
            const px: f64 = @floatFromInt(x);
            const py: f64 = @floatFromInt(y);
            const coverage = @max(0, @min(px + 1, upper) - @max(px, lower)) * @max(0, @min(py + 1, upper) - @max(py, lower));
            const channel: u32 = @intFromFloat(@round(255 * (1 - coverage)));
            const expected = (channel << 16) | (channel << 8) | 255;
            const actual = zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
            if (!closeColor(expected, actual)) {
                std.debug.print("fractional clip mode={d} scale={d} pixel={d},{d} expected={x} actual={x}\n", .{ mode, scale, x, y, expected, actual });
                return error.PixelMismatch;
            }
        };
    }
}
fn gpu(context: *anyopaque, window: *anyopaque, driver: ui.d3d11.Driver) !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const data = try fixtures();
    var pixels: [width * height * 4]u32 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const w: u32 = @intFromFloat(width * scale);
        const h: u32 = @intFromFloat(height * scale);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } };
        for (&data, 0..) |*stored, index| for ([_]bool{ false, true }) |clipped| {
            try record(&buffer, stored, clipped);
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try renderer.readPixelsForTest(w, h, pixels[0 .. w * h]);
            try check(stored, clipped, scale, pixels[0 .. w * h], index);
            renderer.end() catch |err| if (err != error.PresentationBusy) return err;
        };
    }
    const stats = renderer.gradientStats();
    try std.testing.expectEqual(1, stats.effect_creations);
    try std.testing.expectEqual(90, stats.draws);
    // D2D can retain a render result when only the consumer clip changes.
    try std.testing.expect(stats.constant_uploads > 0 and stats.constant_uploads <= stats.draws);
    try eccentric(&renderer, context, window);
    renderer.deinit();
    try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
    std.debug.print("analytic {s}: 90 full-pixel hard/steep/premultiplied/16-stop/clip/DPI cases; effect=1, constants={d}, resources=0\n", .{ @tagName(driver), stats.constant_uploads });
}
fn eccentric(renderer: *ui.d3d11.Renderer, context: *anyopaque, window: *anyopaque) !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]bool{ false, true }) |wide| for ([_]f32{ 1, 2 }) |scale| for ([_]bool{ false, true }) |steep| for ([_]bool{ false, true }) |far_end| {
        const w: u32 = if (wide) 16384 else 192;
        const h: u32 = if (wide) 192 else 16384;
        const short_center: f32 = if (far_end) 16383.5 else 0.5;
        const center: brushes.Point = if (wide) .{ .x = short_center / scale, .y = 96.5 / scale } else .{ .x = 96.5 / scale, .y = short_center / scale };
        const radius: brushes.Point = if (wide) .{ .x = 2 / scale, .y = 1000000 / scale } else .{ .x = 1000000 / scale, .y = 2 / scale };
        var stops = hard;
        if (steep) stops[2].offset = 0.500001;
        const stored = try brushes.Stored.init(.{ .radial = .{ .center = center, .radius = radius, .stops = &stops } });
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(w)) / scale, .height = @as(f32, @floatFromInt(h)) / scale }, 0xffffff);
        try buffer.gradientRect(.{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(w)) / scale, .height = @as(f32, @floatFromInt(h)) / scale }, 0, gradient(&stored));
        try renderer.begin(.{ .native_context = context, .native_window = window, .size = .{ .width = w, .height = h, .scale = scale } });
        try renderer.replayBuffer(&buffer);
        for ([_]u32{ 0, 1, 2, 16 }) |distance| {
            const along = if (far_end) 16383 - distance else distance;
            const x = if (wide) along else 96;
            const y = if (wide) 96 else along;
            const expected = stored.sample((@as(f64, @floatFromInt(x)) + 0.5) / scale, (@as(f64, @floatFromInt(y)) + 0.5) / scale).over(0xffffff, 255);
            const actual = try renderer.readPixelForTest(x, y);
            if (!closeColor(expected, actual)) {
                std.debug.print("eccentric wide={any} scale={d} steep={any} far={any} distance={d} expected={x} actual={x}\n", .{ wide, scale, steep, far_end, distance, expected, actual });
                return error.PixelMismatch;
            }
        }
        renderer.end() catch |err| if (err != error.PresentationBusy) return err;
    };
    try std.testing.expectEqual(1, renderer.gradientStats().effect_creations);
}
const FallbackState = struct {
    kind: u8 = 0,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(0xffffff);
        const value: brushes.Gradient = switch (self.kind) {
            0 => .{ .linear = .{ .start = .{ .x = -1e30 }, .end = .{ .x = 1e30 }, .stops = &hard } },
            1 => .{ .radial = .{ .center = .{}, .radius = .{ .x = 1e-30, .y = 1e-30 }, .stops = &hard } },
            else => .{ .linear = .{ .start = .{}, .end = .{ .x = width }, .stops = &hard } },
        };
        frame.gradientRect(.{ .x = 0, .y = 0, .width = width, .height = height }, 0, value);
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn fallback(app: *z.App, mode: ui.RenderMode) !void {
    var state: FallbackState = .{};
    var context = ui.Context.init(&state, FallbackState.draw, FallbackState.action);
    context.render_mode = mode;
    const window = try app.createWindow(.{});
    try context.attach(window);
    try std.testing.expect(!context.gpu_unavailable);
    state.kind = 2;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(1, context.gpu_frames);
    const surface = context.gpu_renderer.surfaceForTest().?;
    try std.testing.expect((@as(u32, @bitCast(c.GetWindowLongW(surface, c.GWL_STYLE))) & c.WS_VISIBLE) != 0);
    for (0..2) |kind| {
        state.kind = @intCast(kind);
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(kind + 2, state.draws);
        try std.testing.expectEqual(kind + 1, context.gdi_frames);
        try std.testing.expectEqual(kind + 1, context.fallbacks);
        try std.testing.expectEqual(1, context.gpu_frames);
        try std.testing.expect((@as(u32, @bitCast(c.GetWindowLongW(surface, c.GWL_STYLE))) & c.WS_VISIBLE) == 0);
        try std.testing.expectEqual(@as(c.COLORREF, 0xff0000), c.GetPixel(context.renderer.dc, 5, 5));
        try std.testing.expectEqual(0, context.command_buffer.len);
    }
    state.kind = 2;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(4, state.draws);
    try std.testing.expectEqual(2, context.gpu_frames);
    try std.testing.expect((@as(u32, @bitCast(c.GetWindowLongW(surface, c.GWL_STYLE))) & c.WS_VISIBLE) != 0);
    try std.testing.expectEqual(1, context.gpu_renderer.gradientStats().effect_creations);
    _ = try window.destroy();
    try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
    std.debug.print("analytic {s}: explicit precision rejection -> same-buffer GDI fallback, one business draw, next GPU frame recovers\n", .{@tagName(mode)});
}
pub fn main() !void {
    if (builtin.os.tag == .windows) {
        var allocator: std.heap.DebugAllocator(.{}) = .init;
        defer std.debug.assert(allocator.deinit() == .ok);
        var diagnostics: z.diagnostics.Recorder(8) = .{};
        const app = try z.App.initWithOptions(allocator.allocator(), .{ .diagnostics_sink = diagnostics.sink() });
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            const dc = c.GetDC(hwnd) orelse return error.GetDCFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            try software(dc, hwnd);
            if (ui.capabilities.gpu) {
                try gpu(dc, hwnd.?, .hardware);
                try gpu(dc, hwnd.?, .warp);
            }
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        }
        _ = try window.destroy();
        if (ui.capabilities.gpu) {
            try fallback(app, .hardware);
            try fallback(app, .warp);
            var entries: [8]z.diagnostics.Diagnostic = undefined;
            try std.testing.expectEqual(4, diagnostics.snapshot(&entries).count);
            for (entries[0..4]) |entry| {
                try std.testing.expectEqual(error.UnsupportedGradientPrecision, entry.err.?);
                try std.testing.expectEqual(.renderer, entry.domain);
                try std.testing.expectEqual(null, entry.code);
            }
        }
    } else {
        const surface = cairo_image_surface_create(0, width * 2, height * 2) orelse return error.SurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.ContextFailed;
        defer cairo_destroy(context);
        try software(context, null);
        try std.testing.expectEqual(0, zlc_test_live_patterns());
    }
    std.debug.print("analytic software: 90 full-pixel hard/steep/premultiplied/16-stop/clip/DPI cases; resources balanced\n", .{});
}
