const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

const Host = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    counts: [16]u8 = undefined,
    calls: usize = 0,
    legacy: usize = 0,
    consumed: bool = false,
    clear_on_input: bool = false,
    clear_on_action: bool = false,
    reject: bool = false,
    advance_on_input: bool = false,
    repaint_target: ?ui.ClickTarget = null,
    failure: ?anyerror = null,

    fn draw(_: *anyopaque, _: *ui.Frame) void {}
    fn ordinary(ptr: *anyopaque, _: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.legacy += 1;
    }
    fn preprocess(ptr: *anyopaque, context: *ui.Context, ev: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (ev == .pointer_down and self.advance_on_input) {
            self.advance_on_input = false;
            // A native operation can supersede this ingress without forwarding
            // another event to this particular Content attachment.
            _ = self.app.windows.get(self.window.key).?.native.pointer_operation.advance();
        }
        if (ev == .pointer_down) if (self.repaint_target) |target| {
            self.repaint_target = null;
            self.frame(&.{target}) catch |err| {
                self.failure = err;
            };
        };
        if (ev == .pointer_down and self.clear_on_input) {
            self.clear_on_input = false;
            context.clearPointerClicks() catch |err| {
                self.failure = err;
            };
        }
        return self.consumed;
    }
    fn clicked(ptr: *anyopaque, _: z.Window, click: ui.ControlClick) ui.ClickOutcome {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.calls == self.counts.len) {
            self.failure = error.TooManyCallbacks;
            return .rejected;
        }
        self.counts[self.calls] = click.count;
        self.calls += 1;
        if (self.clear_on_action) {
            self.clear_on_action = false;
            self.context.clearPointerClicks() catch |err| {
                self.failure = err;
            };
        }
        return if (self.reject) .rejected else .accepted;
    }
    fn setup(self: *Host) !void {
        try self.attach();
        try self.context.preparePointerClicks(std.testing.allocator, self.registration());
    }
    fn attach(self: *Host) !void {
        self.app = try z.App.init(std.testing.allocator);
        errdefer self.app.deinit();
        self.window = try self.app.createWindow(.{ .native_pointer_clicks = true });
        self.context = ui.Context.init(self, draw, ordinary);
        self.context.render_mode = .gdi;
        self.context.semantics_enabled = false;
        try self.context.attach(self.window);
    }
    fn registration(self: *Host) ui.PointerClickRegistration {
        return .{ .context = self, .on_input = preprocess, .on_click = clicked };
    }
    fn deinit(self: *Host) void {
        _ = self.window.destroy() catch unreachable;
        self.app.dispatch() catch unreachable;
        std.debug.assert(self.app.resourceStats().allocated_records == 0);
        self.app.deinit();
    }
    fn frame(self: *Host, targets: []const ui.ClickTarget) !void {
        self.context.command_buffer.reset();
        self.context.input_state.beginFrame();
        errdefer self.context.input_state.cancelFrame();
        var value: ui.Frame = .{ .context = &self.context, .size = .{ .width = 100, .height = 80, .scale = 1 } };
        for (targets, 0..) |target, i| try value.clickButton(target, .{ .x = @floatFromInt(i * 30), .y = 0, .width = 20, .height = 20 }, "Click", .{});
        try self.context.input_state.validateFrame();
        self.context.input_state.commitFrame();
    }
    fn ordinaryFrame(self: *Host) !void {
        self.context.command_buffer.reset();
        self.context.input_state.beginFrame();
        errdefer self.context.input_state.cancelFrame();
        var value: ui.Frame = .{ .context = &self.context, .size = .{ .width = 100, .height = 80, .scale = 1 } };
        try value.button(7, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, "Ordinary");
        try self.context.input_state.validateFrame();
        self.context.input_state.commitFrame();
    }
    fn pair(self: *Host, x: f32, tick: u32) !void {
        return self.pairTiming(x, tick, true);
    }
    fn pairTiming(self: *Host, x: f32, tick: u32, qualified: bool) !void {
        const record = self.app.windows.get(self.window.key).?;
        const down_op = record.native.pointer_operation.advance();
        const timing: z.PointerClickTiming = .{ .tick_ms = tick, .position = .{ .x = x, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
        const down = record.pointerBeginDown(down_op, .primary, if (qualified) timing else null).?;
        record.emitPointer(down_op, down.press.sequence, .down, .{ .position = .{ .x = x, .y = 5 } });
        _ = record.pointerFinish(down_op, down.press.sequence, .primary, .down, .delivered);
        const up_op = record.native.pointer_operation.advance();
        const up = record.pointerBeginUp(up_op, .primary).?;
        record.emitPointer(up_op, up.press.sequence, .up, .{ .position = .{ .x = x, .y = 5 } });
        record.emitPointerCancel(up_op, up.press.sequence, .primary);
        _ = record.pointerFinish(up_op, up.press.sequence, .primary, .up, .delivered);
        if (self.failure) |err| return err;
    }
};

test "registered button uses its own target counts and one callback route" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const a = try host.context.newClickTarget(7);
    const b = try host.context.newClickTarget(8);
    try host.frame(&.{ a, b });
    try host.pair(5, 10);
    try host.pair(35, 20);
    try host.pair(35, 30);
    try host.pair(35, 40);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 3 }, host.counts[0..host.calls]);
    try std.testing.expectEqual(@as(usize, 0), host.legacy);
    const workspace = host.context.input_state.clicks.?;
    std.debug.print("UI pointer layouts Input={d} Context={d} Frame={d} Workspace={d} Kernel={d} Registration={d}\n", .{ @sizeOf(@TypeOf(host.context.input_state)), @sizeOf(ui.Context), @sizeOf(ui.Frame), @sizeOf(@TypeOf(workspace.*)), @sizeOf(@TypeOf(workspace.state)), @sizeOf(ui.PointerClickRegistration) });
    try std.testing.expect(@sizeOf(@TypeOf(workspace.*)) <= 4096);
}

