const std = @import("std");
const z = @import("root.zig");
const fake = @import("platform/testing.zig");
const raw = @import("platform/pointer_press.zig");

fn sample(tick: u32) z.PointerClickTiming {
    return .{ .tick_ms = tick, .position = .{ .x = 10, .y = 20, .domain = 999 }, .policy = .{ .interval_ms = 500, .min_x = -2, .max_x = 3, .min_y = -3, .max_y = 3 } };
}
fn record(window: z.Window) *z.WindowRecord {
    return window.app.windows.get(window.key).?;
}
fn deliver(window: z.Window, phase: z.PointerPhase, button: z.PointerButton, timing: ?z.PointerClickTiming) z.PointerPress {
    const item = record(window);
    const scope = item.enterNative();
    defer scope.end();
    const operation = fake.advancePointerOperation(item);
    const transition = (if (phase == .down) item.pointerBeginDown(operation, button, timing) else item.pointerBeginUp(operation, button)).?;
    item.emitPointer(operation, transition.press.sequence, phase, .{ .position = .{ .x = 4, .y = 8 }, .button = button, .modifiers = .{ .shift = true } });
    _ = item.pointerFinish(operation, transition.press.sequence, button, phase, .delivered);
    return transition.press;
}
fn detach(_: *anyopaque) void {}

test "held native receipt survives deadline and motion without granting an active snapshot" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const press = deliver(window, .down, .primary, sample(10));
    try window.pointerPressHeld(press, .primary);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(press, .down));
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(press, .secondary));
    var altered = press;
    altered.window_count += 1;
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(altered, .primary));
    altered = press;
    altered.qualified = !press.qualified;
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(altered, .primary));
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(.{}, .primary));
    const item = record(window);
    item.pointerMotion(item.pointerOperation(), .{ .x = 1000, .y = 2000, .domain = 1 });
    // Moving outside the click-distance policy does not release a drag.
    try window.pointerPressHeld(press, .primary);
    _ = deliver(window, .down, .secondary, null);
    try window.pointerPressHeld(press, .primary);
    _ = deliver(window, .up, .secondary, null);
    try window.pointerPressHeld(press, .primary);
    _ = deliver(window, .up, .primary, null);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(press, .primary));
}

test "held native receipt rejects unfinished down release and native counter changes" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const item = record(window);
    const down = item.pointerBeginDown(fake.advancePointerOperation(item), .primary, sample(20)).?;
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(down.press, .primary));
    try std.testing.expect(item.pointerFinish(down.operation, down.press.sequence, .primary, .down, .delivered));
    try window.pointerPressHeld(down.press, .primary);
    const up = item.pointerBeginUp(fake.advancePointerOperation(item), .primary).?;
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(down.press, .primary));
    try std.testing.expect(item.pointerFinish(up.operation, up.press.sequence, .primary, .up, .delivered));
    const next = deliver(window, .down, .primary, null);
    try window.pointerPressHeld(next, .primary);
    const operation = fake.advancePointerOperation(item);
    // Even before Core observes a native revoke, its old owner is stale.
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(next, .primary));
    item.pointerRevoke(operation, true);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(next, .primary));
}

test "held native receipt requires owner live input and its original Window generation" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const plain = try app.createWindow(.{});
    try std.testing.expectError(error.UnsupportedCapability, plain.pointerPressHeld(.{}, .primary));
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const press = deliver(window, .down, .primary, null);
    const Probe = struct {
        fn worker(value: z.Window, receipt: z.PointerPress) void {
            std.testing.expectError(error.WrongThread, value.pointerPressHeld(receipt, .primary)) catch unreachable;
        }
    };
    const worker = try std.Thread.spawn(.{}, Probe.worker, .{ window, press });
    worker.join();
    try window.perform(.disable);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(press, .primary));
    try window.perform(.enable);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(press, .primary));
    const fresh = deliver(window, .down, .primary, null);
    record(window).emit(.{ .focus = false });
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(fresh, .primary));
    const closing = deliver(window, .down, .primary, null);
    _ = try window.destroy();
    _ = try app.createWindow(.{ .native_pointer_clicks = true });
    try std.testing.expectError(error.StalePointerInput, window.pointerPressHeld(closing, .primary));
}

