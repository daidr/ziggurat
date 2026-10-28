const std = @import("std");
const ui = @import("ziggurat_ui");
const diff = @import("ziggurat_document_diff_view");
const auxiliary = @import("ziggurat_document_accessibility").auxiliary;

pub const max_nodes = 65;
pub const label_bytes = 4096;
pub const Button = struct { bounds: ui.Rect, name: []const u8, enabled: bool = true };
pub const Hunk = struct { index: usize, original_to_modified: ?Button = null, modified_to_original: ?Button = null };
/// The host supplies toolbar geometry. Context buttons use the two actual
/// prepared header rectangles, never the gap or a union of both columns.
pub const Plan = struct { bounds: ui.Rect, name: []const u8 = "Comparison controls", hunks: []const Hunk = &.{}, context_headers: bool = true, enabled: bool = true };
pub const Limits = struct { hunks: usize = 16, context_regions: usize = 16 };
pub const Intent = union(enum) { revert: struct { hunk: usize, direction: diff.Direction }, context: struct { key: diff.editable.ContextKey, collapsed: bool } };
pub const Outcome = struct { changed: bool, index_required: bool = false, presentation_error: ?anyerror = null };

const Bank = struct {
    nodes: [max_nodes]auxiliary.Node = undefined,
    bounds: [max_nodes]ui.Rect = undefined,
    enabled: [max_nodes]bool = undefined,
    labels: [label_bytes]u8 = undefined,
    len: usize = 0,
    used: usize = 0,
};
/// Explicit caller-owned workspace. Its stable address and unique Frame ID
/// range cover Bridge.create through Bridge.close. Do not copy a bound value.
/// Both banks, labels and identity leases are included in the Bridge budget.
pub const Controls = struct {
    namespace: u64,
    next_id: u64,
    limits: Limits,
    bound: bool = false,
    valid: bool = false,
    active: u1 = 0,
    banks: [2]Bank = .{ .{}, .{} },

    pub fn init(namespace: u64, first_id: u64, limits: Limits) !Controls {
        if (namespace == 0 or first_id == 0 or first_id == std.math.maxInt(u64)) return error.InvalidControlIdentity;
        if (limits.hunks > 16 or limits.context_regions > 16) return error.InvalidControlLimits;
        return .{ .namespace = namespace, .next_id = first_id, .limits = limits };
    }
    pub fn intent(self: *const Controls, key: auxiliary.Key, expanded: bool) !Intent {
        if (key.namespace != self.namespace or key.comparison == 0) return error.ForeignControl;
        return switch (key.kind) {
            .invoke => if (key.variant <= 1) .{ .revert = .{ .hunk = std.math.cast(usize, key.item) orelse return error.InvalidHunk, .direction = if (key.variant == 0) .a_to_b else .b_to_a } } else error.InvalidControlIdentity,
            .disclosure => if (key.variant <= 1) .{ .context = .{ .key = .{ .serial = key.comparison, .id = key.item }, .collapsed = !expanded } } else error.InvalidControlIdentity,
            .group => error.NotSupported,
        };
    }
    fn id(self: *Controls, key: auxiliary.Key) !u64 {
        if (self.valid) for (self.banks[self.active].nodes[0..self.banks[self.active].len]) |node| {
            if (std.meta.eql(node.key, key)) return node.frame_id;
        };
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }
    fn append(self: *Controls, bank: *Bank, key: auxiliary.Key, parent: ?u64, rectangle: ui.Rect, name: []const u8, enabled: bool, expanded: bool) !void {
        if (bank.len == max_nodes) return error.ControlCapacityExceeded;
        if (!ui.layout.validRect(rectangle) or rectangle.width <= 0 or rectangle.height <= 0) return error.InvalidGeometry;
        if (!std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidControlLabel;
        if (name.len > label_bytes - bank.used) return error.ControlLabelCapacityExceeded;
        const frame_id = try self.id(key);
        const label = bank.labels[bank.used..][0..name.len];
        @memcpy(label, name);
        bank.used += name.len;
        bank.nodes[bank.len] = .{ .key = key, .frame_id = frame_id, .parent = parent, .name = label, .expanded = expanded, .focusable = key.kind != .group };
        bank.bounds[bank.len] = rectangle;
        bank.enabled[bank.len] = enabled;
        bank.len += 1;
    }
    pub fn candidate(self: *Controls, view: *diff.EditableSplit, presentation: diff.Presentation, plan: Plan) !auxiliary.SemanticPlan {
        if (presentation.comparison_serial == 0 or !presentation.projected or presentation.composing) return error.ComparisonRequired;
        if (plan.hunks.len > self.limits.hunks) return error.ControlCapacityExceeded;
        const bank = &self.banks[1 - self.active];
        bank.len = 0;
        bank.used = 0;
        try self.append(bank, .{ .namespace = self.namespace, .comparison = presentation.comparison_serial, .item = 0, .kind = .group }, null, plan.bounds, plan.name, plan.enabled, false);
        const parent = bank.nodes[0].frame_id;
        for (plan.hunks, 0..) |hunk, at| {
            for (plan.hunks[0..at]) |previous| if (previous.index == hunk.index) return error.DuplicateHunk;
            var visible = false;
            for (presentation.rows) |row| if (row.hunk == hunk.index) {
                visible = true;
                break;
            };
            if (!visible) return error.HunkNotPresented;
            const buttons = [2]?Button{ hunk.original_to_modified, hunk.modified_to_original };
            for (buttons, 0..) |button, direction| if (button) |value| {
                if (presentation.mode == .unified and direction == 1) return error.ReadOnlySource;
                try self.append(bank, .{ .namespace = self.namespace, .comparison = presentation.comparison_serial, .item = hunk.index, .kind = .invoke, .variant = @intCast(direction) }, parent, value.bounds, value.name, plan.enabled and value.enabled, false);
            };
        }
        if (plan.context_headers) {
            var storage: [96]diff.editable.ContextRegion = undefined;
            const regions = try view.contextRegions(&storage);
            if (regions.len > self.limits.context_regions) return error.ControlCapacityExceeded;
            for (regions) |region| for (region.headers, 0..) |header, side| if (header) |rectangle| {
                try self.append(bank, .{ .namespace = self.namespace, .comparison = region.key.serial, .item = region.key.id, .kind = .disclosure, .variant = @intCast(side) }, parent, rectangle, if (region.collapsed) "Expand unchanged context" else "Collapse unchanged context", plan.enabled, !region.collapsed);
            };
        }
        _ = try auxiliary.validate(.{ .nodes = bank.nodes[0..bank.len] }, .{ .nodes = max_nodes, .label_bytes = label_bytes });
        return .{ .nodes = bank.nodes[0..bank.len] };
    }
    pub fn publish(self: *Controls) void {
        self.active = 1 - self.active;
        self.valid = true;
    }
    pub fn draw(self: *Controls, frame: *ui.Frame) !void {
        return self.drawBody(frame) catch |err| {
            frame.failure = frame.failure orelse err;
            return err;
        };
    }
    fn drawBody(self: *Controls, frame: *ui.Frame) !void {
        if (!self.valid) return error.ControlsRequired;
        const bank = &self.banks[self.active];
        for (bank.nodes[0..bank.len], bank.bounds[0..bank.len], bank.enabled[0..bank.len]) |node, bounds, enabled| {
            if (node.key.kind == .invoke) {
                try frame.buttonWithOptions(node.frame_id, bounds, node.name, .{ .enabled = enabled, .semantic_parent = node.parent.? });
            } else {
                if (node.key.kind == .disclosure) {
                    try frame.addControl(node.frame_id, bounds, .{ .enabled = enabled });
                    frame.rect(bounds, if (enabled) 0xe0e0e0 else 0xeeeeee);
                    const line: ui.Rect = .{ .x = bounds.x + bounds.width * 0.2, .y = bounds.y + bounds.height * 0.45, .width = bounds.width * 0.6, .height = @max(1, bounds.height * 0.1) };
                    frame.rect(line, 0x333333);
                    if (!node.expanded) frame.rect(.{ .x = bounds.x + bounds.width * 0.45, .y = bounds.y + bounds.height * 0.2, .width = @max(1, bounds.width * 0.1), .height = bounds.height * 0.6 }, 0x333333);
                }
                try frame.semantic(.{ .id = node.frame_id, .parent = node.parent orelse ui.accessibility.root_id, .role = node.role(), .name = node.name, .bounds = bounds, .enabled = enabled, .focused = frame.context.input_state.focused == node.frame_id });
            }
        }
    }
};

test "typed controls keep full comparison identity and reject ambiguous variants" {
    var controls = try Controls.init(8, 100, .{});
    const key: auxiliary.Key = .{ .namespace = 8, .comparison = 4, .item = 900, .kind = .invoke, .variant = 1 };
    const action = try controls.intent(key, false);
    try std.testing.expectEqual(diff.Direction.b_to_a, action.revert.direction);
    try std.testing.expectEqual(@as(usize, 900), action.revert.hunk);
    var invalid = key;
    invalid.namespace = 7;
    try std.testing.expectError(error.ForeignControl, controls.intent(invalid, false));
    invalid = key;
    invalid.variant = 2;
    try std.testing.expectError(error.InvalidControlIdentity, controls.intent(invalid, false));
    controls.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, controls.id(key));
}
