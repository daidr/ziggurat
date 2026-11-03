//! GPU textures on macOS: a Metal device domain's uploads and offscreen
//! surfaces' snapshots draw in its renderers with their alpha, fit, mips
//! and clips at three scales; a frame drawing another domain's texture
//! fails whole; device loss revokes every texture and renderer object until
//! the domain is recreated, and stop leaves only shells to close; slots,
//! budgets and allocation failures roll back. Then the platform-neutral
//! domain and surface lifetime checks run (gpu_domain_lifetime.zig,
//! gpu_offscreen_lifetime.zig).
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const resources = ui.gpu_resources;
const Surface = ui.gpu_offscreen.Surface;
const drawing = ui.drawing;
const metal = ui.metal;
fn check(ok: bool, at: std.builtin.SourceLocation) !void {
    if (ok) return;
    std.debug.print("check failed at {s}:{d}\n", .{ at.file, at.line });
    return error.CheckFailed;
}
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
pub const std_options: std.Options = .{ .allow_stack_tracing = false };
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
fn near(want: u32, got: u32) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const a: i32 = @intCast((want >> shift) & 255);
        const b: i32 = @intCast((got >> shift) & 255);
        if (@abs(a - b) > 1) {
            std.debug.print("pixel expected={x}, actual={x}\n", .{ want, got });
            return error.PixelMismatch;
        }
    }
}
fn over(before: u32, opacity: u8) u32 {
    const alpha: f64 = 128.0 / 255.0 * @as(f64, @floatFromInt(opacity)) / 255.0;
    var result: u32 = 0xff000000;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const source: f64 = if (shift == 16) alpha * 255 else 0;
        const channel: u32 = @intFromFloat(@round(source + @as(f64, @floatFromInt((before >> shift) & 255)) * (1 - alpha)));
        result |= channel << shift;
    }
    return result;
}
/// One frame of `buffer` drawn offscreen, opaque, as 0xAARRGGBB pixels.
const Frame = struct {
    pixels: [128 * 128]u32 = undefined,
    side: u32 = 0,
    fn draw(self: *Frame, renderer: *metal.Renderer, buffer: *const ui.commands.Buffer, size: z.Size) !void {
        self.side = size.width;
        try renderer.beginOffscreen(size, false);
        renderer.replayBuffer(buffer) catch |err| {
            renderer.abort();
            return err;
        };
        try renderer.endOffscreen(std.mem.sliceAsBytes(self.pixels[0 .. size.width * size.height]), size.width * 4);
    }
    fn at(self: *const Frame, x: f32, y: f32, scale: f32) u32 {
        return self.pixels[@as(usize, @intFromFloat(y * scale)) * self.side + @as(usize, @intFromFloat(x * scale))];
    }
};

fn raw(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    try expectError(error.UnsupportedDriver, resources.DeviceDomain.create(app, allocator, .{ .driver = .warp }));
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .texture_bytes = 4096 });
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
    var renderer: metal.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    defer renderer.deinit();
    try expectError(error.ResourceInUse, domain.close());
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var frame: Frame = .{};
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const side: u32 = @intFromFloat(64 * scale);
        const size: z.Size = .{ .width = side, .height = side, .scale = scale };
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0);
        try buffer.texture(.{ .x = 16, .y = 16, .width = 1, .height = 1 }, try colored_texture.view(), .{ .sampling = .mip_linear });
        try frame.draw(&renderer, &buffer, size);
        // 4px -> 1 physical pixel selects mip2; 1.5/2px selects mip1.
        try near(if (scale == 1) 0xff008000 else 0xff000080, frame.at(16, 16, scale));
        for ([_]drawing.ImageFit{ .stretch, .contain, .cover }) |fit| for ([_]drawing.ImageSampling{ .nearest, .linear, .mip_linear }) |sampling| {
            buffer.reset();
            try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, background);
            try buffer.pushClip(.{ .x = 4, .y = 4, .width = 36, .height = 36 });
            try buffer.texture(.{ .x = 8, .y = 8, .width = 24, .height = 16 }, view, .{ .fit = fit, .sampling = sampling, .opacity = 128 });
            try buffer.popClip();
            try expectError(error.ResourceInUse, texture.close());
            try frame.draw(&renderer, &buffer, size);
            try near(over(background, 128), frame.at(20, 16, scale));
            try near(0xff000000 | background, frame.at(6, 6, scale));
            if (fit == .contain) try near(0xff000000 | background, frame.at(9, 16, scale));
        };
        const before = try domain.stats();
        for (0..8) |_| try frame.draw(&renderer, &buffer, size);
        try equal(before.bitmap_creations, (try domain.stats()).bitmap_creations);
        // A foreign domain's texture fails the frame before even the fill
        // before it draws.
        const foreign = try resources.DeviceDomain.create(app, allocator, .{});
        defer foreign.close() catch unreachable;
        source.init();
        const other = try foreign.upload(source.view());
        defer other.close() catch unreachable;
        buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x00ff00);
        try buffer.texture(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, try other.view(), .{});
        try expectError(error.TextureDomainMismatch, frame.draw(&renderer, &buffer, size));
        // Only the command buffer still pins it; the rejected frame took none.
        try equal(@as(usize, 1), (try other.view()).lease.pins);
        buffer.reset();
        try equal(@as(usize, 0), (try other.view()).lease.pins);
    }
    std.debug.print("Metal domain: shared-device texture alpha/fit/mip/clip/3 scales and whole-frame rejection passed\n", .{});
}

