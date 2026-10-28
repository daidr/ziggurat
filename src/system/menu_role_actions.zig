//! The window and application behavior of standard menu roles. Edit, view
//! and document roles belong to the content that has focus, so `perform`
//! leaves them to the caller.
const z = @import("ziggurat");
const roles = @import("menu_roles.zig");

pub const Outcome = enum { performed, unhandled };

/// Runs the default action of a role item's ID on the owner thread. `window`
/// is the window whose menu or keyboard focus chose the item.
pub fn perform(app: *z.App, window: ?z.Window, id: u64) !Outcome {
    const role = roles.Role.fromId(id) orelse return .unhandled;
    switch (role) {
        .quit => _ = app.requestQuit(),
        .close => {
            const target = window orelse return .unhandled;
            _ = try target.requestCloseFrom(.user);
        },
        .minimize => try (window orelse return .unhandled).perform(.minimize),
        .zoom => {
            const target = window orelse return .unhandled;
            const state = try target.state();
            try target.perform(if (state.maximized) .restore else .maximize);
        },
        .toggle_full_screen => {
            const target = window orelse return .unhandled;
            const state = try target.state();
            try target.setFullscreen(!state.fullscreen_requested);
        },
        else => return .unhandled,
    }
    return .performed;
}

test "window roles act on the chosen window and other roles stay with the caller" {
    const std = @import("std");
    const app = try z.App.init(std.testing.allocator);
    defer app.deinit();
    const window = try app.createWindow(.{});
    try std.testing.expectEqual(Outcome.unhandled, try perform(app, window, roles.Role.copy.id()));
    try std.testing.expectEqual(Outcome.unhandled, try perform(app, window, 7));
    try std.testing.expectEqual(Outcome.unhandled, try perform(app, null, roles.Role.close.id()));
    try std.testing.expectEqual(Outcome.performed, try perform(app, window, roles.Role.zoom.id()));
    try std.testing.expect((try window.state()).maximized);
    try std.testing.expectEqual(Outcome.performed, try perform(app, window, roles.Role.zoom.occurrenceId(1)));
    try std.testing.expect(!(try window.state()).maximized);
    try std.testing.expectEqual(Outcome.performed, try perform(app, window, roles.Role.toggle_full_screen.id()));
    try std.testing.expect((try window.state()).fullscreen);
    try std.testing.expectEqual(Outcome.performed, try perform(app, window, roles.Role.close.id()));
    try std.testing.expect(window.isClosed());
}
