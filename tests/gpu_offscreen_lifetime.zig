const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const Surface = ui.gpu_offscreen.Surface;
const Domain = ui.gpu_resources.DeviceDomain;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const options: ui.gpu_offscreen.Options = .{ .size = .{ .width = 8, .height = 8, .scale = 1 }, .max_depth = 1, .resident_bytes = 0 };
const Hook = struct {
    backing: std.mem.Allocator,
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque) anyerror!void = null,
    armed: enum { none, alloc, free } = .none,
    fail_next: bool = false,
    live: usize = 0,
    calls: usize = 0,
    failure: ?anyerror = null,
    fn allocator(self: *Hook) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn fire(self: *Hook) void {
        self.armed = .none;
        self.callback.?(self.context.?) catch |err| {
            self.failure = err;
        };
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.armed == .alloc) self.fire();
        if (self.fail_next) {
            self.fail_next = false;
            return null;
        }
        const bytes = self.backing.rawAlloc(length, alignment, ret) orelse return null;
        self.live += length;
        return bytes;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        if (self.armed == .free) self.fire();
        self.live -= bytes.len;
        self.backing.rawFree(bytes, alignment, ret);
    }
    fn check(self: *Hook) !void {
        if (self.failure) |err| return err;
        try expect(self.armed == .none);
    }
};
const Observer = struct { closed: bool = false, failure: ?anyerror = null };
const Host = struct {
    allocator: std.mem.Allocator,
    app: *z.App,
    observer: *Observer,
    hook: Hook,
    domain: *Domain = undefined,
    window: z.Window = undefined,
    surface: ?*Surface = null,
    fn interrupt(context: *anyopaque) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.surface) |surface| {
            try expectError(error.Busy, surface.close());
            try expectError(error.Busy, surface.stats());
            try expectError(error.Busy, surface.snapshot());
        }
        try expectError(error.Busy, self.domain.stats());
        _ = try self.window.destroy();
        self.app.quit();
        try expectError(error.Busy, self.app.finishShutdown());
        try self.app.dispatch();
        try expect(!self.observer.closed);
    }
    fn onClosed(context: *anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.release() catch |err| {
            self.observer.failure = err;
        };
    }
    fn release(self: *Host) !void {
        if (self.hook.failure) |err| return err;
        if (self.surface) |surface| {
            self.surface = null;
            try surface.close();
        }
        try equal(@as(usize, 0), (try self.domain.stats()).attachments);
        try equal(@as(usize, 0), (try self.domain.stats()).workspace_reservation);
        try self.domain.close();
        try equal(@as(usize, 0), self.hook.live);
        self.observer.closed = true;
        self.allocator.destroy(self);
    }
};
fn interruptedHost(allocator: std.mem.Allocator, snapshot: bool, fail: bool) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var observer: Observer = .{};
    const host = try allocator.create(Host);
    host.* = .{ .allocator = allocator, .app = app, .observer = &observer, .hook = .{ .backing = allocator } };
    host.hook.context = host;
    host.hook.callback = Host.interrupt;
    host.domain = try Domain.create(app, if (snapshot) host.hook.allocator() else allocator, .{ .driver = .warp });
    host.window = try app.createWindow(.{ .on_closed = .{ .context = host, .notify = Host.onClosed } });
    if (snapshot) {
        host.surface = try Surface.create(host.domain, allocator, options);
        var buffer: ui.commands.Buffer = .{};
        defer buffer.reset();
        try buffer.fill(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0x123456);
        try host.surface.?.render(&buffer);
    }
    host.hook.armed = .alloc;
    host.hook.fail_next = fail;
    const expected: anyerror = if (fail) error.OutOfMemory else error.Closed;
    if (snapshot) try expectError(expected, host.surface.?.snapshot()) else try expectError(expected, Surface.create(host.domain, host.hook.allocator(), options));
    // No Host access after the operation: on_closed can own the entire free.
    try app.dispatch();
    if (observer.failure) |err| return err;
    try expect(observer.closed);
    try app.finishShutdown();
    try equal(@as(u32, 0), ui.d3d11.globalResourceCount());
}
const CloseReentry = struct {
    surface: *Surface,
    domain: *Domain,
    app: *z.App,
    fn run(context: *anyopaque) !void {
        const self: *CloseReentry = @ptrCast(@alignCast(context));
        try expectError(error.Closed, self.surface.close());
        try expectError(error.Closed, self.surface.stats());
        try expectError(error.Busy, self.domain.stats());
        try expectError(error.ResourceInUse, self.domain.close());
        self.app.quit();
        try expectError(error.Busy, self.app.finishShutdown());
    }
};
fn closingReentry(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    const domain = try Domain.create(app, allocator, .{ .driver = .warp });
    var hook: Hook = .{ .backing = allocator };
    const surface = try Surface.create(domain, hook.allocator(), options);
    var reentry: CloseReentry = .{ .surface = surface, .domain = domain, .app = app };
    hook.context = &reentry;
    hook.callback = CloseReentry.run;
    hook.armed = .free;
    try surface.close();
    try hook.check();
    try equal(@as(usize, 0), hook.live);
    try equal(@as(usize, 0), (try domain.stats()).attachments);
    try equal(@as(usize, 0), (try domain.stats()).workspace_reservation);
    try app.finishShutdown();
    app.deinit();
    try domain.close();
}
fn budgets(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const small = try Domain.create(app, allocator, .{ .driver = .warp, .texture_bytes = 16 * 1024, .total_bytes = 64 * 1024 });
    var hook: Hook = .{ .backing = allocator };
    try expectError(error.CapacityExceeded, Surface.create(small, hook.allocator(), options));
    try equal(@as(usize, 0), hook.calls);
    try equal(@as(usize, 0), (try small.stats()).attachments);
    try small.close();
    const domain = try Domain.create(app, hook.allocator(), .{ .driver = .warp, .texture_bytes = 1024 });
    const surface = try Surface.create(domain, allocator, options); // 3*256 bytes
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try surface.render(&buffer);
    const texture = try surface.snapshot(); // last 256 bytes
    const calls = hook.calls;
    try expectError(error.TextureBudgetExceeded, surface.snapshot());
    try equal(calls, hook.calls);
    try texture.close();
    const again = try surface.snapshot();
    try again.close();
    try surface.close();
    try domain.close();
    try equal(@as(usize, 0), hook.live);
}
fn allocationPass(allocator: std.mem.Allocator, app: *z.App) !void {
    const domain = try Domain.create(app, allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    const surface = try Surface.create(domain, allocator, options);
    defer surface.close() catch unreachable;
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try surface.render(&buffer);
    const snapshot = try surface.snapshot();
    defer snapshot.close() catch unreachable;
}
const Worker = struct {
    surface: *Surface,
    domain: *Domain,
    allocator: std.mem.Allocator,
    fn run(self: *Worker) !void {
        var buffer: ui.commands.Buffer = .{};
        try expectError(error.WrongThread, Surface.create(self.domain, self.allocator, options));
        try expectError(error.WrongThread, self.surface.render(&buffer));
        try expectError(error.WrongThread, self.surface.snapshot());
        try expectError(error.WrongThread, self.surface.stats());
        try expectError(error.WrongThread, self.surface.close());
    }
};
fn slotsAndWork(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const domain = try Domain.create(app, allocator, .{ .driver = .warp });
    defer domain.close() catch unreachable;
    var low = options;
    low.render_work = 1;
    const limited = try Surface.create(domain, allocator, low);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try expectError(error.RenderWorkExceeded, limited.render(&buffer));
    try equal(@as(u64, 0), (try limited.stats()).layers.committed_frames);
    try limited.close();
    var hook: Hook = .{ .backing = allocator };
    const surface = try Surface.create(domain, hook.allocator(), options);
    const allocations = hook.calls;
    const native_creations = (try surface.stats()).layers.native_creations;
    for (0..16) |_| try surface.render(&buffer);
    try equal(allocations, hook.calls);
    try equal(native_creations, (try surface.stats()).layers.native_creations);
    var worker: Worker = .{ .surface = surface, .domain = domain, .allocator = allocator };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    var snapshots: [ui.gpu_resources.capacity]*ui.gpu_resources.Texture = undefined;
    for (&snapshots) |*snapshot| snapshot.* = try surface.snapshot();
    const before = try domain.stats();
    try expectError(error.Full, surface.snapshot());
    try equal(before.bitmap_creations, (try domain.stats()).bitmap_creations);
    try equal(@as(usize, ui.gpu_resources.capacity), (try domain.stats()).textures);
    try buffer.texture(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try snapshots[0].view(), .{});
    try expectError(error.ResourceInUse, snapshots[0].close());
    try surface.render(&buffer);
    buffer.reset();
    try surface.close();
    try equal(@as(usize, 0), hook.live);
    try equal(@as(usize, 0), (try domain.stats()).workspace_reservation);
    try expectError(error.ResourceInUse, domain.close());
    for (snapshots) |snapshot| try snapshot.close();
}
pub fn run(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |snapshot| for ([_]bool{ false, true }) |fail| try interruptedHost(allocator, snapshot, fail);
    try closingReentry(allocator);
    try budgets(allocator);
    try slotsAndWork(allocator);
    const app = try z.App.init(allocator);
    defer app.deinit();
    try std.testing.checkAllAllocationFailures(allocator, allocationPass, .{app});
    try equal(@as(u32, 0), ui.d3d11.globalResourceCount());
}
