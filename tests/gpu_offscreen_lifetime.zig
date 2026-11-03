//! Offscreen surface lifetimes on every GPU platform (D3D11 on Windows,
//! Metal on macOS).
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const gpu = if (builtin.os.tag == .windows) ui.d3d11 else ui.metal;
/// Direct3D's software device; macOS has only the system's.
const soft: ui.gpu_resources.Driver = if (builtin.os.tag == .windows) .warp else .hardware;
const Surface = ui.gpu_offscreen.Surface;
const Domain = ui.gpu_resources.DeviceDomain;
/// A failed check names its line: these runs print no stack traces.
fn verify(ok: bool, at: std.builtin.SourceLocation) !void {
    if (ok) return;
    std.debug.print("check failed at {s}:{d}\n", .{ at.file, at.line });
    return error.CheckFailed;
}
fn equalAt(expected: anytype, actual: @TypeOf(expected), at: std.builtin.SourceLocation) !void {
    std.testing.expectEqual(expected, actual) catch |err| {
        std.debug.print("at {s}:{d}\n", .{ at.file, at.line });
        return err;
    };
}
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
        try verify(self.armed == .none, @src());
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
        try verify(!self.observer.closed, @src());
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
        try equalAt(@as(usize, 0), (try self.domain.stats()).attachments, @src());
        try equalAt(@as(usize, 0), (try self.domain.stats()).workspace_reservation, @src());
        try self.domain.close();
        try equalAt(@as(usize, 0), self.hook.live, @src());
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
    host.domain = try Domain.create(app, if (snapshot) host.hook.allocator() else allocator, .{ .driver = soft });
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
    // Windows reports the close at that safe point; AppKit may only once
    // shutdown finishes. Either way on_closed owns the free.
    try app.finishShutdown();
    if (observer.failure) |err| return err;
    try verify(observer.closed, @src());
    try equalAt(@as(u32, 0), gpu.globalResourceCount(), @src());
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
    const domain = try Domain.create(app, allocator, .{ .driver = soft });
    var hook: Hook = .{ .backing = allocator };
    const surface = try Surface.create(domain, hook.allocator(), options);
    var reentry: CloseReentry = .{ .surface = surface, .domain = domain, .app = app };
    hook.context = &reentry;
    hook.callback = CloseReentry.run;
    hook.armed = .free;
    try surface.close();
    try hook.check();
    try equalAt(@as(usize, 0), hook.live, @src());
    try equalAt(@as(usize, 0), (try domain.stats()).attachments, @src());
    try equalAt(@as(usize, 0), (try domain.stats()).workspace_reservation, @src());
    try app.finishShutdown();
    app.deinit();
    try domain.close();
}
fn budgets(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    const small = try Domain.create(app, allocator, .{ .driver = soft, .texture_bytes = 16 * 1024, .total_bytes = 64 * 1024 });
    var hook: Hook = .{ .backing = allocator };
    try expectError(error.CapacityExceeded, Surface.create(small, hook.allocator(), options));
    try equalAt(@as(usize, 0), hook.calls, @src());
    try equalAt(@as(usize, 0), (try small.stats()).attachments, @src());
    try small.close();
    const domain = try Domain.create(app, hook.allocator(), .{ .driver = soft, .texture_bytes = 1024 });
    const surface = try Surface.create(domain, allocator, options); // 3*256 bytes
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try surface.render(&buffer);
    const texture = try surface.snapshot(); // last 256 bytes
    const calls = hook.calls;
    try expectError(error.TextureBudgetExceeded, surface.snapshot());
    try equalAt(calls, hook.calls, @src());
    try texture.close();
    const again = try surface.snapshot();
    try again.close();
    try surface.close();
    try domain.close();
    try equalAt(@as(usize, 0), hook.live, @src());
}
fn allocationPass(allocator: std.mem.Allocator, app: *z.App) !void {
    const domain = try Domain.create(app, allocator, .{ .driver = soft });
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
    const domain = try Domain.create(app, allocator, .{ .driver = soft });
    defer domain.close() catch unreachable;
    var low = options;
    low.render_work = 1;
    const limited = try Surface.create(domain, allocator, low);
    var buffer: ui.commands.Buffer = .{};
    defer buffer.reset();
    try expectError(error.RenderWorkExceeded, limited.render(&buffer));
    try equalAt(@as(u64, 0), (try limited.stats()).layers.committed_frames, @src());
    try limited.close();
    var hook: Hook = .{ .backing = allocator };
    const surface = try Surface.create(domain, hook.allocator(), options);
    const allocations = hook.calls;
    const native_creations = (try surface.stats()).layers.native_creations;
    for (0..16) |_| try surface.render(&buffer);
    try equalAt(allocations, hook.calls, @src());
    try equalAt(native_creations, (try surface.stats()).layers.native_creations, @src());
    var worker: Worker = .{ .surface = surface, .domain = domain, .allocator = allocator };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    var snapshots: [ui.gpu_resources.capacity]*ui.gpu_resources.Texture = undefined;
    for (&snapshots) |*snapshot| snapshot.* = try surface.snapshot();
    const before = try domain.stats();
    try expectError(error.Full, surface.snapshot());
    try equalAt(before.bitmap_creations, (try domain.stats()).bitmap_creations, @src());
    try equalAt(@as(usize, ui.gpu_resources.capacity), (try domain.stats()).textures, @src());
    try buffer.texture(.{ .x = 0, .y = 0, .width = 8, .height = 8 }, try snapshots[0].view(), .{});
    try expectError(error.ResourceInUse, snapshots[0].close());
    try surface.render(&buffer);
    buffer.reset();
    try surface.close();
    try equalAt(@as(usize, 0), hook.live, @src());
    try equalAt(@as(usize, 0), (try domain.stats()).workspace_reservation, @src());
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
    try equalAt(@as(u32, 0), gpu.globalResourceCount(), @src());
}
