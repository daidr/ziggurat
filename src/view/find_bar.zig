//! A find bar: a query input, the position of the current match ("2 of
//! 7"), buttons for the previous and next match, case and whole-word
//! options and a Done button, in a toolbar named "Find". The application
//! owns the query, the search and the matches; the bar reports what the
//! user asked for and shows the matches it is given.
//!
//! Enter in the input moves to the next match and Shift+Enter to the
//! previous one; F3 and Shift+F3 do the same anywhere in the window, and
//! F3 opens a closed bar. Escape within the bar, or Done, closes it.
//! Opening focuses the input; closing returns focus to the control that
//! had it when the bar opened. Changes to the match position are
//! announced to accessibility clients.
const std = @import("std");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Error = view.Error;
const Embed = view.Embed;

/// Kept by the application at a stable address. Set `open` to show the
/// bar, such as from a Ctrl+F shortcut.
pub const FindBar = struct {
    open: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    /// The bar was shown in the last pass.
    shown: bool = false,
    /// The control that had focus when the bar opened.
    opener: ?u64 = null,
    /// The match position last announced.
    announced: ?Matches = null,
};

/// The application's matches for the current query and options.
pub const Matches = struct {
    count: usize = 0,
    /// Index of the current match, below `count`, or null before the
    /// first step.
    current: ?usize = null,

    /// The index a step forward or back reaches, wrapping at the ends; null
    /// without matches.
    pub fn step(self: Matches, forward: bool) ?usize {
        if (self.count == 0) return null;
        const at = self.current orelse return if (forward) 0 else self.count - 1;
        if (forward) return if (at + 1 >= self.count) 0 else at + 1;
        return if (at == 0) self.count - 1 else at - 1;
    }
};

/// The bar's words, for localization.
pub const Texts = struct {
    name: []const u8 = "Find",
    previous: []const u8 = "Previous match",
    next: []const u8 = "Next match",
    match_case: []const u8 = "Match case",
    whole_word: []const u8 = "Whole word",
    done: []const u8 = "Done",
    /// Between the current match's number and the count, as "2 of 7".
    of: []const u8 = "of",
    /// Shown when a query has no matches.
    no_results: []const u8 = "No results",
};

/// What the user asked of the bar in this pass.
pub const FindEvent = enum {
    /// The bar opened; its input has focus.
    opened,
    next,
    previous,
    /// `case_sensitive` or `whole_word` changed: search again.
    options,
    /// The bar closed.
    closed,
};

/// The find bar bound to `bar`, shown while `bar.open` is set, with
/// `input` as its query input, usually a `TextField` that reports its
/// emptiness through `Embed.status`. `matches` is the search result for
/// the current query. Build it where the bar goes, such as above the
/// content; give it a `Style.key` when siblings before it can change.
pub fn findBar(v: *View, bar: *FindBar, input: Embed, matches: Matches, texts: Texts, style: Style) Error!?FindEvent {
    var event: ?FindEvent = null;
    const root_id = v.buffers.nodes[0].id;
    const next_id = actionId(root_id, style.key, "next");
    const previous_id = actionId(root_id, style.key, "previous");
    const close_id = actionId(root_id, style.key, "close");
    // F3 works anywhere in the window, and opens a closed bar.
    try v.bindKey(.{ .key = .f3, .allow_repeat = true }, true, next_id);
    try v.bindKey(.{ .key = .f3, .modifiers = .{ .shift = true }, .allow_repeat = true }, true, previous_id);
    const stepped: ?FindEvent = if (v.takeEvent(next_id) != null) .next else if (v.takeEvent(previous_id) != null) .previous else null;
    if (stepped) |value| {
        if (!bar.open) {
            bar.open = true;
        } else event = value;
    }
    if (v.takeEvent(close_id) != null) bar.open = false;
    if (!bar.open) {
        if (bar.shown) {
            bar.shown = false;
            bar.announced = null;
            v.restore = bar.opener;
            bar.opener = null;
            event = .closed;
        }
        return event;
    }
    const opening = !bar.shown;
    if (opening) {
        bar.shown = true;
        bar.opener = v.focus;
        event = .opened;
    }
    var value = style;
    if (value.name.len == 0) value.name = texts.name;
    if (value.gap == 0) value.gap = 8;
    value.alignment = .center;
    try v.toolbar(value);
    var field = Style{ .grow = 1, .name = texts.name };
    field.key = 1;
    try v.embed(input, field);
    const field_id = v.lastNode().id;
    if (opening) v.restore = field_id;
    try v.bindKey(.{ .key = .enter, .allow_repeat = true }, false, next_id);
    try v.bindKey(.{ .key = .enter, .modifiers = .{ .shift = true }, .allow_repeat = true }, false, previous_id);
    try v.bindKey(.{ .key = .escape }, false, close_id);
    const empty = if (input.status) |status| status(input.context).empty else false;
    if (empty) {
        try v.text("", .{ .key = 2 });
    } else if (matches.count == 0) {
        try v.text(texts.no_results, .{ .key = 2 });
    } else if (matches.current) |current| {
        try v.textf("{d} {s} {d}", .{ current + 1, texts.of, matches.count }, .{ .key = 2 });
    } else {
        try v.textf("{d}", .{matches.count}, .{ .key = 2 });
    }
    // The position is announced as it changes.
    const status_text = v.lastNode().text;
    if (!empty and !std.meta.eql(bar.announced, @as(?Matches, matches))) {
        bar.announced = matches;
        if (status_text.len > 0) v.announce(status_text);
    }
    if (try v.navButton(.up, .{ .key = 3, .name = texts.previous, .enabled = matches.count > 0 })) event = .previous;
    try v.bindKey(.{ .key = .escape }, false, close_id);
    if (try v.navButton(.down, .{ .key = 4, .name = texts.next, .enabled = matches.count > 0 })) event = .next;
    try v.bindKey(.{ .key = .escape }, false, close_id);
    if (try v.checkbox(&bar.case_sensitive, texts.match_case, .{ .key = 5 })) event = .options;
    try v.bindKey(.{ .key = .escape }, false, close_id);
    if (try v.checkbox(&bar.whole_word, texts.whole_word, .{ .key = 6 })) event = .options;
    try v.bindKey(.{ .key = .escape }, false, close_id);
    if (try v.button(texts.done, .{ .key = 7 })) {
        bar.open = false;
        event = .closed;
    }
    try v.bindKey(.{ .key = .escape }, false, close_id);
    try v.end();
    if (!bar.open and bar.shown) {
        // Done closed it: the next pass builds nothing, so hand focus back now.
        bar.shown = false;
        bar.announced = null;
        v.restore = bar.opener;
        bar.opener = null;
    }
    return event;
}

/// A stable action id for `tag` of the bar keyed `key`; never the
/// semantic root.
fn actionId(seed: u64, key: ?u64, tag: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update("find");
    if (key) |value| hasher.update(std.mem.asBytes(&value));
    hasher.update(tag);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}
