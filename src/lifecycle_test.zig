const std = @import("std");
const z = @import("root.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

test "typed key consumption pins its context and preserves absent consumer and disabled boundaries without allocation" {
    const KeyProbe = struct {
        calls: usize = 0,
        events: usize = 0,
        detached: bool = false,
        closed: bool = false,
        closing: bool = false,
        fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (value == .key_input) self.events += 1;
        }
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detached = true;
        }
        fn notify(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.closed = true;
        }
        fn key(ptr: *anyopaque, window: z.Window, input: z.KeyInput) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            std.debug.assert(input.key == .f24 and input.modifiers.super and input.repeat);
            if (self.closing) {
                std.debug.assert((window.destroy() catch unreachable) == .deferred);
                std.debug.assert(!self.detached and !self.closed);
                return false;
            }
            return true;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    var probe: KeyProbe = .{};
    const window = try app.createWindow(.{ .on_closed = .{ .context = &probe, .notify = KeyProbe.notify } });
    try window.setContent(.{ .context = &probe, .event = KeyProbe.event, .detach = KeyProbe.detach, .key_input = KeyProbe.key });
    const record = app.windows.get(window.key).?;
    failing.fail_index = failing.alloc_index;
    const input: z.KeyInput = .{ .key = .f24, .modifiers = .{ .super = true }, .repeat = true };
    try expect(record.keyInput(input));
    try equal(1, probe.calls);
    try equal(0, probe.events);
    try window.perform(.disable);
    try expect(record.keyInput(input));
    try equal(1, probe.calls);
    try window.perform(.enable);
    probe.closing = true;
    try expect(record.keyInput(input));
    try equal(2, probe.calls);
    try expect(!probe.detached and !probe.closed);
    try app.dispatch();
    try expect(probe.detached and probe.closed);
    try equal(0, app.resourceStats().allocated_records);

    failing.fail_index = std.math.maxInt(usize);
    const legacy = try app.createWindow(.{});
    try legacy.setContent(.{ .context = &probe, .event = KeyProbe.event, .detach = KeyProbe.detach });
    try expect(!app.windows.get(legacy.key).?.keyInput(input));
    try equal(0, probe.events);
    _ = try legacy.destroy();
}

test "owned windows reject stale foreign owners and failed creation leaves no relationship" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{});
    try std.testing.expectError(error.OwnerRequired, app.createWindow(.{ .modal = true }));
    const other_app = try z.App.init(std.testing.allocator);
    defer other_app.deinit();
    try std.testing.expectError(error.ForeignApp, other_app.createWindow(.{ .owner = owner }));
    app.native.fail_create = true;
    try std.testing.expectError(error.CreateWindowFailed, app.createWindow(.{ .owner = owner, .modal = true }));
    try app.dispatch();
    try equal(1, app.resourceStats().allocated_records);
    try equal(0, (try owner.relationship()).modal_children);
    _ = try owner.destroy();
    const replacement = try app.createWindow(.{});
    try std.testing.expectError(error.Closed, app.createWindow(.{ .owner = owner }));
    _ = try replacement.destroy();
}

test "modal policy crosses modeless layers and restores latest sibling branch and enable intent" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{});
    const branch_a = try app.createWindow(.{ .owner = owner });
    const branch_b = try app.createWindow(.{ .owner = owner });
    const modal_a = try app.createWindow(.{ .owner = branch_a, .modal = true });
    const modal_b = try app.createWindow(.{ .owner = branch_b, .modal = true });
    const unrelated = try app.createWindow(.{});
    try expect((try owner.state()).enabled);
    try modal_a.perform(.show);
    try expect(!(try owner.state()).enabled and !(try branch_a.state()).enabled and !(try branch_b.state()).enabled);
    try expect((try modal_a.state()).enabled and (try unrelated.state()).enabled);
    try equal(modal_a.key, (try owner.focusTarget()).key);
    try std.testing.expectError(error.ModalBlocked, owner.perform(.focus));
    try modal_b.perform(.show);
    try equal(1, (try branch_a.relationship()).modal_children);
    try equal(1, (try branch_b.relationship()).modal_children);
    try expect(!(try modal_a.state()).enabled and (try modal_b.state()).enabled);
    try equal(modal_b.key, (try branch_a.focusTarget()).key);
    try owner.perform(.disable);
    try modal_b.perform(.hide);
    try expect((try modal_a.state()).enabled and !(try owner.state()).enabled);
    try modal_a.perform(.hide);
    try expect(!(try owner.state()).enabled and !(try owner.state()).enabled_requested);
    try expect((try branch_a.state()).enabled and (try branch_b.state()).enabled);
    try owner.perform(.enable);
    try expect((try owner.state()).enabled);
    _ = try owner.destroy();
    try expect(modal_a.isClosed() and modal_b.isClosed() and branch_a.isClosed() and branch_b.isClosed());
    _ = try unrelated.destroy();
    try equal(0, app.resourceStats().allocated_records);
}

