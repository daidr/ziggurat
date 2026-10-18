const std = @import("std");
const z = @import("root.zig");
const c = z.composition;
const Probe = struct {
    attached: usize = 0,
    detached: usize = 0,
    events: usize = 0,
    updated: usize = 0,
    fail_attach: bool = false,
    fail_update: bool = false,
    remove_attach: bool = false,
    remove_event: bool = false,
    remove_reentrant: bool = false,
    pressed: bool = false,
    last_pointer: ?z.PointerButtonInput = null,
    actions: usize = 0,
    moves: usize = 0,
    cancels: usize = 0,
    blurred: usize = 0,
    focused: usize = 0,
    remove_on_blur: ?c.Region = null,
    cancel_action: enum { none, remove, close } = .none,
    close_on_focus: bool = false,
    owner_to_close: ?*c.Owner = null,
    closed: bool = false,
    fn participant(self: *Probe) c.Participant {
        return .{ .context = self, .attach = attach, .update = update, .detach = detach, .event = event };
    }
    fn attach(context: *anyopaque, region: c.Region) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        _ = try region.snapshot();
        self.attached += 1;
        if (self.remove_attach) _ = try region.remove();
        if (self.fail_attach) return error.Injected;
    }
    fn update(context: *anyopaque, _: c.Region, _: c.Viewport) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (self.fail_update) return error.Injected;
        self.updated += 1;
    }
    fn detach(context: *anyopaque, region: c.Region) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        std.testing.expectError(error.Closed, region.snapshot()) catch unreachable;
        self.detached += 1;
    }
    fn event(context: *anyopaque, region: c.Region, input: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.events += 1;
        switch (input) {
            .pointer_down => |pointer| {
                self.last_pointer = pointer;
                self.pressed = true;
                if (self.remove_reentrant) {
                    const window = (region.snapshot() catch unreachable).window;
                    _ = region.remove() catch unreachable;
                    window.app.windows.get(window.key).?.emit(.{ .pointer_down = .{ .position = .{ .x = 0, .y = 0 } } });
                }
            },
            .pointer_up => |pointer| {
                self.last_pointer = pointer;
                if (self.pressed) self.actions += 1;
                self.pressed = false;
            },
            .pointer_move => self.moves += 1,
            .cancel_input => {
                self.cancels += 1;
                self.pressed = false;
                switch (self.cancel_action) {
                    .none => {},
                    .remove => _ = region.remove() catch unreachable,
                    .close => _ = ((region.snapshot() catch unreachable).window).destroy() catch unreachable,
                }
                if (self.cancel_action != .none) std.testing.expectEqual(@as(usize, 0), self.detached) catch unreachable;
            },
            .focus => |focused| {
                if (focused) {
                    self.focused += 1;
                    if (self.close_on_focus) {
                        const window = (region.snapshot() catch unreachable).window;
                        _ = window.destroy() catch unreachable;
                        window.app.dispatch() catch unreachable;
                        std.testing.expect(!self.closed) catch unreachable;
                    }
                } else {
                    self.blurred += 1;
                    self.pressed = false;
                    if (self.remove_on_blur) |target| _ = target.remove() catch unreachable;
                }
            },
            else => {},
        }
        if (self.remove_event) {
            _ = region.remove() catch unreachable;
            std.testing.expectEqual(@as(usize, 0), self.detached) catch unreachable;
            std.testing.expect(region.beginCallback() == null) catch unreachable;
        }
    }
    fn closedNotify(context: *anyopaque, _: z.Window) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.owner_to_close.?.close() catch unreachable;
        self.owner_to_close = null;
        self.closed = true;
    }
};
const viewport: c.Viewport = .{ .bounds = .{ .x = 10, .y = 20, .width = 80, .height = 60 } };

