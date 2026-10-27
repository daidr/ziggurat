//! Right-to-left layout. A view lays out in the direction of its `Options`
//! (usually from the application's locale), and any container can take a
//! direction of its own with `Style.direction`; what is built inside it
//! inherits that direction. Right to left, every container except a split
//! mirrors its children across its own bounds after the usual layout: a
//! row starts at the right, a column's start alignment is the right edge,
//! left and right padding trade places, a grid's columns run from the
//! right, and token fields wrap from the right. The coordinate system is
//! not mirrored: x still grows to the right in bounds, pointer positions
//! and painting.
//!
//! Text starts at the right of its box, popups line up with the right edge
//! of their anchor, popovers swap start and end, the scroll indicator moves
//! to the left edge, and back/forward navigation buttons and directional
//! icons point the other way. Left and Right follow what is on screen in
//! tab lists, segmented controls, trees and token fields; spatial arrow
//! navigation already follows the mirrored bounds.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("root.zig");

const View = view.View;
const Node = view.Node;
const Rect = view.Rect;
const KeyRoute = view.KeyRoute;

pub const Direction = enum {
    ltr,
    rtl,

    /// The direction of a locale or localizer's `direction()`, or of any
    /// enum with an `rtl` tag, such as `ziggurat_i18n`'s:
    /// `view.Direction.of(locale.direction())`.
    pub fn of(writing: anytype) Direction {
        return if (writing == .rtl) .rtl else .ltr;
    }
};

/// Mirror `rects` across the horizontal extent of `bounds`.
pub fn mirror(rects: []Rect, bounds: Rect) void {
    const axis = 2 * bounds.x + bounds.width;
    for (rects) |*rect| rect.x = axis - rect.x - rect.width;
}

/// `input` with Left and Right exchanged when the focused control lays
/// out right to left, so the arrows move the way they point.
pub fn visualInput(v: *const View, input: z.KeyInput) z.KeyInput {
    if (input.key != .left and input.key != .right) return input;
    const node = focusedNode(v) orelse return input;
    if (!node.rtl) return input;
    var swapped = input;
    swapped.key = if (input.key == .left) .right else .left;
    return swapped;
}

/// Left and Right among the tabs or segments of a right-to-left row move
/// to the neighbour on that side and select it, as the arrows do in order
/// left to right.
pub fn routeGroupArrow(v: *View, input: z.KeyInput) ?KeyRoute {
    const mods = input.modifiers;
    if (mods.control or mods.alt or mods.super or mods.shift) return null;
    if (input.key != .left and input.key != .right) return null;
    const all = v.nodes();
    const node = focusedNode(v) orelse return null;
    const group = node.radio_group orelse return null;
    if (node.parent >= all.len) return null;
    const container = &all[node.parent];
    if (!container.rtl or (container.kind != .tab_list and container.kind != .segmented)) return null;
    // Visually left is the next item in build order, right the previous.
    const forward = input.key == .left;
    var members: [view.max_popup_items]u32 = undefined;
    var count: usize = 0;
    var current: usize = 0;
    var child = container.first_child;
    while (child < all.len) : (child = all[child].next_sibling) {
        const member = &all[child];
        if (member.radio_group == null or member.radio_group.? != group) continue;
        if (count == members.len) break;
        if (member.id == node.id) current = count;
        members[count] = child;
        count += 1;
    }
    if (count < 2) return .handled;
    var step: usize = 1;
    while (step < count) : (step += 1) {
        const at = if (forward) (current + step) % count else (current + count - step) % count;
        const target = &all[members[at]];
        if (!target.style.enabled or v.visible(target) == null) continue;
        v.arrow_focus = target.id;
        return .{ .deliver = .{ .action = target.id } };
    }
    return .handled;
}

fn focusedNode(v: *const View) ?*const Node {
    const focused = v.focus orelse return null;
    for (v.nodes()) |*node| if (node.id == focused) return node;
    return null;
}

test "mirror keeps widths and reverses order" {
    var rects = [_]Rect{ .{ .x = 10, .y = 0, .width = 20, .height = 5 }, .{ .x = 30, .y = 0, .width = 50, .height = 5 } };
    mirror(&rects, .{ .x = 10, .y = 0, .width = 100, .height = 5 });
    try std.testing.expectEqual(@as(f32, 90), rects[0].x);
    try std.testing.expectEqual(@as(f32, 40), rects[1].x);
    try std.testing.expectEqual(Direction.rtl, Direction.of(@as(enum { ltr, rtl }, .rtl)));
}