fn lossAndStop(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    const domain = try resources.DeviceDomain.create(app, allocator, .{});
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    const view = try texture.view();
    var renderer: metal.Renderer = .{};
    var wait: ?z.NativeWaitToken = null;
    try renderer.init(.{ .domain = domain, .native_wait_slot = &wait });
    var second: metal.Renderer = .{};
    try second.init(.{ .domain = domain });
    var image_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var green = @as([16]u8, @bitCast(@as([4][4]u8, @splat(.{ 0, 128, 0, 128 }))));
    const levels = [_]drawing.ImageLevel{.{ .pixels = &green, .width = 2, .height = 2, .stride = 8, .byte_len = 16 }};
    const image: drawing.ImageView = .{ .lease = &image_lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    try renderer.uploadImage(image);
    var buffer: ui.commands.Buffer = .{};
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, view, .{});
    const size: z.Size = .{ .width = 32, .height = 32, .scale = 1 };
    var frame: Frame = .{};
    for ([_]*metal.Renderer{ &renderer, &second }) |current| {
        try frame.draw(current, &buffer, size);
        try near(0xffff7f7f, frame.at(16, 16, 1));
    }
    const before = (try domain.stats()).generation;
    try domain.injectDeviceLossForTest();
    try equal(before + 1, (try domain.stats()).generation);
    try equal(.lost, (try domain.stats()).status);
    try equal(@as(usize, 0), (try domain.stats()).pixel_bytes);
    try equal(@as(u32, 0), (try domain.stats()).native_objects);
    try expectError(error.TextureDeviceLost, texture.view());
    try expectError(error.ResourceInUse, texture.close());
    try expectError(error.DomainDeviceLost, renderer.beginOffscreen(size, false));
    try expectError(error.DomainDeviceLost, renderer.uploadImage(image));
    try expectError(error.DomainDeviceLost, domain.upload(source.view()));
    try domain.recreate();
    try equal(.ready, (try domain.stats()).status);
    try expectError(error.StaleTextureGeneration, texture.view());
    const replacement = try domain.upload(source.view());
    defer replacement.close() catch unreachable;
    buffer.reset();
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try replacement.view(), .{});
    // The renderer takes the new device: what it held uploads again.
    try buffer.image(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, image, .{ .sampling = .nearest });
    try check(!renderer.holdsFrame(&buffer), @src());
    try renderer.residentFrame(&buffer);
    try frame.draw(&renderer, &buffer, size);
    try near(0xff7fbf3f, frame.at(4, 4, 1));
    try near(0xffff7f7f, frame.at(16, 16, 1));
    try check(renderer.stats().device_creations == 2 and renderer.stats().device_losses == 1, @src());
    buffer.reset();
    try texture.close();
    // Stop drops every native object; the shells stay to be closed.
    const survivor = try domain.upload(source.view());
    try buffer.texture(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try survivor.view(), .{});
    app.quit();
    try app.finishShutdown();
    try equal(@as(u32, 0), (try domain.stats()).native_objects);
    try equal(@as(usize, 2), (try domain.stats()).attachments);
    try expectError(error.Closed, survivor.view());
    try expectError(error.ResourceInUse, survivor.close());
    try expectError(error.Closed, renderer.uploadImage(image));
    try check(try renderer.releaseImage(image.identity), @src());
    app.deinit();
    renderer.deinit();
    second.deinit();
    buffer.reset();
    try survivor.close();
    try image_lease.ensureUnused();
    try domain.close();
    try equal(@as(u32, 0), metal.globalResourceCount());
    std.debug.print("Metal domain: loss revokes textures and renderer objects, recreate, re-upload and stop shells passed\n", .{});
}

fn capacityAndFailure(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var source: Source = .{};
    source.init();
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .texture_bytes = 4096 });
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
    // At the representable boundary the generation does not wrap.
    @constCast(view.domain).generation = std.math.maxInt(u64);
    try domain.injectDeviceLossForTest();
    try equal(std.math.maxInt(u64), (try domain.stats()).generation);
    try equal(.exhausted, (try domain.stats()).status);
    try expectError(error.GenerationExhausted, domain.recreate());
    try expectError(error.GenerationExhausted, first.view());
}

fn allocationPass(allocator: std.mem.Allocator, app: *z.App) !void {
    const domain = try resources.DeviceDomain.create(app, allocator, .{});
    defer domain.close() catch unreachable;
    var source: Source = .{};
    source.init();
    const texture = try domain.upload(source.view());
    defer texture.close() catch unreachable;
}

