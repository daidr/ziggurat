const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const vector = @import("ziggurat_vector");
const drawing = ui.drawing;
const brushes = ui.commands.brushes;
const reference = @import("gradient_interpolation_oracle.zig");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_layer_test_pixel(*anyopaque, c_int, u32, u32) u32;
extern fn zlc_layer_live_objects() u32;
extern fn zlc_test_live_image_objects() u32;

const width = 48;
const height = 40;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
const background: u32 = 0xff183048;
const stops = [_]brushes.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 32, .a = 64 } },
    .{ .offset = 0.25, .color = .{ .r = 0, .g = 255, .b = 0, .a = 224 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
    .{ .offset = 0.75, .color = .{ .r = 240, .g = 160, .b = 0, .a = 192 } },
    .{ .offset = 1, .color = .{ .r = 255, .g = 0, .b = 32, .a = 64 } },
};
const hard_stops = [_]brushes.Stop{
    .{ .offset = 0, .color = .{ .r = 255, .g = 0, .b = 255, .a = 0 } },
    .{ .offset = 0.5, .color = .{ .r = 255, .g = 0, .b = 0, .a = 160 } },
    .{ .offset = 0.5, .color = .{ .r = 0, .g = 0, .b = 255, .a = 224 } },
    .{ .offset = 1, .color = .{ .r = 0, .g = 255, .b = 0, .a = 96 } },
};

fn descriptor(space: brushes.InterpolationSpace, kind: usize, hard: bool) brushes.Gradient {
    const palette: []const brushes.Stop = if (hard) &hard_stops else &stops;
    return switch (kind) {
        0 => .{ .linear = .{ .start = .{ .x = 6, .y = 8 }, .end = .{ .x = 38, .y = 24 }, .stops = palette, .interpolation = space } },
        1 => .{ .radial = .{ .center = .{ .x = 23.5, .y = 20.5 }, .radius = .{ .x = 18, .y = 11 }, .stops = palette, .interpolation = space } },
        else => .{ .conic = .{ .center = .{ .x = 23.5, .y = 20.5 }, .direction = .counter_clockwise, .stops = palette, .interpolation = space } },
    };
}
fn parameter(kind: usize, x: f64, y: f64) f64 {
    if (kind == 0) return ((x - 6) * 32 + (y - 8) * 16) / (32 * 32 + 16 * 16);
    const dx = x - 23.5;
    const dy = y - 20.5;
    if (kind == 1) return @sqrt(dx * dx / (18 * 18) + dy * dy / (11 * 11));
    if (dx == 0 and dy == 0) return 0;
    // Independent acos/quadrant reconstruction rather than production atan2.
    const angle = std.math.acos(std.math.clamp(dx / @sqrt(dx * dx + dy * dy), -1, 1));
    const turns = (if (dy < 0) angle else -angle) / (2 * std.math.pi);
    return turns - @floor(turns);
}

const Placement = struct {
    origin: drawing.Point,
    clip: ?ui.Rect,
    opacity: u8,
};
fn placement(scale: f32, index: usize) Placement {
    return .{
        .origin = .{ .x = 10 + 0.25 / scale, .y = 9 + 0.75 / scale },
        .clip = if (index == 0) null else .{ .x = 12.25, .y = 10.5, .width = 22.5, .height = 22.25 },
        .opacity = if (index == 2) 153 else 255,
    };
}
fn record(buffer: *ui.commands.Buffer, view: drawing.CoverageView, place: Placement, gradient: brushes.Gradient) !void {
    buffer.reset();
    try buffer.fill(bounds, background & 0xffffff);
    if (place.clip) |clip| try buffer.pushClip(clip);
    if (place.opacity != 255) try buffer.beginGroup(bounds, .{ .opacity = place.opacity });
    try buffer.gradientCoverage(place.origin, view, gradient);
    if (place.opacity != 255) try buffer.endGroup();
    if (place.clip != null) try buffer.popClip();
    try buffer.finish();
}

// Tent weights over every source texel are independent of the production
// floor/four-neighbor sampler. Padding bytes are deliberately never visited.
fn maskPlane(out: []f64, size: z.Size, mask: drawing.Coverage, origin: drawing.Point) void {
    const dx = @as(f64, origin.x) * size.scale + @as(f64, @floatFromInt(mask.origin_x));
    const dy = @as(f64, origin.y) * size.scale + @as(f64, @floatFromInt(mask.origin_y));
    for (0..size.height) |y| for (0..size.width) |x| {
        var value: f64 = 0;
        for (0..mask.height) |row| {
            const wy = @max(0, 1 - @abs(@as(f64, @floatFromInt(y)) - dy - @as(f64, @floatFromInt(row))));
            if (wy == 0) continue;
            for (0..mask.width) |column| {
                const wx = @max(0, 1 - @abs(@as(f64, @floatFromInt(x)) - dx - @as(f64, @floatFromInt(column))));
                value += @as(f64, @floatFromInt(mask.pixels[row * mask.stride + column])) * wx * wy;
            }
        }
        out[y * size.width + x] = value / 255;
    };
}
fn expected(palette: *const reference.Palette, kind: usize, size: z.Size, place: Placement, mask: f64, x: usize, y: usize) u32 {
    const px = (@as(f64, @floatFromInt(x)) + 0.5) / size.scale;
    const py = (@as(f64, @floatFromInt(y)) + 0.5) / size.scale;
    // The transparent child is BGRA8 before the mask/outer opacity composite.
    const color = palette.at(parameter(kind, px, py));
    var source: [4]f64 = undefined;
    for (&source, color) |*channel, value| channel.* = @floatCast(@round(std.math.clamp(value * 255, 0, 255)));
    var amount = mask * @as(f64, @floatFromInt(place.opacity)) / 255;
    if (place.clip) |clip| {
        amount *= @max(0, @min(@as(f64, @floatFromInt(x + 1)), (@as(f64, clip.x) + clip.width) * size.scale) - @max(@as(f64, @floatFromInt(x)), @as(f64, clip.x) * size.scale));
        amount *= @max(0, @min(@as(f64, @floatFromInt(y + 1)), (@as(f64, clip.y) + clip.height) * size.scale) - @max(@as(f64, @floatFromInt(y)), @as(f64, clip.y) * size.scale));
    }
    var result: u32 = 0;
    for (source, [_]u5{ 16, 8, 0, 24 }) |channel, shift| {
        const bg: f64 = @floatFromInt((background >> shift) & 255);
        result |= @as(u32, @intFromFloat(std.math.clamp(@round(channel * amount + bg * (1 - source[3] * amount / 255)), 0, 255))) << shift;
    }
    return result;
}
fn verify(pixels: []const u32, masks: []const f64, size: z.Size, place: Placement, space: brushes.InterpolationSpace, kind: usize, index: usize, hard: bool, label: []const u8) !void {
    const palette_stops: []const brushes.Stop = if (hard) &hard_stops else &stops;
    const palette = reference.Palette.init(@backingInt(space), palette_stops);
    for (0..size.height) |y| for (0..size.width) |x| {
        const want = expected(&palette, kind, size, place, masks[y * size.width + x], x, y);
        const actual = pixels[y * size.width + x];
        inline for ([_]u5{ 0, 8, 16, 24 }) |shift| {
            const difference = @abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255)));
            if (difference > 3) {
                std.debug.print("gradient coverage {s} space={s} kind={d} mask={d} hard={} dpi={d} at={d},{d} expected={x} actual={x} channel={d}\n", .{ label, @tagName(space), kind, index, hard, size.scale, x, y, want, actual, shift });
                return error.GradientCoveragePixelMismatch;
            }
        }
    };
}
fn read(renderer: anytype, output: []u32, size: z.Size) !void {
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) {
        try renderer.readLayerPixels(false, output);
    } else if (builtin.os.tag == .windows) {
        if (c.GdiFlush() == 0) return error.FlushFailed;
        @memcpy(output, renderer.layer_workspace.?.current().pixels.?[0..output.len]);
    } else for (0..size.height) |y| for (0..size.width) |x| {
        output[y * size.width + x] = zlc_layer_test_pixel(renderer.native.?, 0, @intCast(x), @intCast(y));
    };
}
fn finish(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try renderer.endChecked(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn render(renderer: anytype, allocator: std.mem.Allocator, base: z.Paint, label: []const u8) !void {
    const software = @TypeOf(renderer.*) == ui.SoftwareRenderer;
    const path = try vector.Path.parseData(allocator, "M0 0 H20 V18 H0 Z M6 5 H14 V13 H6 Z", .{});
    defer path.close() catch unreachable;
    const curve = try vector.Path.parseData(allocator, "M0 16 C2 -2 18 -2 20 16", .{});
    defer curve.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var output: [width * height * 4]u32 = undefined;
    var masks: [width * height * 4]f64 = undefined;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var paint = base;
        paint.size = .{ .width = @intFromFloat(width * scale), .height = @intFromFloat(height * scale), .scale = scale };
        try renderer.prepareLayers(allocator, .{ .size = paint.size, .max_depth = 2, .legacy_text = .disabled });
        const filled = try path.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .scale = scale, .viewport = .{ .x = -2, .y = -2, .width = 24, .height = 22 }, .style = .{ .fill = .even_odd } });
        defer filled.close() catch unreachable;
        const stroked = try curve.prepare(allocator, .{ .main_thread = std.Thread.getCurrentId(), .scale = scale, .viewport = .{ .x = -2, .y = -2, .width = 24, .height = 22 }, .style = .{ .stroke = .{ .width = 3, .cap = .round, .join = .round, .dashes = &.{ 4, 2 } } } });
        defer stroked.close() catch unreachable;
        var lease = drawing.Lease.init(std.Thread.getCurrentId());
        const raw = [_]u8{ 255, 64, 128, 255, 89, 90, 0, 192, 32, 128, 91, 92, 224, 255, 64, 192, 93, 94, 255, 96, 255, 160, 95, 96 };
        const literal: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 4, .height = 4, .stride = 6, .origin_x = -2, .origin_y = 1, .scale = scale } };
        for ([_]drawing.CoverageView{ literal, try filled.view(), try stroked.view() }, 0..) |view, index| {
            try renderer.uploadCoverage(view);
            var resident_live = true;
            defer if (resident_live) {
                buffer.reset();
                _ = renderer.releaseCoverage(view.identity) catch unreachable;
            };
            errdefer renderer.abort();
            const place = placement(scale, index);
            const count = @as(usize, paint.size.width) * paint.size.height;
            maskPlane(masks[0..count], paint.size, view.coverage, place.origin);
            const creations = renderer.layerStats().native_creations;
            for ([_]brushes.InterpolationSpace{ .srgb, .srgb_linear, .oklab }) |space| {
                if (!software and space != .srgb) continue;
                for (0..3) |kind| {
                    try record(&buffer, view, place, descriptor(space, kind, false));
                    try renderer.begin(paint);
                    try renderer.replayBuffer(&buffer);
                    try read(renderer, output[0..count], paint.size);
                    try verify(output[0..count], masks[0..count], paint.size, place, space, kind, index, false, label);
                    try finish(renderer, paint);
                }
                try record(&buffer, view, place, descriptor(space, 0, true));
                try renderer.begin(paint);
                try renderer.replayBuffer(&buffer);
                try read(renderer, output[0..count], paint.size);
                try verify(output[0..count], masks[0..count], paint.size, place, space, 0, index, true, label);
                try finish(renderer, paint);
            }
            try std.testing.expectEqual(creations, renderer.layerStats().native_creations);
            buffer.reset();
            _ = try renderer.releaseCoverage(view.identity);
            resident_live = false;
            try view.lease.ensureUnused();
        }
        try lease.ensureUnused();
    }
}

