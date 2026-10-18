const std = @import("std");
extern fn zwpw_test_profile_session([*]const u8, usize) c_int;

test "Windows owned Profile session policy and native callback ownership" {
    const certificate = @embedFile("fixtures/profile-https/server-cert.pem");
    try std.testing.expectEqual(@as(c_int, 1), zwpw_test_profile_session(certificate.ptr, certificate.len));
}
