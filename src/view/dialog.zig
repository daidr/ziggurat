//! Dialogs drawn inside the window: a modal dialog, a sheet attached to
//! the window's top edge, and an alert dialog with response buttons. A
//! shown dialog dims the rest of the window with a scrim; nothing behind
//! it takes presses, keys or focus, so Tab and Shift+Tab cycle among its
//! own controls. Focus moves into it as it opens and returns to the
//! control that had it when it closes. Accessibility clients see a dialog
//! or alert dialog named by `Style.name` and described by
//! `DialogOptions.description`. One dialog is shown at a time.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Insets = view.Insets;
const Error = view.Error;
const DialogOptions = view.DialogOptions;
const DialogState = view.DialogState;

/// Starts a dialog shown while `is_open` is set. Build its content only
/// when this returns `.open`, and close it with `end` either way. When it
/// opens, focus moves to its first control, or to the one that called
/// `View.initialFocus`. Escape, when `options.dismiss_on_escape` is set,
/// and a press on the scrim, when `options.dismiss_on_scrim` is set and
/// the role is not `.alert`, clear `is_open`; the pass that clears it
/// returns `.dismissed`. However it closes, focus returns to the control
/// that had it when the dialog opened. A dialog cannot open inside a
/// popup, popover or another dialog. Padding is 16 DIP and the gap 12 DIP
/// unless set; the width is at least `view.dialog_min_width` while the
/// window has room.
pub fn dialog(v: *View, is_open: *bool, options: DialogOptions, style: Style) Error!DialogState {
    var value = style;
    if (value.padding.top == 0 and value.padding.bottom == 0 and value.padding.left == 0 and value.padding.right == 0) value.padding = Insets.all(16);
    if (value.gap == 0) value.gap = 12;
    const node = try v.openNode(.dialog, value);
    node.modal = options;
    node.modal.description = try v.copyText(options.description);
    if (options.role == .alert) node.modal.dismiss_on_scrim = false;
    const id = node.id;
    var dismissed = false;
    if (v.dialog_dismiss) |target| if (target == id) {
        v.dialog_dismiss = null;
        dismissed = is_open.*;
        is_open.* = false;
    };
    node.checked = is_open.*;
    const shown = if (v.dialog_shown) |current| current == id else false;
    if (is_open.* and !shown) {
        // Another dialog still shown keeps its place; one at a time.
        if (v.dialog_shown != null) return error.Busy;
        v.dialog_shown = id;
        v.dialog_opener = v.focus;
        v.dialog_opened = id;
    } else if (!is_open.* and shown) {
        v.dialog_shown = null;
        v.restore = v.dialog_opener;
        v.dialog_opener = null;
    }
    return if (is_open.*) .open else if (dismissed) .dismissed else .closed;
}

/// A dialog attached to the top edge of the window, as `dialog` with
/// `options.position` set to `.top`.
pub fn sheet(v: *View, is_open: *bool, options: DialogOptions, style: Style) Error!DialogState {
    var value = options;
    value.position = .top;
    return dialog(v, is_open, value, style);
}

/// What an alert dialog shows; the strings are copied.
pub const Alert = struct {
    title: []const u8,
    message: []const u8 = "",
    /// Response buttons in order, at least one.
    buttons: []const []const u8,
    /// The button that takes focus as the alert opens.
    default: usize = 0,
    /// The response Escape gives, or null when Escape does nothing.
    cancel: ?usize = null,
};

/// An alert dialog shown while `is_open` is set: its title, message and a
/// row of response buttons. A press on a button, or Escape for
/// `alert.cancel`, clears `is_open` and returns that button's index; null
/// otherwise. A press on the scrim never dismisses it. Build nothing
/// after it for the alert; it ends itself.
pub fn alertDialog(v: *View, is_open: *bool, alert: Alert, style: Style) Error!?usize {
    if (alert.buttons.len == 0 or alert.default >= alert.buttons.len) return error.InvalidValue;
    if (alert.cancel) |index| if (index >= alert.buttons.len) return error.InvalidValue;
    var value = style;
    if (value.name.len == 0) value.name = alert.title;
    const state = try dialog(v, is_open, .{ .role = .alert, .dismiss_on_escape = alert.cancel != null, .description = alert.message }, value);
    var response: ?usize = null;
    if (state == .dismissed) response = alert.cancel;
    if (state == .open) {
        try v.text(alert.title, .{ .font = .heading3 });
        if (alert.message.len > 0) try v.text(alert.message, .{});
        try v.row(.{ .gap = 8, .justify = .end });
        for (alert.buttons, 0..) |label, index| {
            if (try v.button(label, .{ .key = index })) {
                response = index;
                is_open.* = false;
            }
            if (index == alert.default) v.initialFocus();
        }
        try v.end();
    }
    try v.end();
    return response;
}