test "pointer snapshots bind native ingress phase real button and current sticky eligibility" {
    const Probe = struct {
        calls: usize = 0,
        downs: usize = 0,
        ups: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const phase: z.PointerPhase = switch (value) {
                .pointer_down => .down,
                .pointer_up => .up,
                else => return,
            };
            const input = if (phase == .down) value.pointer_down else value.pointer_up;
            const snapshot = window.pointerPressSnapshot(input.press, phase) catch unreachable;
            std.testing.expectEqual(z.PointerButton.secondary, snapshot.button) catch unreachable;
            std.testing.expect(input.modifiers.shift) catch unreachable;
            std.testing.expectEqual(@as(u32, 0), snapshot.timing.?.tick_ms) catch unreachable;
            std.testing.expectEqual(@as(u64, 1), snapshot.timing.?.position.domain) catch unreachable;
            std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, if (phase == .down) .up else .down)) catch unreachable;
            self.calls += 1;
            if (phase == .down) {
                self.downs += 1;
                const item = record(window);
                item.pointerMotion(item.pointerOperation(), .{ .x = 100, .y = 20, .domain = 0 });
                item.pointerMotion(item.pointerOperation(), .{ .x = 10, .y = 20, .domain = 0 });
                const after = window.pointerPressSnapshot(input.press, phase) catch unreachable;
                std.testing.expect(!after.continuation_eligible) catch unreachable;
                std.testing.expectEqual(@as(u8, 1), input.press.window_count) catch unreachable;
                // A lifetime/composition forwarding pin preserves this ingress.
                const pin = window.beginCallback().?;
                std.testing.expect(!(window.pointerPressSnapshot(input.press, phase) catch unreachable).continuation_eligible) catch unreachable;
                pin.end();
            } else {
                self.ups += 1;
                std.testing.expect(!snapshot.continuation_eligible) catch unreachable;
            }
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = detach });
    const down = deliver(window, .down, .secondary, sample(0));
    try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(down, .down));
    const up = deliver(window, .up, .secondary, null);
    try std.testing.expectEqual(down.sequence, up.sequence);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.downs);
    try std.testing.expectEqual(@as(usize, 1), probe.ups);
}

test "native null timing retains receipt pairing and completed qualified bursts use one owner" {
    const Probe = struct {
        qualified: bool = false,
        count: u8 = 1,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const phase: z.PointerPhase = switch (value) {
                .pointer_down => .down,
                .pointer_up => .up,
                else => return,
            };
            const input = if (phase == .down) value.pointer_down else value.pointer_up;
            const snapshot = window.pointerPressSnapshot(input.press, phase) catch unreachable;
            std.testing.expectEqual(self.qualified, snapshot.timing != null) catch unreachable;
            std.testing.expectEqual(self.count, input.press.window_count) catch unreachable;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = detach });
    const unqualified = deliver(window, .down, .primary, null);
    try std.testing.expect(unqualified.sequence != 0 and !unqualified.qualified);
    try std.testing.expectEqual(unqualified.sequence, deliver(window, .up, .primary, null).sequence);
    probe.qualified = true;
    for ([_]u32{ 0, 100, 200, 300 }, [_]u8{ 1, 2, 3, 1 }) |tick, count| {
        probe.count = count;
        _ = deliver(window, .down, .primary, sample(tick));
        _ = deliver(window, .up, .primary, null);
    }
}

test "Core snapshot exposes last raw completion only during current native down" {
    const Probe = struct {
        expected_previous: u64 = 0,
        downs: usize = 0,
        ups: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const phase: z.PointerPhase = switch (value) {
                .pointer_down => .down,
                .pointer_up => .up,
                else => return,
            };
            const input = if (phase == .down) value.pointer_down else value.pointer_up;
            const snapshot = window.pointerPressSnapshot(input.press, phase) catch unreachable;
            std.testing.expectEqual(if (phase == .down) self.expected_previous else 0, snapshot.previous_completed_sequence) catch unreachable;
            if (phase == .down) self.downs += 1 else self.ups += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = detach });
    const first = deliver(window, .down, .primary, sample(0));
    _ = deliver(window, .up, .primary, null);
    probe.expected_previous = first.sequence;
    const second = deliver(window, .down, .primary, sample(10));
    _ = deliver(window, .up, .primary, null);
    // This native observation has no public button and never emits Content.
    const item = record(window);
    const ignored = item.pointerBeginDown(fake.advancePointerOperation(item), null, null).?;
    try std.testing.expectEqual(@as(u64, 0), ignored.press.sequence);
    try std.testing.expectEqual(second.sequence, item.pointer_state.?.owner.last_sequence);
    probe.expected_previous = 0;
    _ = deliver(window, .down, .primary, sample(20));
    _ = deliver(window, .up, .primary, null);
    const consumed = item.pointerBeginDown(fake.advancePointerOperation(item), .secondary, sample(30)).?;
    try std.testing.expect(item.pointerFinish(consumed.operation, consumed.press.sequence, .secondary, .down, .consumed));
    _ = deliver(window, .down, .primary, sample(40));
    _ = deliver(window, .up, .primary, null);
    try std.testing.expectEqual(@as(usize, 4), probe.downs);
    try std.testing.expectEqual(@as(usize, 4), probe.ups);
    try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(second, .down));
}

