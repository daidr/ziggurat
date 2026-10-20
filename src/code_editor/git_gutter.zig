//! Changes against a base text in an editor's gutter, as the file's last
//! committed version: a bar beside lines added or modified and a wedge where
//! lines were deleted, with commands that go to the next or previous change
//! and put back the base lines of the changes the selections touch.
//!
//! The base and the comparison are explicit main-thread work over Document
//! snapshots; `update` compares again only when the text version changed.
const std = @import("std");
const d = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");
const editing = @import("ziggurat_document_editor");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const syntax = @import("ziggurat_code_syntax");

pub const Status = enum { unchanged, added, modified, deleted_above };
pub const Direction = enum { next, previous };

pub const GitGutter = struct {
    allocator: std.mem.Allocator,
    options: diff.Options,
    base: ?*d.Document = null,
    result: ?diff.Result = null,
    /// The text version and line count the hunks describe.
    text_version: ?u64 = null,
    lines: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: diff.Options) GitGutter {
        return .{ .allocator = allocator, .options = options };
    }
    pub fn deinit(self: *GitGutter) void {
        self.clear();
        self.* = undefined;
    }
    fn clear(self: *GitGutter) void {
        if (self.result) |*value| value.deinit();
        self.result = null;
        if (self.base) |value| value.close() catch {};
        self.base = null;
        self.text_version = null;
    }

    /// Compare against `text` from now on, or with null show no changes.
    pub fn setBase(self: *GitGutter, text: ?[]const u8) !void {
        const value = text orelse {
            self.clear();
            return;
        };
        const base = try d.Document.create(self.allocator, std.Thread.getCurrentId(), value, .{});
        self.clear();
        self.base = base;
    }

    /// Compare the document with the base again when its text changed.
    /// Returns whether the hunks changed. A comparison over the diff limits
    /// fails and leaves no hunks until a later update succeeds.
    pub fn update(self: *GitGutter, document: *d.Document) !bool {
        const base = self.base orelse return false;
        const version = try document.committedTextVersion();
        if (self.text_version == version) return false;
        if (self.result) |*value| value.deinit();
        self.result = null;
        self.text_version = null;
        const old = try base.snapshot();
        defer old.close() catch {};
        const new = try document.snapshot();
        defer new.close() catch {};
        const a = try old.borrowReader();
        defer a.release() catch {};
        const b = try new.borrowReader();
        defer b.release() catch {};
        self.result = try diff.compare(self.allocator, a, b, self.options);
        self.text_version = version;
        self.lines = try document.lineCount();
        return true;
    }

    pub fn hunks(self: *const GitGutter) []const diff.Hunk {
        return if (self.result) |value| value.hunks else &.{};
    }

    /// How the gutter marks line `line` of the document.
    pub fn status(self: *const GitGutter, line: usize) Status {
        const list = self.hunks();
        var low: usize = 0;
        var high = list.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const b = list[middle].b.lines;
            if (b.end > line or b.start >= line) high = middle else low = middle + 1;
        }
        if (low < list.len) {
            const hunk = list[low];
            const b = hunk.b.lines;
            if (b.start <= line and line < b.end) return if (hunk.a.lines.start == hunk.a.lines.end) .added else .modified;
            if (b.start == b.end and b.start == line) return .deleted_above;
        }
        // Lines deleted after the last line show on it.
        if (list.len != 0 and self.lines != 0 and line == self.lines - 1) {
            const last = list[list.len - 1].b.lines;
            if (last.start == last.end and last.start > line) return .deleted_above;
        }
        return .unchanged;
    }

    /// The line a caret on `line` goes to for the next or previous change,
    /// wrapping around, or null without changes.
    pub fn hunkTarget(self: *const GitGutter, line: usize, direction: Direction) ?usize {
        const list = self.hunks();
        if (list.len == 0) return null;
        const last_line = self.lines -| 1;
        switch (direction) {
            .next => {
                for (list) |hunk| if (hunk.b.lines.start > line) return @min(hunk.b.lines.start, last_line);
                return @min(list[0].b.lines.start, last_line);
            },
            .previous => {
                var at = list.len;
                while (at > 0) {
                    at -= 1;
                    if (list[at].b.lines.start < line) return @min(list[at].b.lines.start, last_line);
                }
                return @min(list[list.len - 1].b.lines.start, last_line);
            },
        }
    }

    /// Move the caret to the start of the next or previous change.
    pub fn goToHunk(self: *const GitGutter, adapter: *editing.Adapter, direction: Direction) !bool {
        const document = try adapter.sourceDocument();
        const caret = (try document.selection()).caret;
        const target = self.hunkTarget(try document.lineAt(caret), direction) orelse return false;
        const start = (try document.line(target)).start;
        return adapter.setSelections(&.{.{ .anchor = start, .caret = start }}, 0);
    }

    /// Put back the base lines of every change the selections' lines touch,
    /// as one edit. Returns false when they touch none or the hunks are stale.
    pub fn revertHunks(self: *const GitGutter, adapter: *editing.Adapter) !bool {
        const base = self.base orelse return false;
        const document = try adapter.sourceDocument();
        if (self.text_version != try document.committedTextVersion()) return false;
        const count = try document.selectionCount();
        const selections = try self.allocator.alloc(d.Selection, count);
        defer self.allocator.free(selections);
        _ = try document.selections(selections);
        const list = self.hunks();
        var chosen: std.ArrayList(usize) = .empty;
        defer chosen.deinit(self.allocator);
        for (selections) |item| {
            const range = item.range();
            const from = try document.lineAt(range.start);
            var to = try document.lineAt(range.end);
            // A selection ending at a line's start leaves that line out.
            if (to > from and (try document.line(to)).start == range.end) to -= 1;
            for (list, 0..) |hunk, index| {
                const b = hunk.b.lines;
                const touches = (b.start <= to and (b.end > from or (b.start == b.end and b.start >= from))) or
                    (b.start == b.end and b.start >= self.lines -| 1 and to >= self.lines -| 1 and index == list.len - 1);
                if (touches and std.mem.indexOfScalar(usize, chosen.items, index) == null) try chosen.append(self.allocator, index);
            }
        }
        if (chosen.items.len == 0) return false;
        std.mem.sort(usize, chosen.items, {}, std.sort.asc(usize));
        var texts: std.ArrayList(u8) = .empty;
        defer texts.deinit(self.allocator);
        for (chosen.items) |index| {
            const a = list[index].a.bytes;
            const at = texts.items.len;
            try texts.resize(self.allocator, at + a.end - a.start);
            _ = try base.read(a, texts.items[at..]);
        }
        const edits = try self.allocator.alloc(d.Replacement, chosen.items.len);
        defer self.allocator.free(edits);
        var at: usize = 0;
        for (chosen.items, edits) |index, *edit| {
            const hunk = list[index];
            const length = hunk.a.bytes.end - hunk.a.bytes.start;
            edit.* = .{ .range = hunk.b.bytes, .text = texts.items[at .. at + length] };
            at += length;
        }
        _ = try adapter.replaceMany(try document.version(), edits);
        return true;
    }

    /// Paint the change marks of the lines the editor shows, in the gutter
    /// column `bounds`, at the positions of the editor's prepared layout.
    /// Paint reads cached geometry only.
    pub fn paint(self: *const GitGutter, frame: *ui.Frame, adapter: *editing.Adapter, bounds: ui.Rect, theme: syntax.Theme) !void {
        if (self.hunks().len == 0) return;
        const document = try adapter.sourceDocument();
        const revision = try document.version();
        const lines = try document.lineCount();
        var line = (try adapter.viewportAnchor()).line;
        const x = bounds.x + bounds.width - 4;
        try frame.pushClip(bounds);
        defer frame.popClip() catch {};
        var next_rect: ?t.Rect = null;
        while (line < lines) : (line += 1) {
            const rect = next_rect orelse ((adapter.positionRect(revision, (try document.line(line)).start, .downstream) catch break) orelse break);
            if (rect.y > bounds.y + bounds.height) break;
            next_rect = if (line + 1 < lines) (adapter.positionRect(revision, (try document.line(line + 1)).start, .downstream) catch null) else null;
            // The bar spans every visual row of a wrapped line.
            const height = if (next_rect) |below| @max(rect.height, below.y - rect.y) else rect.height;
            switch (self.status(line)) {
                .unchanged => {},
                .added => frame.rect(.{ .x = x, .y = rect.y, .width = 3, .height = height }, theme.added),
                .modified => frame.rect(.{ .x = x, .y = rect.y, .width = 3, .height = height }, theme.modified),
                .deleted_above => {
                    // A wedge pointing into the text at the line's top.
                    var step: f32 = 0;
                    while (step < 3) : (step += 1) frame.rect(.{ .x = x - 1, .y = rect.y - 3 + step, .width = 2 + 2 * step, .height = 1 }, theme.deleted);
                    while (step < 6) : (step += 1) frame.rect(.{ .x = x - 1, .y = rect.y - 3 + step, .width = 2 + 2 * (5 - step), .height = 1 }, theme.deleted);
                },
            }
        }
    }
};