test "clear retains stale marks and ordinary successful front alone removes them" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    try host.context.clearPointerClicks();
    try host.pair(5, 10);
    try std.testing.expectEqual(@as(usize, 0), host.calls + host.legacy);
    try std.testing.expectError(error.NoFrame, host.context.input_state.add(9, .{ .x = 0, .y = 0, .width = 20, .height = 20 }));
    host.context.input_state.rollback(0);
    host.context.input_state.commitFrame();
    try std.testing.expectEqual(@as(usize, 1), host.context.input_state.len);
    try std.testing.expect((try host.context.input_state.clicks.?.state.mark(0)) != 0);
    host.context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = &host.context, .size = .{ .width = 100, .height = 80, .scale = 1 } };
    try frame.button(7, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, "Ordinary");
    host.context.input_state.commitFrame();
    try host.pair(5, 20);
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expectEqual(@as(usize, 1), host.legacy);
}

test "candidate stale-token bind rolls back paint and hit data" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    try host.context.replacePointerClickRegistration(host.registration());
    host.context.command_buffer.reset();
    host.context.input_state.beginFrame();
    defer host.context.input_state.cancelFrame();
    var frame: ui.Frame = .{ .context = &host.context, .size = .{ .width = 100, .height = 80, .scale = 1 } };
    const before = host.context.command_buffer.len;
    try std.testing.expectError(error.StaleTarget, frame.clickButton(target, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, "Stale", .{}));
    try std.testing.expectEqual(@as(usize, 0), host.context.input_state.pending_len);
    try std.testing.expectEqual(@as(usize, 0), host.context.input_state.clicks.?.state.banks[host.context.input_state.clicks.?.state.front ^ 1].len);
    try std.testing.expectEqual(before, host.context.command_buffer.len);
}

test "preprocessor consumption and callback clear never fall back or seed history" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    host.consumed = true;
    try host.pair(5, 10);
    try std.testing.expectEqual(@as(usize, 0), host.calls + host.legacy);
    host.consumed = false;
    try host.pair(5, 20);
    host.clear_on_action = true;
    try host.pair(5, 30);
    try host.pair(5, 40);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, host.counts[0..host.calls]);
    try std.testing.expectEqual(@as(usize, 0), host.legacy);
    try std.testing.expect(host.context.input_state.clicks.?.state.savedHistoryPoint() == null);
}

