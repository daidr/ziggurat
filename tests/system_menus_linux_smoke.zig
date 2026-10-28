const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn zsl_popup_activate(*anyopaque, i32) c_int;
extern fn zsl_message_press(*anyopaque, i32) c_int;
extern fn zsl_message_close(*anyopaque) c_int;
extern fn zsl_menubar_activate(*anyopaque, i32) c_int;
extern fn zsl_menubar_checked(*anyopaque, i32) c_int;
extern fn zsl_menubar_key(*anyopaque, u32, u32) c_int;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_name(*anyopaque) [*:0]const u8;
extern fn gtk_widget_grab_focus(*anyopaque) void;

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
const bar_items = [_]system.Item{
    .{ .id = 30, .kind = .submenu, .label = "&File" },
    .{ .id = 31, .parent = 30, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
    .{ .id = 32, .parent = 30, .label = "&Open", .accelerator = .{ .key = .o, .modifiers = .{ .control = true } } },
    .{ .id = 33, .parent = 30, .label = "Word wrap" },
    .{ .id = 34, .parent = 30, .label = "Unavailable", .enabled = false, .accelerator = .{ .key = .f5 } },
    .{ .id = 35, .kind = .submenu, .label = "&Tools", .enabled = false },
    .{ .id = 36, .parent = 35, .label = "Locked", .accelerator = .{ .key = .f7 } },
};
// Ctrl in GDK's state mask.
const control_mask = 1 << 2;
const buttons = [_]system.MessageButton{ .{ .id = 21, .label = "&Save" }, .{ .id = 22, .label = "_Discard" }, .{ .id = 23, .label = "Cancel" } };

const Step = enum { bar_command, bar_accelerator, bar_consumed, bar_disabled, bar_check, bar_replace, popup_select, popup_nested, popup_locked, popup_cancel, popup_detach, bar_clear, message_press, message_close, message_cancel, message_close_window, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    area: *anyopaque = undefined,
    owner: system.Owner = undefined,
    step: Step = .bar_command,
    attempts: usize = 0,
    popups: [8]?system.PopupResult = @splat(null),
    popup_count: usize = 0,
    messages: [8]?system.MessageResult = @splat(null),
    message_count: usize = 0,
    commands: [16]u64 = @splat(0),
    command_count: usize = 0,
    consumed_keys: usize = 0,
    window_closed: bool = false,
    failure: ?anyerror = null,

    fn action(ptr: *anyopaque, _: z.Window, value: system.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        switch (value) {
            .popup => |result| {
                std.debug.assert(self.owner.popup.pending.native == null);
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
            .menu => |id| {
                self.commands[self.command_count] = id;
                self.command_count += 1;
                self.advance();
            },
            else => unreachable,
        }
    }
    fn keyInput(ptr: *anyopaque, _: z.Window, input: z.KeyInput) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (input.key == .o and input.modifiers.control) {
            self.consumed_keys += 1;
            return true;
        }
        return false;
    }
    fn contentEvent(_: *anyopaque, _: z.Window, _: z.Event) void {}
    fn contentDetach(_: *anyopaque) void {}
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.owner.window == null and self.owner.message_dialog.native == null);
        self.window_closed = true;
        self.app.quit();
    }
    fn advance(self: *State) void {
        self.step = @fromBackingInt(@intCast(@backingInt(self.step) + 1));
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
            zio.sleep(5 * std.time.ns_per_ms);
            try self.app.post(.{ .context = self, .call = run });
            return false;
        };
        return true;
    }
    fn rootName(self: *State) []const u8 {
        return std.mem.span(gtk_widget_get_name(gtk_bin_get_child(self.window.nativeHandle().?).?));
    }
    fn perform(self: *State) !void {
        switch (self.step) {
            .bar_command => {
                self.area = gtk_bin_get_child(self.window.nativeHandle().?).?;
                try self.owner.setMenu(&bar_items);
                try std.testing.expectEqualStrings("GtkBox", self.rootName());
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 0) == 1);
            },
            .bar_accelerator => try std.testing.expect(zsl_menubar_key(self.owner.bar.?, 's', control_mask) == 1),
            .bar_consumed => {
                // Content consumes Ctrl+O first; Ctrl+S then reaches the bar.
                gtk_widget_grab_focus(self.area);
                try std.testing.expect(zsl_menubar_key(self.owner.bar.?, 'o', control_mask) == 1);
                try std.testing.expect(zsl_menubar_key(self.owner.bar.?, 's', control_mask) == 1);
            },
            .bar_disabled => {
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 3) == 0);
                // GTK sensitivity does not follow a disabled submenu; the bar does.
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 4) == 1);
                try std.testing.expect(zsl_menubar_key(self.owner.bar.?, 0xffc4, 0) == 1);
                try std.testing.expect(zsl_menubar_key(self.owner.bar.?, 0xffc2, 0) == 1);
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 1) == 1);
            },
            .bar_check => {
                try self.owner.setItemState(33, true, true);
                try std.testing.expectEqual(1, zsl_menubar_checked(self.owner.bar.?, 2));
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 2) == 1);
            },
            .bar_replace => {
                // GTK toggled the item on activation; the bar keeps the
                // application's state.
                try std.testing.expectEqual(1, zsl_menubar_checked(self.owner.bar.?, 2));
                try self.owner.setItemState(33, true, false);
                try std.testing.expectEqual(-1, zsl_menubar_checked(self.owner.bar.?, 2));
                try std.testing.expectError(error.MenuItemNotFound, self.owner.setItemState(99, true, false));
                try self.owner.setMenu(bar_items[0..3]);
                try std.testing.expectEqualStrings("GtkBox", self.rootName());
                try std.testing.expect(zsl_menubar_activate(self.owner.bar.?, 1) == 1);
            },
            .bar_clear => {
                try self.owner.setMenu(&bar_items);
                try std.testing.expectEqualStrings("GtkBox", self.rootName());
                try self.owner.clearMenu();
                try std.testing.expect(self.owner.bar == null);
                try std.testing.expectEqualStrings("GtkDrawingArea", self.rootName());
                self.advance();
            },
            .popup_select => {
                if (!try self.popup(1)) return;
                try std.testing.expectError(error.MenuAlreadyPending, self.owner.popupMenu(9, &items, .pointer));
                try std.testing.expect(zsl_popup_activate(self.owner.popup.pending.native.?, 0) == 1);
            },
            .popup_nested => {
                if (!try self.popup(2)) return;
                try std.testing.expect(zsl_popup_activate(self.owner.popup.pending.native.?, 2) == 1);
            },
            .popup_locked => {
                if (!try self.popup(3)) return;
                // Native sensitivity does not cover a submenu's own window; the
                // framework still refuses commands below a disabled ancestor.
                try std.testing.expect(zsl_popup_activate(self.owner.popup.pending.native.?, 3) == 1);
            },
            .popup_cancel => {
                if (!try self.popup(4)) return;
                try std.testing.expect(zsl_popup_activate(self.owner.popup.pending.native.?, 4) == 0);
                try self.owner.cancelPopup();
            },
            .popup_detach => {
                if (!try self.popup(5)) return;
                try self.owner.detach();
                try std.testing.expect(self.owner.window == null and self.owner.popup.pending.native == null);
                // Detach also took the menu bar away and restored the content.
                try std.testing.expectEqualStrings("GtkDrawingArea", self.rootName());
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
                // The window also closes under a menu bar.
                try self.owner.setMenu(&bar_items);
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
    try state.window.setContent(.{ .context = &state, .event = State.contentEvent, .detach = State.contentDetach, .key_input = State.keyInput });
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
    try std.testing.expectEqualSlices(u64, &.{ 31, 31, 31, 32, 33, 32 }, state.commands[0..state.command_count]);
    try std.testing.expectEqual(1, state.consumed_keys);
    try std.testing.expectEqual(system.MessageResult{ .request = 10, .response = .{ .button = 22 } }, state.messages[0].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 11, .response = .{ .button = 23 } }, state.messages[1].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 12, .response = .dismissed }, state.messages[2].?);
    std.debug.print("GTK system menus smoke passed: menu bar command/accelerator/content-first/disabled/check/replace/clear, popup select/nested/disabled-ancestor/cancel/detach, message press/close/cancel/window-closure; native links left={d}\n", .{system.message.resourceCount()});
}
