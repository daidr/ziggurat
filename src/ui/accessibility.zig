const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const affine_state = @import("affine_state.zig");
const recipients = @import("text_field_workspace.zig");
const affine = affine_state.affine;
pub const virtual_lists = @import("collection_native.zig");
const c = if (builtin.os.tag == .windows) @import("ziggurat_c_win32") else struct {};

pub const max_nodes = 128;
pub const text_capacity = 32768;
pub const root_id: u64 = 0;
pub const Role = enum(u32) { window, group, button, text, text_box, checkbox, radio, toggle_switch, progress, radio_group, slider, stepper, list, tab_list, tab, toolbar, splitter, link, disclosure, meter, navigation, list_box, list_item, combo_box, tooltip, status, search, image, tree, tree_item, table, table_header, column_header, table_row, token_field, token, popup, calendar, color_well, dialog, alert_dialog, menu, menu_item, menu_item_checkbox, menu_item_radio, region, log, timer, alert, separator, row_header, option, article, cell, heading };
/// The kind of popup an element opens, as ARIA's aria-haspopup.
pub const Popup = enum(u3) { none, menu, list_box, tree, grid, dialog };
/// Which item an element is the current one of, as ARIA's aria-current:
/// `item` is aria-current="true".
pub const Current = enum(u3) { none, item, page, step, location, date, time };
/// The order a table is sorted in by a column, as ARIA's aria-sort.
pub const Sort = enum(u2) { none, ascending, descending, other };
/// What the suggestions of a text field or combo box complete as the user
/// types, as ARIA's aria-autocomplete.
pub const AutoComplete = enum(u2) { none, inline_text, list, both };
pub const Node = struct {
    id: u64,
    parent: ?u64 = root_id,
    role: Role,
    name: []const u8,
    value: []const u8 = "",
    /// Help or error text that describes the control beyond its name.
    description: []const u8 = "",
    bounds: z.Rect,
    enabled: bool = true,
    focused: bool = false,
    read_only: bool = false,
    checked: bool = false,
    /// A checkbox that is partly checked, such as one over a group whose
    /// boxes are only some checked; `checked` is then false.
    mixed: bool = false,
    /// The value fails the application's validation.
    invalid: bool = false,
    /// A form cannot be submitted without a value.
    required: bool = false,
    /// A text box whose value is a password: it reports no value, text or
    /// selection, only that it holds a password.
    password: bool = false,
    /// A tree or table whose items can be selected together.
    multiple: bool = false,
    /// Whether a tree item's children are shown; null for a leaf.
    expanded: ?bool = null,
    range_value: f64 = 0,
    range_minimum: f64 = 0,
    range_maximum: f64 = 100,
    range_small_change: f64 = 0,
    range_large_change: f64 = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    /// The place of an item among all of its list's, table's or tree's,
    /// from 1, whether the others are built or not, as a list built only
    /// in view has: assistive technology reads "5 of 10,000". 0 counts the
    /// item among the built ones.
    position: u32 = 0,
    /// On a list, table or tree: how many items it has, built or not; 0 for
    /// those built.
    set_size: u32 = 0,
    /// How deep a tree item is, from 1; 0 for none or not given.
    level: u32 = 0,
    /// Unavailable to assistive technology while it keeps the keyboard
    /// focus, as ARIA's aria-disabled: `enabled` reads false, the node
    /// stays focusable, and only the focus reaches it from assistive
    /// technology.
    focusable_disabled: bool = false,
    /// Its content is about to change, as a region loading, which
    /// assistive technology waits for before reading it: aria-busy.
    busy: bool = false,
    /// A cell of a grid that is chosen or not; null for one that cannot be.
    selected: ?bool = null,
    /// A separator or slider running up and down.
    vertical: bool = false,
    popup: Popup = .none,
    current: Current = .none,
    sort: Sort = .none,
    auto_complete: AutoComplete = .none,
    /// What screen readers call the node's role in place of its own, as
    /// "carousel" for a group: aria-roledescription. "" reads the role.
    role_description: []const u8 = "",
    /// The keys that press or focus it, as aria-keyshortcuts, written as
    /// the platform's menus write them ("⌘K" on macOS, "Ctrl+K" elsewhere),
    /// separated by spaces.
    key_shortcuts: []const u8 = "",
    /// The text of a range's value beside its number, as aria-valuetext:
    /// "3 of 5 stars".
    value_text: []const u8 = "",
    /// The node whose content or presence this one controls, as the region
    /// a disclosure opens: aria-controls. 0 for none.
    controls: u64 = 0,
    /// Native content inside the node whose own tree assistive technology
    /// reads there, such as a web view's page: its GtkWidget on Linux,
    /// whose accessible becomes the node's first child, or its NSView on
    /// macOS, which becomes the element's first child. Ignored on Windows.
    native: ?*anyopaque = null,
};
/// Nodes holding native content (`Node.native`) in one publication.
pub const max_native_pages = 16;
pub const Entry = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    name_start: usize,
    name_len: usize,
    value_start: usize,
    value_len: usize,
    description_start: usize,
    description_len: usize,
    bounds: z.Rect,
    enabled: bool,
    focused: bool,
    read_only: bool,
    checked: bool,
    mixed: bool,
    invalid: bool,
    required: bool,
    password: bool,
    multiple: bool,
    expanded: ?bool,
    range_value: f64,
    range_minimum: f64,
    range_maximum: f64,
    range_small_change: f64,
    range_large_change: f64,
    selection_start: usize,
    selection_end: usize,
    position: u32 = 0,
    set_size: u32 = 0,
    level: u32 = 0,
    native: ?*anyopaque = null,
    focusable_disabled: bool = false,
    busy: bool = false,
    selected: ?bool = null,
    vertical: bool = false,
    popup: Popup = .none,
    current: Current = .none,
    sort: Sort = .none,
    auto_complete: AutoComplete = .none,
    extra_start: usize = 0,
    role_description_len: usize = 0,
    key_shortcuts_len: usize = 0,
    value_text_len: usize = 0,
    controls: u64 = 0,

    fn extraLen(self: Entry) usize {
        return self.role_description_len + self.key_shortcuts_len + self.value_text_len;
    }
    pub fn roleDescription(self: Entry, storage: []const u8) []const u8 {
        return storage[self.extra_start..][0..self.role_description_len];
    }
    pub fn keyShortcuts(self: Entry, storage: []const u8) []const u8 {
        return storage[self.extra_start + self.role_description_len ..][0..self.key_shortcuts_len];
    }
    pub fn valueText(self: Entry, storage: []const u8) []const u8 {
        return storage[self.extra_start + self.role_description_len + self.key_shortcuts_len ..][0..self.value_text_len];
    }
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
            if (entry.name_start > self.used or entry.name_len > self.used - entry.name_start or entry.value_start > self.used or entry.value_len > self.used - entry.value_start or entry.description_start > self.used or entry.description_len > self.used - entry.description_start or entry.extra_start > self.used or entry.extraLen() > self.used - entry.extra_start) return error.InvalidSemanticText;
            const name = self.storage[entry.name_start..][0..entry.name_len];
            const value = self.storage[entry.value_start..][0..entry.value_len];
            const description = self.storage[entry.description_start..][0..entry.description_len];
            if (!std.unicode.utf8ValidateSlice(name) or !std.unicode.utf8ValidateSlice(value) or !std.unicode.utf8ValidateSlice(description)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, value, 0) != null or std.mem.indexOfScalar(u8, description, 0) != null) return error.EmbeddedNul;
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
                bytes += entry.name_len + entry.value_len + entry.description_len + entry.extraLen();
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
            const description = text[used..][0..entry.description_len];
            @memcpy(description, self.storage[entry.description_start..][0..entry.description_len]);
            used += description.len;
            const role_description = text[used..][0..entry.role_description_len];
            @memcpy(role_description, entry.roleDescription(&self.storage));
            used += role_description.len;
            const key_shortcuts = text[used..][0..entry.key_shortcuts_len];
            @memcpy(key_shortcuts, entry.keyShortcuts(&self.storage));
            used += key_shortcuts.len;
            const value_text = text[used..][0..entry.value_text_len];
            @memcpy(value_text, entry.valueText(&self.storage));
            used += value_text.len;
            nodes[written] = .{ .id = entry.id, .parent = entry.parent, .role = entry.role, .name = name, .value = value, .description = description, .bounds = entry.bounds, .enabled = entry.enabled, .focused = entry.focused, .read_only = entry.read_only, .checked = entry.checked, .mixed = entry.mixed, .invalid = entry.invalid, .required = entry.required, .password = entry.password, .multiple = entry.multiple, .expanded = entry.expanded, .range_value = entry.range_value, .range_minimum = entry.range_minimum, .range_maximum = entry.range_maximum, .range_small_change = entry.range_small_change, .range_large_change = entry.range_large_change, .selection_start = entry.selection_start, .selection_end = entry.selection_end, .position = entry.position, .set_size = entry.set_size, .level = entry.level, .native = entry.native, .focusable_disabled = entry.focusable_disabled, .busy = entry.busy, .selected = entry.selected, .vertical = entry.vertical, .popup = entry.popup, .current = entry.current, .sort = entry.sort, .auto_complete = entry.auto_complete, .role_description = role_description, .key_shortcuts = key_shortcuts, .value_text = value_text, .controls = entry.controls };
            written += 1;
        };
        return nodes[0..written];
    }

    /// The entry of `id`, if the tree has one.
    pub fn find(self: *const Tree, id: u64) ?*const Entry {
        for (self.entries[0..self.len]) |*entry| if (entry.id == id) return entry;
        return null;
    }
    pub fn reset(self: *Tree, name: []const u8, bounds: z.Rect) !void {
        self.len = 0;
        self.used = 0;
        self.mapped = null;
        try self.add(.{ .id = root_id, .parent = null, .role = .window, .name = name, .bounds = bounds });
    }
    pub fn add(self: *Tree, node: Node) !void {
        if (self.len == max_nodes) return error.TooManySemanticNodes;
        inline for (.{ node.name, node.value, node.description, node.role_description, node.key_shortcuts, node.value_text }) |field| {
            if (!std.unicode.utf8ValidateSlice(field)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, field, 0) != null) return error.EmbeddedNul;
        }
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
        const extra_len = node.role_description.len + node.key_shortcuts.len + node.value_text.len;
        if (node.name.len + node.value.len + node.description.len + extra_len > self.storage.len - self.used) return error.SemanticTextCapacityExceeded;
        const start = self.used;
        const description_start = start + node.name.len + node.value.len;
        const extra_start = description_start + node.description.len;
        @memcpy(self.storage[start..][0..node.name.len], node.name);
        @memcpy(self.storage[start + node.name.len ..][0..node.value.len], node.value);
        @memcpy(self.storage[description_start..][0..node.description.len], node.description);
        @memcpy(self.storage[extra_start..][0..node.role_description.len], node.role_description);
        @memcpy(self.storage[extra_start + node.role_description.len ..][0..node.key_shortcuts.len], node.key_shortcuts);
        @memcpy(self.storage[extra_start + node.role_description.len + node.key_shortcuts.len ..][0..node.value_text.len], node.value_text);
        self.entries[self.len] = .{
            .id = node.id,
            .parent = node.parent,
            .role = node.role,
            .name_start = start,
            .name_len = node.name.len,
            .value_start = start + node.name.len,
            .value_len = node.value.len,
            .description_start = description_start,
            .description_len = node.description.len,
            .bounds = node.bounds,
            .enabled = node.enabled,
            .focused = node.focused,
            .read_only = node.read_only,
            .checked = node.checked,
            .mixed = node.mixed,
            .invalid = node.invalid,
            .required = node.required,
            .password = node.password,
            .multiple = node.multiple,
            .expanded = node.expanded,
            .range_value = node.range_value,
            .range_minimum = node.range_minimum,
            .range_maximum = node.range_maximum,
            .range_small_change = node.range_small_change,
            .range_large_change = node.range_large_change,
            .selection_start = node.selection_start,
            .selection_end = node.selection_end,
            .position = node.position,
            .set_size = node.set_size,
            .level = node.level,
            .native = node.native,
            .focusable_disabled = node.focusable_disabled,
            .busy = node.busy,
            .selected = node.selected,
            .vertical = node.vertical,
            .popup = node.popup,
            .current = node.current,
            .sort = node.sort,
            .auto_complete = node.auto_complete,
            .extra_start = extra_start,
            .role_description_len = node.role_description.len,
            .key_shortcuts_len = node.key_shortcuts.len,
            .value_text_len = node.value_text.len,
            .controls = node.controls,
        };
        self.used += node.name.len + node.value.len + node.description.len + extra_len;
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

