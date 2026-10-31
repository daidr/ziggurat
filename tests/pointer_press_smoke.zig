const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const c = @import("ziggurat_c_win32");

const position: c.LPARAM = 20 | (20 << 16);
const Mode = enum { plain, queued, nested_queue, sticky_unknown, capture_theft, nested_up, up_capture, shadow, disable, service_consumed, close };
const Entry = struct { phase: z.PointerPhase, input: z.PointerButtonInput, snapshot: ?z.PointerPressSnapshot };
const Fixture = struct {
    app: *z.App = undefined,
    window: z.Window = undefined,
    other: z.Window = undefined,
    mode: Mode = .plain,
    enabled: bool = true,
    entries: [64]Entry = undefined,
    count: usize = 0,
    other_buttons: usize = 0,
    depth: usize = 0,
    expected_events: usize = 0,
    queue_mode: bool = false,
    cancel_count: usize = 0,
    detach_count: usize = 0,
    close_count: usize = 0,
    service_count: usize = 0,
    shadow_count: usize = 0,
    consumed_tick: ?u32 = null,
    consumed_point: c.DWORD = 0,
    failure: ?anyerror = null,

    fn init(self: *Fixture, allocator: std.mem.Allocator, enabled: bool, mode: Mode) !void {
        self.* = .{ .enabled = enabled, .mode = mode };
        self.app = try z.App.initWithOptions(allocator, .{ .icon_policy = .disabled, .diagnostics_sink = .{ .context = self, .emit = diagnostic } });
        errdefer self.app.deinit();
        self.window = try self.app.createWindow(.{ .native_pointer_clicks = enabled, .width = 240, .height = 120, .on_closed = .{ .context = self, .notify = closed } });
        self.other = try self.app.createWindow(.{ .native_pointer_clicks = enabled, .width = 240, .height = 120 });
        try self.window.setContent(.{ .context = self, .event = event, .detach = detached });
        try self.other.setContent(.{ .context = self, .event = shadowEvent, .detach = noop });
        _ = c.SetFocus(self.hwnd());
        if (c.GetFocus() != self.hwnd()) return error.ThreadFocusUnavailable;
        if (mode == .up_capture) std.debug.print("up_capture_init enabled={} focus=confirmed capture_null={}\n", .{ enabled, c.GetCapture() == null });
    }
    fn deinit(self: *Fixture) void {
        if (!self.window.isClosed()) _ = self.window.destroy() catch unreachable;
        if (!self.other.isClosed()) _ = self.other.destroy() catch unreachable;
        self.app.dispatch() catch unreachable;
        std.debug.assert(self.app.resourceStats().allocated_records == 0);
        self.app.deinit();
    }
    fn hwnd(self: *const Fixture) c.HWND {
        return @ptrCast(self.window.nativeHandle());
    }
    fn item(self: *Fixture) *z.WindowRecord {
        return self.app.windows.get(self.window.key).?;
    }
    fn send(self: *Fixture, message: c.UINT, wp: c.WPARAM) void {
        _ = c.SendMessageW(self.hwnd(), message, wp, position);
    }
    fn pair(self: *Fixture) void {
        self.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
        self.send(c.WM_LBUTTONUP, 0);
    }
    fn post(self: *Fixture, message: c.UINT, wp: c.WPARAM) !void {
        if (c.PostMessageW(self.hwnd(), message, wp, position) == 0) return error.PostFailed;
    }
    fn check(self: *Fixture) !void {
        if (self.failure) |err| return err;
    }
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.failure = value.err orelse error.Diagnostic;
    }
    fn noop(_: *anyopaque) void {}
    fn detached(ptr: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.detach_count += 1;
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.close_count += 1;
    }
    fn shadowEvent(ptr: *anyopaque, _: z.Window, _: z.Event) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        if (self.mode != .shadow) return;
        const receipt = self.entries[self.count - 1].input.press;
        std.testing.expectError(error.StalePointerInput, self.window.pointerPressSnapshot(receipt, .down)) catch |err| {
            self.failure = err;
        };
        self.shadow_count += 1;
    }
    fn service(ptr: *anyopaque, _: z.Window, message: u32, _: usize, lp: isize) ?isize {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        if (self.mode == .nested_queue and (message == c.WM_CAPTURECHANGED or message == c.WM_LBUTTONDOWN)) {
            std.debug.print("nested_native message={s} lp=0x{x} lp_self={} capture_owned={} op={d} count={d}\n", .{ if (message == c.WM_CAPTURECHANGED) @as([]const u8, "CAPTURECHANGED") else "LBUTTONDOWN", @as(usize, @bitCast(lp)), @as(usize, @bitCast(lp)) == @intFromPtr(self.hwnd()), c.GetCapture() == self.hwnd(), self.item().pointerOperation(), self.count });
        }
        if (message != c.WM_LBUTTONDOWN or self.mode != .service_consumed) return null;
        self.service_count += 1;
        self.consumed_tick = @bitCast(c.GetMessageTime());
        self.consumed_point = c.GetMessagePos();
        return 0;
    }
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Fixture = @ptrCast(@alignCast(ptr));
        self.receive(window, value) catch |err| {
            self.failure = err;
            self.app.quit();
        };
    }
    fn receive(self: *Fixture, window: z.Window, value: z.Event) !void {
        if (value == .cancel_input) {
            self.cancel_count += 1;
            return;
        }
        const phase: z.PointerPhase = switch (value) {
            .pointer_down => .down,
            .pointer_up => .up,
            else => return,
        };
        if (self.count == self.entries.len) return error.CapacityExceeded;
        const input = if (phase == .down) value.pointer_down else value.pointer_up;
        if (input.button != .primary) {
            // Other buttons reach content without joining the primary history.
            if (self.enabled and input.press.sequence != 0) try std.testing.expectEqual(input.button, (try window.pointerPressSnapshot(input.press, phase)).button);
            self.other_buttons += 1;
            return;
        }
        const snapshot: ?z.PointerPressSnapshot = if (self.enabled and input.press.sequence != 0) try window.pointerPressSnapshot(input.press, phase) else null;
        if (snapshot) |original| {
            try std.testing.expectEqual(input.button, original.button);
            try std.testing.expectEqual(input.press.qualified, original.timing != null);
            try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, if (phase == .down) .up else .down));
        } else try std.testing.expectEqual(@as(u64, 0), input.press.sequence);
        const index = self.count;
        self.entries[index] = .{ .phase = phase, .input = input, .snapshot = snapshot };
        self.count += 1;
        const is_queued = self.queue_mode and self.depth == 0;
        if (is_queued) {
            const original = snapshot.?.timing orelse return error.QueuedTimingMissing;
            // These are the original currently dispatched message's fields,
            // not a later live cursor or current clock sample.
            if (phase == .down or self.mode == .service_consumed) {
                const tick: u32 = if (phase == .down) @bitCast(c.GetMessageTime()) else self.consumed_tick.?;
                const bits = if (phase == .down) c.GetMessagePos() else self.consumed_point;
                try std.testing.expectEqual(tick, original.tick_ms);
                const x: i16 = @bitCast(@as(u16, @truncate(bits)));
                const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
                try std.testing.expectEqual(@as(f64, @floatFromInt(x)), original.position.x);
                try std.testing.expectEqual(@as(f64, @floatFromInt(y)), original.position.y);
            } else {
                var paired = false;
                for (self.entries[0..index]) |entry| if (entry.phase == .down and entry.input.press.sequence == input.press.sequence) {
                    try std.testing.expectEqualDeep(entry.snapshot.?.timing.?, original);
                    paired = true;
                    break;
                };
                try std.testing.expect(paired);
            }
        } else if (snapshot) |original| try std.testing.expect(original.timing == null);

        if (self.depth == 0) switch (self.mode) {
            .nested_queue => if (phase == .down) {
                const before_count = self.count;
                std.debug.print("nested_queue_before count={d} op={d} capture_owned={} cancels={d}\n", .{ self.count, self.item().pointerOperation(), c.GetCapture() == self.hwnd(), self.cancel_count });
                self.depth = 1;
                self.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
                self.depth = 0;
                std.debug.print("nested_queue_after count={d} op={d} capture_owned={} cancels={d} phase={s}\n", .{ self.count, self.item().pointerOperation(), c.GetCapture() == self.hwnd(), self.cancel_count, @tagName(self.app.phase) });
                if (self.count != before_count + 1) return error.ExpectedNestedDownDelivery;
                const nested_snapshot = self.entries[index + 1].snapshot orelse return error.ExpectedNestedDownSnapshot;
                if (nested_snapshot.timing != null) return error.NestedReusedQueueTiming;
                try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .down));
            },
            .sticky_unknown => if (phase == .down) {
                // Direct, unmatched native motion has no authoritative raw
                // sample, so it conservatively revokes only continuation.
                self.send(c.WM_MOUSEMOVE, c.MK_LBUTTON);
                const after = try window.pointerPressSnapshot(input.press, .down);
                try std.testing.expect(!after.continuation_eligible);
                try std.testing.expectEqual(input.press.window_count, self.entries[index].input.press.window_count);
            },
            .capture_theft => if (phase == .down) {
                _ = c.SetCapture(@ptrCast(self.other.nativeHandle()));
                try std.testing.expect(c.GetCapture() == self.other.nativeHandle());
                try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .down));
            },
            .nested_up => if (phase == .up) {
                self.depth = 1;
                self.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
                self.depth = 0;
                try std.testing.expect(c.GetCapture() == self.hwnd());
                try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .up));
            },
            .up_capture => if (phase == .up) {
                try std.testing.expectEqual(@as(u64, 0), input.press.sequence);
                try std.testing.expect(c.GetCapture() == null);
                _ = c.SetCapture(self.hwnd());
                const acquired = c.GetCapture() == self.hwnd();
                std.debug.print("up_capture_content enabled={} receipt={d} acquired={}\n", .{ self.enabled, input.press.sequence, acquired });
                if (!acquired) return error.ContentCaptureAcquireFailed;
            },
            .shadow => if (phase == .down) {
                self.app.windows.get(self.other.key).?.emit(.{ .pointer_down = input });
                _ = c.SendMessageW(@ptrCast(self.other.nativeHandle()), c.WM_PAINT, 0, 0);
                _ = try window.pointerPressSnapshot(input.press, .down);
            },
            .disable => if (phase == .down) {
                try window.perform(.disable);
                try window.perform(.enable);
                try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .down));
            },
            .close => if (phase == .down) {
                try std.testing.expectEqual(z.CloseResult.deferred, try window.destroy());
                try std.testing.expectError(error.StalePointerInput, window.pointerPressSnapshot(input.press, .down));
                try std.testing.expectEqual(@as(usize, 0), self.detach_count);
            },
            else => {},
        };
        if (self.expected_events != 0 and self.count == self.expected_events) self.app.quit();
    }
};

