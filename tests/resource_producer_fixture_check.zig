const std = @import("std");
const ipc = @import("ziggurat_ipc");
const service = @import("producer_service");

test "checked-in resource producer client matches its current service schema" {
    const source = try ipc.generate(service.Service, std.testing.allocator);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(@embedFile("resource_producer_fixture.ts"), source);
}
