//! A Document is what a rich text editor edits: a Text, its selection with
//! the attributes typing gets there, and the history of undo, which the
//! application keeps from frame to frame. A toolbar, a menu or a timer
//! formats and edits it while an editor shows it, and the editor follows at
//! its next frame. All of it runs on one thread, the UI's.
//!
//! Commands act on the selection as an editor's shortcuts do: on a range
//! they change its runs or paragraphs, as one step of undo; on a caret,
//! character formats change only the typing attributes, which the next
//! typed text gets and the next move of the caret forgets.
const std = @import("std");
const zio = @import("ziggurat_io");
const tx = @import("text.zig");

const Allocator = std.mem.Allocator;
const Text = tx.Text;
const Para = tx.Para;
const Attributes = tx.Attributes;
const ParagraphStyle = tx.ParagraphStyle;
const ListKind = tx.ListKind;

/// Steps of undo a document keeps.
pub const max_undo = 200;
/// Typing within this many milliseconds of the last joins its step.
pub const coalesce_ms = 1000;

pub const Selection = struct {
    /// Where the selection started.
    anchor: u32,
    /// Where it ends and the caret is; equal to anchor for a caret.
    caret: u32,

    pub fn start(self: Selection) u32 {
        return @min(self.anchor, self.caret);
    }
    pub fn end(self: Selection) u32 {
        return @max(self.anchor, self.caret);
    }
    pub fn empty(self: Selection) bool {
        return self.anchor == self.caret;
    }
};

/// How an edit joins the steps of undo.
pub const StepMode = enum {
    /// A step of its own.
    new,
    /// Typing: joins the last step while typing goes on.
    typing,
    /// Part of the step made last, as a composition's commit.
    same,
};

/// A step of undo: the paragraphs it changed, in the text from `first` on,
/// `count` of them now, and those the other side of it held.
const Step = struct {
    first: u32 = std.math.maxInt(u32),
    count: u32 = 0,
    held: std.ArrayList(Para) = .empty,
    selection_before: Selection,
    selection_after: Selection,
    changed: bool = false,

    fn started(self: *const Step) bool {
        return self.first != std.math.maxInt(u32);
    }
    fn deinit(self: *Step, allocator: Allocator) void {
        for (self.held.items) |*p| p.deinit(allocator);
        self.held.deinit(allocator);
    }
};

/// Whether a format holds for a selection: all of it, none, or some, as a
/// toolbar's button shows it.
pub const FormatState = enum { off, on, mixed };

/// The formats of a document's selection, as a toolbar and a Format menu
/// show them: of the runes selected, or of the typing attributes at a
/// caret. Strings borrow the document's text until it changes.
pub const Formatting = struct {
    /// Those of the first rune selected, or the typing attributes.
    attributes: Attributes,
    bold: FormatState = .off,
    italic: FormatState = .off,
    underline: FormatState = .off,
    strikethrough: FormatState = .off,
    code: FormatState = .off,
    /// The link all of the selection is in; "" when none is.
    link: []const u8 = "",
    /// The style of the first paragraph selected, and whether others
    /// differ from it.
    paragraph: ParagraphStyle = .{},
    paragraphs_mixed: bool = false,
};

/// Changes attributes with a function, for formats chosen at run time.
pub const AttributeChanger = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, *Attributes) void,
    pub fn change(self: AttributeChanger, a: *Attributes) void {
        self.call(self.context, a);
    }
};

/// Changes paragraph styles with a function.
pub const StyleChanger = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, *ParagraphStyle) void,
    pub fn change(self: StyleChanger, s: *ParagraphStyle) void {
        self.call(self.context, s);
    }
};

/// Where p goes as the runes from start to start+removed become
/// `inserted` others: a caret or the start of a range where text is
/// inserted goes after it, the end of a range does not grow, and what was
/// replaced collapses to its edges.
pub fn mapPosition(p: u32, start: u32, removed: u32, inserted: u32, upper: bool) u32 {
    const end = start + removed;
    if (p < start) return p;
    if (removed == 0 and p == start) return if (upper) p else p + inserted;
    if (p < end) return if (upper) start + inserted else start;
    return p + inserted - removed;
}

