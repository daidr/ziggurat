const std = @import("std");
test "explicit TLS consumer native failure matrix and shared physical capacity" {
    const allocator = std.testing.allocator;
    const directory = std.process.getEnvVarOwned(allocator, "ZIGGURAT_HTTPS_TEST_ROOT") catch |failure| switch (failure) {
        error.EnvironmentVariableNotFound => return error.MissingHttpsTestRoot,
        else => return failure,
    };
    defer allocator.free(directory);
    const cert = try std.fs.path.joinZ(allocator, &.{ directory, "server-cert.pem" });
    defer allocator.free(cert);
    const key = try std.fs.path.joinZ(allocator, &.{ directory, "server-key.pem" });
    defer allocator.free(key);
    try std.testing.expectEqual(@as(c_int, 0), zhr_test_native(cert.ptr, key.ptr));
}
extern fn zhr_test_native([*:0]const u8, [*:0]const u8) c_int;