fn synchronous(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, .plain);
    defer fixture.deinit();
    const before = fixture.item().pointerOperation();
    fixture.pair();
    try fixture.check();
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
    try std.testing.expect(fixture.entries[0].input.press.sequence != 0);
    try std.testing.expectEqual(fixture.entries[0].input.press.sequence, fixture.entries[1].input.press.sequence);
    try std.testing.expectEqual(@as(u8, 1), fixture.entries[0].input.press.window_count);
    try std.testing.expect(fixture.item().pointerOperation() > before);
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressSnapshot(fixture.entries[0].input.press, .down));

    // Observation includes every button; content sees only the four known ones.
    for ([_]struct { down: c.UINT, up: c.UINT, wp: c.WPARAM, button: z.PointerButton }{
        .{ .down = c.WM_RBUTTONDOWN, .up = c.WM_RBUTTONUP, .wp = 0, .button = .secondary },
        .{ .down = c.WM_MBUTTONDOWN, .up = c.WM_MBUTTONUP, .wp = 0, .button = .middle },
        .{ .down = c.WM_XBUTTONDOWN, .up = c.WM_XBUTTONUP, .wp = @as(usize, c.XBUTTON1) << 16, .button = .back },
        .{ .down = c.WM_XBUTTONDOWN, .up = c.WM_XBUTTONUP, .wp = @as(usize, c.XBUTTON2) << 16, .button = .forward },
    }) |button| {
        const old_operation = fixture.item().pointerOperation();
        const old_sequence = fixture.item().pointer_state.?.owner.last_sequence;
        fixture.send(button.down, button.wp);
        try std.testing.expect(fixture.item().pointerOperation() > old_operation);
        try std.testing.expectEqual(old_sequence + 1, fixture.item().pointer_state.?.owner.last_sequence);
        fixture.send(button.up, button.wp);
    }
    const sequence = fixture.item().pointer_state.?.owner.last_sequence;
    fixture.send(c.WM_XBUTTONDOWN, @as(usize, 3) << 16);
    fixture.send(c.WM_XBUTTONUP, @as(usize, 3) << 16);
    try std.testing.expectEqual(sequence, fixture.item().pointer_state.?.owner.last_sequence);
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
    try std.testing.expectEqual(@as(usize, 8), fixture.other_buttons);
    try fixture.check();
}

