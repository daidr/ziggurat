const std = @import("std");
const builtin = @import("builtin");
extern fn zws_test_core() c_int;
test "Windows private shared channel real worker roundtrip and terminal ownership" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, 0), zws_test_core());
}
