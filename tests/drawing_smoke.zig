const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const commands = ui.commands;
const Color = commands.Color;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlc_test_pixel(*anyopaque, u32, u32) u32;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
const background: u32 = 0x204060;

fn fixture(buffer: *commands.Buffer) !void {
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 192, .height = 128 }, background);
    try buffer.roundedRect(.{ .x = 2, .y = 2, .width = 20, .height = 16 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.roundedRect(.{ .x = 10, .y = 8, .width = 20, .height = 16 }, 0, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    try buffer.roundedRect(.{ .x = 40, .y = 4, .width = 28, .height = 24 }, 8, Color.rgb(0xff0000));
    try buffer.strokeRect(.{ .x = 78, .y = 4, .width = 28, .height = 24 }, 6, 3, Color.rgb(0x00ffff));
    // The outer contour must remain identical when the stroke is thicker than
    // the radius. A centerline-only native stroke would square these corners.
    try buffer.strokeRect(.{ .x = 120, .y = 4, .width = 24, .height = 24 }, 3, 8, Color.rgb(0xff00ff));
    try buffer.roundedRect(.{ .x = 150, .y = 4, .width = 24, .height = 24 }, 3, Color.rgb(0xff00ff));
    try buffer.pushClip(.{ .x = 4, .y = 42, .width = 12, .height = 12 });
    try buffer.roundedRect(.{ .x = 0, .y = 38, .width = 32, .height = 24 }, 10, .{ .r = 255, .g = 255, .b = 0, .a = 128 });
    try buffer.popClip();
    try buffer.roundedRect(.{ .x = 40, .y = 40, .width = 20, .height = 20 }, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try buffer.roundedRect(.{ .x = 70.25, .y = 40.25, .width = 20.5, .height = 18.5 }, 4.25, Color.rgb(0x00ff00));
    try buffer.strokeRect(.{ .x = 105, .y = 40, .width = 20, .height = 10 }, 4, 999, Color.rgb(0xff0000));
    try buffer.strokeRect(.{ .x = 140, .y = 40, .width = 20, .height = 20 }, 0, 3, .{ .r = 0, .g = 255, .b = 255, .a = 128 });
    try buffer.roundedRect(.{ .x = -4, .y = 75, .width = 12, .height = 12 }, 2, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 0, .height = 0 }, 4, Color.rgb(0));
    try buffer.finish();
}

fn blend(rgb: u32, color: Color) u32 {
    const alpha: u32 = color.a;
    const inverse = 255 - alpha;
    const red = (@as(u32, color.r) * alpha + ((rgb >> 16) & 255) * inverse + 127) / 255;
    const green = (@as(u32, color.g) * alpha + ((rgb >> 8) & 255) * inverse + 127) / 255;
    const blue = (@as(u32, color.b) * alpha + (rgb & 255) * inverse + 127) / 255;
    return (red << 16) | (green << 8) | blue;
}
fn near(expected: u32, actual: u32, tolerance: u32) !void {
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((expected >> shift) & 255);
        const b: i32 = @intCast((actual >> shift) & 255);
        if (@abs(a - b) > tolerance) {
            std.debug.print("pixel expected={x:0>6} actual={x:0>6} tolerance={d}\n", .{ expected, actual, tolerance });
            return error.PixelMismatch;
        }
    }
}
fn check(reader: anytype) !void {
    const red = blend(background, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    const overlap = blend(red, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    const probes = .{
        .{ 6, 6, red },                                                         .{ 14, 10, overlap },                                                       .{ 54, 10, 0xff0000 },    .{ 40, 4, background },
        .{ 92, 5, 0x00ffff },                                                   .{ 92, 12, background },                                                    .{ 78, 4, background },   .{ 8, 47, blend(background, .{ .r = 255, .g = 255, .b = 0, .a = 128 }) },
        .{ 20, 47, background },                                                .{ 45, 45, background },                                                    .{ 80, 49, 0x00ff00 },    .{ 115, 45, 0xff0000 },
        .{ 0, 80, blend(background, .{ .r = 0, .g = 255, .b = 0, .a = 128 }) }, .{ 140, 40, blend(background, .{ .r = 0, .g = 255, .b = 255, .a = 128 }) }, .{ 150, 50, background },
    };
    inline for (probes) |probe| near(probe[2], try reader.pixel(probe[0], probe[1]), 2) catch |err| {
        std.debug.print("at DIP ({d},{d})\n", .{ probe[0], probe[1] });
        return err;
    };
    // Native rounded primitives and path tessellation have different edge AA.
    // Keep interior/color probes strict; allow 10% coverage at curved edges.
    for (0..3) |offset| try near(try reader.pixel(@intCast(120 + offset), 4), try reader.pixel(@intCast(150 + offset), 4), 26);
    try std.testing.expect((try reader.pixel(120, 4)) != 0xff00ff);
}
const SoftwareReader = struct {
    renderer: *ui.SoftwareRenderer,
    scale: f32,
    fn pixel(self: @This(), x: u32, y: u32) !u32 {
        if (builtin.os.tag == .windows) {
            const value = c.GetPixel(self.renderer.dc, @intFromFloat(@as(f32, @floatFromInt(x)) * self.scale), @intFromFloat(@as(f32, @floatFromInt(y)) * self.scale));
            if (value == c.CLR_INVALID) return error.ReadPixelFailed;
            return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
        } else return zlc_test_pixel(self.renderer.native.?, x, y);
    }
};
const GpuReader = struct {
    renderer: *ui.d3d11.Renderer,
    scale: f32,
    fn pixel(self: @This(), x: u32, y: u32) !u32 {
        return self.renderer.readPixelForTest(@intFromFloat(@as(f32, @floatFromInt(x)) * self.scale), @intFromFloat(@as(f32, @floatFromInt(y)) * self.scale));
    }
};
fn software(paint_context: *anyopaque, window: ?*anyopaque) !void {
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: commands.Buffer = .{};
    try fixture(&buffer);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const paint: z.Paint = .{ .native_context = paint_context, .native_window = window, .size = .{ .width = @intFromFloat(192 * scale), .height = @intFromFloat(128 * scale), .scale = scale } };
        try renderer.begin(paint);
        for (0..4) |_| {
            try renderer.replay(buffer.commands(), buffer.textBytes());
            try check(SoftwareReader{ .renderer = &renderer, .scale = scale });
        }
        renderer.end(paint);
        var invalid = paint;
        invalid.size.width = std.math.maxInt(u32);
        try std.testing.expectError(error.InvalidGeometry, renderer.begin(invalid));
        invalid.size = .{ .width = 32768, .height = 32768, .scale = scale };
        try std.testing.expectError(error.InvalidGeometry, renderer.begin(invalid));
        invalid = paint;
        invalid.size.scale = 1e30;
        try std.testing.expectError(error.InvalidGeometry, renderer.begin(invalid));
        try std.testing.expect(renderer.hasSurface());
        const malformed = [_]commands.Command{ .{ .push_clip = .{ .x = 1, .y = 1, .width = 10, .height = 10 } }, .{ .shape = .{ .bounds = .{ .x = 0, .y = 0, .width = 20, .height = 20 }, .color = Color.rgb(0), .radius = std.math.nan(f32) } } };
        try std.testing.expectError(error.InvalidGeometry, renderer.replay(&malformed, ""));
        try renderer.replay(buffer.commands(), buffer.textBytes());
        try check(SoftwareReader{ .renderer = &renderer, .scale = scale });
    }
    renderer.deinit();
    renderer.deinit();
}
fn finish(renderer: *ui.d3d11.Renderer) !void {
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}
fn gpu(driver: ui.d3d11.Driver, context: *anyopaque, window: *anyopaque) !void {
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: commands.Buffer = .{};
    try fixture(&buffer);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = @intFromFloat(192 * scale), .height = @intFromFloat(128 * scale), .scale = scale } };
        try renderer.begin(paint);
        try renderer.replay(buffer.commands(), buffer.textBytes());
        try check(GpuReader{ .renderer = &renderer, .scale = scale });
        try finish(&renderer);
        const warmed = renderer.geometryStats();
        try std.testing.expectEqual(2, warmed.cached);
        for (0..5) |_| {
            try renderer.begin(paint);
            try renderer.replay(buffer.commands(), buffer.textBytes());
            try finish(&renderer);
        }
        try std.testing.expectEqual(warmed.creations, renderer.geometryStats().creations);
        try std.testing.expectEqual(warmed.evictions, renderer.geometryStats().evictions);
        var invalid = paint;
        invalid.size.scale = 1e30;
        try std.testing.expectError(error.InvalidGeometry, renderer.begin(invalid));
        try std.testing.expectEqual(warmed, renderer.geometryStats());
        try std.testing.expect(!renderer.active);
    }
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 384, .height = 256, .scale = 2 } };
    const warmed = renderer.geometryStats();
    buffer.reset();
    try buffer.strokeRect(.{ .x = 5, .y = 60, .width = 28, .height = 24 }, 6, 3, Color.rgb(0x00ffff));
    try renderer.begin(paint);
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try finish(&renderer);
    try std.testing.expectEqual(warmed, renderer.geometryStats());
    buffer.reset();
    for (0..40) |index| try buffer.strokeRect(.{ .x = @floatFromInt(index), .y = 70, .width = @as(f32, @floatFromInt(index)) + 20, .height = 30 }, 7, 2, Color.rgb(0x8090a0));
    try renderer.begin(paint);
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try finish(&renderer);
    try std.testing.expectEqual(ui.d3d11.geometry_cache_capacity, renderer.geometryStats().cached);
    try std.testing.expect(renderer.geometryStats().evictions >= 10);
    renderer.injectDeviceLoss();
    try renderer.begin(paint);
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try std.testing.expectError(error.DeviceLost, renderer.end());
    try std.testing.expectEqual(0, renderer.geometryStats().cached);
    try fixture(&buffer);
    try renderer.begin(paint);
    try renderer.replay(buffer.commands(), buffer.textBytes());
    try check(GpuReader{ .renderer = &renderer, .scale = 2 });
    try finish(&renderer);
    const stats = renderer.geometryStats();
    std.debug.print("drawing {s}: shapes/alpha/clip/scales verified; geometry created={d} evicted={d} cached={d}\n", .{ @tagName(driver), stats.creations, stats.evictions, stats.cached });
    renderer.deinit();
    try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
}

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        var allocator: std.heap.DebugAllocator(.{}) = .init;
        defer std.debug.assert(allocator.deinit() == .ok);
        const app = try z.App.init(allocator.allocator());
        defer app.deinit();
        const window = try app.createWindow(.{});
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        {
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before_gdi = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            try software(dc, hwnd);
            try std.testing.expectEqual(before_gdi, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) {
                try gpu(.hardware, dc, hwnd.?);
                try gpu(.warp, dc, hwnd.?);
            }
        }
        _ = try window.destroy();
        std.debug.print("drawing GDI: rounded/inside stroke/alpha/clip/scales=1,1.5,2 verified, GDI handles stable\n", .{});
    } else if (builtin.os.tag == .linux) {
        const surface = cairo_image_surface_create(0, 384, 256) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        try software(context, null);
        std.debug.print("drawing Cairo: rounded/inside stroke/alpha/clip/scales=1,1.5,2 verified\n", .{});
    } else return error.UnsupportedPlatform;
}
