//! The settings portal's color-scheme reaches GTK's prefer-dark setting, from
//! which WebKitGTK takes pages' prefers-color-scheme, while the app follows
//! the desktop, and not while it forces an appearance. Needs a session bus:
//! dbus-run-session -- xvfb-run. The app's GTK style sheet restyles what
//! GTK draws, replaced by the next that parses.
const std = @import("std");
const z = @import("ziggurat");
const system = @import("ziggurat_system");

extern fn zpf_start(u32) c_int;
extern fn zpf_owned() c_int;
extern fn zpf_reads() c_int;
extern fn zpf_change(u32) void;
extern fn zpf_pump(c_int) void;
extern fn zpf_prefers_dark() c_int;
extern fn zpf_label_color() c_uint;

/// Pump until GTK prefers `dark`, for up to two seconds.
fn expectDark(dark: bool) !void {
    var waited: usize = 0;
    while ((zpf_prefers_dark() != 0) != dark) : (waited += 1) {
        if (waited == 100) {
            std.debug.print("theme portal: prefer-dark stayed {d}, want {}\n", .{ zpf_prefers_dark(), dark });
            return error.PreferDarkMismatch;
        }
        zpf_pump(20);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    if (zpf_start(1) == 0) return error.NoSessionBus;
    var waited: usize = 0;
    while (zpf_owned() == 0) : (waited += 1) {
        if (waited == 100) return error.PortalNameNotOwned;
        zpf_pump(20);
    }
    const app = try z.App.init(gpa.allocator());
    defer app.deinit();
    // The portal's dark style reaches GTK at start, with no source set.
    try expectDark(true);
    try std.testing.expect(zpf_reads() >= 1);
    // The desktop switches to light, and back to dark.
    zpf_change(2);
    try expectDark(false);
    zpf_change(1);
    try expectDark(true);
    // A forced appearance owns the setting; the portal changes nothing.
    system.theme.apply(app, .light, false);
    try expectDark(false);
    zpf_change(2);
    zpf_change(1);
    zpf_pump(200);
    try expectDark(false);
    // Following the desktop again takes the portal's latest style.
    system.theme.apply(app, .system, true);
    try expectDark(true);
    zpf_change(0);
    try expectDark(false);
    // The app's style sheet wins over the theme; one that does not parse
    // keeps the one before, and "" removes it.
    const themed = zpf_label_color();
    try system.theme.setGtkCss(app, "label { color: #123456; }", null);
    try std.testing.expectEqual(@as(c_uint, 0x123456), zpf_label_color());
    var message: [system.theme.max_css_error]u8 = undefined;
    try std.testing.expectError(error.InvalidStyleSheet, system.theme.setGtkCss(app, "label { color: ", &message));
    try std.testing.expect(std.mem.sliceTo(&message, 0).len > 0);
    try std.testing.expectEqual(@as(c_uint, 0x123456), zpf_label_color());
    try system.theme.setGtkCss(app, "label { color: #654321; }", null);
    try std.testing.expectEqual(@as(c_uint, 0x654321), zpf_label_color());
    try system.theme.setGtkCss(app, "", null);
    try std.testing.expectEqual(themed, zpf_label_color());
    std.debug.print("theme portal: color-scheme follows into GTK while the app follows the desktop; the app's GTK sheet applies and is replaced\n", .{});
}
