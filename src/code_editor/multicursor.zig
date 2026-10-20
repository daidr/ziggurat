//! Multi-caret selection commands over a document editor: select the next or
//! previous occurrence, select every occurrence, add a caret on the line
//! above or below, grow and shrink selections by syntax, split selections
//! into lines, go to the matching bracket, and undo and redo the selection
//! changes these commands make. The newest selection is the primary one.
//!
//! The commands read the Document through explicit allocations and change
//! only selections, through `Adapter.setSelections`, which merges overlaps.
const std = @import("std");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const syntax = @import("ziggurat_code_syntax");
const DocumentLines = @import("highlight.zig").DocumentLines;

pub const Direction = enum { above, below };

pub const Options = struct {
    /// Characters other than letters, digits and _ inside words, usually the
    /// language's `word_chars`.
    word_chars: []const u8 = "",
    /// Columns a tab advances to, for carets added above and below.
    tab_size: usize = 4,
    /// Selections at most; keep it within the editor's `Limits.selections`.
    max_selections: usize = 64,
    /// Selection changes `undoSelection` can take back.
    history: usize = 256,
};

const Saved = struct { items: []d.Selection, primary: usize };

pub const Commands = struct {
    allocator: std.mem.Allocator,
    options: Options,
    /// Tokens for strings and brackets; without them every bracket counts.
    highlighter: ?*const syntax.Highlighter = null,
    language: ?*const syntax.Language = null,
    /// Matches after the first are whole words, as the first was a word.
    whole_word: bool = false,
    /// Carets added above or below, newest last, and their direction.
    added: std.ArrayList(d.Selection) = .empty,
    add_direction: ?Direction = null,
    goal_column: ?usize = null,
    /// What `selectLarger` grew from, innermost last.
    larger: std.ArrayList(Saved) = .empty,
    undo: std.ArrayList(Saved) = .empty,
    redo: std.ArrayList(Saved) = .empty,
    /// The selections the last command set; other changes reset the state
    /// above that continues from them.
    last: ?Saved = null,
    last_revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Commands {
        return .{ .allocator = allocator, .options = options };
    }
    pub fn deinit(self: *Commands) void {
        self.added.deinit(self.allocator);
        freeAll(self.allocator, &self.larger);
        freeAll(self.allocator, &self.undo);
        freeAll(self.allocator, &self.redo);
        if (self.last) |value| self.allocator.free(value.items);
        self.* = undefined;
    }
    fn freeAll(allocator: std.mem.Allocator, list: *std.ArrayList(Saved)) void {
        for (list.items) |value| allocator.free(value.items);
        list.deinit(allocator);
    }

    /// Use the tokens and brackets of a language's highlighter.
    pub fn setSyntax(self: *Commands, language: ?*const syntax.Language, highlighter: ?*const syntax.Highlighter) void {
        self.language = language;
        self.highlighter = highlighter;
        if (language) |value| self.options.word_chars = value.word_chars;
    }

    const Current = struct { items: []d.Selection, primary: usize, revision: u64 };

    fn current(self: *Commands, adapter: *editing.Adapter) !Current {
        const document = try adapter.sourceDocument();
        const count = try document.selectionCount();
        const items = try self.allocator.alloc(d.Selection, count);
        errdefer self.allocator.free(items);
        const view = try document.selections(items);
        const revision = try document.version();
        // Selections changed by anything else start the chains afresh.
        if (self.last == null or self.last_revision != revision or self.last.?.primary != view.primary or !sameSelections(self.last.?.items, items)) self.forget();
        return .{ .items = items, .primary = view.primary, .revision = revision };
    }
    fn forget(self: *Commands) void {
        self.whole_word = false;
        self.added.clearRetainingCapacity();
        self.add_direction = null;
        self.goal_column = null;
        for (self.larger.items) |value| self.allocator.free(value.items);
        self.larger.clearRetainingCapacity();
    }

    /// Set selections, recording what they replace for `undoSelection`.
    fn apply(self: *Commands, adapter: *editing.Adapter, before: Current, items: []const d.Selection, primary: usize) !bool {
        const changed = try adapter.setSelections(items, primary);
        if (!changed) return false;
        try self.push(&self.undo, before.items, before.primary);
        for (self.redo.items) |value| self.allocator.free(value.items);
        self.redo.clearRetainingCapacity();
        try self.remember(adapter);
        return true;
    }
    fn push(self: *Commands, list: *std.ArrayList(Saved), items: []const d.Selection, primary: usize) !void {
        const copy = try self.allocator.dupe(d.Selection, items);
        errdefer self.allocator.free(copy);
        if (list.items.len == self.options.history) {
            self.allocator.free(list.items[0].items);
            _ = list.orderedRemove(0);
        }
        try list.append(self.allocator, .{ .items = copy, .primary = primary });
    }
    fn remember(self: *Commands, adapter: *editing.Adapter) !void {
        const document = try adapter.sourceDocument();
        const items = try self.allocator.alloc(d.Selection, try document.selectionCount());
        const view = document.selections(items) catch |err| {
            self.allocator.free(items);
            return err;
        };
        if (self.last) |value| self.allocator.free(value.items);
        self.last = .{ .items = items, .primary = view.primary };
        self.last_revision = try document.version();
    }

    /// Read the whole text; the caller frees it.
    fn text(self: *Commands, adapter: *editing.Adapter) ![]u8 {
        const document = try adapter.sourceDocument();
        const length = try document.byteLength();
        const buffer = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(buffer);
        _ = try document.read(.{ .start = 0, .end = length }, buffer);
        return buffer;
    }

    /// Add the next occurrence of the primary selection's text, or with
    /// `previous` the one before it. A caret alone selects its word first,
    /// and then looks for whole words.
    pub fn selectNext(self: *Commands, adapter: *editing.Adapter, previous: bool) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const source = try self.text(adapter);
        defer self.allocator.free(source);
        const primary = before.items[before.primary];
        const range = primary.range();
        if (range.start == range.end) {
            const word = try self.wordAt(adapter, primary.caret);
            if (word.start == word.end) return false;
            const next = try self.allocator.dupe(d.Selection, before.items);
            defer self.allocator.free(next);
            next[before.primary] = .{ .anchor = word.start, .caret = word.end };
            const changed = try self.apply(adapter, before, next, before.primary);
            self.whole_word = true;
            return changed;
        }
        if (before.items.len >= self.options.max_selections) return false;
        const query = source[range.start..range.end];
        const taken: Taken = .{ .items = before.items };
        const filter: syntax.search.Filter = .{ .context = &taken, .call = Taken.free };
        const found = if (previous)
            syntax.search.backward(source, query, range.start, self.whole_word, self.options.word_chars, filter)
        else
            syntax.search.forward(source, query, range.end, self.whole_word, self.options.word_chars, filter);
        const at = found orelse return false;
        const whole = self.whole_word;
        const next = try self.allocator.alloc(d.Selection, before.items.len + 1);
        defer self.allocator.free(next);
        @memcpy(next[0..before.items.len], before.items);
        next[before.items.len] = .{ .anchor = at, .caret = at + query.len };
        const changed = try self.apply(adapter, before, next, before.items.len);
        self.whole_word = whole;
        return changed;
    }

    const Taken = struct {
        items: []const d.Selection,
        fn free(context: *const anyopaque, start: usize, end: usize) bool {
            const self: *const Taken = @ptrCast(@alignCast(context));
            for (self.items) |item| {
                const range = item.range();
                if (range.start < end and range.end > start) return false;
            }
            return true;
        }
    };

    /// Select every occurrence of the primary selection's text, or of the
    /// word at the caret, keeping the original primary.
    pub fn selectAllMatches(self: *Commands, adapter: *editing.Adapter) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const source = try self.text(adapter);
        defer self.allocator.free(source);
        var primary = before.items[before.primary];
        var whole = self.whole_word;
        if (primary.anchor == primary.caret) {
            const word = try self.wordAt(adapter, primary.caret);
            if (word.start == word.end) return false;
            primary = .{ .anchor = word.start, .caret = word.end };
            whole = true;
        }
        const range = primary.range();
        const query = source[range.start..range.end];
        var next: std.ArrayList(d.Selection) = .empty;
        defer next.deinit(self.allocator);
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, query)) |found| {
            if (next.items.len + 1 == self.options.max_selections) break;
            if (found != range.start and (!whole or syntax.search.isWholeWord(source, found, found + query.len, self.options.word_chars)))
                try next.append(self.allocator, .{ .anchor = found, .caret = found + query.len });
            at = found + query.len;
        }
        try next.append(self.allocator, primary);
        const changed = try self.apply(adapter, before, next.items, next.items.len - 1);
        self.whole_word = whole;
        return changed;
    }

    /// Add a caret on the line above or below the outermost caret in that
    /// direction, at the primary caret's column. Going back the other way
    /// removes the carets added, newest first.
    pub fn addCaret(self: *Commands, adapter: *editing.Adapter, direction: Direction) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const document = try adapter.sourceDocument();
        if (self.add_direction != null and self.add_direction.? != direction and self.added.items.len > 0) {
            const removed = self.added.pop().?;
            var next: std.ArrayList(d.Selection) = .empty;
            defer next.deinit(self.allocator);
            var primary: usize = 0;
            for (before.items) |item| if (!std.meta.eql(item, removed)) {
                if (self.added.items.len > 0 and std.meta.eql(item, self.added.items[self.added.items.len - 1])) primary = next.items.len;
                try next.append(self.allocator, item);
            };
            if (next.items.len > 0 and next.items.len < before.items.len) {
                if (self.added.items.len == 0) primary = @min(before.primary, next.items.len - 1);
                return self.apply(adapter, before, next.items, primary);
            }
        }
        if (before.items.len >= self.options.max_selections) return false;
        if (self.added.items.len == 0) self.add_direction = direction;
        const primary = before.items[before.primary];
        var from = primary.caret;
        for (before.items) |item| {
            if ((direction == .above and item.caret < from) or (direction == .below and item.caret > from)) from = item.caret;
        }
        const line = try document.lineAt(from);
        const lines = try document.lineCount();
        if ((direction == .above and line == 0) or (direction == .below and line + 1 >= lines)) return false;
        const goal = self.goal_column orelse try self.column(document, primary.caret);
        const target_line = if (direction == .above) line - 1 else line + 1;
        const to = try self.offsetAtColumn(document, target_line, goal);
        const caret: d.Selection = .{ .anchor = to, .caret = to };
        const next = try self.allocator.alloc(d.Selection, before.items.len + 1);
        defer self.allocator.free(next);
        @memcpy(next[0..before.items.len], before.items);
        next[before.items.len] = caret;
        try self.added.ensureUnusedCapacity(self.allocator, 1);
        const changed = try self.apply(adapter, before, next, before.items.len);
        self.added.appendAssumeCapacity(caret);
        self.goal_column = goal;
        return changed;
    }

    /// The display column of a byte offset, with tabs advancing to stops.
    fn column(self: *Commands, document: *const d.Document, offset: usize) !usize {
        const line = try document.line(try document.lineAt(offset));
        var buffer: [syntax.max_line]u8 = undefined;
        const count = try document.read(.{ .start = line.start, .end = @min(offset, line.start + buffer.len) }, &buffer);
        return self.columns(buffer[0..count]);
    }
    fn columns(self: *const Commands, prefix: []const u8) usize {
        var width: usize = 0;
        var view = std.unicode.Utf8View.init(prefix) catch return prefix.len;
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            if (c == '\t') {
                width += self.options.tab_size - width % self.options.tab_size;
            } else width += 1;
        }
        return width;
    }
    /// The offset in a line nearest a display column, clamped to its end.
    fn offsetAtColumn(self: *Commands, document: *const d.Document, index: usize, goal: usize) !usize {
        const line = try document.line(index);
        var buffer: [syntax.max_line]u8 = undefined;
        const count = try document.read(.{ .start = line.start, .end = @min(line.end, line.start + buffer.len) }, &buffer);
        var text_end = count;
        if (text_end > 0 and buffer[text_end - 1] == '\r') text_end -= 1;
        var width: usize = 0;
        var at: usize = 0;
        while (at < text_end and width < goal) {
            const size = std.unicode.utf8ByteSequenceLength(buffer[at]) catch 1;
            width += if (buffer[at] == '\t') self.options.tab_size - width % self.options.tab_size else 1;
            at = @min(text_end, at + size);
        }
        return line.start + at;
    }

    /// The word around an offset, by the word characters of the language.
    fn wordAt(self: *Commands, adapter: *editing.Adapter, offset: usize) !struct { start: usize, end: usize } {
        const document = try adapter.sourceDocument();
        const line = try document.line(try document.lineAt(offset));
        var buffer: [syntax.max_line]u8 = undefined;
        const count = try document.read(.{ .start = line.start, .end = @min(line.end, line.start + buffer.len) }, &buffer);
        const word = syntax.search.wordAt(buffer[0..count], offset - line.start, self.options.word_chars);
        // The word, not a run of spaces or punctuation.
        if (word.start == word.end) return .{ .start = offset, .end = offset };
        const scalar = std.unicode.utf8Decode(buffer[word.start .. word.start + (std.unicode.utf8ByteSequenceLength(buffer[word.start]) catch 1)]) catch return .{ .start = offset, .end = offset };
        if (syntax.search.classOf(scalar, self.options.word_chars) != .word) return .{ .start = offset, .end = offset };
        return .{ .start = line.start + word.start, .end = line.start + word.end };
    }

    fn matcher(self: *Commands, document: *const d.Document, line: []u8, tokens: []syntax.Token) syntax.brackets.Matcher(DocumentLines) {
        return .{ .source = .{ .document = document }, .highlighter = self.highlighter, .pairs = .of(self.language), .line = line, .tokens = tokens };
    }

    /// Grow each selection a step: to the word at a caret, the inside of the
    /// string around it, then the string, the inside of the brackets around
    /// it, then the brackets, the line, and the whole text.
    pub fn selectLarger(self: *Commands, adapter: *editing.Adapter) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const document = try adapter.sourceDocument();
        const next = try self.allocator.dupe(d.Selection, before.items);
        defer self.allocator.free(next);
        var line: [syntax.max_line]u8 = undefined;
        var tokens: [512]syntax.Token = undefined;
        var brackets = self.matcher(document, &line, &tokens);
        var grown = false;
        for (next) |*item| {
            const range = item.range();
            const wider = try self.largerRange(adapter, &brackets, range.start, range.end);
            if (wider.start < range.start or wider.end > range.end) {
                item.* = if (item.caret < item.anchor) .{ .anchor = wider.end, .caret = wider.start } else .{ .anchor = wider.start, .caret = wider.end };
                grown = true;
            }
        }
        if (!grown) return false;
        const copy = try self.allocator.dupe(d.Selection, before.items);
        errdefer self.allocator.free(copy);
        try self.larger.ensureUnusedCapacity(self.allocator, 1);
        const changed = try self.apply(adapter, before, next, before.primary);
        // Select Smaller takes it back.
        self.larger.appendAssumeCapacity(.{ .items = copy, .primary = before.primary });
        return changed;
    }

    /// Take back the last growth of `selectLarger`.
    pub fn selectSmaller(self: *Commands, adapter: *editing.Adapter) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const saved = self.larger.pop() orelse return false;
        defer self.allocator.free(saved.items);
        return self.apply(adapter, before, saved.items, saved.primary);
    }

    fn largerRange(self: *Commands, adapter: *editing.Adapter, brackets: anytype, start: usize, end: usize) !d.Range {
        const document = try adapter.sourceDocument();
        if (start == end) {
            const word = try self.wordAt(adapter, start);
            if (word.end > word.start) return .{ .start = word.start, .end = word.end };
        }
        // The string around the selection: its inside, then with quotes.
        if (try self.stringAround(document, start, end)) |inside| {
            if (inside.start < start or inside.end > end) return inside;
            const line_start = (try document.line(try document.lineAt(inside.start))).start;
            if (inside.start > line_start and (inside.start - 1 < start or inside.end + 1 > end)) return .{ .start = inside.start - 1, .end = inside.end + 1 };
        }
        // The brackets around it: their inside, then them; a selected pair
        // grows to the pair around it.
        var pair = try brackets.enclosing(start, end);
        if (pair) |value| if (value.open == start and value.close + 1 == end) {
            pair = if (start > 0) try brackets.enclosing(start - 1, end) else null;
        };
        if (pair) |value| {
            if (value.open + 1 <= start and value.close >= end and (value.open + 1 < start or value.close > end)) return .{ .start = value.open + 1, .end = value.close };
            return .{ .start = value.open, .end = value.close + 1 };
        }
        const first = try document.line(try document.lineAt(start));
        const last = try document.line(try document.lineAt(end));
        if (first.start < start or last.end > end) return .{ .start = first.start, .end = last.end };
        return .{ .start = 0, .end = try document.byteLength() };
    }

    /// Inside the quotes of the string token holding start..end on one line.
    fn stringAround(self: *Commands, document: *const d.Document, start: usize, end: usize) !?d.Range {
        const highlighter = self.highlighter orelse return null;
        const index = try document.lineAt(start);
        if (try document.lineAt(end) != index) return null;
        const line = try document.line(index);
        var buffer: [syntax.max_line]u8 = undefined;
        if (line.end - line.start > buffer.len) return null;
        const count = try document.read(line, &buffer);
        var tokens: [512]syntax.Token = undefined;
        const list = highlighter.tokens(index, buffer[0..count], &tokens).tokens;
        var from: usize = 0;
        var at: usize = 0;
        while (at < list.len) : (at += 1) {
            const token = list[at];
            if (token.kind == .string or token.kind == .escape) {
                var last = at;
                while (last + 1 < list.len and (list[last + 1].kind == .string or list[last + 1].kind == .escape)) last += 1;
                const a = line.start + from;
                const z = line.start + list[last].end;
                if (a <= start and end <= z and z - a >= 2) return .{ .start = a + 1, .end = z - 1 };
                at = last;
                from = list[last].end;
                continue;
            }
            from = token.end;
        }
        return null;
    }

    /// One selection per line of each selection, as each line's part of it.
    pub fn splitIntoLines(self: *Commands, adapter: *editing.Adapter) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const document = try adapter.sourceDocument();
        var next: std.ArrayList(d.Selection) = .empty;
        defer next.deinit(self.allocator);
        for (before.items) |item| {
            const range = item.range();
            const first = try document.lineAt(range.start);
            var last = try document.lineAt(range.end);
            // A selection ending at a line's start stops on the line before.
            if (last > first and (try document.line(last)).start == range.end) last -= 1;
            var index = first;
            while (index <= last) : (index += 1) {
                const line = try document.line(index);
                const a = @max(range.start, line.start);
                const z = @min(range.end, line.end);
                if (next.items.len == self.options.max_selections) break;
                try next.append(self.allocator, .{ .anchor = a, .caret = z });
            }
        }
        if (next.items.len == 0) return false;
        return self.apply(adapter, before, next.items, next.items.len - 1);
    }

    /// Move each caret to the other bracket of the pair around it, or with
    /// `extend` select to it.
    pub fn toBracket(self: *Commands, adapter: *editing.Adapter, extend: bool) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const document = try adapter.sourceDocument();
        const next = try self.allocator.dupe(d.Selection, before.items);
        defer self.allocator.free(next);
        var line: [syntax.max_line]u8 = undefined;
        var tokens: [512]syntax.Token = undefined;
        var brackets = self.matcher(document, &line, &tokens);
        for (next) |*item| {
            const pair = try brackets.enclosing(item.caret, item.caret) orelse continue;
            const target = syntax.brackets.jumpTarget(item.caret, pair);
            item.* = .{ .anchor = if (extend) item.anchor else target, .caret = target };
        }
        return self.apply(adapter, before, next, before.primary);
    }

    /// The pair of brackets around the primary caret, to highlight.
    pub fn bracketsAround(self: *Commands, adapter: *editing.Adapter) !?syntax.brackets.Pair {
        const document = try adapter.sourceDocument();
        const caret = (try document.selection()).caret;
        var line: [syntax.max_line]u8 = undefined;
        var tokens: [512]syntax.Token = undefined;
        var brackets = self.matcher(document, &line, &tokens);
        return brackets.enclosing(caret, caret);
    }

    /// Keep only the primary selection.
    pub fn single(self: *Commands, adapter: *editing.Adapter) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        if (before.items.len < 2) return false;
        return self.apply(adapter, before, before.items[before.primary .. before.primary + 1], 0);
    }

    /// Take back the last selection change these commands made, or with
    /// `redo` put it back.
    pub fn undoSelection(self: *Commands, adapter: *editing.Adapter, redo: bool) !bool {
        const before = try self.current(adapter);
        defer self.allocator.free(before.items);
        const from = if (redo) &self.redo else &self.undo;
        const to = if (redo) &self.undo else &self.redo;
        const document = try adapter.sourceDocument();
        const length = try document.byteLength();
        while (from.pop()) |saved| {
            defer self.allocator.free(saved.items);
            // Selections past the end of edited text are skipped.
            var valid = true;
            for (saved.items) |item| if (item.anchor > length or item.caret > length) {
                valid = false;
            };
            if (!valid) continue;
            const changed = adapter.setSelections(saved.items, saved.primary) catch continue;
            if (!changed) continue;
            try self.push(to, before.items, before.primary);
            try self.remember(adapter);
            return true;
        }
        return false;
    }
};

fn sameSelections(a: []const d.Selection, b: []const d.Selection) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.anchor != y.anchor or x.caret != y.caret) return false;
    return true;
}