test "nested synthetic other-window native and close callbacks cannot borrow suspended ingress" {
    const Probe = struct {
        a: z.Window = undefined,
        b: z.Window = undefined,
        press: z.PointerPress = .{},
        nested: usize = 0,
        nested_native: bool = false,
        closes: usize = 0,
        diagnostics: usize = 0,
        keys: usize = 0,
        hits: usize = 0,
        fn stale(self: *@This()) void {
            std.testing.expectError(error.StalePointerInput, self.a.pointerPressSnapshot(self.press, .down)) catch unreachable;
        }
        fn nestedEvent(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale();
            if (self.nested_native) {
                _ = window.pointerPressSnapshot(value.pointer_down.press, .down) catch unreachable;
            } else std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(value.pointer_down.press, .down)) catch unreachable;
            self.nested += 1;
        }
        fn key(ptr: *anyopaque, _: z.Window, _: z.KeyInput) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale();
            self.keys += 1;
            return true;
        }
        fn hit(ptr: *anyopaque, _: z.Window, _: z.Point) z.WindowHit {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale();
            self.hits += 1;
            return .client;
        }
        fn close(ptr: *anyopaque, _: z.Window, _: z.CloseReason) z.CloseDecision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale();
            self.closes += 1;
            return .cancel;
        }
        fn diagnostic(ptr: *anyopaque, _: z.diagnostics.Diagnostic) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale();
            self.diagnostics += 1;
        }
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            if (value != .pointer_down) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.press = value.pointer_down.press;
            _ = window.pointerPressSnapshot(self.press, .down) catch unreachable;
            record(self.b).emit(.{ .pointer_down = value.pointer_down });
            self.nested_native = true;
            _ = deliver(self.b, .down, .primary, sample(0));
            self.nested_native = false;
            const native = self.b.beginNativeCallback().?;
            self.stale();
            native.end();
            const app_native = window.app.beginNativeCallback();
            self.stale();
            app_native.end();
            std.testing.expectEqual(z.CloseResult.cancelled, self.b.requestClose() catch unreachable) catch unreachable;
            _ = record(window).keyInput(.{ .key = .f24 });
            _ = self.b.hitTest(.{ .x = 50, .y = 50 }) catch unreachable;
            window.app.report(.{ .domain = .core, .operation = .window_update });
            // Returning from independent callbacks restores the original frame,
            // while its actual operation is still checked by the getter.
            _ = window.pointerPressSnapshot(self.press, .down) catch unreachable;
        }
    };
    var probe: Probe = .{};
    const app = try z.App.initWithOptions(std.testing.allocator, .{ .diagnostics_sink = .{ .context = &probe, .emit = Probe.diagnostic } });
    defer app.deinit();
    probe.a = try app.createWindow(.{ .native_pointer_clicks = true });
    probe.b = try app.createWindow(.{ .native_pointer_clicks = true, .on_close = .{ .context = &probe, .request = Probe.close }, .decoration = .custom, .resize_border = 0, .hit_test = .{ .context = &probe, .query = Probe.hit } });
    try probe.a.setContent(.{ .context = &probe, .event = Probe.event, .detach = detach, .key_input = Probe.key });
    try probe.b.setContent(.{ .context = &probe, .event = Probe.nestedEvent, .detach = detach });
    _ = deliver(probe.a, .down, .primary, sample(1));
    try std.testing.expectEqual(@as(usize, 2), probe.nested);
    try std.testing.expectEqual(@as(usize, 1), probe.closes);
    try std.testing.expectEqual(@as(usize, 1), probe.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), probe.keys);
    try std.testing.expectEqual(@as(usize, 1), probe.hits);
}

