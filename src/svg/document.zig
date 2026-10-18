const std = @import("std");
const xml = @import("xml.zig");
pub const Attribute = xml.Attribute;
pub const Limits = struct { input_bytes: usize = 1024 * 1024, nodes: usize = 4096, depth: usize = 32, attributes: usize = 32, attribute_bytes: usize = 65536, bytes: usize = 8 * 1024 * 1024 };
pub const Node = struct {
    kind: enum { element, text },
    name: []const u8 = "",
    text: []const u8 = "",
    attributes: []const Attribute = &.{},
    parent: ?usize = null,
    first_child: ?usize = null,
    next_sibling: ?usize = null,
    pub fn attribute(self: Node, name: []const u8) ?[]const u8 {
        for (self.attributes) |value| if (std.mem.eql(u8, value.name, name)) return value.value;
        return null;
    }
};
pub const Stats = struct { nodes: usize, attributes: usize, owned_bytes: usize };
pub const State = struct { allocator: std.mem.Allocator, owner: std.Thread.Id, input: []u8, nodes: []Node, attributes: []Attribute, values: []u8, stats: Stats, busy: bool = false, closing: bool = false };
pub fn state(document: *const Document) *State {
    return @ptrCast(@alignCast(@constCast(document)));
}

/// Owns source, decoded attributes/text and a bounded element tree. Prepared
/// rendering resources will be independent snapshots. Never move or mutate
/// borrowed node/attribute storage; every operation uses the creating thread.
pub const Document = opaque {
    pub fn parse(allocator: std.mem.Allocator, input: []const u8, limits: Limits) !*Document {
        if (limits.input_bytes == 0 or limits.input_bytes > 16 * 1024 * 1024 or limits.nodes == 0 or limits.nodes > 65536 or limits.bytes == 0 or limits.bytes > 64 * 1024 * 1024) return error.InvalidLimits;
        if (input.len > limits.input_bytes) return error.InputTooLarge;
        const reader_limits: xml.Limits = .{ .depth = limits.depth, .attributes = limits.attributes, .attribute_bytes = limits.attribute_bytes, .nodes = limits.nodes };
        var reader = try xml.Reader.init(input, reader_limits);
        var nodes: usize = 0;
        var attributes: usize = 0;
        var values: usize = 0;
        while (try reader.next()) |token| switch (token) {
            .start => |element| {
                if (nodes == limits.nodes) return error.NodesFull;
                nodes += 1;
                attributes += element.attributes.len;
                for (element.attributes) |attribute| values += try xml.decode(null, attribute.value, true);
            },
            .text => |text| {
                if (nodes == limits.nodes) return error.NodesFull;
                nodes += 1;
                values += try decodeText(null, text);
            },
            .end => {},
        };
        var bytes: usize = @sizeOf(State);
        try account(&bytes, input.len, 1, limits.bytes);
        try account(&bytes, nodes, @sizeOf(Node), limits.bytes);
        try account(&bytes, attributes, @sizeOf(Attribute), limits.bytes);
        try account(&bytes, values, 1, limits.bytes);
        const value = try allocator.create(State);
        errdefer allocator.destroy(value);
        const source = try allocator.dupe(u8, input);
        errdefer allocator.free(source);
        const node_storage = try allocator.alloc(Node, nodes);
        errdefer allocator.free(node_storage);
        const attr_storage = try allocator.alloc(Attribute, attributes);
        errdefer allocator.free(attr_storage);
        const text_storage = try allocator.alloc(u8, values);
        errdefer allocator.free(text_storage);
        reader = try xml.Reader.init(source, reader_limits);
        var node_at: usize = 0;
        var attr_at: usize = 0;
        var text_at: usize = 0;
        var stack: [64]usize = undefined;
        var last_child: [65]?usize = @splat(null);
        var depth: usize = 0;
        while (try reader.next()) |token| {
            if (token == .end) {
                depth -= 1;
                continue;
            }
            const current = &node_storage[node_at];
            current.* = .{ .kind = if (token == .start) .element else .text, .parent = if (depth == 0) null else stack[depth - 1] };
            if (last_child[depth]) |previous| node_storage[previous].next_sibling = node_at else if (depth > 0) node_storage[stack[depth - 1]].first_child = node_at;
            last_child[depth] = node_at;
            switch (token) {
                .start => |element| {
                    current.name = element.name;
                    current.attributes = attr_storage[attr_at..][0..element.attributes.len];
                    for (element.attributes) |attribute| {
                        const length = try xml.decode(text_storage[text_at..], attribute.value, true);
                        attr_storage[attr_at] = .{ .name = attribute.name, .value = text_storage[text_at..][0..length] };
                        attr_at += 1;
                        text_at += length;
                    }
                    if (!element.empty) {
                        stack[depth] = node_at;
                        depth += 1;
                        last_child[depth] = null;
                    }
                },
                .text => |text| {
                    const length = try decodeText(text_storage[text_at..], text);
                    current.text = text_storage[text_at..][0..length];
                    text_at += length;
                },
                .end => unreachable,
            }
            node_at += 1;
        }
        try rootNamespace(node_storage[0]);
        value.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .input = source, .nodes = node_storage, .attributes = attr_storage, .values = text_storage, .stats = .{ .nodes = nodes, .attributes = attributes, .owned_bytes = bytes } };
        return @ptrCast(value);
    }
    pub fn checkOwner(self: *const Document) !void {
        if (state(self).owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (state(self).closing) return error.Closed;
    }
    pub fn prepare(self: *const Document, allocator: std.mem.Allocator, options: @import("prepare.zig").Options) !*@import("prepare.zig").Prepared {
        try self.checkOwner();
        const value = state(self);
        if (value.busy) return error.Busy;
        value.busy = true;
        defer value.busy = false;
        // Capture provider configuration before any foreign allocator can mutate
        // caller-owned descriptors. The copied provider lives for the whole call.
        var image_provider: ?@import("image.zig").Provider = if (options.image_provider) |provider| provider.* else null;
        var captured = options;
        captured.image_provider = if (image_provider) |*provider| provider else null;
        if (image_provider) |provider| try provider.limits.validate();
        const image_lease = if (image_provider) |provider| provider.lease else null;
        if (image_lease) |pin| try pin.acquire();
        defer if (image_lease) |pin| pin.release();
        const lease = if (options.text_provider) |provider| provider.lease else null;
        if (lease) |pin| try pin.acquire();
        defer if (lease) |pin| pin.release();
        const prepared = try @import("prepare.zig").prepare(self, allocator, captured);
        errdefer prepared.close() catch unreachable;
        // All backend/stylesheet/text-cache scratch destructors have returned.
        // Keep the source/provider pins through this final cancellation gate;
        // after it only pure pin release and ownership return remain.
        if (options.cancellation) |cancel| try cancel.check();
        return prepared;
    }
    pub fn node(self: *const Document, index: usize) !Node {
        try self.checkOwner();
        const value = state(self);
        if (index >= value.nodes.len) return error.InvalidNode;
        return value.nodes[index];
    }
    pub fn stats(self: *const Document) !Stats {
        try self.checkOwner();
        return state(self).stats;
    }
    pub fn close(self: *Document) !void {
        try self.checkOwner();
        const value = state(self);
        if (value.busy) return error.Busy;
        value.closing = true;
        const allocator = value.allocator;
        allocator.free(value.values);
        allocator.free(value.attributes);
        allocator.free(value.nodes);
        allocator.free(value.input);
        allocator.destroy(value);
    }
};
fn account(total: *usize, count: usize, unit: usize, limit: usize) !void {
    if (count > (limit -| total.*) / unit) return error.CapacityExceeded;
    total.* += count * unit;
    if (total.* > limit) return error.CapacityExceeded;
}
fn rootNamespace(root: Node) !void {
    const colon = std.mem.indexOfScalar(u8, root.name, ':');
    if (colon) |at| {
        if (at == 0 or !std.mem.eql(u8, root.name[at + 1 ..], "svg")) return error.SvgRootRequired;
        var buffer: [134]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "xmlns:{s}", .{root.name[0..at]});
        if (!std.mem.eql(u8, root.attribute(key) orelse return error.UnsupportedNamespace, "http://www.w3.org/2000/svg")) return error.UnsupportedNamespace;
    } else {
        if (!std.mem.eql(u8, root.name, "svg")) return error.SvgRootRequired;
        if (root.attribute("xmlns")) |uri| if (!std.mem.eql(u8, uri, "http://www.w3.org/2000/svg")) return error.UnsupportedNamespace;
    }
}
fn decodeText(output: ?[]u8, text: xml.Text) !usize {
    if (!text.cdata) return xml.decode(output, text.bytes, false);
    var at: usize = 0;
    var written: usize = 0;
    while (at < text.bytes.len) {
        var byte = text.bytes[at];
        at += 1;
        if (byte == '\r') {
            if (at < text.bytes.len and text.bytes[at] == '\n') at += 1;
            byte = '\n';
        }
        if (output) |target| {
            if (written == target.len) return error.BufferTooSmall;
            target[written] = byte;
        }
        written += 1;
    }
    return written;
}
