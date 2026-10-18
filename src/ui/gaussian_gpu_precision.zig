const std = @import("std");
const scope = @import("gaussian_scope.zig");
/// The integer filter itself is exact. D2D's source/output clip and bitmap
/// translations must also stay within this explicitly tested pixel envelope.
pub fn supports(capture: scope.Capture) bool {
    const scale: f64 = capture.scale;
    const radius: f64 = @floatFromInt(capture.radius);
    const left: f64 = @floatFromInt(capture.left);
    const top: f64 = @floatFromInt(capture.top);
    const right = left + @as(f64, @floatFromInt(capture.width));
    const bottom = top + @as(f64, @floatFromInt(capture.height));
    for ([_]f64{ left, top, right, bottom, left - radius, top - radius, right + radius, bottom + radius, radius - left, radius - top }) |value| {
        if (@abs(value) > 16384) return false;
        const narrowed: f32 = @floatCast(value / scale);
        if (!std.math.isFinite(narrowed) or @abs(@as(f64, narrowed) * scale - value) > 1.0 / 4096.0) return false;
    }
    return true;
}
test "Gaussian GPU clip profile accepts prepared DPI and rejects translated precision loss" {
    const arithmetic = @import("gaussian_kernel.zig");
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        const kernel = try arithmetic.Kernel.prepare(.{ .sigma = 1, .scale = scale });
        try std.testing.expect(supports(try scope.Capture.init(.{ .x = -2.25, .y = 4.1, .width = 10, .height = 8 }, &kernel)));
        try std.testing.expect(!supports(try scope.Capture.init(.{ .x = 20000, .width = 2, .height = 2 }, &kernel)));
    }
}
