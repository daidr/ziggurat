//! Tri-state checkboxes. A checkbox can show a mixed state, drawn with a
//! dash and reported to accessibility clients as the indeterminate toggle
//! state, such as one that heads a group whose boxes are only some checked.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Insets = view.Insets;
const Error = view.Error;

pub const CheckState = enum {
    unchecked,
    checked,
    /// Partly checked.
    mixed,

    /// Checked when every value is set, unchecked when none is (or there
    /// are none), mixed otherwise.
    pub fn of(values: []const bool) CheckState {
        var set: usize = 0;
        for (values) |value| set += @intFromBool(value);
        return derive(set, values.len);
    }
    fn derive(set: usize, total: usize) CheckState {
        if (set == 0) return .unchecked;
        return if (set == total) .checked else .mixed;
    }
};

/// A checkbox bound to `state`. Activation checks an unchecked or mixed
/// box and unchecks a checked one; true when it changed. Only the
/// application sets the mixed state.
pub fn checkboxState(v: *View, state: *CheckState, label: []const u8, style: Style) Error!bool {
    const node = try v.appendNode(.checkbox, style);
    node.text = try v.copyText(label);
    const changed = v.takeEvent(node.id) != null;
    if (changed) state.* = if (state.* == .checked) .unchecked else .checked;
    node.checked = state.* == .checked;
    node.mixed = state.* == .mixed;
    return changed;
}

/// A checkbox without a look bound to `checked`: opens a container, a row
/// by default, that the application fills and draws from the value, as a
/// box of its own and a label; close it with `end`. Activation toggles the
/// value; true when it changed. It keeps the checkbox's focus, keys and
/// semantics, named by `Style.name` or the text inside it, and shows the
/// theme's focus ring.
pub fn checkboxBase(v: *View, checked: *bool, style: Style) Error!bool {
    const node = try v.openNode(.checkbox, style);
    node.plain = true;
    const changed = v.takeEvent(node.id) != null;
    if (changed) checked.* = !checked.*;
    node.checked = checked.*;
    return changed;
}

/// A checkbox without a look bound to `state`, as `checkboxState` is: a
/// press, or Space while it has the focus, checks an unchecked or mixed
/// box and unchecks a checked one, and assistive technology reads it as
/// mixed while it is. Opens a container as `checkboxBase` does; close it
/// with `end`. True when the state changed.
pub fn checkboxStateBase(v: *View, state: *CheckState, style: Style) Error!bool {
    const node = try v.openNode(.checkbox, style);
    node.plain = true;
    const changed = v.takeEvent(node.id) != null;
    if (changed) state.* = if (state.* == .checked) .unchecked else .checked;
    node.checked = state.* == .checked;
    node.mixed = state.* == .mixed;
    return changed;
}

/// How far a group's boxes are indented under its head, in DIP: the
/// width of a box and the gap after it.
pub const group_indent: f32 = 30;

/// One box of a `checkboxGroup`.
pub const GroupItem = struct { value: *bool, label: []const u8, enabled: bool = true };

/// A checkbox labelled `label` over the boxes of `items`, built indented
/// below it. Its state is derived from theirs: checked when all are,
/// unchecked when none are and mixed otherwise. Activating it checks every
/// enabled box unless all of them already are, which unchecks them. True
/// when any value changed. Give it a `Style.key` when the group can move.
pub fn checkboxGroup(v: *View, label: []const u8, items: []const GroupItem, style: Style) Error!bool {
    try v.column(.{ .key = style.key, .enabled = style.enabled, .grow = style.grow, .alignment = .start });
    var set: usize = 0;
    var enabled_set: usize = 0;
    var enabled_total: usize = 0;
    for (items) |entry| {
        set += @intFromBool(entry.value.*);
        if (!entry.enabled) continue;
        enabled_total += 1;
        enabled_set += @intFromBool(entry.value.*);
    }
    var state = CheckState.derive(set, items.len);
    var head = style;
    head.key = null;
    head.grow = 0;
    var changed = false;
    if (try checkboxState(v, &state, label, head)) {
        const value = enabled_set != enabled_total or enabled_total == 0;
        for (items) |entry| if (entry.enabled and entry.value.* != value) {
            entry.value.* = value;
            changed = true;
        };
        // The head shows the state the change produced.
        var after: usize = 0;
        for (items) |entry| after += @intFromBool(entry.value.*);
        const node = v.lastNode();
        const derived = CheckState.derive(after, items.len);
        node.checked = derived == .checked;
        node.mixed = derived == .mixed;
    }
    try v.column(.{ .padding = .{ .left = group_indent }, .alignment = .start });
    for (items, 0..) |entry, index| {
        if (try v.checkbox(entry.value, entry.label, .{ .key = index, .enabled = entry.enabled })) changed = true;
    }
    try v.end();
    try v.end();
    return changed;
}
