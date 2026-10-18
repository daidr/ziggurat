const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const resources = ui.gpu_resources;
const Surface = ui.gpu_offscreen.Surface;
const gpu = ui.d3d11;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
fn near(want: u32, got: u32) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const a: i32 = @intCast((want >> shift) & 255);
        const b: i32 = @intCast((got >> shift) & 255);
        if (@abs(a - b) > 1) {
            std.debug.print("GPU offscreen pixel expected={x}, actual={x}\n", .{ want, got });
            return error.PixelMismatch;
        }
    }
}
fn basic(allocator: std.mem.Allocator, driver: resources.Driver, scale: f32) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const side: u32 = @intFromFloat(64 * scale);
    const size: z.Size = .{ .width = side, .height = side, .scale = scale };
    const surface = try Surface.create(domain, allocator, .{ .size = size, .max_depth = 2, .resident_bytes = 0 });
    var surface_alive = true;
    defer if (surface_alive) surface.close() catch unreachable;
    try expectError(error.NoFrame, surface.snapshot());
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.roundedRect(.{ .x = 8, .y = 8, .width = 40, .height = 32 }, 4, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try surface.render(&buffer);
    var pixels: [128 * 128]u32 = undefined;
    try surface.readFrontForTest(pixels[0 .. side * side]);
    try near(0, pixels[0]);
    const middle: usize = @intFromFloat(16 * scale);
    try near(0x80800000, pixels[middle * side + middle]);
    const first = try surface.snapshot();
    defer first.close() catch unreachable;
    const old_view = try first.view();
    try equal(@as(u32, 1), old_view.levels);
    // Reusing front/work must never mutate the exported bitmap.
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x00ff00);
    try surface.render(&buffer);
    const warm = (try surface.stats()).layers.native_creations;
    for (0..8) |_| try surface.render(&buffer);
    try equal(warm, (try surface.stats()).layers.native_creations);
    try surface.close();
    surface_alive = false;
    try equal(@as(usize, 0), (try domain.stats()).workspace_reservation);
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    defer _ = window.destroy() catch false;
    {
        const dc = c.GetDC(window.nativeHandle()) orelse return error.NoSurface;
        defer _ = c.ReleaseDC(window.nativeHandle(), dc);
        var renderer: gpu.Renderer = .{};
        try renderer.init(.{ .domain = domain });
        defer renderer.deinit();
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x0000ff);
        try buffer.texture(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, old_view, .{});
        try renderer.begin(.{ .native_window = window.nativeHandle(), .native_context = dc, .size = size });
        try renderer.replayBuffer(&buffer);
        try near(0x0080007f, try renderer.readPixelForTest(@intCast(middle), @intCast(middle)));
        try near(0x000000ff, try renderer.readPixelForTest(0, 0));
        renderer.end() catch |err| if (err != error.PresentationBusy) return err;
        buffer.reset();
    }
}
fn transactions(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp, .texture_bytes = 256 * 1024 });
    const size: z.Size = .{ .width = 32, .height = 32, .scale = 1 };
    const baseline = try domain.stats();
    try expectError(error.GraphicsFailed, Surface.createWithFailureForTest(domain, allocator, .{ .size = size, .max_depth = 1, .resident_bytes = 0 }, 2));
    try equal(baseline.native_objects, (try domain.stats()).native_objects);
    try equal(baseline.total_reservation, (try domain.stats()).total_reservation);
    const surface = try Surface.create(domain, allocator, .{ .size = size, .max_depth = 1, .resident_bytes = 0 });
    var buffer: ui.commands.Buffer = .{};
    try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, 0, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    try surface.render(&buffer);
    const before = try domain.stats();
    try surface.injectSnapshotFailureForTest(2);
    try expectError(error.OutOfMemory, surface.snapshot());
    try equal(before.pixel_bytes, (try domain.stats()).pixel_bytes);
    try equal(before.native_objects, (try domain.stats()).native_objects);
    const first = try surface.snapshot();
    buffer.reset();
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try first.view(), .{});
    try surface.render(&buffer); // same-domain immutable snapshot as input
    buffer.reset();
    try surface.injectDeviceLossForTest();
    try expectError(error.DeviceLost, surface.render(&buffer));
    try equal(@as(usize, 0), (try surface.stats()).workspace_actual);
    try expect((try surface.stats()).workspace_reserved != 0);
    try expectError(error.DomainDeviceLost, surface.snapshot());
    try domain.recreate();
    try expectError(error.StaleSurfaceGeneration, surface.snapshot());
    try surface.render(&buffer);
    const restored = try surface.snapshot();
    try expectError(error.StaleTextureGeneration, first.view());
    app.quit();
    try app.finishShutdown();
    try equal(@as(usize, 0), (try surface.stats()).workspace_actual);
    try expectError(error.Closed, surface.render(&buffer));
    try expectError(error.Closed, surface.snapshot());
    app.deinit();
    try surface.close();
    try first.close();
    try restored.close();
    try domain.close();
    try equal(@as(u32, 0), gpu.globalResourceCount());
}
fn mixed(allocator: std.mem.Allocator, driver: resources.Driver, scale: f32) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const size: z.Size = .{ .width = @intFromFloat(64 * scale), .height = @intFromFloat(48 * scale), .scale = scale };
    const surface = try Surface.create(domain, allocator, .{ .size = size, .max_depth = 4, .resident_bytes = 1024 * 1024 });
    var alive = true;
    defer if (alive) surface.close() catch unreachable;
    var mask_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const mask_pixels = try allocator.alloc(u8, @as(usize, size.width) * size.height);
    defer allocator.free(mask_pixels);
    @memset(mask_pixels, 128);
    const mask: ui.drawing.CoverageView = .{ .lease = &mask_lease, .identity = try ui.drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels, .width = size.width, .height = size.height, .stride = size.width, .origin_x = 0, .origin_y = 0, .scale = scale } };
    var image_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    var green = [_]u8{ 0, 128, 0, 128 } ** 4;
    const levels = [_]ui.drawing.ImageLevel{.{ .pixels = &green, .width = 2, .height = 2, .stride = 8, .byte_len = 16 }};
    const image: ui.drawing.ImageView = .{ .lease = &image_lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &levels };
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    var engine_alive = true;
    defer if (engine_alive) engine.close() catch unreachable;
    const shaped = try engine.layout("A \u{05d0}\u{05d1}", .{ .width = 32, .wrap = .word_character });
    var layout_alive = true;
    defer if (layout_alive) shaped.close() catch unreachable;
    const prepared = try shaped.prepare(scale, .{ .viewport = .{ .x = 0, .y = 0, .width = 32, .height = 16 } });
    var prepared_alive = true;
    defer if (prepared_alive) prepared.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    const canvas: ui.Rect = .{ .x = 0, .y = 0, .width = 64, .height = 48 };
    try buffer.pushClip(.{ .x = 0.25, .y = 0.25, .width = 63.5, .height = 47.5 });
    try buffer.beginGroup(canvas, .{});
    try buffer.roundedRect(canvas, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.beginGroup(.{ .x = 8, .y = 8, .width = 24, .height = 24 }, .{ .opacity = 128, .mask = mask });
    try buffer.fill(.{ .x = 8, .y = 8, .width = 24, .height = 24 }, 0x0000ff);
    try buffer.roundedRect(.{ .x = 16, .y = 8, .width = 16, .height = 24 }, 0, .{ .r = 0, .g = 255, .b = 0, .a = 128 });
    try buffer.endGroup();
    try buffer.image(.{ .x = 40, .y = 8, .width = 8, .height = 8 }, image, .{ .sampling = .nearest });
    try buffer.gradientRect(.{ .x = 32, .y = 24, .width = 24, .height = 8 }, 0, .{ .linear = .{ .start = .{ .x = 32, .y = 24 }, .end = .{ .x = 56, .y = 24 }, .stops = &.{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    } } });
    try buffer.preparedText(.{ .x = 0, .y = 32 }, try prepared.view(), .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    try buffer.text(.{ .x = 40, .y = 32, .width = 24, .height = 16 }, "A", 0);
    try buffer.endGroup();
    try buffer.popClip();
    try expectError(error.ImageNotUploaded, surface.render(&buffer));
    try expect(!(try surface.stats()).has_frame);
    try surface.uploadImage(image);
    try expectError(error.CoverageNotUploaded, surface.render(&buffer));
    try surface.uploadCoverage(mask);
    try surface.render(&buffer);
    var pixels: [128 * 128]u32 = undefined;
    const plane = pixels[0 .. size.width * size.height];
    try surface.readFrontForTest(plane);
    const at = struct {
        fn pixel(values: []const u32, extent: z.Size, x: f32, y: f32) u32 {
            return values[@as(usize, @intFromFloat(y * extent.scale)) * extent.width + @as(usize, @intFromFloat(x * extent.scale))];
        }
    }.pixel;
    try near(0x80800000, at(plane, size, 4, 4));
    try near(0xa0600040, at(plane, size, 12, 12));
    try near(0xa0602020, at(plane, size, 20, 12));
    try near(0xc0408000, at(plane, size, 44, 12));
    const area = (1 - @as(f64, scale) * 0.25) * (1 - @as(f64, scale) * 0.25);
    const edge: u32 = @intFromFloat(@round(128 * area));
    try near((edge << 24) | (edge << 16), plane[0]);
    var glyphs: [2]usize = .{ 0, 0 };
    for (0..size.height) |y| for (0..size.width) |x| {
        const value = plane[y * size.width + x];
        inline for ([_]u5{ 0, 8, 16 }) |shift| try expect(((value >> shift) & 255) <= value >> 24);
        if (y >= @as(usize, @intFromFloat(32 * scale)) and value >> 24 > 128) {
            if (x < @as(usize, @intFromFloat(32 * scale))) glyphs[0] += 1;
            if (x >= @as(usize, @intFromFloat(40 * scale))) glyphs[1] += 1;
        }
    };
    try expect(glyphs[0] > 0 and glyphs[1] > 0);
    const snapshot = try surface.snapshot();
    defer snapshot.close() catch unreachable;
    const before = try surface.stats();
    for (0..8) |_| try surface.render(&buffer);
    try equal(before.layers.native_creations, (try surface.stats()).layers.native_creations);
    // A failed new frame retains its previous alpha front.
    var rejected: ui.commands.Buffer = .{};
    defer rejected.reset();
    try rejected.fill(canvas, 0x00ff00);
    rejected.storage[rejected.len] = .pop_clip;
    rejected.len += 1;
    try expectError(error.ClipStackEmpty, surface.render(&rejected));
    var actual: [128 * 128]u32 = undefined;
    try surface.readFrontForTest(actual[0..plane.len]);
    try std.testing.expectEqualSlices(u32, plane, actual[0..plane.len]);
    buffer.reset();
    for (0..4) |_| try buffer.beginGroup(canvas, .{});
    try buffer.fill(canvas, 0x00ff00);
    for (0..4) |_| try buffer.endGroup();
    try surface.render(&buffer);
    buffer.reset();
    try surface.close();
    alive = false;
    try image_lease.ensureUnused();
    try mask_lease.ensureUnused();
    try prepared.close();
    prepared_alive = false;
    try shaped.close();
    layout_alive = false;
    try engine.close();
    engine_alive = false;
    try (try snapshot.view()).validate();
    try expect(text.resourceCounts().references == 0);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    for ([_]resources.Driver{ .hardware, .warp }) |driver| for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try basic(allocator, driver, scale);
        try mixed(allocator, driver, scale);
        try equal(@as(u32, 0), gpu.globalResourceCount());
    };
    try transactions(allocator);
    try @import("gpu_offscreen_lifetime.zig").run(allocator);
    std.debug.print("GPU offscreen: actual transparent target, immutable GPU snapshot sampling, 3 DPI, rollback, loss/stop and refs=0 passed\n", .{});
}
