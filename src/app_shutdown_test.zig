const std = @import("std");
const z = @import("root.zig");
const c = z.composition;

test "quit inside dispatch defers accepted window destroys until stop ownership settles" {
    const Probe = struct {
        const Event = enum { quit, accepted, failed_stop, stop, detach, closed };
        app: *z.App,
        window: z.Window = undefined,
        events: [6]Event = undefined,
        count: usize = 0,
        fail_stop: bool,
        attempts: usize = 0,
        fn record(self: *@This(), value: Event) void {
            self.events[self.count] = value;
            self.count += 1;
        }
        fn quit(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.app.post(.{ .context = self, .call = accepted }) catch unreachable;
            self.record(.quit);
            self.app.quit();
        }
        fn accepted(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.app.phase == .stopping);
            self.record(.accepted);
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
        }
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            if (self.fail_stop and self.attempts == 1) {
                self.record(.failed_stop);
                return error.NativeReleaseFailed;
            }
            self.record(.stop);
        }
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.record(.detach);
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.record(.closed);
        }
    };
    for ([_]bool{ false, true }) |fail| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const app = try z.App.init(failing.allocator());
        defer app.deinit();
        var probe: Probe = .{ .app = app, .fail_stop = fail };
        probe.window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.closed } });
        try probe.window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        var node: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
        _ = try app.registerStop(&node);
        try app.post(.{ .context = &probe, .call = Probe.quit });
        failing.fail_index = failing.alloc_index;
        const allocations = failing.alloc_index;
        if (fail) {
            try std.testing.expectError(error.NativeReleaseFailed, app.run());
            try std.testing.expectEqualSlices(Probe.Event, &.{ .quit, .accepted, .failed_stop }, probe.events[0..probe.count]);
            const record = app.windows.get(probe.window.key) orelse return error.NativeRecordReleasedBeforeStop;
            try std.testing.expect(record.native.alive and app.resourceStats().allocated_records == 1);
            try app.finishShutdown();
            try std.testing.expectEqualSlices(Probe.Event, &.{ .quit, .accepted, .failed_stop, .stop, .detach, .closed }, probe.events[0..probe.count]);
        } else {
            try app.run();
            try std.testing.expectEqualSlices(Probe.Event, &.{ .quit, .accepted, .stop, .detach, .closed }, probe.events[0..probe.count]);
        }
        try app.finishShutdown();
        try std.testing.expectEqual(allocations, failing.alloc_index);
        try std.testing.expect(app.resourceStats().allocated_records == 0 and app.resourceStats().stop_participants == 0);
    }
}

