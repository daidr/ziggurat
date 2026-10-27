//! A notification-area app whose icon opens a flyout, the panel of the
//! app: above the icon of the Windows taskbar, below an icon of a panel at
//! the top. It closes as the user clicks elsewhere, presses Escape or
//! clicks the icon again.
//!
//! The panel is the app's only visible window; a window that never shows
//! keeps the App running while the panel is closed. Linux indicators show
//! menus only and report no clicks, so there the icon's menu opens the
//! panel.
//!
//! Run it with `zig build run-menubar-flyout`. On Linux the icon needs a
//! status-notifier host on the session bus.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const view = @import("ziggurat_view");
const system = @import("ziggurat_system");

const open_command = 1;
const quit_command = 2;
const quit_action = 10;
const muted: u32 = 0x5f6b7a;

const menu = [_]system.Item{
    .{ .id = open_command, .label = "Open Focus" },
    .{ .kind = .separator },
    .{ .id = quit_command, .label = "Quit" },
};

/// All state is read and changed on the main thread, by tray callbacks and
/// the view.
const Focus = struct {
    app: ?*z.App = null,
    tray: system.Tray = undefined,
    panel: system.Flyout = .{},
    storage: view.Storage(32, 512) = .{},
    host: view.Host = undefined,
    focus: bool = false,
    sound: bool = true,
    minutes: f64 = 25,

    fn build(self: *Focus, v: *view.View) anyerror!void {
        try v.column(.{ .grow = 1, .self_align = .stretch, .padding = view.Insets.all(16), .gap = 12, .radius = 10, .border = 0xc9d1dc, .background = 0xffffff });
        try v.text("Focus", .{ .font = .{ .size = 17, .weight = .bold } });
        _ = try v.toggleSwitch(&self.focus, "Focus mode", .{ .self_align = .stretch });
        _ = try v.toggleSwitch(&self.sound, "Sound", .{ .self_align = .stretch });
        try v.textf("Sessions of {d} minutes", .{@as(u32, @intFromFloat(self.minutes))}, .{ .color = muted, .font = .{ .size = 12 } });
        _ = try v.slider(&self.minutes, .{ .minimum = 5, .maximum = 60, .step = 1 }, .{ .name = "Session length", .self_align = .stretch });
        try v.spacer(.{});
        try v.row(.{ .self_align = .stretch });
        try v.spacer(.{});
        if (try v.button("Quit", .{ .key = quit_action })) self.quit();
        try v.end();
        try v.end();
    }

    /// Opens the panel next to the icon, or closes it.
    fn toggle(self: *Focus) void {
        if (self.panel.isOpen()) {
            _ = self.panel.close() catch {};
            return;
        }
        const app = self.app orelse return;
        const window = self.panel.open(app, .{
            .anchor = .{ .tray = &self.tray },
            .placement = .bottom,
            .gap = 4,
            .width = 280,
            .height = 264,
            .focusable = true,
            .shadow = true,
            .hidden = true,
            .title = "Focus",
        }) catch |err| return std.log.err("panel: {s}", .{@errorName(err)});
        // The Host of an earlier panel detached with its window.
        self.host = view.Host.init(self, build, self.storage.buffers(), .{ .root = .{ .padding = view.Insets.all(0) } });
        self.host.attach(window) catch |err| {
            std.log.err("panel content: {s}", .{@errorName(err)});
            _ = window.destroy() catch {};
            return;
        };
        self.panel.show();
    }

    fn quit(self: *Focus) void {
        if (self.app) |app| app.quit();
    }

    fn onTray(ptr: *anyopaque, tray: *system.Tray, action: system.TrayAction) void {
        const self: *Focus = @ptrCast(@alignCast(ptr));
        switch (action) {
            .activate => self.toggle(),
            .context => {
                if (self.panel.isOpen()) _ = self.panel.close() catch {};
                tray.popupMenu(1, &menu, .icon) catch |err| std.log.err("tray menu: {s}", .{@errorName(err)});
            },
            .menu => |id| self.command(id),
            .popup => |result| if (result.selected) |id| self.command(id),
        }
    }

    fn command(self: *Focus, id: u64) void {
        switch (id) {
            open_command => if (!self.panel.isOpen()) self.toggle(),
            quit_command => self.quit(),
            else => {},
        }
    }
};

/// A target: blue rings on transparent, which show on light and dark
/// taskbars.
fn trayPixels() [32 * 32 * 4]u8 {
    var pixels: [32 * 32 * 4]u8 = @splat(0);
    for (0..32) |y| for (0..32) |x| {
        const dx = @as(f32, @floatFromInt(x)) - 15.5;
        const dy = @as(f32, @floatFromInt(y)) - 15.5;
        const d = dx * dx + dy * dy;
        if ((d < 15 * 15 and d > 11 * 11) or (d < 7 * 7 and d > 4 * 4) or d < 1.5 * 1.5) {
            const i = (y * 32 + x) * 4;
            pixels[i..][0..4].* = .{ 79, 124, 255, 255 };
        }
    };
    return pixels;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();

    var focus: Focus = .{ .app = app };
    focus.tray = system.Tray.init(&focus, Focus.onTray);
    // Never shown: it keeps the App running while the panel is closed.
    _ = try app.createWindow(.{ .title = "Focus", .width = 1, .height = 1 });

    const pixels = trayPixels();
    const icon = system.TrayIcon.init(32, 32, &pixels) catch |err| blk: {
        std.log.warn("tray icon: {s}; using the application's", .{@errorName(err)});
        break :blk null;
    };
    // Linux indicators report no clicks: there the menu is the way in.
    try focus.tray.show(app, .{
        .icon = if (icon) |value| value.handle else null,
        .tooltip = "Focus",
        .title = "Focus",
        .menu = if (builtin.os.tag == .linux) &menu else null,
    });
    if (icon) |value| value.deinit();
    defer focus.tray.remove() catch {};
    try app.run();
}

test "the panel's controls" {
    var focus: Focus = .{};
    var storage: view.Storage(32, 512) = .{};
    var h = view.Harness.init(&focus, Focus.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 280, .height = 264 } });
    try h.render();
    _ = try h.find(.{ .text = "Sessions of 25 minutes" });
    try h.click(.{ .text = "Focus mode" });
    try std.testing.expect(focus.focus);
    try h.click(.{ .text = "Sound" });
    try std.testing.expect(!focus.sound);
    try std.testing.expectEqual(@as(usize, 1), h.count(.{ .kind = .slider }));
    focus.minutes = 40;
    try h.render();
    _ = try h.find(.{ .text = "Sessions of 40 minutes" });
}

test "the icon is a target" {
    const pixels = trayPixels();
    // The center dot and the outer ring are drawn, the gap between is not.
    try std.testing.expectEqual(@as(u8, 255), pixels[(15 * 32 + 15) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 255), pixels[(15 * 32 + 2) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 0), pixels[(15 * 32 + 6) * 4 + 3]);
}
