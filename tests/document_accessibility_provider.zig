const std = @import("std");
extern fn zda_test_provider() c_int;
extern fn zda_test_mapping() c_int;
extern fn zda_test_presentation() c_int;
extern fn zda_test_auxiliary() c_int;
extern fn zda_test_word_units() c_int;
extern fn zda_test_hit_identity() c_int;
extern fn zda_test_hit_foreign() c_int;

test "complete hit binds account source and exact Text and withdraws without a serial increment" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_hit_identity());
}

test "point final return rejects same Text new bank and close during final COM free" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_hit_foreign());
}

test "opt-in native word units preserve full source boundaries reverse moves fallback and closed ranges" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_word_units());
}
test "native COM text providers keep full source identities, Unicode ranges, bounded actions, move geometry and late lifetime" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_provider());
}
test "native affine document geometry clips exact polygons and publishes atomically" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_mapping());
}
test "presentation epoch follows native geometry publication and rejects old queued actions" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_presentation());
}
test "one root publishes auxiliary patterns identities geometry and actions atomically" {
    try std.testing.expectEqual(@as(c_int, 0), zda_test_auxiliary());
}
