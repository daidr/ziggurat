const std = @import("std");
extern fn zhtp_test_provider() c_int;
test "Windows optional TLS provider: bounded worker ownership and actual records" {
    try std.testing.expectEqual(@as(c_int, 0), zhtp_test_provider());
}
