const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const drawing = ui.drawing;
const offscreen = ui.offscreen;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_opaque(*anyopaque) c_int;

fn count() u32 {
    return if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else zlc_layer_live_objects() + zlc_test_live_image_objects();
}
fn near(expected: u32, actual: u32, tolerance: i32) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        if (@abs(@as(i32, @intCast((expected >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > tolerance) {
            std.debug.print("offscreen pixel expected={x}, actual={x}\n", .{ expected, actual });
            return error.OffscreenPixelMismatch;
        }
    }
}
fn pixel(view: drawing.ImageView, x: usize, y: usize) u32 {
    const level = view.levels[0];
    const value = level.pixels[y * level.stride + x * 4 ..][0..4];
    return @as(u32, value[0]) | (@as(u32, value[1]) << 8) | (@as(u32, value[2]) << 16) | (@as(u32, value[3]) << 24);
}
fn at(view: drawing.ImageView, scale: f32, x: f32, y: f32) u32 {
    return pixel(view, @intFromFloat(x * scale), @intFromFloat(y * scale));
}
fn white(source: u32) u32 {
    const inverse = 255 - (source >> 24);
    return 0xff000000 | (((source >> 16) & 255) + inverse) << 16 | (((source >> 8) & 255) + inverse) << 8 | ((source & 255) + inverse);
}
fn replay(renderer: anytype, snapshot: *offscreen.Snapshot, size: z.Size, context: *anyopaque, window: ?*anyopaque) !void {
    const view = try snapshot.view();
    try renderer.uploadImage(view);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, 0xffffff);
    try buffer.image(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, view, .{ .sampling = .nearest });
    try std.testing.expectError(error.ResourceInUse, snapshot.close());
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = size };
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    for (0..size.height) |y| for (0..size.width) |x| {
        const actual = if (@TypeOf(renderer.*) != ui.SoftwareRenderer) try renderer.readPixelForTest(@intCast(x), @intCast(y)) else if (builtin.os.tag == .windows) blk: {
            const value = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
            if (value == c.CLR_INVALID) return error.ReadPixelFailed;
            break :blk 0xff000000 | ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
        } else zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
        try near(white(pixel(view, x, y)), actual | 0xff000000, 3);
    };
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
    buffer.reset();
    _ = try renderer.releaseImage(view.identity);
}