test "actual adapter operation defeats stale native tickets and nested old finalizers" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const item = record(window);
    const scope = item.enterNative();
    defer scope.end();
    const first_op = fake.advancePointerOperation(item);
    try std.testing.expect(item.pointerBeginDown(first_op + 100, .primary, sample(0)) == null);
    const first = item.pointerBeginDown(first_op, .primary, sample(0)).?;
    const next_op = fake.advancePointerOperation(item);
    const next = item.pointerBeginDown(next_op, .primary, sample(1)).?;
    try std.testing.expect(!item.pointerFinish(first_op, first.press.sequence, .primary, .down, .denied));
    try std.testing.expect(item.pointerFinish(next_op, next.press.sequence, .primary, .down, .delivered));
    item.pointerRevoke(first_op, true);
    try std.testing.expectEqual(@as(u64, 1), item.pointerDomain());
    const up_op = fake.advancePointerOperation(item);
    const up = item.pointerBeginUp(up_op, .primary).?;
    try std.testing.expectEqual(next.press.sequence, up.press.sequence);
    try std.testing.expect(item.pointerFinish(up_op, up.press.sequence, .primary, .up, .delivered));
}

test "restoring a suspended native frame cannot restore an old operation" {
    const Probe = struct {
        depth: usize = 0,
        old: z.PointerPress = .{},
        calls: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
            if (value != .pointer_down) return;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            _ = window.pointerPressSnapshot(value.pointer_down.press, .down) catch unreachable;
            if (self.depth == 0) {
                self.depth = 1;
                self.old = value.pointer_down.press;
                _ = deliver(window, .down, .secondary, sample(1));
                std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(self.old, .down)) catch unreachable;
            } else std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(self.old, .down)) catch unreachable;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = detach });
    _ = deliver(window, .down, .primary, sample(0));
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(deliver(window, .up, .secondary, null).sequence != 0);
}

test "disabled permission and domain changes revoke before callbacks without reviving a pair" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const old = deliver(window, .down, .primary, sample(0));
    try std.testing.expectEqual(old.sequence, record(window).pointerSequenceHighWater().?);
    try window.perform(.disable);
    try window.perform(.enable);
    try std.testing.expectEqual(old.sequence, record(window).pointerSequenceHighWater().?);
    try std.testing.expectEqual(@as(u64, 0), deliver(window, .up, .primary, null).sequence);
    const item = record(window);
    const previous = item.pointerDomain();
    _ = item.invalidatePointer(true);
    try std.testing.expectEqual(previous + 1, item.pointerDomain());
    item.native.pointer_operation.value = std.math.maxInt(u64) - 1;
    const retired = fake.advancePointerOperation(item);
    item.pointerRevoke(retired, false);
    try std.testing.expect(item.pointerBeginDown(retired, .primary, sample(0)) == null);
    try std.testing.expectEqual(retired, fake.advancePointerOperation(item));
}

test "pointer opt-in allocation is absent by default and OOM construction rolls back" {
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(failure.allocator());
    defer app.deinit();
    const plain = try app.createWindow(.{});
    try std.testing.expect(!record(plain).pointerEnabled());
    try std.testing.expect(record(plain).pointerSequenceHighWater() == null);
    try std.testing.expectError(error.UnsupportedCapability, plain.pointerPressSnapshot(.{}, .down));
    _ = try plain.destroy();
    // Warmed registry slot makes the next allocations the title copy and the
    // record, followed by exactly the optional raw owner. Its failed
    // allocation takes no context.
    const before = failure.alloc_index;
    failure.fail_index = before + 2;
    try std.testing.expectError(error.OutOfMemory, app.createWindow(.{ .native_pointer_clicks = true }));
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    failure.fail_index = std.math.maxInt(usize);
    const enabled = try app.createWindow(.{ .native_pointer_clicks = true });
    try std.testing.expect(record(enabled).pointerEnabled());
    try std.testing.expectEqual(@as(u64, 0), record(enabled).pointerSequenceHighWater().?);
    try std.testing.expectEqual(@as(usize, 3), failure.alloc_index - before - 2);
    _ = try enabled.destroy();
}