fn heldOutsideCallback(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, .plain);
    defer fixture.deinit();
    fixture.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
    const press = fixture.entries[fixture.count - 1].input.press;
    try fixture.window.pointerPressHeld(press, .primary);
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressSnapshot(press, .down));
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressHeld(press, .secondary));
    fixture.send(c.WM_LBUTTONUP, 0);
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressHeld(press, .primary));
    fixture.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
    const cancelled = fixture.entries[fixture.count - 1].input.press;
    try fixture.window.pointerPressHeld(cancelled, .primary);
    fixture.send(c.WM_CANCELMODE, 0);
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressHeld(cancelled, .primary));
    fixture.send(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
    const unfocused = fixture.entries[fixture.count - 1].input.press;
    try fixture.window.pointerPressHeld(unfocused, .primary);
    _ = c.SetFocus(fixture.other.nativeHandle());
    try std.testing.expectError(error.StalePointerInput, fixture.window.pointerPressHeld(unfocused, .primary));
    try fixture.check();
    std.debug.print("pointer held Windows: outside callback succeeds; active snapshot/other button/up/cancel/native focus loss rejected\n", .{});
}

fn queued(allocator: std.mem.Allocator, nested: bool) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, if (nested) .nested_queue else .queued);
    defer fixture.deinit();
    fixture.expected_events = if (nested) 2 else 8;
    fixture.queue_mode = true;
    if (nested) try fixture.window.setService(.{ .context = &fixture, .message = Fixture.service, .native_destroying = Fixture.noop });
    if (nested) {
        try fixture.post(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
    } else {
        for (0..4) |_| {
            try fixture.post(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
            try fixture.post(c.WM_LBUTTONUP, 0);
        }
    }
    try fixture.app.run();
    try fixture.check();
    try std.testing.expectEqual(fixture.expected_events, fixture.count);
    if (!nested) {
        for ([_]u8{ 1, 2, 3, 1 }, 0..) |count, i| {
            try std.testing.expectEqual(count, fixture.entries[i * 2].input.press.window_count);
            try std.testing.expectEqual(fixture.entries[i * 2].input.press.sequence, fixture.entries[i * 2 + 1].input.press.sequence);
        }
    }
}

fn reentry(allocator: std.mem.Allocator, mode: Mode) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, mode);
    defer fixture.deinit();
    if (mode == .service_consumed) try fixture.window.setService(.{ .context = &fixture, .message = Fixture.service, .native_destroying = Fixture.noop });
    if (mode == .sticky_unknown or mode == .service_consumed) {
        fixture.queue_mode = true;
        fixture.expected_events = if (mode == .sticky_unknown) 2 else 1;
        try fixture.post(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
        try fixture.post(c.WM_LBUTTONUP, 0);
        try fixture.app.run();
    } else fixture.pair();
    try fixture.check();
    if (mode == .close) {
        try fixture.app.dispatch();
        try std.testing.expectEqual(@as(usize, 1), fixture.detach_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.close_count);
    } else if (mode == .nested_up) {
        // Old up's release tail must leave nested new capture alone.
        try std.testing.expect(c.GetCapture() == fixture.hwnd());
        fixture.mode = .plain;
        fixture.send(c.WM_LBUTTONUP, 0);
    } else if (mode == .capture_theft) {
        try std.testing.expect(c.GetCapture() == fixture.other.nativeHandle());
        _ = c.ReleaseCapture();
    } else if (mode == .sticky_unknown) {
        try std.testing.expectEqual(@as(usize, 2), fixture.count);
        try std.testing.expect(fixture.entries[0].snapshot.?.continuation_eligible);
        try std.testing.expect(!fixture.entries[1].snapshot.?.continuation_eligible);
        try std.testing.expectEqual(fixture.entries[0].input.press.sequence, fixture.entries[1].input.press.sequence);
    } else if (mode == .service_consumed) {
        try std.testing.expectEqual(@as(usize, 1), fixture.service_count);
        try std.testing.expectEqual(@as(usize, 1), fixture.count);
        try std.testing.expectEqual(@as(u8, 1), fixture.entries[0].input.press.window_count);
        try std.testing.expect(!fixture.entries[0].snapshot.?.continuation_eligible);
    } else if (mode == .shadow) try std.testing.expect(fixture.shadow_count >= 2);
}

