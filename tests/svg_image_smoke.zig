const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const svg = @import("ziggurat_svg");
const images = @import("ziggurat_images");
const resource = @import("ziggurat_image_drawing");
const drawing = resource.drawing;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_image_objects() u32;
const png = @embedFile("image_fixture/colors.png");
fn encoded() [std.base64.standard.Encoder.calcSize(png.len)]u8 {
    var result: [std.base64.standard.Encoder.calcSize(png.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, png);
    return result;
}
const key = "data:image/png;base64," ++ encoded();
const Mode = @FieldType(svg.PrepareOptions, "compositing");
const Job = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    image: ?*resource.PreparedImage = null,
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.prepare() catch |err| {
            self.failure = err;
        };
    }
    fn prepare(self: *Job) !void {
        var worker = try images.Worker.init(self.main_thread);
        defer worker.deinit();
        const decoded = try worker.decode(self.allocator, png, .{});
        defer decoded.close() catch unreachable;
        self.image = try resource.PreparedImage.create(self.allocator, decoded, .{});
    }
};
const Provider = struct {
    lease: drawing.Lease,
    image: *resource.PreparedImage,
    calls: usize = 0,
    fn resolve(context: *anyopaque, uri: []const u8) !drawing.ImageView {
        const self: *Provider = @ptrCast(@alignCast(context));
        try std.testing.expectEqualStrings(key, uri);
        try std.testing.expectEqual(@as(usize, 1), self.lease.pins);
        self.calls += 1;
        return self.image.view();
    }
    fn interface(self: *Provider) svg.image.Provider {
        return .{ .context = self, .lease = &self.lease, .resolve_fn = resolve };
    }
};
fn allocationTrial(allocator: std.mem.Allocator, document: *svg.Document, provider: *Provider, mode: Mode) !void {
    const interface = provider.interface();
    const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = 128, .height = 48, .compositing = mode, .image_provider = &interface });
    defer output.close() catch unreachable;
}
// Fixed decoded source values, including transparent RGB suppression.
const colors = [6][4]f64{ .{ 0, 0, 255, 255 }, .{ 0, 128, 0, 128 }, .{ 0, 0, 0, 0 }, .{ 0, 255, 255, 255 }, .{ 64, 0, 64, 64 }, .{ 255, 255, 0, 255 } };
fn oracle(px: f64, py: f64, fixture: usize, scale: f64) [4]f64 {
    // Independent positioning rectangle [16,80] x [8,40], raster 2x3.
    const sx: f64 = if (fixture != 1) 32 else 32.0 / 3.0;
    const sy: f64 = if (fixture == 0 or fixture == 1) 32.0 / 3.0 else 32;
    const tx: f64 = if (fixture == 1) 16 + (64 - 64.0 / 3.0) / 2.0 else 16;
    const ty: f64 = if (fixture >= 2) -24 else 8;
    const local_x = px / scale - (if (fixture == 3) 0.25 * py / scale - 4 else 0);
    const x = std.math.clamp((local_x - tx) / sx - 0.5, 0, 1);
    const y = std.math.clamp((py / scale - ty) / sy - 0.5, 0, 2);
    const ix: usize = @intFromFloat(@floor(x));
    const iy: usize = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const weights = [4]f64{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
    const ix1: usize = @min(ix + 1, 1);
    const iy1: usize = @min(iy + 1, 2);
    const indices = [4]usize{ iy * 2 + ix, iy * 2 + ix1, iy1 * 2 + ix, iy1 * 2 + ix1 };
    var result: [4]f64 = @splat(0);
    for (indices, weights) |at, weight| for (&result, colors[at]) |*channel, byte| {
        channel.* += byte * weight;
    };
    var covered: u16 = 0;
    const left = @max(16, tx);
    const right = @min(80, tx + 2 * sx);
    const top = @max(8, ty);
    const bottom = @min(40, ty + 3 * sy);
    for (0..4) |ry| for (0..4) |rx| {
        const output_x = (px - 0.5 + (@as(f64, @floatFromInt(rx)) + 0.5) / 4) / scale;
        const y_sample = (py - 0.5 + (@as(f64, @floatFromInt(ry)) + 0.5) / 4) / scale;
        const x_sample = output_x - (if (fixture == 3) 0.25 * y_sample - 4 else 0);
        if (x_sample >= left and x_sample < right and y_sample >= top and y_sample < bottom) covered += 1;
    };
    for (&result) |*channel| channel.* *= @as(f64, @floatFromInt(covered)) / 16;
    return result;
}
fn verify(image: *svg.Prepared, fixture: usize, scale: f64) !void {
    const level = (try image.view()).levels[0];
    for (0..level.height) |y| for (0..level.width) |x| {
        const expected = oracle(@as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5, fixture, scale);
        const actual = level.pixels[y * level.stride + x * 4 ..][0..4];
        for (actual, expected) |got, want| if (@abs(@as(i32, got) - @as(i32, @intFromFloat(@round(want)))) > 1) {
            std.debug.print("image oracle fixture={d} scale={d} at={d},{d} got={any} want={any}\n", .{ fixture, scale, x, y, actual, expected });
            return error.EmbeddedImageOracleMismatch;
        };
    };
}
fn read(renderer: anytype, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) return renderer.readPixelForTest(x, y);
    if (builtin.os.tag == .windows) {
        const pixel = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (pixel == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((pixel & 255) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn replay(renderer: anytype, image: *svg.Prepared, scale: f32, context: *anyopaque, window: ?*anyopaque) !void {
    const view = try image.view();
    const level = view.levels[0];
    try renderer.uploadImage(view);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 128, .height = 48 }, 0x204060);
    try buffer.pushClip(.{ .x = 12, .y = 0, .width = 112, .height = 48 });
    try buffer.image(.{ .x = 0, .y = 0, .width = 128, .height = 48 }, view, .{ .sampling = .nearest });
    try buffer.popClip();
    try std.testing.expectError(error.ResourceInUse, image.close());
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = level.width, .height = level.height, .scale = scale } };
    for (0..4) |pass| {
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        if (pass == 0) for (0..level.height) |y| for (0..level.width) |x| {
            const pixel = level.pixels[y * level.stride + x * 4 ..][0..4];
            const actual = try read(renderer, @intCast(x), @intCast(y));
            inline for ([_]u5{ 0, 8, 16 }) |shift| {
                const channel = shift / 8;
                const background: f64 = @floatFromInt((@as(u32, 0x204060) >> shift) & 255);
                const expected: u8 = if (@as(f64, @floatFromInt(x)) >= 12 * scale and @as(f64, @floatFromInt(x)) < 124 * scale) @intFromFloat(@round(@as(f64, @floatFromInt(pixel[channel])) + background * (1 - @as(f64, @floatFromInt(pixel[3])) / 255))) else @intFromFloat(background);
                const got: u8 = @truncate(actual >> shift);
                if (@abs(@as(i32, expected) - @as(i32, got)) > 2) return error.NativeTextPixelMismatch;
            }
        };
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
            if (err != error.PresentationBusy) return err;
        };
    }
    const warmed = renderer.imageStats().native_creations;
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
    try std.testing.expectEqual(warmed, renderer.imageStats().native_creations);
    buffer.reset();
    _ = try renderer.releaseImage(view.identity);
    try image.lease.ensureUnused();
}
fn nativeReplay(allocator: std.mem.Allocator, image: *svg.Prepared, scale: f32) !void {
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.NoSurface;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                try replay(&renderer, image, scale, dc, hwnd);
            }
            try std.testing.expectEqual(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try replay(&renderer, image, scale, dc, hwnd);
                renderer.deinit();
                try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 256, 96) orelse return error.NoSurface;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.NoSurface;
        defer cairo_destroy(context);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try replay(&renderer, image, scale, context, null);
        renderer.deinit();
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
}

