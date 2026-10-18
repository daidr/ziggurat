const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const images = @import("ziggurat_images");
const prepared = @import("ziggurat_image_drawing");
const drawing = prepared.drawing;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_image_objects() u32;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const background = 0x204060;
const Job = struct {
    allocator: std.mem.Allocator,
    main_thread: std.Thread.Id,
    resources: [36]?*prepared.PreparedImage = @splat(null),
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.prepare() catch |err| {
            self.failure = err;
        };
    }
    fn prepare(self: *Job) !void {
        errdefer self.close();
        var worker = try images.Worker.init(self.main_thread);
        defer worker.deinit();
        const color = try worker.decode(self.allocator, @embedFile("image_fixture/drawing.png"), .{});
        defer color.close() catch unreachable;
        const checker = try worker.decode(self.allocator, @embedFile("image_fixture/checker.png"), .{});
        defer checker.close() catch unreachable;
        const bands = try worker.decode(self.allocator, @embedFile("image_fixture/bands.png"), .{});
        defer bands.close() catch unreachable;
        const tiny = try worker.decode(self.allocator, @embedFile("image_fixture/colors.png"), .{});
        defer tiny.close() catch unreachable;
        self.resources[0] = try prepared.PreparedImage.create(self.allocator, color, .{});
        self.resources[1] = try prepared.PreparedImage.create(self.allocator, checker, .{});
        self.resources[2] = try prepared.PreparedImage.create(self.allocator, bands, .{ .source = .{ .x = 2, .width = 4, .height = 4 } });
        for (self.resources[3..]) |*resource| resource.* = try prepared.PreparedImage.create(self.allocator, tiny, .{});
    }
    fn close(self: *Job) void {
        for (&self.resources) |*resource| if (resource.*) |value| {
            value.close() catch unreachable;
            resource.* = null;
        };
    }
    fn view(self: *Job, index: usize) !drawing.ImageView {
        return self.resources[index].?.view();
    }
};
fn scene(buffer: *ui.commands.Buffer, job: *Job) !void {
    buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 256, .height = 160 }, background);
    const color = try job.view(0);
    try buffer.image(.{ .x = 8, .y = 8, .width = 32, .height = 32 }, color, .{ .sampling = .nearest });
    try buffer.image(.{ .x = 48, .y = 8, .width = 32, .height = 32 }, color, .{ .sampling = .linear });
    try buffer.image(.{ .x = 88, .y = 8, .width = 32, .height = 32 }, color, .{ .opacity = 128 });
    try buffer.image(.{ .x = 8, .y = 56, .width = 48, .height = 32 }, color, .{ .fit = .contain, .sampling = .nearest });
    try buffer.image(.{ .x = 64, .y = 56, .width = 48, .height = 24 }, color, .{ .fit = .cover, .sampling = .nearest });
    try buffer.image(.{ .x = 128, .y = 8, .width = 24, .height = 64 }, try job.view(2), .{});
    try buffer.image(.{ .x = 8, .y = 104, .width = 8, .height = 8 }, try job.view(1), .{ .sampling = .mip_linear });
    try buffer.image(.{ .x = 32, .y = 104, .width = 8, .height = 8 }, try job.view(1), .{ .sampling = .nearest });
    try buffer.pushClip(.{ .x = 72, .y = 104, .width = 16, .height = 16 });
    try buffer.image(.{ .x = 64, .y = 96, .width = 48, .height = 40 }, color, .{ .sampling = .nearest });
    try buffer.popClip();
    // No residency is required for an entirely invisible command.
    try buffer.image(.{ .x = 176, .y = 8, .width = 32, .height = 32 }, try job.view(35), .{ .opacity = 0 });
    try buffer.finish();
}
fn physical(point: u32, scale: f32) u32 {
    return @intFromFloat(@as(f32, @floatFromInt(point)) * scale);
}
fn read(renderer: anytype, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) return renderer.readPixelForTest(x, y);
    if (builtin.os.tag == .windows) {
        const value = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (value == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn near(expected: u32, actual: u32) !void {
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((expected >> shift) & 255);
        const b: i32 = @intCast((actual >> shift) & 255);
        if (@abs(a - b) > 3) {
            std.debug.print("image pixel expected={x:0>6}, actual={x:0>6}\n", .{ expected, actual });
            return error.ImagePixelMismatch;
        }
    }
}
fn checkScene(renderer: anytype, scale: f32) !void {
    const Probe = struct { x: u32, y: u32, color: u32 };
    for ([_]Probe{
        .{ .x = 12, .y = 12, .color = 0xff0000 },
        .{ .x = 32, .y = 12, .color = 0x10a030 },
        .{ .x = 12, .y = 32, .color = background },
        .{ .x = 32, .y = 32, .color = 0xffffff },
        .{ .x = 92, .y = 12, .color = 0x902030 },
        .{ .x = 10, .y = 60, .color = background },
        .{ .x = 20, .y = 60, .color = 0xff0000 },
        .{ .x = 68, .y = 60, .color = 0xff0000 },
        .{ .x = 104, .y = 60, .color = 0x10a030 },
        .{ .x = 128, .y = 12, .color = 0x00ff00 },
        .{ .x = 151, .y = 68, .color = 0x00ff00 },
        .{ .x = 152, .y = 68, .color = background },
        .{ .x = 10, .y = 106, .color = 0x1020b0 },
        .{ .x = 32, .y = 104, .color = background },
        .{ .x = 74, .y = 106, .color = 0xff0000 },
        .{ .x = 70, .y = 106, .color = background },
        .{ .x = 180, .y = 12, .color = background },
    }) |probe| {
        errdefer std.debug.print("image probe DIP ({d},{d}), scale {d}\n", .{ probe.x, probe.y, scale });
        try near(probe.color, try read(renderer, physical(probe.x, scale), physical(probe.y, scale)));
    }
    // A boundary sample of linear red/half-transparent green must interpolate
    // premultiplied channels. Transparent RGB never contributes to the result.
    const fx = (@as(f64, @floatFromInt(physical(64, scale))) + 0.5) / scale;
    const weight = (fx - 48) / 2 - 7.5;
    const alpha = 1 - weight * (127.0 / 255.0);
    const red = 255 * (1 - weight) + 32 * (1 - alpha);
    const green = 128 * weight + 64 * (1 - alpha);
    const blue = 96 * (1 - alpha);
    const expected = (@as(u32, @intFromFloat(@round(red))) << 16) | (@as(u32, @intFromFloat(@round(green))) << 8) | @as(u32, @intFromFloat(@round(blue)));
    try near(expected, try read(renderer, physical(64, scale), physical(12, scale)));
}
fn finish(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.end(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn render(renderer: anytype, job: *Job, context: *anyopaque, window: ?*anyopaque) !void {
    for (0..3) |i| try renderer.uploadImage(try job.view(i));
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = physical(256, scale), .height = physical(160, scale), .scale = scale } };
        try scene(&buffer, job);
        for (0..2) |_| {
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try checkScene(renderer, scale);
            try finish(renderer, paint);
        }
        buffer.reset();
    }
    const stats = renderer.imageStats();
    try equal(0, stats.misses);
    const uploads = stats.uploads;
    const objects = stats.native_objects;
    for (0..3) |i| try renderer.uploadImage(try job.view(i));
    try equal(uploads, renderer.imageStats().uploads);
    try equal(objects, renderer.imageStats().native_objects);
    if (builtin.os.tag != .windows or @TypeOf(renderer.*) != ui.SoftwareRenderer) {
        try equal(3, stats.uploads);
        try equal(3, stats.resident_entries);
        for (0..3) |i| {
            try expect(try job.resources[i].?.inUse());
            _ = try renderer.releaseImage((try job.view(i)).identity);
        }
    } else try equal(0, stats.native_objects);
}
fn cache(renderer: anytype, job: *Job, context: *anyopaque, window: ?*anyopaque) !void {
    const first = try job.view(3);
    const second = try job.view(4);
    try renderer.setImageBudget(first.pixelBytes());
    try renderer.uploadImage(first);
    const before = renderer.imageStats();
    renderer.injectImageUploadFailureForTest(2);
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try expectError(error.ImageUploadFailed, renderer.uploadImage(second)) else try expectError(error.GraphicsFailed, renderer.uploadImage(second));
    const failed = renderer.imageStats();
    try equal(before.resident_entries, failed.resident_entries);
    try equal(before.pixel_bytes, failed.pixel_bytes);
    try equal(before.native_objects, failed.native_objects);
    try equal(before.evictions, failed.evictions);
    try equal(before.uploads, failed.uploads);
    try equal(@max(before.peak_reserved_bytes, 2 * first.pixelBytes()), failed.peak_reserved_bytes);
    try expect(try job.resources[3].?.inUse());
    try expect(!try job.resources[4].?.inUse());
    const paint: z.Paint = .{ .native_context = context, .native_window = window, .size = .{ .width = 256, .height = 160, .scale = 1 } };
    try renderer.begin(paint);
    try renderer.image(first, .{ .x = 0, .y = 0, .width = 20, .height = 30 }, .{ .sampling = .nearest });
    try near(0xff0000, try read(renderer, 2, 2));
    try finish(renderer, paint);
    try renderer.uploadImage(second);
    try expect(!try job.resources[3].?.inUse());
    try expect(try job.resources[4].?.inUse());
    try renderer.setImageBudget(1);
    try expect(!try job.resources[4].?.inUse());
    try equal(0, renderer.imageStats().native_objects);
    try expectError(error.ImageBudgetExceeded, renderer.uploadImage(first));
    try expect(!try renderer.releaseImage(second.identity));
    try renderer.setImageBudget(drawing.default_image_budget);
    for (3..35) |i| try renderer.uploadImage(try job.view(i));
    try equal(32, renderer.imageStats().resident_entries);
    // Refresh the oldest. Capacity eviction must then select the second entry.
    try renderer.uploadImage(first);
    try renderer.uploadImage(try job.view(35));
    try expect(try job.resources[3].?.inUse());
    try expect(!try job.resources[4].?.inUse());
    try equal(32, renderer.imageStats().resident_entries);
    try renderer.begin(paint);
    try expectError(error.ImageNotUploaded, renderer.image(second, .{ .x = 0, .y = 0, .width = 20, .height = 30 }, .{}));
    try finish(renderer, paint);
    for (3..36) |i| _ = try renderer.releaseImage((try job.view(i)).identity);
    try equal(0, renderer.imageStats().native_objects);
    try equal(0, renderer.imageStats().pixel_bytes);
}
const State = struct {
    resource: *prepared.PreparedImage,
    context: *ui.Context = undefined,
    window: z.Window = undefined,
    err: ?anyerror = null,
    bad_frame: bool = false,
    close_in_draw: bool = false,
    expected_diagnostic: ?anyerror = null,
    diagnostics: usize = 0,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected_diagnostic) |wanted| actual == wanted else false else false;
        if (matches) self.diagnostics += 1 else self.err = value.err orelse error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.checked(frame) catch |err| {
            self.err = err;
        };
    }
    fn checked(self: *State, frame: *ui.Frame) !void {
        frame.clear(background);
        try frame.image(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try self.resource.view(), .{ .sampling = .nearest });
        try expectError(error.ResourceInUse, self.resource.close());
        try expectError(error.Busy, self.context.releaseImage((try self.resource.view()).identity));
        if (self.bad_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_in_draw) try equal(z.CloseResult.deferred, try self.window.destroy());
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const size = try self.window.clientBounds();
            zlg_test_paint(self.window.app.windows.get(self.window.key).?.native.native.?, size.width, size.height);
        }
        if (self.err) |err| return err;
    }
};
fn integrated(allocator: std.mem.Allocator, job: *Job, gpu: bool) !void {
    var state: State = .{ .resource = job.resources[0].? };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = if (gpu) .warp else .gdi;
    state.context = &context;
    const window = try app.createWindow(.{});
    state.window = window;
    try context.attach(window);
    try context.uploadImage(try state.resource.view());
    try state.paint();
    const residency: usize = if (gpu or builtin.os.tag != .windows) 1 else 0;
    try equal(residency, (try state.resource.view()).lease.pins);
    state.bad_frame = true;
    state.expected_diagnostic = error.InvalidGeometry;
    try state.paint();
    try equal(1, state.diagnostics);
    try equal(residency, (try state.resource.view()).lease.pins);
    state.bad_frame = false;
    state.expected_diagnostic = null;
    if (ui.capabilities.gpu) if (gpu) {
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        context.gpu_renderer.injectImageUploadDeviceLossForTest();
        try expectError(error.DeviceLost, context.uploadImage(try job.view(1)));
        try expect(context.gpu_wait == null);
        try expect(!app.unwatchNative(token));
        for (app.native.waits) |wait| try expect(wait.handle == null);
        try equal(residency, (try state.resource.view()).lease.pins);
        try expect(!try job.resources[1].?.inUse());
        try state.paint();
        try expect((try context.imageStats()).gpu.?.restores > 0);
        context.gpu_renderer.injectDeviceLoss();
        state.expected_diagnostic = error.DeviceLost;
        try state.paint();
        try equal(1, context.fallbacks);
        try near(0xff0000, try read(&context.renderer, 2, 2));
        state.expected_diagnostic = null;
    };
    _ = try context.releaseImage((try state.resource.view()).identity);
    try expect(!try state.resource.inUse());
    try context.uploadImage(try state.resource.view());
    state.close_in_draw = true;
    try state.paint();
    try expect(window.isClosed());
    try app.run();
    try equal(0, (try state.resource.view()).lease.pins);
    try expect(context.window == null);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    var job: Job = .{ .allocator = allocator, .main_thread = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    thread.join();
    defer job.close();
    if (job.failure) |err| return err;
    for (job.resources) |resource| try resource.?.adopt();
    try equal(0, images.nativeReferences());
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                try render(&renderer, &job, dc, hwnd);
            }
            try equal(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try render(&renderer, &job, dc, hwnd);
                try cache(&renderer, &job, dc, hwnd);
                renderer.deinit();
                try equal(0, ui.d3d11.globalResourceCount());
                std.debug.print("images {s}: pixels/DPI/crop/fit/alpha/mips; transactional mip failure, LRU32, resources=0\n", .{@tagName(driver)});
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 512, 320) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const dc = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(dc);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try render(&renderer, &job, dc, null);
        try cache(&renderer, &job, dc, null);
        renderer.deinit();
        try equal(0, zlc_test_live_image_objects());
    }
    try integrated(allocator, &job, false);
    if (ui.capabilities.gpu) try integrated(allocator, &job, true);
    for (job.resources) |resource| try expect(!try resource.?.inUse());
    std.debug.print("images: software pixels/DPI/crop/fit/premultiplied sampling and Context failed-frame/close pins passed\n", .{});
}