fn observedButtons(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, .queued);
    defer fixture.deinit();
    fixture.queue_mode = true;
    fixture.expected_events = 20;
    for ([_]struct { down: c.UINT, up: c.UINT, wp: c.WPARAM }{
        .{ .down = c.WM_RBUTTONDOWN, .up = c.WM_RBUTTONUP, .wp = 0 },
        .{ .down = c.WM_MBUTTONDOWN, .up = c.WM_MBUTTONUP, .wp = 0 },
        .{ .down = c.WM_XBUTTONDOWN, .up = c.WM_XBUTTONUP, .wp = @as(usize, c.XBUTTON1) << 16 },
        .{ .down = c.WM_XBUTTONDOWN, .up = c.WM_XBUTTONUP, .wp = @as(usize, c.XBUTTON2) << 16 },
        .{ .down = c.WM_XBUTTONDOWN, .up = c.WM_XBUTTONUP, .wp = @as(usize, 3) << 16 },
    }) |button| {
        try fixture.post(c.WM_CANCELMODE, 0);
        try fixture.post(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
        try fixture.post(c.WM_LBUTTONUP, 0);
        try fixture.post(button.down, button.wp);
        try fixture.post(button.up, button.wp);
        try fixture.post(c.WM_LBUTTONDOWN, c.MK_LBUTTON);
        try fixture.post(c.WM_LBUTTONUP, 0);
    }
    try fixture.app.run();
    try fixture.check();
    try std.testing.expectEqual(@as(usize, 20), fixture.count);
    try std.testing.expectEqual(@as(usize, 8), fixture.other_buttons);
    for (fixture.entries[0..fixture.count]) |entry| try std.testing.expectEqual(@as(u8, 1), entry.input.press.window_count);
}