fn surfaceBasic(allocator: std.mem.Allocator, scale: f32) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{});
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
    // Drawing the surface again never changes the snapshot.
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x00ff00);
    try surface.render(&buffer);
    const warm = (try surface.stats()).layers.native_creations;
    for (0..8) |_| try surface.render(&buffer);
    try equal(warm, (try surface.stats()).layers.native_creations);
    try surface.close();
    surface_alive = false;
    try equal(@as(usize, 0), (try domain.stats()).workspace_reservation);
    var renderer: metal.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    defer renderer.deinit();
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, 0x0000ff);
    try buffer.texture(.{ .x = 0, .y = 0, .width = 64, .height = 64 }, old_view, .{});
    var frame: Frame = .{};
    try frame.draw(&renderer, &buffer, size);
    try near(0xff80007f, frame.pixels[middle * side + middle]);
    try near(0xff0000ff, frame.pixels[0]);
    buffer.reset();
}

fn surfaceTransactions(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .texture_bytes = 256 * 1024 });
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
    try surface.render(&buffer); // the domain's snapshot as the surface's input
    buffer.reset();
    try surface.injectDeviceLossForTest();
    try expectError(error.DeviceLost, surface.render(&buffer));
    try equal(@as(usize, 0), (try surface.stats()).workspace_actual);
    try check((try surface.stats()).workspace_reserved != 0, @src());
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
    try equal(@as(u32, 0), metal.globalResourceCount());
}

fn surfaceMixed(allocator: std.mem.Allocator, scale: f32) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{});
    defer domain.close() catch unreachable;
    const size: z.Size = .{ .width = @intFromFloat(64 * scale), .height = @intFromFloat(48 * scale), .scale = scale };
    const surface = try Surface.create(domain, allocator, .{ .size = size, .max_depth = 4, .resident_bytes = 1024 * 1024 });
    var alive = true;
    defer if (alive) surface.close() catch unreachable;
    var mask_lease = drawing.Lease.init(std.Thread.getCurrentId());
    const mask_pixels = try allocator.alloc(u8, @as(usize, size.width) * size.height);
    defer allocator.free(mask_pixels);
    @memset(mask_pixels, 128);
    const mask: drawing.CoverageView = .{ .lease = &mask_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = mask_pixels, .width = size.width, .height = size.height, .stride = size.width, .origin_x = 0, .origin_y = 0, .scale = scale } };
    var image_lease = drawing.Lease.init(std.Thread.getCurrentId());
    var green = @as([16]u8, @bitCast(@as([4][4]u8, @splat(.{ 0, 128, 0, 128 }))));
    const levels = [_]drawing.ImageLevel{.{ .pixels = &green, .width = 2, .height = 2, .stride = 8, .byte_len = 16 }};
    const image: drawing.ImageView = .{ .lease = &image_lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
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
    try check(!(try surface.stats()).has_frame, @src());
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
    var glyphs: [2]usize = .{ 0, 0 };
    for (0..size.height) |y| for (0..size.width) |x| {
        const value = plane[y * size.width + x];
        inline for ([_]u5{ 0, 8, 16 }) |shift| try check(((value >> shift) & 255) <= value >> 24, @src());
        if (y >= @as(usize, @intFromFloat(32 * scale)) and value >> 24 > 128) {
            if (x < @as(usize, @intFromFloat(32 * scale))) glyphs[0] += 1;
            if (x >= @as(usize, @intFromFloat(40 * scale))) glyphs[1] += 1;
        }
    };
    try check(glyphs[0] > 0 and glyphs[1] > 0, @src());
    const snapshot = try surface.snapshot();
    defer snapshot.close() catch unreachable;
    const before = try surface.stats();
    for (0..8) |_| try surface.render(&buffer);
    try equal(before.layers.native_creations, (try surface.stats()).layers.native_creations);
    // A failed frame keeps the front it had.
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
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true, .stack_trace_frames = 0 }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    run(debug.allocator()) catch |err| {
        // Printed before the leak check of the abandoned run fires.
        std.debug.print("metal domain smoke failed: {s}\n", .{@errorName(err)});
        return err;
    };
}
fn run(allocator: std.mem.Allocator) !void {
    try raw(allocator);
    try equal(@as(u32, 0), metal.globalResourceCount());
    try lossAndStop(allocator);
    try capacityAndFailure(allocator);
    try equal(@as(u32, 0), metal.globalResourceCount());
    {
        const app = try z.App.init(allocator);
        defer app.deinit();
        try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{app});
    }
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try surfaceBasic(allocator, scale);
        try surfaceMixed(allocator, scale);
        try equal(@as(u32, 0), metal.globalResourceCount());
    }
    try surfaceTransactions(allocator);
    std.debug.print("Metal offscreen: transparent target, snapshots drawn by renderers, 3 scales, rollback, loss/stop passed\n", .{});
    try @import("gpu_domain_lifetime.zig").run(allocator);
    try equal(@as(u32, 0), metal.globalResourceCount());
    try @import("gpu_offscreen_lifetime.zig").run(allocator);
    try equal(@as(u32, 0), metal.globalResourceCount());
    std.debug.print("Metal domain: budgets, reentry, threads, window frames and surface lifetimes passed\n", .{});
}
