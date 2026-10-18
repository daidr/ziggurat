const std = @import("std");
const z = @import("root.zig");
const Client = struct {
    token: ?z.TextClientToken = null,
    unbound: usize = 0,
    reason: ?z.text.UnbindReason = null,
    reenter: bool = false,
    close_read: bool = false,
    raw_close: bool = false,
    blur_read: bool = false,
    close_change: bool = false,
    change_result: z.text.ChangeResult = .applied,
    close_unbind: bool = false,
    blur_unbind: bool = false,
    rebind: ?*Client = null,
    fn descriptor(self: *Client) z.TextClient {
        return .{ .context = self, .owner = std.Thread.getCurrentId(), .read = read, .change = change, .unbound = unbind };
    }
    fn read(ptr: *anyopaque, window: z.Window, storage: []u8) !z.text.Snapshot {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (self.reenter) {
            try std.testing.expectError(error.Busy, window.clearTextClient(self.token.?));
            try std.testing.expectError(error.Busy, window.setTextClient(self.descriptor()));
            var nested: [8]u8 = undefined;
            try std.testing.expectError(error.Busy, window.readTextClient(self.token.?, &nested));
        }
        if (self.close_read) _ = try window.destroy();
        if (self.raw_close) try @import("platform/testing.zig").destroy(window.app.windows.get(window.key).?);
        if (self.blur_read) window.app.windows.get(window.key).?.emit(.{ .focus = false });
        if (storage.len < 5) return error.CapacityExceeded;
        @memcpy(storage[0..5], "😀x");
        return .{ .range = .{ .start = 30, .end = 33 }, .selection = .{ .anchor = 32, .caret = 33 }, .revision = 4, .bytes = 5 };
    }
    fn change(ptr: *anyopaque, window: z.Window, _: z.text.Change) !z.text.ChangeResult {
        const self: *Client = @ptrCast(@alignCast(ptr));
        if (self.close_change) _ = try window.destroy();
        return self.change_result;
    }
    fn unbind(ptr: *anyopaque, window: z.Window, reason: z.text.UnbindReason) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.unbound += 1;
        self.reason = reason;
        if (reason == .focus_lost) if (self.rebind) |next| {
            next.token = window.setTextClient(next.descriptor()) catch unreachable;
        };
        if (self.blur_unbind) window.app.windows.get(window.key).?.emit(.{ .focus = false });
        if (self.close_unbind) _ = window.destroy() catch unreachable;
    }
};