fn reflected(renderer: anytype, allocator: std.mem.Allocator, base: z.Paint, label: []const u8) !void {
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    var table: ui.commands.TransformStorage = .{};
    var output: [width * height * 4]u32 = undefined;
    var masks: [width * height * 4]f64 = undefined;
    const palette = reference.Palette.init(0, &stops);
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var paint = base;
        paint.size = .{ .width = @intFromFloat(width * scale), .height = @intFromFloat(height * scale), .scale = scale };
        try renderer.prepareTransforms(allocator, .{ .layers = .{ .size = paint.size, .max_depth = 2, .legacy_text = .disabled }, .source_size = .{ .width = width, .height = height } });
        var lease = drawing.Lease.init(std.Thread.getCurrentId());
        const raw = [_]u8{ 255, 64, 128, 255, 192, 0, 224, 255, 64 };
        const view: drawing.CoverageView = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 3, .height = 3, .stride = 3, .origin_x = -1, .origin_y = 2, .scale = scale } };
        try renderer.uploadCoverage(view);
        var resident_live = true;
        defer if (resident_live) {
            buffer.reset();
            _ = renderer.releaseCoverage(view.identity) catch unreachable;
        };
        errdefer renderer.abort();
        const place: Placement = .{ .origin = .{ .x = 10 + 0.75 / scale, .y = 9 + 0.25 / scale }, .clip = .{ .x = 10.125, .y = 9.75, .width = 5.5, .height = 5.25 }, .opacity = 255 };
        const count = @as(usize, paint.size.width) * paint.size.height;
        maskPlane(masks[0..count], paint.size, view.coverage, place.origin);
        table.scale = scale;
        try buffer.bindTransformStorage(&table);
        try buffer.fill(bounds, background & 0xffffff);
        try buffer.beginTransform(try ui.layers.NativeTransform.init(.{ .xx = -1, .x0 = width }, .{ .width = width, .height = height }, scale));
        try buffer.pushClip(place.clip.?);
        try buffer.gradientCoverage(place.origin, view, descriptor(.srgb, 0, false));
        try buffer.popClip();
        try buffer.endTransform();
        try buffer.finish();
        const creations = renderer.layerStats().native_creations;
        for (0..2) |_| {
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try read(renderer, output[0..count], paint.size);
            for (0..paint.size.height) |y| for (0..paint.size.width) |x| {
                // Reflection maps centers exactly: (x+.5) -> width-(x+.5).
                // Neither mask coordinates nor gradient anchors move twice.
                const source_x = paint.size.width - 1 - x;
                const want = expected(&palette, 0, paint.size, place, masks[y * paint.size.width + source_x], source_x, y);
                const actual = output[y * paint.size.width + x];
                inline for ([_]u5{ 0, 8, 16, 24 }) |shift| if (@abs(@as(i32, @intCast((want >> shift) & 255)) - @as(i32, @intCast((actual >> shift) & 255))) > 3) {
                    std.debug.print("gradient coverage reflection {s} DPI={d} at={d},{d} source_x={d} expected={x} actual={x}\n", .{ label, scale, x, y, source_x, want, actual });
                    return error.GradientCoverageReflectionMismatch;
                };
            };
            try finish(renderer, paint);
        }
        try std.testing.expectEqual(creations, renderer.layerStats().native_creations);
        buffer.reset();
        _ = try renderer.releaseCoverage(view.identity);
        resident_live = false;
        try lease.ensureUnused();
    }
}