test "nested modal counts and failed show restore the previous active branch" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{});
    const first = try app.createWindow(.{ .owner = owner, .modal = true });
    const sibling = try app.createWindow(.{ .owner = owner, .modal = true });
    const nested = try app.createWindow(.{ .owner = first, .modal = true });
    try first.perform(.show);
    try nested.perform(.show);
    try equal(1, (try owner.relationship()).modal_children);
    try equal(1, (try first.relationship()).modal_children);
    try expect(!(try first.state()).enabled and (try nested.state()).enabled);
    app.native.fail_show = true;
    try std.testing.expectError(error.WindowUpdateFailed, sibling.perform(.show));
    try expect(!(try sibling.relationship()).modal_active);
    try equal(nested.key, (try owner.focusTarget()).key);
    try equal(1, (try owner.relationship()).modal_children);
    try sibling.perform(.show);
    try equal(2, (try owner.relationship()).modal_children);
    try expect(!(try nested.state()).enabled and (try sibling.state()).enabled);
    _ = try sibling.destroy();
    try equal(1, (try owner.relationship()).modal_children);
    try equal(nested.key, (try owner.focusTarget()).key);
    _ = try nested.destroy();
    try expect((try first.state()).enabled and !(try owner.state()).enabled);
    _ = try first.destroy();
    try expect((try owner.state()).enabled);
    _ = try owner.destroy();
}

test "destroy failure restores visible modal order and reopening ancestors does not revive closed children" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{});
    const first = try app.createWindow(.{ .owner = owner, .modal = true });
    const second = try app.createWindow(.{ .owner = owner, .modal = true });
    try first.perform(.show);
    try second.perform(.show);
    app.native.fail_destroy = true;
    try std.testing.expectError(error.DestroyWindowFailed, first.destroy());
    try expect(!first.isClosed() and (try first.relationship()).modal_active);
    try equal(2, (try owner.relationship()).modal_children);
    try equal(second.key, (try owner.focusTarget()).key);
    try expect(!(try first.state()).enabled and (try second.state()).enabled);
    _ = try second.destroy();
    const child = try app.createWindow(.{ .owner = first, .modal = true });
    try child.perform(.show);
    app.native.destroy_countdown = 1;
    try std.testing.expectError(error.DestroyWindowFailed, owner.destroy());
    try expect(child.isClosed() and !first.isClosed() and !owner.isClosed());
    try expect((try first.relationship()).modal_active);
    try equal(0, (try first.relationship()).modal_children);
    try equal(1, (try owner.relationship()).modal_children);
    try expect(!(try owner.state()).enabled and (try first.state()).enabled);
    _ = try owner.destroy();
    try equal(0, app.resourceStats().allocated_records);
}

test "owner close preflights descendant vetoes and final notifications are children first" {
    const Node = struct {
        id: u8,
        order: *[3]u8,
        length: *usize,
        cancel: bool = false,
        requests: usize = 0,
        reason: ?z.CloseReason = null,
        fn request(ptr: *anyopaque, window: z.Window, reason: z.CloseReason) z.CloseDecision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.requests += 1;
            self.reason = reason;
            std.testing.expectEqual(z.CloseResult.in_progress, window.requestClose() catch unreachable) catch unreachable;
            std.testing.expectError(error.CloseInProgress, window.app.createWindow(.{})) catch unreachable;
            return if (self.cancel) .cancel else .allow;
        }
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.order[self.length.*] = self.id;
            self.length.* += 1;
        }
        fn options(self: *@This(), owner: ?z.Window) z.WindowOptions {
            return .{ .owner = owner, .on_close = .{ .context = self, .request = request }, .on_closed = .{ .context = self, .notify = closed } };
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var order: [3]u8 = undefined;
    var length: usize = 0;
    var root_node: Node = .{ .id = 0, .order = &order, .length = &length };
    var child_node: Node = .{ .id = 1, .order = &order, .length = &length };
    var grandchild_node: Node = .{ .id = 2, .order = &order, .length = &length, .cancel = true };
    const owner = try app.createWindow(root_node.options(null));
    const child = try app.createWindow(child_node.options(owner));
    const grandchild = try app.createWindow(grandchild_node.options(child));
    try equal(z.CloseResult.cancelled, try owner.requestClose());
    try expect(!owner.isClosed() and !child.isClosed() and !grandchild.isClosed());
    try equal(0, length);
    try equal(z.CloseReason.application, root_node.reason.?);
    try equal(z.CloseReason.owner, grandchild_node.reason.?);
    grandchild_node.cancel = false;
    try equal(z.CloseResult.closed, try owner.requestClose());
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 0 }, &order);
    try equal(0, app.resourceStats().allocated_records);
}

