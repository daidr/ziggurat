//! AppKit menus, popup menus, alerts, open and save panels, status items and
//! the Dock against the real session: each step drives the native objects
//! through test hooks as a click or a key would, and checks what reaches
//! the application.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

pub const std_options: std.Options = .{ .allow_stack_tracing = builtin.os.tag != .macos };

extern fn zsm_bar_menu(*anyopaque) *anyopaque;
extern fn zsm_test_main_menu() ?*anyopaque;
extern fn zsm_test_menu_perform(*anyopaque, [*]const i32, u32) c_int;
extern fn zsm_test_menu_key(*anyopaque, [*:0]const u8, u32) c_int;
extern fn zsm_test_menu_item(*anyopaque, [*]const i32, u32, [*]u8, usize, *u32, *u32, *c_int, *c_int, *c_int) c_int;
extern fn zsm_test_menu_action_is(*anyopaque, [*]const i32, u32, [*:0]const u8) c_int;
extern fn zsm_test_services_menu_is(*anyopaque, [*]const i32, u32) c_int;
extern fn zsm_test_send_action([*:0]const u8, *anyopaque) c_int;
extern fn zsm_test_window_view(*anyopaque) *anyopaque;
extern fn zsm_popup_is_open(*anyopaque) c_int;
extern fn zsm_popup_choose(*anyopaque, i32) c_int;
extern fn zsm_message_key(*anyopaque, [*:0]const u8, u32) c_int;
extern fn zsm_message_press(*anyopaque, i32) c_int;
extern fn zsm_message_button(*anyopaque, i32, *c_int, *c_int) c_int;
extern fn zsm_message_is_sheet(*anyopaque) c_int;
extern fn zsm_chooser_accept(*anyopaque, [*]const [*:0]const u8, u32) c_int;
extern fn zsm_chooser_describe(*anyopaque, *c_int, *c_int, *c_int, *c_int, [*]u8, usize) c_int;
extern fn zsm_tray_test_click(*anyopaque, c_int, c_int) void;
extern fn zsm_tray_test_title_is(*anyopaque, [*:0]const u8) c_int;
extern fn zsm_tray_test_monospaced_digits(*anyopaque) c_int;
extern fn zsm_tray_test_menu(*anyopaque) ?*anyopaque;
extern fn zsm_dock_test_menu(*anyopaque) *anyopaque;
extern fn zsm_dock_test_badge_is([*:0]const u8) c_int;
extern fn zsm_dock_test_progress() f64;

const command: u32 = 1 << 20;
const shift: u32 = 1 << 17;
const png = @embedFile("image_fixture/colors.png");

const file_items = [_]system.Item{
    .{ .id = 30, .kind = .submenu, .label = "&File" },
    .{ .id = 31, .parent = 30, .label = "&Save", .accelerator = .{ .key = .s, .modifiers = .{ .super = true } } },
    .{ .id = 32, .parent = 30, .label = "&Open…" },
    .{ .id = 33, .parent = 30, .label = "Word wrap" },
    .{ .id = 34, .parent = 30, .label = "Unavailable", .enabled = false, .accelerator = .{ .key = .f5 } },
    .{ .id = 35, .parent = 30, .kind = .submenu, .label = "&Tools", .enabled = false },
    .{ .id = 36, .parent = 35, .label = "Locked", .accelerator = .{ .key = .f7 } },
    .{ .id = 37, .parent = 30, .label = "Small", .radio = true, .checked = true },
    .{ .id = 38, .parent = 30, .label = "Large", .radio = true },
    .{ .id = 39, .parent = 30, .label = "Zoom In", .accelerator = .{ .key = .plus, .modifiers = .{ .super = true } } },
};
const popup_items = [_]system.Item{
    .{ .id = 1, .label = "&First" },
    .{ .id = 2, .label = "R&&D" },
    .{ .kind = .separator },
    .{ .id = 3, .label = "Off", .enabled = false },
};
const buttons = [_]system.MessageButton{ .{ .id = 21, .label = "&Save" }, .{ .id = 22, .label = "Discard", .destructive = true }, .{ .id = 23, .label = "Cancel" } };

