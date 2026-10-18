const std = @import("std");
const embedded = @import("web_assets");
pub fn main() !void {
    const Resource = struct { path: []const u8, mime: []const u8, bytes: []const u8 };
    const table = embedded.resourceTable(Resource);
    var total_bytes: usize = embedded.html.len;
    for (table, 0..) |resource, index| {
        try std.testing.expect(resource.path.len > 1 and resource.path[0] == '/');
        try std.testing.expect(!std.mem.eql(u8, resource.path, embedded.entry_path));
        if (index != 0) try std.testing.expect(std.mem.lessThan(u8, table[index - 1].path, resource.path));
        try std.testing.expect(resource.mime.len > 0);
        total_bytes += resource.bytes.len;
    }
    try std.testing.expectEqual(embedded.total_bytes, total_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(embedded.html));
    try std.testing.expect(std.mem.indexOfScalar(u8, embedded.html, 0) == null);
    try std.testing.expectEqual(64, embedded.digest.len);
    for (embedded.digest) |byte| try std.testing.expect(std.ascii.isHex(byte));
    std.debug.print("embedded resources passed: generated module and content-addressed compile-time bytes\n", .{});
}