test "first prepare seeds only zeros over an existing ordinary front" {
    var host: Host = .{};
    host.app = try z.App.init(std.testing.allocator);
    defer host.app.deinit();
    host.window = try host.app.createWindow(.{ .native_pointer_clicks = true });
    host.context = ui.Context.init(&host, Host.draw, Host.ordinary);
    host.context.semantics_enabled = false;
    try host.context.attach(host.window);
    try host.context.input_state.add(7, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try host.context.preparePointerClicks(std.testing.allocator, host.registration());
    try std.testing.expectEqual(@as(u64, 0), try host.context.input_state.clicks.?.state.mark(0));
    try host.pair(5, 10);
    try std.testing.expectEqual(@as(usize, 1), host.legacy);
    try std.testing.expectEqual(@as(usize, 0), host.calls);
}

test "registered down rechecks the raw receipt after preprocessing" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    host.advance_on_input = true;
    const record = host.app.windows.get(host.window.key).?;
    const op = record.native.pointer_operation.advance();
    const timing: z.PointerClickTiming = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
    const down = record.pointerBeginDown(op, .primary, timing).?;
    record.emitPointer(op, down.press.sequence, .down, .{ .position = .{ .x = 5, .y = 5 } });
    _ = record.pointerFinish(op, down.press.sequence, .primary, .down, .delivered);
    try std.testing.expect(host.context.input_state.active == null);
    try std.testing.expect(host.context.input_state.clicks.?.state.savedHeldPoint() == null);
    try host.pair(5, 20);
    try std.testing.expectEqualSlices(u8, &.{1}, host.counts[0..host.calls]);
}

test "old down does not focus a front published by its preprocessor" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    host.repaint_target = target;
    const record = host.app.windows.get(host.window.key).?;
    const op = record.native.pointer_operation.advance();
    const timing: z.PointerClickTiming = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
    const down = record.pointerBeginDown(op, .primary, timing).?;
    record.emitPointer(op, down.press.sequence, .down, .{ .position = .{ .x = 5, .y = 5 } });
    _ = record.pointerFinish(op, down.press.sequence, .primary, .down, .delivered);
    try std.testing.expect(host.context.input_state.active == null);
    try std.testing.expect(host.context.input_state.focused == null);
    try host.pair(5, 20);
    try std.testing.expectEqualSlices(u8, &.{1}, host.counts[0..host.calls]);
}

const CountingAllocator = struct {
    context: ?*ui.Context = null,
    window: ?z.Window = null,
    fail: bool = false,
    action: enum { none, clear, close, nested } = .none,
    close_on_free: bool = false,
    observed: ?anyerror = null,
    registration: ui.PointerClickRegistration = undefined,
    allocations: usize = 0,
    requests: usize = 0,
    bytes: usize = 0,
    peak: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        if (self.fail) return null;
        const action = self.action;
        self.action = .none;
        switch (action) {
            .none => {},
            .clear => self.context.?.clearPointerClicks() catch |err| {
                self.observed = err;
            },
            .close => {
                _ = self.window.?.destroy() catch unreachable;
            },
            .nested => self.context.?.preparePointerClicks(self.allocator(), self.registration) catch |err| {
                self.observed = err;
            },
        }
        const result = std.testing.allocator.rawAlloc(len, alignment, ret) orelse return null;
        self.allocations += 1;
        self.bytes += len;
        self.peak = @max(self.peak, self.bytes);
        return result;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.bytes -= bytes.len;
        std.testing.allocator.rawFree(bytes, alignment, ret);
        if (self.close_on_free) {
            self.close_on_free = false;
            _ = self.window.?.destroy() catch unreachable;
        }
    }
};

