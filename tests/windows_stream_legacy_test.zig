const std = @import("std");
extern fn zws_test_legacy() c_int;
test "Windows shared physical domain preserves direct file IStream" {
    try std.testing.expectEqual(@as(c_int, 0), zws_test_legacy());
}
