const std = @import("std");
const zio = @import("ziggurat_io");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;

extern fn zsf_start() c_int;
extern fn zsf_ready() c_int;
extern fn zsf_registrations() c_int;
extern fn zsf_item_path() [*:0]const u8;
extern fn zsf_item_call([*:0]const u8, c_int, c_int) void;
extern fn zsf_item_property([*:0]const u8) void;
extern fn zsf_property_ready() c_int;
extern fn zsf_property_text() [*:0]const u8;
extern fn zsf_notify_count() c_int;
extern fn zsf_last_id() u32;
extern fn zsf_closed_by_client() u32;
extern fn zsf_last_summary() [*:0]const u8;
extern fn zsf_last_body() [*:0]const u8;
extern fn zsf_last_urgency() c_int;
extern fn zsf_last_silent() c_int;
extern fn zsf_last_transient() c_int;
extern fn zsf_invoke(u32) void;
extern fn zsf_menu_layout([*:0]const u8) void;
extern fn zsf_layout_ready() c_int;
extern fn zsf_layout_text() [*:0]const u8;
extern fn zsf_layout_revision() u32;
extern fn zsf_layout_id(c_int) i32;
extern fn zsf_menu_click([*:0]const u8, i32) void;
extern fn zsl_tray_menu_path(*anyopaque) [*:0]const u8;
extern fn zsf_server_close(u32) void;
extern fn zsl_popup_activate(*anyopaque, i32) c_int;
extern fn zsl_chooser_select(*anyopaque, [*]const [*:0]const u8, u32, ?[*:0]const u8) c_int;
extern fn zsl_chooser_accept(*anyopaque, u32, ?[*:0]const u8) c_int;
extern fn zsl_chooser_complete(*anyopaque, [*]const [*:0]const u8, u32) c_int;
extern fn gdk_pixbuf_new(c_int, c_int, c_int, c_int, c_int) ?*anyopaque;
extern fn gdk_pixbuf_fill(*anyopaque, u32) void;
extern fn g_object_unref(*anyopaque) void;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern fn XOpenDisplay(?[*:0]const u8) ?*anyopaque;
extern fn XCloseDisplay(*anyopaque) c_int;
extern fn XFlush(*anyopaque) c_int;
extern fn XSync(*anyopaque, c_int) c_int;
extern fn XKeysymToKeycode(*anyopaque, c_ulong) u8;
extern fn XDefaultRootWindow(*anyopaque) c_ulong;
extern fn XGrabKey(*anyopaque, c_int, c_uint, c_ulong, c_int, c_int, c_int) c_int;

const XTestKey = *const fn (*anyopaque, c_uint, c_int, c_ulong) callconv(.c) c_int;
const control_l = 0xffe3;
const shift_l = 0xffe1;
const f9 = 0xffc6;
const f10 = 0xffc7;
// X11 ControlMask | Mod1Mask.
const control_alt = (1 << 2) | (1 << 3);

const menu = [_]system.Item{ .{ .id = 1, .label = "&Show" }, .{ .id = 2, .label = "&Quit" } };
const tray_menu = [_]system.Item{
    .{ .id = 1, .label = "&Show", .accelerator = .{ .key = .s, .modifiers = .{ .control = true } } },
    .{ .kind = .separator },
    .{ .id = 3, .kind = .submenu, .label = "More", .enabled = false },
    .{ .id = 4, .parent = 3, .label = "Deep" },
    .{ .id = 2, .label = "Quit", .checked = true },
};
const guid = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };

const Step = enum {
    bus,
    tray_show,
    tray_tooltip,
    tray_icon_name,
    tray_activate,
    tray_context,
    tray_update,
    tray_pixmap,
    standalone_show,
    standalone_id,
    standalone_label,
    standalone_menu_path,
    standalone_layout,
    standalone_menu_click,
    standalone_menu_replace,
    standalone_menu_replaced,
    standalone_context,
    standalone_popup,
    notify_show,
    notify_check,
    notify_replace,
    notify_withdrawn,
    notify_replaced,
    notify_latest,
    hotkey_press,
    hotkey_repeat,
    hotkey_conflict,
    chooser_open,
    chooser_many,
    chooser_save,
    chooser_folder,
    chooser_cancel,
    chooser_capacity,
    chooser_detach,
    close_window,
    done,
};

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    owner: system.Owner = undefined,
    tray: system.Tray = undefined,
    step: Step = .bus,
    attempts: usize = 0,
    waiting: bool = false,
    actions: usize = 0,
    tray_actions: usize = 0,
    hotkeys: usize = 0,
    revision: u32 = 0,
    stale_id: i32 = 0,
    activated: [4]u64 = @splat(0),
    activated_count: usize = 0,
    notification_id: u32 = 0,
    xtest: XTestKey = undefined,
    display: *anyopaque = undefined,
    directory: [512]u8 = undefined,
    directory_len: usize = 0,
    paths: [4][600]u8 = undefined,
    path_ptrs: [4][*:0]const u8 = undefined,
    destination: [4096]u8 = undefined,
    small: [4]u8 = undefined,
    results: usize = 0,
    detached_results: usize = 0,
    window_closed: bool = false,
    failure: ?anyerror = null,

    fn action(ptr: *anyopaque, _: z.Window, value: system.Action) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.app.assertOwner();
        self.actions += 1;
        self.check(value) catch |err| return self.fail(err);
    }
    fn check(self: *State, value: system.Action) !void {
        switch (self.step) {
            .tray_activate => try std.testing.expect(value == .tray_activate),
            .tray_context => try std.testing.expectEqual(system.Action{ .tray_context = .{ .x = 40, .y = 50 } }, value),
            .notify_check, .notify_latest => {
                self.activated[self.activated_count] = value.notification_activated;
                self.activated_count += 1;
            },
            .hotkey_press, .hotkey_repeat => {
                try std.testing.expectEqual(system.Action{ .hotkey = 1 }, value);
                // A repeated press without release reports once; a second
                // report would arrive during the next step and fail there.
                self.hotkeys += 1;
            },
            else => return error.UnexpectedAction,
        }
        self.advance();
    }
    fn trayAction(ptr: *anyopaque, tray: *system.Tray, value: system.TrayAction) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.assert(tray == &self.tray);
        self.tray_actions += 1;
        self.checkTray(value) catch |err| return self.fail(err);
    }
    fn checkTray(self: *State, value: system.TrayAction) !void {
        switch (self.step) {
            .standalone_context => try std.testing.expectEqual(system.TrayAction{ .context = .{ .x = 30, .y = 31 } }, value),
            .standalone_popup => try std.testing.expectEqual(system.TrayAction{ .popup = .{ .request = 77, .selected = 2 } }, value),
            // A command below a disabled submenu was clicked first and ignored.
            .standalone_menu_click => try std.testing.expectEqual(system.TrayAction{ .menu = 2 }, value),
            // So was a command of the replaced menu.
            .standalone_menu_replaced => try std.testing.expectEqual(system.TrayAction{ .menu = 12 }, value),
            else => return error.UnexpectedAction,
        }
        self.advance();
    }
    fn chosen(ptr: *anyopaque, _: z.Window, result: system.picker.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.results += 1;
        self.checkChosen(result) catch |err| return self.fail(err);
    }
    fn checkChosen(self: *State, result: system.picker.Result) !void {
        std.debug.assert(self.owner.chooser == null);
        switch (self.step) {
            .chooser_open => try std.testing.expectEqualStrings(std.mem.span(self.path_ptrs[0]), result.selected),
            .chooser_many => {
                try std.testing.expectEqual(2, result.selected_multiple.len);
                try std.testing.expectEqualStrings(std.mem.span(self.path_ptrs[0]), result.selected_multiple[0]);
                try std.testing.expectEqualStrings(std.mem.span(self.path_ptrs[1]), result.selected_multiple[1]);
                try std.testing.expectEqual(result.selected_multiple[0].ptr + result.selected_multiple[0].len, result.selected_multiple[1].ptr);
            },
            .chooser_save => {
                const expected = try std.fmt.bufPrint(&self.paths[3], "{s}/out.txt", .{self.directory[0..self.directory_len]});
                try std.testing.expectEqualStrings(expected, result.selected);
            },
            .chooser_folder => try std.testing.expectEqualStrings(std.mem.span(self.path_ptrs[2]), result.selected),
            .chooser_cancel => try std.testing.expect(result == .cancelled),
            .chooser_capacity => try std.testing.expectEqual(error.ResultCapacityExceeded, result.failed.err),
            else => return error.UnexpectedResult,
        }
        self.advance();
    }
    fn closed(ptr: *anyopaque, _: z.Window) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.owner.window == null and self.owner.tray == null and self.owner.chooser == null and self.owner.hotkey_count == 0 and self.owner.notification == null);
        self.window_closed = true;
        self.app.quit();
    }
    fn advance(self: *State) void {
        self.step = @fromBackingInt(@intCast(@backingInt(self.step) + 1));
        self.attempts = 0;
        self.waiting = false;
        self.app.post(.{ .context = self, .call = run }) catch |err| self.fail(err);
    }
    fn fail(self: *State, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.app.quit();
    }
    fn poll(ptr: ?*anyopaque) callconv(.c) c_int {
        run(ptr.?);
        return 0;
    }
    fn run(ptr: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.perform() catch |err| {
            std.debug.print("step {s} failed: {s}\n", .{ @tagName(self.step), @errorName(err) });
            self.fail(err);
        };
    }
    /// Polls a condition the main loop has to make true, without blocking it.
    fn ready(self: *State, condition: bool) !bool {
        if (condition) return true;
        if (self.attempts > 2000) return error.Timeout;
        self.attempts += 1;
        // A GLib timer lets bus and X11 sources run between polls.
        _ = g_timeout_add(2, poll, self);
        return false;
    }
    fn property(self: *State, name: [*:0]const u8, expected: []const u8) !void {
        if (!self.waiting) {
            self.waiting = true;
            zsf_item_property(name);
        }
        if (!try self.ready(zsf_property_ready() != 0)) return;
        try std.testing.expectEqualStrings(expected, std.mem.span(zsf_property_text()));
        self.advance();
    }
    /// Reads the standalone item's menu as a panel would.
    fn layout(self: *State) !bool {
        if (!self.waiting) {
            self.waiting = true;
            zsf_menu_layout(zsl_tray_menu_path(self.tray.native.?));
        }
        return self.ready(zsf_layout_ready() != 0);
    }
    fn press(self: *State, keysyms: []const c_ulong, release: bool) !void {
        for (keysyms) |keysym| if (self.xtest(self.display, XKeysymToKeycode(self.display, keysym), 1, 0) == 0) return error.InputInjectionFailed;
        if (release) {
            var index = keysyms.len;
            while (index != 0) {
                index -= 1;
                if (self.xtest(self.display, XKeysymToKeycode(self.display, keysyms[index]), 0, 0) == 0) return error.InputInjectionFailed;
            }
        }
        _ = XFlush(self.display);
    }
    /// Folder loading is asynchronous; answer once GTK shows the choice.
    fn accept(self: *State, count: u32, first: ?[*:0]const u8) !void {
        const chooser = self.owner.chooser orelse return error.MissingChooser;
        _ = try self.ready(zsl_chooser_accept(chooser.native, count, first) != 0);
    }
    fn perform(self: *State) !void {
        switch (self.step) {
            .bus => if (try self.ready(zsf_ready() != 0)) self.advance(),
            .tray_show => {
                if (!self.waiting) {
                    try self.owner.setTray(.{ .tooltip = "Ziggurat 工具" });
                    self.waiting = true;
                }
                if (try self.ready(zsf_registrations() == 1)) self.advance();
            },
            .tray_tooltip => try self.property("ToolTip", "Ziggurat 工具"),
            .tray_icon_name => try self.property("IconName", "application-x-executable"),
            .tray_activate => zsf_item_call("Activate", 5, 6),
            .tray_context => zsf_item_call("ContextMenu", 40, 50),
            .tray_update => {
                const pixbuf = gdk_pixbuf_new(0, 1, 8, 2, 2) orelse return error.OutOfMemory;
                gdk_pixbuf_fill(pixbuf, 0x112233ff);
                try self.owner.setTray(.{ .icon = pixbuf, .tooltip = "Updated" });
                // The icon is borrowed only by the call.
                g_object_unref(pixbuf);
                try std.testing.expectError(error.TextCapacityExceeded, self.owner.setTray(.{ .tooltip = &@as([128]u8, @splat('x')) }));
                self.advance();
            },
            .tray_pixmap => try self.property("IconPixmap", "2x2:ff112233"),
            .standalone_show => {
                if (!self.waiting) {
                    try self.owner.clearTray();
                    try self.tray.show(self.app, .{ .tooltip = "Standalone", .guid = guid, .title = "Ziggurat", .menu = &tray_menu });
                    try std.testing.expectError(error.DuplicateMenuId, self.tray.setMenu(&.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } }));
                    try std.testing.expectError(error.TrayIdentityChanged, self.tray.show(self.app, .{ .tooltip = "Other" }));
                    self.waiting = true;
                }
                if (try self.ready(zsf_registrations() == 2)) self.advance();
            },
            .standalone_id => try self.property("Id", "1032547698badcfe0123456789abcdef"),
            .standalone_label => try self.property("XAyatanaLabel", "Ziggurat"),
            .standalone_menu_path => try self.property("Menu", std.mem.span(zsl_tray_menu_path(self.tray.native.?))),
            .standalone_layout => {
                if (!try self.layout()) return;
                try std.testing.expectEqualStrings("(_Show[Control+s];-;!More(!Deep);Quit*)", std.mem.span(zsf_layout_text()));
                self.revision = zsf_layout_revision();
                self.advance();
            },
            .standalone_menu_click => {
                if (self.waiting) return;
                self.waiting = true;
                const path = zsl_tray_menu_path(self.tray.native.?);
                zsf_menu_click(path, zsf_layout_id(4));
                self.stale_id = zsf_layout_id(5);
                zsf_menu_click(path, self.stale_id);
            },
            .standalone_menu_replace => {
                if (!self.waiting) try self.tray.setMenu(&.{.{ .id = 12, .label = "Open" }});
                if (!try self.layout()) return;
                try std.testing.expectEqualStrings("(Open)", std.mem.span(zsf_layout_text()));
                try std.testing.expectEqual(self.revision + 1, zsf_layout_revision());
                self.advance();
            },
            .standalone_menu_replaced => {
                if (self.waiting) return;
                self.waiting = true;
                const path = zsl_tray_menu_path(self.tray.native.?);
                zsf_menu_click(path, self.stale_id);
                zsf_menu_click(path, zsf_layout_id(1));
            },
            .standalone_context => zsf_item_call("ContextMenu", 30, 31),
            .standalone_popup => {
                if (!self.waiting) {
                    try self.tray.popupMenu(77, &menu, .icon);
                    try std.testing.expectError(error.MenuAlreadyPending, self.tray.popupMenu(78, &menu, .pointer));
                    self.waiting = true;
                }
                try std.testing.expect(zsl_popup_activate(self.tray.popup.pending.native.?, 1) == 1);
            },
            .notify_show => {
                if (!self.waiting) {
                    try self.tray.remove();
                    try std.testing.expectError(error.EmptyNotification, self.owner.showNotification(5, .{ .title = "x", .body = "" }));
                    try std.testing.expectError(error.InvalidNotificationId, self.owner.showNotification(0, .{ .title = "x", .body = "y" }));
                    try self.owner.showNotification(5, .{ .title = "完成", .body = "导出完成", .kind = .err });
                    self.waiting = true;
                }
                if (!try self.ready(zsf_notify_count() == 1 and self.owner.notification != null and system.message.resourceCount() > 0)) return;
                try std.testing.expectEqualStrings("完成", std.mem.span(zsf_last_summary()));
                try std.testing.expectEqualStrings("导出完成", std.mem.span(zsf_last_body()));
                try std.testing.expect(zsf_last_urgency() == 2 and zsf_last_silent() == 1 and zsf_last_transient() == 1);
                self.notification_id = zsf_last_id();
                self.advance();
            },
            .notify_check => zsf_invoke(self.notification_id),
            .notify_replace => {
                // Activation withdrew the shown notification. A replacement
                // withdraws the one the server already shows.
                if (!self.waiting) {
                    try std.testing.expect(self.owner.notification == null);
                    try self.owner.showNotification(6, .{ .title = "First", .body = "Replaced" });
                    self.waiting = true;
                }
                if (!try self.ready(zsf_notify_count() == 2)) return;
                const first = zsf_last_id();
                try self.owner.showNotification(7, .{ .title = "Second", .body = "Closed by the server", .silent = false, .real_time = false });
                // One replaced before the bus answers is never sent at all.
                try self.owner.showNotification(7, .{ .title = "Second", .body = "Closed by the server", .silent = false, .real_time = false });
                self.notification_id = first;
                self.advance();
            },
            .notify_withdrawn => {
                if (!try self.ready(zsf_notify_count() == 3 and zsf_closed_by_client() == self.notification_id)) return;
                try std.testing.expect(zsf_last_silent() == 0 and zsf_last_transient() == 0 and zsf_last_urgency() == 1);
                self.notification_id = zsf_last_id();
                zsf_server_close(self.notification_id);
                self.advance();
            },
            .notify_replaced => {
                if (!self.waiting) {
                    zsf_invoke(self.notification_id - 1);
                    self.waiting = true;
                }
                if (!try self.ready(self.owner.notification == null)) return;
                try self.owner.showNotification(8, .{ .title = "Third", .body = "Activated" });
                self.advance();
            },
            .notify_latest => {
                if (try self.ready(zsf_notify_count() == 4 and zsf_last_id() == self.notification_id + 1)) {
                    // A stale activation from the closed notification is ignored.
                    zsf_invoke(self.notification_id);
                    zsf_invoke(zsf_last_id());
                }
            },
            .hotkey_press => {
                if (!self.waiting) {
                    try std.testing.expectError(error.InvalidHotkeyId, self.owner.registerHotkey(0, .{ .key = .f9 }));
                    try self.owner.registerHotkey(1, .{ .key = .f9, .modifiers = .{ .control = true, .shift = true } });
                    try std.testing.expectError(error.DuplicateHotkeyId, self.owner.registerHotkey(1, .{ .key = .f8 }));
                    try std.testing.expectError(error.HotkeyRegistrationFailed, self.owner.registerHotkey(3, .{ .key = .f9, .modifiers = .{ .control = true, .shift = true } }));
                    self.waiting = true;
                    try self.press(&.{ control_l, shift_l, f9 }, true);
                }
            },
            .hotkey_repeat => try self.press(&.{ control_l, shift_l, f9, f9 }, true),
            .hotkey_conflict => {
                if (!self.waiting) {
                    self.waiting = true;
                    zio.sleep(50 * std.time.ns_per_ms);
                    return self.app.post(.{ .context = self, .call = run });
                }
                try std.testing.expectEqual(2, self.hotkeys);
                // Another client already holds Ctrl+Alt+F10.
                const other = XOpenDisplay(null) orelse return error.DisplayUnavailable;
                defer _ = XCloseDisplay(other);
                _ = XGrabKey(other, XKeysymToKeycode(other, f10), control_alt, XDefaultRootWindow(other), 0, 1, 1);
                _ = XSync(other, 0);
                try std.testing.expectError(error.HotkeyRegistrationFailed, self.owner.registerHotkey(2, .{ .key = .f10, .modifiers = .{ .control = true, .alt = true } }));
                try std.testing.expect(self.owner.last_error != 0 and self.owner.hotkey_count == 1);
                try self.owner.unregisterHotkey(1);
                try std.testing.expectError(error.HotkeyNotFound, self.owner.unregisterHotkey(1));
                // The released grab is free for a fresh registration.
                try self.owner.registerHotkey(4, .{ .key = .f9, .modifiers = .{ .control = true, .shift = true } });
                try self.owner.clearHotkeys();
                self.advance();
            },
            .chooser_open => {
                if (!self.waiting) {
                    try self.owner.openFile(.{ .extensions = &.{".txt"} }, &self.destination, self, chosen);
                    try std.testing.expectError(error.DialogAlreadyPending, self.owner.openFile(.{}, &self.destination, self, chosen));
                    _ = zsl_chooser_select(self.owner.chooser.?.native, self.path_ptrs[0..1].ptr, 1, null);
                    self.waiting = true;
                }
                try self.accept(1, self.path_ptrs[0]);
            },
            .chooser_many => {
                // GTK's own dialog offers no scripted multiple selection, so
                // the native result stands in for the user's choice here.
                try self.owner.openFiles(.{ .extensions = &.{ ".txt", ".md" } }, &self.destination, self, chosen);
                try std.testing.expect(zsl_chooser_complete(self.owner.chooser.?.native, self.path_ptrs[0..2].ptr, 2) == 1);
            },
            .chooser_save => {
                if (!self.waiting) {
                    try std.testing.expectError(error.InvalidFileFilters, self.owner.saveFile(.{ .extensions = &.{"*"} }, &self.destination, self, chosen));
                    try std.testing.expectError(error.InvalidSuggestedName, self.owner.saveFile(.{ .suggested_name = "a/b" }, &self.destination, self, chosen));
                    try self.owner.saveFile(.{ .suggested_name = "report" }, &self.destination, self, chosen);
                    const folder: [*:0]const u8 = @ptrCast(self.directory[0..self.directory_len :0].ptr);
                    _ = zsl_chooser_select(self.owner.chooser.?.native, &.{folder}, 1, "out.txt");
                    self.waiting = true;
                }
                try self.accept(1, null);
            },
            .chooser_folder => {
                if (!self.waiting) {
                    try self.owner.pickFolder(.{}, &self.destination, self, chosen);
                    self.waiting = true;
                }
                // Until the parent folder loads, GTK reports the parent itself.
                _ = zsl_chooser_select(self.owner.chooser.?.native, self.path_ptrs[2..3].ptr, 1, null);
                try self.accept(1, self.path_ptrs[2]);
            },
            .chooser_cancel => {
                try self.owner.openFile(.{}, &self.destination, self, chosen);
                try self.owner.cancelFileDialog();
            },
            .chooser_capacity => {
                if (!self.waiting) {
                    try self.owner.openFile(.{}, &self.small, self, chosen);
                    _ = zsl_chooser_select(self.owner.chooser.?.native, self.path_ptrs[0..1].ptr, 1, null);
                    self.waiting = true;
                }
                try self.accept(1, null);
            },
            .chooser_detach => {
                try self.owner.openFile(.{}, &self.destination, self, chosen);
                const before = self.results;
                try self.owner.detach();
                try std.testing.expect(self.owner.chooser == null and self.results == before);
                try self.owner.attach(self.window);
                self.advance();
            },
            .close_window => {
                // Everything an Owner holds goes away with its window.
                try self.owner.setMenu(&menu);
                try self.owner.setTray(.{ .tooltip = "Closing" });
                try self.owner.registerHotkey(9, .{ .key = .f9, .modifiers = .{ .control = true, .shift = true } });
                try self.owner.showNotification(9, .{ .title = "Closing", .body = "Window closes underneath" });
                try self.owner.pickFolder(.{}, &self.destination, self, chosen);
                _ = try self.window.destroy();
            },
            .done => unreachable,
        }
    }
};

pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(allocator.deinit() == .ok);
    if (zsf_start() == 0) return error.SessionBusUnavailable;
    const app = try z.App.init(allocator.allocator());
    defer app.deinit();
    var state: State = .{ .app = app };
    var library = try std.DynLib.open("libXtst.so.6");
    defer library.close();
    state.xtest = library.lookup(XTestKey, "XTestFakeKeyEvent") orelse return error.XTestUnavailable;
    state.display = XOpenDisplay(null) orelse return error.DisplayUnavailable;
    defer _ = XCloseDisplay(state.display);

    try std.Io.Dir.cwd().createDirPath(zio.io(), ".zig-cache/tmp/system-desktop-smoke/folder");
    const directory = try zio.realpath(std.Io.Dir.cwd(), ".zig-cache/tmp/system-desktop-smoke", state.directory[0 .. state.directory.len - 1]);
    state.directory_len = directory.len;
    state.directory[directory.len] = 0;
    for ([_][]const u8{ "a.txt", "b.md", "folder" }, 0..) |name, index| {
        const path = try std.fmt.bufPrintSentinel(&state.paths[index], "{s}/{s}", .{ directory, name }, 0);
        state.path_ptrs[index] = path.ptr;
        if (index < 2) {
            const file = try std.Io.Dir.createFileAbsolute(zio.io(), path, .{});
            file.close(zio.io());
        }
    }

    state.owner = system.Owner.init(&state, State.action);
    state.tray = system.Tray.init(&state, State.trayAction);
    state.window = try app.createWindow(.{ .title = "System desktop smoke", .width = 320, .height = 200, .on_closed = .{ .context = &state, .notify = State.closed } });
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
    try std.testing.expectEqualSlices(u64, &.{ 5, 8 }, state.activated[0..state.activated_count]);
    try std.testing.expectEqual(2, state.hotkeys);
    try std.testing.expectEqual(6, state.results);
    try std.testing.expect(state.tray.native == null);
    std.debug.print("Linux desktop smoke passed: tray export/register/activate/context/update/pixmap, standalone tray identity/label/dbusmenu layout/click/replace/popup, notifications hints/activate/replace/server-close/stale, X11 hotkeys press/repeat/conflict/release, choosers open/many/save/folder/cancel/capacity/detach, window closure; native records left={d}\n", .{system.message.resourceCount()});
}