pub fn main() !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(heap.deinit() == .ok);
    const allocator = heap.allocator();
    var job: Job = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    thread.join();
    if (job.failure) |err| return err;
    const raster = job.image.?;
    var raster_open = true;
    defer if (raster_open) raster.close() catch unreachable;
    try raster.adopt();
    var provider: Provider = .{ .lease = drawing.Lease.init(std.Thread.getCurrentId()), .image = raster };
    const interface = provider.interface();
    const input = (try raster.view()).levels[0];
    for (colors, 0..) |pixel, i| for (pixel, 0..) |channel, c_index| try std.testing.expectEqual(@as(u8, @intFromFloat(channel)), input.pixels[i * 4 + c_index]);
    const aspects = [_][]const u8{ "none", "xMidYMid meet", "xMidYMid slice", "xMidYMid slice" };
    for ([_]Mode{ .pixel, .sample_color }) |mode| for (aspects, 0..) |aspect, fixture| {
        const source = try std.fmt.allocPrint(allocator, "<svg viewBox='0 0 128 48'><image href='{s}' x='16' y='8' width='64' height='32' preserveAspectRatio='{s}' {s}/></svg>", .{ key, aspect, if (fixture == 3) "transform='matrix(1 0 .25 1 -4 0)'" else "" });
        defer allocator.free(source);
        const document = try svg.Document.parse(allocator, source, .{});
        defer document.close() catch unreachable;
        if (fixture == 0) {
            try std.testing.checkAllAllocationFailures(allocator, allocationTrial, .{ document, &provider, mode });
            try provider.lease.ensureUnused();
            try (try raster.view()).lease.ensureUnused();
        }
        for ([_]f32{ 1, 1.5, 2 }) |scale| {
            const output = try document.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .width = @intFromFloat(128 * scale), .height = @intFromFloat(48 * scale), .compositing = mode, .image_provider = &interface });
            defer output.close() catch unreachable;
            try std.testing.expectEqual(@as(usize, 0), provider.lease.pins);
            try (try raster.view()).lease.ensureUnused();
            if (mode == .sample_color and fixture == 3 and scale == 2) {
                try raster.close();
                raster_open = false;
            }
            try verify(output, fixture, scale);
            try nativeReplay(allocator, output, scale);
        }
        std.debug.print("SVG embedded image {s}/{s}/fixture{d}: codec fixed pixels, independent 3-DPI bilinear/coverage oracle, native replay and leases=0\n", .{ @tagName(mode), aspect, fixture });
    };
    std.debug.print("SVG embedded image provider requests={d}; explicit worker decode, immutable resource lookup, owned snapshots\n", .{provider.calls});
}
