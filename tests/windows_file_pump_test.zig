const std = @import("std");
extern fn zws_test_file_pump() c_int;
test "Windows file pump owns window bytes HEAD cancellation and last refs" {
    try std.testing.expectEqual(@as(c_int, 0), zws_test_file_pump());
}