test "App stop follows all accepted posts and precedes ordinary window teardown without allocation" {
    const Probe = struct {
        app: *z.App,
        window: z.Window = undefined,
        posts: usize = 0,
        stops: usize = 0,
        detached: bool = false,
        closed: bool = false,
        node: z.StopParticipant = undefined,
        fn posted(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.stops == 0 and !self.detached);
            self.posts += 1;
        }
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectEqual(@as(usize, 256), self.posts);
            try std.testing.expect(!self.detached and self.window.nativeHandle() != null);
            try std.testing.expect(self.app.beginCallback() == null);
            try std.testing.expectError(error.Closed, self.app.registerStop(&self.node));
            try std.testing.expectError(error.Busy, self.app.finishShutdown());
            try std.testing.expectError(error.Closed, self.app.post(.{ .context = self, .call = posted }));
            self.stops += 1;
        }
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.stops == 1 and !self.detached);
            self.detached = true;
        }
        fn onClosed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.detached and !self.closed);
            self.closed = true;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    try std.testing.expectError(error.NotStopping, app.finishShutdown());
    var probe: Probe = .{ .app = app };
    probe.node = .{ .context = &probe, .stop = Probe.stop };
    probe.window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = Probe.onClosed } });
    try probe.window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    _ = try app.registerStop(&probe.node);
    failing.fail_index = failing.alloc_index;
    const allocations = failing.alloc_index;
    for (0..256) |_| try app.post(.{ .context = &probe, .call = Probe.posted });
    try std.testing.expectError(error.Full, app.post(.{ .context = &probe, .call = Probe.posted }));
    app.quit();
    try app.finishShutdown();
    try app.finishShutdown();
    try std.testing.expect(probe.closed and app.phase == .stopped);
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expectEqual(@as(usize, 1), probe.stops);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().stop_participants);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "App scope pins activity without a window and defers callback close until a safe point" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const scope = app.beginCallback().?;
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    try std.testing.expectError(error.AlreadyRunning, app.run());
    const window = try app.createWindow(.{});
    try std.testing.expect((try window.destroy()) == .deferred);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), app.resourceStats().allocated_records);
    app.quit();
    try std.testing.expect(app.beginCallback() == null);
    try std.testing.expectError(error.Busy, app.finishShutdown());
    scope.end();
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "teardown scope preserves App lifetime through stopped and deinit without reopening ingress" {
    const Probe = struct {
        app: *z.App,
        calls: usize = 0,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const scope = self.app.beginTeardownCallback();
            defer scope.end();
            try std.testing.expect(self.app.phase == .stopping and self.app.destroying);
            try std.testing.expect(self.app.beginCallback() == null);
            try std.testing.expectError(error.Closed, self.app.createWindow(.{}));
            try std.testing.expectError(error.Busy, self.app.finishShutdown());
            self.calls += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    app.quit();
    try app.finishShutdown();
    const scope = app.beginTeardownCallback();
    try std.testing.expect(app.beginCallback() == null);
    try std.testing.expectError(error.Closed, app.createWindow(.{}));
    try std.testing.expectError(error.Busy, app.finishShutdown());
    scope.end();
    app.deinit();

    const during_deinit = try z.App.init(std.testing.allocator);
    var probe: Probe = .{ .app = during_deinit };
    var node: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
    _ = try during_deinit.registerStop(&node);
    during_deinit.deinit();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "failed App stops retain native lifetime and retry without replaying logical completion" {
    const Probe = struct {
        app: *z.App,
        fail: bool = true,
        attempts: usize = 0,
        logical: usize = 0,
        completed: bool = false,
        good_stops: usize = 0,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.attempts += 1;
            if (!self.completed) {
                self.completed = true;
                self.logical += 1;
            }
            if (self.fail) return error.NativeReleaseFailed;
        }
        fn good(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.good_stops += 1;
        }
    };
    var recorder: z.diagnostics.Recorder(4) = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = recorder.sink(), .stop_capacity = 2 });
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    var good: z.StopParticipant = .{ .context = &probe, .stop = Probe.good };
    var failing: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
    _ = try app.registerStop(&good);
    const token = try app.registerStop(&failing);
    const window = try app.createWindow(.{});
    // The accepted quit is executed by the ordinary run loop.
    try app.post(.{ .context = app, .call = struct {
        fn quit(ptr: *anyopaque) void {
            const target: *z.App = @ptrCast(@alignCast(ptr));
            target.quit();
        }
    }.quit });
    try std.testing.expectError(error.NativeReleaseFailed, app.run());
    try std.testing.expect(app.phase == .stopping and window.nativeHandle() != null);
    try std.testing.expectError(error.StopInProgress, app.cancelStop(token));
    try std.testing.expectEqual(@as(usize, 1), probe.good_stops);
    try std.testing.expectEqual(@as(usize, 1), app.resourceStats().stop_participants);
    var records: [4]z.diagnostics.Diagnostic = undefined;
    const captured = recorder.snapshot(&records);
    try std.testing.expectEqual(@as(usize, 1), captured.count);
    try std.testing.expect(records[0].operation == .app_stop and records[0].code == null);
    try std.testing.expectError(error.NativeReleaseFailed, app.finishShutdown());
    probe.fail = false;
    try app.finishShutdown();
    try std.testing.expectEqual(@as(usize, 3), probe.attempts);
    try std.testing.expectEqual(@as(usize, 1), probe.logical);
    try std.testing.expectEqual(@as(usize, 1), probe.good_stops);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "App stop nodes do not keep a zero-window application running and sealed work can cancel ownership" {
    const Probe = struct {
        app: *z.App,
        token: z.StopToken = undefined,
        calls: usize = 0,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
        fn cancel(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.app.cancelStop(self.token) catch unreachable);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    var node: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
    probe.token = try app.registerStop(&node);
    try app.post(.{ .context = &probe, .call = Probe.cancel });
    try app.run();
    try std.testing.expect(app.phase == .stopped);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().registry_slots);
}