test "raw owner destruction retains the relationship until child notifications finish" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const owner = try app.createWindow(.{});
    const child = try app.createWindow(.{ .owner = owner, .modal = true });
    const grandchild = try app.createWindow(.{ .owner = child });
    try child.perform(.show);
    const record: *z.WindowRecord = @ptrCast(@alignCast(owner.nativeHandle().?));
    try @import("platform/testing.zig").destroy(record);
    try expect(owner.isClosed() and child.isClosed() and grandchild.isClosed());
    try app.dispatch();
    try equal(0, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().pending_destroys);
}

test "deep owned trees close iteratively without historical scans or per-close allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    const root = try app.createWindow(.{});
    var previous = root;
    for (0..1000) |_| previous = try app.createWindow(.{ .owner = previous });
    failing.fail_index = failing.alloc_index;
    try equal(z.CloseResult.closed, try root.destroy());
    try expect(previous.isClosed());
    try equal(0, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().live_windows);
}

test "client bounds validate before changing geometry and expose per-window capabilities" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .width = 400, .height = 300, .min_width = 200, .min_height = 100 });
    const record: *z.WindowRecord = @ptrCast(@alignCast(window.nativeHandle().?));
    const initial = try window.clientBounds();
    try equal(400, initial.width);
    try equal(300, initial.height);
    try std.testing.expectError(error.InvalidSize, window.setClientBounds(.{ .position = .{ .x = 99, .y = 77 }, .width = 199, .height = 300 }));
    try std.testing.expectError(error.InvalidSize, window.resize(0, 300));
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    record.native.caps.client_position = false;
    try expect(!(try window.capabilities()).client_position);
    try expect((try window.clientBounds()).position == null);
    try std.testing.expectError(error.UnsupportedCapability, window.setClientBounds(.{ .position = .{ .x = 99, .y = 77 }, .width = 600, .height = 500 }));
    try equal(400, (try window.clientBounds()).width);
    try window.setClientBounds(.{ .width = 600, .height = 500 });
    try equal(600, (try window.clientBounds()).width);
    record.native.caps.client_position = true;
    try std.testing.expectEqualDeep(initial.position, (try window.clientBounds()).position);
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, window.clientBounds());
    try std.testing.expectError(error.Closed, window.capabilities());
    try std.testing.expectError(error.Closed, window.setFullscreen(true));
    try std.testing.expectError(error.Closed, window.setAlwaysOnTop(true));
}

test "fullscreen preserves normal placement and independent topmost and enable policy" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    try window.setClientBounds(.{ .position = .{ .x = -300, .y = 180 }, .width = 601, .height = 399 });
    const initial = try window.clientBounds();
    try window.perform(.maximize);
    try window.setFullscreen(true);
    try window.setFullscreen(true);
    try expect((try window.state()).fullscreen and (try window.state()).fullscreen_requested);
    try std.testing.expectError(error.InvalidWindowState, window.resize(800, 600));
    try std.testing.expectError(error.InvalidWindowState, window.setClientBounds(initial));
    try std.testing.expectError(error.InvalidWindowState, window.perform(.restore));
    try window.setAlwaysOnTop(true);
    try window.perform(.disable);
    try window.setFullscreen(false);
    try window.setFullscreen(false);
    const restored = try window.state();
    try expect(!restored.fullscreen and !restored.fullscreen_requested and restored.maximized);
    try expect(restored.always_on_top and restored.always_on_top_requested and !restored.enabled and !restored.visible);
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    try window.perform(.restore);
    try window.setClientBounds(.{ .width = 400, .height = 300 });
    try std.testing.expectEqualDeep(initial.position, (try window.clientBounds()).position);
    try window.setAlwaysOnTop(false);
    _ = try window.destroy();
}

test "failed geometry update preserves prior state and native diagnostic without allocation" {
    var recorder: z.diagnostics.Recorder(8) = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = recorder.sink() });
    defer app.deinit();
    const window = try app.createWindow(.{});
    const initial = try window.clientBounds();
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setFullscreen(true));
    try expect(!(try window.state()).fullscreen);
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setClientBounds(.{ .width = 800, .height = 600 }));
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    try window.setFullscreen(true);
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setFullscreen(false));
    try expect((try window.state()).fullscreen);
    try window.setFullscreen(false);
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    var buffer: [8]z.diagnostics.Diagnostic = undefined;
    const snapshot = recorder.snapshot(&buffer);
    try equal(3, snapshot.count);
    for (buffer[0..snapshot.count]) |diagnostic| {
        try equal(z.diagnostics.Operation.window_update, diagnostic.operation);
        try equal(z.diagnostics.Domain.win32, diagnostic.domain);
        try equal(@as(?u32, 5), diagnostic.code);
        try equal(error.WindowUpdateFailed, diagnostic.err.?);
        try std.testing.expectEqualDeep(window.diagnosticId(), diagnostic.window.?);
    }
    _ = try window.destroy();
}

