const std = @import("std");
const d = @import("document.zig");
pub fn localName(nodes: []const d.Node, index: usize) ![]const u8 {
    const name = nodes[index].name;
    const colon = std.mem.indexOfScalar(u8, name, ':');
    var key_buffer: [134]u8 = undefined;
    const key = if (colon) |at| blk: {
        if (at == 0 or at + 1 == name.len or std.mem.indexOfScalar(u8, name[at + 1 ..], ':') != null) return error.UnsupportedNamespace;
        break :blk try std.fmt.bufPrint(&key_buffer, "xmlns:{s}", .{name[0..at]});
    } else "xmlns";
    var ancestor: ?usize = index;
    while (ancestor) |at| {
        if (nodes[at].attribute(key)) |uri| {
            if (!std.mem.eql(u8, uri, "http://www.w3.org/2000/svg")) return error.UnsupportedNamespace;
            return if (colon) |separator| name[separator + 1 ..] else name;
        }
        ancestor = nodes[at].parent;
    }
    if (colon != null) return error.UnsupportedNamespace;
    return name;
}
