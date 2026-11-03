//! The hatching of a split comparison's fillers, the rows one side has and
//! the other lacks: diagonal stripes every `period` DIP, drawn as one
//! repeating gradient per filler whatever its height, so that a filler
//! millions of DIP high costs what a short one does. The stripes keep to
//! the content, not to the filler, so those of consecutive rows make one
//! pattern that moves with the content as it scrolls.
const std = @import("std");
const ui = @import("ziggurat_ui");

/// Horizontal distance between stripes, in DIP.
pub const period: f32 = 8;
/// The part of each period a stripe takes.
pub const stripe: f32 = 0.2;

/// Where a stripe starts at the filler's top, as a phase in [0, period):
/// the content's offset `scroll` (in DIP from its top, kept in f64 so that
/// the stripes hold still millions of DIP down) folded into one period.
pub fn phase(scroll: f64) f32 {
    const folded = @mod(scroll, @as(f64, period));
    return @floatCast(if (folded < 0) folded + period else folded);
}

/// The gradient of the hatching anchored at (`x`, `top`), the screen point
/// of the content's left edge and of its top folded into one period
/// (`origin - phase(scroll)`), with `base` under stripes of `color`.
/// Stripes rise from left to right.
pub fn gradient(stops: *[4]ui.commands.brushes.Stop, x: f32, top: f32, base: u32, color: u32) ui.commands.Gradient {
    stops.* = .{
        .{ .offset = 0, .color = ui.Color.rgb(base) },
        .{ .offset = 1 - stripe, .color = ui.Color.rgb(base) },
        .{ .offset = 1 - stripe, .color = ui.Color.rgb(color) },
        .{ .offset = 1, .color = ui.Color.rgb(color) },
    };
    // Along (1, 1), x + y grows by `period` from one stripe to the next.
    return .{ .linear = .{ .start = .{ .x = x, .y = top }, .end = .{ .x = x + period / 2, .y = top + period / 2 }, .stops = stops, .spread = .repeat } };
}

/// Fill `rectangle` with the hatching, anchored at `x` and `top`, the
/// screen point of the content's top-left corner folded into one period.
pub fn fill(frame: *ui.Frame, rectangle: ui.Rect, x: f32, top: f32, base: u32, color: u32) void {
    if (rectangle.width <= 0 or rectangle.height <= 0) return;
    var stops: [4]ui.commands.brushes.Stop = undefined;
    frame.gradientRect(rectangle, 0, gradient(&stops, x, top, base, color));
}

test "the stripes keep to the content as it scrolls" {
    try std.testing.expectEqual(@as(f32, 0), phase(0));
    try std.testing.expectEqual(@as(f32, 3), phase(11));
    try std.testing.expectEqual(@as(f32, 5), phase(-3));
    // Far down, the phase is still exact.
    try std.testing.expectEqual(@as(f32, 2), phase(8_000_000_002));
    var stops: [4]ui.commands.brushes.Stop = undefined;
    const value = gradient(&stops, 10, 20, 0xeeeeee, 0xdddddd);
    try std.testing.expectEqual(ui.commands.brushes.Spread.repeat, value.linear.spread);
    try std.testing.expectEqual(@as(f32, 14), value.linear.end.x);
}