test "geometry callbacks reject recursive updates and defer close until their outer scope ends" {
    const Reentrant = struct {
        callbacks: usize = 0,
        detaches: usize = 0,
        close: bool = false,
        fn event(ptr: *anyopaque, window: z.Window, event_value: z.Event) void {
            if (event_value != .resize) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.callbacks += 1;
            std.testing.expectError(error.Busy, window.resize(500, 400)) catch unreachable;
            std.testing.expectError(error.Busy, window.setFullscreen(true)) catch unreachable;
            std.testing.expectError(error.Busy, window.setAlwaysOnTop(true)) catch unreachable;
            std.testing.expectError(error.Busy, window.perform(.maximize)) catch unreachable;
            _ = window.clientBounds() catch unreachable;
            if (self.close) {
                std.testing.expectEqual(z.CloseResult.deferred, window.destroy() catch unreachable) catch unreachable;
                std.debug.assert(self.detaches == 0);
            }
        }
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detaches += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var probe: Reentrant = .{};
    try window.setContent(.{ .context = &probe, .event = Reentrant.event, .detach = Reentrant.detach });
    try window.resize(600, 400);
    try window.setFullscreen(true);
    try window.setFullscreen(false);
    try equal(3, probe.callbacks);
    probe.close = true;
    try window.resize(620, 420);
    try equal(0, probe.detaches);
    try equal(1, app.resourceStats().pending_destroys);
    try app.dispatch();
    try equal(1, probe.detaches);
    try equal(0, app.resourceStats().allocated_records);
}

test "window state notifications are deduplicated, pinned and do not allocate on updates" {
    const StateProbe = struct {
        notifications: usize = 0,
        close: bool = false,
        detached: bool = false,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            if (value != .window_state) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.notifications += 1;
            std.testing.expectEqualDeep(value.window_state, window.state() catch unreachable) catch unreachable;
            std.testing.expectError(error.Busy, window.setFullscreen(false)) catch unreachable;
            if (self.close) {
                _ = window.destroy() catch unreachable;
                std.debug.assert(!self.detached);
            }
        }
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detached = true;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failing.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{});
    var probe: StateProbe = .{};
    try window.setContent(.{ .context = &probe, .event = StateProbe.event, .detach = StateProbe.detach });
    failing.fail_index = failing.alloc_index;
    try window.setFullscreen(true);
    try window.setFullscreen(true);
    try equal(1, probe.notifications);
    try window.setAlwaysOnTop(true);
    try window.setAlwaysOnTop(true);
    try equal(2, probe.notifications);
    try window.setFullscreen(false);
    try window.setClientBounds(.{ .width = 600, .height = 400 });
    _ = try window.clientBounds();
    _ = try window.capabilities();
    try equal(3, probe.notifications);
    probe.close = true;
    try window.setAlwaysOnTop(false);
    try equal(4, probe.notifications);
    try expect(window.isClosed() and !probe.detached);
    try app.dispatch();
    try expect(probe.detached);
    try equal(0, app.resourceStats().allocated_records);
}

test "rollback publishes the final state and preserves failure code across reentrant callbacks" {
    const RollbackProbe = struct {
        states: [2]bool = undefined,
        count: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            if (value != .window_state) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.count < self.states.len);
            self.states[self.count] = value.window_state.fullscreen;
            self.count += 1;
            std.testing.expectEqualDeep(value.window_state, window.state() catch unreachable) catch unreachable;
            // A successful nested native call clears the App's transient code.
            // The failed outer operation must already own its diagnostic value.
            if (!value.window_state.fullscreen) window.setTitle("Rollback complete") catch unreachable;
        }
        fn detach(_: *anyopaque) void {}
    };
    var recorder: z.diagnostics.Recorder(4) = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = recorder.sink() });
    defer app.deinit();
    const window = try app.createWindow(.{});
    const initial = try window.clientBounds();
    var probe: RollbackProbe = .{};
    try window.setContent(.{ .context = &probe, .event = RollbackProbe.event, .detach = RollbackProbe.detach });
    app.native.fail_fullscreen_after_event = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setFullscreen(true));
    try equal(2, probe.count);
    try expect(probe.states[0] and !probe.states[1]);
    try expect(!(try window.state()).fullscreen);
    try std.testing.expectEqualDeep(initial, try window.clientBounds());
    var buffer: [4]z.diagnostics.Diagnostic = undefined;
    try equal(1, recorder.snapshot(&buffer).count);
    try equal(@as(?u32, 5), buffer[0].code);
    try equal(z.diagnostics.Domain.win32, buffer[0].domain);
    try equal(error.WindowUpdateFailed, buffer[0].err.?);
    _ = try window.destroy();
}