test "composition forwards the complete press payload through captured release" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    const owner = try c.Owner.create(std.testing.allocator, window, .{ .capacity = 1 });
    defer {
        owner.detach() catch unreachable;
        owner.close() catch unreachable;
    }
    const region = try owner.reserve(viewport);
    var probe: Probe = .{};
    try region.attach(probe.participant());
    const record = app.windows.get(window.key).?;
    var pointer: z.PointerButtonInput = .{
        .position = .{ .x = 30, .y = 30 },
        .modifiers = .{ .shift = true, .control = true },
        .press = .{ .sequence = 71, .window_count = 3, .eligible = true, .qualified = true },
    };
    record.emit(.{ .pointer_down = pointer });
    try std.testing.expectEqualDeep(pointer, probe.last_pointer.?);
    pointer.position = .{ .x = 200, .y = 200 };
    pointer.press.eligible = false;
    record.emit(.{ .pointer_up = pointer });
    try std.testing.expectEqualDeep(pointer, probe.last_pointer.?);
    try std.testing.expectEqual(@as(usize, 1), probe.actions);
}

test "composition sole owner, attach rollback, update transaction and slot generations" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{ .capacity = 2 });
    defer owner.close() catch unreachable;
    try std.testing.expectError(error.ContentAlreadyAttached, c.Owner.create(std.testing.allocator, window, .{}));
    const region = try owner.reserve(viewport);
    var probe: Probe = .{ .fail_attach = true };
    try std.testing.expectError(error.Injected, region.attach(probe.participant()));
    try std.testing.expectEqual(@as(usize, 0), probe.detached);
    probe.fail_attach = false;
    try region.attach(probe.participant());
    try std.testing.expectError(error.AlreadyAttached, region.attach(probe.participant()));
    probe.fail_update = true;
    var changed = viewport;
    changed.bounds.width = 99;
    try std.testing.expectError(error.Injected, region.update(changed));
    try std.testing.expectEqualDeep(viewport, (try region.snapshot()).viewport);
    probe.fail_update = false;
    try region.update(changed);
    try std.testing.expectEqualDeep(changed, (try region.snapshot()).viewport);
    try std.testing.expect(try region.remove());
    try std.testing.expectEqual(@as(usize, 1), probe.detached);
    const next = try owner.reserve(viewport);
    try std.testing.expectEqual(region.index, next.index);
    try std.testing.expect(region.generation != next.generation);
    try std.testing.expectError(error.Closed, region.snapshot());
    try std.testing.expect(!(try region.remove()));
    try owner.detach();
    _ = try window.destroy();
}

test "composition remove blocks entry before last callback releases and closes once" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    var probe: Probe = .{ .remove_event = true };
    const region = try owner.reserve(viewport);
    try region.attach(probe.participant());
    const scope = region.beginCallback().?;
    const record = app.windows.get(window.key).?;
    record.emit(.{ .pointer_down = .{ .position = .{ .x = 30, .y = 30 } } });
    try std.testing.expectEqual(@as(usize, 1), probe.events);
    try std.testing.expectEqual(@as(usize, 0), probe.detached);
    try std.testing.expectError(error.Busy, owner.detach());
    scope.end();
    try std.testing.expectEqual(@as(usize, 1), probe.detached);
    _ = try window.destroy();
    try app.dispatch();
}

test "composition provisional remove neither resurrects nor double detaches failed attach" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    var probe: Probe = .{ .remove_attach = true };
    const region = try owner.reserve(viewport);
    try region.attach(probe.participant());
    try std.testing.expectError(error.Closed, region.snapshot());
    try std.testing.expectEqual(@as(usize, 1), probe.detached);
    probe.fail_attach = true;
    const retry = try owner.reserve(viewport);
    try std.testing.expectError(error.Injected, retry.attach(probe.participant()));
    try std.testing.expectEqual(@as(usize, 1), probe.detached);
    _ = try window.destroy();
}

