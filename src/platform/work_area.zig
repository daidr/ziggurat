//! Screen geometry of Windows' maximize, kept free of Win32 types so its
//! rules run under the test backend.

pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The rectangle of a window maximized into the work area of a monitor, for
/// one, `r`, that Windows maximized over the whole monitor: it overhangs the
/// work area as `r` overhangs the monitor, by the invisible borders a
/// maximized window keeps off screen. Null when `r` does not cover the
/// monitor, or the work area is the whole monitor (no taskbar, or one that
/// hides).
pub fn maximized(r: Rect, monitor: Rect, work: Rect) ?Rect {
    if (std.meta.eql(work, monitor) or r.left > monitor.left or r.top > monitor.top or r.right < monitor.right or r.bottom < monitor.bottom) return null;
    return .{
        .left = work.left - (monitor.left - r.left),
        .top = work.top - (monitor.top - r.top),
        .right = work.right + (r.right - monitor.right),
        .bottom = work.bottom + (r.bottom - monitor.bottom),
    };
}

/// Where a maximized window belongs once it is maximized: the work area,
/// overhung by what lies outside the part DWM shows of it (`shown`). Null
/// when it is there already or the work area is the whole monitor.
pub fn fit(r: Rect, shown: Rect, monitor: Rect, work: Rect) ?Rect {
    if (std.meta.eql(work, monitor)) return null;
    const visible = if (shown.right > shown.left) shown else r;
    const result: Rect = .{
        .left = work.left - (visible.left - r.left),
        .top = work.top - (visible.top - r.top),
        .right = work.right + (r.right - visible.right),
        .bottom = work.bottom + (r.bottom - visible.bottom),
    };
    return if (std.meta.eql(result, r)) null else result;
}

const std = @import("std");

test "a window maximized over the monitor moves into its work area with the same borders" {
    const monitor: Rect = .{ .left = 0, .top = 0, .right = 3840, .bottom = 2160 };
    // A taskbar 96 px high at 200%.
    const bottom: Rect = .{ .left = 0, .top = 0, .right = 3840, .bottom = 2064 };
    const over: Rect = .{ .left = -16, .top = -16, .right = 3856, .bottom = 2176 };
    try std.testing.expectEqual(Rect{ .left = -16, .top = -16, .right = 3856, .bottom = 2080 }, maximized(over, monitor, bottom).?);
    try std.testing.expectEqual(Rect{ .left = 104, .top = -16, .right = 3856, .bottom = 2176 }, maximized(over, monitor, .{ .left = 120, .top = 0, .right = 3840, .bottom = 2160 }).?);
    try std.testing.expectEqual(bottom, maximized(monitor, monitor, bottom).?);
    // A secondary monitor above and to the right of the primary one.
    try std.testing.expectEqual(Rect{ .left = 3832, .top = -88, .right = 5768, .bottom = 960 }, maximized(.{ .left = 3832, .top = -88, .right = 5768, .bottom = 1008 }, .{ .left = 3840, .top = -80, .right = 5760, .bottom = 1000 }, .{ .left = 3840, .top = -80, .right = 5760, .bottom = 952 }).?);
    try std.testing.expectEqual(@as(?Rect, null), maximized(.{ .left = -16, .top = -16, .right = 3856, .bottom = 2080 }, monitor, bottom));
    try std.testing.expectEqual(@as(?Rect, null), maximized(over, monitor, monitor));
    try std.testing.expectEqual(@as(?Rect, null), maximized(.{ .left = 100, .top = 100, .right = 900, .bottom = 700 }, monitor, bottom));
}

test "a maximized window fits the work area by what DWM shows of it" {
    const monitor: Rect = .{ .left = 0, .top = 0, .right = 1024, .bottom = 768 };
    const work: Rect = .{ .left = 0, .top = 0, .right = 1024, .bottom = 728 };
    const r: Rect = .{ .left = -8, .top = -8, .right = 1032, .bottom = 776 };
    try std.testing.expectEqual(Rect{ .left = -8, .top = -8, .right = 1032, .bottom = 736 }, fit(r, monitor, monitor, work).?);
    // Without what DWM shows, the window's own rectangle counts as shown.
    try std.testing.expectEqual(work, fit(r, .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, monitor, work).?);
    try std.testing.expectEqual(@as(?Rect, null), fit(.{ .left = -8, .top = -8, .right = 1032, .bottom = 736 }, work, monitor, work));
    try std.testing.expectEqual(@as(?Rect, null), fit(r, monitor, monitor, monitor));
}
