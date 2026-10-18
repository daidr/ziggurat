const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const affine_state = @import("affine_state.zig");
const recipients = @import("text_field_workspace.zig");
const affine = affine_state.affine;
pub const virtual_lists = @import("collection_native.zig");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};

pub const max_nodes = 128;
pub const text_capacity = 32768;
pub const root_id: u64 = 0;
pub const Role = enum(u32) { window, group, button, text, text_box, checkbox, radio, toggle_switch, progress, radio_group, slider, stepper, list };
pub const Node = struct {
    id: u64,
    parent: ?u64 = root_id,
    role: Role,
    name: []const u8,
    value: []const u8 = "",
    bounds: z.Rect,
    enabled: bool = true,
    focused: bool = false,
    read_only: bool = false,
    checked: bool = false,
    range_value: f64 = 0,
    range_minimum: f64 = 0,
    range_maximum: f64 = 100,
    range_small_change: f64 = 0,
    range_large_change: f64 = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
};
const Entry = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    name_start: usize,
    name_len: usize,
    value_start: usize,
    value_len: usize,
    bounds: z.Rect,
    enabled: bool,
    focused: bool,
    read_only: bool,
    checked: bool,
    range_value: f64,
    range_minimum: f64,
    range_maximum: f64,
    range_small_change: f64,
    range_large_change: f64,
    selection_start: usize,
    selection_end: usize,
};

