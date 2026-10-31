const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const drawing = text.drawing;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
const background: u32 = 0x204060;
const tint: ui.Color = .{ .r = 220, .g = 110, .b = 30, .a = 128 };

fn fixture(buffer: *ui.commands.Buffer, view: drawing.PreparedTextView, clip: bool, color: ui.Color) !void {
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 192 }, background);
    if (clip) try buffer.pushClip(.{ .x = 24, .y = 20, .width = 40, .height = 30 });
    try buffer.preparedText(.{ .x = 12, .y = 12 }, view, color);
    if (clip) try buffer.popClip();
    try buffer.finish();
}
fn pixel(renderer: *ui.SoftwareRenderer, x: u32, y: u32) !u32 {
    if (builtin.os.tag == .windows) {
        const v = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (v == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((v & 255) << 16) | (v & 0xff00) | ((v >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn blend(coverage: u8) u32 {
    const alpha = (@as(u32, coverage) * tint.a + 127) / 255;
    const inverse = 255 - alpha;
    const r = (tint.r * alpha + ((background >> 16) & 255) * inverse + 127) / 255;
    const g = (tint.g * alpha + ((background >> 8) & 255) * inverse + 127) / 255;
    const b = (tint.b * alpha + (background & 255) * inverse + 127) / 255;
    return (r << 16) | (g << 8) | b;
}
fn near(expected: u32, actual: u32) !void {
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((expected >> shift) & 255);
        const b: i32 = @intCast((actual >> shift) & 255);
        if (@abs(a - b) > 2) return error.CoveragePixelMismatch;
    }
}
fn checkSoftware(renderer: *ui.SoftwareRenderer, view: drawing.PreparedTextView, clip: bool, transparent: bool) !void {
    const mask = view.coverage;
    const scale = mask.scale;
    const origin_x: i32 = @as(i32, @intFromFloat(12 * scale)) + mask.origin_x;
    const origin_y: i32 = @as(i32, @intFromFloat(12 * scale)) + mask.origin_y;
    const width: u32 = @intFromFloat(256 * scale);
    const height: u32 = @intFromFloat(192 * scale);
    var changed: usize = 0;
    for (0..height) |yy| for (0..width) |xx| {
        const x: i32 = @intCast(xx);
        const y: i32 = @intCast(yy);
        const inside = !clip or (x >= @as(i32, @intFromFloat(24 * scale)) and x < @as(i32, @intFromFloat(64 * scale)) and y >= @as(i32, @intFromFloat(20 * scale)) and y < @as(i32, @intFromFloat(50 * scale)));
        var coverage: u8 = 0;
        if (!transparent and inside and x >= origin_x and y >= origin_y and x - origin_x < mask.width and y - origin_y < mask.height) coverage = mask.pixels[@as(usize, @intCast(y - origin_y)) * mask.stride + @as(usize, @intCast(x - origin_x))];
        const actual = try pixel(renderer, @intCast(xx), @intCast(yy));
        try near(blend(coverage), actual);
        if (actual != background) changed += 1;
    };
    if (transparent) try std.testing.expectEqual(0, changed) else try std.testing.expect(changed > 0);
}
fn software(allocator: std.mem.Allocator, context: *anyopaque, window: ?*anyopaque) !void {
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const engine = try text.Engine.create(failing.allocator(), std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("אבג مرحبا a\u{0301} 👩‍👩‍👧‍👦\nक्षि 中文 xyz", .{ .width = 120, .wrap = .word_character });
    defer layout.close() catch unreachable;
    const stats = try layout.buildStats();
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const prepared = try layout.prepare(scale, .{});
        defer prepared.close() catch unreachable;
        const view = try prepared.view();
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = @intFromFloat(256 * scale), .height = @intFromFloat(192 * scale), .scale = scale } };
        try renderer.begin(paint);
        const allocations = failing.alloc_index;
        failing.fail_index = allocations;
        for (0..3) |pass| {
            try fixture(&buffer, view, pass == 1, if (pass == 2) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else tint);
            try std.testing.expect(try prepared.inUse());
            try std.testing.expectError(error.ResourceInUse, prepared.close());
            try std.testing.expectError(error.PreparedAlive, layout.close());
            try renderer.replayBuffer(&buffer);
            try checkSoftware(&renderer, view, pass == 1, pass == 2);
            buffer.reset();
            try std.testing.expect(!try prepared.inUse());
        }
        renderer.end(paint);
        var bad = view;
        bad.coverage.scale = scale + 0.25;
        try std.testing.expectError(error.PreparedDpiMismatch, renderer.preparedText(bad, .{}, tint));
        try std.testing.expectEqual(allocations, failing.alloc_index);
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(stats, try layout.buildStats());
        failing.fail_index = std.math.maxInt(usize);
        std.debug.print("prepared text software scale={d}: exact mask/tint/clip/transparent pixels, no Zig allocation or reshape\n", .{scale});
    }
    const viewport = try layout.prepare(1, .{ .viewport = .{ .x = 24, .y = 8, .width = 40, .height = 25 } });
    defer viewport.close() catch unreachable;
    const view = try viewport.view();
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 256, .height = 192, .scale = 1 } };
    try renderer.begin(paint);
    try fixture(&buffer, view, false, tint);
    try renderer.replayBuffer(&buffer);
    // Viewport at layout (24,8) maps to frame (36,20), without changing origin.
    for (0..70) |y| for (0..120) |x| if (x < 36 or x >= 76 or y < 20 or y >= 45) try std.testing.expectEqual(background, try pixel(&renderer, @intCast(x), @intCast(y)));
    buffer.reset();
    renderer.end(paint);
}
fn finish(renderer: *ui.d3d11.Renderer) !void {
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}
fn solidProbe(view: drawing.PreparedTextView) !struct { x: u32, y: u32 } {
    const mask = view.coverage;
    if (mask.width > 4 and mask.height > 4) for (2..mask.height - 2) |y| {
        for (2..mask.width - 2) |x| {
            var full = true;
            for (y - 2..y + 3) |yy| for (x - 2..x + 3) |xx| {
                if (mask.pixels[yy * mask.stride + xx] != 255) full = false;
            };
            if (full) return .{ .x = @intCast(@as(i64, @intCast(x)) + mask.origin_x + @as(i64, @intFromFloat(12 * mask.scale))), .y = @intCast(@as(i64, @intCast(y)) + mask.origin_y + @as(i64, @intFromFloat(12 * mask.scale))) };
        }
    };
    return error.NoInteriorGlyphPixel;
}
fn gpu(allocator: std.mem.Allocator, driver: ui.d3d11.Driver, context: *anyopaque, window: *anyopaque) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const layout = try engine.layout("abc אבג مرحبا\na\u{0301} 👩‍👩‍👧‍👦 xyz", .{ .width = 120, .wrap = .word_character });
    defer layout.close() catch unreachable;
    const stats = try layout.buildStats();
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .driver = driver });
    defer renderer.deinit();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const prepared = try layout.prepare(scale, .{});
        defer prepared.close() catch unreachable;
        const view = try prepared.view();
        try fixture(&buffer, view, false, tint);
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = @intFromFloat(256 * scale), .height = @intFromFloat(192 * scale), .scale = scale } };
        for (0..3) |pass| {
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try std.testing.expect((try renderer.textPixelsForTest(@intFromFloat(12 * scale), @intFromFloat(12 * scale), @intFromFloat(120 * scale), @intFromFloat(90 * scale), background)) > 20);
            for (try layout.lines()) |line| {
                if (line.start == line.end or line.width < 2) continue;
                try std.testing.expect((try renderer.textPixelsForTest(@intFromFloat((12 + @max(0, line.x)) * scale), @intFromFloat((12 + line.y) * scale), @intFromFloat(line.width * scale), @intFromFloat(line.height * scale), background)) > 0);
            }
            if (pass == 1) renderer.injectDeviceLoss();
            if (pass == 1) try std.testing.expectError(error.DeviceLost, renderer.end()) else try finish(&renderer);
        }
        // Same layout/prepared references survive recreation; no new shaping.
        try std.testing.expectEqual(stats, try layout.buildStats());
        try std.testing.expect(renderer.stats().device_losses > 0);
        buffer.reset();
    }
    const block = try engine.layout("█", .{ .size = 32 });
    defer block.close() catch unreachable;
    const prepared = try block.prepare(2, .{});
    defer prepared.close() catch unreachable;
    const view = try prepared.view();
    const probe = try solidProbe(view);
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 512, .height = 384, .scale = 2 } };
    try fixture(&buffer, view, false, tint);
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try near(blend(255), try renderer.readPixelForTest(probe.x, probe.y));
    try finish(&renderer);
    buffer.reset();
    // Clip out an interior glyph pixel, ensuring clipping applies to the
    // prepared native-layout branch and restores the surrounding clip stack.
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 192 }, background);
    try buffer.pushClip(.{ .x = 0, .y = 0, .width = @as(f32, @floatFromInt(probe.x)) / 2 - 1, .height = 192 });
    try buffer.preparedText(.{ .x = 12, .y = 12 }, view, tint);
    try buffer.popClip();
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    try std.testing.expectEqual(background, try renderer.readPixelForTest(probe.x, probe.y));
    try finish(&renderer);
    buffer.reset();
    std.debug.print("prepared text {s}: actual D2D native layout pixels, scale/resize/device loss verified\n", .{@tagName(driver)});
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            try software(allocator, dc, hwnd);
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) {
                try gpu(allocator, .hardware, dc, hwnd.?);
                try gpu(allocator, .warp, dc, hwnd.?);
                try std.testing.expectEqual(0, ui.d3d11.globalResourceCount());
            }
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 512, 384) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        try software(allocator, context, null);
    }
    try std.testing.expectEqual(text.ResourceCounts{}, text.resourceCounts());
    std.debug.print("prepared text drawing smoke passed, all native resources released\n", .{});
}
