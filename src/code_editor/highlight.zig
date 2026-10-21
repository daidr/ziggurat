//! Syntax highlighting of a document editor: the incremental line
//! highlighter follows the Document, and the visible lines' tokens become
//! foreground range markers that the editor draws in the theme's colors.
//! Token weights and slants of a theme are not drawn: the editor shapes each
//! paragraph in one font.
const std = @import("std");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const syntax = @import("ziggurat_code_syntax");

/// A Document's lines as a highlighter and bracket matcher source.
pub const DocumentLines = struct {
    document: *const d.Document,

    pub fn lineCount(self: DocumentLines) !usize {
        return self.document.lineCount();
    }
    pub fn readLine(self: DocumentLines, index: usize, buffer: []u8) !syntax.SourceLine {
        const range = try self.document.line(index);
        const length = range.end - range.start;
        const count = try self.document.read(.{ .start = range.start, .end = range.start + @min(length, buffer.len) }, buffer);
        return .{ .text = buffer[0..count], .length = length };
    }
    pub fn lineStart(self: DocumentLines, index: usize) !usize {
        return (try self.document.line(index)).start;
    }
    pub fn lineAt(self: DocumentLines, offset: usize) !usize {
        return self.document.lineAt(offset);
    }
    pub fn byteLength(self: DocumentLines) !usize {
        return self.document.byteLength();
    }
};

pub const Options = struct {
    /// Lines tokenized per update; the rest wait for the next one.
    budget: usize = 4096,
    /// Markers installed at most, counting the host's own; the editor's
    /// `Limits.range_markers` must allow as many.
    max_markers: usize = 4096,
};

pub const Update = struct {
    /// Every line shown starts in a confirmed state; false asks for another
    /// update, as from a posted task.
    ready: bool,
    /// The markers match the editor's committed text. False while a newer
    /// edit or composition is pending; update again after it.
    current: bool,
    markers: usize,
};

pub const Highlighting = struct {
    allocator: std.mem.Allocator,
    language: *const syntax.Language,
    theme: syntax.Theme,
    options: Options,
    highlighter: syntax.Highlighter,
    markers: std.ArrayList(editing.RangeMarker) = .empty,
    text_version: ?u64 = null,
    line: []u8,
    tokens: []syntax.Token,

    /// A language without a tokenizer installs no token markers.
    pub fn init(allocator: std.mem.Allocator, language: *const syntax.Language, theme: syntax.Theme, options: Options) !Highlighting {
        var highlighter = try syntax.Highlighter.init(allocator, language.tokenizer orelse plain);
        errdefer highlighter.deinit();
        const line = try allocator.alloc(u8, syntax.max_line);
        errdefer allocator.free(line);
        const tokens = try allocator.alloc(syntax.Token, 1024);
        return .{ .allocator = allocator, .language = language, .theme = theme, .options = options, .highlighter = highlighter, .line = line, .tokens = tokens };
    }
    pub fn deinit(self: *Highlighting) void {
        self.highlighter.deinit();
        self.markers.deinit(self.allocator);
        self.allocator.free(self.line);
        self.allocator.free(self.tokens);
        self.* = undefined;
    }

    pub fn setLanguage(self: *Highlighting, language: *const syntax.Language) void {
        self.language = language;
        self.highlighter.reset(language.tokenizer orelse plain);
        self.text_version = null;
    }
    pub fn setTheme(self: *Highlighting, theme: syntax.Theme) void {
        self.theme = theme;
    }

    /// Follow an edit that replaced lines `start..old_end` with
    /// `start..new_end`, for hosts that know their edits. Others need not
    /// call it: `update` finds changed lines by their hashes.
    pub fn edited(self: *Highlighting, start: usize, old_end: usize, new_end: usize, text_version: u64) !void {
        try self.highlighter.edit(start, old_end, new_end);
        self.text_version = text_version;
    }

    /// Highlight lines `first..first + count` of the adapter's Document and
    /// install them as foreground markers merged with the host's `extra`
    /// markers, which keep their own order among equal starts. Prepare the
    /// editor again afterwards to draw them.
    pub fn update(self: *Highlighting, adapter: *editing.Adapter, first: usize, count: usize, extra: []const editing.RangeMarker) !Update {
        const document = try adapter.sourceDocument();
        const version = try document.committedTextVersion();
        const lines: DocumentLines = .{ .document = document };
        if (self.text_version != version) {
            try self.highlighter.sync(lines);
            self.text_version = version;
        }
        const total = try document.lineCount();
        const start = @min(first, total -| 1);
        const end = @min(total, start + count);
        const ready = try self.highlighter.highlight(lines, end -| 1, self.options.budget);
        try self.collect(lines, start, end, extra);
        const result = try adapter.setRangeMarkers(version, self.markers.items);
        return .{ .ready = ready, .current = result.current, .markers = self.markers.items.len };
    }

    /// The markers of lines `start..end` and `extra`, sorted by start.
    pub fn collect(self: *Highlighting, lines: DocumentLines, start: usize, end: usize, extra: []const editing.RangeMarker) !void {
        self.markers.clearRetainingCapacity();
        const budget = self.options.max_markers -| extra.len;
        var index = start;
        outer: while (index < end) : (index += 1) {
            const line = try lines.readLine(index, self.line);
            if (line.length > line.text.len) continue;
            const line_start = try lines.lineStart(index);
            const tokens = self.highlighter.tokens(index, line.text, self.tokens).tokens;
            var from: usize = 0;
            for (tokens) |token| {
                defer from = token.end;
                const color = self.theme.color(token.kind);
                if (color == self.theme.text or token.end <= from) continue;
                const range: d.Range = .{ .start = line_start + from, .end = line_start + token.end };
                if (self.markers.items.len != 0) {
                    const previous = &self.markers.items[self.markers.items.len - 1];
                    if (previous.color == color and previous.range.end == range.start) {
                        previous.range.end = range.end;
                        continue;
                    }
                }
                if (self.markers.items.len == budget) break :outer;
                try self.markers.append(self.allocator, .{ .range = range, .kind = .foreground, .color = color });
            }
        }
        if (extra.len == 0) return;
        try self.markers.appendSlice(self.allocator, extra);
        std.mem.sort(editing.RangeMarker, self.markers.items, {}, struct {
            fn less(_: void, a: editing.RangeMarker, b: editing.RangeMarker) bool {
                return a.range.start < b.range.start;
            }
        }.less);
    }
};

const plain_marker: u8 = 0;
/// One text run per line, for languages without a tokenizer.
const plain = syntax.Tokenizer{ .context = &plain_marker, .call = plainTokenize };
fn plainTokenize(_: *const anyopaque, line: []const u8, _: u64, out: *syntax.Output) u64 {
    out.add(line.len, .text);
    return 0;
}
