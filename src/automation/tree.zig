//! The elements of a window of views as assistive technology reads them:
//! the nodes of the Host's last frame that have a role, in tree order, a
//! parent before its children. Rows and columns that only lay others out,
//! and spacers, have no element.
const std = @import("std");
const view = @import("ziggurat_view");
const protocol = @import("protocol.zig");

const Node = view.Node;
const Kind = view.Kind;

/// The role of a node's element, or null when it has none.
pub fn role(node: *const Node) ?[]const u8 {
    return switch (node.kind) {
        .button, .nav_button, .combo_toggle => "button",
        .disclosure => "disclosure",
        .link => "link",
        .checkbox => "checkBox",
        .radio, .segment => "radio",
        .radio_group, .segmented => "radioGroup",
        .toggle_switch => "switch",
        .slider, .rating => "slider",
        .stepper => "stepper",
        .progress, .loading => "progress",
        .meter => "meter",
        .tab => "tab",
        .tab_list => "tabList",
        .list_box => "list",
        .list_item => "listItem",
        .tree => "tree",
        .tree_row => "treeItem",
        .table => "table",
        .table_row, .table_header => "row",
        .column_header => "columnHeader",
        .dialog => if (node.modal.role == .alert) "alertDialog" else "dialog",
        .popover => "dialog",
        .popup => "popup",
        .toolbar => "toolbar",
        .text, .note, .badge => "text",
        .image, .svg, .icon, .avatar => "image",
        .combo_box, .combo_field => "comboBox",
        .popup_button => "popUpButton",
        .embed, .editable_text => "textField",
        .scroll => "scroll",
        .toast, .toasts => "status",
        .split => "splitter",
        .spacer => null,
        else => if (node.style.name.len != 0) "group" else null,
    };
}

fn focusable(node: *const Node) bool {
    return switch (node.kind) {
        .button, .link, .nav_button, .combo_box, .popup_button, .checkbox, .radio, .segment, .tab, .list_item, .disclosure, .toggle_switch, .slider, .stepper, .rating, .tree_row, .column_header, .token, .combo_toggle, .editable_text => true,
        .embed => if (node.embed) |embed| embed.focusable or embed.status != null else false,
        else => false,
    };
}
fn pressable(node: *const Node) bool {
    return switch (node.kind) {
        .button, .link, .nav_button, .combo_box, .popup_button, .checkbox, .toggle_switch, .radio, .segment, .tab, .list_item, .disclosure, .column_header, .token, .combo_toggle, .editable_text, .tree_row, .table_row => true,
        else => false,
    };
}
fn textual(node: *const Node) bool {
    return node.kind == .editable_text or (node.kind == .embed and if (node.embed) |embed| embed.status != null else false);
}
fn ranged(kind: Kind) bool {
    return switch (kind) {
        .slider, .stepper, .rating, .meter, .progress => true,
        else => false,
    };
}

/// True when a scroll container holds the node, so scrollIntoView can
/// move it.
fn scrolled(nodes: []const Node, node: *const Node) bool {
    var parent = node.parent;
    while (parent < nodes.len) : (parent = nodes[parent].parent) {
        if (nodes[parent].scroll != null) return true;
    }
    return false;
}

/// True when the node is in a popup, popover or dialog that is closed.
fn hidden(nodes: []const Node, node: *const Node) bool {
    if (node.hidden()) return true;
    var parent = node.parent;
    while (parent < nodes.len) : (parent = nodes[parent].parent) {
        if (nodes[parent].hidden()) return true;
    }
    return false;
}

