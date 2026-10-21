//! A navigation sidebar: sections under headings, each holding items with
//! an optional icon and a count or status badge. It is a tree to
//! accessibility clients: headings are expandable tree items and items
//! are selectable ones. The application owns the selection, a single
//! `Selection` of item ids, and decides what each item shows.
//!
//! Items share one Tab stop on the selection's cursor. Up/Down and
//! Home/End move between headings and items, selecting the items they
//! reach; a heading takes the cursor without being selected. Left
//! collapses a section or moves from an item to its heading, Right
//! expands one, and Space or Enter on a heading toggles it. A letter or
//! digit moves to the next item or heading whose label starts with it. A
//! press on a heading expands or collapses it.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Error = view.Error;
const Selection = view.Selection;
const ImageView = view.ImageView;

/// Starts a sidebar bound to `selection`, usually single, which holds the
/// application's item ids. Build its sections with `sidebarSection` and
/// its items with `sidebarItem`; close it with `end`. Named by
/// `Style.name`; give it a `Style.background` or `Style.material` to set
/// it apart from the content. Put it in a `scroll` container for long lists.
pub fn sidebar(v: *View, selection: *Selection, style: Style) Error!void {
    try v.tree(selection, style);
    const node = v.lastNode();
    // On a tree, the flag lets letters move the cursor.
    node.heading = true;
}

/// A section heading for the application's id `id`, unique in the sidebar
/// among headings and items. `expanded` is null for a section that is
/// always open. Build its items after it when this returns true, then
/// close the section with `end` either way.
pub fn sidebarSection(v: *View, id: u64, title: []const u8, expanded: ?*bool, style: Style) Error!bool {
    _ = try v.treeItem(id, expanded, title, style);
    v.lastNode().heading = true;
    return if (expanded) |flag| flag.* else true;
}

pub const ItemOptions = struct {
    /// Drawn after the indent, before the label.
    icon: ?ImageView = null,
    /// A count or short status drawn at the end of the row, such as unread
    /// messages, and announced with the item.
    badge: []const u8 = "",
};

/// An item for the application's id `id`, unique in the sidebar. True once
/// for the pass where a press, a navigation key or Enter chose it.
pub fn sidebarItem(v: *View, id: u64, label: []const u8, options: ItemOptions, style: Style) Error!bool {
    if (v.depth == 0) return error.UnbalancedContainer;
    const parent = &v.buffers.nodes[v.stack[v.depth - 1]];
    const tree = if (parent.kind == .tree) parent else if (parent.kind == .tree_item and parent.collection < v.len) &v.buffers.nodes[parent.collection] else return error.NotContainer;
    const selection = tree.selection orelse return error.NotContainer;
    // A press or key selects at the sidebar's start; an accessibility
    // client's invoke selects in the item itself.
    const by_input = if (v.item_event) |event| event.collection == tree.id and event.item == id and event.op != .cursor and event.op != .expand and event.op != .collapse else false;
    const was = selection.contains(id);
    const activated = try v.treeItem(id, null, label, style);
    const row = v.lastNode();
    row.image = options.icon;
    row.badge = try v.copyText(options.badge);
    try v.end();
    return activated or (row.checked and (by_input or !was));
}
