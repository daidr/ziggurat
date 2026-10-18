const std = @import("std");
const material = @embedFile("fixtures/profile-https/server-cert.pem") ++ "\n" ++ @embedFile("fixtures/profile-https/server-key.pem");
const mismatched = @embedFile("fixtures/profile-https/server-cert.pem") ++ "\n" ++ @embedFile("fixtures/profile-https/other-key.pem");
extern fn zht_test_run([*]const u8, usize) c_int;
extern fn zht_test_mismatch([*]const u8, usize) c_int;
test "owned HTTPS transport native lifetime and construction gates" {
    try std.testing.expectEqual(@as(c_int, 0), zht_test_run(material, material.len));
}
test "different legal private key records actual native parser boundary" {
    const status = zht_test_mismatch(mismatched, mismatched.len);
    try std.testing.expect(status == 0 or status == 6);
    std.debug.print("owned transport mismatched legal pair: native_create_status={d}; no handshake was performed by this probe\n", .{status});
}
