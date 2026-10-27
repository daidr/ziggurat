const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const images = @import("ziggurat_images");
const prepared = @import("ziggurat_image_drawing");
const drawing = prepared.drawing;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
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
const Job = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    resources: [6]?*prepared.PreparedImage = @splat(null),
    err: ?anyerror = null,
    fn run(self: *Job) void {
        self.prepare() catch |err| {
            self.err = err;
        };
    }
    fn prepare(self: *Job) !void {
        errdefer self.close();
        var worker = try images.Worker.init(self.owner);
        defer worker.deinit();
        const red = try worker.decode(self.allocator, @embedFile("image_fixture/update-red.png"), .{});
        defer red.close() catch unreachable;
        const blue = try worker.decode(self.allocator, @embedFile("image_fixture/update-blue.png"), .{});
        defer blue.close() catch unreachable;
        const tiny = try worker.decode(self.allocator, @embedFile("image_fixture/colors.png"), .{});
        defer tiny.close() catch unreachable;
        for (&self.resources, 0..) |*resource, i| resource.* = try prepared.PreparedImage.create(self.allocator, if (i == 4) tiny else if (i % 2 == 0) red else blue, .{});
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
fn native(comptime T: type) bool {
    return builtin.os.tag != .windows or T != ui.SoftwareRenderer;
}
fn pixel(renderer: anytype, x: u32, y: u32) !u32 {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) return renderer.readPixelForTest(x, y);
    if (builtin.os.tag == .windows) {
        const value = c.GetPixel(renderer.dc, @intCast(x), @intCast(y));
        if (value == c.CLR_INVALID) return error.ReadPixelFailed;
        return ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
    }
    return zlc_test_raw_pixel(renderer.native.?, x, y);
}
fn finish(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.end(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn paintImage(renderer: anytype, view: drawing.ImageView, paint: z.Paint, color: u32) !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(.{ .x = 0, .y = 0, .width = 128, .height = 64 }, 0xffffff);
    try buffer.image(.{ .x = 4, .y = 4, .width = 32, .height = 32 }, view, .{ .sampling = .nearest });
    try buffer.image(.{ .x = 48, .y = 4, .width = 1, .height = 1 }, view, .{ .sampling = .mip_linear });
    try renderer.begin(paint);
    try renderer.replayBuffer(&buffer);
    const scale = paint.size.scale;
    try equal(color, try pixel(renderer, @intFromFloat(8 * scale), @intFromFloat(8 * scale)));
    try equal(color, try pixel(renderer, @intFromFloat(48 * scale), @intFromFloat(4 * scale)));
    try finish(renderer, paint);
}
fn runRenderer(renderer: anytype, observer: anytype, job: *Job, paint: z.Paint) !void {
    const a = try job.view(0);
    const b = try job.view(1);
    const duplicate = try job.view(5);
    const multiplier: usize = if (comptime native(@TypeOf(renderer.*))) 2 else 1;
    const charge = a.pixelBytes() * multiplier;
    try renderer.setImageBudget(charge - 1);
    try expectError(error.ImageBudgetExceeded, renderer.uploadDynamicImage(a));
    try equal(0, renderer.imageStats().resident_entries);
    try renderer.setImageBudget(charge);
    try renderer.uploadDynamicImage(a);
    try observer.uploadDynamicImage(a);
    try equal(2, a.lease.residency_pins);
    try equal(2, a.lease.pins);
    const initial = renderer.imageStats();
    try equal(charge, initial.pixel_bytes);
    try equal(1, initial.dynamic_entries);
    try renderer.uploadDynamicImage(a);
    try renderer.uploadImage(a);
    try equal(initial.native_creations, renderer.imageStats().native_creations);
    try equal(initial.uploads, renderer.imageStats().uploads);
    var old_frame: ui.commands.Buffer = .{};
    defer old_frame.reset();
    try old_frame.image(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, a, .{});
    try expectError(error.ResourceInUse, renderer.updateImage(a.identity, b));
    try equal(initial.updates, renderer.imageStats().updates);
    old_frame.reset();
    try expectError(error.ImageShapeMismatch, renderer.updateImage(a.identity, try job.view(4)));
    try expectError(error.ImageNotUploaded, renderer.updateImage(0, b));
    if (comptime native(@TypeOf(renderer.*))) {
        // Fail after a complete first candidate bank. The old entry still fits
        // the budget and must not be evicted before both banks are available.
        renderer.injectImageUploadFailureForTest(@intCast(a.levels.len + 1));
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try expectError(error.ImageUploadFailed, renderer.uploadDynamicImage(duplicate)) else try expectError(error.GraphicsFailed, renderer.uploadDynamicImage(duplicate));
        try equal(initial.native_objects, renderer.imageStats().native_objects);
        try equal(initial.evictions, renderer.imageStats().evictions);
        try equal(initial.pixel_bytes, renderer.imageStats().pixel_bytes);
        try equal(0, duplicate.lease.pins);
        try paintImage(renderer, a, paint, 0xff0000);
    }
    try renderer.updateImage(a.identity, b);
    try equal(1, a.lease.residency_pins); // observer retains the old immutable view
    try equal(1, b.lease.residency_pins);
    try paintImage(renderer, b, paint, 0x0000ff);
    try paintImage(observer, a, paint, 0xff0000);
    if (comptime native(@TypeOf(renderer.*))) {
        try renderer.begin(paint);
        try expectError(error.ImageNotUploaded, renderer.image(a, .{ .x = 4, .y = 4, .width = 32, .height = 32 }, .{}));
        try finish(renderer, paint);
    } else try paintImage(renderer, a, paint, 0xff0000);
    // Exact transition retry is bounded to the most recent commit and does not
    // copy again. An unrelated missing identity must not be accepted.
    const committed = renderer.imageStats();
    try renderer.updateImage(a.identity, b);
    try equal(committed.updates, renderer.imageStats().updates);
    try equal(committed.native_creations, renderer.imageStats().native_creations);
    try expectError(error.ImageNotUploaded, renderer.updateImage((try job.view(2)).identity, b));
    if (comptime native(@TypeOf(renderer.*))) {
        renderer.injectImageUpdateFailureForTest(2);
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try expectError(error.ImageUpdateFailed, renderer.updateImage(b.identity, a)) else try expectError(error.GraphicsFailed, renderer.updateImage(b.identity, a));
        try equal(committed.updates, renderer.imageStats().updates);
        try equal(committed.native_objects, renderer.imageStats().native_objects);
        try equal(committed.pixel_bytes, renderer.imageStats().pixel_bytes);
        try equal(1, b.lease.residency_pins);
        try paintImage(renderer, b, paint, 0x0000ff); // base and 1x1 mip both stay blue
    }
    const creations = renderer.imageStats().native_creations;
    for (0..32) |_| {
        try renderer.updateImage(b.identity, a);
        try paintImage(renderer, a, paint, 0xff0000);
        try renderer.updateImage(a.identity, b);
        try paintImage(renderer, b, paint, 0x0000ff);
    }
    try equal(creations, renderer.imageStats().native_creations);
    try equal(initial.native_objects, renderer.imageStats().native_objects);
    try equal(65, renderer.imageStats().updates);
    try equal(65 * a.pixelBytes(), renderer.imageStats().update_bytes);
    var resized = paint;
    resized.size = .{ .width = 256, .height = 128, .scale = 2 };
    try paintImage(renderer, b, resized, 0x0000ff);
    try equal(creations, renderer.imageStats().native_creations);
    try equal(initial.native_objects, renderer.imageStats().native_objects);
    try equal(1, b.lease.residency_pins);
    try paintImage(renderer, b, paint, 0x0000ff);
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
        renderer.injectImageUpdateDeviceLossAtMipForTest(2);
        try expectError(error.DeviceLost, renderer.updateImage(b.identity, a));
        try equal(0, renderer.imageStats().native_objects);
        try equal(65, renderer.imageStats().updates);
        try paintImage(renderer, b, paint, 0x0000ff);
        try expect(renderer.imageStats().restores > 0);
        try equal(initial.native_objects, renderer.imageStats().native_objects);
    }
    // A normal static entry cannot be upgraded implicitly or consumed by an
    // update of another entry. GDI static uploads intentionally have no registry.
    if (comptime native(@TypeOf(renderer.*))) {
        try renderer.setImageBudget(charge * 2);
        try renderer.uploadImage(duplicate);
        try expectError(error.ImageNotDynamic, renderer.uploadDynamicImage(duplicate));
        try expectError(error.ImageAlreadyUploaded, renderer.updateImage(b.identity, duplicate));
        try expectError(error.ImageNotDynamic, renderer.updateImage(duplicate.identity, a));
        _ = try renderer.releaseImage(duplicate.identity);
    }
    try renderer.setImageBudget(charge - 1);
    try equal(0, renderer.imageStats().dynamic_entries);
    try equal(0, renderer.imageStats().native_objects);
    try equal(0, b.lease.pins);
    try expect(!try renderer.releaseImage(b.identity));
    _ = try observer.releaseImage(a.identity);
    try equal(0, a.lease.pins);
}
const State = struct {
    current: *prepared.PreparedImage,
    replacement: *prepared.PreparedImage,
    context: *ui.Context = undefined,
    window: z.Window = undefined,
    err: ?anyerror = null,
    close_in_draw: bool = false,
    expected: ?anyerror = null,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected) |wanted| actual == wanted else false else false;
        if (!matches) self.err = value.err orelse error.UnexpectedDiagnostic;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.checked(frame) catch |err| {
            self.err = err;
        };
    }
    fn checked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try frame.image(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, try self.current.view(), .{ .sampling = .nearest });
        try expectError(error.ResourceInUse, self.current.close());
        try expectError(error.Busy, self.context.updateImage((try self.current.view()).identity, try self.replacement.view()));
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
    var state: State = .{ .current = job.resources[0].?, .replacement = job.resources[1].? };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = if (gpu) .warp else .gdi;
    state.context = &context;
    const window = try app.createWindow(.{});
    state.window = window;
    try context.attach(window);
    const a = try job.view(0);
    const b = try job.view(1);
    try context.uploadDynamicImage(a);
    try state.paint();
    if (ui.capabilities.gpu) if (gpu) {
        context.gpu_renderer.injectImageUpdateFailureForTest(2);
        try expectError(error.GraphicsFailed, context.updateImage(a.identity, b));
        try equal(1, (try context.imageStats()).software.updates);
        try equal(0, (try context.imageStats()).gpu.?.updates);
        try context.updateImage(a.identity, b); // software exact transition is no-op
        try equal(1, (try context.imageStats()).software.updates);
        try equal(1, (try context.imageStats()).gpu.?.updates);
        state.current = job.resources[1].?;
        state.replacement = job.resources[0].?;
        try state.paint();
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        context.gpu_renderer.injectImageUpdateDeviceLossAtMipForTest(2);
        try expectError(error.DeviceLost, context.updateImage(b.identity, a));
        try expect(context.gpu_wait == null);
        try expect(!app.unwatchNative(token));
        for (app.native.waits) |wait| try expect(wait.handle == null);
        // Keep the old business view until the transition succeeds. Recovery
        // uses the last committed GPU CPU snapshot, not partial inactive data.
        try state.paint();
        try expect((try context.imageStats()).gpu.?.restores > 0);
        context.gpu_renderer.injectDeviceLoss();
        state.expected = error.DeviceLost;
        try state.paint();
        try equal(1, context.fallbacks);
        try equal(0x0000ff, try pixel(&context.renderer, 8, 8));
        state.expected = null;
        try context.updateImage(b.identity, a);
        state.current = job.resources[0].?;
        state.replacement = job.resources[1].?;
    } else {
        try context.updateImage(a.identity, b);
        state.current = job.resources[1].?;
        state.replacement = job.resources[0].?;
    } else {
        try context.updateImage(a.identity, b);
        state.current = job.resources[1].?;
        state.replacement = job.resources[0].?;
    }
    try state.paint();
    const view = try state.current.view();
    try equal(view.lease.pins, view.lease.residency_pins);
    state.close_in_draw = true;
    try state.paint();
    try expect(window.isClosed());
    try app.run();
    try expect(context.window == null);
    try equal(0, a.lease.pins);
    try equal(0, b.lease.pins);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    var job: Job = .{ .allocator = allocator, .owner = std.Thread.getCurrentId() };
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    thread.join();
    defer job.close();
    if (job.err) |err| return err;
    for (job.resources) |resource| try resource.?.adopt();
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const handles = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            const paint: z.Paint = .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = 128, .height = 64, .scale = 1 } };
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                var observer: ui.SoftwareRenderer = .{};
                defer observer.deinit();
                try runRenderer(&renderer, &observer, &job, paint);
            }
            try equal(handles, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                var observer: ui.d3d11.Renderer = .{};
                try observer.init(.{ .driver = driver });
                defer observer.deinit();
                try runRenderer(&renderer, &observer, &job, paint);
                renderer.deinit();
                observer.deinit();
                try equal(0, ui.d3d11.globalResourceCount());
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 128, 64) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const dc = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(dc);
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        var observer: ui.SoftwareRenderer = .{};
        defer observer.deinit();
        try runRenderer(&renderer, &observer, &job, .{ .native_context = dc, .size = .{ .width = 128, .height = 64, .scale = 1 } });
        renderer.deinit();
        observer.deinit();
        try equal(0, zlc_test_live_image_objects());
    }
    try integrated(allocator, &job, false);
    if (ui.capabilities.gpu) try integrated(allocator, &job, true);
    for (job.resources) |resource| try expect(!try resource.?.inUse());
    std.debug.print("dynamic images: real base/mip pixels, 65 commits with stable native objects, failed-bank rollback/retry, cross-renderer/Frame leases, DPI/resize, budget and Context close passed\n", .{});
    if (ui.capabilities.gpu) std.debug.print("dynamic GPU: hardware/WARP mid-mip device-loss recovery, Context partial-commit retry, pending-watch cancellation and old-version GDI fallback passed\n", .{});
}
