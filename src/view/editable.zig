//! Text that becomes a text field to edit in place, such as a name in a
//! list. Shown, it is a label that acts as a button: a press, Enter, Space
//! or F2 begins editing. Editing, the application's text input takes its
//! place and focus: Enter commits, Escape cancels, and focus leaving the
//! input commits. Focus then returns to the label.
//!
//! The application owns the text and the input, usually a `TextField`
//! from `text_field.zig`. On `.begin` it loads the current text into the
//! field; on `.commit` it copies the field's text back, or keeps the old
//! text after `.cancel`.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Error = view.Error;
const Embed = view.Embed;

/// Kept by the application at a stable address with the text it edits.
pub const EditableText = struct {
    editing: bool = false,
    /// The input has held focus since editing began, so focus leaving it
    /// commits.
    focused: bool = false,
    /// The input takes focus in the next pass that builds it.
    focus_input: bool = false,
    /// Node id of the label, where focus returns after editing.
    label: ?u64 = null,
};

/// What happened to an editable text in this pass.
pub const Edit = enum {
    /// Editing began: load the text into the input.
    begin,
    /// Enter or focus leaving the input ended editing: keep the input's text.
    commit,
    /// Escape ended editing: keep the previous text.
    cancel,
};

pub const Options = struct {
    /// Shown as the label's tooltip and announced with it, such as
    /// "Press Enter or F2 to rename".
    hint: []const u8 = "",
    /// Shown in place of an empty value.
    placeholder: []const u8 = "",
};

/// The label showing `value`, or `input` while `state.editing` is set.
/// `input` must report its node's composition through `Embed.status` when
/// it is a text input, so Enter and Escape reach an input method first.
/// Give it a `Style.key` when siblings before it can change. The label is
/// named by `value`; `Style.name` names the input.
pub fn editableText(v: *View, state: *EditableText, value: []const u8, input: Embed, options: Options, style: Style) Error!?Edit {
    var result: ?Edit = null;
    if (!state.editing) {
        const node = try v.appendNode(.editable_text, style);
        node.text = try v.copyText(if (value.len == 0) options.placeholder else value);
        node.tooltip = try v.copyText(options.hint);
        state.label = node.id;
        const begin = actionId(node.id, "begin");
        try v.bindKey(.{ .key = .f2 }, false, begin);
        const pressed = v.takeEvent(node.id) != null;
        const keyed = v.takeEvent(begin) != null;
        if ((pressed or keyed) and node.style.enabled) {
            state.editing = true;
            state.focused = false;
            state.focus_input = true;
            result = .begin;
        }
        return result;
    }
    try v.embed(input, style);
    const node = v.lastNode();
    const commit = actionId(node.id, "commit");
    const cancel = actionId(node.id, "cancel");
    try v.bindKey(.{ .key = .enter }, false, commit);
    try v.bindKey(.{ .key = .escape }, false, cancel);
    if (state.focus_input) {
        state.focus_input = false;
        v.restore = node.id;
    }
    const has_focus = if (v.focus) |id| id == node.id else false;
    if (v.takeEvent(commit) != null) {
        result = .commit;
    } else if (v.takeEvent(cancel) != null) {
        result = .cancel;
    } else if (has_focus) {
        state.focused = true;
    } else if (state.focused) {
        // Focus left the input after it had it.
        result = .commit;
    }
    if (result != null) {
        state.editing = false;
        state.focused = false;
        // Focus goes back to the label unless it moved elsewhere.
        if (has_focus or v.focus == null) v.restore = state.label;
    }
    return result;
}

/// A stable action id for `tag` of the node `id`; never the semantic root.
fn actionId(id: u64, tag: []const u8) u64 {
    const value = std.hash.Wyhash.hash(id, tag);
    return if (value == 0) 1 else value;
}
