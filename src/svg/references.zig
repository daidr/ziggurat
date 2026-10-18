const std = @import("std");
const d = @import("document.zig");
const Entry = struct { id: []const u8, node: usize };
pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    pub fn init(allocator: std.mem.Allocator, nodes: []const d.Node, budget: usize) !Index {
        var count: usize = 0;
        for (nodes) |node| if (node.kind == .element and node.attribute("id") != null) {
            count += 1;
        };
        if (count > budget / @sizeOf(Entry)) return error.CapacityExceeded;
        const entries = try allocator.alloc(Entry, count);
        errdefer allocator.free(entries);
        count = 0;
        for (nodes, 0..) |node, at| if (node.kind == .element) {
            if (node.attribute("id")) |id| {
                try validateId(id);
                entries[count] = .{ .id = id, .node = at };
                count += 1;
            }
        };
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.less);
        for (entries, 0..) |entry, i| if (i != 0 and std.mem.eql(u8, entries[i - 1].id, entry.id)) return error.DuplicateId;
        return .{ .allocator = allocator, .entries = entries };
    }
    pub fn bytes(self: Index) usize {
        return self.entries.len * @sizeOf(Entry);
    }
    pub fn deinit(self: *Index) void {
        self.allocator.free(self.entries);
    }
    pub fn find(self: Index, id: []const u8) ?usize {
        var left: usize = 0;
        var right = self.entries.len;
        while (left < right) {
            const middle = left + (right - left) / 2;
            switch (std.mem.order(u8, id, self.entries[middle].id)) {
                .eq => return self.entries[middle].node,
                .lt => right = middle,
                .gt => left = middle + 1,
            }
        }
        return null;
    }
};
fn validateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024) return error.InvalidId;
    for (value) |byte| if (std.ascii.isWhitespace(byte) or byte == 0) return error.InvalidId;
}
pub fn fragment(input: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0 or value[0] != '#') return error.ExternalResourceDenied;
    const id = value[1..];
    try validateId(id);
    // URI escaping requires a separate decoding contract, never a heuristic.
    if (std.mem.indexOfScalar(u8, id, '%') != null) return error.UnsupportedReferenceEscape;
    return id;
}
pub fn href(nodes: []const d.Node, at: usize) ![]const u8 {
    const node = nodes[at];
    if (node.attribute("xlink:href")) |value| {
        var ancestor: ?usize = at;
        var valid = false;
        while (ancestor) |index| {
            if (nodes[index].attribute("xmlns:xlink")) |uri| {
                valid = std.mem.eql(u8, uri, "http://www.w3.org/1999/xlink");
                break;
            }
            ancestor = nodes[index].parent;
        }
        if (!valid) return error.UnsupportedNamespace;
        _ = try fragment(value);
    }
    return try fragment(node.attribute("href") orelse node.attribute("xlink:href") orelse return error.MissingReference);
}