test "descriptions and form state survive export" {
    var tree: Tree = .{};
    const bounds: z.Rect = .{ .x = 0, .y = 0, .width = 30, .height = 20 };
    try tree.reset("Window", bounds);
    try tree.add(.{ .id = 4, .role = .checkbox, .name = "Terms", .description = "Required to continue", .invalid = true, .required = true, .bounds = bounds });
    try std.testing.expectError(error.EmbeddedNul, tree.add(.{ .id = 5, .role = .button, .name = "x", .description = "a\x00b", .bounds = bounds }));
    try tree.validate();
    var nodes: [1]Node = undefined;
    var text: [32]u8 = undefined;
    const copied = try tree.exportSubtree(4, &nodes, &text);
    try std.testing.expectEqualStrings("Terms", copied[0].name);
    try std.testing.expectEqualStrings("Required to continue", copied[0].description);
    try std.testing.expect(copied[0].invalid and copied[0].required);
    var small: [10]u8 = undefined;
    try std.testing.expectError(error.SemanticExportCapacityExceeded, tree.exportSubtree(4, &nodes, &small));
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

/// What live regions read out, as ARIA's do on the web: the content added
/// to a log (`Role.log`), politely, after what is being read, and an
/// alert's (`Role.alert`) as it appears or changes, at once. Screen
/// readers read neither from the platforms' own live regions outside web
/// content, but all read announcements. Alerts are told by their text,
/// which an element's ID shifting as others appear before it keeps. The
/// first publication says nothing: its content was there before.
pub const Live = struct {
    pub const max_text = 512;
    pub const max_told = 8;
    pub const Told = struct { text: []const u8, assertive: bool, buffer: [max_text]u8 = undefined };
    seen: [max_nodes]u64 = undefined,
    seen_len: usize = 0,
    alerts: [max_told]u64 = undefined,
    alerts_len: usize = 0,
    started: bool = false,

    fn contains(list: []const u64, id: u64) bool {
        return std.mem.indexOfScalar(u64, list, id) != null;
    }
    fn indexOf(tree: *const Tree, id: ?u64) ?usize {
        const wanted = id orelse return null;
        for (tree.entries[0..tree.len], 0..) |entry, at| if (entry.id == wanted) return at;
        return null;
    }
    /// Whether entry `at` is inside entry `ancestor` (or is it).
    fn within(tree: *const Tree, at: usize, ancestor: usize) bool {
        var index: ?usize = at;
        var steps: usize = 0;
        while (index) |i| : (steps += 1) {
            if (i == ancestor) return true;
            if (steps > max_nodes) return false;
            index = indexOf(tree, tree.entries[i].parent);
        }
        return false;
    }
    /// The text of entry `at` and those inside it, as a live region reads
    /// it: the names of the entries with nothing inside, a text's whole,
    /// joined by spaces.
    pub fn text(tree: *const Tree, at: usize, buffer: []u8) []const u8 {
        var len: usize = 0;
        for (tree.entries[at..tree.len], at..) |entry, i| {
            if (!within(tree, i, at)) continue;
            var leaf = true;
            for (tree.entries[i + 1 .. tree.len]) |later| if (later.parent == entry.id) {
                leaf = false;
                break;
            };
            // A text's runs, as links, are in its own name.
            if (i != at) if (indexOf(tree, entry.parent)) |parent| if (parent != at and tree.entries[parent].role == .text and within(tree, parent, at)) continue;
            if (!leaf and entry.role != .text) continue;
            const name = tree.storage[entry.name_start..][0..entry.name_len];
            if (name.len == 0) continue;
            const gap: usize = @intFromBool(len > 0);
            if (len + gap + name.len > buffer.len) break;
            if (gap == 1) buffer[len] = ' ';
            @memcpy(buffer[len + gap ..][0..name.len], name);
            len += gap + name.len;
        }
        return buffer[0..len];
    }
    /// Compare `tree` with the last publication and return what to read
    /// out, filling `told`.
    pub fn update(self: *Live, tree: *const Tree, told: []Told) []Told {
        const speak = self.started;
        self.started = true;
        var has = false;
        for (tree.entries[0..tree.len]) |entry| if (entry.role == .log or entry.role == .alert) {
            has = true;
            break;
        };
        if (!has) {
            self.seen_len = 0;
            self.alerts_len = 0;
            return told[0..0];
        }
        var count: usize = 0;
        var seen: [max_nodes]u64 = undefined;
        var seen_len: usize = 0;
        // The nearest log each entry is in, its own if it is one.
        var log_of: [max_nodes]?usize = @splat(null);
        var added: [max_told]struct { log: usize, len: usize, buffer: [max_text]u8 } = undefined;
        var added_len: usize = 0;
        for (tree.entries[0..tree.len], 0..) |entry, i| {
            const parent = indexOf(tree, entry.parent);
            log_of[i] = switch (entry.role) {
                .log => i,
                .alert => null,
                else => if (parent) |p| (if (p < i) log_of[p] else null) else null,
            };
            const r = log_of[i] orelse continue;
            seen[seen_len] = entry.id;
            seen_len += 1;
            // What a log that showed before gained, at the top of what is
            // new: what is inside it is read with it.
            if (r == i or !speak or !contains(self.seen[0..self.seen_len], tree.entries[r].id) or contains(self.seen[0..self.seen_len], entry.id)) continue;
            if (parent) |p| if (p != r and !contains(self.seen[0..self.seen_len], tree.entries[p].id)) continue;
            var piece: [max_text]u8 = undefined;
            const value = text(tree, i, &piece);
            if (value.len == 0) continue;
            const slot = for (added[0..added_len]) |*item| {
                if (item.log == r) break item;
            } else blk: {
                if (added_len == added.len) continue;
                added[added_len] = .{ .log = r, .len = 0, .buffer = undefined };
                added_len += 1;
                break :blk &added[added_len - 1];
            };
            const gap: usize = @intFromBool(slot.len > 0);
            if (slot.len + gap + value.len > slot.buffer.len) continue;
            if (gap == 1) slot.buffer[slot.len] = ' ';
            @memcpy(slot.buffer[slot.len + gap ..][0..value.len], value);
            slot.len += gap + value.len;
        }
        for (added[0..added_len]) |*item| if (count < told.len) {
            told[count] = .{ .text = undefined, .assertive = false };
            @memcpy(told[count].buffer[0..item.len], item.buffer[0..item.len]);
            told[count].text = told[count].buffer[0..item.len];
            count += 1;
        };
        var alerts: [max_told]u64 = undefined;
        var alerts_len: usize = 0;
        for (tree.entries[0..tree.len], 0..) |entry, i| if (entry.role == .alert) {
            var buffer: [max_text]u8 = undefined;
            const value = text(tree, i, &buffer);
            if (value.len == 0) continue;
            const hash = std.hash.Wyhash.hash(0, value);
            if (speak and !contains(self.alerts[0..self.alerts_len], hash) and !contains(alerts[0..alerts_len], hash) and count < told.len) {
                told[count] = .{ .text = undefined, .assertive = true };
                @memcpy(told[count].buffer[0..value.len], value);
                told[count].text = told[count].buffer[0..value.len];
                count += 1;
            }
            if (alerts_len < alerts.len) {
                alerts[alerts_len] = hash;
                alerts_len += 1;
            }
        };
        @memcpy(self.seen[0..seen_len], seen[0..seen_len]);
        self.seen_len = seen_len;
        @memcpy(self.alerts[0..alerts_len], alerts[0..alerts_len]);
        self.alerts_len = alerts_len;
        return told[0..count];
    }
};

test "live regions read what a log gained and what an alert shows" {
    var tree: Tree = .{};
    const bounds: z.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    var live: Live = .{};
    var told: [Live.max_told]Live.Told = undefined;
    try tree.reset("Window", bounds);
    try tree.add(.{ .id = 1, .role = .log, .name = "Chat", .bounds = bounds });
    try tree.add(.{ .id = 2, .parent = 1, .role = .text, .name = "Hello", .bounds = bounds });
    try std.testing.expectEqual(@as(usize, 0), live.update(&tree, &told).len);
    try tree.reset("Window", bounds);
    try tree.add(.{ .id = 1, .role = .log, .name = "Chat", .bounds = bounds });
    try tree.add(.{ .id = 2, .parent = 1, .role = .text, .name = "Hello", .bounds = bounds });
    try tree.add(.{ .id = 3, .parent = 1, .role = .text, .name = "How are you", .bounds = bounds });
    try tree.add(.{ .id = 4, .role = .alert, .name = "", .bounds = bounds });
    try tree.add(.{ .id = 5, .parent = 4, .role = .text, .name = "Disk full", .bounds = bounds });
    const said = live.update(&tree, &told);
    try std.testing.expectEqual(@as(usize, 2), said.len);
    try std.testing.expectEqualStrings("How are you", said[0].text);
    try std.testing.expect(!said[0].assertive);
    try std.testing.expectEqualStrings("Disk full", said[1].text);
    try std.testing.expect(said[1].assertive);
    // The same alert says nothing again.
    try std.testing.expectEqual(@as(usize, 0), live.update(&tree, &told).len);
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
        return .{ .epoch = registration_key.epoch, .serial = registration_key.serial, .id = registration_key.id, .publication = publication, .slot = registration_key.slot, .kind = @backingInt(recipient_kind) };
    }
    fn registrationKey(self: RecipientAuthority) !recipients.Key {
        if (self.epoch == 0 or self.serial == 0 or self.id == 0 or self.publication == 0 or self.slot >= recipients.max_fields or self.kind > @backingInt(recipients.Kind.control)) return error.InvalidRecipientAuthority;
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
    description_start: u32,
    description_len: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    range_value: f64,
    range_minimum: f64,
    range_maximum: f64,
    range_small_change: f64,
    range_large_change: f64,
    position: u32,
    set_size: u32,
    level: u32,
    /// `NativeState` bits.
    states: u32 = 0,
    role_description_start: u32 = 0,
    role_description_len: u32 = 0,
    key_shortcuts_start: u32 = 0,
    key_shortcuts_len: u32 = 0,
    value_text_start: u32 = 0,
    value_text_len: u32 = 0,
    reserved0: u32 = 0,
    reserved1: u32 = 0,
    controls: u64 = 0,
};
/// What `NativeNode.states` packs, beside `flags`: the 1-bit states, then
/// the popup kind (bits 8 to 10), current (11 to 13), sort (14, 15) and
/// autocomplete (16, 17).
pub const NativeState = struct {
    pub const focusable_disabled: u32 = 1;
    pub const busy: u32 = 2;
    pub const selectable: u32 = 4;
    pub const selected: u32 = 8;
    pub const vertical: u32 = 16;
    pub fn pack(entry: anytype) u32 {
        var bits: u32 = 0;
        if (entry.focusable_disabled) bits |= focusable_disabled;
        if (entry.busy) bits |= busy;
        if (entry.selected) |chosen| bits |= selectable | (if (chosen) selected else 0);
        if (entry.vertical) bits |= vertical;
        bits |= @as(u32, @backingInt(entry.popup)) << 8;
        bits |= @as(u32, @backingInt(entry.current)) << 11;
        bits |= @as(u32, @backingInt(entry.sort)) << 14;
        bits |= @as(u32, @backingInt(entry.auto_complete)) << 16;
        return bits;
    }
};
comptime {
    if (@sizeOf(NativeNode) != 184) @compileError("semantic node ABI mismatch");
}
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
extern fn zua_pages(*anyopaque, [*]const u64, [*]const *anyopaque, u32) i32;
extern fn zua_announce(*anyopaque, [*]const u16, u32, c_int) i32;
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
/// Whether the native host keeps registered recipients and complete lists
/// (`virtual_lists`): UI Automation on Windows, NSAccessibility on macOS.
pub const native_recipients = builtin.os.tag == .windows or builtin.os.tag == .macos;
pub fn recipientsMetadataBytes() usize {
    return if (native_recipients) zua_collections_metadata_size() else 0;
}
pub fn collectionsResourceCount() u32 {
    return if (native_recipients) zua_collections_count() else 0;
}
pub fn geometryResourceCount() u32 {
    return if (native_recipients) zua_geometry_count() else 0;
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
    /// What the live regions of the last publication held.
    live: Live = .{},

    pub const GeometryCandidate = struct { native: *anyopaque, scratch: *NativeGeometry };
    pub const RecipientsCandidate = struct { native: *anyopaque };

    pub fn init(context: *anyopaque, on_action: *const fn (*anyopaque, z.Window, Action) void) Bridge {
        return .{ .context = context, .on_action = on_action };
    }
    pub fn attach(self: *Bridge, window: z.Window) !void {
        virtual_lists.enableMath();
        window.app.assertOwner();
        if (self.native != null) return error.AlreadyAttached;
        const handle = try attachHandle(window);
        const cleanup = try window.app.allocator.create(NativeCleanup);
        errdefer window.app.allocator.destroy(cleanup);
        const native = zua_create(handle, enqueue, self) orelse return if (builtin.os.tag == .linux) error.AccessibilityHostRequired else error.AccessibilityCreationFailed;
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
        const host = try hostFrame(window);
        const origin = host.origin;
        const scale = host.scale;
        const visible = host.visible;
        const enabled = host.enabled;
        const focused = host.focused;
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
            const description_start = used;
            const description_len = try std.unicode.utf8ToUtf16Le(native_text[used..], tree.storage[entry.description_start..][0..entry.description_len]);
            used += description_len;
            const role_description_start = used;
            const role_description_len = try std.unicode.utf8ToUtf16Le(native_text[used..], entry.roleDescription(&tree.storage));
            used += role_description_len;
            const key_shortcuts_start = used;
            const key_shortcuts_len = try std.unicode.utf8ToUtf16Le(native_text[used..], entry.keyShortcuts(&tree.storage));
            used += key_shortcuts_len;
            const value_text_start = used;
            const value_text_len = try std.unicode.utf8ToUtf16Le(native_text[used..], entry.valueText(&tree.storage));
            used += value_text_len;
            native_nodes[index] = .{
                .id = entry.id,
                .parent = entry.parent orelse root_id,
                .role = @backingInt(entry.role),
                .flags = @as(u32, @intFromBool(entry.enabled and enabled)) | (@as(u32, @intFromBool(entry.focused and focused)) << 1) | (@as(u32, @intFromBool(entry.read_only)) << 2) | (@as(u32, @intFromBool(!visible or entry.bounds.width == 0 or entry.bounds.height == 0)) << 3) | (@as(u32, @intFromBool(entry.checked)) << 4) | (@as(u32, @intFromBool(entry.invalid)) << 5) | (@as(u32, @intFromBool(entry.required)) << 6) | (@as(u32, @intFromBool(entry.multiple)) << 7) | (@as(u32, @intFromBool(entry.expanded != null)) << 8) | (@as(u32, @intFromBool(entry.expanded orelse false)) << 9) | (@as(u32, @intFromBool(entry.mixed)) << 10) | (@as(u32, @intFromBool(entry.password)) << 11),
                .name_start = @intCast(name_start),
                .name_len = @intCast(name_len),
                .value_start = @intCast(value_start),
                .value_len = @intCast(value_len),
                .selection_start = @intCast(try std.unicode.calcUtf16LeLen(value[0..entry.selection_start])),
                .selection_end = @intCast(try std.unicode.calcUtf16LeLen(value[0..entry.selection_end])),
                .description_start = @intCast(description_start),
                .description_len = @intCast(description_len),
                .x = @as(f64, entry.bounds.x) * scale + origin.x,
                .y = @as(f64, entry.bounds.y) * scale + origin.y,
                .width = @as(f64, entry.bounds.width) * scale,
                .height = @as(f64, entry.bounds.height) * scale,
                .range_value = entry.range_value,
                .range_minimum = entry.range_minimum,
                .range_maximum = entry.range_maximum,
                .range_small_change = entry.range_small_change,
                .range_large_change = entry.range_large_change,
                .position = entry.position,
                .set_size = entry.set_size,
                .level = entry.level,
                .states = NativeState.pack(entry),
                .role_description_start = @intCast(role_description_start),
                .role_description_len = @intCast(role_description_len),
                .key_shortcuts_start = @intCast(key_shortcuts_start),
                .key_shortcuts_len = @intCast(key_shortcuts_len),
                .value_text_start = @intCast(value_text_start),
                .value_text_len = @intCast(value_text_len),
                .controls = entry.controls,
            };
        }
        if (window.isClosed() or self.native == null) return error.Closed;
        const origin_point: affine.Point = .{ .x = origin.x, .y = origin.y };
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
        var told: [Live.max_told]Live.Told = undefined;
        for (self.live.update(tree, &told)) |item| {
            var units: [Live.max_text]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&units, item.text) catch continue;
            _ = zua_announce(self.native.?, &units, @intCast(len), @intFromBool(item.assertive));
        }
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            // The trees of native content, such as web pages, inside the
            // nodes standing for them.
            var ids: [max_native_pages]u64 = undefined;
            var natives: [max_native_pages]*anyopaque = undefined;
            var count: usize = 0;
            for (tree.entries[0..tree.len]) |entry| if (entry.native) |native| if (count < max_native_pages) {
                ids[count] = entry.id;
                natives[count] = native;
                count += 1;
            };
            if (zua_pages(self.native.?, &ids, &natives, @intCast(count)) < 0) return error.AccessibilityPublishFailed;
        }
    }
    /// Allocate the optional copied authority store before publishing a new
    /// recipient workspace. No native operation borrows the candidate's owner.
    pub fn createRecipientsCandidate(self: *Bridge) !RecipientsCandidate {
        if (!native_recipients) return error.UnsupportedPlatform;
        const window = self.window orelse return error.Closed;
        window.app.assertOwner();
        if (self.native == null) return error.Closed;
        return .{ .native = zua_collections_create() orelse return error.OutOfMemory };
    }
    pub fn destroyRecipientsCandidate(candidate: RecipientsCandidate) void {
        if (native_recipients) zua_collections_free(candidate.native);
    }
    pub fn commitRecipientsCandidate(self: *Bridge, candidate: RecipientsCandidate) !void {
        if (!native_recipients) return error.UnsupportedPlatform;
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
        // macOS elements turn their view's points into screen coordinates
        // as they are asked for; Linux reads the drawing area's origins
        // again.
        if (builtin.os.tag == .linux) {
            const native = self.native orelse return error.Closed;
            self.last_hresult = zua_position_changed(native, 0, 0);
            return;
        }
        if (builtin.os.tag != .windows) return;
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
        if (builtin.os.tag != .windows) return null;
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
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
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
            callback(self.context, window, .{ .key = key, .publication = native.recipient.publication, .kind = @fromBackingInt(@intCast(native.recipient.kind)), .action = .{ .ordinary = action } });
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

/// Where a window's content is for the native host, and how it shows.
const HostFrame = struct { origin: struct { x: f64, y: f64 }, scale: f64, visible: bool, enabled: bool, focused: bool };

fn hostFrame(window: z.Window) !HostFrame {
    switch (builtin.os.tag) {
        .windows => {
            var origin: c.POINT = .{ .x = 0, .y = 0 };
            const hwnd: c.HWND = @ptrCast(window.nativeHandle());
            if (hwnd == null or c.ClientToScreen(hwnd, &origin) == 0) return error.Closed;
            return .{
                .origin = .{ .x = @floatFromInt(origin.x), .y = @floatFromInt(origin.y) },
                // Semantic bounds are in the content's DIPs, zoomed as it draws.
                .scale = @as(f64, @floatFromInt(c.GetDpiForWindow(hwnd))) / 96 * window.zoom(),
                .visible = c.IsWindowVisible(hwnd) != 0 and c.IsIconic(hwnd) == 0,
                .enabled = c.IsWindowEnabled(hwnd) != 0,
                .focused = c.GetFocus() == hwnd,
            };
        },
        // In the content view's points, or the drawing area's logical
        // pixels: the elements place themselves on the screen as they are
        // asked.
        .macos, .linux => {
            const state = try window.state();
            return .{ .origin = .{ .x = 0, .y = 0 }, .scale = window.zoom(), .visible = state.visible and !state.minimized, .enabled = state.enabled, .focused = state.focused };
        },
        else => return error.UnsupportedPlatform,
    }
}

extern fn zlg_accessibility_host_available(*anyopaque) c_int;
/// Whether the window can show assistive technology a tree: on Linux, a
/// window created with `.accessibility_host = .children`.
pub fn hostAvailable(window: z.Window) bool {
    if (builtin.os.tag != .linux) return true;
    const handle = attachHandle(window) catch return false;
    return zlg_accessibility_host_available(handle) != 0;
}

/// What `zua_create` hosts the tree in: the window's GTK record on Linux,
/// whose drawing area must be the accessible child host
/// (`WindowOptions.accessibility_host = .children`), else its native handle.
fn attachHandle(window: z.Window) !*anyopaque {
    if (builtin.os.tag == .linux) {
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (comptime @hasField(@TypeOf(scope.record.native), "native")) return scope.record.native.native orelse error.Closed;
        return error.UnsupportedPlatform;
    }
    return window.nativeHandle() orelse error.Closed;
}

fn geometryRef(bounds: affine.Rect, reference: affine.Ref) NativeGeometryRef {
    return .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height, .space = @backingInt(reference.space), .clip = if (reference.clip) |id| @backingInt(id) else std.math.maxInt(u32) };
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
