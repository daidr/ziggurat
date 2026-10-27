const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const resources = ui.gpu_resources;
const drawing = ui.drawing;
const gpu = ui.d3d11;
const c = @import("ziggurat_c_win32");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const background = 0x102030;
const Source = struct {
    lease: drawing.Lease = undefined,
    pixels: [64]u8 = undefined,
    smaller: [16]u8 = undefined,
    last: [4]u8 = .{ 0, 0, 128, 128 },
    levels: [3]drawing.ImageLevel = undefined,
    fn init(self: *Source) void {
        self.lease = drawing.Lease.init(std.Thread.getCurrentId());
        for (0..16) |i| @memcpy(self.pixels[i * 4 ..][0..4], &self.last);
        for (0..4) |i| @memcpy(self.smaller[i * 4 ..][0..4], &self.last);
        self.levels = .{
            .{ .pixels = &self.pixels, .byte_len = 64, .width = 4, .height = 4, .stride = 16 },
            .{ .pixels = &self.smaller, .byte_len = 16, .width = 2, .height = 2, .stride = 8 },
            .{ .pixels = &self.last, .byte_len = 4, .width = 1, .height = 1, .stride = 4 },
        };
    }
    fn view(self: *Source) drawing.ImageView {
        return .{ .lease = &self.lease, .identity = 1, .levels = &self.levels };
    }
};
fn finish(renderer: *gpu.Renderer) !void {
    renderer.end() catch |err| if (err != error.PresentationBusy) return err;
}
fn visible(renderer: *const gpu.Renderer) bool {
    const window = renderer.surfaceForTest() orelse return false;
    return c.GetWindowLongW(window, c.GWL_STYLE) & c.WS_VISIBLE != 0;
}
fn near(want: u32, got: u32) !void {
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((want >> shift) & 255);
        const b: i32 = @intCast((got >> shift) & 255);
        if (@abs(a - b) > 1) {
            std.debug.print("texture pixel expected={x}, actual={x}\n", .{ want, got });
            return error.TexturePixelMismatch;
        }
    }
}
fn pixel(renderer: *gpu.Renderer, x: u32, y: u32) !u32 {
    if (renderer.layerOptions()) |options| {
        var pixels: [128 * 128]u32 = undefined;
        try renderer.readLayerPixels(false, pixels[0 .. options.size.width * options.size.height]);
        return pixels[y * options.size.width + x] & 0xffffff;
    }
    return renderer.readPixelForTest(x, y);
}
fn over(before: u32, opacity: u8) u32 {
    const alpha: f64 = 128.0 / 255.0 * @as(f64, @floatFromInt(opacity)) / 255.0;
    var result: u32 = 0;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const source: f64 = if (shift == 16) alpha * 255 else 0;
        const channel: u32 = @intFromFloat(@round(source + @as(f64, @floatFromInt((before >> shift) & 255)) * (1 - alpha)));
        result |= channel << shift;
    }
    return result;
}
fn raw(allocator: std.mem.Allocator, driver: resources.Driver) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver, .texture_bytes = 4096 });
    defer domain.close() catch unreachable;
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    defer texture.close() catch unreachable;
    const view = try texture.view();
    try source.lease.ensureUnused();
    @memset(&source.pixels, 0); // A texture never borrows the CPU upload source.
    var colored: Source = .{};
    colored.init();
    for (0..4) |i| @memcpy(colored.smaller[i * 4 ..][0..4], &[_]u8{ 128, 0, 0, 128 });
    colored.last = .{ 0, 128, 0, 128 };
    const colored_texture = try domain.upload(colored.view());
    defer colored_texture.close() catch unreachable;
    @memset(&colored.pixels, 0);
    @memset(&colored.smaller, 0);
    @memset(&colored.last, 0);
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    defer _ = window.destroy() catch false;
    {
        const dc = c.GetDC(window.nativeHandle()) orelse return error.NoSurface;
        defer _ = c.ReleaseDC(window.nativeHandle(), dc);
        var renderer: gpu.Renderer = .{};
        try renderer.init(.{ .domain = domain });
        defer renderer.deinit();
        try expectError(error.ResourceInUse, domain.close());
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        for ([_]f32{ 1, 1.5, 2 }) |scale| {
            const size: u32 = @intFromFloat(64 * scale);
            const paint: z.Paint = .{ .native_window = window.nativeHandle(), .native_context = dc, .size = .{ .width = size, .height = size, .scale = scale } };
            _ = c.SetWindowPos(window.nativeHandle(), null, 0, 0, @intCast(size), @intCast(size), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            try renderer.prepareLayers(allocator, .{ .size = paint.size, .max_depth = 2 });
            buffer.reset();
            try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0);
            try buffer.texture(.{ .x = 16, .y = 16, .width = 1, .height = 1 }, try colored_texture.view(), .{ .sampling = .mip_linear });
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            // 4px -> 1 physical pixel selects mip2; 1.5/2px selects mip1.
            try near(if (scale == 1) 0x008000 else 0x000080, try pixel(&renderer, @intFromFloat(16 * scale), @intFromFloat(16 * scale)));
            try finish(&renderer);
            for ([_]drawing.ImageFit{ .stretch, .contain, .cover }) |fit| for ([_]drawing.ImageSampling{ .nearest, .linear, .mip_linear }) |sampling| {
                buffer.reset();
                try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, background);
                try buffer.pushClip(.{ .x = 4, .y = 4, .width = 36, .height = 36 });
                try buffer.texture(.{ .x = 8, .y = 8, .width = 24, .height = 16 }, view, .{ .fit = fit, .sampling = sampling, .opacity = 128 });
                try buffer.popClip();
                try expectError(error.ResourceInUse, texture.close());
                try renderer.begin(paint);
                try renderer.replayBuffer(&buffer);
                try near(over(background, 128), try pixel(&renderer, @intFromFloat(20 * scale), @intFromFloat(16 * scale)));
                try near(background, try pixel(&renderer, @intFromFloat(6 * scale), @intFromFloat(6 * scale)));
                if (fit == .contain) try near(background, try pixel(&renderer, @intFromFloat(9 * scale), @intFromFloat(16 * scale)));
                try finish(&renderer);
            };
            const native_before = try domain.stats();
            for (0..8) |_| {
                try renderer.begin(paint);
                try renderer.replayBuffer(&buffer);
                try finish(&renderer);
            }
            try equal(native_before.bitmap_creations, (try domain.stats()).bitmap_creations);
            // A foreign domain fails before even a preceding fill reaches work.
            const foreign = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
            defer foreign.close() catch unreachable;
            source.init();
            const other = try foreign.upload(source.view());
            defer other.close() catch unreachable;
            buffer.reset();
            try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x00ff00);
            try buffer.texture(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, try other.view(), .{});
            const was_visible = visible(&renderer);
            var front: [128 * 128]u32 = undefined;
            try renderer.readLayerPixels(true, front[0 .. size * size]);
            const accepted = front[0];
            try renderer.begin(paint);
            try expectError(error.TextureDomainMismatch, renderer.replayBuffer(&buffer));
            try equal(was_visible, visible(&renderer));
            var work: [128 * 128]u32 = undefined;
            try renderer.readLayerPixels(true, work[0 .. size * size]);
            try equal(accepted, work[0]);
            buffer.reset();
        }
    }
    try equal(@as(usize, 0), (try domain.stats()).attachments);
    std.debug.print("GPU domain {s}: shared-device texture alpha/fit/mip/clip/3DPI and whole-batch rejection passed\n", .{@tagName(driver)});
}
fn noop(_: *anyopaque) void {}
fn lossAndStop(allocator: std.mem.Allocator, driver: resources.Driver) !void {
    const app = try z.App.init(allocator);
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    const view = try texture.view();
    const window = try app.createWindow(.{ .width = 32, .height = 32 });
    var renderer: gpu.Renderer = .{};
    var wait: ?z.NativeWaitToken = null;
    try renderer.init(.{ .domain = domain, .native_wait_slot = &wait });
    var second: gpu.Renderer = .{};
    var second_wait: ?z.NativeWaitToken = null;
    try second.init(.{ .domain = domain, .native_wait_slot = &second_wait });
    var buffer: ui.commands.Buffer = .{};
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, view, .{});
    {
        const dc = c.GetDC(window.nativeHandle()) orelse return error.NoSurface;
        defer _ = c.ReleaseDC(window.nativeHandle(), dc);
        const paint: z.Paint = .{ .native_window = window.nativeHandle(), .native_context = dc, .size = .{ .width = 32, .height = 32, .scale = 1 } };
        for ([_]*gpu.Renderer{ &renderer, &second }) |current| {
            try current.begin(paint);
            try current.replayBuffer(&buffer);
            try near(0xff7f7f, try current.readPixelForTest(16, 16));
            try finish(current);
        }
        const handle = renderer.frameReadyHandle().?;
        const second_handle = second.frameReadyHandle().?;
        wait = try app.watchNative(handle, .{ .context = &buffer, .call = noop });
        second_wait = try app.watchNative(second_handle, .{ .context = &buffer, .call = noop });
        const before = (try domain.stats()).generation;
        const old_wait = wait.?;
        const old_second = second_wait.?;
        try domain.injectDeviceLossForTest();
        try expect(wait == null and second_wait == null);
        try expect(!app.unwatchNative(old_wait) and !app.unwatchNative(old_second));
        var flags: c.DWORD = 0;
        try expect(c.GetHandleInformation(handle, &flags) == 0);
        try expect(c.GetHandleInformation(second_handle, &flags) == 0);
        try equal(before + 1, (try domain.stats()).generation);
        try equal(@as(usize, 0), (try domain.stats()).pixel_bytes);
        try expectError(error.TextureDeviceLost, texture.view());
        try expectError(error.ResourceInUse, texture.close());
        try expectError(error.DomainDeviceLost, renderer.begin(paint));
        try domain.recreate();
        try expectError(error.StaleTextureGeneration, texture.view());
        source.init();
        const replacement = try domain.upload(source.view());
        defer replacement.close() catch unreachable;
        buffer.reset();
        try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try replacement.view(), .{});
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try near(0xff7f7f, try renderer.readPixelForTest(16, 16));
        try finish(&renderer);
        buffer.reset();
    }
    try texture.close();
    // Stop precedes content teardown; raw renderer/texture shells retain their
    // explicit domain borrow and must remain safe after App.deinit.
    const survivor = try domain.upload(source.view());
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try survivor.view(), .{});
    app.quit();
    try app.finishShutdown();
    try equal(@as(u32, 0), (try domain.stats()).native_objects);
    try equal(@as(usize, 2), (try domain.stats()).attachments);
    try expectError(error.Closed, survivor.view());
    try expectError(error.ResourceInUse, survivor.close());
    app.deinit();
    renderer.deinit();
    second.deinit();
    buffer.reset();
    try survivor.close();
    try domain.close();
    try equal(@as(u32, 0), gpu.globalResourceCount());
}
fn capacityAndFailure(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var source: Source = .{};
    source.init();
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp, .texture_bytes = 4096 });
    defer domain.close() catch unreachable;
    const first = try domain.upload(source.view());
    defer first.close() catch unreachable;
    const baseline = try domain.stats();
    try domain.injectUploadFailureAtForTest(2);
    try expectError(error.OutOfMemory, domain.upload(source.view()));
    const after = try domain.stats();
    try equal(baseline.native_objects, after.native_objects);
    try equal(baseline.textures, after.textures);
    try equal(baseline.pixel_bytes, after.pixel_bytes);
    try equal(baseline.bitmap_creations + 1, after.bitmap_creations);
    try source.lease.ensureUnused();
    var textures: [31]*resources.Texture = undefined;
    for (&textures) |*texture| texture.* = try domain.upload(source.view());
    try expectError(error.Full, domain.upload(source.view()));
    try equal(@as(usize, 32), (try domain.stats()).textures);
    for (textures) |texture| try texture.close();
    const view = try first.view();
    // Fault injection at the representable boundary exercises native nonwrap.
    @constCast(view.domain).generation = std.math.maxInt(u64);
    try domain.injectDeviceLossForTest();
    try equal(std.math.maxInt(u64), (try domain.stats()).generation);
    try equal(.exhausted, (try domain.stats()).status);
    try expectError(error.GenerationExhausted, domain.recreate());
    try expectError(error.GenerationExhausted, first.view());
}
fn allocationPass(allocator: std.mem.Allocator, app: *z.App) !void {
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    defer texture.close() catch unreachable;
}
fn candidatesAndOperations(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp });
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    var renderer: gpu.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    {
        const dc = c.GetDC(window.nativeHandle()) orelse return error.NoSurface;
        defer _ = c.ReleaseDC(window.nativeHandle(), dc);
        const size: z.Size = .{ .width = 64, .height = 64, .scale = 1 };
        const paint: z.Paint = .{ .native_window = window.nativeHandle(), .native_context = dc, .size = size };
        const candidate = try renderer.createLayerCandidate(allocator, .{ .size = size, .max_depth = 1 });
        var other: gpu.Renderer = .{};
        try other.init(.{ .domain = domain });
        try expectError(error.InvalidLayerCandidate, other.commitLayerCandidate(candidate));
        other.deinit();
        try domain.injectDeviceLossForTest();
        try expectError(error.DomainDeviceLost, renderer.commitLayerCandidate(candidate));
        try domain.recreate();
        try expectError(error.StaleLayerCandidate, renderer.commitLayerCandidate(candidate));
        gpu.Renderer.destroyLayerCandidate(candidate);
        try renderer.prepareLayers(allocator, .{ .size = size, .max_depth = 1 });
        try renderer.uploadImage(source.view());
        try renderer.begin(paint);
        try expectError(error.Busy, domain.upload(source.view()));
        try expectError(error.Busy, domain.injectDeviceLossForTest());
        app.quit();
        try expectError(error.Busy, app.finishShutdown());
        renderer.discard();
        try renderer.releaseLayers();
    }
    _ = try window.destroy();
    app.quit();
    try app.finishShutdown();
    const before = renderer.imageStats();
    try expectError(error.Closed, renderer.uploadImage(source.view()));
    try expectError(error.Closed, renderer.uploadDynamicImage(source.view()));
    try expectError(error.Closed, renderer.uploadCoverage(.{ .lease = &source.lease, .identity = 123, .coverage = .{ .pixels = source.pixels[0..4], .width = 1, .height = 1, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 } }));
    try equal(before.upload_requests, renderer.imageStats().upload_requests);
    // Stopped resources permit cleanup, never new native payload creation.
    try expect(try renderer.releaseImage(source.view().identity));
    try renderer.setImageBudget(16);
    try renderer.releaseLayers();
    renderer.deinit();
    try texture.close();
    app.deinit();
    try domain.close();
    try equal(@as(u32, 0), gpu.globalResourceCount());
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    for ([_]resources.Driver{ .hardware, .warp }) |driver| {
        try raw(allocator, driver);
        try equal(@as(u32, 0), gpu.globalResourceCount());
        try lossAndStop(allocator, driver);
    }
    try capacityAndFailure(allocator);
    try candidatesAndOperations(allocator);
    try equal(@as(u32, 0), gpu.globalResourceCount());
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{app});
    }
    try equal(@as(u32, 0), gpu.globalResourceCount());
    try @import("gpu_domain_lifetime.zig").run(allocator);
    try equal(@as(u32, 0), gpu.globalResourceCount());
    std.debug.print("GPU domain: fixed slots/budget, candidate failure, generations, wait revocation, post-stop shells, allocation rollback and refs=0 passed\n", .{});
}
