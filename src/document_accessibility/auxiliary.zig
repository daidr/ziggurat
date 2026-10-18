const std = @import("std");
const ui = @import("ziggurat_ui");

pub const Kind = enum(u32) { group = 0, invoke = 1, disclosure = 2 };
/// All fields participate in native identity; no hash or truncated ordinal.
pub const Key = extern struct {
    namespace: u64,
    comparison: u64,
    item: u64,
    kind: Kind,
    variant: u32 = 0,
};
pub const Node = struct {
    key: Key,
    frame_id: u64,
    parent: ?u64 = null,
    name: []const u8,
    expanded: bool = false,
    focusable: bool = false,

    pub fn role(self: Node) ui.accessibility.Role {
        return if (self.key.kind == .invoke) .button else .group;
    }
};
pub const SemanticPlan = struct { nodes: []const Node };
pub const Limits = struct {
    nodes: usize = 128,
    label_bytes: usize = 4096,

    pub fn validate(self: Limits) !void {
        if (self.nodes == 0 or self.nodes > ui.accessibility.max_nodes or self.label_bytes == 0 or self.label_bytes > ui.accessibility.text_capacity) return error.InvalidAuxiliaryLimits;
    }
};
pub fn validate(plan: SemanticPlan, limits: Limits) !usize {
    try limits.validate();
    if (plan.nodes.len == 0 or plan.nodes.len > limits.nodes) return error.InvalidAuxiliaryPlan;
    var bytes: usize = 0;
    for (plan.nodes, 0..) |node, at| {
        if (node.frame_id == 0 or node.key.namespace == 0 or node.key.comparison == 0) return error.InvalidAuxiliaryIdentity;
        if (!std.unicode.utf8ValidateSlice(node.name)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, node.name, 0) != null) return error.EmbeddedNul;
        if (node.name.len > limits.label_bytes - bytes) return error.AuxiliaryLabelCapacityExceeded;
        bytes += node.name.len;
        if (at == 0) {
            if (node.parent != null or node.key.kind != .group) return error.InvalidAuxiliaryRoot;
        } else {
            var found = false;
            for (plan.nodes[0..at]) |previous| if (previous.frame_id == node.parent) {
                found = true;
                break;
            };
            if (!found) return error.MissingAuxiliaryParent;
        }
        for (plan.nodes[0..at]) |previous| if (previous.frame_id == node.frame_id or std.meta.eql(previous.key, node.key)) return error.DuplicateAuxiliaryIdentity;
        if (node.key.kind != .disclosure and node.expanded) return error.InvalidAuxiliaryPattern;
        if (node.key.kind == .group and node.focusable) return error.InvalidAuxiliaryPattern;
    }
    return bytes;
}

test "auxiliary plan validates identity parent patterns and bounded labels" {
    const nodes = [_]Node{
        .{ .key = .{ .namespace = 1, .comparison = 2, .item = 0, .kind = .group }, .frame_id = 8, .name = "Controls" },
        .{ .key = .{ .namespace = 1, .comparison = 2, .item = 1, .kind = .invoke }, .frame_id = 9, .parent = 8, .name = "Revert" },
    };
    try std.testing.expectEqual(@as(usize, 14), try validate(.{ .nodes = &nodes }, .{}));
    try std.testing.expectError(error.AuxiliaryLabelCapacityExceeded, validate(.{ .nodes = &nodes }, .{ .label_bytes = 13 }));
    var invalid = nodes;
    invalid[1].parent = 42;
    try std.testing.expectError(error.MissingAuxiliaryParent, validate(.{ .nodes = &invalid }, .{}));
    invalid = nodes;
    invalid[1].key = nodes[0].key;
    try std.testing.expectError(error.DuplicateAuxiliaryIdentity, validate(.{ .nodes = &invalid }, .{}));
    invalid = nodes;
    invalid[1].expanded = true;
    try std.testing.expectError(error.InvalidAuxiliaryPattern, validate(.{ .nodes = &invalid }, .{}));
}