/// Explicit semantic records. Names, values and geometry come from the caller;
/// text is copied into fixed storage and never inferred from a paint command.
/// Stable IDs must retain their semantic identity and role while a Bridge lives.
pub const Tree = struct {
    entries: [max_nodes]Entry = undefined,
    len: usize = 0,
    storage: [text_capacity]u8 = undefined,
    used: usize = 0,
    mapped: ?*affine_state.Snapshot = null,

    /// Read-only complete graph/text validation, without temporary node copies.
    pub fn validate(self: *const Tree) !void {
        if (self.len == 0 or self.len > max_nodes or self.used > self.storage.len) return error.InvalidSemanticRoot;
        for (self.entries[0..self.len], 0..) |entry, at| {
            if (entry.name_start > self.used or entry.name_len > self.used - entry.name_start or entry.value_start > self.used or entry.value_len > self.used - entry.value_start) return error.InvalidSemanticText;
            const name = self.storage[entry.name_start..][0..entry.name_len];
            const value = self.storage[entry.value_start..][0..entry.value_len];
            if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
            if (!std.math.isFinite(entry.bounds.x) or !std.math.isFinite(entry.bounds.y) or !std.math.isFinite(entry.bounds.width) or !std.math.isFinite(entry.bounds.height) or entry.bounds.width < 0 or entry.bounds.height < 0) return error.InvalidGeometry;
            if (entry.selection_start > value.len or entry.selection_end > value.len or !boundary(value, entry.selection_start) or !boundary(value, entry.selection_end)) return error.InvalidSelection;
            if (!std.math.isFinite(entry.range_value) or !std.math.isFinite(entry.range_minimum) or !std.math.isFinite(entry.range_maximum) or entry.range_minimum > entry.range_maximum or entry.range_value < entry.range_minimum or entry.range_value > entry.range_maximum or !std.math.isFinite(entry.range_small_change) or entry.range_small_change < 0 or !std.math.isFinite(entry.range_large_change) or entry.range_large_change < 0) return error.InvalidRangeValue;
            if (at == 0) {
                if (entry.id != root_id or entry.parent != null or entry.role != .window) return error.InvalidSemanticRoot;
            } else {
                var parent: ?usize = null;
                for (self.entries[0..at], 0..) |previous, before| {
                    if (previous.id == entry.id) return error.DuplicateSemanticId;
                    if (previous.id == entry.parent) parent = before;
                }
                _ = parent orelse return error.MissingSemanticParent;
            }
        }
    }
    /// Copy an explicit subtree into caller-owned storage. Validation covers
    /// the complete tree before either output is written. Returned labels
    /// borrow only `text`, never this Tree or its recording Frame.
    pub fn exportSubtree(self: *const Tree, id: u64, nodes: []Node, text: []u8) ![]Node {
        try self.validate();
        var selected: [max_nodes]bool = @splat(false);
        var found = false;
        var count: usize = 0;
        var bytes: usize = 0;
        for (self.entries[0..self.len], 0..) |entry, at| {
            if (at != 0) for (self.entries[0..at], 0..) |previous, before| {
                if (previous.id == entry.parent) {
                    selected[at] = selected[before];
                    break;
                }
            };
            if (entry.id == id) {
                found = true;
                selected[at] = true;
            }
            if (selected[at]) {
                count += 1;
                bytes += entry.name_len + entry.value_len;
            }
        }
        if (!found) return error.MissingSemanticNode;
        if (count > nodes.len or bytes > text.len) return error.SemanticExportCapacityExceeded;
        var used: usize = 0;
        var written: usize = 0;
        for (self.entries[0..self.len], 0..) |entry, at| if (selected[at]) {
            const name = text[used..][0..entry.name_len];
            @memcpy(name, self.storage[entry.name_start..][0..entry.name_len]);
            used += name.len;
            const value = text[used..][0..entry.value_len];
            @memcpy(value, self.storage[entry.value_start..][0..entry.value_len]);
            used += value.len;
            nodes[written] = .{ .id = entry.id, .parent = entry.parent, .role = entry.role, .name = name, .value = value, .bounds = entry.bounds, .enabled = entry.enabled, .focused = entry.focused, .read_only = entry.read_only, .checked = entry.checked, .range_value = entry.range_value, .range_minimum = entry.range_minimum, .range_maximum = entry.range_maximum, .range_small_change = entry.range_small_change, .range_large_change = entry.range_large_change, .selection_start = entry.selection_start, .selection_end = entry.selection_end };
            written += 1;
        };
        return nodes[0..written];
    }

    pub fn reset(self: *Tree, name: []const u8, bounds: z.Rect) !void {
        self.len = 0;
        self.used = 0;
        self.mapped = null;
        try self.add(.{ .id = root_id, .parent = null, .role = .window, .name = name, .bounds = bounds });
    }
    pub fn add(self: *Tree, node: Node) !void {
        if (self.len == max_nodes) return error.TooManySemanticNodes;
        if (!std.unicode.utf8ValidateSlice(node.name) or !std.unicode.utf8ValidateSlice(node.value)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, node.name, 0) != null or std.mem.indexOfScalar(u8, node.value, 0) != null) return error.EmbeddedNul;
        if (!std.math.isFinite(node.bounds.x) or !std.math.isFinite(node.bounds.y) or !std.math.isFinite(node.bounds.width) or !std.math.isFinite(node.bounds.height) or node.bounds.width < 0 or node.bounds.height < 0) return error.InvalidGeometry;
        if (!std.math.isFinite(node.range_value) or !std.math.isFinite(node.range_minimum) or !std.math.isFinite(node.range_maximum) or node.range_minimum > node.range_maximum or node.range_value < node.range_minimum or node.range_value > node.range_maximum or !std.math.isFinite(node.range_small_change) or node.range_small_change < 0 or !std.math.isFinite(node.range_large_change) or node.range_large_change < 0) return error.InvalidRangeValue;
        if (node.selection_start > node.value.len or node.selection_end > node.value.len or !boundary(node.value, node.selection_start) or !boundary(node.value, node.selection_end)) return error.InvalidSelection;
        if (node.id == root_id) {
            if (self.len != 0 or node.parent != null or node.role != .window) return error.InvalidSemanticRoot;
        } else {
            const parent = node.parent orelse return error.MissingSemanticParent;
            var found = false;
            for (self.entries[0..self.len]) |entry| if (entry.id == parent) {
                found = true;
                break;
            };
            if (!found) return error.MissingSemanticParent;
        }
        for (self.entries[0..self.len]) |entry| if (entry.id == node.id) return error.DuplicateSemanticId;
        if (node.name.len > self.storage.len - self.used or node.value.len > self.storage.len - self.used - node.name.len) return error.SemanticTextCapacityExceeded;
        const start = self.used;
        @memcpy(self.storage[start..][0..node.name.len], node.name);
        @memcpy(self.storage[start + node.name.len ..][0..node.value.len], node.value);
        self.entries[self.len] = .{
            .id = node.id,
            .parent = node.parent,
            .role = node.role,
            .name_start = start,
            .name_len = node.name.len,
            .value_start = start + node.name.len,
            .value_len = node.value.len,
            .bounds = node.bounds,
            .enabled = node.enabled,
            .focused = node.focused,
            .read_only = node.read_only,
            .checked = node.checked,
            .range_value = node.range_value,
            .range_minimum = node.range_minimum,
            .range_maximum = node.range_maximum,
            .range_small_change = node.range_small_change,
            .range_large_change = node.range_large_change,
            .selection_start = node.selection_start,
            .selection_end = node.selection_end,
        };
        self.used += node.name.len + node.value.len;
        self.len += 1;
    }
    pub fn addMapped(self: *Tree, node: Node, reference: affine.Ref, local_bounds: affine.Rect) !void {
        const mapped = self.mapped orelse return error.SemanticGeometryRequired;
        if (mapped.semantic_len != self.len) return error.InvalidSemanticGeometry;
        const before = self.len;
        const used = self.used;
        try self.add(node);
        errdefer {
            self.len = before;
            self.used = used;
        }
        try mapped.addSemantic(reference, local_bounds);
    }
};
fn boundary(text: []const u8, index: usize) bool {
    return index <= text.len and (index == text.len or text[index] & 0xc0 != 0x80);
}

