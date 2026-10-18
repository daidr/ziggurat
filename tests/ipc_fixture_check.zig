const std = @import("std");
const ipc = @import("ipc");
const fixture = @import("fixture");

test "checked-in browser fixture matches the current generator and service" {
    const source = try ipc.generate(fixture.Service, std.testing.allocator);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(@embedFile("ipc_fixture.ts"), source);
}
