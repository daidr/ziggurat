const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const shadows = @import("ziggurat_shadows");
const vector = @import("ziggurat_vector");
const drawing = shadows.drawing;
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn zlc_test_live_image_objects() u32;
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const bg = 0x204060;
fn resident(comptime T: type) bool {
    return builtin.os.tag != .windows or T != ui.SoftwareRenderer;
}
fn finish(renderer: anytype, paint: z.Paint) !void {
    if (@TypeOf(renderer.*) == ui.SoftwareRenderer) renderer.end(paint) else renderer.end() catch |err| {
        if (err != error.PresentationBusy) return err;
    };
}
fn near(want: u32, got: u32, x: u32, y: u32) !void {
    inline for ([_]u5{ 0, 8, 16 }) |shift| {
        const a: i32 = @intCast((want >> shift) & 255);
        const b: i32 = @intCast((got >> shift) & 255);
        if (@abs(a - b) > 3) {
            std.debug.print("coverage pixel({d},{d}) expected={x}, actual={x}\n", .{ x, y, want, got });
            return error.CoveragePixelMismatch;
        }
    }
}
fn over(before: u32, tint: ui.Color, coverage: f64) u32 {
    const alpha: u32 = @intFromFloat(@round(coverage * @as(f64, @floatFromInt(tint.a)) / 255));
    const inv = 255 - alpha;
    const red = (@as(u32, tint.r) * alpha + ((before >> 16) & 255) * inv + 127) / 255;
    const green = (@as(u32, tint.g) * alpha + ((before >> 8) & 255) * inv + 127) / 255;
    const blue = (@as(u32, tint.b) * alpha + (before & 255) * inv + 127) / 255;
    return red << 16 | green << 8 | blue;
}
const Item = struct { view: drawing.CoverageView, origin: drawing.Point, tint: ui.Color, clip: ?ui.Rect = null };
fn sample(item: Item, x: u32, y: u32) f64 {
    const mask = item.view.coverage;
    if (item.clip) |clip| {
        const px = (@as(f64, @floatFromInt(x)) + 0.5) / mask.scale;
        const py = (@as(f64, @floatFromInt(y)) + 0.5) / mask.scale;
        if (px < clip.x or py < clip.y or px >= @as(f64, clip.x) + clip.width or py >= @as(f64, clip.y) + clip.height) return 0;
    }
    const dx = @as(f64, item.origin.x) * mask.scale + @as(f64, @floatFromInt(mask.origin_x));
    const dy = @as(f64, item.origin.y) * mask.scale + @as(f64, @floatFromInt(mask.origin_y));
    const sx = @as(f64, @floatFromInt(x)) - dx;
    const sy = @as(f64, @floatFromInt(y)) - dy;
    if (sx < -1 or sy < -1 or sx > @as(f64, @floatFromInt(mask.width)) or sy > @as(f64, @floatFromInt(mask.height))) return 0;
    const bx: i64 = @intFromFloat(@floor(sx));
    const by: i64 = @intFromFloat(@floor(sy));
    const fx = sx - @floor(sx);
    const fy = sy - @floor(sy);
    var value: f64 = 0;
    for (0..2) |iy| for (0..2) |ix| {
        const mx = bx + @as(i64, @intCast(ix));
        const my = by + @as(i64, @intCast(iy));
        if (mx < 0 or my < 0 or mx >= mask.width or my >= mask.height) continue;
        value += @as(f64, @floatFromInt(mask.pixels[@as(usize, @intCast(my)) * mask.stride + @as(usize, @intCast(mx))])) * (if (ix == 0) 1 - fx else fx) * (if (iy == 0) 1 - fy else fy);
    };
    return value;
}
fn pixels(renderer: anytype, allocator: std.mem.Allocator, paint: z.Paint, items: []const Item) !void {
    const width = paint.size.width;
    const height = paint.size.height;
    const output = try allocator.alloc(u32, @as(usize, width) * height);
    defer allocator.free(output);
    if (@TypeOf(renderer.*) != ui.SoftwareRenderer) try renderer.readPixelsForTest(width, height, output) else {
        if (builtin.os.tag == .windows and c.GdiFlush() == 0) return error.FlushFailed;
        for (0..height) |y| for (0..width) |x| {
            output[y * width + x] = if (builtin.os.tag == .windows) renderer.pixels.?[y * width + x] & 0xffffff else zlc_test_raw_pixel(renderer.native.?, @intCast(x), @intCast(y));
        };
    }
    for (0..height) |y| for (0..width) |x| {
        var expected: u32 = bg;
        for (items) |item| expected = over(expected, item.tint, sample(item, @intCast(x), @intCast(y)));
        try near(expected, output[y * width + x], @intCast(x), @intCast(y));
    };
}
fn render(renderer: anytype, allocator: std.mem.Allocator, base: z.Paint) !void {
    const main_thread = std.Thread.getCurrentId();
    const path = try vector.Path.parseData(allocator, "M0 10 C0 0 20 0 20 10 A10 10 0 0 1 0 10 Z M7 7 h6 v6 h-6 Z", .{});
    defer path.close() catch unreachable;
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        var paint = base;
        paint.size = .{ .width = @intFromFloat(128 * scale), .height = @intFromFloat(100 * scale), .scale = scale };
        const outer = try shadows.PreparedShadow.create(allocator, .{ .width = 20, .height = 16, .radius = 5 }, .{ .offset = .{ .x = 2, .y = 1 }, .spread = 1, .sigma = 1.5 }, .{ .main_thread = main_thread, .scale = scale });
        defer outer.close() catch unreachable;
        const inset = try shadows.PreparedShadow.create(allocator, .{ .width = 20, .height = 16, .radius = 5 }, .{ .kind = .inset, .offset = .{ .x = 2, .y = 1 }, .sigma = 1.5, .spread = 1 }, .{ .main_thread = main_thread, .scale = scale });
        defer inset.close() catch unreachable;
        const fill = try path.prepare(allocator, .{ .main_thread = main_thread, .viewport = .{ .x = -3, .y = -3, .width = 26, .height = 26 }, .scale = scale, .style = .{ .fill = .even_odd } });
        defer fill.close() catch unreachable;
        const stroke = try path.prepare(allocator, .{ .main_thread = main_thread, .viewport = .{ .x = -3, .y = -3, .width = 26, .height = 26 }, .scale = scale, .style = .{ .stroke = .{ .width = 2, .cap = .round, .join = .round } } });
        defer stroke.close() catch unreachable;
        const dash_path = try vector.Path.parseData(allocator, "M0 10 C0 0 20 0 20 10 A10 10 0 0 1 0 10 Z", .{});
        const dashed = dash_path.prepare(allocator, .{ .main_thread = main_thread, .viewport = .{ .x = -3, .y = -3, .width = 26, .height = 26 }, .scale = scale, .style = .{ .stroke = .{ .width = 2, .cap = .round, .join = .round, .dashes = &.{ 3, 2, 1 }, .dash_offset = -2, .trim = .{ .start = 0.1, .end = 0.9 } } } }) catch |err| {
            try dash_path.close();
            return err;
        };
        try dash_path.close();
        defer dashed.close() catch unreachable;
        var raw_lease = drawing.Lease.init(main_thread);
        const raw = [_]u8{ 0, 0, 0, 0, 0, 91, 92, 0, 64, 128, 255, 0, 93, 94, 0, 0, 0, 0, 0, 95, 96 };
        const unaligned: drawing.CoverageView = .{ .lease = &raw_lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &raw, .width = 5, .height = 3, .stride = 7, .origin_x = 0, .origin_y = 0, .scale = scale } };
        var edge_leases: [3]drawing.Lease = undefined;
        var edges: [3]drawing.CoverageView = undefined;
        const solid = @as([4]u8, @splat(255));
        for (&edge_leases, &edges) |*lease, *view| {
            lease.* = drawing.Lease.init(main_thread);
            view.* = .{ .lease = lease, .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &solid, .width = 2, .height = 2, .stride = 2, .origin_x = 0, .origin_y = 0, .scale = scale } };
        }
        const items = [_]Item{
            .{ .view = try outer.view(), .origin = .{ .x = 25, .y = 20 }, .tint = .{ .r = 240, .g = 30, .b = 80, .a = 170 } },
            .{ .view = try inset.view(), .origin = .{ .x = 75, .y = 20 }, .tint = .{ .r = 20, .g = 220, .b = 100, .a = 128 } },
            .{ .view = try fill.view(), .origin = .{ .x = 25, .y = 65 }, .tint = .{ .r = 30, .g = 80, .b = 240, .a = 200 }, .clip = .{ .x = 28, .y = 64, .width = 10, .height = 20 } },
            .{ .view = try stroke.view(), .origin = .{ .x = 75, .y = 65 }, .tint = .{ .r = 240, .g = 240, .b = 40, .a = 140 } },
            .{ .view = try dashed.view(), .origin = .{ .x = 100, .y = 65 }, .tint = .{ .r = 20, .g = 220, .b = 240, .a = 170 }, .clip = .{ .x = 102, .y = 64, .width = 22, .height = 24 } },
            .{ .view = unaligned, .origin = .{ .x = 8.5, .y = 8.5 }, .tint = .{ .r = 255, .g = 0, .b = 0, .a = 128 } },
            .{ .view = edges[0], .origin = .{ .x = 8 + 0.25 / scale, .y = 16 + 0.25 / scale }, .tint = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
            .{ .view = edges[1], .origin = .{ .x = 8 + 0.5 / scale, .y = 24 + 0.5 / scale }, .tint = .{ .r = 0, .g = 255, .b = 0, .a = 160 }, .clip = .{ .x = 8 + 1 / scale, .y = 24, .width = 1 / scale, .height = 4 / scale } },
            .{ .view = edges[2], .origin = .{ .x = 8 + 0.75 / scale, .y = 32 + 0.75 / scale }, .tint = .{ .r = 0, .g = 0, .b = 255, .a = 200 } },
        };
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        defer {
            if (@TypeOf(renderer.*) != ui.SoftwareRenderer) if (renderer.active) {
                renderer.abort();
            };
            buffer.reset();
            for (items) |item| {
                _ = renderer.releaseCoverage(item.view.identity) catch false;
            }
        }
        try buffer.fill(.{ .x = 0, .y = 0, .width = 128, .height = 100 }, bg);
        for (items) |item| {
            try renderer.uploadCoverage(item.view);
            if (item.clip) |clip| try buffer.pushClip(clip);
            try buffer.coverage(item.origin, item.view, item.tint);
            if (item.clip != null) try buffer.popClip();
        }
        try equal(items.len, buffer.coverageResources().len);
        try expectError(error.ResourceInUse, outer.close());
        const before = renderer.coverageStats();
        for (0..3) |_| {
            try renderer.begin(paint);
            try renderer.replayBuffer(&buffer);
            try pixels(renderer, allocator, paint, &items);
            try finish(renderer, paint);
        }
        try equal(before.native_creations, renderer.coverageStats().native_creations);
        buffer.reset();
        // An empty legacy resource entry point must fail explicitly.
        var missing: ui.commands.Buffer = .{};
        defer missing.reset();
        try missing.coverage(.{}, items[0].view, ui.Color.rgb(0));
        try renderer.begin(paint);
        try expectError(error.MissingResources, renderer.replay(missing.commands(), missing.textBytes()));
        if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try finish(renderer, paint);
        missing.reset();
        var wrong = items[0].view;
        wrong.coverage.scale = 3;
        try renderer.begin(paint);
        try expectError(error.CoverageDpiMismatch, renderer.coverage(wrong, .{}, ui.Color.rgb(0)));
        try finish(renderer, paint);
        for (items) |item| _ = try renderer.releaseCoverage(item.view.identity);
        for (items) |item| try equal(0, item.view.lease.pins);
        try equal(0, renderer.coverageStats().native_objects);
    }
}
fn pressure(renderer: anytype, paint: z.Paint) !void {
    var leases: [35]drawing.Lease = undefined;
    for (&leases) |*lease| lease.* = drawing.Lease.init(std.Thread.getCurrentId());
    var data: [16]u8 = @splat(255);
    const levels = [_]drawing.ImageLevel{.{ .pixels = &data, .byte_len = 16, .width = 2, .height = 2, .stride = 8 }};
    var views: [33]drawing.CoverageView = undefined;
    for (&views, 0..) |*view, i| view.* = .{ .lease = &leases[i], .identity = try drawing.reserveRasterIdentity(), .coverage = .{ .pixels = &data, .width = 4, .height = 4, .stride = 4, .origin_x = 0, .origin_y = 0, .scale = 1 } };
    const image: drawing.ImageView = .{ .lease = &leases[33], .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    const replacement: drawing.ImageView = .{ .lease = &leases[34], .identity = try drawing.reserveRasterIdentity(), .levels = &levels };
    try renderer.setRasterBudget(4096);
    try renderer.uploadDynamicImage(image);
    try renderer.uploadCoverage(views[0]);
    if (comptime resident(@TypeOf(renderer.*))) {
        const before = renderer.rasterStats();
        const faults: u32 = if (@TypeOf(renderer.*) == ui.SoftwareRenderer) 2 else 1;
        for (1..faults + 1) |fault| {
            renderer.injectImageUploadFailureForTest(@intCast(fault));
            if (@TypeOf(renderer.*) == ui.SoftwareRenderer) try expectError(error.CoverageUploadFailed, renderer.uploadCoverage(views[1])) else try expectError(error.GraphicsFailed, renderer.uploadCoverage(views[1]));
            const failed = renderer.rasterStats();
            try equal(before.resident_entries, failed.resident_entries);
            try equal(before.pixel_bytes, failed.pixel_bytes);
            try equal(before.coverage.native_objects, failed.coverage.native_objects);
            try equal(0, views[1].lease.pins);
        }
        for (views[1..31]) |view| try renderer.uploadCoverage(view);
        try equal(32, renderer.rasterStats().resident_entries);
        // Refresh dynamic image before evicting the oldest A8 entry.
        try renderer.uploadDynamicImage(image);
        try renderer.uploadCoverage(views[31]);
        try equal(0, views[0].lease.pins);
        try equal(32, renderer.rasterStats().resident_entries);
        try renderer.begin(paint);
        try expectError(error.CoverageNotUploaded, renderer.coverage(views[0], .{}, ui.Color.rgb(0)));
        try renderer.coverage(views[1], .{ .x = 2, .y = 2 }, ui.Color.rgb(0xff0000));
        try finish(renderer, paint);
    }
    try renderer.updateImage(image.identity, replacement);
    try renderer.updateImage(image.identity, replacement);
    try equal(1, renderer.imageStats().updates);
    _ = try renderer.releaseImage(replacement.identity);
    const mask_charge: usize = if (@TypeOf(renderer.*) != ui.SoftwareRenderer) 36 else 16;
    try renderer.setRasterBudget(mask_charge);
    try equal(if (comptime resident(@TypeOf(renderer.*))) mask_charge else @as(usize, 0), renderer.rasterStats().pixel_bytes);
    for (views) |view| _ = try renderer.releaseCoverage(view.identity);
    for (leases) |lease| try equal(0, lease.pins);
    try renderer.setRasterBudget(drawing.default_image_budget);
}
const State = struct {
    view: drawing.CoverageView,
    context: *ui.Context = undefined,
    window: z.Window = undefined,
    err: ?anyerror = null,
    bad: bool = false,
    close: bool = false,
    diagnostics: usize = 0,
    expected: ?anyerror = null,
    fn action(_: *anyopaque, _: u64) void {}
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        // Compare unwrapped error payloads; see docs/toolchain-known-issues.md.
        const matches = if (value.err) |actual| if (self.expected) |wanted| actual == wanted else false else false;
        if (matches) self.diagnostics += 1 else {
            std.debug.print("unexpected coverage diagnostic: {any}, expected={any}, operation={s}\n", .{ value.err, self.expected, @tagName(value.operation) });
            self.err = value.err orelse error.UnexpectedDiagnostic;
        }
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.checked(frame) catch |err| {
            self.err = err;
        };
    }
    fn checked(self: *State, frame: *ui.Frame) !void {
        frame.clear(bg);
        try frame.coverage(.{ .x = 10, .y = 10 }, self.view, .{ .r = 255, .g = 0, .b = 0, .a = 128 });
        try expectError(error.ResourceInUse, self.view.lease.ensureUnused());
        try expectError(error.Busy, self.context.releaseCoverage(self.view.identity));
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
fn integrated(allocator: std.mem.Allocator, gpu: bool, pending_close: bool) !void {
    var state: State = .{ .view = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    var context = ui.Context.init(&state, State.draw, State.action);
    context.render_mode = if (gpu) .warp else .gdi;
    state.context = &context;
    const window = try app.createWindow(.{});
    state.window = window;
    const scale: f32 = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(window.nativeHandle().?));
    const shadow = try shadows.PreparedShadow.create(allocator, .{ .width = 20, .height = 16, .radius = 4 }, .{ .kind = .inset, .sigma = 1 }, .{ .main_thread = std.Thread.getCurrentId(), .scale = scale });
    defer shadow.close() catch unreachable;
    defer {
        if (!window.isClosed()) {
            _ = window.destroy() catch unreachable;
        }
    }
    state.view = try shadow.view();
    try context.attach(window);
    try context.uploadCoverage(state.view);
    try state.paint();
    const pins: usize = if (gpu or builtin.os.tag != .windows) 1 else 0;
    try equal(pins, state.view.lease.pins);
    state.bad = true;
    state.expected = error.InvalidGeometry;
    try state.paint();
    try equal(1, state.diagnostics);
    try equal(pins, state.view.lease.pins);
    state.bad = false;
    state.expected = null;
    if (ui.capabilities.gpu) if (gpu) {
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        context.gpu_renderer.injectImageUploadDeviceLossForTest();
        var extra = state.view;
        extra.identity = try drawing.reserveRasterIdentity();
        try expectError(error.DeviceLost, context.uploadCoverage(extra));
        try expect(context.gpu_wait == null);
        try expect(!app.unwatchNative(token));
        try state.paint();
        try expect((try context.coverageStats()).gpu.?.restores > 0);
        context.gpu_renderer.injectDeviceLoss();
        state.expected = error.DeviceLost;
        try state.paint();
        try equal(1, context.fallbacks);
        state.expected = null;
        // A resource release cancels the old borrowed wait before touching GPU.
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        try expect(context.gpu_wait != null);
    };
    _ = try context.releaseCoverage(state.view.identity);
    try equal(0, state.view.lease.pins);
    try context.uploadCoverage(state.view);
    if (ui.capabilities.gpu and pending_close) {
        context.gpu_renderer.injectPresentationBusy();
        try state.paint();
        const token = context.gpu_wait orelse return error.MissingGpuWatch;
        _ = try window.destroy();
        try expect(!app.unwatchNative(token));
    } else {
        state.close = true;
        try state.paint();
    }
    try expect(window.isClosed());
    try app.run();
    try equal(0, state.view.lease.pins);
    try expect(context.window == null);
    try expect(context.gpu_wait == null);
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
            const dc = c.GetDC(hwnd) orelse return error.CreateSurfaceFailed;
            defer _ = c.ReleaseDC(hwnd, dc);
            const paint: z.Paint = .{ .native_context = dc, .native_window = hwnd, .size = .{ .width = 128, .height = 100, .scale = 1 } };
            const before = c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS);
            {
                var renderer: ui.SoftwareRenderer = .{};
                defer renderer.deinit();
                try render(&renderer, allocator, paint);
                try pressure(&renderer, paint);
            }
            try equal(before, c.GetGuiResources(c.GetCurrentProcess(), c.GR_GDIOBJECTS));
            if (ui.capabilities.gpu) for ([_]ui.d3d11.Driver{ .hardware, .warp }) |driver| {
                var renderer: ui.d3d11.Renderer = .{};
                try renderer.init(.{ .driver = driver });
                defer renderer.deinit();
                try render(&renderer, allocator, paint);
                try pressure(&renderer, paint);
                renderer.deinit();
                try equal(0, ui.d3d11.globalResourceCount());
                std.debug.print("coverage {s}: A8 shadow/path pixels, DPI, mixed residency and resources=0\n", .{@tagName(driver)});
            };
        }
        _ = try window.destroy();
    } else {
        const surface = cairo_image_surface_create(0, 256, 200) orelse return error.CreateSurfaceFailed;
        defer cairo_surface_destroy(surface);
        const dc = cairo_create(surface) orelse return error.CreateSurfaceFailed;
        defer cairo_destroy(dc);
        const paint: z.Paint = .{ .native_context = dc, .size = .{ .width = 128, .height = 100, .scale = 1 } };
        var renderer: ui.SoftwareRenderer = .{};
        defer renderer.deinit();
        try render(&renderer, allocator, paint);
        try pressure(&renderer, paint);
        renderer.deinit();
        try equal(0, zlc_test_live_image_objects());
    }
    try integrated(allocator, false, false);
    if (ui.capabilities.gpu) {
        try integrated(allocator, true, false);
        try integrated(allocator, true, true);
    }
    std.debug.print("coverage: software/path/shadow pixels, padded A8, shared budget/LRU32, candidate rollback, dynamic retry and Context failed/close pins passed\n", .{});
}
