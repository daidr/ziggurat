//! Hidden-window check of the system details against the real session: PNG
//! icons, menu item icons, the forced and followed appearance, clipboard clear and bitmaps,
//! opening a URL off the owner thread, and an App that keeps running after its last window closed.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const system = @import("ziggurat_system");
const Watchdog = @import("watchdog.zig").Watchdog;
const exitAfter = @import("watchdog.zig").exitAfter;

const windows = builtin.os.tag == .windows;
const linux = builtin.os.tag == .linux;
const c = @import("ziggurat_c_win32");
extern "dwmapi" fn DwmGetWindowAttribute(c.HWND, u32, *anyopaque, u32) callconv(.winapi) c.HRESULT;
extern fn zsx_window_icon(window: *anyopaque) ?*anyopaque;
extern fn zsx_theme_prefers_dark() c_int;
extern fn zsl_test_menubar_icon(bar: *anyopaque, command: i32) c_int;
extern fn zsl_test_tray_icon(tray: *anyopaque, index: u32) usize;

const Step = enum { clipboard_written, clipboard_cleared, bitmap, open_url, close_window, done };

const State = struct {
    app: *z.App,
    window: z.Window = undefined,
    board: system.clipboard.Board = undefined,
    request: system.clipboard.Request = .{},
    buffer: [4096]u8 = undefined,
    step: Step = .clipboard_written,
    open: system.OpenUrl = .{},
    open_result: ?anyerror!void = null,
    all_closed: usize = 0,
    failure: ?anyerror = null,

    fn fail(self: *State, err: anyerror) void {
        std.debug.print("step {s} failed: {s}\n", .{ @tagName(self.step), @errorName(err) });
        if (self.failure == null) self.failure = err;
        self.app.quit();
    }
    fn result(ptr: *anyopaque, value: system.clipboard.Result) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.check(value) catch |err| self.fail(err);
    }
    fn check(self: *State, value: system.clipboard.Result) !void {
        switch (self.step) {
            .clipboard_written => {
                try std.testing.expect(value.formats.text);
                try self.board.clear();
                self.step = .clipboard_cleared;
                try self.board.formats(&self.request, self, result);
            },
            .clipboard_cleared => {
                try std.testing.expect(!value.formats.text and !value.formats.png);
                self.step = .bitmap;
                if (windows) {
                    try putBitmap(self.window);
                    try self.board.read(&self.request, .{ .kind = .png }, &self.buffer, self, result, .{});
                } else try self.openUrl();
            },
            .bitmap => {
                // The bitmap reads as a PNG stream the system decodes.
                var icon = try system.Icon.fromPng(self.app, value.data);
                defer icon.deinit();
                try std.testing.expectEqual(system.icon.Size{ .width = 2, .height = 2 }, icon.size);
                try self.openUrl();
            },
            else => return error.UnexpectedResult,
        }
    }
    fn openUrl(self: *State) !void {
        self.step = .open_url;
        // A Windows shell offers to find an app for an unknown scheme, so
        // only Linux opens one; GIO fails it without asking.
        if (!linux) return self.closeWindow();
        try self.open.start(self.app, "ziggurat-smoke-none://nothing", .{ .extra_schemes = &.{"ziggurat-smoke-none"} }, self, opened);
        try std.testing.expect(self.open.pending());
    }
    fn opened(ptr: *anyopaque, request: *system.OpenUrl) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.open_result = request.result;
        std.testing.expect(!request.pending()) catch |err| return self.fail(err);
        self.closeWindow() catch |err| self.fail(err);
    }
    fn closeWindow(self: *State) !void {
        self.step = .close_window;
        _ = try self.window.destroy();
    }
    fn allClosed(ptr: *anyopaque, app: *z.App) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.all_closed += 1;
        self.step = .done;
        app.quit();
    }
};