test "optional owner allocator callbacks may stop construction and reenter final free" {
    const Allocator = struct {
        app: ?*z.App = null,
        armed: bool = false,
        stop_on_alloc: bool = false,
        allocations: usize = 0,
        state: ?[*]u8 = null,
        replacement: ?z.Window = null,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const bytes = std.testing.allocator.rawAlloc(len, alignment, address) orelse return null;
            if (self.armed) {
                self.allocations += 1;
                if (self.allocations == 2) {
                    self.armed = false;
                    self.state = bytes;
                    if (self.stop_on_alloc) self.app.?.quit();
                }
            }
            return bytes;
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.state == bytes.ptr) {
                self.state = null;
                const native = self.app.?.beginNativeCallback();
                if (!self.stop_on_alloc) self.replacement = self.app.?.createWindow(.{ .native_pointer_clicks = true }) catch unreachable;
                native.end();
            }
            std.testing.allocator.rawFree(bytes, alignment, address);
        }
    };
    for ([_]bool{ true, false }) |stop| {
        var allocator: Allocator = .{ .stop_on_alloc = stop };
        const app = try z.App.init(allocator.allocator());
        allocator.app = app;
        defer app.deinit();
        const warm = try app.createWindow(.{});
        _ = try warm.destroy();
        allocator.armed = true;
        if (stop) {
            try std.testing.expectError(error.CreateWindowFailed, app.createWindow(.{ .native_pointer_clicks = true }));
            try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
        } else {
            const old = try app.createWindow(.{ .native_pointer_clicks = true });
            _ = try old.destroy();
            const next = allocator.replacement.?;
            try std.testing.expect(old.isClosed());
            try std.testing.expect(old.key.generation != next.key.generation);
            try std.testing.expect(record(next).pointerEnabled());
            try std.testing.expectEqual(@as(usize, 1), app.resourceStats().allocated_records);
            _ = try next.destroy();
        }
    }
}

test "closing inside native pointer callback retains raw state until final callback pin" {
    const Probe = struct {
        detach_count: usize = 0,
        fn event(_: *anyopaque, window: z.Window, value: z.Event) void {
            if (value != .pointer_down) return;
            std.testing.expectEqual(z.CloseResult.deferred, window.destroy() catch unreachable) catch unreachable;
            std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(value.pointer_down.press, .down)) catch unreachable;
            std.testing.expectEqual(@as(usize, 1), window.app.resourceStats().allocated_records) catch unreachable;
        }
        fn detached(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.detach_count += 1;
        }
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detached });
    _ = deliver(window, .down, .primary, sample(0));
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), probe.detach_count);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "private owner transition lookup and snapshot button do not issue identity" {
    var owner: raw.Owner = .{};
    const down = owner.beginDown(1, .forward, sample(0)).?;
    try std.testing.expect(owner.lookup(1, down.press.sequence, .back, .down) == null);
    try std.testing.expect(owner.lookup(2, down.press.sequence, .forward, .down) == null);
    const looked = owner.lookup(1, down.press.sequence, .forward, .down).?;
    try std.testing.expectEqual(z.PointerButton.forward, (try owner.snapshot(looked, down.press, .down)).button);
    try std.testing.expectEqual(down.press.sequence, owner.last_sequence);
}

test "App native callback scope is a teardown pin after stop without reopening ingress" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{ .native_pointer_clicks = true });
    const native = app.beginNativeCallback();
    try std.testing.expectEqual(@as(usize, 1), app.activity_depth);
    app.quit();
    try std.testing.expectError(error.Closed, app.createWindow(.{}));
    try std.testing.expectError(error.Busy, app.finishShutdown());
    native.end();
    try std.testing.expectEqual(@as(usize, 0), app.activity_depth);
    try app.finishShutdown();
    try std.testing.expect(window.beginNativeCallback() == null);
    const stopped = app.beginNativeCallback();
    try std.testing.expectEqual(@as(usize, 1), app.activity_depth);
    try std.testing.expectError(error.Closed, app.createWindow(.{}));
    stopped.end();
    try std.testing.expectEqual(@as(usize, 0), app.activity_depth);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
