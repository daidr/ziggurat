const std = @import("std");
const zio = @import("ziggurat_io");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const reference = @import("gradient_interpolation_oracle.zig");
const b = ui.commands.brushes;
const c = @import("ziggurat_c_win32");
extern fn zgi_registered(*anyopaque, *u32) i32;
extern fn zgi_after_program_free(*anyopaque, *anyopaque, *const fn (*anyopaque) callconv(.c) void) i32;
extern fn zgi_hook_pending() c_int;
const width = 32;
const height = 24;
const bounds: ui.Rect = .{ .x = 0, .y = 0, .width = width, .height = height };

fn stops(output: *[16]b.Stop, count: usize, palette: usize) []const b.Stop {
    const colors = [_]u32{ 0, 0xffffff, 0x00ff00, 0x0000ff, 0xffff00, 0xff00ff, 0xff0000, 0x00ffff };
    for (output[0..count], 0..) |*stop, index| stop.* = .{ .offset = if (index + 1 == count) 1 else @as(f32, @floatFromInt(index)) / 64, .color = .rgb(colors[(index * 3 + palette) % colors.len]) };
    return output[0..count];
}
fn gradient(space: b.InterpolationSpace, values: []const b.Stop, direction: usize) b.Gradient {
    return .{ .linear = .{
        .start = if (direction == 1) .{ .x = width } else if (direction == 3) .{ .y = height } else .{},
        .end = if (direction == 0) .{ .x = width } else if (direction == 2) .{ .y = height } else .{},
        .stops = values,
        .interpolation = space,
    } };
}
fn near(want: u32, actual: u32, x: usize, y: usize) !u32 {
    var maximum: u32 = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const aa: i32 = @intCast((want >> shift) & 255);
        const bb: i32 = @intCast((actual >> shift) & 255);
        const difference: u32 = @intCast(@abs(aa - bb));
        maximum = @max(maximum, difference);
        if (difference > 1) {
            std.debug.print("prepared interpolation pixel={d},{d} want={x} actual={x} delta={d}\n", .{ x, y, want, actual, difference });
            return error.PixelMismatch;
        }
    }
    return maximum;
}
fn rejected(surface: *ui.gpu_offscreen.Surface, buffer: *ui.commands.Buffer, pixels: []u32, preserved: []const u32) !void {
    const old = try surface.stats();
    try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(buffer));
    const now = try surface.stats();
    std.debug.print("reject checkpoint renders={d}->{d} clear={d}->{d}\n", .{ old.renders, now.renders, old.layers.clear_pixels, now.layers.clear_pixels });
    try std.testing.expectEqual(old.renders, now.renders);
    try std.testing.expectEqualDeep(old.layers, now.layers);
    try surface.readFrontForTest(pixels);
    try std.testing.expectEqualSlices(u32, preserved, pixels);
}
fn surfaceCase(app: *z.App, driver: ui.gpu_resources.Driver, scale: f32) !void {
    const allocator = std.heap.page_allocator;
    const domain = try ui.gpu_resources.DeviceDomain.create(app, allocator, .{ .driver = driver });
    defer domain.close() catch unreachable;
    const size: z.Size = .{ .width = @intFromFloat(width * scale), .height = @intFromFloat(height * scale), .scale = scale };
    const surface = try ui.gpu_offscreen.Surface.create(domain, allocator, .{ .size = size });
    defer surface.close() catch unreachable;
    const pixels = try allocator.alloc(u32, @as(usize, size.width) * size.height);
    defer allocator.free(pixels);
    const saved = try allocator.alloc(u32, pixels.len);
    defer allocator.free(saved);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try buffer.fill(bounds, 0x112233);
    try surface.render(&buffer);
    try surface.readFrontForTest(saved);
    const before_metadata = (try domain.stats()).metadata_reservation;
    var values: [16]b.Stop = undefined;
    buffer.reset();
    try buffer.gradientRect(bounds, 0, gradient(.srgb, stops(&values, 2, 0), 0));
    try buffer.gradientRect(bounds, 0, gradient(.oklab, values[0..2], 0));
    try rejected(surface, &buffer, pixels, saved);
    try std.testing.expectEqual(@as(u32, 0), (try surface.gradientInterpolationStats()).ready);
    try surface.prepareGradientInterpolation();
    const prepared = try surface.gradientInterpolationStats();
    std.debug.print("prepare checkpoint {s} DPI={d}: {any}\n", .{ @tagName(driver), scale, prepared });
    try std.testing.expectEqual(@as(u32, 1), prepared.ready);
    try std.testing.expect(prepared.metadata_actual > 0 and prepared.metadata_actual == prepared.metadata_reserved);
    try std.testing.expectEqual(before_metadata + prepared.metadata_reserved, (try domain.stats()).metadata_reservation);
    const resources = ui.d3d11.globalResourceCount();
    try surface.prepareGradientInterpolation();
    std.debug.print("repeat checkpoint: {any}\n", .{try surface.gradientInterpolationStats()});
    try std.testing.expectEqual(resources, ui.d3d11.globalResourceCount());
    try std.testing.expectEqualDeep(prepared, try surface.gradientInterpolationStats());
    var maximum: u32 = 0;
    var planes: usize = 0;
    for ([_]b.InterpolationSpace{ .srgb_linear, .oklab }) |space| for ([_]usize{ 2, 4, 16 }) |count| for (0..4) |palette| for (0..4) |direction| {
        const colors = stops(&values, count, palette);
        buffer.reset();
        try buffer.gradientRect(bounds, 0, gradient(space, colors, direction));
        try surface.render(&buffer);
        try surface.readFrontForTest(pixels);
        const oracle = reference.Palette.init(@backingInt(space), colors);
        for (0..size.height) |y| for (0..size.width) |x| {
            const position = if (direction < 2) (@as(f64, @floatFromInt(x)) + 0.5) / (width * @as(f64, scale)) else (@as(f64, @floatFromInt(y)) + 0.5) / (height * @as(f64, scale));
            const parameter = if (direction == 1 or direction == 3) 1 - position else position;
            maximum = @max(maximum, try near(reference.over(oracle.at(parameter), 0, 255), pixels[y * size.width + x], x, y));
        };
        planes += 1;
    };
    // A complete default plane remains byte-identical with and without the
    // optional program. The recorded default command is never rewritten.
    var pairs: usize = 0;
    std.debug.print("pixel checkpoint planes={d} max_byte={d}\n", .{ planes, maximum });
    for ([_]usize{ 2, 16 }) |count| for (0..3) |kind| {
        const colors = stops(&values, count, 1);
        for (values[0..count], 0..) |*stop, index| stop.offset = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));
        values[count - 1].color = values[0].color;
        const descriptor: b.Gradient = switch (kind) {
            0 => gradient(.srgb, colors, 0),
            1 => .{ .radial = .{ .center = .{ .x = 16, .y = 12 }, .radius = .{ .x = 12, .y = 10 }, .stops = colors } },
            else => .{ .conic = .{ .center = .{ .x = 16, .y = 12 }, .stops = colors } },
        };
        buffer.reset();
        try buffer.gradientRect(bounds, 0, descriptor);
        try surface.render(&buffer);
        try surface.readFrontForTest(saved);
        try surface.releaseGradientInterpolation();
        try surface.render(&buffer);
        try surface.readFrontForTest(pixels);
        try std.testing.expectEqualSlices(u32, saved, pixels);
        try surface.prepareGradientInterpolation();
        pairs += 1;
    };
    buffer.reset();
    try buffer.gradientRect(bounds, 0, gradient(.oklab, stops(&values, 2, 0), 0));
    try surface.render(&buffer);
    try surface.readFrontForTest(saved);
    const texture = try surface.snapshot();
    defer {
        buffer.reset();
        texture.close() catch unreachable;
    }
    buffer.reset();
    try buffer.texture(bounds, try texture.view(), .{});
    var unresolved = gradient(.oklab, values[0..2], 0);
    unresolved.linear.end.x = 0.0625;
    try buffer.gradientRect(bounds, 1, unresolved);
    try rejected(surface, &buffer, pixels, saved);
    buffer.reset();
    try buffer.pushClip(.{ .x = 0.25, .y = 0, .width = width - 1, .height = height });
    unresolved.linear.end.x = 20000;
    try buffer.gradientRect(bounds, 0, unresolved);
    try buffer.popClip();
    try rejected(surface, &buffer, pixels, saved);
    buffer.reset();
    try surface.injectDeviceLossForTest();
    try std.testing.expectError(error.DeviceLost, surface.render(&buffer));
    const lost = try surface.gradientInterpolationStats();
    try std.testing.expectEqual(@as(u32, 0), lost.ready);
    try std.testing.expect(lost.metadata_actual < lost.metadata_reserved);
    try std.testing.expectError(error.DomainDeviceLost, surface.prepareGradientInterpolation());
    try domain.recreate();
    try buffer.gradientRect(bounds, 0, gradient(.oklab, values[0..2], 0));
    try std.testing.expectError(error.UnsupportedGradientPrecision, surface.render(&buffer));
    try surface.prepareGradientInterpolation();
    try surface.render(&buffer);
    try std.testing.expectEqual(@as(u32, 1), (try surface.gradientInterpolationStats()).ready);
    try surface.releaseGradientInterpolation();
    try std.testing.expectEqual(before_metadata, (try domain.stats()).metadata_reservation);
    buffer.reset();
    std.debug.print("gradient program {s} DPI={d}: planes={d} max_byte={d} default_bitexact_pairs={d} beforeclear/Texture/loss/reprepare/metadata green\n", .{ @tagName(driver), scale, planes, maximum, pairs });
}
fn candidateFailures(app: *z.App) !void {
    std.debug.print("candidate failures begin\n", .{});
    const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    defer renderer.deinit();
    var worker: WrongThread = .{ .renderer = &renderer };
    const thread = try std.Thread.spawn(.{}, WrongThread.run, .{&worker});
    thread.join();
    var registered: u32 = 99;
    const first_registered_hr = zgi_registered(renderer.native.?, &registered);
    std.debug.print("registration checkpoint HRESULT={x} found={d}\n", .{ @as(u32, @bitCast(first_registered_hr)), registered });
    try std.testing.expect(first_registered_hr >= 0);
    try std.testing.expectEqual(@as(u32, 0), registered);
    const before = try domain.stats();
    const resources = ui.d3d11.globalResourceCount();
    for (1..5) |stage| {
        std.debug.print("candidate checkpoint stage={d}\n", .{stage});
        try std.testing.expectError(error.GraphicsFailed, renderer.createGradientInterpolationCandidateWithFailureForTest(@intCast(stage)));
        try std.testing.expectEqual(resources, ui.d3d11.globalResourceCount());
        try std.testing.expectEqual(before.metadata_reservation, (try domain.stats()).metadata_reservation);
        try std.testing.expect(!(try renderer.gradientInterpolationReady()));
    }
    try renderer.prepareGradientInterpolation();
    const prepared_registered_hr = zgi_registered(renderer.native.?, &registered);
    std.debug.print("registered prepare checkpoint HRESULT={x} found={d}\n", .{ @as(u32, @bitCast(prepared_registered_hr)), registered });
    try std.testing.expect(prepared_registered_hr >= 0);
    try std.testing.expectEqual(@as(u32, 1), registered);
    const prepared = try renderer.gradientInterpolationStats();
    try std.testing.expectError(error.AlreadyPrepared, renderer.createGradientInterpolationCandidateWithFailureForTest(1));
    try std.testing.expectEqualDeep(prepared, try renderer.gradientInterpolationStats());
    try renderer.releaseGradientInterpolation();
    const released_registered_hr = zgi_registered(renderer.native.?, &registered);
    std.debug.print("registered release checkpoint HRESULT={x} found={d}\n", .{ @as(u32, @bitCast(released_registered_hr)), registered });
    try std.testing.expect(released_registered_hr >= 0);
    try std.testing.expectEqual(@as(u32, 0), registered);
    try std.testing.expectEqual(before.metadata_reservation, (try domain.stats()).metadata_reservation);
}
const WrongThread = struct {
    renderer: *ui.d3d11.Renderer,
    fn run(self: *@This()) void {
        std.testing.expectError(error.WrongThread, self.renderer.gradientInterpolationReady()) catch unreachable;
        std.testing.expectError(error.WrongThread, self.renderer.gradientInterpolationStats()) catch unreachable;
        std.testing.expectError(error.WrongThread, self.renderer.prepareGradientInterpolation()) catch unreachable;
        std.testing.expectError(error.WrongThread, self.renderer.releaseGradientInterpolation()) catch unreachable;
    }
};
const CloseHook = struct {
    app: *z.App,
    window: z.Window = undefined,
    fired: bool = false,
    returned: bool = false,
    closed: bool = false,
    draws: usize = 0,
    quit: bool,
    fn afterFree(ptr: *anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.fired = true;
        const old_draws = self.draws;
        _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0);
        std.debug.assert(self.draws == old_draws);
        if (self.quit) self.app.quit() else _ = self.window.destroy() catch unreachable;
        std.debug.assert(!self.closed);
        self.returned = true;
    }
};
const ClosingContext = struct {
    context: ui.Context,
    hook: *CloseHook,
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const hook: *CloseHook = @ptrCast(@alignCast(ptr));
        hook.draws += 1;
        frame.clear(0);
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn onClosed(ptr: *anyopaque, _: z.Window) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.hook.returned or !self.hook.fired);
        self.hook.closed = true;
        std.heap.page_allocator.destroy(self);
    }
};
fn reentry(quit: bool, shared: bool) !void {
    std.debug.print("reentry checkpoint begin quit={any} domain={any}\n", .{ quit, shared });
    return reentryBody(quit, shared) catch |err| {
        std.debug.print("reentry failure quit={any} domain={any}: {s}\n", .{ quit, shared, @errorName(err) });
        return err;
    };
}
fn reentryBody(quit: bool, shared: bool) !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    const domain = if (shared) try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = .warp }) else null;
    defer if (domain) |value| value.close() catch unreachable;
    var hook: CloseHook = .{ .app = app, .quit = quit };
    const host = try std.heap.page_allocator.create(ClosingContext);
    host.* = .{ .context = ui.Context.init(&hook, ClosingContext.draw, ClosingContext.action), .hook = &hook };
    var window_created = false;
    defer {
        if (!hook.closed) {
            if (window_created) _ = hook.window.destroy() catch unreachable else std.heap.page_allocator.destroy(host);
        }
        if (app.phase == .stopping) app.finishShutdown() catch unreachable else app.dispatch() catch unreachable;
    }
    host.context.render_mode = .warp;
    host.context.gpu_domain = domain;
    hook.window = try app.createWindow(.{ .on_closed = .{ .context = host, .notify = ClosingContext.onClosed } });
    window_created = true;
    try host.context.attach(hook.window);
    std.debug.print("reentry attached\n", .{});
    try host.context.prepareGradientInterpolation();
    std.debug.print("reentry prepared\n", .{});
    try std.testing.expect(zgi_after_program_free(host.context.gpu_renderer.native.?, &hook, CloseHook.afterFree) >= 0);
    if (domain) |value| {
        try value.injectDeviceLossForTest();
    } else {
        // Deliver the ordinary renderer's real staged loss through a native
        // paint, just as its public retry path does; do not fabricate a State.
        host.context.gpu_renderer.injectDeviceLoss();
        _ = c.SendMessageW(hook.window.nativeHandle(), c.WM_PAINT, 0, 0);
        try std.testing.expectEqual(@as(usize, 1), host.context.gdi_frames);
        try std.testing.expect(!(try host.context.gpu_renderer.gradientInterpolationReady()));
    }
    std.debug.print("reentry lost\n", .{});
    try std.testing.expectEqual(@as(u32, 1), (try host.context.gpu_renderer.gradientInterpolationStats()).device_losses);
    if (domain) |value| try value.recreate();
    std.debug.print("reentry recreated\n", .{});
    try std.testing.expectError(error.Closed, host.context.prepareGradientInterpolation());
    // The ordinary backend safe point completes the deferred close. on_closed
    // may then free the entire embedded Context; do not read host again.
    if (quit) try app.finishShutdown() else try app.dispatch();
    try std.testing.expect(hook.fired and hook.returned and hook.closed);
    try std.testing.expectEqual(@as(c_int, 0), zgi_hook_pending());
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("reentry checkpoint green quit={any} domain={any}\n", .{ quit, shared });
}
fn ordinaryStopped() !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    var hook: CloseHook = .{ .app = app, .quit = true };
    var context = ui.Context.init(&hook, ClosingContext.draw, ClosingContext.action);
    context.render_mode = .warp;
    hook.window = try app.createWindow(.{});
    try context.attach(hook.window);
    defer {
        app.quit();
        app.finishShutdown() catch unreachable;
    }
    const before = ui.d3d11.globalResourceCount();
    app.quit();
    try std.testing.expectError(error.Closed, context.prepareGradientInterpolation());
    try std.testing.expectEqual(before, ui.d3d11.globalResourceCount());
    std.debug.print("ordinary stopped admission green\n", .{});
}
fn fullMetadata(app: *z.App) !void {
    const probe = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{});
    const base = (try probe.stats()).metadata_reservation;
    try probe.close();
    const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .texture_bytes = 1, .total_bytes = base + 1 });
    defer domain.close() catch unreachable;
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    defer renderer.deinit();
    const before = ui.d3d11.globalResourceCount();
    try std.testing.expectError(error.CapacityExceeded, renderer.prepareGradientInterpolation());
    try std.testing.expectEqual(before, ui.d3d11.globalResourceCount());
    try std.testing.expectEqual(base, (try domain.stats()).metadata_reservation);
}
fn stopped() !void {
    const app = try z.App.init(std.heap.page_allocator);
    defer app.deinit();
    const domain = try ui.gpu_resources.DeviceDomain.create(app, std.heap.page_allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    defer renderer.deinit();
    try renderer.prepareGradientInterpolation();
    app.quit();
    try std.testing.expectError(error.Closed, renderer.prepareGradientInterpolation());
    try std.testing.expect(try renderer.gradientInterpolationReady());
    try app.finishShutdown();
    try std.testing.expect(!(try renderer.gradientInterpolationReady()));
    try renderer.releaseGradientInterpolation();
    try std.testing.expectEqual(@as(u64, 0), (try renderer.gradientInterpolationStats()).metadata_reserved);
}
pub fn main(init: std.process.Init.Minimal) !void {
    if (builtin.os.tag != .windows or !ui.capabilities.gpu) return error.GpuNotEnabled;
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--ordinary-stop")) return ordinaryStopped();
    if (args.len == 2 and std.mem.eql(u8, args[1], "--ordinary-reentry")) return reentry(true, false);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--conditioning")) {
        const app = try z.App.init(std.heap.page_allocator);
        defer app.deinit();
        for ([_]ui.gpu_resources.Driver{ .hardware, .warp }) |driver| {
            try @import("gradient_program_cases.zig").conditioning(app, driver);
        }
        try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--unified")) {
        const app = try z.App.init(std.heap.page_allocator);
        defer app.deinit();
        for ([_]ui.gpu_resources.Driver{ .hardware, .warp }) |driver| {
            for ([_]f32{ 1, 1.5, 2 }) |scale| try @import("gradient_program_cases.zig").run(app, driver, scale);
            try @import("gradient_program_cases.zig").wide(app, driver);
        }
        try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
        std.debug.print("unified prepared GPU interpolation: actual two-driver pixel oracle, warm resources0\n", .{});
        return;
    }
    {
        const app = try z.App.init(std.heap.page_allocator);
        defer app.deinit();
        for ([_]ui.gpu_resources.Driver{ .hardware, .warp }) |driver| for ([_]f32{ 1, 1.5, 2 }) |scale| try surfaceCase(app, driver, scale);
        for ([_]ui.gpu_resources.Driver{ .hardware, .warp }) |driver| {
            for ([_]f32{ 1, 1.5, 2 }) |scale| try @import("gradient_program_cases.zig").run(app, driver, scale);
            try @import("gradient_program_cases.zig").wide(app, driver);
        }
        try candidateFailures(app);
        std.debug.print("candidate checkpoint green\n", .{});
        try fullMetadata(app);
        std.debug.print("metadata checkpoint green\n", .{});
        const resources = app.resourceStats();
        try std.testing.expectEqual(@as(usize, 0), resources.live_windows);
        try std.testing.expectEqual(@as(usize, 0), resources.allocated_records);
        try std.testing.expectEqual(@as(usize, 0), resources.stop_participants);
    }
    try stopped();
    std.debug.print("stop checkpoint green\n", .{});
    try reentry(false, true);
    try reentry(true, true);
    try ordinaryStopped();
    try reentry(false, false);
    try reentry(true, false);
    try std.testing.expectEqual(@as(u32, 0), ui.d3d11.globalResourceCount());
    std.debug.print("gradient program: 576 independent oracle planes, 36 original-program pairs, known resources0\n", .{});
}