fn disabledAndExhausted(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, false, .plain);
    defer fixture.deinit();
    try std.testing.expect(fixture.item().pointer_state == null);
    fixture.pair();
    try fixture.check();
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
    try std.testing.expect(fixture.item().pointerOperation() >= 2);
    try std.testing.expectError(error.UnsupportedCapability, fixture.window.pointerPressSnapshot(.{}, .down));
    try std.testing.expectError(error.UnsupportedCapability, fixture.window.pointerPressHeld(.{}, .primary));
    fixture.item().native.pointer_operation.value = std.math.maxInt(u64) - 1;
    fixture.pair();
    try std.testing.expectEqual(std.math.maxInt(u64), fixture.item().pointerOperation());
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
}

fn sequenceExhausted(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, true, .plain);
    defer fixture.deinit();
    fixture.item().pointer_state.?.owner.last_sequence = std.math.maxInt(u64) - 1;
    fixture.pair();
    try fixture.check();
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
    try std.testing.expectEqual(@as(u64, 0), fixture.entries[0].input.press.sequence);
    try std.testing.expectEqual(@as(u64, 0), fixture.entries[1].input.press.sequence);
    try std.testing.expectEqual(std.math.maxInt(u64), fixture.item().pointer_state.?.owner.last_sequence);
}

