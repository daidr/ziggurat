const std = @import("std");
const z = @import("root.zig");

const Probe = struct {
    action: enum { none, nested, rebind, composition, close } = .none,
    calls: usize = 0,
    unbound: usize = 0,
    failure: ?anyerror = null,
    fn event(ptr: *anyopaque, window: z.Window, value: z.Event) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        if (value != .text_preedit_cancel) return;
        self.calls += 1;
        self.checked(window) catch |err| {
            self.failure = err;
        };
    }
    fn checked(self: *Probe, window: z.Window) !void {
        try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
        try std.testing.expect(!window.app.windows.get(window.key).?.native.composing);
        switch (self.action) {
            .none => {},
            .nested => try std.testing.expectError(error.Busy, window.setTextInputMode(.system)),
            .rebind => _ = try window.setTextClient(self.client()),
            .composition => {
                const record = window.app.windows.get(window.key).?;
                record.native.composing = true;
                record.native.composition_epoch += 1;
            },
            .close => _ = try window.destroy(),
        }
    }
    fn detach(_: *anyopaque) void {}
    fn client(self: *Probe) z.TextClient {
        return .{ .context = self, .owner = std.Thread.getCurrentId(), .read = read, .change = change, .unbound = removed };
    }
    fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
        return error.CapacityExceeded;
    }
    fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
        return .rejected;
    }
    fn removed(ptr: *anyopaque, _: z.Window, _: z.text.UnbindReason) void {
        const self: *Probe = @ptrCast(@alignCast(ptr));
        self.unbound += 1;
    }
};

test "text mode selection is explicit allocation-free and idempotent" {
    var fault = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const app = try z.App.init(fault.allocator());
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    const initial = try window.textInputStamp();
    fault.fail_index = fault.alloc_index;
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.system));
    try std.testing.expectEqual(initial, try window.textInputStamp());
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
    const selected = try window.textInputStamp();
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, selected.mode);
    try std.testing.expectEqual(initial.epoch + 1, selected.epoch);
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(selected, try window.textInputStamp());
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.system));
    try std.testing.expectEqual(fault.fail_index, fault.alloc_index);
}

test "text mode cancel callback cannot overwrite a new client composition or closure" {
    for ([_]@TypeOf(@as(Probe, .{}).action){ .none, .nested, .rebind, .composition, .close }) |action| {
        const app = try z.App.init(std.testing.allocator);
        defer app.deinit();
        const window = try app.createWindow(.{});
        defer {
            _ = window.destroy() catch unreachable;
            app.dispatch() catch unreachable;
        }
        var probe: Probe = .{ .action = action };
        try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
        app.native.emit_text_cancel = true;
        app.windows.get(window.key).?.native.composing = true;
        const result = try window.setTextInputMode(.keyboard_compose);
        app.native.emit_text_cancel = false;
        if (probe.failure) |err| return err;
        try std.testing.expectEqual(@as(usize, 1), probe.calls);
        const applied = action == .none or action == .nested;
        try std.testing.expectEqual(if (applied) z.TextInputModeResult.applied else .superseded, result);
        if (!window.isClosed()) try std.testing.expectEqual(if (applied) z.TextInputMode.keyboard_compose else .system, try window.textInputMode());
        if (action == .rebind) try std.testing.expect(try window.hasTextClient());
        if (action == .composition) try std.testing.expect(app.windows.get(window.key).?.native.composing);
    }
}

test "text mode failures preserve actual selection and do not undo cancellation" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer {
        _ = window.destroy() catch unreachable;
        app.dispatch() catch unreachable;
    }
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    app.native.emit_text_cancel = true;
    app.native.fail_text_cancel = true;
    try std.testing.expectError(error.CompositionQueryFailed, window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    app.native.fail_update = true;
    try std.testing.expectError(error.WindowUpdateFailed, window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(z.TextInputMode.system, try window.textInputMode());
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    app.native.emit_text_cancel = false;
    app.windows.get(window.key).?.text_input_epoch = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, window.setTextInputMode(.keyboard_compose));
    try std.testing.expectEqual(z.TextInputModeResult.applied, try window.setTextInputMode(.system));
}

test "creation selects keyboard compose without changing the default" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const first = try app.createWindow(.{ .text_input_mode = .keyboard_compose });
    const second = try app.createWindow(.{});
    try std.testing.expectEqual(z.TextInputMode.keyboard_compose, try first.textInputMode());
    try std.testing.expectEqual(z.TextInputMode.system, try second.textInputMode());
    _ = try first.destroy();
    _ = try second.destroy();
    try app.dispatch();
}