fn putBitmap(window: z.Window) !void {
    const hwnd: c.HWND = @ptrCast(window.nativeHandle().?);
    var dib: [40 + 16]u8 = @splat(0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 2, .little);
    std.mem.writeInt(i32, dib[8..12], 2, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    @memset(dib[40..], 0x80);
    const block = c.GlobalAlloc(c.GMEM_MOVEABLE, dib.len) orelse return error.OutOfMemory;
    const pointer: [*]u8 = @ptrCast(c.GlobalLock(block) orelse return error.OutOfMemory);
    @memcpy(pointer[0..dib.len], &dib);
    _ = c.GlobalUnlock(block);
    if (c.OpenClipboard(hwnd) == 0) return error.ClipboardBusy;
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    if (c.SetClipboardData(c.CF_DIB, block) == null) return error.ClipboardWriteFailed;
}

fn frameDark(window: z.Window) !bool {
    var value: c.BOOL = 0;
    if (DwmGetWindowAttribute(@ptrCast(window.nativeHandle().?), 20, &value, @sizeOf(c.BOOL)) < 0) return error.DwmQueryFailed;
    return value != 0;
}

/// Commands and submenus show icons beside their labels, but the items of
/// the bar itself show none; setItemIcon replaces and removes them, and
/// remade items keep them.
fn menuIcons(app: *z.App, window: z.Window, png: []const u8) !void {
    try std.testing.expectError(error.InvalidPng, system.MenuIcon.fromPng(app, "not a png", .{}));
    var full = try system.MenuIcon.fromPng(app, png, .{});
    defer full.deinit();
    var template = try system.MenuIcon.fromPng(app, png, .{ .template = true });
    defer template.deinit();
    var owner = system.Owner.init(app, struct {
        fn action(_: *anyopaque, _: z.Window, _: system.Action) void {}
    }.action);
    try owner.attach(window);
    defer owner.detach() catch {};
    try owner.setMenu(&.{
        .{ .id = 40, .kind = .submenu, .label = "File", .icon = &full },
        .{ .id = 41, .parent = 40, .label = "Open", .icon = &full, .accelerator = .{ .key = .o, .modifiers = .{ .control = true } } },
        .{ .id = 42, .parent = 40, .label = "Wrap", .checked = true, .icon = &template },
        .{ .id = 43, .parent = 40, .label = "Plain" },
        .{ .id = 44, .label = "Top", .icon = &full },
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false }, &try shownIcons(&owner, .{ 41, 42, 43, 44 }));
    try owner.setItemIcon(41, null);
    try owner.setItemIcon(43, &template);
    try owner.setItemIcon(44, &full);
    // Unchecked, GTK makes the item again.
    try owner.setItemState(42, true, false);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, false }, &try shownIcons(&owner, .{ 41, 42, 43, 44 }));
    try std.testing.expectError(error.MenuItemNotFound, owner.setItemIcon(99, &full));
    if (windows) {
        // The bar's own items, submenus included, show no bitmap; the
        // icons fit 16 DIPs at the window's DPI.
        var info = std.mem.zeroes(c.MENUITEMINFOW);
        info.cbSize = @sizeOf(c.MENUITEMINFOW);
        info.fMask = c.MIIM_BITMAP;
        try std.testing.expect(c.GetMenuItemInfoW(owner.menu, 0, c.TRUE, &info) != 0);
        try std.testing.expectEqual(null, info.hbmpItem);
        const bitmap = itemBitmap(&owner, 42).?;
        var object: c.BITMAP = undefined;
        try std.testing.expect(c.GetObjectW(bitmap, @sizeOf(c.BITMAP), &object) != 0);
        const dpi = c.GetDpiForWindow(@ptrCast(window.nativeHandle().?));
        try std.testing.expectEqual(@as(c_long, @intCast(16 * @max(dpi, 96) / 96)), object.bmWidth);
        try std.testing.expectEqual(32, object.bmBitsPixel);
    }
    if (linux) {
        // A tray's panel gets the PNG as DBusMenu's icon-data.
        var tray = system.Tray.init(app, struct {
            fn action(_: *anyopaque, _: *system.Tray, _: system.TrayAction) void {}
        }.action);
        try tray.show(app, .{ .tooltip = "Icons", .menu = &.{ .{ .id = 50, .label = "Tokyo", .radio = true, .checked = true, .icon = &full }, .{ .id = 51, .label = "Direct", .radio = true } } });
        defer tray.remove() catch {};
        try std.testing.expectEqual(png.len, zsl_test_tray_icon(tray.native.?, 0));
        try std.testing.expectEqual(0, zsl_test_tray_icon(tray.native.?, 1));
    }
}
fn shownIcons(owner: *system.Owner, ids: [4]u64) ![4]bool {
    var shown: [4]bool = undefined;
    for (ids, &shown) |id, *value| {
        if (windows) value.* = itemBitmap(owner, id) != null;
        if (linux) {
            const index = for (owner.bar_entries[0..owner.bar_count], 0..) |entry, at| {
                if (entry.id == id) break at;
            } else return error.MenuItemNotFound;
            const result = zsl_test_menubar_icon(owner.bar.?, @intCast(index));
            if (result < 0) return error.MenuItemBroken;
            value.* = result == 1;
        }
    }
    return shown;
}
fn itemBitmap(owner: *system.Owner, id: u64) ?c.HBITMAP {
    for (owner.entries[0..owner.entry_count]) |entry| if (entry.id == id) {
        var info = std.mem.zeroes(c.MENUITEMINFOW);
        info.cbSize = @sizeOf(c.MENUITEMINFOW);
        info.fMask = c.MIIM_BITMAP;
        if (c.GetMenuItemInfoW(entry.menu, entry.command, c.FALSE, &info) == 0) return null;
        return info.hbmpItem;
    };
    return null;
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const allocator = debug.allocator();
    try exitAfter("system details smoke", 120);
    var state: State = .{ .app = undefined };
    const app = try z.App.initWithOptions(allocator, .{ .on_all_windows_closed = .{ .context = &state, .closed = State.allClosed } });
    defer app.deinit();
    state.app = app;
    var watchdog: Watchdog = .{ .app = app };
    try watchdog.start();
    defer watchdog.stop();
    state.window = try app.createWindow(.{ .title = "System details" });

    // A bitmap encoded as PNG, decoded by the system as an icon.
    var dib: [40 + 16 * 16 * 4]u8 = @splat(0x40);
    @memset(dib[0..40], 0);
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], 16, .little);
    std.mem.writeInt(i32, dib[8..12], 16, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    var png_bytes: [2048]u8 = undefined;
    const png = try system.bitmap.dibToPng(&dib, &png_bytes);
    var icon = try system.Icon.fromPng(app, png);
    defer icon.deinit();
    try std.testing.expectEqual(system.icon.Size{ .width = 16, .height = 16 }, icon.size);
    try std.testing.expectError(error.InvalidPng, system.Icon.fromPng(app, "not a png"));
    try system.icon.setWindowIcon(state.window, &icon);
    if (windows) {
        const big = c.SendMessageW(@ptrCast(state.window.nativeHandle().?), c.WM_GETICON, c.ICON_BIG, 0);
        try std.testing.expectEqual(@intFromPtr(icon.handle()), @as(usize, @bitCast(big)));
    } else try std.testing.expectEqual(icon.handle(), zsx_window_icon(state.window.nativeHandle().?).?);
    try menuIcons(app, state.window, png);
    var tray = system.Tray.init(&state, struct {
        fn action(_: *anyopaque, _: *system.Tray, _: system.TrayAction) void {}
    }.action);
    // The PNG icon serves a tray item as a native one does; App shutdown
    // removes the item.
    if (windows) try tray.show(app, .{ .icon = icon.handle(), .tooltip = "Details" });

    // A forced appearance reaches what the system draws.
    var follower: system.theme.Follower = .{};
    try follower.start(app, .{ .source = .dark });
    try std.testing.expect(follower.isDark());
    try follower.track(state.window);
    if (windows) try std.testing.expect(try frameDark(state.window));
    if (linux) try std.testing.expectEqual(1, zsx_theme_prefers_dark());
    follower.setSource(.light);
    try std.testing.expect(!follower.isDark());
    if (windows) try std.testing.expect(!try frameDark(state.window));
    if (linux) try std.testing.expectEqual(0, zsx_theme_prefers_dark());
    // A window's buttons keep their own appearance through the app's.
    try follower.setWindowButtons(state.window, .dark);
    if (windows) try std.testing.expect(try frameDark(state.window));
    follower.setSource(.light);
    if (windows) try std.testing.expect(try frameDark(state.window));
    try follower.setWindowButtons(state.window, .system);
    if (windows) try std.testing.expect(!try frameDark(state.window));
    follower.setSource(.system);
    try std.testing.expectEqual(follower.preferences().color_scheme == .dark, follower.isDark());

    try state.board.init(app, .{});
    defer state.board.deinit();
    try state.board.write(&.{.{ .format = .{ .kind = .text }, .data = "details" }});
    try state.board.formats(&state.request, &state, State.result);

    try app.run();
    follower.stop();
    if (state.failure) |err| return err;
    try std.testing.expectEqual(Step.done, state.step);
    try std.testing.expectEqual(1, state.all_closed);
    if (linux) try std.testing.expect(std.meta.isError(state.open_result.?));
    std.debug.print("system details passed: png icon, menu icons, appearance, clipboard clear/bitmap, open url={s}, running without windows\n", .{if (state.open_result) |value| (if (value) |_| "opened" else |err| @errorName(err)) else "skipped"});
}