const Probe = struct {
    window: z.Window = undefined,
    detaches: usize = 0,
    requests: usize = 0,
    cancel: bool = false,
    reason: ?z.CloseReason = null,
    close_from_event: bool = false,
    other: ?z.Window = null,
    replacement: ?z.Window = null,
    replace_on_detach: bool = false,
    fn event(ptr: *anyopaque, window: z.Window, _: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (self.close_from_event) {
            std.debug.assert((window.destroy() catch unreachable) == .deferred);
            std.debug.assert(self.detaches == 0);
            std.debug.assert(window.nativeHandle() == null);
        }
    }
    fn detach(ptr: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.window.isClosed());
        self.detaches += 1;
        if (self.other) |other| _ = other.destroy() catch unreachable;
        if (self.replace_on_detach) self.replacement = self.window.app.createWindow(.{}) catch unreachable;
    }
    fn request(ptr: *anyopaque, window: z.Window, reason: z.CloseReason) z.CloseDecision {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        self.reason = reason;
        std.debug.assert((window.requestClose() catch unreachable) == .in_progress);
        return if (self.cancel) .cancel else .allow;
    }
    fn content(self: *Probe) z.Content {
        return .{ .context = self, .event = event, .detach = detach };
    }
    fn handler(self: *Probe) z.CloseHandler {
        return .{ .context = self, .request = request };
    }
};

test "closed handle stays invalid across reuse; native records are immediately reclaimed" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    const window = try app.createWindow(.{});
    probe.window = window;
    try window.setContent(probe.content());
    try std.testing.expectError(error.ContentAlreadyAttached, window.setContent(probe.content()));
    try equal(z.CloseResult.closed, try window.destroy());
    try equal(z.CloseResult.closed, try window.destroy());
    try equal(1, probe.detaches);
    try equal(0, app.resourceStats().allocated_records);
    for (0..10000) |_| {
        const fresh = try app.createWindow(.{});
        try expect(window.isClosed());
        try expect(window.nativeHandle() == null);
        try std.testing.expectError(error.Closed, window.setContent(probe.content()));
        _ = try window.requestClose();
        try expect(!fresh.isClosed());
        _ = try fresh.destroy();
    }
    try equal(1, app.resourceStats().registry_slots);
    try equal(0, app.resourceStats().allocated_records);
}

test "close cancellation is synchronous, reentrancy is bounded, force bypasses veto" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{ .cancel = true };
    const window = try app.createWindow(.{ .on_close = probe.handler() });
    probe.window = window;
    try window.setContent(probe.content());
    try equal(z.CloseResult.cancelled, try window.requestClose());
    try equal(1, probe.requests);
    try equal(@as(?z.CloseReason, .application), probe.reason);
    try expect(!window.isClosed());
    try equal(0, probe.detaches);
    _ = try window.destroy();
    try equal(1, probe.requests);
    try equal(1, probe.detaches);
}

test "closing in a callback waits until it unwinds and detaches exactly once" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{ .close_from_event = true };
    const window = try app.createWindow(.{});
    probe.window = window;
    try window.setContent(probe.content());
    app.windows.get(window.key).?.emit(.cancel_input);
    try expect(window.isClosed());
    try equal(0, probe.detaches);
    try equal(1, app.resourceStats().pending_destroys);
    try app.dispatch();
    try equal(1, probe.detaches);
    try equal(0, app.resourceStats().allocated_records);
}

test "destroy work is independent of a full application mailbox" {
    const Noop = struct {
        fn call(_: *anyopaque) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var context: usize = 0;
    const task: z.Task = .{ .context = &context, .call = Noop.call };
    for (0..256) |_| try app.post(task);
    try std.testing.expectError(error.Full, app.post(task));
    const window = try app.createWindow(.{});
    const scope = window.beginCallback().?;
    try equal(z.CloseResult.deferred, try window.destroy());
    try app.dispatch();
    try equal(1, app.resourceStats().allocated_records);
    scope.end();
    try app.dispatch();
    try equal(0, app.resourceStats().allocated_records);
}

test "quit veto keeps every window alive until all handlers agree" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var veto: Probe = .{ .cancel = true };
    var allow: Probe = .{};
    veto.window = try app.createWindow(.{ .on_close = veto.handler() });
    allow.window = try app.createWindow(.{ .on_close = allow.handler() });
    try veto.window.setContent(veto.content());
    try allow.window.setContent(allow.content());
    try equal(z.App.QuitResult.cancelled, app.requestQuit());
    try expect(!allow.window.isClosed() and !veto.window.isClosed());
    try equal(0, allow.detaches);
    try equal(@as(?z.CloseReason, .quit), allow.reason);
    veto.cancel = false;
    try equal(z.App.QuitResult.accepted, app.requestQuit());
    try equal(z.App.Phase.stopping, app.phase);
    try std.testing.expectError(error.Closed, app.createWindow(.{}));
}