fn mixed(allocator: std.mem.Allocator, app: *z.App, scale: f32) !void {
    const size: z.Size = .{ .width = @intFromFloat(64 * scale), .height = @intFromFloat(48 * scale), .scale = scale };
    const surface = try offscreen.Surface.create(app, allocator, .{ .size = size, .max_depth = 4 });
    var live = true;
    defer if (live) surface.close() catch unreachable;
    const baseline = try surface.stats();
    var mask_lease = drawing.Lease.init(std.Thread.getCurrentId());
    const mask_pixels = try allocator.alloc(u8, @as(usize, size.width) * size.height);
    defer allocator.free(mask_pixels);
    @memset(mask_pixels, 128);
    const mask: drawing.CoverageView = .{ .lease = &mask_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels, .width = size.width, .height = size.height, .stride = size.width, .origin_x = 0, .origin_y = 0, .scale = scale } };
    try surface.uploadCoverage(mask);
    var image_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var image_pixels = @as([16]u8, @bitCast(@as([4][4]u8, @splat(.{ 0, 128, 0, 128 }))));
    const image_levels = [_]drawing.ImageLevel{.{ .pixels = &image_pixels, .byte_len = image_pixels.len, .width = 2, .height = 2, .stride = 8 }};
    const image: drawing.ImageView = .{ .lease = &image_lease, .identity = try drawing.reserveRasterIdentity(), .levels = &image_levels };
    try surface.uploadImage(image);
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    var engine_live = true;
    defer if (engine_live) engine.close() catch unreachable;
    const shaped = try engine.layout("A \u{05d0}\u{05d1}", .{ .width = 32, .wrap = .word_character });
    var shaped_live = true;
    defer if (shaped_live) shaped.close() catch unreachable;
    const prepared = try shaped.prepare(scale, .{ .viewport = .{ .x = 0, .y = 0, .width = 32, .height = 16 } });
    var prepared_live = true;
    defer if (prepared_live) prepared.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 63.5, .height = 47.5 });
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.beginGroup(.{ .x = 8, .y = 8, .width = 24, .height = 24 }, .{ .opacity = 128, .mask = mask });
    try buffer.fill(.{ .x = 8, .y = 8, .width = 24, .height = 24 }, 0x0000ff);
    try buffer.roundedRect(.{ .x = 16, .y = 8, .width = 16, .height = 24 }, 0, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    try buffer.endGroup();
    try buffer.image(.{ .x = 40, .y = 8, .width = 8, .height = 8 }, image, .{ .sampling = .nearest });
    const gradient: ui.commands.Gradient = .{ .linear = .{ .start = .{ .x = 32, .y = 24 }, .end = .{ .x = 56, .y = 24 }, .stops = &.{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    } } };
    try buffer.gradientRect(.{ .x = 32, .y = 24, .width = 24, .height = 8 }, 0, gradient);
    try buffer.preparedText(.{ .x = 0, .y = 32 }, try prepared.view(), .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    try buffer.text(.{ .x = 40, .y = 32, .width = 24, .height = 16 }, "A", 0);
    try buffer.popClip();
    try buffer.finish();
    const snapshot = try surface.render(&buffer);
    defer snapshot.close() catch unreachable;
    const view = try snapshot.view();
    try view.validate();
    try near(0x80800000, at(view, scale, 4, 4), 0);
    try near(0xa0600040, at(view, scale, 12, 12), 2);
    try near(0xa0602020, at(view, scale, 20, 12), 2);
    try near(0xc0408000, at(view, scale, 44, 12), 1);
    const gx: usize = @intFromFloat(40 * scale);
    const gy: usize = @intFromFloat(28 * scale);
    const t = ((@as(f64, @floatFromInt(gx)) + 0.5) / scale - 32) / 24;
    const blue = t * 128;
    const inverse = 1 - blue / 255;
    const gradient_alpha: u32 = @intFromFloat(@round(blue + 128 * inverse));
    const gradient_red: u32 = @intFromFloat(@round(128 * inverse));
    const gradient_blue: u32 = @intFromFloat(@round(blue));
    try near((gradient_alpha << 24) | (gradient_red << 16) | gradient_blue, pixel(view, gx, gy), 1);
    const coverage = (1 - @as(f64, scale) * 0.25) * (1 - @as(f64, scale) * 0.25);
    const edge: u32 = @intFromFloat(@round(128 * coverage));
    try near((edge << 24) | (edge << 16), pixel(view, 0, 0), 2);
    var prepared_glyphs: usize = 0;
    var legacy_glyphs: usize = 0;
    for (0..size.height) |y| for (0..size.width) |x| {
        const value = pixel(view, x, y);
        inline for ([_]u5{ 0, 8, 16 }) |shift| try std.testing.expect(((value >> shift) & 255) <= value >> 24);
        if (y >= @as(usize, @intFromFloat(32 * scale)) and value != 0x80800000 and (value >> 24) > 128) {
            if (x < @as(usize, @intFromFloat(32 * scale))) prepared_glyphs += 1;
            if (x >= @as(usize, @intFromFloat(40 * scale))) legacy_glyphs += 1;
        }
    };
    try std.testing.expect(prepared_glyphs > 0);
    try std.testing.expect(legacy_glyphs > 0);
    for (0..16) |_| {
        const next = try surface.render(&buffer);
        try std.testing.expect((try next.view()).identity != view.identity);
        try std.testing.expectEqualSlices(u8, view.levels[0].pixels[0..view.levels[0].byte_len], (try next.view()).levels[0].pixels[0..view.levels[0].byte_len]);
        try next.close();
    }
    try std.testing.expectEqual(baseline.layers.native_creations, (try surface.stats()).layers.native_creations);
    buffer.reset();
    // Four explicit groups fit the advertised four slots; transparent root
    // uses no synthetic group or caller clip depth.
    for (0..4) |_| try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, .{});
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, 0x00ff00);
    for (0..4) |_| try buffer.endGroup();
    const depth = try surface.render(&buffer);
    try near(0xff00ff00, at(try depth.view(), scale, 4, 4), 0);
    try depth.close();
    buffer.reset();
    try surface.close();
    live = false;
    try mask_lease.ensureUnused();
    try image_lease.ensureUnused();
    try std.testing.expect(!(try prepared.inUse()));
    try prepared.close();
    prepared_live = false;
    try shaped.close();
    shaped_live = false;
    try engine.close();
    engine_live = false;
    @memset(mask_pixels, 0);
    @memset(&image_pixels, 0);
    try near(0xc0408000, at(try snapshot.view(), scale, 44, 12), 1);
    // Source commands and native workspace are gone. This snapshot's source
    // pixels and identity remain unchanged for every destination backend.
    if (builtin.os.tag == .windows) {
        const window = try app.createWindow(.{ .width = 160, .height = 120 });
        {
            const dc = c.GetDC(window.nativeHandle()) orelse return error.GetDcFailed;
            defer _ = c.ReleaseDC(window.nativeHandle(), dc);
            var renderer: ui.SoftwareRenderer = .{};
            defer renderer.deinit();
            try replay(&renderer, snapshot, size, dc, window.nativeHandle());
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var gpu: ui.d3d11.Renderer = .{};
                try gpu.init(.{ .driver = driver });
                defer gpu.deinit();
                try replay(&gpu, snapshot, size, dc, window.nativeHandle());
            };
        }
        _ = try window.destroy();
    } else {
        const target = cairo_image_surface_create(0, @intCast(size.width), @intCast(size.height)) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(target);
        const context = cairo_create(target) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(context);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try replay(&renderer, snapshot, size, context, null);
    }
}

