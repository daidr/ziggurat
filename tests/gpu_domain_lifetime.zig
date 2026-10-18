const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const resources = ui.gpu_resources;
const drawing = ui.drawing;
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
});
const expect = std.testing.expect;
fn equal(expected: anytype, actual: @TypeOf(expected)) !void {
    std.testing.expectEqual(expected, actual) catch |err| {
        std.debug.dumpCurrentStackTrace(null);
        return err;
    };
}
const expectError = std.testing.expectError;
const Hook = struct {
    backing: std.mem.Allocator,
    when: enum { none, allocation, free } = .none,
    callback: ?*const fn (*anyopaque) anyerror!void = null,
    context: ?*anyopaque = null,
    failure: ?anyerror = null,
    calls: usize = 0,
    live: usize = 0,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn fire(self: *Hook) void {
        self.when = .none;
        self.callback.?(self.context.?) catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.when == .allocation) self.fire();
        const value = self.backing.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        return value;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.when == .free) self.fire();
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret);
    }
    fn check(self: *Hook) !void {
        if (self.failure) |err| return err;
        try expect(self.when == .none);
    }
};
const Pixel = struct {
    lease: drawing.Lease,
    level: [1]drawing.ImageLevel,
    fn init() Pixel {
        return .{ .lease = drawing.Lease.init(std.Thread.getCurrentId()), .level = .{.{ .pixels = &.{ 0, 128, 0, 128 }, .byte_len = 4, .width = 1, .height = 1, .stride = 4 }} };
    }
    fn view(self: *Pixel) drawing.ImageView {
        return .{ .lease = &self.lease, .identity = 2, .levels = &self.level };
    }
};
fn budgets(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var hook: Hook = .{ .backing = allocator };
    try expectError(error.CapacityExceeded, resources.DeviceDomain.create(app, hook.allocator(), .{ .total_bytes = 1 }));
    try equal(@as(usize, 0), hook.calls);
    const domain = try resources.DeviceDomain.create(app, hook.allocator(), .{ .driver = .warp, .texture_bytes = 4 });
    var pixel = Pixel.init();
    const texture = try domain.upload(pixel.view());
    const calls = hook.calls;
    try expectError(error.TextureBudgetExceeded, domain.upload(pixel.view()));
    try equal(calls, hook.calls);
    try equal(@as(usize, 4), (try domain.stats()).peak_reserved_bytes);
    try texture.close();
    try domain.close();
    try equal(@as(usize, 0), hook.live);
}
const Reentry = struct {
    domain: *resources.DeviceDomain,
    pixel: *Pixel,
    buffer: *ui.commands.Buffer,
    texture: ?*resources.Texture = null,
    view: ?drawing.TextureView = null,
    app: *z.App,
    fn allocate(context: *anyopaque) !void {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.buffer.reset();
        try expectError(error.ResourceInUse, self.pixel.lease.ensureUnused());
        try expectError(error.Busy, self.domain.close());
        try expectError(error.Busy, self.domain.stats());
        try expectError(error.Busy, self.domain.upload(self.pixel.view()));
    }
    fn free(context: *anyopaque) !void {
        const self: *Reentry = @ptrCast(@alignCast(context));
        try expectError(error.Closed, self.texture.?.view());
        try expectError(error.Closed, self.view.?.validate());
        try expectError(error.Closed, self.texture.?.close());
        try expectError(error.Busy, self.domain.close());
        try expectError(error.Busy, self.domain.stats());
        self.app.quit();
        try expectError(error.Busy, self.app.finishShutdown());
    }
    fn stopOnAllocate(context: *anyopaque) !void {
        const self: *Reentry = @ptrCast(@alignCast(context));
        self.app.quit();
        try expectError(error.Busy, self.app.finishShutdown());
    }
};
fn reentrant(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    var hook: Hook = .{ .backing = allocator };
    const domain = try resources.DeviceDomain.create(app, hook.allocator(), .{ .driver = .warp });
    var pixel = Pixel.init();
    var buffer: ui.commands.Buffer = .{};
    try buffer.image(.{ .x = 0, .y = 0, .width = 4, .height = 4 }, pixel.view(), .{});
    var reentry: Reentry = .{ .domain = domain, .pixel = &pixel, .buffer = &buffer, .app = app };
    hook.context = &reentry;
    hook.callback = Reentry.allocate;
    hook.when = .allocation;
    const texture = try domain.upload(pixel.view());
    try hook.check();
    try pixel.lease.ensureUnused();
    reentry.texture = texture;
    reentry.view = try texture.view();
    hook.callback = Reentry.free;
    hook.when = .free;
    try texture.close();
    try hook.check();
    try app.finishShutdown();
    try equal(@as(u32, 0), (try domain.stats()).native_objects);
    app.deinit();
    try domain.close();
    try equal(@as(usize, 0), hook.live);

    const next = try z.App.init(allocator);
    var interrupted: Hook = .{ .backing = allocator };
    const other = try resources.DeviceDomain.create(next, interrupted.allocator(), .{ .driver = .warp });
    reentry.domain = other;
    reentry.app = next;
    interrupted.context = &reentry;
    interrupted.callback = Reentry.stopOnAllocate;
    interrupted.when = .allocation;
    try expectError(error.Closed, other.upload(pixel.view()));
    try interrupted.check();
    try next.finishShutdown();
    next.deinit();
    try other.close();
    try equal(@as(usize, 0), interrupted.live);
}
const WrongThread = struct {
    app: *z.App,
    allocator: std.mem.Allocator,
    domain: *resources.DeviceDomain,
    texture: *resources.Texture,
    renderer: *ui.d3d11.Renderer,
    pixel: *Pixel,
    fn run(self: *WrongThread) !void {
        try expectError(error.WrongThread, resources.DeviceDomain.create(self.app, self.allocator, .{}));
        try expectError(error.WrongThread, self.domain.stats());
        try expectError(error.WrongThread, self.domain.close());
        try expectError(error.WrongThread, self.texture.view());
        try expectError(error.WrongThread, self.texture.close());
        try expectError(error.WrongThread, self.renderer.begin(.{ .native_context = self.pixel, .size = .{ .width = 1, .height = 1, .scale = 1 } }));
        try expectError(error.WrongThread, self.renderer.replay(&.{}, ""));
        try expectError(error.WrongThread, self.renderer.uploadImage(self.pixel.view()));
        try expectError(error.WrongThread, self.renderer.releaseImage(self.pixel.view().identity));
        try expectError(error.WrongThread, self.renderer.createLayerCandidate(self.allocator, .{ .size = .{ .width = 1, .height = 1, .scale = 1 }, .max_depth = 1 }));
    }
};
fn threadsAndRegistration(allocator: std.mem.Allocator) !void {
    const app = try z.App.initWithOptions(allocator, .{ .stop_capacity = 1 });
    var dummy: usize = 0;
    var node: z.StopParticipant = .{ .context = &dummy, .stop = struct {
        fn call(_: *anyopaque) !void {}
    }.call };
    const token = try app.registerStop(&node);
    try expectError(error.Full, resources.DeviceDomain.create(app, allocator, .{ .driver = .warp }));
    try equal(@as(u32, 0), ui.d3d11.globalResourceCount());
    try expect(try app.cancelStop(token));
    const domain = try resources.DeviceDomain.create(app, allocator, .{ .driver = .warp });
    var borrows: [resources.capacity]resources.DeviceDomain.Borrow = undefined;
    for (&borrows) |*borrow| borrow.* = try domain.acquireRenderer(null);
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    var unused: usize = 0;
    const callbacks = struct {
        fn draw(_: *anyopaque, _: *ui.Frame) void {}
        fn action(_: *anyopaque, _: u64) void {}
    };
    var context = ui.Context.init(&unused, callbacks.draw, callbacks.action);
    context.gpu_domain = domain;
    context.render_mode = .hardware;
    try expectError(error.DomainDriverMismatch, context.attach(window));
    try expect(context.window == null and context.gpu_renderer.native == null);
    context.render_mode = .automatic;
    try expectError(error.Full, context.attach(window));
    try expect(context.window == null and context.gpu_renderer.native == null);
    try equal(@as(usize, resources.capacity), (try domain.stats()).attachments);
    for (borrows) |borrow| domain.releaseRenderer(borrow.slot);
    try context.attach(window);
    _ = try window.destroy();
    try equal(@as(usize, 0), (try domain.stats()).attachments);
    var pixel = Pixel.init();
    const texture = try domain.upload(pixel.view());
    var renderer: ui.d3d11.Renderer = .{};
    try renderer.init(.{ .domain = domain });
    var wrong: WrongThread = .{ .app = app, .allocator = allocator, .domain = domain, .texture = texture, .renderer = &renderer, .pixel = &pixel };
    const thread = try std.Thread.spawn(.{}, WrongThread.run, .{&wrong});
    thread.join();
    renderer.deinit();
    try texture.close();
    try domain.close();
    app.deinit();
}
const Consumer = struct {
    view: drawing.TextureView,
    node: u64 = 1,
    calls: usize = 0,
    close: ?z.Window = null,
    fn draw(context: *anyopaque, frame: *ui.Frame) void {
        const self: *Consumer = @ptrCast(@alignCast(context));
        self.calls += 1;
        frame.clear(0x204060);
        frame.texture(.{ .x = 8, .y = 8, .width = 32, .height = 32 }, self.view, .{}) catch return;
        frame.button(self.node, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, "") catch return;
        if (self.close) |window| _ = window.destroy() catch false;
    }
    fn action(_: *anyopaque, _: u64) void {}
};
fn integrated(allocator: std.mem.Allocator) !void {
    var diagnostics: z.diagnostics.Recorder(16) = .{};
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = diagnostics.sink() });
    defer app.deinit();
    const domain = try resources.DeviceDomain.create(app, allocator, .{});
    defer domain.close() catch unreachable;
    const foreign = try resources.DeviceDomain.create(app, allocator, .{});
    defer foreign.close() catch unreachable;
    var pixel = Pixel.init();
    const texture = try domain.upload(pixel.view());
    defer texture.close() catch unreachable;
    const other = try foreign.upload(pixel.view());
    defer other.close() catch unreachable;
    var state: Consumer = .{ .view = try texture.view() };
    var context = ui.Context.init(&state, Consumer.draw, Consumer.action);
    context.gpu_domain = domain;
    const window = try app.createWindow(.{ .width = 64, .height = 64 });
    defer {
        _ = window.destroy() catch false;
        app.dispatch() catch unreachable;
    }
    try context.attach(window);
    const hwnd = window.nativeHandle();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    const size = context.last_paint_size.?;
    try context.prepareLayers(allocator, .{ .size = size, .max_depth = 2 });
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try expect(context.gpu_frames != 0);
    try expect(context.input_state.available(1));
    const software_frames = context.gdi_frames;
    const surface = context.gpu_renderer.surfaceForTest().?;
    state.view = try other.view();
    state.node = 2;
    const calls = state.calls;
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try equal(calls + 1, state.calls);
    try expect(context.input_state.available(1) and !context.input_state.available(2));
    try expect(c.GetWindowLongW(surface, c.GWL_STYLE) & c.WS_VISIBLE != 0);
    try equal(software_frames, context.gdi_frames);
    try equal(@as(usize, 0), (try other.view()).lease.pins);
    var entries: [16]z.diagnostics.Diagnostic = undefined;
    const snapshot = diagnostics.snapshot(&entries);
    var mismatched = false;
    var unsupported = false;
    for (entries[0..snapshot.count]) |entry| if (entry.err) |err| {
        if (err == error.TextureDomainMismatch) {
            mismatched = true;
            try equal(@as(?u32, null), entry.code);
        }
        if (err == error.UnsupportedTextureBackend) {
            unsupported = true;
            try equal(@as(?u32, null), entry.code);
        }
    };
    try expect(mismatched and unsupported);
    state.view = try texture.view();
    state.node = 1;
    context.gpu_renderer.injectPresentationBusy();
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    const pending = context.gpu_wait orelse return error.MissingGpuWait;
    try domain.injectDeviceLossForTest();
    try expect(context.gpu_wait == null);
    try expect(!app.unwatchNative(pending));
    try equal(@as(usize, 0), state.view.lease.pins);
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try expect(context.input_state.available(1));
    try equal(software_frames, context.gdi_frames);
    try domain.recreate();
    const replacement = try domain.upload(pixel.view());
    defer replacement.close() catch unreachable;
    state.view = try replacement.view();
    state.close = window;
    _ = c.SendMessageW(hwnd, c.WM_PAINT, 0, 0);
    try expect(window.isClosed());
    // Callback-triggered destruction runs at the owner dispatch safe point.
    try app.dispatch();
    try equal(@as(usize, 0), state.view.lease.pins);
    try equal(@as(usize, 0), (try domain.stats()).attachments);
}
pub fn run(allocator: std.mem.Allocator) !void {
    try budgets(allocator);
    try reentrant(allocator);
    try threadsAndRegistration(allocator);
    try integrated(allocator);
}