/// The attributes typing gets in place of the runes from start to end of
/// t: those of the first selected, else of the rune before (after it at
/// the start of a paragraph), without a link, code or tag at their edges.
pub fn typingAttributesOf(t: *const Text, start: u32, end: u32) Attributes {
    if (start < end) {
        var a = t.attributesAt(start);
        a.attachment = null;
        return a;
    }
    const r = t.paragraphRange(start);
    if (start == r.start) return t.attributesAt(start).extending();
    const before = t.attributesAt(start - 1);
    // The newline: a link or code ends with the line.
    const after: Attributes = if (start == r.end) .{} else t.attributesAt(start);
    var a = before.extending();
    // What does not extend holds inside: between two runes of a link.
    if (std.mem.eql(u8, before.link, after.link)) a.link = before.link;
    if (before.code and after.code) a.code = true;
    if (std.mem.eql(u8, before.tag, after.tag)) a.tag = before.tag;
    return a;
}

pub const Document = struct {
    allocator: Allocator,
    text: Text,
    anchor: u32 = 0,
    caret: u32 = 0,
    /// Set by a command at the caret, interned in the text; null derives
    /// them from the text there.
    typing: ?Attributes = null,
    /// Counts the changes of the text.
    version: u64 = 1,
    /// Counts the changes of the selection made by the document's methods,
    /// which an editor takes.
    selection_version: u64 = 1,
    undo_steps: std.ArrayList(Step) = .empty,
    redo_steps: std.ArrayList(Step) = .empty,
    last_edit: i64 = 0,
    /// Typing may join the last step.
    coalesce: bool = false,
    /// Milliseconds now, for the coalescing of typing.
    clock: *const fn () i64 = zio.milliTimestamp,

    /// A document of `text`, which it takes, its caret at the end.
    pub fn init(allocator: Allocator, text: Text) Document {
        var d: Document = .{ .allocator = allocator, .text = text };
        const n = d.text.len();
        d.anchor = n;
        d.caret = n;
        return d;
    }

    /// A document of plain text.
    pub fn initString(allocator: Allocator, s: []const u8) !Document {
        return init(allocator, try Text.initString(allocator, s));
    }

    pub fn deinit(self: *Document) void {
        for (self.undo_steps.items) |*s| s.deinit(self.allocator);
        self.undo_steps.deinit(self.allocator);
        for (self.redo_steps.items) |*s| s.deinit(self.allocator);
        self.redo_steps.deinit(self.allocator);
        self.text.deinit();
        self.* = undefined;
    }

    /// Replaces the text, as when the application opens another note: it is
    /// not a step of undo, and clears the history. The selection goes to
    /// the end. The document takes `text`.
    pub fn setText(self: *Document, text: Text) void {
        self.text.deinit();
        self.text = text;
        self.clearHistory();
        self.coalesce = false;
        self.version += 1;
        const n = self.text.len();
        self.setSelectionRaw(n, n);
    }

    fn clearHistory(self: *Document) void {
        for (self.undo_steps.items) |*s| s.deinit(self.allocator);
        self.undo_steps.clearRetainingCapacity();
        for (self.redo_steps.items) |*s| s.deinit(self.allocator);
        self.redo_steps.clearRetainingCapacity();
    }

    pub fn selection(self: *const Document) Selection {
        return .{ .anchor = self.anchor, .caret = self.caret };
    }

    /// Selects the runes between anchor and caret, or puts the caret there
    /// when they are equal; an editor scrolls it into view.
    pub fn setSelection(self: *Document, anchor: u32, caret: u32) void {
        self.setSelectionRaw(anchor, caret);
    }

    fn setSelectionRaw(self: *Document, anchor: u32, caret: u32) void {
        const n = self.text.len();
        self.anchor = @min(anchor, n);
        self.caret = @min(caret, n);
        self.typing = null;
        self.coalesce = false;
        self.selection_version += 1;
    }

    /// Moves the selection as an editor does, without telling editors.
    pub fn moveSelection(self: *Document, anchor: u32, caret: u32) void {
        const n = self.text.len();
        const a = @min(anchor, n);
        const c = @min(caret, n);
        if (a == self.anchor and c == self.caret) return;
        self.anchor = a;
        self.caret = c;
        self.typing = null;
        self.coalesce = false;
    }

    fn span(self: *const Document) struct { start: u32, end: u32 } {
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }

    /// The attributes typing gets at the caret: those a command set there,
    /// else those of the text around it.
    pub fn typingAttributes(self: *const Document) Attributes {
        if (self.typing) |a| return a;
        const s = self.span();
        return typingAttributesOf(&self.text, s.start, s.end);
    }

    /// Sets the attributes the next typed text gets, until the caret moves.
    pub fn setTypingAttributes(self: *Document, a: Attributes) !void {
        var value = a;
        value.attachment = null;
        self.typing = try self.text.intern(value);
    }

    // ---- Steps of undo ---------------------------------------------------

    /// Runs `func(context, *Edit)` as one step of undo, which undoing
    /// takes back whole with the selection before it.
    pub fn edit(self: *Document, context: anytype, comptime func: anytype) !void {
        return self.editStep(.new, context, func);
    }

    /// Runs an edit joined to the steps as `mode` says.
    pub fn editStep(self: *Document, mode: StepMode, context: anytype, comptime func: anytype) !void {
        const fresh = try self.beginStep(mode);
        var e: Edit = .{ .doc = self, .step_index = self.undo_steps.items.len - 1 };
        func(context, &e) catch |err| {
            self.endStep(fresh, mode);
            return err;
        };
        self.endStep(fresh, mode);
    }

    /// Opens a step; true when it is new.
    fn beginStep(self: *Document, mode: StepMode) !bool {
        const now = self.clock();
        const join = switch (mode) {
            .new => false,
            .typing => self.coalesce and now - self.last_edit < coalesce_ms,
            .same => true,
        };
        if (join and self.undo_steps.items.len > 0) return false;
        try self.undo_steps.append(self.allocator, .{ .selection_before = self.selection(), .selection_after = self.selection() });
        return true;
    }

    fn endStep(self: *Document, fresh: bool, mode: StepMode) void {
        const step = &self.undo_steps.items[self.undo_steps.items.len - 1];
        if (!step.changed) {
            if (fresh) {
                step.deinit(self.allocator);
                _ = self.undo_steps.pop();
            }
            return;
        }
        step.selection_after = self.selection();
        if (self.undo_steps.items.len > max_undo) {
            self.undo_steps.items[0].deinit(self.allocator);
            _ = self.undo_steps.orderedRemove(0);
        }
        for (self.redo_steps.items) |*s| s.deinit(self.allocator);
        self.redo_steps.clearRetainingCapacity();
        self.coalesce = mode == .typing or (mode == .same and self.coalesce);
        self.last_edit = self.clock();
    }

    /// Makes the step cover the paragraphs from `first` to `last` of the
    /// text as it is, keeping copies of those it did not cover yet.
    fn cover(self: *Document, step: *Step, first: u32, last: u32) !void {
        const t = &self.text;
        if (!step.started()) {
            try step.held.ensureTotalCapacity(self.allocator, last - first + 1);
            var p = first;
            while (p <= last) : (p += 1) step.held.appendAssumeCapacity(try t.para(p).clone(self.allocator));
            step.first = first;
            step.count = last - first + 1;
            return;
        }
        const hi = step.first + step.count - 1;
        if (first < step.first) {
            var copies: std.ArrayList(Para) = .empty;
            defer copies.deinit(self.allocator);
            errdefer for (copies.items) |*p| p.deinit(self.allocator);
            var p = first;
            while (p < step.first) : (p += 1) try copies.append(self.allocator, try t.para(p).clone(self.allocator));
            try step.held.insertSlice(self.allocator, 0, copies.items);
            step.count += step.first - first;
            step.first = first;
        }
        if (last > hi) {
            var p = hi + 1;
            while (p <= last) : (p += 1) {
                var copy = try t.para(p).clone(self.allocator);
                errdefer copy.deinit(self.allocator);
                try step.held.append(self.allocator, copy);
                step.count += 1;
            }
        }
    }

    /// Notes a change of the text from `start` to `start+removed`, now
    /// `inserted` runes, and moves the selection with it.
    fn replaced(self: *Document, start: u32, removed: u32, inserted: u32) void {
        self.version += 1;
        const s = self.span();
        var a: u32 = undefined;
        var z: u32 = undefined;
        if (s.start == s.end) {
            a = mapPosition(s.start, start, removed, inserted, false);
            z = a;
        } else {
            a = mapPosition(s.start, start, removed, inserted, false);
            z = mapPosition(s.end, start, removed, inserted, true);
        }
        if (self.caret >= self.anchor) {
            self.anchor = a;
            self.caret = z;
        } else {
            self.anchor = z;
            self.caret = a;
        }
        self.typing = null;
    }

    // ---- Undo ------------------------------------------------------------

    pub fn canUndo(self: *const Document) bool {
        return self.undo_steps.items.len > 0;
    }
    pub fn canRedo(self: *const Document) bool {
        return self.redo_steps.items.len > 0;
    }

    /// Takes back the last step of undo, restoring the text, its
    /// attributes and the selection.
    pub fn undo(self: *Document) !void {
        try self.takeBack(false);
    }
    /// Takes back the last step undone.
    pub fn redo(self: *Document) !void {
        try self.takeBack(true);
    }

    fn takeBack(self: *Document, forward: bool) !void {
        const allocator = self.allocator;
        const from = if (forward) &self.redo_steps else &self.undo_steps;
        const to = if (forward) &self.undo_steps else &self.redo_steps;
        if (from.items.len == 0) return;
        try to.ensureUnusedCapacity(allocator, 1);
        var step = from.items[from.items.len - 1];
        var removed: std.ArrayList(Para) = .empty;
        try removed.ensureTotalCapacity(allocator, step.count);
        errdefer removed.deinit(allocator);
        try self.text.paras.ensureUnusedCapacity(allocator, step.held.items.len);
        // Nothing fails from here on: the paragraphs trade places.
        removed.appendSliceAssumeCapacity(self.text.paras.items[step.first..][0..step.count]);
        self.text.paras.replaceRangeAssumeCapacity(step.first, step.count, step.held.items);
        self.text.invalidate();
        step.count = @intCast(step.held.items.len);
        step.held.deinit(allocator);
        step.held = removed;
        _ = from.pop();
        to.appendAssumeCapacity(step);
        self.version += 1;
        const sel = if (forward) step.selection_after else step.selection_before;
        self.setSelectionRaw(sel.anchor, sel.caret);
    }

    /// Ends the step typing adds to, as at a save, so that what is typed
    /// next undoes on its own.
    pub fn breakUndoCoalescing(self: *Document) void {
        self.coalesce = false;
    }

    // ---- Commands ----------------------------------------------------------

    /// The formats of the selection.
    pub fn formatting(self: *const Document) Formatting {
        const s = self.span();
        var f: Formatting = .{ .attributes = self.typingAttributes() };
        if (s.start < s.end) {
            // From the first rune that takes a format, not a newline.
            var it = self.text.rangeRuns(s.start, s.end);
            while (it.next()) |item| if (!std.mem.eql(u8, item.run.text, "\n")) {
                f.attributes = item.run.attributes;
                f.attributes.attachment = null;
                break;
            };
        }
        const at = f.attributes;
        f.bold = state(at.bold());
        f.italic = state(at.italic);
        f.underline = state(at.underline);
        f.strikethrough = state(at.strikethrough);
        f.code = state(at.code);
        f.link = at.link;
        if (s.start < s.end) {
            var it = self.text.rangeRuns(s.start, s.end);
            while (it.next()) |item| {
                if (std.mem.eql(u8, item.run.text, "\n")) continue; // a newline selected takes no format
                const x = item.run.attributes;
                mix(&f.bold, x.bold());
                mix(&f.italic, x.italic);
                mix(&f.underline, x.underline);
                mix(&f.strikethrough, x.strikethrough);
                mix(&f.code, x.code);
                if (!std.mem.eql(u8, x.link, f.link)) f.link = "";
            }
        }
        const ps = self.text.paragraphSpan(s.start, s.end);
        f.paragraph = self.text.para(ps.first).style;
        var p = ps.first + 1;
        while (p <= ps.last) : (p += 1) {
            if (!self.text.para(p).style.eql(f.paragraph)) f.paragraphs_mixed = true;
        }
        return f;
    }

    fn state(on: bool) FormatState {
        return if (on) .on else .off;
    }
    fn mix(s: *FormatState, on: bool) void {
        if ((s.* == .on) != on) s.* = .mixed;
    }

    /// Changes the attributes of the selection with
    /// `changer.change(*Attributes)`, as one step of undo, or the typing
    /// attributes at a caret.
    pub fn format(self: *Document, changer: anytype) !void {
        const s = self.span();
        if (s.start == s.end) {
            var t = self.typingAttributes();
            changer.change(&t);
            t.attachment = null;
            self.typing = try self.text.intern(t);
            return;
        }
        const anchor = self.anchor;
        const caret = self.caret;
        const Ctx = struct {
            changer: @TypeOf(changer),
            start: u32,
            end: u32,
            fn run(c: @This(), e: *Edit) !void {
                try e.format(c.start, c.end, c.changer);
            }
        };
        try self.edit(Ctx{ .changer = changer, .start = s.start, .end = s.end }, Ctx.run);
        self.anchor = anchor;
        self.caret = caret;
    }

    const Toggle = struct {
        field: enum { bold, italic, underline, strikethrough, code },
        on: bool,
        pub fn change(self: Toggle, a: *Attributes) void {
            switch (self.field) {
                .bold => a.weight = if (self.on) 700 else 0,
                .italic => a.italic = self.on,
                .underline => a.underline = self.on,
                .strikethrough => a.strikethrough = self.on,
                .code => a.code = self.on,
            }
        }
    };

    fn toggle(self: *Document, field: @FieldType(Toggle, "field")) !void {
        const f = self.formatting();
        const current = switch (field) {
            .bold => f.bold,
            .italic => f.italic,
            .underline => f.underline,
            .strikethrough => f.strikethrough,
            .code => f.code,
        };
        try self.format(Toggle{ .field = field, .on = current != .on });
    }

    /// Makes the selection bold, or not when all of it is.
    pub fn toggleBold(self: *Document) !void {
        try self.toggle(.bold);
    }
    pub fn toggleItalic(self: *Document) !void {
        try self.toggle(.italic);
    }
    pub fn toggleUnderline(self: *Document) !void {
        try self.toggle(.underline);
    }
    pub fn toggleStrikethrough(self: *Document) !void {
        try self.toggle(.strikethrough);
    }
    pub fn toggleCode(self: *Document) !void {
        try self.toggle(.code);
    }

    /// The runes around i that link to the same URL as rune i.
    fn linkRange(self: *const Document, i: u32) struct { start: u32, end: u32 } {
        const t = &self.text;
        const url = t.attributesAt(i).link;
        if (url.len == 0 or i >= t.len()) return .{ .start = i, .end = i };
        const r = t.paragraphRange(i);
        var a = i;
        var z = i;
        while (a > r.start and std.mem.eql(u8, t.attributesAt(a - 1).link, url)) a -= 1;
        while (z < r.end and std.mem.eql(u8, t.attributesAt(z).link, url)) z += 1;
        return .{ .start = a, .end = z };
    }

    const SetLink = struct {
        url: []const u8,
        pub fn change(self: SetLink, a: *Attributes) void {
            a.link = self.url;
        }
    };

    /// Links the selection to `url`, or takes its link away for "". At a
    /// caret inside a link it changes or takes away that link; elsewhere it
    /// inserts `url`, linked to itself.
    pub fn setLink(self: *Document, url: []const u8) !void {
        var s = self.span();
        if (s.start == s.end) {
            var r = self.linkRange(s.start);
            if (r.start == r.end and s.start > 0) {
                r = self.linkRange(s.start - 1);
                if (r.end != s.start) r = .{ .start = s.start, .end = s.start };
            }
            if (r.start == r.end) {
                if (url.len > 0) {
                    var attrs = self.typingAttributes();
                    attrs.link = url;
                    const Ctx = struct {
                        at: u32,
                        url: []const u8,
                        attrs: Attributes,
                        fn run(c: @This(), e: *Edit) !void {
                            try e.replaceString(c.at, c.at, c.url, c.attrs);
                        }
                    };
                    try self.edit(Ctx{ .at = s.start, .url = url, .attrs = attrs }, Ctx.run);
                }
                return;
            }
            s = .{ .start = r.start, .end = r.end };
        }
        const anchor = self.anchor;
        const caret = self.caret;
        const Ctx = struct {
            start: u32,
            end: u32,
            url: []const u8,
            fn run(c: @This(), e: *Edit) !void {
                try e.format(c.start, c.end, SetLink{ .url = c.url });
            }
        };
        try self.edit(Ctx{ .start = s.start, .end = s.end, .url = url }, Ctx.run);
        self.anchor = anchor;
        self.caret = caret;
    }

    /// Changes the styles of the paragraphs selected with
    /// `changer.change(*ParagraphStyle)`, as one step of undo.
    pub fn formatParagraphs(self: *Document, changer: anytype) !void {
        const s = self.span();
        const anchor = self.anchor;
        const caret = self.caret;
        const typing = self.typing;
        const Ctx = struct {
            changer: @TypeOf(changer),
            start: u32,
            end: u32,
            fn run(c: @This(), e: *Edit) !void {
                try e.formatParagraphs(c.start, c.end, c.changer);
            }
        };
        try self.edit(Ctx{ .changer = changer, .start = s.start, .end = s.end }, Ctx.run);
        self.anchor = anchor;
        self.caret = caret;
        self.typing = typing;
    }

    /// Whether every paragraph selected satisfies `predicate`.
    fn paragraphsAll(self: *const Document, comptime predicate: fn (ParagraphStyle, anytype) bool, arg: anytype) bool {
        const s = self.span();
        const ps = self.text.paragraphSpan(s.start, s.end);
        var p = ps.first;
        while (p <= ps.last) : (p += 1) if (!predicate(self.text.para(p).style, arg)) return false;
        return true;
    }

    const Heading = struct {
        level: u8,
        pub fn change(self: Heading, p: *ParagraphStyle) void {
            p.heading = @min(self.level, 6);
            if (p.heading > 0) {
                p.list = .none;
                p.checked = false;
                p.code_block = false;
            }
        }
    };

    /// Makes the paragraphs selected headings of `level`, from 1, or body
    /// paragraphs for 0.
    pub fn setHeading(self: *Document, level: u8) !void {
        try self.formatParagraphs(Heading{ .level = level });
    }

    const List = struct {
        kind: ListKind,
        off: bool,
        pub fn change(self: List, p: *ParagraphStyle) void {
            if (self.off) {
                p.list = .none;
                p.checked = false;
                return;
            }
            p.list = self.kind;
            p.heading = 0;
            p.code_block = false;
            if (self.kind != .tasks) p.checked = false;
        }
    };

    fn isList(p: ParagraphStyle, kind: anytype) bool {
        return p.list == kind;
    }
    fn isQuote(p: ParagraphStyle, _: anytype) bool {
        return p.quote;
    }
    fn isCodeBlock(p: ParagraphStyle, _: anytype) bool {
        return p.code_block;
    }

    /// Makes the paragraphs selected items of a list of `kind`, or takes
    /// them out of it when all of them are.
    pub fn toggleList(self: *Document, kind: ListKind) !void {
        const off = self.paragraphsAll(isList, kind);
        try self.formatParagraphs(List{ .kind = kind, .off = off });
    }

    const Quote = struct {
        on: bool,
        pub fn change(self: Quote, p: *ParagraphStyle) void {
            p.quote = self.on;
        }
    };
    const CodeBlock = struct {
        on: bool,
        pub fn change(self: CodeBlock, p: *ParagraphStyle) void {
            p.code_block = self.on;
            if (self.on) {
                p.heading = 0;
                p.list = .none;
                p.checked = false;
            }
        }
    };

    /// Makes the paragraphs selected a quotation, or not when all are.
    pub fn toggleQuote(self: *Document) !void {
        const off = self.paragraphsAll(isQuote, {});
        try self.formatParagraphs(Quote{ .on = !off });
    }
    /// Makes the paragraphs selected a block of code, or not when all are.
    pub fn toggleCodeBlock(self: *Document) !void {
        const off = self.paragraphsAll(isCodeBlock, {});
        try self.formatParagraphs(CodeBlock{ .on = !off });
    }

    const Indent = struct {
        levels: i32,
        pub fn change(self: Indent, p: *ParagraphStyle) void {
            p.indent = @intCast(zio.asUnsigned(std.math.clamp(@as(i32, p.indent) + self.levels, 0, tx.max_indent)));
        }
    };

    /// Indents the paragraphs selected by `levels`, or outdents them for a
    /// negative count, as Tab and Shift+Tab do in a list.
    pub fn indent(self: *Document, levels: i32) !void {
        try self.formatParagraphs(Indent{ .levels = levels });
    }

    const SetAlign = struct {
        value: tx.Align,
        pub fn change(self: SetAlign, p: *ParagraphStyle) void {
            p.@"align" = self.value;
        }
    };

    /// Aligns the lines of the paragraphs selected.
    pub fn setAlign(self: *Document, value: tx.Align) !void {
        try self.formatParagraphs(SetAlign{ .value = value });
    }

    const Check = struct {
        pub fn change(_: Check, p: *ParagraphStyle) void {
            if (p.list == .tasks) p.checked = !p.checked;
        }
    };

    /// Checks the task holding rune i, or unchecks it.
    pub fn toggleChecked(self: *Document, i: u32) !void {
        const anchor = self.anchor;
        const caret = self.caret;
        const typing = self.typing;
        const Ctx = struct {
            at: u32,
            fn run(c: @This(), e: *Edit) !void {
                try e.formatParagraphs(c.at, c.at, Check{});
            }
        };
        try self.edit(Ctx{ .at = i }, Ctx.run);
        self.anchor = anchor;
        self.caret = caret;
        self.typing = typing;
    }

    /// Replaces the selection with `s` in the typing attributes, as typing
    /// does but as a step of undo of its own.
    pub fn insertText(self: *Document, s: []const u8) !void {
        const sel = self.span();
        const Ctx = struct {
            start: u32,
            end: u32,
            s: []const u8,
            attrs: Attributes,
            fn run(c: @This(), e: *Edit) !void {
                const n = e.text().len();
                try e.replaceString(c.start, c.end, c.s, c.attrs);
                const at = c.end + e.text().len() - n;
                e.select(at, at);
            }
        };
        try self.edit(Ctx{ .start = sel.start, .end = sel.end, .s = s, .attrs = self.typingAttributes() }, Ctx.run);
    }

    /// Replaces the selection with `text`, as a paste does.
    pub fn insert(self: *Document, text: *const Text) !void {
        const sel = self.span();
        const Ctx = struct {
            start: u32,
            end: u32,
            with: *const Text,
            fn run(c: @This(), e: *Edit) !void {
                try e.replace(c.start, c.end, c.with);
                const at = c.start + c.with.len();
                e.select(at, at);
            }
        };
        try self.edit(Ctx{ .start = sel.start, .end = sel.end, .with = text }, Ctx.run);
    }

    /// Replaces the selection with an attachment, which the text copies.
    pub fn insertAttachment(self: *Document, attachment: *const tx.Attachment) !void {
        const sel = self.span();
        var attrs = self.typingAttributes().extending();
        attrs.attachment = attachment;
        const Ctx = struct {
            start: u32,
            end: u32,
            attrs: Attributes,
            fn run(c: @This(), e: *Edit) !void {
                try e.replaceString(c.start, c.end, tx.object_replacement_utf8, c.attrs);
                e.select(c.start + 1, c.start + 1);
            }
        };
        try self.edit(Ctx{ .start = sel.start, .end = sel.end, .attrs = attrs }, Ctx.run);
    }
};

