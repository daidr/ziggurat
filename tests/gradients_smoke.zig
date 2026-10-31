const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const commands = ui.commands;
const brushes = commands.brushes;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_patterns() u32;
extern fn zlc_test_opaque(*anyopaque) c_int;
const transparent_blue = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
const transparent_half = [_]brushes.Stop{ .{ .offset = 0, .color = .{ .r = 0, .g = 255, .b = 0, .a = 0 } }, .{ .offset = 0.5, .color = .{ .r = 255, .g = 0, .b = 0, .a = 128 } }, .{ .offset = 1, .color = .rgb(0x0000ff) } };
const near_stops = [_]brushes.Stop{ .{ .offset = 0.5, .color = .rgb(0xff0000) }, .{ .offset = 0.500001, .color = .rgb(0x00ff00) } };
fn transparentFixture(buffer: *commands.Buffer) !void {
    buffer.reset();
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 192, .height = 128 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 192 }, .stops = &.{ .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } }, .{ .offset = 1, .color = .{ .r = 0, .g = 255, .b = 0, .a = 0 } } } } });
}
fn fixture(buffer: *commands.Buffer) !void {
    buffer.reset();
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 64, .height = 32 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 64 }, .stops = &transparent_blue } });
    try buffer.gradientRect(.{ .x = 64, .y = 0, .width = 64, .height = 32 }, 0, .{ .linear = .{ .start = .{ .x = 64 }, .end = .{ .x = 128 }, .stops = &transparent_half } });
    try buffer.gradientRect(.{ .x = 130, .y = 0, .width = 40, .height = 28 }, 8, .{ .linear = .{ .start = .{ .x = 130 }, .end = .{ .x = 170 }, .stops = &transparent_blue } });
    try buffer.gradientRect(.{ .x = 0, .y = 50, .width = 64, .height = 48 }, 5, .{ .radial = .{ .center = .{ .x = 32, .y = 74 }, .radius = .{ .x = 28, .y = 14 }, .stops = &transparent_half } });
    try buffer.gradientStrokeRect(.{ .x = 80, .y = 50, .width = 40, .height = 30 }, 8, 6, .{ .linear = .{ .start = .{ .x = 80 }, .end = .{ .x = 120 }, .stops = &transparent_blue } });
    try buffer.pushClip(.{ .x = 136, .y = 52, .width = 12, .height = 12 });
    try buffer.gradientRect(.{ .x = 128, .y = 44, .width = 40, .height = 40 }, 6, .{ .linear = .{ .start = .{ .x = 128 }, .end = .{ .x = 168 }, .stops = &transparent_blue } });
    try buffer.popClip();
    try buffer.gradientRect(.{ .x = 0, .y = 100, .width = 64, .height = 20 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 64 }, .stops = &.{ transparent_blue[0], transparent_blue[0], transparent_blue[1] } } });
    try buffer.finish();
}
fn near(expected: u32, actual: u32) !void {
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((expected >> shift) & 255);
        const b: i32 = @intCast((actual >> shift) & 255);
        if (@abs(a - b) > 3) {
            std.debug.print("gradient expected={x:0>6} actual={x:0>6}\n", .{ expected & 0xffffff, actual & 0xffffff });
            return error.PixelMismatch;
        }
    }
}
fn reference(stops: []const brushes.Stop, parameter: f64) u32 {
    const stored = brushes.Stored.init(.{ .linear = .{ .start = .{}, .end = .{ .x = 1 }, .stops = stops } }) catch unreachable;
    return stored.sample(parameter, 0).over(0xffffff, 255);
}
fn check(reader: anytype, scale: f32) !void {
    const center = 0.5 / @as(f64, scale);
    try near(reference(&transparent_blue, (31 + center) / 64), try reader.pixel(31, 15));
    // A transparent colored stop must never leak its hidden RGB channels.
    const blue = try reader.pixel(31, 15);
    try std.testing.expectEqual((blue >> 16) & 255, (blue >> 8) & 255);
    for ([_]u32{ 80, 95, 112 }) |x| try near(reference(&transparent_half, (@as(f64, @floatFromInt(x)) + center - 64) / 64), try reader.pixel(x, 15));
    const radial_x = (14 + center) / 28;
    const radial_y = center / 14;
    try near(reference(&transparent_half, @sqrt(radial_x * radial_x + radial_y * radial_y)), try reader.pixel(46, 74));
    try near(0x0000ff, try reader.pixel(62, 74));
    try near(reference(&transparent_blue, (20 + center) / 40), try reader.pixel(100, 51));
    try near(0xffffff, try reader.pixel(100, 65));
    try near(reference(&transparent_blue, (12 + center) / 40), try reader.pixel(140, 58));
    try near(0xffffff, try reader.pixel(150, 58));
    try near(0xffffff, try reader.pixel(130, 0));
    try near(reference(&transparent_blue, (31 + center) / 64), try reader.pixel(31, 110));
    // At a partially covered rounded edge all channels remain on the
    // premultiplied blue-over-white line, including alpha-zero red stops.
    const edge = try reader.pixel(132, 2);
    try std.testing.expectEqual((edge >> 16) & 255, (edge >> 8) & 255);
    try std.testing.expectEqual(@as(u32, 255), edge & 255);
}
const SoftwareReader = struct {
    renderer: *ui.SoftwareRenderer,
    scale: f32,
    fn pixel(self: @This(), x: u32, y: u32) !u32 {
        if (builtin.os.tag == .windows) {
            const rgb = c.GetPixel(self.renderer.dc, @intFromFloat(@as(f32, @floatFromInt(x)) * self.scale), @intFromFloat(@as(f32, @floatFromInt(y)) * self.scale));
            if (rgb == c.CLR_INVALID) return error.ReadPixelFailed;
            return ((rgb & 255) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 255);
        } else return zlc_test_pixel(self.renderer.native.?, x, y);
    }
};
fn animations(buffer: *commands.Buffer, index: usize) !void {
    buffer.reset();
    const delta: f32 = @floatFromInt(index);
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 192, .height = 128 }, 5, .{ .linear = .{ .start = .{ .x = delta }, .end = .{ .x = 64 + delta, .y = delta * 0.25 }, .stops = &transparent_blue } });
    try buffer.gradientRect(.{ .x = 10, .y = 10, .width = 100, .height = 80 }, 4, .{ .radial = .{ .center = .{ .x = 32 + delta, .y = 40 }, .radius = .{ .x = 28 + delta, .y = 14 + delta * 0.5 }, .stops = &transparent_half } });
}
fn steepProbe(buffer: *commands.Buffer) !void {
    buffer.reset();
    try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 192, .height = 128 }, 0, .{ .linear = .{ .start = .{ .x = 96.25 - 4096 }, .end = .{ .x = 96.25 + 4096 }, .stops = &near_stops } });
}
fn eviction(buffer: *commands.Buffer, start: usize) !void {
    buffer.reset();
    for (start..start + 20) |index| {
        var stops = transparent_blue;
        stops[1].color = .{ .r = @intCast(index), .g = 0, .b = 255 };
        try buffer.gradientRect(.{ .x = 0, .y = 0, .width = 192, .height = 128 }, 0, .{ .linear = .{ .start = .{}, .end = .{ .x = 192 }, .stops = &stops } });
    }
}
fn software(context: *anyopaque, window: ?*anyopaque) !void {
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: commands.Buffer = .{};
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = @intFromFloat(192 * scale), .height = @intFromFloat(128 * scale), .scale = scale } };
        try renderer.begin(paint);
        try transparentFixture(&buffer);
        const before = if (builtin.os.tag == .linux) renderer.brushStats() else {};
        try renderer.replayBuffer(&buffer);
        try near(0xffffff, try (SoftwareReader{ .renderer = &renderer, .scale = scale }).pixel(31, 15));
        if (builtin.os.tag == .linux) try std.testing.expectEqual(before, renderer.brushStats());
        try fixture(&buffer);
        // Deliberately no background fill: a newly created surface is opaque white.
        try renderer.replayBuffer(&buffer);
        try check(SoftwareReader{ .renderer = &renderer, .scale = scale }, scale);
        if (builtin.os.tag == .linux) try std.testing.expectEqual(1, zlc_test_opaque(renderer.native.?));
        try std.testing.expectError(error.MissingResources, renderer.replay(buffer.commands(), buffer.textBytes()));
        if (builtin.os.tag == .linux) {
            const stats = renderer.brushStats();
            for (0..8) |index| {
                try animations(&buffer, index);
                try renderer.replayBuffer(&buffer);
            }
            try std.testing.expectEqual(stats, renderer.brushStats());
        }
        try steepProbe(&buffer);
        try renderer.replayBuffer(&buffer);
        try near(0xff0000, try (SoftwareReader{ .renderer = &renderer, .scale = scale }).pixel(95, 110));
        try near(0x00ff00, try (SoftwareReader{ .renderer = &renderer, .scale = scale }).pixel(97, 110));
        if (builtin.os.tag == .linux) try std.testing.expectEqual(1, zlc_test_opaque(renderer.native.?));
        renderer.end(paint);
    }
    if (builtin.os.tag == .linux) {
        for (0..2) |index| {
            try eviction(&buffer, index * 20);
            try renderer.replayBuffer(&buffer);
        }
        try std.testing.expectEqual(0, renderer.brushStats().cached);
        try std.testing.expectEqual(0, renderer.brushStats().creations);
        renderer.deinit();
        try std.testing.expectEqual(0, zlc_test_live_patterns());
    }
}
const GpuReader = struct {
    renderer: *ui.d3d11.Renderer,
    scale: f32,
    fn pixel(self: @This(), x: u32, y: u32) !u32 {
        return self.renderer.readPixelForTest(@intFromFloat(@as(f32, @floatFromInt(x)) * self.scale), @intFromFloat(@as(f32, @floatFromInt(y)) * self.scale));
    }
};
fn finish(renderer: *ui.d3d11.Renderer) !void {
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}
fn gpu(driver: ui.d3d11.Driver, context: *anyopaque, window: *anyopaque) !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: commands.Buffer = .{};
    var paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 192, .height = 128, .scale = 1 } };
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        paint.size = .{ .width = @intFromFloat(192 * scale), .height = @intFromFloat(128 * scale), .scale = scale };
        try renderer.begin(paint);
        try transparentFixture(&buffer);
        const before = renderer.brushStats();
        try renderer.replayBuffer(&buffer);
        try near(0xffffff, try (GpuReader{ .renderer = &renderer, .scale = scale }).pixel(31, 15));
        try std.testing.expectEqual(before, renderer.brushStats());
        try fixture(&buffer);
        try renderer.replayBuffer(&buffer);
        try check(GpuReader{ .renderer = &renderer, .scale = scale }, scale);
        try finish(&renderer);
        const stats = renderer.gradientStats();
        for (0..8) |index| {
            try animations(&buffer, index);
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try finish(&renderer);
        }
        try std.testing.expectEqual(stats.effect_creations, renderer.gradientStats().effect_creations);
        try std.testing.expect(renderer.gradientStats().draws >= stats.draws + 16);
        try steepProbe(&buffer);
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try near(0xff0000, try (GpuReader{ .renderer = &renderer, .scale = scale }).pixel(95, 110));
        try near(0x00ff00, try (GpuReader{ .renderer = &renderer, .scale = scale }).pixel(97, 110));
        try finish(&renderer);
    }
    for (0..2) |index| {
        try eviction(&buffer, index * 20);
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try finish(&renderer);
    }
    // Forty different descriptors in two buffers reuse the one device effect.
    try std.testing.expectEqual(0, renderer.brushStats().cached);
    try std.testing.expectEqual(1, renderer.gradientStats().effect_creations);
    try std.testing.expect(renderer.gradientStats().constant_uploads > 0);
    renderer.injectDeviceLoss();
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try std.testing.expectError(error.DeviceLost, renderer.end());
    try std.testing.expectEqual(0, renderer.brushStats().cached);
    try fixture(&buffer);
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try check(GpuReader{ .renderer = &renderer, .scale = 2 }, 2);
    try finish(&renderer);
    const stats = renderer.gradientStats();
    try std.testing.expectEqual(2, stats.effect_creations);
    try std.testing.expectEqual(1, stats.device_restores);
    renderer.deinit();
    try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
    std.debug.print("gradients {s}: premultiplied pixels/DPI/clip/anchor animation, effects={d} restored={d} draws={d} constants={d}; resources=0\n", .{ @tagName(driver), stats.effect_creations, stats.device_restores, stats.draws, stats.constant_uploads });
}
pub fn main() !void {
    std.debug.print("gradient storage: Command={d}B, Buffer={d}B, brush table={d}B\n", .{ @sizeOf(commands.Command), @sizeOf(commands.Buffer), @sizeOf(brushes.Stored) * brushes.max_brushes });
    if (builtin.os.tag == .windows) {
        var allocator: std.heap.DebugAllocator(.{}) = .init;
        defer std.debug.assert(allocator.deinit() == .ok);
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            try software(dc, hwnd);
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) {
                try gpu(.hardware, dc, hwnd.?);
                try gpu(.warp, dc, hwnd.?);
            }
        }
        _ = try window.destroy();
        std.debug.print("gradients GDI: first-frame opaque/source-over/rounded stroke/clip/DPI verified; GDI stable\n", .{});
    } else {
        const surface = cairo_image_surface_create(0, 384, 256) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        try software(context, null);
        std.debug.print("gradients Cairo: first-frame opaque/premultiplied pixels/clip/DPI/anchor cache verified; patterns=0\n", .{});
    }
}
