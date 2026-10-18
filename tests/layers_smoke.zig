const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const text = @import("ziggurat_text_layout");
const drawing = ui.drawing;
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
}) else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn near(want: u32, got: u32) !void {
    inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const a: i32 = @intCast((want >> shift) & 255);
        const b: i32 = @intCast((got >> shift) & 255);
        if (@abs(a - b) > 3) {
            std.debug.print("layer pixel expected={x}, actual={x}\n", .{ want, got });
            return error.LayerPixelMismatch;
        }
    }
}
fn overWhite(value: u32, opacity: f64) u32 {
    const alpha = @as(f64, @floatFromInt(value >> 24)) * opacity;
    var result: u32 = 0xff000000;
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const source: f64 = @floatFromInt((value >> shift) & 255);
        const channel: u32 = @intFromFloat(@round(source * opacity + 255 - alpha));
        result |= channel << shift;
    }
    return result;
}
fn fill(renderer: anytype, rect: ui.Rect, color: ui.Color) !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.roundedRect(rect, 0, color);
    try renderer.replayBuffer(&buffer);
}
fn read(renderer: anytype, front: bool, pixels: []u32, size: z.Size) !void {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
        try renderer.readLayerPixels(front, pixels);
        return;
    }
    if (builtin.os.tag == .windows) {
        if (c.GdiFlush() == 0) return error.FlushFailed;
        const surface = if (front) renderer.layer_workspace.?.front() else renderer.layer_workspace.?.current();
        @memcpy(pixels, surface.pixels.?[0..pixels.len]);
    } else for (0..size.height) |y| for (0..size.width) |x| {
        pixels[y * size.width + x] = zlc_layer_test_pixel(renderer.native.?, @intFromBool(front), @intCast(x), @intCast(y));
    };
}
fn finish(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn nativeCount(renderer: anytype) u32 {
    return if (@TypeOf(renderer.*) != ui.SoftwareRenderer) ui.d3d11.globalResourceCount() else if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else zlc_layer_live_objects();
}
fn mixed(renderer: anytype, allocator: std.mem.Allocator, paint: z.Paint) !void {
    const engine = try text.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const shaped = try engine.layout("A \u{05d0}\u{05d1}", .{ .width = 60, .wrap = .word_character });
    defer shaped.close() catch unreachable;
    const prepared = try shaped.prepare(paint.size.scale, .{ .viewport = .{ .x = 0, .y = 0, .width = 60, .height = 24 } });
    defer prepared.close() catch unreachable;
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const image_bytes = [_]u8{ 0, 128, 0, 128 } ** 4;
    const levels = [_]drawing.ImageLevel{.{ .pixels = &image_bytes, .byte_len = image_bytes.len, .width = 2, .height = 2, .stride = 8 }};
    const image: drawing.ImageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    try renderer.uploadImage(image);
    defer _ = renderer.releaseImage(image.identity) catch unreachable;
    const stops = [_]ui.commands.brushes.Stop{
        .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 0, .a = 0 } },
        .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    };
    const gradient: ui.commands.Gradient = .{ .linear = .{ .start = .{ .x = 8, .y = 32 }, .end = .{ .x = 24, .y = 32 }, .stops = &stops } };
    const stored = try ui.commands.brushes.Stored.init(gradient);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.beginGroup(.{ .x = 0, .y = 0, .width = 64, .height = 48 }, .{ .opacity = 200 });
    try buffer.preparedText(.{ .x = 0, .y = 0 }, try prepared.view(), .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.roundedRect(.{ .x = 0, .y = 32, .width = 8, .height = 8 }, 2, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try buffer.gradientRect(.{ .x = 8, .y = 32, .width = 16, .height = 8 }, 0, gradient);
    try buffer.image(.{ .x = 24, .y = 32, .width = 8, .height = 8 }, image, .{ .sampling = .nearest });
    try buffer.text(.{ .x = 40, .y = 32, .width = 24, .height = 16 }, "A", 0);
    try buffer.endGroup();
    try buffer.finish();
    const pixels = try allocator.alloc(u32, @as(usize, paint.size.width) * paint.size.height);
    defer allocator.free(pixels);
    for (0..2) |_| {
        try renderer.begin(paint);
        try renderer.replayBuffer(&buffer);
        try read(renderer, false, pixels, paint.size);
        const scale = paint.size.scale;
        try near(0xff9bff9b, pixels[@as(usize, @intFromFloat(36 * scale)) * paint.size.width + @as(usize, @intFromFloat(28 * scale))]);
        const xx: u32 = @intFromFloat(12 * scale);
        const yy: u32 = @intFromFloat(36 * scale);
        const value = stored.sample((@as(f64, @floatFromInt(xx)) + 0.5) / scale, (@as(f64, @floatFromInt(yy)) + 0.5) / scale).overAlpha(0, 255);
        try near(overWhite(value, 200.0 / 255.0), pixels[@as(usize, yy) * paint.size.width + xx]);
        var changed: usize = 0;
        var text_pixels: usize = 0;
        for (0..@as(usize, @intFromFloat(24 * scale))) |y| for (0..@as(usize, @intFromFloat(60 * scale))) |x| {
            const v = pixels[y * paint.size.width + x];
            try equal(255, v >> 24);
            if (v != 0xffffffff) {
                changed += 1;
                inline for ([_]u5{ 0, 8, 16 }) |shift| try expect(((v >> shift) & 255) >= 154);
            }
        };
        for (@as(usize, @intFromFloat(32 * scale))..paint.size.height) |y| for (@as(usize, @intFromFloat(40 * scale))..paint.size.width) |x| {
            if (pixels[y * paint.size.width + x] != 0xffffffff) text_pixels += 1;
        };
        try expect(changed > 0);
        try expect(text_pixels > 0);
        try finish(renderer, paint);
    }
}
fn run(renderer: anytype, allocator: std.mem.Allocator, base: z.Paint) !void {
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var paint = base;
        paint.size = .{ .width = @intFromFloat(64 * scale), .height = @intFromFloat(48 * scale), .scale = scale };
        const options: ui.layers.Options = .{ .size = paint.size };
        try renderer.prepareLayers(allocator, options);
        const created = renderer.layerStats().native_creations;
        const pixels = try allocator.alloc(u32, @as(usize, paint.size.width) * paint.size.height);
        defer allocator.free(pixels);
        for (0..3) |_| {
            try renderer.begin(paint);
            try expectError(error.AlreadyDrawing, renderer.releaseLayers());
            try renderer.beginGroup(.{ .x = 0, .y = 0, .width = 32, .height = 32 }, .{ .opacity = 128 });
            try fill(renderer, .{ .x = 0, .y = 0, .width = 24, .height = 24 }, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
            try fill(renderer, .{ .x = 8, .y = 0, .width = 24, .height = 24 }, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
            try read(renderer, false, pixels, paint.size);
            try near(0xc0400080, pixels[@as(usize, @intFromFloat(4 * scale)) * paint.size.width + @as(usize, @intFromFloat(12 * scale))]);
            try renderer.endGroup();
            try renderer.beginGroup(.{ .x = 32, .y = 0, .width = 32, .height = 32 }, .{ .opacity = 128 });
            try fill(renderer, .{ .x = 32, .y = 0, .width = 32, .height = 24 }, ui.Color.rgb(0x00ff00));
            try renderer.endGroup();
            try read(renderer, false, pixels, paint.size);
            try near(0xffbf9fdf, pixels[@as(usize, @intFromFloat(4 * scale)) * paint.size.width + @as(usize, @intFromFloat(12 * scale))]);
            try near(0xff7fff7f, pixels[@as(usize, @intFromFloat(4 * scale)) * paint.size.width + @as(usize, @intFromFloat(40 * scale))]);
            try finish(renderer, paint);
        }
        var lease = drawing.Lease.init(std.Thread.getCurrentId());
        const mask_bytes = [_]u8{255} ** 16;
        const mask: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &mask_bytes, .width = 4, .height = 4, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = scale } };
        try renderer.uploadCoverage(mask);
        for ([_]bool{ false, true }) |same_edge| {
            var buffer: ui.commands.Buffer = .{};
            defer buffer.reset();
            try buffer.pushClip(.{ .x = 1.25 / scale, .y = 1.25 / scale, .width = 3 / scale, .height = 3 / scale });
            try buffer.beginGroup(if (same_edge) .{ .x = 1.25 / scale, .y = 1.25 / scale, .width = 3 / scale, .height = 3 / scale } else .{ .x = 0, .y = 0, .width = 8 / scale, .height = 8 / scale }, .{ .opacity = 128, .mask = mask, .mask_origin = .{ .x = 1.5 / scale, .y = 1.5 / scale } });
            try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 8 / scale, .height = 8 / scale }, 0, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
            try buffer.roundedRect(.{ .x = 0, .y = 0, .width = 8 / scale, .height = 8 / scale }, 0, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
            try buffer.endGroup();
            try buffer.popClip();
            try buffer.finish();
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try read(renderer, false, pixels, paint.size);
            for (0..8) |y| for (0..8) |x| {
                const fx: f64 = @floatFromInt(x);
                const fy: f64 = @floatFromInt(y);
                const clip = @max(0, @min(fx + 1, 4.25) - @max(fx, 1.25)) * @max(0, @min(fy + 1, 4.25) - @max(fy, 1.25));
                const mx = std.math.clamp(fx - 0.5, 0, 1) * std.math.clamp(5.5 - fx, 0, 1);
                const my = std.math.clamp(fy - 0.5, 0, 1) * std.math.clamp(5.5 - fy, 0, 1);
                near(overWhite(0xc0400080, 128.0 / 255.0 * clip * mx * my), pixels[y * paint.size.width + x]) catch |err| {
                    std.debug.print("mask/parentclip pixel({d},{d}) scale={d} backend={s}\n", .{ x, y, scale, @typeName(@TypeOf(renderer.*)) });
                    return err;
                };
            };
            try finish(renderer, paint);
        }
        _ = try renderer.releaseCoverage(mask.identity);
        try equal(0, lease.pins);
        try mixed(renderer, allocator, paint);
        try equal(created, renderer.layerStats().native_creations);
        try read(renderer, true, pixels, paint.size);
        const committed = pixels[0];
        try renderer.begin(paint);
        try fill(renderer, .{ .x = 0, .y = 0, .width = 64, .height = 48 }, ui.Color.rgb(0));
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.abort() else renderer.discard();
        try read(renderer, true, pixels, paint.size);
        try equal(committed, pixels[0]);
        const before_fault = nativeCount(renderer);
        renderer.injectLayerPreparationFailureForTest(2);
        const candidate_error = if (@TypeOf(renderer.*) != ui.SoftwareRenderer) error.GraphicsFailed else if (builtin.os.tag == .windows) error.OutOfMemory else error.LayerPreparationFailed;
        try expectError(candidate_error, renderer.prepareLayers(allocator, options));
        try equal(before_fault, nativeCount(renderer));
        try read(renderer, true, pixels, paint.size);
        try equal(committed, pixels[0]);
        try expect(renderer.layerStats().candidate_peak_bytes >= 2 * renderer.layerStats().pixel_bytes);
        var wrong_dpi = paint;
        wrong_dpi.size.scale += 0.125;
        try expectError(error.LayersRequired, renderer.begin(wrong_dpi));
        if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
            try renderer.begin(paint);
            try fill(renderer, .{ .x = 0, .y = 0, .width = 64, .height = 48 }, ui.Color.rgb(0));
            renderer.injectPresentationBusy();
            try expectError(error.PresentationBusy, renderer.end());
            try read(renderer, true, pixels, paint.size);
            try equal(committed, pixels[0]);
            const before_loss = renderer.layerStats();
            try renderer.begin(paint);
            renderer.injectDeviceLoss();
            try expectError(error.DeviceLost, renderer.end());
            try renderer.begin(paint);
            try expect(renderer.layerStats().native_restores > before_loss.native_restores);
            try equal(before_loss.native_objects, renderer.layerStats().native_objects);
            try finish(renderer, paint);
        }
        var invalid = options;
        invalid.bytes = 1;
        try expectError(error.LayerBudgetExceeded, renderer.prepareLayers(allocator, invalid));
        try expect(renderer.layerStats().prepared);
        try renderer.releaseLayers();
        try expect(!renderer.layerStats().prepared);
    }
}