test "native change rejection and supersession are explicit outcomes without replay" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var client: Client = .{ .change_result = .rejected };
    client.token = try window.setTextClient(client.descriptor());
    try std.testing.expectEqual(z.text.ChangeResult.rejected, try window.changeTextClient(client.token.?, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    client.change_result = .superseded;
    try std.testing.expectEqual(z.text.ChangeResult.superseded, try window.changeTextClient(client.token.?, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    client.change_result = .rejected;
    client.close_change = true;
    // Closure upgrades an unchanged-state rejection; it never acknowledges the
    // original request and does not turn expected supersession into an error.
    try std.testing.expectEqual(z.text.ChangeResult.superseded, try window.changeTextClient(client.token.?, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expect(window.isClosed());
    try std.testing.expectEqual(@as(usize, 0), client.unbound);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), client.unbound);
}

test "physical text client query is owner-only and independent of input eligibility" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    try std.testing.expect(!(try window.hasTextClient()));
    var client: Client = .{};
    client.token = try window.setTextClient(client.descriptor());
    try std.testing.expect(try window.hasTextClient());
    try window.perform(.disable);
    try std.testing.expect(window.textClientToken() == null);
    try std.testing.expect(try window.hasTextClient());
    try window.perform(.enable);
    const modal = try app.createWindow(.{ .owner = window, .modal = true });
    try modal.perform(.show);
    try std.testing.expect((try window.state()).modal_blocked);
    try std.testing.expect(window.textClientToken() == null);
    try std.testing.expect(try window.hasTextClient());
    const Other = struct {
        fn run(w: z.Window) void {
            std.testing.expectError(error.WrongThread, w.hasTextClient()) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Other.run, .{window});
    thread.join();
    try std.testing.expectEqual(@as(usize, 0), client.unbound);
    _ = try modal.destroy();
    _ = try window.destroy();
    try std.testing.expectError(error.Closed, window.hasTextClient());
}
test "text client generations, wrong thread, bounded reads and closing callbacks" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var old: Client = .{};
    old.token = try window.setTextClient(old.descriptor());
    var storage: [8]u8 = undefined;
    old.reenter = true;
    const snapshot = try window.readTextClient(old.token.?, &storage);
    try std.testing.expectEqual(@as(usize, 30), snapshot.range.start);
    try std.testing.expectError(error.CapacityExceeded, window.readTextClient(old.token.?, storage[0..1]));
    var replacement: Client = .{};
    replacement.token = try window.setTextClient(replacement.descriptor());
    try std.testing.expectEqual(z.text.UnbindReason.replaced, old.reason.?);
    try std.testing.expect(!(try window.clearTextClient(old.token.?)));
    const Other = struct {
        fn run(w: z.Window, token: z.TextClientToken) void {
            var bytes: [8]u8 = undefined;
            std.testing.expectError(error.WrongThread, w.readTextClient(token, &bytes)) catch unreachable;
            std.testing.expectError(error.WrongThread, w.clearTextClient(token)) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Other.run, .{ window, replacement.token.? });
    thread.join();
    replacement.close_read = true;
    try std.testing.expectError(error.StaleTextClient, window.readTextClient(replacement.token.?, &storage));
    try std.testing.expectEqual(@as(usize, 0), replacement.unbound);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), replacement.unbound);
    try std.testing.expectEqual(z.text.UnbindReason.closed, replacement.reason.?);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
test "text blur revokes before host rebind and stale unbind cannot clear replacement" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var old: Client = .{};
    old.token = try window.setTextClient(old.descriptor());
    var replacement: Client = .{};
    const Host = struct {
        fn event(ptr: *anyopaque, w: z.Window, ev: z.Event) void {
            const client: *Client = @ptrCast(@alignCast(ptr));
            if (ev == .focus and !ev.focus) client.token = w.setTextClient(client.descriptor()) catch unreachable;
        }
        fn detach(_: *anyopaque) void {}
    };
    try window.setContent(.{ .context = &replacement, .event = Host.event, .detach = Host.detach });
    app.windows.get(window.key).?.emit(.{ .focus = false });
    try std.testing.expectEqual(z.text.UnbindReason.focus_lost, old.reason.?);
    try std.testing.expectEqual(replacement.token.?.generation, window.textClientToken().?.generation);
    try std.testing.expect(!(try window.clearTextClient(old.token.?)));
    replacement.close_unbind = true;
    try std.testing.expect(try window.clearTextClient(replacement.token.?));
    try app.dispatch();
    try std.testing.expect(window.isClosed());
    try std.testing.expectEqual(@as(usize, 1), replacement.unbound);
}

test "raw destruction and reentrant blur never unbind a context still on the read stack" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var client: Client = .{ .raw_close = true };
    client.token = try window.setTextClient(client.descriptor());
    var storage: [8]u8 = undefined;
    try std.testing.expectError(error.StaleTextClient, window.readTextClient(client.token.?, &storage));
    try std.testing.expectEqual(@as(usize, 0), client.unbound);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), client.unbound);
    const replacement = try app.createWindow(.{});
    defer _ = replacement.destroy() catch unreachable;
    var blurred: Client = .{ .blur_read = true };
    blurred.token = try replacement.setTextClient(blurred.descriptor());
    try std.testing.expectError(error.StaleTextClient, replacement.readTextClient(blurred.token.?, &storage));
    try std.testing.expectEqual(@as(usize, 1), blurred.unbound);
    try std.testing.expectEqual(z.text.UnbindReason.focus_lost, blurred.reason.?);
}

test "replacement and clear consume blur raised by an unbinding callback" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var old: Client = .{ .blur_unbind = true };
    old.token = try window.setTextClient(old.descriptor());
    var next: Client = .{};
    try std.testing.expectError(error.FocusLost, window.setTextClient(next.descriptor()));
    try std.testing.expect(window.textClientToken() == null);
    next.token = try window.setTextClient(next.descriptor());
    var bytes: [8]u8 = undefined;
    _ = try window.readTextClient(next.token.?, &bytes);
    next.blur_unbind = true;
    try std.testing.expect(try window.clearTextClient(next.token.?));
    old.blur_unbind = false;
    old.token = try window.setTextClient(old.descriptor());
    _ = try window.readTextClient(old.token.?, &bytes);
}

test "closed unbinding is pinned, precedes detach and permits freeing its own context" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    var unbound_count: usize = 0;
    var detached: usize = 0;
    const Owned = struct {
        count: *usize,
        fn read(_: *anyopaque, _: z.Window, _: []u8) !z.text.Snapshot {
            return error.Unavailable;
        }
        fn change(_: *anyopaque, _: z.Window, _: z.text.Change) !z.text.ChangeResult {
            return .applied;
        }
        fn unbound(ptr: *anyopaque, w: z.Window, reason: z.text.UnbindReason) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.testing.expectEqual(z.text.UnbindReason.closed, reason) catch unreachable;
            std.testing.expect(w.app.activity_depth > 0) catch unreachable;
            self.count.* += 1;
            std.testing.allocator.destroy(self);
        }
    };
    const Host = struct {
        count: *usize,
        detached: *usize,
        fn event(_: *anyopaque, _: z.Window, _: z.Event) void {}
        fn detach(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            std.testing.expectEqual(@as(usize, 1), self.count.*) catch unreachable;
            self.detached.* += 1;
        }
    };
    const owned = try std.testing.allocator.create(Owned);
    owned.* = .{ .count = &unbound_count };
    var host: Host = .{ .count = &unbound_count, .detached = &detached };
    _ = try window.setTextClient(.{ .context = owned, .owner = std.Thread.getCurrentId(), .read = Owned.read, .change = Owned.change, .unbound = Owned.unbound });
    try window.setContent(.{ .context = &host, .event = Host.event, .detach = Host.detach });
    _ = try window.destroy();
    try std.testing.expectEqual(@as(usize, 1), unbound_count);
    try std.testing.expectEqual(@as(usize, 1), detached);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}