const Fallback = struct {
    view: drawing.CoverageView,
    space: brushes.InterpolationSpace = .srgb,
    draws: usize = 0,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.clear(background & 0xffffff);
        frame.gradientCoverage(.{ .x = 3, .y = 4 }, self.view, descriptor(self.space, 0, true)) catch {};
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn fallback(app: *z.App, mode: ui.RenderMode) !void {
    var lease = drawing.Lease.init(std.Thread.getCurrentId());
    const raw = @as([16]u8, @splat(255));
    const window = try app.createWindow(.{ .width = width, .height = height });
    defer _ = window.destroy() catch unreachable;
    const size = try window.contentSize();
    const scale = size.scale;
    var state: Fallback = .{ .view = .{ .lease = &lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 4, .height = 4, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = scale } } };
    var context = ui.Context.init(&state, Fallback.draw, Fallback.action);
    context.render_mode = mode;
    try context.attach(window);
    try context.uploadCoverage(state.view);
    try context.prepareLayers(std.heap.page_allocator, .{ .size = size, .legacy_text = .disabled });
    const logical = try window.clientBounds();
    std.debug.print("gradient coverage Context {s} physical={d}x{d} scale={d} logical={d}x{d}\n", .{ @tagName(mode), size.width, size.height, scale, logical.width, logical.height });
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    std.debug.print("gradient coverage Context first paint draws={d} gpu={d} gdi={d} fallbacks={d} actual_size={any}\n", .{ state.draws, context.gpu_frames, context.gdi_frames, context.fallbacks, context.last_paint_size });
    try std.testing.expectEqual(@as(usize, 1), state.draws);
    try std.testing.expectEqual(@as(usize, 1), context.gpu_frames);
    for ([_]brushes.InterpolationSpace{ .srgb_linear, .oklab }, 0..) |space, index| {
        state.space = space;
        const draws = context.gpu_renderer.gradientStats().draws;
        _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(index + 2, state.draws);
        try std.testing.expectEqual(index + 1, context.fallbacks);
        try std.testing.expectEqual(index + 1, context.gdi_frames);
        try std.testing.expectEqual(draws, context.gpu_renderer.gradientStats().draws);
        const paint_size = context.last_paint_size orelse return error.MissingPaint;
        const count = @as(usize, paint_size.width) * paint_size.height;
        const masks = try std.heap.page_allocator.alloc(f64, count);
        defer std.heap.page_allocator.free(masks);
        const place: Placement = .{ .origin = .{ .x = 3, .y = 4 }, .clip = null, .opacity = 255 };
        maskPlane(masks, paint_size, state.view.coverage, place.origin);
        if (c.GdiFlush() == 0) return error.FlushFailed;
        try verify(context.renderer.pixels.?[0..count], masks, paint_size, place, space, 0, 0, true, "same buffer Context fallback");
    }
    state.space = .srgb;
    _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
    try std.testing.expectEqual(@as(usize, 4), state.draws);
    try std.testing.expectEqual(@as(usize, 2), context.gpu_frames);
    _ = try window.destroy();
    try lease.ensureUnused();
}