fn allocationPass(allocator: std.mem.Allocator, app: *z.App) !void {
    const surface = try offscreen.Surface.create(app, allocator, .{ .size = .{ .width = 16, .height = 16, .scale = 1 } });
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    const snapshot = try surface.render(&buffer);
    try snapshot.close();
}
fn rawModes(allocator: std.mem.Allocator, context: *anyopaque) !void {
    var renderer: ui.SoftwareRenderer = .{};
    defer renderer.deinit();
    const size: z.Size = .{ .width = 8, .height = 8, .scale = 1 };
    const paint: z.Paint = .{ .native_context = context, .size = size };
    try renderer.prepareLayers(allocator, .{ .size = size });
    try renderer.prepareOffscreen();
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try renderer.beginOffscreen();
    try renderer.replayBuffer(&buffer);
    try std.testing.expectError(error.SurfaceModeMismatch, renderer.begin(paint));
    try std.testing.expectError(error.SurfaceModeMismatch, renderer.endChecked(paint));
    var pixels: [8 * 8 * 4]u8 = undefined;
    try renderer.endOffscreen(&pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128 }, pixels[0..4]);
    try std.testing.expectError(error.OffscreenSurface, renderer.releaseLayers());
    try renderer.begin(paint);
    buffer.storage[0].shape.radius = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGeometry, renderer.replayBuffer(&buffer));
    // The failed ordinary attempt changed its work mode, not its committed
    // transparent front. Release may not leak that front into a window plane.
    try std.testing.expectError(error.OffscreenSurface, renderer.releaseLayers());
    try renderer.begin(paint);
    try std.testing.expectError(error.SurfaceModeMismatch, renderer.endOffscreen(&pixels));
    try renderer.endChecked(paint);
    try renderer.releaseLayers();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(u32, 255), renderer.pixels.?[0] >> 24);
    } else try std.testing.expect(zlc_test_opaque(renderer.native.?) != 0);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        for ([_]f32{ 1, 1.5, 2 }) |scale| try mixed(allocator, app, scale);
        if (builtin.os.tag == .windows) {
            const dc = c.CreateCompatibleDC(null) orelse return error.CreateSurfaceFailed;
            defer _ = c.DeleteDC(dc);
            try rawModes(allocator, dc);
        } else {
            const surface = cairo_image_surface_create(0, 8, 8) orelse return error.CreateSurfaceFailed;
            defer cairo_surface_destroy(surface);
            const context = cairo_create(surface) orelse return error.CreateSurfaceFailed;
            defer cairo_destroy(context);
            try rawModes(allocator, context);
        }
        const baseline = count();
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{app});
        try std.testing.expectEqual(baseline, count());
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
        for (1..if (builtin.os.tag == .windows) @as(usize, 6) else @as(usize, 5)) |plane| {
            const unexpected = offscreen.Surface.createWithFailureForTest(app, allocator, .{ .size = .{ .width = 16, .height = 16, .scale = 1 } }, @intCast(plane)) catch {
                try std.testing.expectEqual(baseline, count());
                continue;
            };
            try unexpected.close();
            return error.ExpectedPreparationFailure;
        }
    }
    const before = count();
    try @import("offscreen_lifetime.zig").run(allocator);
    try std.testing.expectEqual(before, count());
    if (ui.capabilities.gpu) try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    std.debug.print("offscreen: transparent root, groups/mask/text/image, 3 DPI, independent snapshots, budgets/OOM/native failures, allocator reentry, App stop and refs=0 passed\n", .{});
}