test "focus unbind callback may install a new generation without old cleanup removing it" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var next: Client = .{};
    var old: Client = .{ .rebind = &next };
    old.token = try window.setTextClient(old.descriptor());
    window.app.windows.get(window.key).?.emit(.{ .focus = false });
    try std.testing.expectEqual(next.token.?.generation, window.textClientToken().?.generation);
    try std.testing.expect(!(try window.clearTextClient(old.token.?)));
    var bytes: [8]u8 = undefined;
    _ = try window.readTextClient(next.token.?, &bytes);
}

test "native cancellation failure revokes once and never installs a replacement until explicit retry" {
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var old: Client = .{};
    var next: Client = .{};
    old.token = try window.setTextClient(old.descriptor());
    app.native.fail_text_cancel = true;
    try std.testing.expectError(error.CompositionQueryFailed, window.setTextClient(next.descriptor()));
    try std.testing.expectEqual(@as(usize, 1), old.unbound);
    try std.testing.expect(window.textClientToken() == null);
    next.token = try window.setTextClient(next.descriptor());
    var bytes: [8]u8 = undefined;
    _ = try window.readTextClient(next.token.?, &bytes);
    app.native.fail_text_cancel = true;
    try std.testing.expectError(error.CompositionQueryFailed, window.clearTextClient(next.token.?));
    try std.testing.expectEqual(@as(usize, 1), next.unbound);
    try std.testing.expect(window.textClientToken() == null);
    old.token = try window.setTextClient(old.descriptor());
    old.close_change = true;
    try std.testing.expectError(error.StaleTextClient, window.changeTextClient(old.token.?, .{ .select = .{ .anchor = 0, .caret = 0 } }));
    try std.testing.expectEqual(@as(usize, 1), old.unbound);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 2), old.unbound);
}

test "revocation cancellation is lifecycle only and native failure restores ordinary legacy cancellation" {
    const Probe = struct {
        revoked: usize = 0,
        ordinary: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, input: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (input == .text_preedit_revoked) {
                std.testing.expect(!(window.hasTextClient() catch unreachable)) catch unreachable;
                self.revoked += 1;
            } else if (input == .text_preedit_cancel) self.ordinary += 1;
        }
        fn detach(_: *anyopaque) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var probe: Probe = .{};
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    var client: Client = .{};
    client.token = try window.setTextClient(client.descriptor());
    app.native.emit_text_cancel = true;
    app.native.fail_text_cancel = true;
    try std.testing.expectError(error.CompositionQueryFailed, window.clearTextClient(client.token.?));
    try std.testing.expectEqual(@as(usize, 1), client.unbound);
    try std.testing.expectEqual(@as(usize, 1), probe.revoked);
    try std.testing.expectEqual(@as(usize, 0), probe.ordinary);
    // No physical client also describes legacy editors. It is not sufficient
    // to classify an independent cancellation as an owner revocation.
    try window.cancelTextComposition();
    try std.testing.expectEqual(@as(usize, 1), probe.ordinary);
}

test "new binding inside focus revocation receives ordinary cancellation within the old native scope" {
    const Probe = struct {
        next: *Client,
        revoked: usize = 0,
        ordinary: usize = 0,
        fn event(ptr: *anyopaque, window: z.Window, input: z.Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (input == .text_preedit_revoked) {
                self.revoked += 1;
                self.next.token = window.setTextClient(self.next.descriptor()) catch unreachable;
                window.cancelTextComposition() catch unreachable;
            } else if (input == .text_preedit_cancel) {
                std.testing.expect(window.textClientToken() != null) catch unreachable;
                self.ordinary += 1;
            }
        }
        fn detach(_: *anyopaque) void {}
    };
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    defer _ = window.destroy() catch unreachable;
    var next: Client = .{};
    var old: Client = .{};
    var probe: Probe = .{ .next = &next };
    try window.setContent(.{ .context = &probe, .event = Probe.event, .detach = Probe.detach });
    old.token = try window.setTextClient(old.descriptor());
    app.native.emit_text_cancel = true;
    window.app.windows.get(window.key).?.emit(.{ .focus = false });
    try std.testing.expectEqual(@as(usize, 1), old.unbound);
    try std.testing.expectEqual(@as(usize, 1), probe.revoked);
    try std.testing.expectEqual(@as(usize, 1), probe.ordinary);
    try std.testing.expectEqual(next.token.?.generation, window.textClientToken().?.generation);
}