fn unmatchedCapture(allocator: std.mem.Allocator, enabled: bool) !void {
    var fixture: Fixture = .{};
    try fixture.init(allocator, enabled, .up_capture);
    defer fixture.deinit();
    try std.testing.expect(c.GetCapture() == null);
    std.debug.print("up_capture_before enabled={} capture_null=confirmed\n", .{enabled});
    // This is a real native primary up with no paired down and no entry owner.
    // Ordinary Content may acquire capture. The old up must not release it.
    fixture.send(c.WM_LBUTTONUP, 0);
    const preserved = c.GetCapture() == fixture.hwnd();
    std.debug.print("up_capture_after enabled={} events={d} preserved={}\n", .{ enabled, fixture.count, preserved });
    try fixture.check();
    try std.testing.expectEqual(@as(usize, 1), fixture.count);
    if (!preserved) return error.ExpectedUpCapturePreserved;
    _ = c.ReleaseCapture();
}

fn isolatedWindows(up_capture: bool) !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.PointerPress.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    const suffix: []const u16 = if (up_capture) std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child up-capture") else std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0 or exit_code != 0) return error.TestProcessFailed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = try zio.argsAlloc(std.heap.page_allocator, init.args);
    defer zio.argsFree(std.heap.page_allocator, args);
    if (args.len == 1) return isolatedWindows(false);
    if (args.len == 2 and std.mem.eql(u8, args[1], "up-capture")) return isolatedWindows(true);
    if ((args.len != 2 and args.len != 3) or !std.mem.eql(u8, args[1], "--desktop-child")) return error.InvalidArgument;
    const only_up_capture = args.len == 3;
    if (only_up_capture and !std.mem.eql(u8, args[2], "up-capture")) return error.InvalidArgument;
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    if (only_up_capture) {
        try unmatchedCapture(allocator, true);
        try unmatchedCapture(allocator, false);
        std.debug.print("pointer up-capture: enabled/default unmatched native up preserves capture acquired in Content; resources=0\n", .{});
        return;
    }
    try synchronous(allocator);
    try heldOutsideCallback(allocator);
    try queued(allocator, false);
    try queued(allocator, true);
    try observedButtons(allocator);
    for ([_]Mode{ .sticky_unknown, .capture_theft, .nested_up, .shadow, .disable, .service_consumed, .close }) |mode| try reentry(allocator, mode);
    try disabledAndExhausted(allocator);
    try sequenceExhausted(allocator);
    try unmatchedCapture(allocator, true);
    try unmatchedCapture(allocator, false);
    std.debug.print("pointer raw Windows: 16 native groups, queue/original fields, one-use/null timing, held outside callback, five button breaks, capture/reentry, permission/close/exhaustion; no UI semantic claim\n", .{});
}
