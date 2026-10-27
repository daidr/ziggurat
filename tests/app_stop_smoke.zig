const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const native = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

const StopProbe = struct {
    app: *z.App,
    posts: usize = 0,
    stops: usize = 0,
    detached: bool = false,
    fn post(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.stops == 0);
        self.posts += 1;
    }
    fn stop(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqual(@as(usize, 256), self.posts);
        try std.testing.expect(!self.detached and self.app.beginCallback() == null);
        self.stops += 1;
    }
    fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
    fn detach(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.stops == 1 and !self.detached);
        self.detached = true;
    }
};

fn stopOrder(allocator: std.mem.Allocator) !void {
    const app = try z.App.init(allocator);
    defer app.deinit();
    var probe: StopProbe = .{ .app = app };
    var node: z.StopParticipant = .{ .context = &probe, .stop = StopProbe.stop };
    _ = try app.registerStop(&node);
    const window = try app.createWindow(.{});
    try window.setContent(.{ .context = &probe, .event = StopProbe.event, .detach = StopProbe.detach });
    for (0..256) |_| try app.post(.{ .context = &probe, .call = StopProbe.post });
    app.quit();
    try app.finishShutdown();
    try std.testing.expect(probe.detached);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
}

fn noWindow(allocator: std.mem.Allocator) !void {
    const Resource = struct {
        allocator: std.mem.Allocator,
        released: *usize,
        node: z.StopParticipant = undefined,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const storage = self.allocator;
            self.released.* += 1;
            storage.destroy(self);
        }
    };
    const app = try z.App.init(allocator);
    defer app.deinit();
    var released: usize = 0;
    const resource = try allocator.create(Resource);
    resource.* = .{ .allocator = allocator, .released = &released };
    resource.node = .{ .context = resource, .stop = Resource.stop };
    _ = try app.registerStop(&resource.node);
    try app.run();
    try std.testing.expect(app.phase == .stopped and released == 1);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().registry_slots);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
}

fn nativeEvacuation(allocator: std.mem.Allocator) !void {
    if (comptime builtin.os.tag != .windows) return;
    const Probe = struct {
        app: *z.App,
        window: z.Window,
        host: native.HWND,
        parking: native.HWND,
        child: native.HWND = null,
        owner: ?*z.composition.Owner,
        parents: usize = 0,
        detached: usize = 0,
        closed: bool = false,
        destroy_in_attach: bool,
        failed: bool = false,
        fn attach(ptr: *anyopaque, _: z.composition.Region) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.child = native.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, native.WS_CHILD, 0, 0, 40, 40, self.host, null, native.GetModuleHandleW(null), null);
            if (self.child == null) return error.ChildCreateFailed;
            if (self.destroy_in_attach) {
                if (native.DestroyWindow(self.host) == 0) return error.HostDestroyFailed;
                try std.testing.expect(self.parents == 1 and self.detached == 0 and !self.closed);
            }
        }
        fn parent(ptr: *anyopaque, _: z.composition.Region) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // This callback intentionally performs only bounded Win32 work.
            self.parents += 1;
            if (native.IsWindow(self.child) == 0 or native.GetParent(self.child) != self.host) {
                self.failed = true;
                return;
            }
            native.SetLastError(0);
            const old = native.SetParent(self.child, self.parking);
            if (old == null and native.GetLastError() != 0) self.failed = true;
        }
        fn update(_: *anyopaque, _: z.composition.Region, _: z.composition.Viewport) !void {}
        fn detach(ptr: *anyopaque, _: z.composition.Region) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detached += 1;
            std.debug.assert(self.parents == 1 and native.IsWindow(self.child) != 0);
        }
        fn onClosed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.detached == 1 and !self.closed);
            self.closed = true;
            self.owner.?.close() catch unreachable;
            self.owner = null;
        }
    };
    for ([_]bool{ false, true }) |during_attach| {
        const parking = native.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, 0, 0, 0, 20, 20, null, null, native.GetModuleHandleW(null), null);
        if (parking == null) return error.ParkingCreateFailed;
        defer std.debug.assert(native.DestroyWindow(parking) != 0);
        const app = try z.App.init(allocator);
        defer app.deinit();
        var probe: Probe = .{ .app = app, .window = undefined, .host = null, .parking = parking, .owner = null, .destroy_in_attach = during_attach };
        probe.window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.onClosed } });
        probe.host = @ptrCast(probe.window.nativeHandle());
        probe.owner = try z.composition.Owner.create(allocator, probe.window, .{});
        const region = try probe.owner.?.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } });
        try region.attach(.{ .context = &probe, .attach = Probe.attach, .update = Probe.update, .detach = Probe.detach, .native_parent_destroying = Probe.parent });
        if (!during_attach) {
            const scope = region.beginCallback().?;
            try std.testing.expect(try region.remove());
            try std.testing.expect(native.DestroyWindow(probe.host) != 0);
            try std.testing.expect(probe.parents == 1 and probe.detached == 0 and !probe.closed);
            scope.end();
        }
        try app.dispatch();
        try std.testing.expect(!probe.failed and probe.closed and probe.owner == null);
        try std.testing.expectEqual(@as(usize, 1), probe.parents);
        try std.testing.expectEqual(@as(usize, 1), probe.detached);
        try std.testing.expect(native.IsWindow(probe.child) != 0 and native.GetParent(probe.child) == parking);
        try std.testing.expect(native.DestroyWindow(probe.child) != 0);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
}

pub fn main() !void {
    var allocations: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocations.deinit() == .ok);
    try stopOrder(allocations.allocator());
    try noWindow(allocations.allocator());
    try nativeEvacuation(allocations.allocator());
    std.debug.print("App stop: 256 accepted posts before stop/content detach, participants/records=0; native child evacuation={s}\n", .{if (builtin.os.tag == .windows) "passed (provisional and removing regions)" else "Windows only"});
}