test "preparation is atomic across OOM, allocator reentry and final-free close" {
    inline for (.{ .none, .clear, .close, .nested }) |action| {
        var host: Host = .{};
        try host.attach();
        defer host.deinit();
        var allocator: CountingAllocator = .{ .context = &host.context, .window = host.window, .registration = host.registration() };
        allocator.fail = true;
        try std.testing.expectError(error.OutOfMemory, host.context.preparePointerClicks(allocator.allocator(), host.registration()));
        try std.testing.expect(host.context.input_state.clicks == null);
        const old_epoch = host.context.input_state.click_epoch;
        allocator.fail = false;
        allocator.action = action;
        allocator.close_on_free = action == .clear;
        if (action == .clear) {
            try std.testing.expectError(error.PointerClickStateChanged, host.context.preparePointerClicks(allocator.allocator(), host.registration()));
            try std.testing.expect(host.window.isClosed());
        } else if (action == .close) {
            try std.testing.expectError(error.Closed, host.context.preparePointerClicks(allocator.allocator(), host.registration()));
        } else {
            try host.context.preparePointerClicks(allocator.allocator(), host.registration());
            if (action == .nested) try std.testing.expectEqual(@as(?anyerror, error.Busy), allocator.observed);
            const workspace = host.context.input_state.clicks.?;
            try std.testing.expect(host.context.input_state.click_epoch > old_epoch);
            try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
            const target = try host.context.newClickTarget(7);
            try host.frame(&.{target});
            try host.pair(5, 10);
            try host.frame(&.{target});
            try host.pair(5, 20);
            try host.context.clearPointerClicks();
            try host.context.preparePointerClicks(allocator.allocator(), host.registration());
            try std.testing.expect(workspace == host.context.input_state.clicks.?);
            try std.testing.expectEqual(@as(usize, 1), allocator.allocations);
            try std.testing.expectEqual(allocator.bytes, allocator.peak);
            try std.testing.expectError(error.AllocatorMismatch, host.context.preparePointerClicks(std.testing.allocator, host.registration()));
            _ = try host.window.destroy();
        }
        try host.app.dispatch();
        try std.testing.expect(host.context.input_state.clicks == null and !host.context.input_state.click_preparing);
        try std.testing.expectEqual(@as(usize, 0), allocator.bytes);
    }
}

test "preparation rejects a raw-disabled window before caller allocation or front mutation" {
    var host: Host = .{};
    host.app = try z.App.init(std.testing.allocator);
    defer host.app.deinit();
    host.window = try host.app.createWindow(.{});
    defer _ = host.window.destroy() catch unreachable;
    host.context = ui.Context.init(&host, Host.draw, Host.ordinary);
    host.context.semantics_enabled = false;
    try host.context.attach(host.window);
    try host.context.input_state.add(7, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    var allocator: CountingAllocator = .{ .fail = true };
    try std.testing.expectError(error.UnsupportedCapability, host.context.preparePointerClicks(allocator.allocator(), host.registration()));
    try std.testing.expect(host.context.input_state.clicks == null and !host.context.input_state.click_preparing);
    try std.testing.expectEqual(@as(u64, 0), host.context.input_state.click_epoch);
    try std.testing.expectEqual(@as(usize, 1), host.context.input_state.len);
    try std.testing.expectEqual(@as(usize, 0), allocator.allocations);
    try std.testing.expectEqual(@as(usize, 0), allocator.requests);
}

test "raw unknown or undelivered other-button down breaks semantic continuation" {
    inline for (.{ @as(?z.PointerButton, null), @as(?z.PointerButton, .secondary) }) |button| {
        var host: Host = .{};
        try host.setup();
        defer host.deinit();
        const target = try host.context.newClickTarget(7);
        try host.frame(&.{target});
        try host.pair(5, 10);
        try host.pair(5, 20);
        const record = host.app.windows.get(host.window.key).?;
        const op = record.native.pointer_operation.advance();
        const down = record.pointerBeginDown(op, button, null).?;
        _ = record.pointerFinish(op, down.press.sequence, button, .down, .consumed);
        try host.pair(5, 30);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1 }, host.counts[0..host.calls]);
    }
}

test "enabled raw owner with null timing still authorizes independent single clicks" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    try host.pairTiming(5, 10, false);
    try host.pairTiming(5, 20, false);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, host.counts[0..host.calls]);
    try std.testing.expect(host.context.input_state.clicks.?.state.savedHistoryPoint() == null);
}

test "rejected callback and preprocessor clear never retain accepted history" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    host.reject = true;
    try host.pair(5, 10);
    host.reject = false;
    try host.pair(5, 20);
    host.clear_on_input = true;
    try host.pair(5, 30);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1 }, host.counts[0..host.calls]);
    try std.testing.expectEqual(@as(usize, 0), host.legacy);
}