test "composition focus pins owner through close and rejects recursive transitions" {
    const Focus = struct {
        owner: ?*c.Owner = null,
        next: ?c.Region = null,
        blur: usize = 0,
        closed: bool = false,
        fn attach(_: *anyopaque, _: c.Region) !void {}
        fn update(_: *anyopaque, _: c.Region, _: c.Viewport) !void {}
        fn detach(_: *anyopaque, _: c.Region) void {}
        fn event(context: *anyopaque, region: c.Region, input: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (input != .focus or input.focus) return;
            self.blur += 1;
            std.testing.expectError(error.Busy, self.owner.?.focus(self.next)) catch unreachable;
            const window = (region.snapshot() catch unreachable).window;
            _ = window.destroy() catch unreachable;
            window.app.dispatch() catch unreachable;
            std.testing.expect(!self.closed) catch unreachable;
        }
        fn notify(context: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.owner.?.close() catch unreachable;
            self.owner = null;
            self.closed = true;
        }
        fn participant(self: *@This()) c.Participant {
            return .{ .context = self, .attach = attach, .update = update, .detach = detach, .event = event };
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var focus: Focus = .{};
    const window = try app.createWindow(.{ .on_closed = .{ .context = &focus, .notify = Focus.notify } });
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    focus.owner = owner;
    const backdrop = try owner.reserveBackdrop();
    try backdrop.attach(focus.participant());
    const region = try owner.reserve(viewport);
    var native: Probe = .{};
    try region.attach(native.participant());
    focus.next = region;
    try owner.focus(region);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), focus.blur);
    try std.testing.expectEqual(@as(usize, 0), native.events);
    try std.testing.expect(focus.closed);
    try std.testing.expectEqual(@as(usize, 1), native.detached);
}

test "composition allocation failure leaves content slot available" {
    const Fixture = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const app = try z.App.init(std.testing.allocator);
            defer app.deinit();
            const window = try app.createWindow(.{});
            defer _ = window.destroy() catch unreachable;
            const owner = try c.Owner.create(allocator, window, .{ .capacity = 2 });
            defer owner.close() catch unreachable;
            const region = try owner.reserve(viewport);
            var probe: Probe = .{};
            try region.attach(probe.participant());
            try owner.detach();
            try std.testing.expectEqual(@as(usize, 1), probe.detached);
            try window.setContent(.{ .context = &probe, .event = plainEvent, .detach = plainDetach });
        }
        fn plainEvent(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn plainDetach(_: *anyopaque) void {}
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Fixture.run, .{});
}

test "composition removed backdrop cannot recapture through reentrant input" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    var back: Probe = .{ .remove_reentrant = true };
    const backdrop = try owner.reserveBackdrop();
    try backdrop.attach(back.participant());
    var native: Probe = .{};
    const region = try owner.reserve(viewport);
    try region.attach(native.participant());
    const record = app.windows.get(window.key).?;
    record.emit(.{ .pointer_down = .{ .position = .{ .x = 0, .y = 0 } } });
    try std.testing.expectEqual(@as(usize, 1), back.detached);
    record.emit(.{ .pointer_move = .{ .x = 30, .y = 30 } });
    try std.testing.expectEqual(@as(usize, 1), native.moves);
    _ = try window.destroy();
}