test "stopped App dispatches late mandatory cleanup without reopening business or replaying Stop" {
    const Probe = struct {
        app: *z.App,
        next: *z.Cleanup = undefined,
        stops: usize = 0,
        releases: usize = 0,
        fn stop(ptr: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stops += 1;
        }
        fn first(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert((self.app.phase == .stopping or self.app.phase == .stopped) and self.releases == 0);
            self.releases += 1;
            self.app.deferCleanup(self.next);
        }
        fn second(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert((self.app.phase == .stopping or self.app.phase == .stopped) and self.releases == 1);
            self.releases += 1;
        }
    };
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(fault.allocator());
    defer app.deinit();
    var probe: Probe = .{ .app = app };
    var node: z.StopParticipant = .{ .context = &probe, .stop = Probe.stop };
    _ = try app.registerStop(&node);
    try app.run();
    try std.testing.expect(app.phase == .stopped and probe.stops == 1);
    var late: z.Cleanup = .{ .task = .{ .context = &probe, .call = Probe.first } };
    var next: z.Cleanup = .{ .task = .{ .context = &probe, .call = Probe.second } };
    probe.next = &next;
    const allocations = fault.alloc_index;
    const scope = app.beginTeardownCallback();
    app.deferCleanup(&late);
    scope.end();
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    try std.testing.expectError(error.Closed, app.post(.{ .context = &probe, .call = Probe.second }));
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 2), probe.releases);
    try std.testing.expect(!late.queued and !next.queued and app.cleanup_head == null and probe.stops == 1);
    try app.dispatch();
    try app.finishShutdown();
    try std.testing.expect(probe.releases == 2 and probe.stops == 1 and app.phase == .stopped);
    try std.testing.expectEqual(allocations, fault.alloc_index);
}

test "provisional composition participant gets early native notification once and owns failed rollback" {
    const Probe = struct {
        app: *z.App,
        fail: bool,
        parents: usize = 0,
        detaches: usize = 0,
        inside: bool = false,
        fn attach(ptr: *anyopaque, region: c.Region) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const window = (try region.snapshot()).window;
            const record = self.app.windows.get(window.key).?;
            const native_scope = record.enter();
            defer native_scope.end();
            self.inside = true;
            defer self.inside = false;
            record.nativeDestroying();
            record.native.alive = false;
            record.nativeDestroyed();
            try std.testing.expectEqual(@as(usize, 1), self.parents);
            try std.testing.expectEqual(@as(usize, 0), self.detaches);
            if (self.fail) return error.AttachCandidateFailed;
        }
        fn parent(ptr: *anyopaque, region: c.Region) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.inside);
            std.testing.expectError(error.Closed, region.snapshot()) catch unreachable;
            self.parents += 1;
        }
        fn update(_: *anyopaque, _: c.Region, _: c.Viewport) !void {}
        fn detach(ptr: *anyopaque, _: c.Region) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(!self.inside);
            self.detaches += 1;
        }
    };
    for ([_]bool{ false, true }) |fail| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        const owner = try c.Owner.create(std.testing.allocator, window, .{});
        defer owner.close() catch unreachable;
        const region = try owner.reserve(.{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 } });
        var probe: Probe = .{ .app = app, .fail = fail };
        const participant: c.Participant = .{ .context = &probe, .attach = Probe.attach, .update = Probe.update, .detach = Probe.detach, .native_parent_destroying = Probe.parent };
        if (fail) try std.testing.expectError(error.AttachCandidateFailed, region.attach(participant)) else try region.attach(participant);
        try app.dispatch();
        try std.testing.expectEqual(@as(usize, if (fail) 0 else 1), probe.detaches);
        try std.testing.expectEqual(@as(usize, 1), probe.parents);
        try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    }
}