test "callback close frees Context while independently pinned workspace remains safe" {
    const Observer = struct {
        context: ?*ui.Context = null,
        callbacks: usize = 0,
        closed: usize = 0,
        fn clicked(ptr: *anyopaque, window: z.Window, _: ui.ControlClick) ui.ClickOutcome {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.callbacks += 1;
            _ = window.destroy() catch unreachable;
            return .accepted;
        }
        fn ordinary(_: *anyopaque, _: u64) void {
            unreachable;
        }
        fn closedWindow(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const context = self.context.?;
            self.context = null;
            self.closed += 1;
            std.testing.allocator.destroy(context);
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    var observer: Observer = .{};
    const window = try app.createWindow(.{ .native_pointer_clicks = true, .on_closed = .{ .context = &observer, .notify = Observer.closedWindow } });
    const context = try std.testing.allocator.create(ui.Context);
    observer.context = context;
    context.* = ui.Context.init(&observer, Host.draw, Observer.ordinary);
    context.semantics_enabled = false;
    try context.attach(window);
    var allocator: CountingAllocator = .{}; // Independent of the freed Context.
    try context.preparePointerClicks(allocator.allocator(), .{ .context = &observer, .on_click = Observer.clicked });
    const target = try context.newClickTarget(7);
    context.input_state.beginFrame();
    var frame: ui.Frame = .{ .context = context, .size = .{ .width = 100, .height = 80, .scale = 1 } };
    try frame.clickButton(target, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, "Close", .{});
    context.input_state.commitFrame();
    const workspace = context.input_state.clicks.?;
    try std.testing.expect(workspace.retain());
    {
        const record = app.windows.get(window.key).?;
        const native = record.enterNative();
        defer native.end(); // The remaining code uses only independent owners.
        const op = record.native.pointer_operation.advance();
        const timing: z.PointerClickTiming = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
        const down = record.pointerBeginDown(op, .primary, timing).?;
        record.emitPointer(op, down.press.sequence, .down, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(op, down.press.sequence, .primary, .down, .delivered);
        const up_op = record.native.pointer_operation.advance();
        const up = record.pointerBeginUp(up_op, .primary).?;
        record.emitPointer(up_op, up.press.sequence, .up, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(up_op, up.press.sequence, .primary, .up, .delivered);
    }
    try app.dispatch();
    try std.testing.expect(observer.context == null and observer.callbacks == 1 and observer.closed == 1);
    try std.testing.expect(workspace.state.closed and workspace.state.savedHistoryPoint() == null);
    try std.testing.expectEqual(@as(usize, 1), workspace.refs);
    workspace.release();
    try std.testing.expectEqual(@as(usize, 0), allocator.bytes);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "detached owner overlap preserves installation and counts the actual allocation peak" {
    var host: Host = .{};
    try host.attach();
    defer host.deinit();
    var allocator: CountingAllocator = .{ .context = &host.context };
    try host.context.preparePointerClicks(allocator.allocator(), host.registration());
    const stale = try host.context.newClickTarget(7);
    try host.frame(&.{stale});
    const old = host.context.input_state.clicks.?;
    const old_epoch = host.context.input_state.click_epoch;
    try std.testing.expect(old.retain());
    _ = try host.window.destroy();
    try host.app.dispatch();
    try std.testing.expect(host.context.window == null and old.state.closed and old.refs == 1);
    host.window = try host.app.createWindow(.{ .native_pointer_clicks = true });
    try host.context.attach(host.window);
    try host.context.preparePointerClicks(allocator.allocator(), host.registration());
    try std.testing.expect(host.context.input_state.click_epoch > old_epoch);
    try std.testing.expectError(error.StaleTarget, host.frame(&.{stale}));
    try std.testing.expectEqual(@as(usize, 0), host.context.input_state.pending_len);
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    try host.pair(5, 20);
    try std.testing.expectEqualSlices(u8, &.{1}, host.counts[0..host.calls]);
    try std.testing.expectEqual(@as(usize, 2), allocator.allocations);
    try std.testing.expectEqual(2 * @sizeOf(@TypeOf(old.*)), allocator.peak);
    std.debug.print("UI pointer retired overlap physical_peak={d}, owner_bytes={d}\n", .{ allocator.peak, @sizeOf(@TypeOf(old.*)) });
    // The old allocation's final free is foreign and may close the new window.
    // Neither release path may subsequently touch an obsolete Context owner.
    allocator.window = host.window;
    allocator.close_on_free = true;
    old.release();
    try host.app.dispatch();
    try std.testing.expect(host.context.window == null);
    try std.testing.expectEqual(@as(usize, 0), allocator.bytes);
}

test "registered held press cannot cross into an ordinary same-id front" {
    inline for (.{ false, true }) |revoke_first| {
        var host: Host = .{};
        try host.setup();
        defer host.deinit();
        const target = try host.context.newClickTarget(7);
        try host.frame(&.{target});
        const record = host.app.windows.get(host.window.key).?;
        const op = record.native.pointer_operation.advance();
        const timing: z.PointerClickTiming = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
        const down = record.pointerBeginDown(op, .primary, timing).?;
        record.emitPointer(op, down.press.sequence, .down, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(op, down.press.sequence, .primary, .down, .delivered);
        try std.testing.expectEqual(@as(?u64, 7), host.context.input_state.active);
        if (revoke_first) host.context.input_state.clicks.?.revoke();
        try host.ordinaryFrame();
        const active_after_commit = host.context.input_state.active;
        const up_op = record.native.pointer_operation.advance();
        const up = record.pointerBeginUp(up_op, .primary).?;
        record.emitPointer(up_op, up.press.sequence, .up, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(up_op, up.press.sequence, .primary, .up, .delivered);
        try std.testing.expectEqual(@as(usize, 0), host.calls + host.legacy);
        try std.testing.expect(active_after_commit == null);
        try host.pair(5, 20);
        try std.testing.expectEqual(@as(usize, 1), host.legacy);
    }
}

test "ordinary held press preserves ordinary repaint and cannot acquire a registered action" {
    inline for (.{ false, true }) |register_next| {
        var host: Host = .{};
        try host.setup();
        defer host.deinit();
        const target = try host.context.newClickTarget(7);
        try host.ordinaryFrame();
        const record = host.app.windows.get(host.window.key).?;
        const op = record.native.pointer_operation.advance();
        const timing: z.PointerClickTiming = .{ .tick_ms = 10, .position = .{ .x = 5, .y = 5, .domain = 1 }, .policy = .{ .interval_ms = 500, .min_x = -100, .max_x = 100, .min_y = -100, .max_y = 100 } };
        const down = record.pointerBeginDown(op, .primary, timing).?;
        record.emitPointer(op, down.press.sequence, .down, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(op, down.press.sequence, .primary, .down, .delivered);
        if (register_next) try host.frame(&.{target}) else try host.ordinaryFrame();
        const up_op = record.native.pointer_operation.advance();
        const up = record.pointerBeginUp(up_op, .primary).?;
        record.emitPointer(up_op, up.press.sequence, .up, .{ .position = .{ .x = 5, .y = 5 } });
        _ = record.pointerFinish(up_op, up.press.sequence, .primary, .up, .delivered);
        try std.testing.expectEqual(@as(usize, 0), host.calls);
        try std.testing.expectEqual(@as(usize, if (register_next) 0 else 1), host.legacy);
    }
}

test "registered button keyboard activation remains one ordinary action per nonrepeat key" {
    var host: Host = .{};
    try host.setup();
    defer host.deinit();
    const target = try host.context.newClickTarget(7);
    try host.frame(&.{target});
    try host.window.perform(.focus);
    try host.context.focusControl(7);
    try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .space }));
    try std.testing.expectEqual(@as(usize, 1), host.legacy);
    try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .space, .repeat = true }));
    try std.testing.expectEqual(@as(usize, 1), host.legacy);
    try std.testing.expect(host.context.handleKeyInput(host.window, .{ .key = .enter }));
    try std.testing.expectEqual(@as(usize, 2), host.legacy);
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expect(host.context.input_state.clicks.?.state.savedHistoryPoint() == null);
}
