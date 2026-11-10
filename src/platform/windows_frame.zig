//! The frame policy of Windows windows, as plain computation.

/// A transparent window without the system's frame, a material or a shadow
/// (a popup's, or the one DWM gives a rounded window) keeps its sizing
/// borders for hit testing, but neither DWM nor GDI draws a frame, an
/// outline or an activation border over what its frames leave transparent.
pub fn plainTransparentFrame(options: anytype, has_material: bool) bool {
    const shadowed = if (options.popup) |role| role.shadow else options.corner_radius > 0;
    return options.decoration != .system and options.transparent and !has_material and !shadowed;
}

test "only a shadowless transparent window of its own frames goes without native frame painting" {
    const std = @import("std");
    const Role = struct { shadow: bool };
    const Options = struct { decoration: enum { system, borderless, custom } = .borderless, transparent: bool = true, corner_radius: f32 = 0, popup: ?Role = null };
    try std.testing.expect(plainTransparentFrame(Options{}, false));
    try std.testing.expect(plainTransparentFrame(Options{ .decoration = .custom }, false));
    try std.testing.expect(plainTransparentFrame(Options{ .popup = .{ .shadow = false } }, false));
    try std.testing.expect(!plainTransparentFrame(Options{ .transparent = false }, false));
    try std.testing.expect(!plainTransparentFrame(Options{ .decoration = .system }, false));
    try std.testing.expect(!plainTransparentFrame(Options{}, true));
    try std.testing.expect(!plainTransparentFrame(Options{ .corner_radius = 8 }, false));
    try std.testing.expect(!plainTransparentFrame(Options{ .popup = .{ .shadow = true } }, false));
}