test "subtree export copies labels and rejects complete graph before output" {
    var tree: Tree = .{};
    const bounds: z.Rect = .{ .x = 1, .y = 2, .width = 30, .height = 20 };
    try tree.reset("Window", bounds);
    try tree.add(.{ .id = 8, .role = .group, .name = "Tools", .bounds = bounds });
    try tree.add(.{ .id = 9, .parent = 8, .role = .button, .name = "Apply", .bounds = bounds });
    try tree.add(.{ .id = 10, .role = .text, .name = "Peer", .bounds = bounds });
    var nodes: [2]Node = undefined;
    var labels: [10]u8 = undefined;
    const copied = try tree.exportSubtree(8, &nodes, &labels);
    try std.testing.expectEqual(@as(usize, 2), copied.len);
    try std.testing.expectEqualStrings("Apply", copied[1].name);
    tree.storage[0] = 'x';
    try std.testing.expectEqualStrings("Tools", copied[0].name);
    @memset(&labels, 0xa5);
    nodes[0].id = 77;
    try std.testing.expectError(error.SemanticExportCapacityExceeded, tree.exportSubtree(8, nodes[0..1], &labels));
    try std.testing.expectEqual(@as(u64, 77), nodes[0].id);
    for (labels) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    // An invalid peer outside the requested subtree must also reject atomically.
    tree.entries[3].parent = 999;
    try std.testing.expectError(error.MissingSemanticParent, tree.exportSubtree(8, &nodes, &labels));
    try std.testing.expectEqual(@as(u64, 77), nodes[0].id);
    for (labels) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

pub const Action = union(enum) {
    invoke: u64,
    set_focus: u64,
    set_value: struct { id: u64, text: []const u8 },
    select_text: struct { id: u64, start_utf16: usize, end_utf16: usize },
    set_range: struct { id: u64, value: f64 },
};
/// Request-time authority copied from the same native semantic publication.
/// A zero record describes an ordinary semantic node without a recipient.
pub const RecipientAuthority = extern struct {
    epoch: u64 = 0,
    serial: u64 = 0,
    id: u64 = 0,
    publication: u64 = 0,
    slot: u32 = 0,
    kind: u32 = 0,
    pub fn capture(registration_key: recipients.Key, publication: u64, recipient_kind: recipients.Kind) !RecipientAuthority {
        if (registration_key.epoch == 0 or registration_key.serial == 0 or registration_key.id == 0 or registration_key.slot >= recipients.max_fields or publication == 0) return error.InvalidRecipientAuthority;
        return .{ .epoch = registration_key.epoch, .serial = registration_key.serial, .id = registration_key.id, .publication = publication, .slot = registration_key.slot, .kind = @intFromEnum(recipient_kind) };
    }
    fn registrationKey(self: RecipientAuthority) !recipients.Key {
        if (self.epoch == 0 or self.serial == 0 or self.id == 0 or self.publication == 0 or self.slot >= recipients.max_fields or self.kind > @intFromEnum(recipients.Kind.control)) return error.InvalidRecipientAuthority;
        return .{ .epoch = self.epoch, .serial = self.serial, .id = self.id, .slot = @intCast(self.slot) };
    }
};
pub const CapturedRecipientPayload = union(enum) { ordinary: Action, collection: *const virtual_lists.authority.RowRequest };
pub const CapturedRecipientAction = struct { key: recipients.Key, publication: u64, kind: recipients.Kind, action: CapturedRecipientPayload };
const NativeNode = extern struct {
    id: u64,
    parent: u64,
    role: u32,
    flags: u32,
    name_start: u32,
    name_len: u32,
    value_start: u32,
    value_len: u32,
    selection_start: u32,
    selection_end: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    range_value: f64,
    range_minimum: f64,
    range_maximum: f64,
    range_small_change: f64,
    range_large_change: f64,
};
const NativeAction = extern struct {
    context: ?*anyopaque,
    kind: u32,
    id: u64,
    value: ?[*]const u16,
    value_len: u32,
    start: u32,
    end: u32,
    number: f64,
    recipient: RecipientAuthority,
};
const NativeSpace = extern struct { xx: f64, yx: f64, xy: f64, yy: f64, x0: f64, y0: f64 };
const NativeGeometryRef = extern struct { x: f64, y: f64, width: f64, height: f64, space: u32, clip: u32 };
/// Explicitly prepared serialization scratch. C owns a separate value copy;
/// no MTA provider reads this or any other Zig address.
pub const NativeGeometry = extern struct {
    spaces: [affine_state.max_scopes + affine_state.max_captures + 1]NativeSpace,
    clips: [affine_state.max_clips]NativeGeometryRef,
    nodes: [max_nodes]NativeGeometryRef,
    space_count: u32,
    clip_count: u32,
    node_count: u32,
    origin_x: f64,
    origin_y: f64,
    scale: f64,
};
extern fn zua_create(?*anyopaque, *const fn (*anyopaque, *anyopaque) callconv(.c) c_int, *anyopaque) ?*anyopaque;
extern fn zua_begin_close(*anyopaque) void;
extern fn zua_disconnect(*anyopaque) i32;
extern fn zua_publish(*anyopaque, [*]const NativeNode, u32, [*]const u16, u32) i32;
extern fn zua_publish_geometry(*anyopaque, [*]const NativeNode, u32, [*]const u16, u32, *const NativeGeometry) i32;
extern fn zua_publish_registered(*anyopaque, [*]const NativeNode, u32, [*]const u16, u32, [*]const RecipientAuthority) i32;
extern fn zua_publish_geometry_registered(*anyopaque, [*]const NativeNode, u32, [*]const u16, u32, *const NativeGeometry, [*]const RecipientAuthority) i32;
extern fn zua_collections_create() ?*anyopaque;
extern fn zua_collections_free(*anyopaque) void;
extern fn zua_collections_commit(*anyopaque, *anyopaque) i32;
extern fn zua_collections_metadata_size() usize;
extern fn zua_collections_count() u32;
extern fn zua_geometry_create() ?*anyopaque;
extern fn zua_geometry_free(*anyopaque) void;
extern fn zua_geometry_commit(*anyopaque, *anyopaque) i32;
extern fn zua_geometry_release(*anyopaque) void;
extern fn zua_geometry_count() u32;
extern fn zua_position_changed(*anyopaque, f64, f64) i32;
extern fn zua_get_object(*anyopaque, usize, isize) isize;
extern fn zua_retain_provider(*anyopaque, u64) ?*anyopaque;
extern fn zua_take_action(*anyopaque, *NativeAction) c_int;
extern fn zua_take_collection_action(*anyopaque, *virtual_lists.authority.RowRequest) c_int;
extern fn zua_finish_action(*anyopaque) void;
extern fn zua_resource_counts(*u32, *u32, *u32, *u32) void;

pub const ResourceCounts = struct { states: u32, providers: u32, ranges: u32, actions: u32 };
pub fn recipientsMetadataBytes() usize {
    return if (builtin.os.tag == .windows) zua_collections_metadata_size() else 0;
}
pub fn collectionsResourceCount() u32 {
    return if (builtin.os.tag == .windows) zua_collections_count() else 0;
}
pub fn geometryResourceCount() u32 {
    return if (builtin.os.tag == .windows) zua_geometry_count() else 0;
}
pub fn resourceCounts() ResourceCounts {
    var counts: ResourceCounts = undefined;
    zua_resource_counts(&counts.states, &counts.providers, &counts.ranges, &counts.actions);
    return counts;
}

const NativeCleanup = struct {
    node: z.Cleanup,
    native: *anyopaque,
    allocator: std.mem.Allocator,
    app: *z.App,
    window_id: z.diagnostics.WindowId,

    fn run(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        defer self.allocator.destroy(self);
        const hr = zua_disconnect(self.native);
        if (hr < 0) self.app.report(.{ .domain = .hresult, .operation = .resource_release, .window = self.window_id, .code = @bitCast(hr), .err = error.AccessibilityDisconnectFailed });
    }
};

/// Keep the Bridge at a stable address through detach. Native COM objects own
/// independent snapshot/refcount state and may outlive both this object and App.
/// Native COM allocation occurs at attach/provider creation, never per publish.
/// Attach also allocates one cleanup node with the App allocator. App drains it
/// before deinit; immutable COM identity remains available for disconnection.
pub const Bridge = struct {
    context: *anyopaque,
    on_action: *const fn (*anyopaque, z.Window, Action) void,
    on_recipient_action: ?*const fn (*anyopaque, z.Window, CapturedRecipientAction) void = null,
    window: ?z.Window = null,
    native: ?*anyopaque = null,
    cleanup: ?*NativeCleanup = null,
    geometry_scratch: ?*NativeGeometry = null,
    last_origin: ?affine.Point = null,
    last_hresult: i32 = 0,

    pub const GeometryCandidate = struct { native: *anyopaque, scratch: *NativeGeometry };
    pub const RecipientsCandidate = struct { native: *anyopaque };

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, Action) void) Bridge {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(self: *Bridge, window: z.Window) !void {
        virtual_lists.enableMath();
        window.app.assertOwner();
        if (self.native != null) return error.AlreadyAttached;
        const handle = window.nativeHandle() orelse return error.Closed;
        const cleanup = try window.app.allocator.create(NativeCleanup);
        errdefer window.app.allocator.destroy(cleanup);
        const native = zua_create(handle, enqueue, self) orelse return error.AccessibilityCreationFailed;
        cleanup.* = .{
            .node = .{ .task = .{ .context = cleanup, .call = NativeCleanup.run } },
            .native = native,
            .allocator = window.app.allocator,
            .app = window.app,
            .window_id = window.diagnosticId(),
        };
        self.window = window;
        self.native = native;
        self.cleanup = cleanup;
    }
    pub fn publish(self: *Bridge, tree: *const Tree) !void {
        try self.publishWithRecipients(tree, null);
    }
    pub fn publishRegistered(self: *Bridge, tree: *const Tree, keys: []const RecipientAuthority) !void {
        if (keys.len != tree.len) return error.InvalidRecipientAuthority;
        try self.publishWithRecipients(tree, keys);
    }
    fn publishWithRecipients(self: *Bridge, tree: *const Tree, keys: ?[]const RecipientAuthority) !void {
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (tree.len == 0 or tree.entries[0].id != root_id) return error.InvalidSemanticRoot;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        if (hwnd == null or c.ClientToScreen(hwnd, &origin) == 0) return error.Closed;
        const scale = @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96;
        const visible = c.IsWindowVisible(hwnd) != 0 and c.IsIconic(hwnd) == 0;
        const enabled = c.IsWindowEnabled(hwnd) != 0;
        const focused = c.GetFocus() == hwnd;
        var native_nodes: [max_nodes]NativeNode = undefined;
        var native_text: [text_capacity]u16 = undefined;
        var used: usize = 0;
        for (tree.entries[0..tree.len], 0..) |entry, index| {
            const name_start = used;
            const name_len = try std.unicode.utf8ToUtf16Le(native_text[used..], tree.storage[entry.name_start..][0..entry.name_len]);
            used += name_len;
            const value_start = used;
            const value = tree.storage[entry.value_start..][0..entry.value_len];
            const value_len = try std.unicode.utf8ToUtf16Le(native_text[used..], value);
            used += value_len;
            native_nodes[index] = .{
                .id = entry.id,
                .parent = entry.parent orelse root_id,
                .role = @intFromEnum(entry.role),
                .flags = @as(u32, @intFromBool(entry.enabled and enabled)) | (@as(u32, @intFromBool(entry.focused and focused)) << 1) | (@as(u32, @intFromBool(entry.read_only)) << 2) | (@as(u32, @intFromBool(!visible or entry.bounds.width == 0 or entry.bounds.height == 0)) << 3) | (@as(u32, @intFromBool(entry.checked)) << 4),
                .name_start = @intCast(name_start),
                .name_len = @intCast(name_len),
                .value_start = @intCast(value_start),
                .value_len = @intCast(value_len),
                .selection_start = @intCast(try std.unicode.calcUtf16LeLen(value[0..entry.selection_start])),
                .selection_end = @intCast(try std.unicode.calcUtf16LeLen(value[0..entry.selection_end])),
                .x = @as(f64, entry.bounds.x) * scale + @as(f64, @floatFromInt(origin.x)),
                .y = @as(f64, entry.bounds.y) * scale + @as(f64, @floatFromInt(origin.y)),
                .width = @as(f64, entry.bounds.width) * scale,
                .height = @as(f64, entry.bounds.height) * scale,
                .range_value = entry.range_value,
                .range_minimum = entry.range_minimum,
                .range_maximum = entry.range_maximum,
                .range_small_change = entry.range_small_change,
                .range_large_change = entry.range_large_change,
            };
        }
        if (window.isClosed() or self.native == null) return error.Closed;
        const origin_point: affine.Point = .{ .x = @floatFromInt(origin.x), .y = @floatFromInt(origin.y) };
        const hr = if (tree.mapped) |snapshot| blk: {
            const scratch = self.geometry_scratch orelse return error.SemanticGeometryRequired;
            if (snapshot.semantic_len != tree.len) return error.InvalidSemanticGeometry;
            scratch.space_count = @intCast(snapshot.geometry.space_len);
            scratch.clip_count = @intCast(snapshot.geometry.clip_len);
            scratch.node_count = @intCast(tree.len);
            scratch.origin_x = origin_point.x;
            scratch.origin_y = origin_point.y;
            scratch.scale = scale;
            for (snapshot.geometry.spaces[0..snapshot.geometry.space_len], 0..) |space, index| {
                const inverse = space.to_local;
                scratch.spaces[index] = .{ .xx = inverse.xx, .yx = inverse.yx, .xy = inverse.xy, .yy = inverse.yy, .x0 = inverse.x0, .y0 = inverse.y0 };
            }
            for (snapshot.geometry.clips[0..snapshot.geometry.clip_len], 0..) |clip, index| scratch.clips[index] = geometryRef(clip.bounds, .{ .space = clip.space, .clip = clip.parent });
            for (snapshot.semantics[0..snapshot.semantic_len], 0..) |item, index| scratch.nodes[index] = geometryRef(item.local_bounds, item.reference);
            break :blk if (keys) |values| zua_publish_geometry_registered(self.native.?, &native_nodes, @intCast(tree.len), &native_text, @intCast(used), scratch, values.ptr) else zua_publish_geometry(self.native.?, &native_nodes, @intCast(tree.len), &native_text, @intCast(used), scratch);
        } else if (keys) |values| zua_publish_registered(self.native.?, &native_nodes, @intCast(tree.len), &native_text, @intCast(used), values.ptr) else zua_publish(self.native.?, &native_nodes, @intCast(tree.len), &native_text, @intCast(used));
        self.last_hresult = hr;
        if (hr < 0) return error.AccessibilityPublishFailed;
        self.last_origin = origin_point;
    }
    /// Allocate the optional copied authority store before publishing a new
    /// recipient workspace. No native operation borrows the candidate's owner.
    pub fn createRecipientsCandidate(self: *Bridge) !RecipientsCandidate {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        if (self.native == null) return error.Closed;
        return .{ .native = zua_collections_create() orelse return error.OutOfMemory };
    }
    pub fn destroyRecipientsCandidate(candidate: RecipientsCandidate) void {
        if (builtin.os.tag == .windows) zua_collections_free(candidate.native);
    }
    pub fn commitRecipientsCandidate(self: *Bridge, candidate: RecipientsCandidate) !void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const native = self.native orelse return error.Closed;
        self.last_hresult = zua_collections_commit(native, candidate.native);
        if (self.last_hresult < 0) return error.AccessibilityPreparationFailed;
    }
    pub fn prepareVirtualLists(self: *Bridge, options: virtual_lists.Options) !void {
        _ = try virtual_lists.requiredMetadata(options);
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        const state = self.native orelse return error.Closed;
        if (virtual_lists.prepared(state)) {
            const current = try virtual_lists.stats(state);
            if (current.capacity != options.lists or current.model_limit != options.model_bytes or
                current.provider_limit != options.provider_bytes or current.request_limit != options.request_bytes) return error.NativeCollectionLimitsMismatch;
            return;
        }
        const candidate = try virtual_lists.createCandidate(options);
        errdefer virtual_lists.freeCandidate(candidate);
        try virtual_lists.commitCandidate(state, candidate);
    }
    pub fn virtualListsPrepared(self: *Bridge) bool {
        return if (self.native) |state| virtual_lists.prepared(state) else false;
    }
    pub fn virtualListStats(self: *Bridge) !virtual_lists.Stats {
        return virtual_lists.stats(self.native orelse return error.Closed);
    }
    pub fn installVirtualList(self: *Bridge, key: recipients.Key, product: *virtual_lists.Prepared, revision: u64, bits: []const u64) !void {
        try virtual_lists.install(self.native orelse return error.Closed, key, product, revision, bits);
    }
    pub fn applyVirtualListSelection(self: *Bridge, key: recipients.Key, model: u64, patch: anytype) !void {
        try virtual_lists.applySelection(self.native orelse return error.Closed, key, model, patch);
    }
    pub fn withdrawVirtualList(self: *Bridge, key: recipients.Key) void {
        if (self.native) |state| virtual_lists.withdraw(state, key);
    }
    pub fn clearVirtualLists(self: *Bridge) void {
        if (self.native) |state| virtual_lists.clear(state);
    }
    pub fn beginVirtualListsFrame(self: *Bridge) !void {
        if (self.native) |state| try virtual_lists.beginFrame(state);
    }
    pub fn validateVirtualListsFrame(self: *Bridge) !void {
        if (self.native) |state| try virtual_lists.validateFrame(state);
    }
    pub fn stageVirtualList(self: *Bridge, key: recipients.Key, model: u64, selection: u64, viewport: virtual_lists.Viewport, mapping: *const virtual_lists.math.Mapping) !void {
        try virtual_lists.stage(self.native orelse return error.Closed, key, model, selection, viewport, mapping);
    }
    pub fn createGeometryCandidate(self: *Bridge, scratch: *NativeGeometry) !GeometryCandidate {
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        if (self.native == null) return error.Closed;
        if (self.geometry_scratch != null) return error.AlreadyPrepared;
        return .{ .native = zua_geometry_create() orelse return error.OutOfMemory, .scratch = scratch };
    }
    pub fn destroyGeometryCandidate(candidate: GeometryCandidate) void {
        zua_geometry_free(candidate.native);
    }
    pub fn commitGeometryCandidate(self: *Bridge, candidate: GeometryCandidate) !void {
        const native = self.native orelse return error.Closed;
        self.last_hresult = zua_geometry_commit(native, candidate.native);
        if (self.last_hresult < 0) return error.AccessibilityPreparationFailed;
        self.geometry_scratch = candidate.scratch;
    }
    pub fn releaseGeometry(self: *Bridge) void {
        self.geometry_scratch = null;
        if (self.native) |native| zua_geometry_release(native);
    }
    /// Window movement changes screen coordinates without changing layout.
    /// No rendering, allocation or cross-thread owner access is needed.
    pub fn positionChanged(self: *Bridge) !void {
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const previous = self.last_origin orelse return;
        const native = self.native orelse return error.Closed;
        var origin: c.POINT = .{ .x = 0, .y = 0 };
        const hwnd: c.HWND = @ptrCast(window.nativeHandle());
        if (hwnd == null or c.ClientToScreen(hwnd, &origin) == 0) return error.Closed;
        if (window.isClosed() or self.native != native) return error.Closed;
        const current: affine.Point = .{ .x = @floatFromInt(origin.x), .y = @floatFromInt(origin.y) };
        self.last_hresult = zua_position_changed(native, current.x - previous.x, current.y - previous.y);
        if (self.last_hresult < 0) return error.AccessibilityPublishFailed;
        self.last_origin = current;
    }
    pub fn getObject(self: *Bridge, window: z.Window, wp: usize, lp: isize) ?isize {
        window.app.assertOwner();
        if (lp != -25) return null;
        const native = self.native orelse return null;
        return zua_get_object(native, wp, lp);
    }
    /// An owned IRawElementProviderSimple COM reference for native interop.
    /// The caller must Release it. After detach it retains only native state;
    /// property/pattern operations return UIA_E_ELEMENTNOTAVAILABLE.
    pub fn retainProvider(self: *Bridge, id: u64) !*anyopaque {
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        return zua_retain_provider(self.native.?, id) orelse error.NativeProviderUnavailable;
    }
    /// Revoke Zig entry points now and queue native disconnection at a safe point.
    /// Pending cleanup owns its own storage and never borrows this Bridge.
    pub fn detach(self: *Bridge) void {
        const window = self.window;
        if (window) |value| value.app.assertOwner();
        const native = self.native;
        const cleanup = self.cleanup;
        // MTA enqueue reads this Bridge while holding the native State lock.
        // begin_close takes that lock, waits out enqueue, and revokes context.
        // It makes no COM callouts, so clearing Zig fields afterwards is safe.
        if (native) |state| zua_begin_close(state);
        self.native = null;
        self.window = null;
        self.cleanup = null;
        self.geometry_scratch = null;
        self.last_origin = null;
        if (native != null) {
            const owned = cleanup.?;
            owned.app.deferCleanup(&owned.node);
        }
    }
    fn enqueue(ptr: *anyopaque, action: *anyopaque) callconv(.c) c_int {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        const window = self.window orelse return 0;
        if (window.app.owner == std.Thread.getCurrentId()) {
            dispatch(action);
            return 1;
        }
        window.app.post(.{ .context = action, .call = dispatch }) catch return 0;
        return 1;
    }
    fn dispatch(ptr: *anyopaque) void {
        var native_scope: ?z.NativeAppCallbackScope = null;
        defer if (native_scope) |scope| scope.end();
        defer zua_finish_action(ptr);
        var native: NativeAction = undefined;
        if (zua_take_action(ptr, &native) == 0) return;
        const self: *Bridge = @ptrCast(@alignCast(native.context orelse return));
        const window = self.window orelse return;
        // Keep independent native ingress through both the Window pin's final
        // release and the action's foreign cleanup, including synchronous Invoke.
        native_scope = window.app.beginNativeCallback();
        const scope = window.beginCallback() orelse return;
        defer scope.end();
        const state = window.state() catch return;
        if (!state.enabled or state.modal_blocked) return;
        if (native.kind == 6) return self.dispatchCollection(ptr, window, native.recipient);
        var text: [4096 * 3]u8 = undefined;
        const action: Action = switch (native.kind) {
            1 => .{ .invoke = native.id },
            2 => .{ .set_focus = native.id },
            3 => blk: {
                const len = std.unicode.utf16LeToUtf8(&text, native.value.?[0..native.value_len]) catch return;
                break :blk .{ .set_value = .{ .id = native.id, .text = text[0..len] } };
            },
            4 => .{ .select_text = .{ .id = native.id, .start_utf16 = native.start, .end_utf16 = native.end } },
            5 => .{ .set_range = .{ .id = native.id, .value = native.number } },
            else => return,
        };
        if (native.recipient.serial != 0) {
            const callback = self.on_recipient_action orelse return;
            const key = native.recipient.registrationKey() catch return;
            callback(self.context, window, .{ .key = key, .publication = native.recipient.publication, .kind = @enumFromInt(native.recipient.kind), .action = .{ .ordinary = action } });
            return;
        }
        self.on_action(self.context, window, action);
    }
    noinline fn dispatchCollection(self: *Bridge, action: *anyopaque, window: z.Window, captured: RecipientAuthority) void {
        const callback = self.on_recipient_action orelse return;
        if (captured.serial == 0 or captured.kind != 1) return;
        const key = captured.registrationKey() catch return;
        var request: virtual_lists.authority.RowRequest = undefined;
        if (zua_take_collection_action(action, &request) == 0) return;
        if (request.authority.publication != captured.publication) return;
        callback(self.context, window, .{ .key = key, .publication = captured.publication, .kind = .control, .action = .{ .collection = &request } });
    }
};