pub fn main() !void {
    std.debug.print("gradient coverage record sizes Command={d} Buffer={d} StoredBrush={d} Frame={d} Context={d}; three existing commands, no new record fields\n", .{ @sizeOf(ui.commands.Command), @sizeOf(ui.commands.Buffer), @sizeOf(brushes.Stored), @sizeOf(ui.Frame), @sizeOf(ui.Context) });
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    const selection: ?[]u8 = zio.getEnvVarOwned(allocator, "ZIGGURAT_GRADIENT_COVERAGE_CASE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (selection) |value| allocator.free(value);
    const affine_only = if (selection) |value| blk: {
        if (!std.mem.eql(u8, value, "affine")) return error.InvalidGradientCoverageCase;
        break :blk true;
    } else false;
    const app = try z.App.init(allocator);
    defer app.deinit();
    if (builtin.os.tag == .windows) {
        const window = try app.createWindow(.{});
        {
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            const dc = c.GetDC(hwnd) orelse return error.GetDCFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const baseline = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var software: ui.SoftwareRenderer = .{};
                defer software.deinit();
                const paint: z.Paint = .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = width, .height = height, .scale = 1 } };
                if (!affine_only) try render(&software, allocator, paint, "GDI");
                try reflected(&software, allocator, paint, "GDI");
            }
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var gpu: ui.d3d11.Renderer = .{};
                try gpu.init(.{ .driver = driver });
                defer gpu.deinit();
                const paint: z.Paint = .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = width, .height = height, .scale = 1 } };
                if (!affine_only) try render(&gpu, allocator, paint, @tagName(driver));
                try reflected(&gpu, allocator, paint, @tagName(driver));
            };
            try std.testing.expectEqual(baseline, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
        }
        _ = try window.destroy();
        if (ui.capabilities.gpu and !affine_only) {
            try fallback(app, .hardware);
            try fallback(app, .warp);
            try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
        }
    } else {
        const surface = cairo_image_surface_create(0, width * 2, height * 2) orelse return error.SurfaceFailed;
        defer cairo_surface_destroy(surface);
        const context = cairo_create(surface) orelse return error.ContextFailed;
        defer cairo_destroy(context);
        {
            var renderer: ui.SoftwareRenderer = .{};
            defer renderer.deinit();
            const paint: z.Paint = .{ .native_context = context, .size = .{ .width = width, .height = height, .scale = 1 } };
            if (!affine_only) try render(&renderer, allocator, paint, "Cairo");
            try reflected(&renderer, allocator, paint, "Cairo");
        }
        try std.testing.expectEqual(@as(u32, 0), zlc_layer_live_objects());
        try std.testing.expectEqual(@as(u32, 0), zlc_test_live_image_objects());
    }
    std.debug.print("gradient coverage: selection={s}, reflection/fractional clip+origin at 3 DPI passed; full selection also checks literal A8/evenodd fill/dashed stroke, linear/radial/conic and software 3 spaces; independent XYZ/tent oracle; resources=0\n", .{if (affine_only) "affine" else "all"});
}