const Step = enum { bar, edit, popup_choose, popup_cancel_early, popup_cancel_open, message_escape, message_no_cancel, message_return, message_cancelled, message_period, open_file, open_files, save_file, pick_folder, tray, dock, detach, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    owner: system.Owner = undefined,
    tray: system.Tray = undefined,
    dock: system.Dock = undefined,
    step: Step = .bar,
    attempts: usize = 0,
    commands: [16]u64 = @splat(0),
    command_count: usize = 0,
    popups: [8]?system.PopupResult = @splat(null),
    popup_count: usize = 0,
    messages: [8]?system.MessageResult = @splat(null),
    message_count: usize = 0,
    picks: [8]?[256]u8 = @splat(null),
    pick_count: usize = 0,
    destination: [1024]u8 = undefined,
    edits: [8]?z.EditKey = @splat(null),
    edit_count: usize = 0,
    keys: [8]?z.KeyInput = @splat(null),
    key_count: usize = 0,
    tray_actions: [8]?system.TrayAction = @splat(null),
    tray_count: usize = 0,
    dock_commands: [4]u64 = @splat(0),
    dock_count: usize = 0,
    labels: [2048]u8 = undefined,
    items: [64]system.Item = undefined,
    menu_icon: system.MenuIcon = undefined,
    window_closed: bool = false,
    failure: ?anyerror = null,

    fn action(ptr: *anyopaque, _: z.Window, value: system.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        switch (value) {
            .menu => |id| {
                self.commands[self.command_count] = id;
                self.command_count += 1;
            },
            .popup => |result| {
                self.popups[self.popup_count] = result;
                self.popup_count += 1;
                self.advance();
            },
            .message => |result| {
                self.messages[self.message_count] = result;
                self.message_count += 1;
                self.advance();
            },
            else => {},
        }
    }
    fn picked(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        var text: [256]u8 = @splat(0);
        const written: []const u8 = switch (result) {
            .selected => |path| std.fmt.bufPrint(&text, "one:{s}", .{path}) catch "overflow",
            .selected_multiple => |paths| std.fmt.bufPrint(&text, "many:{s},{s}", .{ paths[0], paths[1] }) catch "overflow",
            .cancelled => "cancelled",
            .failed => |failure| @errorName(failure.err),
        };
        if (written.ptr != &text) @memcpy(text[0..written.len], written);
        self.picks[self.pick_count] = text;
        self.pick_count += 1;
        self.advance();
    }
    fn trayAction(ptr: *anyopaque, _: *system.Tray, value: system.TrayAction) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.tray_actions[self.tray_count] = value;
        self.tray_count += 1;
        if (value == .popup) self.advance();
    }
    fn dockMenu(ptr: *anyopaque, _: *system.Dock, id: u64) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.dock_commands[self.dock_count] = id;
        self.dock_count += 1;
    }
    fn keyInput(ptr: *anyopaque, _: z.Window, input: z.KeyInput) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.keys[self.key_count] = input;
        self.key_count += 1;
        // The content binds Cmd+V itself, so the menu's Paste runs it alone.
        return input.key == .v and input.modifiers.super;
    }
    fn contentEvent(ptr: *anyopaque, _: z.Window, event: z.Event) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (event == .edit_key) {
            self.edits[self.edit_count] = event.edit_key;
            self.edit_count += 1;
        }
    }
    fn contentDetach(_: *anyopaque) void {}
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.window_closed = true;
        self.app.quit();
    }
    fn advance(self: *State) void {
        self.step = @fromBackingInt(@intCast(@backingInt(self.step) + 1));
        self.attempts = 0;
        self.app.post(.{ .context = self, .call = run }) catch |err| self.fail(err);
    }
    fn again(self: *State) !void {
        self.attempts += 1;
        if (self.attempts > 2000) return error.NativeTimeout;
        try self.app.post(.{ .context = self, .call = run });
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
    fn item(menu: *anyopaque, path: []const i32) !struct { title: [128]u8, key: u32, modifiers: u32, state: c_int, enabled: bool, image: bool } {
        var title: [128]u8 = @splat(0);
        var key: u32 = 0;
        var modifiers: u32 = 0;
        var state: c_int = 0;
        var enabled: c_int = 0;
        var image: c_int = 0;
        if (zsm_test_menu_item(menu, path.ptr, @intCast(path.len), &title, title.len, &key, &modifiers, &state, &enabled, &image) == 0) return error.MissingMenuItem;
        return .{ .title = title, .key = key, .modifiers = modifiers, .state = state, .enabled = enabled != 0, .image = image != 0 };
    }
    /// Takes a pointer: a by-value parameter's title would not outlive the call.
    fn titleOf(value: anytype) []const u8 {
        return std.mem.sliceTo(&value.title, 0);
    }
    fn perform(self: *State) !void {
        switch (self.step) {
            .bar => {
                var builder = system.menu_roles.Builder.init(&self.items, &self.labels, .{ .app_name = "Smoke", .platform = .macos });
                _ = try builder.role(null, .app_menu);
                for (file_items) |value| try builder.add(value);
                _ = try builder.role(null, .edit_menu);
                _ = try builder.role(null, .window_menu);
                // The File menu follows the application menu's ten items.
                self.items[11].icon = &self.menu_icon;
                try self.owner.setMenu(builder.result());
                const menu = zsm_bar_menu(self.owner.bar.?);
                try std.testing.expectEqual(@as(?*anyopaque, menu), zsm_test_main_menu());
                const save = try item(menu, &.{ 1, 0 });
                try std.testing.expectEqualStrings("Save", titleOf(&save));
                try std.testing.expect(save.key == 's' and save.modifiers == command and save.image and save.enabled);
                const open = try item(menu, &.{ 1, 1 });
                try std.testing.expectEqualStrings("Open…", titleOf(&open));
                const quit = try item(menu, &.{ 0, 8 });
                try std.testing.expectEqualStrings("Quit Smoke", titleOf(&quit));
                try std.testing.expect(quit.key == 'q' and quit.modifiers == command);
                try std.testing.expect(zsm_test_menu_action_is(menu, &.{ 2, 4 }, 2, "copy:") != 0);
                try std.testing.expect(zsm_test_menu_action_is(menu, &.{ 0, 4 }, 2, "hide:") != 0);
                try std.testing.expect(zsm_test_services_menu_is(menu, &.{ 0, 2 }, 2) != 0);
                // A click and the key equivalent run the command.
                try std.testing.expectEqual(1, zsm_test_menu_perform(menu, &.{ 1, 0 }, 2));
                try std.testing.expectEqual(1, zsm_test_menu_key(menu, "s", command));
                // Disabled, and below a disabled submenu.
                try std.testing.expectEqual(0, zsm_test_menu_perform(menu, &.{ 1, 3 }, 2));
                try std.testing.expectEqual(0, zsm_test_menu_perform(menu, &.{ 1, 4, 0 }, 3));
                // Command-+ and its Command-= twin.
                try std.testing.expectEqual(1, zsm_test_menu_key(menu, "+", command | shift));
                try std.testing.expectEqual(1, zsm_test_menu_key(menu, "=", command));
                // Check and radio state stay the application's.
                try self.owner.setItemState(33, true, true);
                try std.testing.expectEqual(1, (try item(menu, &.{ 1, 2 })).state);
                try std.testing.expectEqual(1, (try item(menu, &.{ 1, 5 })).state);
                try self.owner.setItemState(38, true, true);
                try std.testing.expectEqual(0, (try item(menu, &.{ 1, 5 })).state);
                try std.testing.expectEqual(1, (try item(menu, &.{ 1, 6 })).state);
                try self.owner.setItemState(32, false, false);
                try std.testing.expect(!(try item(menu, &.{ 1, 1 })).enabled);
                try self.owner.setItemIcon(31, null);
                try std.testing.expect(!(try item(menu, &.{ 1, 0 })).image);
                try std.testing.expectError(error.MenuItemNotFound, self.owner.setItemState(99, true, false));
                // Quit is the application's to run.
                try std.testing.expectEqual(1, zsm_test_menu_perform(menu, &.{ 0, 8 }, 2));
                // A replacement takes the main menu.
                try self.owner.setMenu(builder.result()[0..9]);
                try std.testing.expectEqual(@as(?*anyopaque, zsm_bar_menu(self.owner.bar.?)), zsm_test_main_menu());
                try self.owner.clearMenu();
                try std.testing.expectEqual(@as(?*anyopaque, null), zsm_test_main_menu());
                try self.owner.setMenu(builder.result());
                self.advance();
            },
            .edit => {
                // The Edit menu's actions run as their Command shortcuts.
                const view = zsm_test_window_view(self.window.nativeHandle().?);
                try std.testing.expect(zsm_test_send_action("copy:", view) != 0);
                try std.testing.expect(zsm_test_send_action("paste:", view) != 0);
                try std.testing.expect(zsm_test_send_action("redo:", view) != 0);
                try std.testing.expect(zsm_test_send_action("delete:", view) != 0);
                self.advance();
            },
            .popup_choose => {
                if (self.owner.popup.pending.native == null) {
                    try self.owner.popupMenu(1, &popup_items, .{ .client = .{ .x = 12, .y = 9 } });
                    try std.testing.expectError(error.MenuAlreadyPending, self.owner.popupMenu(9, &popup_items, .pointer));
                }
                const native = self.owner.popup.pending.native.?;
                if (zsm_popup_is_open(native) == 0) return self.again();
                try std.testing.expect(zsm_popup_choose(native, 1) == 1);
            },
            .popup_cancel_early => {
                try self.owner.popupMenu(2, &popup_items, .pointer);
                try self.owner.cancelPopup();
            },
            .popup_cancel_open => {
                if (self.owner.popup.pending.native == null) try self.owner.popupMenu(3, &popup_items, .{ .screen = .{ .x = 100, .y = 100 } });
                const native = self.owner.popup.pending.native.?;
                if (zsm_popup_is_open(native) == 0) return self.again();
                try self.owner.cancelPopup();
            },
            .message_escape => {
                try self.owner.showMessage(10, .{ .title = "Unsaved", .message = "Save changes / 保存更改？", .buttons = &buttons, .default_button = 0, .cancel_button = 2, .kind = .question });
                try std.testing.expectError(error.MessageAlreadyPending, self.owner.showMessage(99, .{ .message = "x", .buttons = &buttons }));
                const native = self.owner.message_dialog.native.?;
                try std.testing.expect(zsm_message_is_sheet(native) != 0);
                var default: c_int = 0;
                var destructive: c_int = 0;
                try std.testing.expect(zsm_message_button(native, 0, &default, &destructive) != 0 and default != 0 and destructive == 0);
                try std.testing.expect(zsm_message_button(native, 1, &default, &destructive) != 0 and default == 0 and destructive != 0);
                try std.testing.expect(zsm_message_key(native, "\x1b", 0) == 1);
            },
            .message_no_cancel => {
                if (self.owner.message_dialog.native == null) {
                    try self.owner.showMessage(11, .{ .message = "Nothing to cancel", .buttons = buttons[0..2], .kind = .warning });
                    var default: c_int = 0;
                    var destructive: c_int = 0;
                    try std.testing.expect(zsm_message_button(self.owner.message_dialog.native.?, 0, &default, &destructive) != 0 and default == 0);
                }
                try std.testing.expect(zsm_message_key(self.owner.message_dialog.native.?, "\x1b", 0) == 1);
            },
            .message_return => {
                try self.owner.showMessage(12, .{ .message = "Return answers the default", .buttons = &buttons, .default_button = 1, .cancel_button = 2, .kind = .err });
                try std.testing.expect(zsm_message_key(self.owner.message_dialog.native.?, "\r", 0) == 1);
            },
            .message_cancelled => {
                try self.owner.showMessage(13, .{ .message = "Cancelled by the application", .buttons = buttons[0..1] });
                try self.owner.cancelMessage();
            },
            .message_period => {
                try self.owner.showMessage(14, .{ .message = "Command-period", .buttons = &buttons, .default_button = 2, .cancel_button = 2 });
                try std.testing.expect(zsm_message_key(self.owner.message_dialog.native.?, ".", command) == 1);
            },
            .open_file => try self.choose(.open_file, &.{"/tmp/one.txt"}, .{ .extensions = &.{".txt"} }, 1, 0, 0, null),
            .open_files => try self.choose(.open_files, &.{ "/tmp/a.md", "/tmp/b.md" }, .{}, 0, 1, 0, null),
            .save_file => try self.choose(.save_file, &.{"/tmp/Report.md"}, .{ .extensions = &.{".md"}, .suggested_name = "Report.md" }, 1, 0, 0, "Report.md"),
            .pick_folder => try self.choose(.folder, &.{}, .{}, 0, 0, 1, null),
            .tray => {
                var pixels: [16 * 16 * 4]u8 = @splat(0x80);
                const icon = try system.TrayIcon.init(16, 16, &pixels);
                defer icon.deinit();
                if (self.tray.native == null) {
                    try self.tray.show(self.app, .{ .icon = icon.handle, .template = true, .tooltip = "Smoke", .title = "12 MB/s", .guid = @splat(0x5a) });
                    const native = self.tray.native.?;
                    try std.testing.expect(zsm_tray_test_title_is(native, "12 MB/s") != 0);
                    try std.testing.expect(zsm_tray_test_monospaced_digits(native) != 0);
                    try self.tray.show(self.app, .{ .icon = icon.handle, .tooltip = "Smoke", .title = "3 MB/s", .guid = @splat(0x5a) });
                    try std.testing.expect(zsm_tray_test_title_is(native, "3 MB/s") != 0);
                    try std.testing.expectError(error.TrayIdentityChanged, self.tray.show(self.app, .{ .icon = icon.handle }));
                    zsm_tray_test_click(native, 0, 0);
                    zsm_tray_test_click(native, 0, 1);
                    zsm_tray_test_click(native, 1, 0);
                    try std.testing.expectEqual(3, self.tray_count);
                    try std.testing.expect(self.tray_actions[0].? == .activate and self.tray_actions[1].? == .context and self.tray_actions[2].? == .context);
                    try self.tray.setMenu(&.{ .{ .id = 51, .label = "&Show" }, .{ .kind = .separator }, .{ .id = 52, .label = "Quit" } });
                    const menu = zsm_tray_test_menu(native).?;
                    try std.testing.expectEqual(1, zsm_test_menu_perform(menu, &.{2}, 1));
                    try std.testing.expect(self.tray_actions[3].?.menu == 52);
                    try self.tray.setMenu(&.{});
                    try std.testing.expect(zsm_tray_test_menu(native) == null);
                    try self.tray.popupMenu(4, &popup_items, .icon);
                    try self.owner.setTray(.{ .icon = icon.handle, .tooltip = "Owner" });
                    try self.owner.setTray(.{ .tooltip = "Owner again" });
                    try self.owner.clearTray();
                }
                const native = self.tray.popup.pending.native orelse return;
                if (zsm_popup_is_open(native) == 0) return self.again();
                try std.testing.expect(zsm_popup_choose(native, 0) == 1);
            },
            .dock => {
                try self.dock.setMenu(self.app, &.{ .{ .id = 61, .label = "New &Window" }, .{ .id = 62, .label = "Off", .enabled = false } });
                const menu = zsm_dock_test_menu(self.dock.handle.?);
                try std.testing.expectEqual(1, zsm_test_menu_perform(menu, &.{0}, 1));
                try std.testing.expectEqual(0, zsm_test_menu_perform(menu, &.{1}, 1));
                try self.dock.clear();
                try system.dock.setIcon(self.app, png);
                try system.dock.setIcon(self.app, null);
                var taskbar = try system.taskbar.Taskbar.init("dev.ziggurat.smoke");
                defer taskbar.deinit();
                try taskbar.setBadgeCount(self.window, 3);
                try std.testing.expect(zsm_dock_test_badge_is("3") != 0);
                try taskbar.setProgress(self.window, .{ .normal = 0.5 });
                try std.testing.expectEqual(@as(f64, 0.5), zsm_dock_test_progress());
                try taskbar.setProgress(self.window, .{ .failed = 0.25 });
                try taskbar.setProgress(self.window, .none);
                try std.testing.expectEqual(@as(f64, -1), zsm_dock_test_progress());
                try taskbar.setBadgeCount(self.window, null);
                try std.testing.expect(zsm_dock_test_badge_is("") != 0);
                try taskbar.setAttention(self.window, true);
                try taskbar.setAttention(self.window, false);
                self.advance();
            },
            .detach => {
                // Detaching dismisses what is pending without reporting it.
                try self.owner.popupMenu(7, &popup_items, .pointer);
                try self.owner.showMessage(15, .{ .message = "Detached underneath", .buttons = buttons[0..1] });
                try self.owner.openFile(.{}, &self.destination, self, picked);
                try self.owner.detach();
                try std.testing.expectEqual(@as(?*anyopaque, null), zsm_test_main_menu());
                try self.owner.attach(self.window);
                try self.owner.setMenu(&file_items);
                try self.owner.showMessage(16, .{ .message = "Window closes underneath", .buttons = buttons[0..2] });
                try self.tray.remove();
                _ = try self.window.destroy();
            },
            .done => unreachable,
        }
    }
    fn choose(self: *State, kind: system.picker.Kind, paths: []const [*:0]const u8, options: system.picker.Options, types: c_int, multiple: c_int, directories: c_int, name: ?[]const u8) !void {
        if (self.owner.chooser == null) switch (kind) {
            .open_file => try self.owner.openFile(options, &self.destination, self, picked),
            .open_files => try self.owner.openFiles(options, &self.destination, self, picked),
            .save_file => try self.owner.saveFile(options, &self.destination, self, picked),
            .folder => try self.owner.pickFolder(options, &self.destination, self, picked),
        };
        const native = self.owner.chooser.?.native;
        var sheet: c_int = 0;
        var many: c_int = 0;
        var folders: c_int = 0;
        var count: c_int = 0;
        var field: [256]u8 = @splat(0);
        if (zsm_chooser_describe(native, &sheet, &many, &folders, &count, &field, field.len) == 0) return error.ChooserClosed;
        try std.testing.expectEqual(types, count);
        try std.testing.expectEqual(multiple, many);
        try std.testing.expectEqual(directories, folders);
        if (name) |expected| try std.testing.expectEqualStrings(expected, std.mem.sliceTo(&field, 0));
        if (paths.len == 0) return self.owner.cancelFileDialog();
        try std.testing.expect(zsm_chooser_accept(native, paths.ptr, @intCast(paths.len)) == 1);
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    state.owner = system.Owner.init(&state, State.action);
    state.tray = system.Tray.init(&state, State.trayAction);
    state.dock = system.Dock.init(&state, State.dockMenu);
    state.menu_icon = try system.MenuIcon.fromPng(app, png, .{ .template = true });
    defer state.menu_icon.deinit();
    state.window = try app.createWindow(.{ .title = "System macOS smoke", .width = 360, .height = 240, .on_closed = .{ .context = &state, .notify = State.closed } });
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
    try std.testing.expectEqualSlices(u64, &.{ 31, 31, 39, 39, system.menu_roles.Role.quit.id() }, state.commands[0..state.command_count]);
    // Copy, Paste and Redo reach the content as Cmd+C, Cmd+V and
    // Cmd+Shift+Z; the content takes Cmd+V. Delete is an edit key alone.
    try std.testing.expectEqual(3, state.key_count);
    try std.testing.expect(state.keys[0].?.key == .c and state.keys[0].?.modifiers.super);
    try std.testing.expect(state.keys[2].?.key == .z and state.keys[2].?.modifiers.super and state.keys[2].?.modifiers.shift);
    try std.testing.expectEqual(3, state.edit_count);
    try std.testing.expectEqual(z.EditKey{ .key = .c, .control = true }, state.edits[0].?);
    try std.testing.expectEqual(z.EditKey{ .key = .z, .shift = true, .control = true }, state.edits[1].?);
    try std.testing.expectEqual(z.EditKey{ .key = .delete }, state.edits[2].?);
    try std.testing.expectEqual(3, state.popup_count);
    try std.testing.expectEqual(system.PopupResult{ .request = 1, .selected = 2 }, state.popups[0].?);
    try std.testing.expectEqual(system.PopupResult{ .request = 2, .selected = null }, state.popups[1].?);
    try std.testing.expectEqual(system.PopupResult{ .request = 3, .selected = null }, state.popups[2].?);
    try std.testing.expectEqual(5, state.tray_count);
    try std.testing.expectEqual(system.PopupResult{ .request = 4, .selected = 1 }, state.tray_actions[4].?.popup);
    try std.testing.expectEqual(5, state.message_count);
    try std.testing.expectEqual(system.MessageResult{ .request = 10, .response = .{ .button = 23 } }, state.messages[0].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 11, .response = .dismissed }, state.messages[1].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 12, .response = .{ .button = 22 } }, state.messages[2].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 13, .response = .dismissed }, state.messages[3].?);
    try std.testing.expectEqual(system.MessageResult{ .request = 14, .response = .{ .button = 23 } }, state.messages[4].?);
    try std.testing.expectEqual(4, state.pick_count);
    try std.testing.expectEqualStrings("one:/tmp/one.txt", std.mem.sliceTo(&state.picks[0].?, 0));
    try std.testing.expectEqualStrings("many:/tmp/a.md,/tmp/b.md", std.mem.sliceTo(&state.picks[1].?, 0));
    try std.testing.expectEqualStrings("one:/tmp/Report.md", std.mem.sliceTo(&state.picks[2].?, 0));
    try std.testing.expectEqualStrings("cancelled", std.mem.sliceTo(&state.picks[3].?, 0));
    try std.testing.expectEqualSlices(u64, &.{61}, state.dock_commands[0..state.dock_count]);
    std.debug.print("AppKit system smoke passed: menu bar roles/key equivalents/disabled/check/radio/icons/replace/clear, Edit actions as shortcuts, popup choose/cancel, alerts Escape/Return/Command-period/cancel/destructive, open/save/folder sheets, status item clicks/title/menu/popup, Dock menu/icon/badge/progress; native links left={d}\n", .{system.message.resourceCount()});
}
