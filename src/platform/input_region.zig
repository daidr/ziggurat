//! The pointer against a window's input region (`Window.setInputRegion`),
//! for backends whose system shapes no window's input and lets the pointer
//! through all of a window or none of it (macOS, Windows), switching as the
//! pointer moves. Linux gives the region to the window's input shape.
const core = @import("../root.zig");

/// Whether x, y, in DIP from the top-left corner of the client area, is in
/// one of the rectangles, their far edges excluded.
pub fn contains(region: []const core.Rect, x: f32, y: f32) bool {
    for (region) |rect| if (rect.contains(.{ .x = x, .y = y })) return true;
    return false;
}

/// Whether a window with an input region lets the pointer through to what
/// is behind it, the pointer at x, y: through outside the rectangles, and
/// as it was, `through`, while a button is held. A press that started on
/// the window, as one dragging it by its character, keeps the window until
/// it ends, as one that started behind it keeps what is behind; the release
/// settles it.
pub fn letsPointerThrough(region: []const core.Rect, x: f32, y: f32, held: bool, through: bool) bool {
    if (held) return through;
    return !contains(region, x, y);
}

test contains {
    const std = @import("std");
    const region = [_]core.Rect{ .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .{ .x = 100, .y = 0, .width = 5, .height = 5 } };
    const cases = [_]struct { x: f32, y: f32, want: bool }{
        .{ .x = 10, .y = 20, .want = true },
        .{ .x = 39.9, .y = 59.9, .want = true },
        .{ .x = 40, .y = 30, .want = false },
        .{ .x = 20, .y = 60, .want = false },
        .{ .x = 9.9, .y = 30, .want = false },
        .{ .x = 102, .y = 2, .want = true },
        .{ .x = -1, .y = -1, .want = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, contains(&region, case.x, case.y));
    try std.testing.expect(!contains(&.{}, 0, 0));
}

test letsPointerThrough {
    const std = @import("std");
    const region = [_]core.Rect{.{ .x = 0, .y = 0, .width = 10, .height = 10 }};
    try std.testing.expect(!letsPointerThrough(&region, 5, 5, false, true));
    try std.testing.expect(letsPointerThrough(&region, 50, 5, false, false));
    // A press on the window dragged off it, and one behind dragged onto it.
    try std.testing.expect(!letsPointerThrough(&region, 50, 5, true, false));
    try std.testing.expect(letsPointerThrough(&region, 5, 5, true, true));
    try std.testing.expect(letsPointerThrough(&.{}, 5, 5, false, false));
}