const State = struct {
    context: *ui.Context = undefined,
    window: z.Window = undefined,
    allocator: std.mem.Allocator,
    options: ui.layers.Options = undefined,
    mask: drawing.CoverageView = undefined,
    expected: ?anyerror = null,
    err: ?anyerror = null,
    diagnostics: usize = 0,
    calls: usize = 0,
    bad: bool = false,
    close: bool = false,
    node: u64 = 1,
    bad_replay: bool = false,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected) |wanted| actual == wanted else false else false;
        if (matches) self.diagnostics += 1 else {
            std.debug.print("unexpected layer diagnostic={any}/{d}, expected={any}/{d}, equal={any}\n", .{ value.err, if (value.err) |err| @intFromError(err) else 0, self.expected, if (self.expected) |err| @intFromError(err) else 0, matches });
            self.err = value.err orelse error.UnexpectedDiagnostic;
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.checked(frame) catch |err| {
            self.err = err;
            frame.failure = frame.failure orelse err;
        };
    }
    fn checked(self: *State, frame: *ui.Frame) !void {
        try expectError(error.Busy, self.context.prepareLayers(self.allocator, self.options));
        try expectError(error.Busy, self.context.releaseLayers());
        frame.clear(0x204060);
        try frame.pushOffset(.{ .x = 2, .y = 3 });
        try frame.pushClip(.{ .x = 0.25, .y = 0.25, .width = 20, .height = 20 });
        try frame.beginGroup(.{ .x = 0, .y = 0, .width = 24, .height = 24 }, .{ .opacity = 128, .mask = self.mask });
        try expectError(error.ResourceInUse, self.mask.lease.ensureUnused());
        try frame.beginGroup(.{ .x = 0, .y = 0, .width = 16, .height = 24 }, .{ .opacity = 200 });
        try frame.pushClip(.{ .x = 10, .y = -10, .width = 30, .height = 60 });
        try frame.button(3, .{ .x = 0, .y = 0, .width = 60, .height = 30 }, "Clipped");
        try frame.popClip();
        frame.roundedRect(.{ .x = 0, .y = 0, .width = 24, .height = 24 }, 4, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
        frame.label(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, "A", 0xffffff);
        try frame.endGroup();
        try frame.endGroup();
        try frame.popClip();
        try frame.popOffset();
        try frame.button(self.node, .{ .x = 40, .y = 0, .width = 40, .height = 24 }, "Node");
        if (self.bad_replay) {
            const buffer = &frame.context.command_buffer;
            buffer.storage[buffer.len] = .{ .coverage = .{ .origin = .{}, .color = ui.Color.rgb(0xff0000), .resource = 31 } };
            buffer.len += 1;
        }
        if (self.bad) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close) try equal(z.CloseResult.deferred, try self.window.destroy());
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else {
            const size = try self.window.clientBounds();
            zlg_test_paint(self.window.app.windows.get(self.window.key).?.native.native.?, size.width, size.height);
        }
        if (self.err) |err| return err;
    }
};
fn shown(context: *ui.Context) bool {
    if (ui.capabilities.gpu) {
        const surface = context.gpu_renderer.surfaceForTest() orelse return false;
        return c.GetWindowLongW(surface, c.GWL_STYLE) & c.WS_VISIBLE != 0;
    }
    return false;
}
fn checkNodes(context: *ui.Context, old: u64, new: u64) !void {
    try expect(context.input_state.available(old));
    try expect(!context.input_state.available(new));
    if (ui.capabilities.accessibility) {
        const provider: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try context.accessibility_bridge.retainProvider(old)));
        _ = provider.lpVtbl.*.Release.?(provider);
        try expectError(error.NativeProviderUnavailable, context.accessibility_bridge.retainProvider(new));
    }
}
fn integrated(allocator: std.mem.Allocator, gpu: bool, pending_close: bool) !void {
    var state: State = .{ .allocator = allocator };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 96, .height = 80 });
    defer {
        if (!window.isClosed()) {
            _ = window.destroy() catch unreachable;
        }
    }
    state.window = window;
    const bounds = try window.clientBounds();
    const scale: f32 = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?));
    state.options = .{ .size = .{ .width = bounds.width, .height = bounds.height, .scale = scale } };
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const bytes = [_]u8{255} ** 64;
    state.mask = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &bytes, .width = 8, .height = 8, .stride = 8, .origin_x = 0, .origin_y = 0, .scale = scale } };
    var context = ui.Context.init(&state, State.draw, State.action);
    state.context = &context;
    context.render_mode = if (gpu) .warp else .gdi;
    try context.attach(window);
    try context.uploadCoverage(state.mask);
    state.expected = error.LayersRequired;
    try state.paint();
    try equal(1, state.diagnostics);
    state.expected = null;
    state.options.size = context.last_paint_size orelse return error.MissingPaint;
    try expect(!(try context.layerStats()).software.prepared);
    var small = state.options;
    small.total_bytes = 1;
    const gdi_count = if (builtin.os.tag == .windows) c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS) else 0;
    try expectError(error.LayerAggregateBudgetExceeded, context.prepareLayers(allocator, small));
    if (builtin.os.tag == .windows) try equal(gdi_count, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
    try context.prepareLayers(allocator, state.options);
    const stats = try context.layerStats();
    try equal(stats.software.pixel_bytes + (if (stats.gpu) |value| value.pixel_bytes else 0), stats.current_bytes);
    try state.paint();
    try equal(@as(?u64, 3), context.input_state.hit(.{ .x = 13, .y = 10 }));
    try equal(@as(?u64, null), context.input_state.hit(.{ .x = 5, .y = 10 }));
    try equal(@as(?u64, null), context.input_state.hit(.{ .x = 19, .y = 10 }));
    try equal(@as(?u64, null), context.input_state.hit(.{ .x = 13, .y = 25 }));
    const resident_pins = lease.residency_pins;
    try equal(resident_pins, lease.pins);
    if (builtin.os.tag == .windows) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        try expectError(error.OutOfMemory, context.prepareLayers(failing.allocator(), state.options));
        try equal(stats.current_bytes, (try context.layerStats()).current_bytes);
    }
    if (ui.capabilities.gpu and gpu) {
        const native_before = ui.d3d11.globalResourceCount();
        const software_before = context.renderer.layerStats();
        context.gpu_renderer.injectLayerPreparationFailureForTest(2);
        try expectError(error.GraphicsFailed, context.prepareLayers(allocator, state.options));
        try equal(native_before, ui.d3d11.globalResourceCount());
        try equal(software_before.native_creations, context.renderer.layerStats().native_creations);
        try equal(stats.current_bytes, (try context.layerStats()).current_bytes);
    }
    if (context.gpu_wait != null) try context.prepareLayers(allocator, state.options);
    try checkNodes(&context, 1, 2);
    const was_shown = shown(&context);
    state.node = 2;
    state.bad_replay = true;
    state.expected = error.MissingResources;
    const failed_calls = state.calls;
    try state.paint();
    try equal(failed_calls + 1, state.calls);
    try checkNodes(&context, 1, 2);
    try equal(was_shown, shown(&context));
    try equal(resident_pins, lease.pins);
    state.bad_replay = false;
    state.expected = null;
    if (ui.capabilities.gpu and gpu) {
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        try checkNodes(&context, 1, 2);
        try equal(was_shown, shown(&context));
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        try context.prepareLayers(allocator, state.options);
        try expect(!app.unwatchNative(token));
    }
    try state.paint();
    try checkNodes(&context, 2, 1);
    state.bad = true;
    state.expected = error.InvalidGeometry;
    const calls = state.calls;
    try state.paint();
    try expect(state.calls == calls or state.calls == calls + 1);
    try equal(resident_pins, lease.pins);
    state.bad = false;
    state.expected = null;
    try context.releaseLayers();
    try expect(context.gpu_wait == null);
    try context.prepareLayers(allocator, state.options);
    if (ui.capabilities.gpu and gpu) {
        context.gpu_renderer.injectDeviceLoss();
        state.expected = error.DeviceLost;
        try state.paint();
        try expect(context.fallbacks >= 1);
        state.expected = null;
        const count = state.calls;
        try state.paint();
        try equal(count + 1, state.calls);
        try expect(context.gpu_renderer.layerStats().native_restores > 0);
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        if (pending_close) {
            _ = try window.destroy();
            try expect(!app.unwatchNative(token));
            try app.run();
            try equal(0, lease.pins);
            return;
        }
        try context.prepareLayers(allocator, state.options);
        try expect(context.gpu_wait == null);
        try expect(!app.unwatchNative(token));
    }
    state.close = true;
    try state.paint();
    try expect(window.isClosed());
    try app.run();
    try equal(0, lease.pins);
    try expect(context.window == null);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    if (builtin.os.tag == .windows) {
        const app = try z.App.init(allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        {
            const hwnd = window.nativeHandle();
            const dc = c.GetDC(hwnd) orelse return error.NoSurface;
            defer _ = c.ReleaseDC(hwnd, dc);
            const paint: z.Paint = .{ .native_window = hwnd, .native_context = dc, .size = .{ .width = 64, .height = 48, .scale = 1 } };
            var warmed: ?u32 = null;
            for (0..3) |pass| {
                {
                    var renderer: ui.SoftwareRenderer = .{};
                    defer renderer.deinit();
                    try run(&renderer, allocator, paint);
                }
                const after = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
                std.debug.print("layer GDI pass={d}, handles={d}, textrefs={any}\n", .{ pass, after, text.resourceCounts() });
                if (warmed) |value| try equal(value, after) else warmed = after;
            }
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try run(&renderer, allocator, paint);
                renderer.deinit();
                try equal(0, ui.d3d11.globalResourceCount());
                std.debug.print("layers {s}: alpha, same-depth reuse, rollback and resources=0\n", .{@tagName(driver)});
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 128, 96) orelse return error.NoSurface;
        defer cairo_surface_destroy(surface);
        const dc = cairo_create(surface) orelse return error.NoSurface;
        defer cairo_destroy(dc);
        const paint: z.Paint = .{ .native_context = dc, .size = .{ .width = 64, .height = 48, .scale = 1 } };
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try run(&renderer, allocator, paint);
        renderer.deinit();
        try equal(0, zlc_layer_live_objects());
    }
    try integrated(allocator, false, false);
    if (ui.capabilities.gpu) {
        try integrated(allocator, true, false);
        try integrated(allocator, true, true);
    }
    try equal(text.ResourceCounts{}, text.resourceCounts());
    if (ui.capabilities.gpu) try equal(0, ui.d3d11.globalResourceCount());
    if (ui.capabilities.accessibility) try equal(0, ui.accessibility.resourceCounts().states);
    std.debug.print("layers: software alpha/group/rollback, Context/watch/close and resource balance passed\n", .{});
}