test "shutdown drains accepted tasks and handles cascaded detach destruction" {
    const TaskProbe = struct {
        app: *z.App,
        calls: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            std.debug.assert(self.app.phase == .stopping);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    var a: Probe = .{};
    var b: Probe = .{};
    a.window = try app.createWindow(.{});
    b.window = try app.createWindow(.{});
    try a.window.setContent(a.content());
    try b.window.setContent(b.content());
    b.other = a.window;
    var task: TaskProbe = .{ .app = app };
    try app.post(.{ .context = &task, .call = TaskProbe.call });
    const scope = b.window.beginCallback().?;
    _ = try b.window.destroy();
    scope.end();
    app.deinit();
    try equal(1, task.calls);
    try equal(1, a.detaches);
    try equal(1, b.detaches);
}

test "detach can replace a window before the last-window shutdown checkpoint" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{ .replace_on_detach = true };
    probe.window = try app.createWindow(.{});
    try probe.window.setContent(probe.content());
    _ = try probe.window.destroy();
    try expect(probe.replacement != null);
    try equal(1, app.resourceStats().allocated_records);
    try expect(!probe.replacement.?.isClosed());
}

test "App and window creation roll back every allocator failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const app = try z.App.init(allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            _ = try window.destroy();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "native creation and destruction failures preserve registry consistency" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    app.native.fail_create = true;
    try std.testing.expectError(error.CreateWindowFailed, app.createWindow(.{}));
    try equal(0, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().live_windows);
    const window = try app.createWindow(.{});
    app.native.fail_destroy = true;
    try std.testing.expectError(error.DestroyWindowFailed, window.destroy());
    try expect(!window.isClosed());
    try equal(1, app.resourceStats().allocated_records);
    _ = try window.destroy();
    try equal(0, app.resourceStats().allocated_records);
}

test "quit in the first of 256 accepted tasks executes every task once" {
    const Item = struct {
        app: *z.App,
        first: bool,
        calls: usize = 0,
        fn call(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.first) self.app.quit();
            std.debug.assert(self.app.phase == .stopping);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var items: [256]Item = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{ .app = app, .first = index == 0 };
        try app.post(.{ .context = item, .call = Item.call });
    }
    try std.testing.expectError(error.Full, app.post(.{ .context = &items[0], .call = Item.call }));
    try app.run();
    for (items) |item| try equal(1, item.calls);
    try equal(z.App.Phase.stopped, app.phase);
    try expect(window.isClosed());
    try equal(0, app.resourceStats().allocated_records);
    try std.testing.expectError(error.Closed, app.post(.{ .context = &items[0], .call = Item.call }));
    try std.testing.expectError(error.Closed, app.run());
}

test "deferred destruction failure releases its queue pin and permits retry" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: Probe = .{};
    probe.window = try app.createWindow(.{});
    try probe.window.setContent(probe.content());
    const scope = probe.window.beginCallback().?;
    try equal(z.CloseResult.deferred, try probe.window.destroy());
    scope.end();
    app.native.fail_destroy = true;
    try std.testing.expectError(error.DestroyWindowFailed, app.dispatch());
    try expect(!probe.window.isClosed());
    try equal(0, probe.detaches);
    try equal(0, app.resourceStats().pending_destroys);
    try equal(1, app.resourceStats().allocated_records);
    try equal(0, app.windows.get(probe.window.key).?.pins);
    try equal(z.CloseResult.closed, try probe.window.destroy());
    try equal(1, probe.detaches);
    try equal(0, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().live_windows);
}

test "quit preflight survives native removal of the current and next records" {
    const NativeRemoval = struct {
        next: z.Window = undefined,
        requests: usize = 0,
        fn request(ptr: *anyopaque, window: z.Window, reason: z.CloseReason) z.CloseDecision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(reason == .quit);
            self.requests += 1;
            const native = @import("platform/testing.zig");
            native.destroy(window.app.windows.get(window.key).?) catch unreachable;
            native.destroy(self.next.app.windows.get(self.next.key).?) catch unreachable;
            return .allow;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var veto: Probe = .{ .cancel = true };
    var middle: Probe = .{};
    var removed: Probe = .{};
    var removal: NativeRemoval = .{};
    veto.window = try app.createWindow(.{ .on_close = veto.handler() });
    middle.window = try app.createWindow(.{ .on_close = middle.handler() });
    removed.window = try app.createWindow(.{ .on_close = .{ .context = &removal, .request = NativeRemoval.request } });
    removal.next = middle.window;
    try veto.window.setContent(veto.content());
    try middle.window.setContent(middle.content());
    try removed.window.setContent(removed.content());
    try equal(z.App.QuitResult.cancelled, app.requestQuit());
    try equal(1, removal.requests);
    try equal(0, middle.requests);
    try equal(1, veto.requests);
    try expect(removed.window.isClosed() and middle.window.isClosed());
    try expect(!veto.window.isClosed());
    try equal(z.App.Phase.ready, app.phase);
    try equal(0, removed.detaches);
    try equal(0, middle.detaches);
    try equal(2, app.resourceStats().pending_destroys);
    try app.dispatch();
    try equal(1, removed.detaches);
    try equal(1, middle.detaches);
    try equal(1, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().pending_destroys);
}

test "callback close cascades preserve a replacement and invalidate reused slots" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var a: Probe = .{};
    var b: Probe = .{};
    var c: Probe = .{ .replace_on_detach = true };
    a.window = try app.createWindow(.{});
    b.window = try app.createWindow(.{});
    c.window = try app.createWindow(.{});
    a.other = b.window;
    b.other = c.window;
    try a.window.setContent(a.content());
    try b.window.setContent(b.content());
    try c.window.setContent(c.content());
    const scope = a.window.beginCallback().?;
    try equal(z.CloseResult.deferred, try a.window.destroy());
    try equal(0, a.detaches);
    try equal(0, b.detaches);
    try equal(0, c.detaches);
    scope.end();
    try app.dispatch();
    try equal(1, a.detaches);
    try equal(0, b.detaches);
    try equal(1, app.resourceStats().pending_destroys);
    try app.dispatch();
    try equal(1, b.detaches);
    try equal(0, c.detaches);
    try app.dispatch();
    try equal(1, c.detaches);
    const replacement = c.replacement.?;
    try expect(!replacement.isClosed());
    for ([_]z.Window{ a.window, b.window, c.window }) |stale| {
        try expect(stale.isClosed());
        try equal(z.CloseResult.closed, try stale.destroy());
        try expect(stale.nativeHandle() == null);
    }
    try expect(!replacement.isClosed());
    try equal(1, app.resourceStats().allocated_records);
    try equal(3, app.resourceStats().registry_slots);
    _ = try replacement.destroy();
    try equal(0, app.resourceStats().allocated_records);
}

