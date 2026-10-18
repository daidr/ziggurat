const std = @import("std");
extern fn zwpw_test_lifetime() c_int;

test "Windows owned Profile lifetime admission and physical process retirement" {
    try std.testing.expectEqual(@as(c_int, 1), zwpw_test_lifetime());
}