test "composition successful hide cancels press and moves focus; failed hide preserves it" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    defer owner.close() catch unreachable;
    var back: Probe = .{};
    const backdrop = try owner.reserveBackdrop();
    try backdrop.attach(back.participant());
    var native: Probe = .{};
    const region = try owner.reserve(viewport);
    try region.attach(native.participant());
    try owner.focus(region);
    const record = app.windows.get(window.key).?;
    record.emit(.{ .pointer_down = .{ .position = .{ .x = 30, .y = 30 } } });
    var hidden = viewport;
    hidden.visible = false;
    native.fail_update = true;
    try std.testing.expectError(error.Injected, region.update(hidden));
    try std.testing.expect(native.pressed);
    try std.testing.expectEqual(@as(usize, 0), native.cancels);
    try std.testing.expectEqual(@as(usize, 0), native.blurred);
    native.fail_update = false;
    try region.update(hidden);
    try std.testing.expectEqual(@as(usize, 1), native.cancels);
    try std.testing.expectEqual(@as(usize, 1), native.blurred);
    try std.testing.expectEqual(@as(usize, 1), back.focused);
    try region.update(viewport);
    record.emit(.{ .pointer_up = .{ .position = .{ .x = 30, .y = 30 } } });
    try std.testing.expectEqual(@as(usize, 0), native.actions);
    try owner.focus(region);
    record.emit(.{ .pointer_down = .{ .position = .{ .x = 30, .y = 30 } } });
    var empty = viewport;
    empty.bounds.width = 0;
    try region.update(empty);
    try std.testing.expectError(error.NotAttached, owner.focus(region));
    try std.testing.expectEqual(@as(usize, 2), native.cancels);
    try std.testing.expectEqual(@as(usize, 2), native.blurred);
    try std.testing.expectEqual(@as(usize, 2), back.focused);
    try region.update(viewport);
    record.emit(.{ .pointer_up = .{ .position = .{ .x = 30, .y = 30 } } });
    try std.testing.expectEqual(@as(usize, 0), native.actions);
    try owner.focus(region);
    try std.testing.expect(try region.remove());
    try std.testing.expectEqual(@as(usize, 3), back.focused);
    _ = try window.destroy();
}

test "composition fallback notification pins owner through close and immediate on_closed release" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var back: Probe = .{};
    const window = try app.createWindow(.{ .on_closed = .{ .context = &back, .notify = Probe.closedNotify } });
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    back.owner_to_close = owner;
    defer if (back.owner_to_close != null) {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    };
    const backdrop = try owner.reserveBackdrop();
    try backdrop.attach(back.participant());
    var native: Probe = .{};
    const region = try owner.reserve(viewport);
    try region.attach(native.participant());
    try owner.focus(region);
    back.close_on_focus = true;
    try std.testing.expect(try region.remove());
    try app.dispatch();
    try std.testing.expect(back.closed and back.owner_to_close == null);
    try std.testing.expectEqual(@as(usize, 1), back.focused);
    try std.testing.expectEqual(@as(usize, 1), back.detached);
    try std.testing.expectEqual(@as(usize, 1), native.detached);
}

test "composition hide cancellation may remove itself or close without entering a later blur" {
    for ([_]bool{ false, true }) |close| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        const owner = try c.Owner.create(std.testing.allocator, window, .{});
        defer {
            _ = window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
            owner.close() catch unreachable;
        }
        var back: Probe = .{};
        const backdrop = try owner.reserveBackdrop();
        try backdrop.attach(back.participant());
        var native: Probe = .{ .cancel_action = if (close) .close else .remove };
        const region = try owner.reserve(viewport);
        try region.attach(native.participant());
        try owner.focus(region);
        var hidden = viewport;
        hidden.visible = false;
        try region.update(hidden);
        try app.dispatch();
        try std.testing.expectEqual(@as(usize, 1), native.cancels);
        try std.testing.expectEqual(@as(usize, 1), native.detached);
        try std.testing.expectEqual(@as(usize, 0), native.blurred);
        if (!close) try std.testing.expectEqual(@as(usize, 1), back.focused);
    }
}

test "composition blur removing next target restores fallback once" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    const owner = try c.Owner.create(std.testing.allocator, window, .{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
        owner.close() catch unreachable;
    }
    var back: Probe = .{};
    const backdrop = try owner.reserveBackdrop();
    try backdrop.attach(back.participant());
    var native: Probe = .{};
    const region = try owner.reserve(viewport);
    try region.attach(native.participant());
    back.remove_on_blur = region;
    try owner.focus(region);
    try std.testing.expectEqual(@as(usize, 1), back.blurred);
    try std.testing.expectEqual(@as(usize, 1), back.focused);
    try std.testing.expectEqual(@as(usize, 0), native.focused);
    try std.testing.expectEqual(@as(usize, 1), native.detached);
    try std.testing.expectError(error.Closed, region.snapshot());
}