test "running App keeps the replacement created during its final detach" {
    const State = struct {
        app: *z.App,
        window: z.Window = undefined,
        first: z.Window = undefined,
        calls: usize = 0,
        detaches: usize = 0,
        replacement_was_running: bool = false,
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 2) self.replacement_was_running = self.app.phase == .running and !self.window.isClosed() and self.first.isClosed();
            std.debug.assert((self.window.destroy() catch unreachable) == .deferred);
        }
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detaches += 1;
            if (self.detaches == 1) {
                self.window = self.app.createWindow(.{}) catch unreachable;
                self.window.setContent(.{ .context = self, .event = event, .detach = detach }) catch unreachable;
                self.app.post(.{ .context = self, .call = close }) catch unreachable;
            }
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var state: State = .{ .app = app };
    state.window = try app.createWindow(.{});
    state.first = state.window;
    try state.window.setContent(.{ .context = &state, .event = State.event, .detach = State.detach });
    try app.post(.{ .context = &state, .call = State.close });
    try app.run();
    try equal(2, state.calls);
    try equal(2, state.detaches);
    try expect(state.replacement_was_running);
    try expect(state.first.isClosed() and state.window.isClosed());
    try equal(z.App.Phase.stopped, app.phase);
    try equal(0, app.resourceStats().allocated_records);
    try equal(0, app.resourceStats().pending_destroys);
}

test "closed notification follows detach and may release its own context" {
    const Owner = struct {
        allocator: std.mem.Allocator,
        detached: *bool,
        closed: *usize,
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detached.* = true;
        }
        fn notify(ptr: *anyopaque, window: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.detached.*);
            std.debug.assert(window.isClosed() and window.nativeHandle() == null);
            self.closed.* += 1;
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var detached = false;
    var closed: usize = 0;
    const owner = try std.testing.allocator.create(Owner);
    owner.* = .{ .allocator = std.testing.allocator, .detached = &detached, .closed = &closed };
    const window = try app.createWindow(.{ .on_closed = .{ .context = owner, .notify = Owner.notify } });
    try window.setContent(.{ .context = owner, .event = Owner.event, .detach = Owner.detach });
    const scope = window.beginCallback().?;
    _ = try window.destroy();
    try equal(0, closed);
    try expect(!detached);
    scope.end();
    try app.dispatch();
    try equal(1, closed);
    _ = try window.destroy();
    try equal(1, closed);
    try equal(0, app.resourceStats().allocated_records);
}