/// The elements of `host`'s last frame, allocated in `arena`.
pub fn build(arena: std.mem.Allocator, window: u64, host: *const view.Host) error{OutOfMemory}!protocol.Tree {
    const v = &host.view;
    const nodes = v.nodes();
    // Each node's index in the output, for its children's parent.
    const index = try arena.alloc(u32, nodes.len);
    var out: std.ArrayList(protocol.Node) = try .initCapacity(arena, nodes.len);
    var focus: ?protocol.Digits = null;
    const focused = host.context.input_state.focused;
    for (nodes, 0..) |*node, at| {
        index[at] = std.math.maxInt(u32);
        const name = role(node) orelse continue;
        if (hidden(nodes, node)) continue;
        var parent: ?protocol.Digits = null;
        var up = node.parent;
        while (up < nodes.len) : (up = nodes[up].parent) {
            if (index[up] != std.math.maxInt(u32)) {
                parent = out.items[index[up]].id;
                break;
            }
        }
        const shown = v.visible(node);
        const bounds = shown orelse node.bounds;
        var result: protocol.Node = .{
            .id = .{ .value = node.id },
            .parent = parent,
            .role = name,
            .key = if (node.style.key) |key| .{ .value = key } else null,
            .bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height },
        };
        const label = if (node.style.name.len != 0) node.style.name else node.text;
        if (textual(node)) {
            if (node.style.name.len != 0) result.label = try arena.dupe(u8, node.style.name);
            if (node.kind == .editable_text and node.text.len != 0) result.value = try arena.dupe(u8, node.text);
        } else if (label.len != 0) result.label = try arena.dupe(u8, label);
        // The strings of the view's nodes last until its next pass, so the
        // answer keeps copies.
        if (node.tooltip.len != 0) result.description = try arena.dupe(u8, node.tooltip);
        if (node.note.len != 0 and node.kind != .note) result.description = try arena.dupe(u8, node.note);

        var states: std.ArrayList([]const u8) = .empty;
        if (focusable(node) and node.style.enabled) try states.append(arena, "focusable");
        if (!node.style.enabled or v.inert(node)) try states.append(arena, "disabled");
        switch (node.kind) {
            .checkbox, .toggle_switch, .radio => {
                if (node.checked) try states.append(arena, "checked");
                if (node.mixed) try states.append(arena, "mixed");
            },
            .segment, .tab, .list_item => if (node.checked) try states.append(arena, "selected"),
            .tree_row, .table_row => if (node.selection) |selection| if (selection.contains(node.item)) try states.append(arena, "selected"),
            else => {},
        }
        if (node.kind == .tree_row) if (node.expanded) |open| {
            try states.append(arena, "expandable");
            if (open) try states.append(arena, "expanded");
        };
        if (node.kind == .disclosure) {
            try states.append(arena, "expandable");
            if (node.checked) try states.append(arena, "expanded");
        }
        if (node.invalid) try states.append(arena, "invalid");
        if (node.kind == .search) try states.append(arena, "search");
        if (node.kind == .segment) try states.append(arena, "segment");
        if (node.kind == .column_header) if (node.sort) |direction| try states.append(arena, if (direction == .ascending) "sortAscending" else "sortDescending");
        if (node.kind == .split and node.axis == .column) try states.append(arena, "vertical");
        if (shown == null) try states.append(arena, "offscreen");
        if (states.items.len != 0) result.states = states.items;

        var actions: std.ArrayList([]const u8) = .empty;
        if (node.style.enabled) {
            if (pressable(node)) try actions.append(arena, "press");
            if (focusable(node)) try actions.append(arena, "focus");
            switch (node.kind) {
                .slider, .stepper, .rating, .split => {
                    try actions.append(arena, "increment");
                    try actions.append(arena, "decrement");
                },
                else => {},
            }
            if (textual(node) or node.kind == .slider or node.kind == .stepper or node.kind == .rating) try actions.append(arena, "setValue");
            if (textual(node) and node.kind == .embed) try actions.append(arena, "selectText");
            if (scrolled(nodes, node)) try actions.append(arena, "scrollIntoView");
            if ((node.kind == .tree_row and node.expanded != null) or node.kind == .disclosure) try actions.append(arena, "expand");
        }
        if (actions.items.len != 0) result.actions = actions.items;

        if (ranged(node.kind)) {
            if (node.kind == .progress or node.kind == .loading) {
                result.min = 0;
                result.max = 1;
                result.now = node.fraction;
            } else {
                result.min = node.range.minimum;
                result.max = node.range.maximum;
                result.now = node.value;
                if (node.range.step != 0) result.step = node.range.step;
            }
        }
        if (node.kind == .tree_row) result.level = @as(u32, node.level) + 1;
        if (focused == node.id) focus = result.id;
        index[at] = @intCast(out.items.len);
        out.appendAssumeCapacity(result);
    }
    var tree: protocol.Tree = .{ .window = window, .focus = focus, .nodes = out.items };
    if (v.announcement_len != 0) {
        const list = try arena.alloc([]const u8, 1);
        list[0] = try arena.dupe(u8, v.announcement[0..v.announcement_len]);
        tree.announcements = list;
    }
    return tree;
}
