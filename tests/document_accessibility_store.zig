const std = @import("std");
extern fn zda_test_store() c_int;
extern fn zda_test_store_race() c_int;
test "complete native snapshots keep graphemes, atomic geometry, text stamps and late native-only getter refs" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_store());
}
test "native getters retain immutable blobs while the owner publishes and closes" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_store_race());
}