test "closed notification can replace the final window using its recycled slot" {
    const Owner = struct {
        app: *z.App,
        window: z.Window = undefined,
        notifications: usize = 0,
        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.window.destroy() catch unreachable;
        }
        fn notify(ptr: *anyopaque, closed: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.notifications += 1;
            std.debug.assert(closed.isClosed() and closed.nativeHandle() == null);
            if (self.notifications == 1) {
                self.window = self.app.createWindow(.{ .on_closed = .{ .context = self, .notify = notify } }) catch unreachable;
                std.debug.assert(closed.isClosed() and !self.window.isClosed());
                self.app.post(.{ .context = self, .call = close }) catch unreachable;
            }
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var owner: Owner = .{ .app = app };
    owner.window = try app.createWindow(.{ .on_closed = .{ .context = &owner, .notify = Owner.notify } });
    try app.post(.{ .context = &owner, .call = Owner.close });
    try app.run();
    try equal(2, owner.notifications);
    try equal(1, app.resourceStats().registry_slots);
    try equal(0, app.resourceStats().allocated_records);
}

test "failed native construction never emits a closed notification" {
    const Owner = struct {
        calls: usize = 0,
        fn notify(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var owner: Owner = .{};
    app.native.fail_create = true;
    try std.testing.expectError(error.CreateWindowFailed, app.createWindow(.{ .on_closed = .{ .context = &owner, .notify = Owner.notify } }));
    try equal(0, owner.calls);
    try equal(0, app.resourceStats().allocated_records);
}

test "run waits for a pending closed notification before deciding there are no windows" {
    const Owner = struct {
        app: *z.App,
        window: z.Window = undefined,
        notifications: usize = 0,
        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.window.destroy() catch unreachable;
        }
        fn notify(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.notifications += 1;
            if (self.notifications == 1) {
                self.window = self.app.createWindow(.{ .on_closed = .{ .context = self, .notify = notify } }) catch unreachable;
                self.app.post(.{ .context = self, .call = close }) catch unreachable;
            }
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var owner: Owner = .{ .app = app };
    owner.window = try app.createWindow(.{ .on_closed = .{ .context = &owner, .notify = Owner.notify } });
    const scope = owner.window.beginCallback().?;
    try @import("platform/testing.zig").destroy(app.windows.get(owner.window.key).?);
    scope.end();
    try equal(0, app.resourceStats().live_windows);
    try equal(1, app.resourceStats().pending_destroys);
    try equal(0, owner.notifications);
    try app.run();
    try equal(2, owner.notifications);
    try equal(z.App.Phase.stopped, app.phase);
    try equal(0, app.resourceStats().allocated_records);
}

test "resource cleanup survives a full closed mailbox and can release its own storage" {
    const Owner = struct {
        cleanup: z.Cleanup,
        completed: *usize,
        fn release(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.completed.* += 1;
            std.testing.allocator.destroy(self);
        }
        fn task(ptr: *anyopaque) void {
            const completed: *usize = @ptrCast(@alignCast(ptr));
            completed.* += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    var completed: usize = 0;
    for (0..256) |_| try app.post(.{ .context = &completed, .call = Owner.task });
    try std.testing.expectError(error.Full, app.post(.{ .context = &completed, .call = Owner.task }));
    app.quit();
    try std.testing.expectError(error.Closed, app.post(.{ .context = &completed, .call = Owner.task }));
    for (0..130) |_| {
        const owner = try std.testing.allocator.create(Owner);
        owner.* = .{ .completed = &completed, .cleanup = .{ .task = .{ .context = owner, .call = Owner.release } } };
        app.deferCleanup(&owner.cleanup);
    }
    try std.testing.expectEqual(0, completed);
    app.deinit();
    try std.testing.expectEqual(386, completed);
}

test "resource cleanup waits for callbacks to leave" {
    const Count = struct {
        fn call(ptr: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var completed: usize = 0;
    var cleanup: z.Cleanup = .{ .task = .{ .context = &completed, .call = Count.call } };
    const scope = window.beginCallback().?;
    app.deferCleanup(&cleanup);
    try app.dispatch();
    try std.testing.expectEqual(0, completed);
    scope.end();
    try app.dispatch();
    try std.testing.expectEqual(1, completed);
    try std.testing.expect(!cleanup.queued);
}

test "emitted events reach the content through the native input gate" {
    const EmitProbe = struct {
        texts: usize = 0,
        focus: usize = 0,
        fn event(ptr: *anyopaque, _: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (value) {
                .text_input => self.texts += 1,
                .focus => self.focus += 1,
                else => {},
            }
        }
        fn detach(_: *anyopaque) void {}
        fn emitFromThread(window: z.Window, result: *?anyerror) void {
            window.emitEvent(.{ .focus = true }) catch |err| {
                result.* = err;
            };
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var probe: EmitProbe = .{};
    const window = try app.createWindow(.{});
    try window.setContent(.{ .context = &probe, .event = EmitProbe.event, .detach = EmitProbe.detach });
    try window.emitEvent(.{ .text_input = .{ .text = "a", .producer = .application } });
    try equal(1, probe.texts);
    // Disabled windows take no input, as natively.
    try window.perform(.disable);
    try window.emitEvent(.{ .text_input = .{ .text = "b", .producer = .application } });
    try equal(1, probe.texts);
    try window.perform(.enable);
    var result: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, EmitProbe.emitFromThread, .{ window, &result });
    thread.join();
    try equal(@as(?anyerror, error.WrongThread), result);
    try equal(0, probe.focus);
    _ = try window.destroy();
    try app.dispatch();
    try std.testing.expectError(error.Closed, window.emitEvent(.{ .focus = true }));
}
