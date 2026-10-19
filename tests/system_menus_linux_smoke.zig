const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn zsl_popup_activate(*anyopaque, i32) c_int;
extern fn zsl_message_press(*anyopaque, i32) c_int;
extern fn zsl_message_close(*anyopaque) c_int;

const items = [_]system.Item{
    .{ .id = 1, .label = "&Open", .accelerator = .{ .key = .o, .modifiers = .{ .control = true } } },
    .{ .id = 2, .label = "Snake_case && more", .checked = true },
    .{ .kind = .separator },
    .{ .id = 3, .kind = .submenu, .label = "&Recent" },
    .{ .id = 4, .parent = 3, .label = "First" },
    .{ .id = 5, .kind = .submenu, .label = "Locked", .enabled = false },
    .{ .id = 6, .parent = 5, .label = "Hidden", .accelerator = .{ .key = .f7 } },
    .{ .id = 7, .label = "Off", .enabled = false },
};
const buttons = [_]system.MessageButton{ .{ .id = 21, .label = "&Save" }, .{ .id = 22, .label = "_Discard" }, .{ .id = 23, .label = "Cancel" } };

const Step = enum { popup_select, popup_nested, popup_locked, popup_cancel, popup_detach, message_press, message_close, message_cancel, message_close_window, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    owner: system.Owner = undefined,
    step: Step = .popup_select,
    attempts: usize = 0,
    popups: [8]?system.PopupResult = @splat(null),
    popup_count: usize = 0,
    messages: [8]?system.MessageResult = @splat(null),
    message_count: usize = 0,
    window_closed: bool = false,
    failure: ?anyerror = null,

    fn action(ptr: *anyopaque, _: z.Window, value: system.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        switch (value) {
            .popup => |result| {
                std.debug.assert(self.owner.popup.native == null);
                self.popups[self.popup_count] = result;
                self.popup_count += 1;
                self.advance();
            },
            .message => |result| {
                std.debug.assert(self.owner.message_dialog.native == null);
                self.messages[self.message_count] = result;
                self.message_count += 1;
                self.advance();
            },
            else => unreachable,
        }
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.owner.window == null and self.owner.message_dialog.native == null);
        self.window_closed = true;
        self.app.quit();
    }
    fn advance(self: *State) void {
        self.step = @enumFromInt(@intFromEnum(self.step) + 1);
        self.app.post(.{ .context = self, .call = run }) catch |err| self.fail(err);
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.app.quit();
    }
    fn run(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.perform() catch |err| {
            std.debug.print("step {s} failed: {s}\n", .{ @tagName(self.step), @errorName(err) });
            self.fail(err);
        };
    }
    fn popup(self: *State, request: u64) !bool {
        self.owner.popupMenu(request, &items, .{ .client = .{ .x = 12, .y = 9 } }) catch |err| {
            // The first popup waits for the window to become viewable.
            if (err != error.MenuStartFailed or self.attempts > 400) return err;
            self.attempts += 1;
            std.Thread.sleep(5 * std.time.ns_per_ms);
            try self.app.post(.{ .context = self, .call = run });
            return false;
        };
        return true;
    }
    fn perform(self: *State) !void {
        switch (self.step) {
            .popup_select => {
                if (!try self.popup(1)) return;
                try std.testing.expectError(error.MenuAlreadyPending, self.owner.popupMenu(9, &items, .pointer));
                try std.testing.expect(zsl_popup_activate(self.owner.popup.native.?, 0) == 1);
            },
            .popup_nested => {
                if (!try self.popup(2)) return;
                try std.testing.expect(zsl_popup_activate(self.owner.popup.native.?, 2) == 1);
            },
            .popup_locked => {
                if (!try self.popup(3)) return;
                // Native sensitivity does not cover a submenu's own window; the
                // framework still refuses commands below a disabled ancestor.
                try std.testing.expect(zsl_popup_activate(self.owner.popup.native.?, 3) == 1);
            },
            .popup_cancel => {
                if (!try self.popup(4)) return;
                try std.testing.expect(zsl_popup_activate(self.owner.popup.native.?, 4) == 0);
                try self.owner.cancelPopup();
            },
            .popup_detach => {
                if (!try self.popup(5)) return;
                try self.owner.detach();
                try std.testing.expect(self.owner.window == null and self.owner.popup.native == null);
                try self.owner.attach(self.window);
                self.advance();
            },
            .message_press => {
                try self.owner.showMessage(10, .{ .title = "Unsaved", .message = "Save changes / 保存更改？", .buttons = &buttons, .default_button = 0, .cancel_button = 2, .kind = .question });
                try std.testing.expectError(error.MessageAlreadyPending, self.owner.showMessage(99, .{ .message = "x", .buttons = &buttons }));
                try std.testing.expect(zsl_message_press(self.owner.message_dialog.native.?, 1) == 1);
            },
            .message_close => {
                try self.owner.showMessage(11, .{ .message = "Close me", .buttons = &buttons, .cancel_button = 2, .kind = .warning });
                try std.testing.expect(zsl_message_close(self.owner.message_dialog.native.?) == 1);
            },
            .message_cancel => {
                try self.owner.showMessage(12, .{ .message = "Cancelled by the application", .buttons = buttons[0..1], .kind = .err });
                try self.owner.cancelMessage();
            },
            .message_close_window => {
                try self.owner.showMessage(13, .{ .message = "Window closes underneath", .buttons = buttons[0..2] });
                // Destruction is deferred out of this task; on_closed checks it.
                _ = try self.window.destroy();
            },
            .done => unreachable,
        }
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    state.owner = system.Owner.init(&state, State.action);
    state.window = try app.createWindow(.{ .title = "System menus smoke", .width = 320, .height = 200, .on_closed = .{ .context = &state, .notify = State.closed } });
    try state.owner.attach(state.window);
    state.window.show();
    try app.post(.{ .context = &state, .call = State.run });
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    try app.run();
    try std.testing.expect(!watchdog.expired);
    if (state.failure) |err| return err;
    try std.testing.expect(state.window_closed);
    try std.testing.expectEqual(4, state.popup_count);
    try std.testing.expectEqual(system.PopupResult{ .request = 1, .selected = 1 }, state.popups[0].?);
    try std.testing.expectEqual(system.PopupResult{ .request = 2, .selected = 4 }, state.popups[1].?);
    try std.testing.expectEqual(system.PopupResult{ .request = 3, .selected = null }, state.popups[2].?);
    try std.testing.expectEqual(system.PopupResult{ .request = 4, .selected = null }, state.popups[3].?);
    try std.testing.expectEqual(3, state.message_count);
    try std.testing.expectEqual(system.MessageResult{ .request = 10, .response = .{ .button = 22 } }, state.messages[0].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 11, .response = .{ .button = 23 } }, state.messages[1].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 12, .response = .dismissed }, state.messages[2].?);
    std.debug.print("GTK system menus smoke passed: popup select/nested/disabled-ancestor/cancel/detach, message press/close/cancel/window-closure; native links left={d}\n", .{system.message.resourceCount()});
}
