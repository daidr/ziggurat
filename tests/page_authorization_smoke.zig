const std = @import("std");
extern fn zpa_run() c_int;
pub fn main() !void {
    try std.testing.expectEqual(@as(c_int, 0), zpa_run());
    std.debug.print("page authorization smoke passed: native callback ABI, host command kinds, bounded URI/HTML, exact remote origins, navigation/redirect grants and message gates; COM=0\n", .{});
}