fn geometryRef(bounds: affine.Rect, reference: affine.Ref) NativeGeometryRef {
    return .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height, .space = @intFromEnum(reference.space), .clip = if (reference.clip) |id| @intFromEnum(id) else std.math.maxInt(u32) };
}

comptime {
    if (@sizeOf(RecipientAuthority) != 40 or (@sizeOf(usize) == 8 and @sizeOf(NativeAction) != 96)) @compileError("captured native action ABI mismatch");
    if (@sizeOf(NativeGeometry) != 16472 or @alignOf(NativeGeometry) != 8) @compileError("semantic geometry ABI mismatch");
}

test "captured recipient authority preserves exact key publication and kind" {
    const key: recipients.Key = .{ .epoch = 8, .serial = 12, .id = 5, .slot = 3 };
    const captured = try RecipientAuthority.capture(key, 19, .control);
    try std.testing.expectEqualDeep(key, try captured.registrationKey());
    try std.testing.expectEqual(@as(u64, 19), captured.publication);
    try std.testing.expectEqual(@as(u32, 1), captured.kind);
    try std.testing.expectError(error.InvalidRecipientAuthority, RecipientAuthority.capture(key, 0, .text));
    try std.testing.expectError(error.InvalidRecipientAuthority, (RecipientAuthority{}).registrationKey());
    var invalid = captured;
    invalid.kind = 2;
    try std.testing.expectError(error.InvalidRecipientAuthority, invalid.registrationKey());
    invalid = captured;
    invalid.slot = recipients.max_fields;
    try std.testing.expectError(error.InvalidRecipientAuthority, invalid.registrationKey());
}

test "semantic tree copies explicit records and rejects invalid identities and ranges" {
    var tree: Tree = .{};
    const bounds: z.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 30 };
    try tree.reset("Window", bounds);
    var name = [_]u8{ 'S', 'a', 'v', 'e' };
    try tree.add(.{ .id = 1, .role = .button, .name = &name, .bounds = bounds });
    name[0] = 'X';
    const entry = tree.entries[1];
    try std.testing.expectEqualStrings("Save", tree.storage[entry.name_start..][0..entry.name_len]);
    try std.testing.expectError(error.DuplicateSemanticId, tree.add(.{ .id = 1, .role = .button, .name = "Other", .bounds = bounds }));
    try std.testing.expectError(error.MissingSemanticParent, tree.add(.{ .id = 2, .parent = 99, .role = .text, .name = "Text", .bounds = bounds }));
    try std.testing.expectError(error.InvalidSelection, tree.add(.{ .id = 2, .role = .text_box, .name = "Input", .value = "中", .selection_start = 1, .bounds = bounds }));
    try std.testing.expectEqual(@as(usize, 2), tree.len);
}