/// Changes a document as one step of undo, in `Document.edit`. Offsets are
/// into the text as the edit's changes so far left it, and the selection
/// follows them.
pub const Edit = struct {
    doc: *Document,
    step_index: usize,

    fn step(self: *Edit) *Step {
        return &self.doc.undo_steps.items[self.step_index];
    }

    /// The text as the edit's changes so far left it.
    pub fn text(self: *const Edit) *const Text {
        return &self.doc.text;
    }

    pub fn selection(self: *const Edit) Selection {
        return self.doc.selection();
    }

    /// Selects the runes between anchor and caret.
    pub fn select(self: *Edit, anchor: u32, caret: u32) void {
        self.doc.setSelectionRaw(anchor, caret);
    }

    /// Replaces the runes from start to end with `with`.
    pub fn replace(self: *Edit, start: u32, end: u32, with: *const Text) !void {
        const d = self.doc;
        const n = d.text.len();
        const a = @min(@min(start, end), n);
        const z = @min(@max(start, end), n);
        const before = d.text.paragraphCount();
        const s = d.text.replaceSpan(a, z);
        try d.cover(self.step(), s.first, s.last);
        try d.text.replace(a, z, with);
        self.finishReplace(before, a, z - a, d.text.len() + (z - a) - n);
    }

    /// Replaces the runes from start to end with `s` in attributes `a`.
    pub fn replaceString(self: *Edit, start: u32, end: u32, s: []const u8, a: Attributes) !void {
        const d = self.doc;
        const n = d.text.len();
        const lo = @min(@min(start, end), n);
        const hi = @min(@max(start, end), n);
        const before = d.text.paragraphCount();
        const span = d.text.replaceSpan(lo, hi);
        try d.cover(self.step(), span.first, span.last);
        try d.text.replaceString(lo, hi, s, a);
        self.finishReplace(before, lo, hi - lo, d.text.len() + (hi - lo) - n);
    }

    fn finishReplace(self: *Edit, paragraphs_before: u32, start: u32, removed: u32, inserted: u32) void {
        const d = self.doc;
        const st = self.step();
        const after = d.text.paragraphCount();
        st.count = @intCast(zio.asUnsigned(@as(i64, st.count) + @as(i64, after) - @as(i64, paragraphs_before)));
        st.changed = true;
        d.replaced(start, removed, inserted);
    }

    /// Changes the attributes of the runes from start to end with
    /// `changer.change(*Attributes)`.
    pub fn format(self: *Edit, start: u32, end: u32, changer: anytype) !void {
        const d = self.doc;
        const n = d.text.len();
        const a = @min(start, n);
        const z = @min(end, n);
        if (a >= z) return;
        const s = d.text.formatSpan(a, z);
        try d.cover(self.step(), s.first, s.last);
        if (try d.text.format(a, z, changer)) {
            self.step().changed = true;
            d.version += 1;
        }
    }

    /// Changes the styles of the paragraphs from the one holding start to
    /// the one holding end with `changer.change(*ParagraphStyle)`.
    pub fn formatParagraphs(self: *Edit, start: u32, end: u32, changer: anytype) !void {
        const d = self.doc;
        const s = d.text.paragraphSpan(start, end);
        try d.cover(self.step(), s.first, s.last);
        if (d.text.formatParagraphs(start, end, changer)) {
            self.step().changed = true;
            d.version += 1;
        }
    }
};
