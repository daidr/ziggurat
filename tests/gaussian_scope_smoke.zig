const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
const width = 32;
const height = 24;
// Independent 60-decimal normalization and symmetric Q24 quantization of
// sigma=3/4 physical pixels. These literals never read the prepared descriptor.
const weights = [_]u32{ 2994, 254916, 3668735, 8923926, 3668735, 254916, 2994 };
fn scaled(scale: f32, x: f32, y: f32, w: f32, h: f32) ui.Rect {
    return .{ .x = x / scale, .y = y / scale, .width = w / scale, .height = h / scale };
}
fn over(source: u32, destination: u32) u32 {
    const alpha = source >> 24;
    var result: u32 = 0;
    inline for (0..4) |channel| {
        const a = (source >> (channel * 8)) & 255;
        const b = (destination >> (channel * 8)) & 255;
        result |= (a + (b * (255 - alpha) + 127) / 255) << (channel * 8);
    }
    return result;
}
fn sourcePixel(x: i32, y: i32) u32 {
    if (x < 0 or y < 0 or x >= 10 or y >= 8) return 0;
    var pixel: u32 = 0;
    if (x >= 1 and x < 3 and y >= 2 and y < 4) pixel = 0x80800000;
    if (x >= 2 and x < 5 and y == 3) pixel = over(0x80000080, pixel);
    if (x >= 6 and x < 8 and y >= 4 and y < 6) pixel = over(0x80008000, pixel);
    if (x >= 7 and x < 9 and y >= 1 and y < 3) pixel = over(0x40000040, pixel);
    return pixel;
}
fn filtered(x: i32, y: i32, identity: bool) u32 {
    if (identity) return sourcePixel(x, y);
    var result: u32 = 0;
    inline for (0..4) |channel| {
        var total: u64 = 0;
        for (weights, 0..) |vertical, row| {
            var sum: u64 = 0;
            for (weights, 0..) |horizontal, column| sum += @as(u64, horizontal) * ((sourcePixel(x + @as(i32, @intCast(column)) - 3, y + @as(i32, @intCast(row)) - 3) >> (channel * 8)) & 255);
            total += vertical * ((sum + (1 << 23)) / (1 << 24));
        }
        result |= @as(u32, @intCast((total + (1 << 23)) / (1 << 24))) << (channel * 8);
    }
    return result;
}
fn expected(x: usize, y: usize, identity: bool) u32 {
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    const clip = @max(0, @min(fx + 1, 11.75) - @max(fx, 3.25)) * @max(0, @min(fy + 1, 7.75) - @max(fy, 1.5));
    const pixel = filtered(@intCast(x), @intCast(y), identity);
    const amount = @as(f64, 192) / 255 * @as(f64, 128) / 255 * clip;
    var result: u32 = 0;
    inline for (0..4) |channel| {
        const byte: f64 = @floatFromInt((pixel >> (channel * 8)) & 255);
        result |= @as(u32, @intFromFloat(@floor(byte * amount + 0.5))) << (channel * 8);
    }
    return result;
}
fn verify(pixels: []const u32, identity: bool, reflected: bool) !void {
    for (0..height) |y| for (0..width) |x| {
        // Reflection maps texel centers exactly, without reusing a matrix or
        // production sampling helper in the expected coordinate calculation.
        const want = expected(if (reflected) width - 1 - x else x, y, identity);
        const got = pixels[y * width + x];
        inline for (0..4) |channel| {
            const a: i32 = @intCast((want >> (channel * 8)) & 255);
            const b: i32 = @intCast((got >> (channel * 8)) & 255);
            if (@abs(a - b) > 2) {
                std.debug.print("Gaussian mismatch x={d} y={d} identity={} expected={x:0>8} actual={x:0>8}\n", .{ x, y, identity, want, got });
                return error.PixelMismatch;
            }
        }
    };
}
fn rejectedSource(surface: anytype, kernel: ui.gaussian.View, scale: f32) !void {
    // A valid recorded scope exceeds only this prepared source capacity.
    // Rejection must precede native clears, uploads, output allocation or pins
    // acquired by an accepted render. The previously committed front stays live.
    var bad: ui.commands.Buffer = .{};
    var storage: ui.commands.FilterStorage = .{};
    defer bad.reset();
    try bad.bindFilterStorage(&storage);
    try bad.beginGaussian(scaled(scale, 0, 0, 64, 8), kernel, .{});
    try bad.endGaussian();
    try bad.finish();
    const before = try surface.stats();
    try std.testing.expectError(error.GaussianSourceExceeded, surface.render(&bad));
    try std.testing.expectEqualDeep(before, try surface.stats());
}
const Scene = struct {
    kernel: *ui.gaussian.Kernel,
    image: ui.drawing.ImageView,
    mask: ui.drawing.CoverageView,
    calls: usize = 0,
    draws: usize = 0,
    far: bool = false,
    failure: ?anyerror = null,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Scene = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        self.record(frame) catch |err| {
            self.failure = err;
        };
    }
    fn record(self: *Scene, frame: *ui.Frame) !void {
        frame.clear(0x000000);
        const scale = frame.size.scale;
        if (self.far) {
            frame.roundedRect(scaled(scale, 2, 2, 3, 3), 0, .rgb(0xff0000));
            return frame.gaussianScope(scaled(scale, 20000, 0, 8, 8), try self.kernel.view(), .{}, self, farBody);
        }
        try frame.pushClip(scaled(scale, 3.25, 1.5, 8.5, 6.25));
        try frame.gaussianScope(scaled(scale, -2, -2, 12, 10), try self.kernel.view(), .{ .opacity = 192, .mask = self.mask }, self, body);
        try frame.popClip();
    }
    fn farBody(ptr: *anyopaque, frame: *ui.Frame) !void {
        const self: *Scene = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        frame.roundedRect(scaled(frame.size.scale, 20002, 2, 2, 2), 0, .rgb(0x00ff00));
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn body(ptr: *anyopaque, frame: *ui.Frame) !void {
        const self: *Scene = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const scale = frame.size.scale;
        try std.testing.expectEqualDeep(@as(?ui.Rect, scaled(scale, 3.25, 1.5, 8.5, 6.25)), frame.clipBounds());
        if ((try self.kernel.view()).descriptor.radius != 0) try std.testing.expectError(error.ResourceInUse, self.kernel.close());
        try frame.pushClip(scaled(scale, 0, 0, 10, 8));
        try std.testing.expectEqualDeep(scaled(scale, 0, 0, 10, 8), frame.clips.items[frame.clips.len - 1]);
        frame.roundedRect(scaled(scale, 1, 2, 2, 2), 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
        frame.roundedRect(scaled(scale, 2, 3, 3, 1), 0, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
        try frame.beginGroup(scaled(scale, 6, 4, 2, 2), .{ .opacity = 128 });
        const stops = [_]ui.commands.brushes.Stop{ .{ .offset = 0, .color = .rgb(0x00ff00) }, .{ .offset = 1, .color = .rgb(0x00ff00) } };
        frame.gradientRect(scaled(scale, 6, 4, 2, 2), 0, .{ .linear = .{ .start = .{ .x = 6 / scale, .y = 4 / scale }, .end = .{ .x = 8 / scale, .y = 4 / scale }, .stops = &stops } });
        try frame.endGroup();
        try frame.image(scaled(scale, 7, 1, 2, 2), self.image, .{ .fit = .stretch, .sampling = .nearest });
        try frame.popClip();
    }
};
fn collection(app: *z.App, comptime gpu: bool, driver: if (gpu) ui.gpu_resources.Driver else void, scale: f32, identity: bool, reflected: bool) !void {
    const allocator = std.heap.page_allocator;
    const bank = try ui.gaussian.Bank.create(allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = if (identity) 0 else 0.75 / scale, .scale = scale } });
    defer kernel.close() catch unreachable;
    if (!identity) try std.testing.expectEqualSlices(u32, &weights, (try kernel.view()).descriptor.weights[0..7]);
    var mask_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    var image_lease = ui.drawing.Lease.init(std.Thread.getCurrentId());
    const mask_bytes = [_]u8{128} ** (width * height);
    const image_bytes = [_]u8{ 64, 0, 0, 64 } ** 4;
    const image_levels = [_]ui.drawing.ImageLevel{.{ .pixels = &image_bytes, .width = 2, .height = 2, .stride = 8, .byte_len = 16 }};
    const mask: ui.drawing.CoverageView = .{ .lease = &mask_lease, .identity = try ui.drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &mask_bytes, .width = width, .height = height, .stride = width, .origin_x = 0, .origin_y = 0, .scale = scale } };
    var scene: Scene = .{ .kernel = kernel, .mask = mask, .image = .{ .lease = &image_lease, .identity = try ui.drawing.reserveRasterIdentity(), .levels = &image_levels } };
    var context = ui.Context.init(&scene, Scene.draw, Scene.action);
    defer context.command_buffer.reset();
    var storage: ui.commands.FilterStorage = .{};
    if (!identity) try context.command_buffer.bindFilterStorage(&storage);
    var transforms: ui.commands.TransformStorage = .{ .scale = scale };
    if (reflected) {
        try context.command_buffer.bindTransformStorage(&transforms);
        try context.command_buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = width / scale }, .{ .width = width / scale, .height = height / scale }, scale));
    }
    const size: z.Size = .{ .width = width, .height = height, .scale = scale };
    var frame: ui.Frame = .{ .context = &context, .size = size };
    try frame.pushClip(scaled(scale, 3.25, 1.5, 8.5, 6.25));
    try frame.gaussianScope(scaled(scale, -2, -2, 12, 10), try kernel.view(), .{ .opacity = 192, .mask = mask }, &scene, Scene.body);
    try frame.popClip();
    if (reflected) try context.command_buffer.endTransform();
    try context.command_buffer.finish();
    try std.testing.expectEqual(@as(usize, 1), scene.calls);
    var pixels: [width * height]u32 = undefined;
    if (gpu) {
        const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
        defer domain.close() catch unreachable;
        const options: ui.gpu_offscreen.Options = .{ .size = size, .max_depth = 3, .resident_bytes = 64 * 1024, .transform_source = if (reflected) .{ .width = width / scale, .height = height / scale } else null };
        const surface = if (identity) try ui.gpu_offscreen.Surface.create(domain, allocator, options) else try ui.gpu_offscreen.Surface.createGaussian(domain, allocator, options, .{ .source_size = .{ .width = 14 / scale, .height = 12 / scale }, .max_radius = 3 });
        var surface_closed = false;
        defer if (!surface_closed) surface.close() catch unreachable;
        try surface.uploadCoverage(mask);
        try surface.uploadImage(scene.image);
        try surface.render(&context.command_buffer);
        const warm = try surface.stats();
        for (0..3) |_| try surface.render(&context.command_buffer);
        const after = try surface.stats();
        try std.testing.expectEqual(warm.layers.native_creations, after.layers.native_creations);
        if (!identity) try rejectedSource(surface, try kernel.view(), scale);
        try surface.readFrontForTest(&pixels);
        try verify(&pixels, identity, reflected);
        const texture = try surface.snapshot();
        defer texture.close() catch unreachable;
        try surface.close();
        surface_closed = true;
        // The immutable final Texture owns its backing after both source
        // filter targets and their optional shader program have gone away.
        _ = try texture.view();
    } else {
        const options: ui.offscreen.Options = .{ .size = size, .max_depth = 3, .resident_bytes = 64 * 1024, .output_bytes = 64 * 1024, .transform_source = if (reflected) .{ .width = width / scale, .height = height / scale } else null };
        const surface = if (identity) try ui.offscreen.Surface.create(app, allocator, options) else try ui.offscreen.Surface.createGaussian(app, allocator, options, .{ .source_size = .{ .width = 14 / scale, .height = 12 / scale }, .max_radius = 3 });
        var surface_closed = false;
        defer if (!surface_closed) surface.close() catch unreachable;
        try surface.uploadCoverage(mask);
        try surface.uploadImage(scene.image);
        const snapshot = try surface.render(&context.command_buffer);
        defer snapshot.close() catch unreachable;
        const warm = try surface.stats();
        for (0..3) |_| {
            const next = try surface.render(&context.command_buffer);
            try next.close();
        }
        const after = try surface.stats();
        try std.testing.expectEqual(warm.layers.native_creations, after.layers.native_creations);
        if (!identity) try rejectedSource(surface, try kernel.view(), scale);
        try surface.close();
        surface_closed = true;
        // Independent image/account ownership survives the source Surface.
        const view = try snapshot.view();
        @memcpy(std.mem.sliceAsBytes(&pixels), view.levels[0].pixels[0 .. width * height * 4]);
        try verify(&pixels, identity, reflected);
    }
    if (comptime builtin.os.tag == .windows and gpu) if (scale == 1.5 and !identity and !reflected) {
        context.command_buffer.reset();
        try attachedContext(app, &scene, driver);
    };
    std.debug.print("Gaussian native gpu={} scale={d} identity={} reflected={} source_callbacks={d} pixels={d}\n", .{ gpu, scale, identity, reflected, scene.calls, pixels.len });
}
fn attachedContext(app: *z.App, original: *Scene, driver: ui.gpu_resources.Driver) !void {
    const allocator = std.heap.page_allocator;
    const window = try app.createWindow(.{ .width = 64, .height = 48 });
    defer _ = window.destroy() catch unreachable;
    const size = try window.contentSize();
    if (size.width < width or size.height < height or @as(u64, size.width) * size.height > 1024 * 1024) return error.InvalidContextFixtureSize;
    const bank = try ui.gaussian.Bank.create(allocator, std.Thread.getCurrentId(), .{});
    defer bank.close() catch unreachable;
    const kernel = try bank.prepare(.{ .spec = .{ .sigma = 0.75 / size.scale, .scale = size.scale } });
    defer kernel.close() catch unreachable;
    var scene = original.*;
    scene.kernel = kernel;
    scene.calls = 0;
    scene.draws = 0;
    scene.mask.identity = try ui.drawing.reserveRasterIdentity();
    scene.mask.coverage.scale = size.scale;
    var context = ui.Context.init(&scene, Scene.draw, Scene.action);
    context.render_mode = if (driver == .warp) .warp else .hardware;
    context.semantics_enabled = false;
    try context.attach(window);
    try context.uploadCoverage(scene.mask);
    try context.uploadImage(scene.image);
    const options: ui.GaussianWorkspaceOptions = .{ .layers = .{ .size = size, .max_depth = 3, .legacy_text = .disabled }, .source_size = .{ .width = 14 / size.scale, .height = 12 / size.scale }, .max_radius = 3 };
    try context.prepareGaussianWorkspace(allocator, options);
    const count = @as(usize, size.width) * size.height;
    const front = try allocator.alloc(u32, count);
    defer allocator.free(front);
    const previous = try allocator.alloc(u32, count);
    defer allocator.free(previous);
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    if (scene.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), scene.draws);
    try std.testing.expectEqual(@as(usize, 1), scene.calls);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try context.gpu_renderer.readLayerPixels(true, front);
    for (0..size.height) |y| for (0..size.width) |x| {
        const want = expected(x, y, false) | 0xff000000;
        const actual = front[y * size.width + x];
        inline for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > 2) return error.ContextPixelMismatch;
    };
    @memcpy(previous, front);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, context.prepareGaussianWorkspace(failing.allocator(), options));
    try context.gpu_renderer.readLayerPixels(true, front);
    try std.testing.expectEqualSlices(u32, previous, front);
    scene.far = true;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    if (scene.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), scene.draws);
    try std.testing.expectEqual(@as(usize, 2), scene.calls);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    try std.testing.expectEqual(@as(usize, 1), context.fallbacks);
    try std.testing.expectEqual(@as(usize, 1), context.gdi_frames);
    for (0..size.height) |y| for (0..size.width) |x| {
        const want: u32 = if (x >= 2 and x < 5 and y >= 2 and y < 5) 0xffff0000 else 0xff000000;
        try std.testing.expectEqual(want, context.renderer.pixels.?[y * size.width + x]);
    };
    try context.releaseGaussianWorkspace();
    try std.testing.expect(context.renderer.gaussianCapacity() == null and context.gpu_renderer.gaussianCapacity() == null);
    _ = try window.destroy();
    try (try kernel.view()).lease.ensureUnused();
    std.debug.print("Gaussian Context {s} actual={d}x{d}@{d} live_scope1 whole_buffer_fallback1 old_front_preserved=true release=true\n", .{ @tagName(driver), size.width, size.height, size.scale });
}
fn transactions(app: *z.App) !void {
    const options: ui.offscreen.Options = .{ .size = .{ .width = 16, .height = 16, .scale = 1 }, .max_depth = 2 };
    const filter: ui.GaussianFilterOptions = .{ .source_size = .{ .width = 8, .height = 8 }, .max_radius = 3 };
    var failures: usize = 0;
    for (0..20) |index| {
        var allocator = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = index });
        if (ui.offscreen.Surface.createGaussian(app, allocator.allocator(), options, filter)) |surface| {
            try surface.close();
            try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
        }
    } else return error.AllocationSweepUnbounded;
    for (1..5) |stage| {
        try std.testing.expectError(if (builtin.os.tag == .linux) error.LayerPreparationFailed else error.OutOfMemory, ui.offscreen.Surface.createGaussianWithFailureForTest(app, std.heap.page_allocator, options, filter, @intCast(stage)));
    }
    std.debug.print("Gaussian software construction allocator_failures={d} native_failures=4\n", .{failures});
    if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) {
        const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = .warp });
        defer domain.close() catch unreachable;
        const gpu_options: ui.gpu_offscreen.Options = .{ .size = options.size, .max_depth = 2, .resident_bytes = 0 };
        const baseline = try domain.stats();
        for (1..7) |stage| {
            try std.testing.expectError(error.GraphicsFailed, ui.gpu_offscreen.Surface.createGaussianWithFailureForTest(domain, std.heap.page_allocator, gpu_options, filter, @intCast(stage)));
            const after = try domain.stats();
            try std.testing.expectEqual(baseline.native_objects, after.native_objects);
            try std.testing.expectEqual(baseline.total_reservation, after.total_reservation);
        }
        for (0..10) |index| {
            var allocator = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = index });
            if (ui.gpu_offscreen.Surface.createGaussian(domain, allocator.allocator(), gpu_options, filter)) |surface| {
                try surface.close();
                try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
                try std.testing.expectEqual(baseline.total_reservation, (try domain.stats()).total_reservation);
            }
        } else return error.AllocationSweepUnbounded;
        const bank = try ui.gaussian.Bank.create(std.heap.page_allocator, std.Thread.getCurrentId(), .{});
        defer bank.close() catch unreachable;
        const kernel = try bank.prepare(.{ .spec = .{ .sigma = 0.75 } });
        defer kernel.close() catch unreachable;
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        var storage: ui.commands.FilterStorage = .{};
        try buffer.bindFilterStorage(&storage);
        try buffer.beginGaussian(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try kernel.view(), .{});
        try buffer.roundedRect(.{ .x = 2, .y = 2, .width = 4, .height = 4 }, 0, .rgb(0xff0000));
        try buffer.endGaussian();
        const surface = try ui.gpu_offscreen.Surface.createGaussian(domain, std.heap.page_allocator, gpu_options, filter);
        var surface_closed = false;
        defer if (!surface_closed) surface.close() catch unreachable;
        try surface.render(&buffer);
        const texture = try surface.snapshot();
        defer texture.close() catch unreachable;
        try surface.injectDeviceLossForTest();
        try std.testing.expectError(error.DeviceLost, surface.render(&buffer));
        try std.testing.expectEqual(@as(usize, 0), (try surface.stats()).workspace_actual);
        try std.testing.expectError(error.TextureDeviceLost, texture.view());
        try domain.recreate();
        try std.testing.expectError(error.GaussianNotPrepared, surface.render(&buffer));
        try surface.close();
        surface_closed = true;
        const replacement = try ui.gpu_offscreen.Surface.createGaussian(domain, std.heap.page_allocator, gpu_options, filter);
        defer replacement.close() catch unreachable;
        try replacement.render(&buffer);
        var pixels: [16 * 16]u32 = undefined;
        try replacement.readFrontForTest(&pixels);
        // At this point each axis includes literal taps 2..5: sum=16516312.
        // Independent byte rounding gives horizontal251, then vertical247.
        try std.testing.expectEqual(@as(u32, 0xf7f70000), pixels[3 * 16 + 3]);
        try std.testing.expectError(error.StaleTextureGeneration, texture.view());
        std.debug.print("Gaussian GPU transactions native_failures=6 device_loss_reprepare=true resources_restored\n", .{});
    }
}
pub fn main() !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    for ([_]f32{ 1, 1.5, 2 }) |scale| for ([_]bool{ false, true }) |identity| {
        try collection(app, false, {}, scale, identity, false);
        if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) {
            try collection(app, true, .hardware, scale, identity, false);
            try collection(app, true, .warp, scale, identity, false);
        }
    };
    try collection(app, false, {}, 1.5, false, true);
    if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) {
        try collection(app, true, .hardware, 1.5, false, true);
        try collection(app, true, .warp, 1.5, false, true);
    }
    try transactions(app);
    if (comptime builtin.os.tag == .windows and ui.capabilities.gpu) try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    std.debug.print("Gaussian native selected collection passed resources=0\n", .{});
}
