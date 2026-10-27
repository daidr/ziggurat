//! The layout of one paragraph of attributed text: its spans broken into
//! lines at a width, measured with a view Measurer, as pieces of one style
//! each that draw as single-line labels. It answers what an editor asks of
//! a paragraph: where the caret before a rune is, which rune a point is
//! on, the edges of lines and graphemes, and the rectangles a selection
//! covers. Runes are Unicode scalar values, counted from the paragraph's
//! start.
const std = @import("std");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");

const Allocator = std.mem.Allocator;
pub const Font = view.Font;
pub const Rect = view.Rect;
pub const Point = view.Point;

/// How a span looks.
pub const Style = struct {
    font: Font = .{},
    /// Text color, RGB; null takes the color the paint is given.
    color: ?u32 = null,
    underline: bool = false,
    strikethrough: bool = false,
    /// Behind the span, with alpha.
    background: ?ui.Color = null,
    /// Rounds the background, which then hugs the glyphs.
    radius: f32 = 0,
    /// An object of this size takes the place of the span's one rune, an
    /// attachment, sitting on the baseline.
    object: ?struct { width: f32, height: f32 } = null,
};

pub const Span = struct {
    /// Copied by `build`.
    text: []const u8,
    style: Style = .{},
};

pub const Align = enum { start, center, end };

pub const Options = struct {
    measurer: view.Measurer = .{},
    /// The font of an empty paragraph's line.
    font: Font = .{},
    /// Width lines wrap at; 0 breaks no lines.
    width: f32 = 0,
    @"align": Align = .start,
};

pub const Affinity = enum { upstream, downstream };

/// A piece of one span on one line.
pub const Piece = struct {
    span: u32,
    /// Runes from the paragraph's start, and their bytes in `text`.
    rune: u32,
    runes: u32,
    start: u32,
    end: u32,
    /// From the line's left edge, as aligned.
    x: f32,
    width: f32,
    line: u32,
};

pub const Line = struct {
    y: f32,
    height: f32,
    /// The baseline below `y`.
    baseline: f32,
    /// Left edge, as aligned, and width without the spaces that end it.
    x: f32,
    width: f32,
    /// Runes of the line: from `start` to `end`, the spaces that end it
    /// included.
    start: u32,
    end: u32,
    first_piece: u32,
    pieces_end: u32,
};

pub const Caret = struct { x: f32, y: f32, height: f32 };

const Metrics = struct { height: f32, ascent: f32, size: f32 };

/// A word with the spaces after it, or a character lines break around.
const Word = struct {
    span: u32,
    rune: u32,
    runes: u32,
    start: u32,
    end: u32,
    width: f32,
    /// Without the spaces that end it.
    visible: f32,
    /// No line may break after it: the next span continues the word.
    glued: bool = false,
    cluster: f32 = 0,
};

const SpanInfo = struct { start: u32, end: u32, rune: u32, style: Style };

pub const Layout = struct {
    allocator: Allocator,
    options: Options = .{},
    text: std.ArrayList(u8) = .empty,
    /// Byte offset of each rune, and of the end.
    offsets: std.ArrayList(u32) = .empty,
    spans: std.ArrayList(SpanInfo) = .empty,
    metrics: std.ArrayList(Metrics) = .empty,
    words: std.ArrayList(Word) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    lines: std.ArrayList(Line) = .empty,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: Allocator) Layout {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Layout) void {
        self.text.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.metrics.deinit(self.allocator);
        self.words.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    /// Lays out `spans`, copying them.
    pub fn build(self: *Layout, spans: []const Span, options: Options) !void {
        const allocator = self.allocator;
        self.options = options;
        self.text.clearRetainingCapacity();
        self.offsets.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.metrics.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
        self.pieces.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
        for (spans) |s| {
            if (s.text.len == 0) continue;
            const start: u32 = @intCast(self.text.items.len);
            const rune: u32 = @intCast(self.offsets.items.len);
            try self.text.appendSlice(allocator, s.text);
            var i: usize = 0;
            while (i < s.text.len) {
                try self.offsets.append(allocator, start + @as(u32, @intCast(i)));
                i += std.unicode.utf8ByteSequenceLength(s.text[i]) catch 1;
            }
            try self.spans.append(allocator, .{ .start = start, .end = @intCast(self.text.items.len), .rune = rune, .style = s.style });
            try self.metrics.append(allocator, self.measureFont(s.style));
        }
        try self.offsets.append(allocator, @intCast(self.text.items.len));
        try self.metrics.append(allocator, self.measureFont(.{ .font = options.font }));
        for (0..self.spans.items.len) |k| try self.split(@intCast(k));
        self.glue();
        try self.wrap();
    }

    /// Runes of the paragraph.
    pub fn runeCount(self: *const Layout) u32 {
        return @intCast(self.offsets.items.len - 1);
    }

    /// The byte of rune i.
    pub fn byteOf(self: *const Layout, i: u32) u32 {
        return self.offsets.items[@min(i, self.runeCount())];
    }

    pub fn styleOf(self: *const Layout, piece: Piece) Style {
        return self.spans.items[piece.span].style;
    }

    /// The text of a piece, without the spaces that end its line.
    pub fn pieceText(self: *const Layout, piece: Piece) []const u8 {
        return self.text.items[piece.start..piece.end];
    }

    pub fn fontMetrics(self: *const Layout, span: u32) Metrics {
        return self.metrics.items[span];
    }

    fn measureFont(self: *const Layout, style: Style) Metrics {
        const height = self.options.measurer.textSize("Ag", style.font).height;
        // Labels center their text vertically; the baseline sits a little
        // below the middle.
        var m: Metrics = .{ .height = height, .ascent = height / 2 + style.font.size * 0.35, .size = style.font.size };
        if (style.object) |o| {
            m.ascent = @max(m.ascent, o.height);
            m.height = m.ascent + (height - (height / 2 + style.font.size * 0.35));
        }
        return m;
    }

    fn measure(self: *const Layout, span: u32, start: u32, end: u32) f32 {
        const s = self.spans.items[span];
        if (s.style.object) |o| return if (end > start) o.width else 0;
        if (end <= start) return 0;
        return self.options.measurer.textSize(self.text.items[start..end], s.style.font).width;
    }

    fn split(self: *Layout, k: u32) !void {
        const s = self.spans.items[k];
        const text = self.text.items;
        var at = s.start;
        var rune = s.rune;
        while (at < s.end) {
            const start = at;
            const first_rune = rune;
            // The word: up to a space, or one character lines break around.
            while (at < s.end and !isSpace(text[at])) {
                const length: u32 = @intCast(sequenceLength(text[at]));
                if (s.style.object != null or breaksAround(decode(text[at..@min(s.end, at + length)]))) {
                    if (at == start) {
                        at += length;
                        rune += 1;
                    }
                    break;
                }
                at += length;
                rune += 1;
            }
            const visible_end = at;
            while (at < s.end and isSpace(text[at])) {
                at += 1;
                rune += 1;
            }
            const visible = self.measure(k, start, visible_end);
            const width = if (at > visible_end) self.measure(k, start, at) else visible;
            try self.words.append(self.allocator, .{ .span = k, .rune = first_rune, .runes = rune - first_rune, .start = start, .end = at, .width = width, .visible = visible });
        }
    }

    fn glue(self: *Layout) void {
        const words = self.words.items;
        const text = self.text.items;
        for (words, 0..) |*w, i| {
            if (i + 1 == words.len) continue;
            const next = words[i + 1];
            if (next.span == w.span) continue;
            if (self.spans.items[w.span].style.object != null or self.spans.items[next.span].style.object != null) continue;
            const last = lastCodepoint(text[w.start..w.end]);
            w.glued = !isSpace(text[w.end - 1]) and !breaksAround(last) and !isSpace(text[next.start]) and !breaksAround(decode(text[next.start..@min(next.end, next.start + @as(u32, @intCast(sequenceLength(text[next.start]))))]));
        }
        var i = words.len;
        while (i > 0) {
            i -= 1;
            const w = &words[i];
            w.cluster = if (w.glued) w.width + words[i + 1].cluster else w.visible;
        }
    }

    fn wrap(self: *Layout) !void {
        const width = self.options.width;
        var x: f32 = 0;
        var trailing: f32 = 0;
        var line_start: u32 = 0;
        var line_pieces: u32 = 0;
        var widest: f32 = 0;
        var i: usize = 0;
        while (i < self.words.items.len) : (i += 1) {
            var w = self.words.items[i];
            const starts_cluster = i == 0 or !self.words.items[i - 1].glued;
            if (width > 0 and x > 0 and ((starts_cluster and x + w.cluster > width) or (!starts_cluster and x + w.visible > width))) {
                try self.finishLine(&line_start, w.rune, &line_pieces, x - trailing, &widest);
                x = 0;
                trailing = 0;
            }
            // A word wider than the line breaks between its characters.
            if (width > 0 and x == 0 and w.visible > width and w.runes > 1) {
                const cut = self.fit(w, width);
                if (cut.runes < w.runes) {
                    try self.place(.{ .span = w.span, .rune = w.rune, .runes = cut.runes, .start = w.start, .end = cut.byte, .width = cut.width, .visible = cut.width }, x);
                    try self.finishLine(&line_start, w.rune + cut.runes, &line_pieces, cut.width, &widest);
                    const rest: Word = .{ .span = w.span, .rune = w.rune + cut.runes, .runes = w.runes - cut.runes, .start = cut.byte, .end = w.end, .width = 0, .visible = 0, .glued = w.glued };
                    w = rest;
                    w.visible = self.measure(w.span, w.start, self.visibleEnd(w));
                    w.width = self.measure(w.span, w.start, w.end);
                    w.cluster = w.visible;
                    self.words.items[i] = w;
                    i -= 1;
                    continue;
                }
            }
            try self.place(w, x);
            x += w.width;
            trailing = w.width - w.visible;
        }
        try self.finishLine(&line_start, self.runeCount(), &line_pieces, x - trailing, &widest);
        self.width = widest;
        const last = self.lines.items[self.lines.items.len - 1];
        self.height = last.y + last.height;
        // Alignment.
        if (width > 0 and self.options.@"align" != .start) {
            for (self.lines.items) |*line| {
                const room = @max(0, width - line.width);
                line.x = if (self.options.@"align" == .center) room / 2 else room;
            }
        }
    }

    fn visibleEnd(self: *const Layout, w: Word) u32 {
        var end = w.end;
        while (end > w.start and isSpace(self.text.items[end - 1])) end -= 1;
        return end;
    }

    /// The most runes of `w` that fit `width`, at least one.
    fn fit(self: *const Layout, w: Word, width: f32) struct { runes: u32, byte: u32, width: f32 } {
        var runes: u32 = 1;
        var byte = self.byteOf(w.rune + 1);
        var fitted = self.measure(w.span, w.start, byte);
        while (runes < w.runes) {
            const next = self.byteOf(w.rune + runes + 1);
            const m = self.measure(w.span, w.start, next);
            if (m > width) break;
            runes += 1;
            byte = next;
            fitted = m;
        }
        return .{ .runes = runes, .byte = byte, .width = fitted };
    }

    fn place(self: *Layout, w: Word, x: f32) !void {
        const line: u32 = @intCast(self.lines.items.len);
        const pieces = self.pieces.items;
        if (pieces.len > 0) {
            const last = &pieces[pieces.len - 1];
            if (last.line == line and last.span == w.span and last.end == w.start and self.spans.items[w.span].style.object == null) {
                last.end = w.end;
                last.runes += w.runes;
                last.width = self.measure(w.span, last.start, last.end);
                return;
            }
        }
        try self.pieces.append(self.allocator, .{ .span = w.span, .rune = w.rune, .runes = w.runes, .start = w.start, .end = w.end, .x = x, .width = w.width, .line = line });
    }

    fn finishLine(self: *Layout, line_start: *u32, end: u32, line_pieces: *u32, width: f32, widest: *f32) !void {
        const pieces = self.pieces.items[line_pieces.*..];
        const base = self.metrics.items[self.metrics.items.len - 1];
        var ascent: f32 = if (pieces.len == 0) base.ascent else 0;
        var descent: f32 = if (pieces.len == 0) base.height - base.ascent else 0;
        for (pieces) |p| {
            const m = self.metrics.items[p.span];
            ascent = @max(ascent, m.ascent);
            descent = @max(descent, m.height - m.ascent);
        }
        const y = if (self.lines.items.len == 0) 0 else blk: {
            const previous = self.lines.items[self.lines.items.len - 1];
            break :blk previous.y + previous.height;
        };
        try self.lines.append(self.allocator, .{ .y = y, .height = ascent + descent, .baseline = ascent, .x = 0, .width = @max(0, width), .start = line_start.*, .end = end, .first_piece = line_pieces.*, .pieces_end = @intCast(self.pieces.items.len) });
        widest.* = @max(widest.*, @max(0, width));
        line_pieces.* = @intCast(self.pieces.items.len);
        line_start.* = end;
    }

    // ---- Queries ----------------------------------------------------------

    /// The line of the caret before rune i: at the edge of two lines,
    /// upstream is the end of the first and downstream the start of the
    /// second.
    pub fn lineOf(self: *const Layout, i: u32, affinity: Affinity) u32 {
        const lines = self.lines.items;
        var k: u32 = 0;
        while (k + 1 < lines.len) : (k += 1) {
            const end = lines[k].end;
            if (i < end or (i == end and affinity == .upstream)) return k;
        }
        return @intCast(lines.len - 1);
    }

    /// x of the caret before rune i on line k, from the layout's left.
    fn xOn(self: *const Layout, k: u32, i: u32) f32 {
        const line = self.lines.items[k];
        if (line.first_piece == line.pieces_end) return line.x;
        const pieces = self.pieces.items[line.first_piece..line.pieces_end];
        for (pieces, 0..) |p, n| {
            if (i < p.rune + p.runes or n + 1 == pieces.len) {
                if (i <= p.rune) return line.x + p.x;
                return line.x + p.x + self.measure(p.span, p.start, self.byteOf(@min(i, p.rune + p.runes)));
            }
        }
        unreachable;
    }

    /// The caret before rune i.
    pub fn caret(self: *const Layout, i: u32, affinity: Affinity) Caret {
        const k = self.lineOf(@min(i, self.runeCount()), affinity);
        const line = self.lines.items[k];
        return .{ .x = self.xOn(k, @min(i, self.runeCount())), .y = line.y, .height = line.height };
    }

    /// The caret position nearest a point local to the layout.
    pub fn hit(self: *const Layout, point: Point) struct { rune: u32, affinity: Affinity } {
        const lines = self.lines.items;
        var k: u32 = 0;
        while (k + 1 < lines.len and point.y >= lines[k].y + lines[k].height) k += 1;
        const line = lines[k];
        const last_line = k + 1 == lines.len;
        // The end of a wrapped line is before the spaces that end it.
        var end = line.end;
        if (!last_line) {
            while (end > line.start and isSpace(self.text.items[self.byteOf(end - 1)])) end -= 1;
            if (end == line.start) end = line.end;
        }
        if (point.x <= line.x) return .{ .rune = line.start, .affinity = .downstream };
        for (self.pieces.items[line.first_piece..line.pieces_end]) |p| {
            const left = line.x + p.x;
            if (point.x >= left + p.width and p.rune + p.runes < end) continue;
            // Within the piece: the nearest edge of a rune.
            var r = p.rune;
            var prev_x = left;
            while (r < p.rune + p.runes and r < end) {
                const next_x = left + self.measure(p.span, p.start, self.byteOf(r + 1));
                if (point.x < (prev_x + next_x) / 2) break;
                prev_x = next_x;
                r += 1;
            }
            if (r >= end and !last_line) return .{ .rune = end, .affinity = .upstream };
            return .{ .rune = r, .affinity = .downstream };
        }
        return .{ .rune = end, .affinity = if (last_line) .downstream else .upstream };
    }

    /// The rectangle line k covers of the runes from a to b, local to the
    /// layout, or null when it holds none of them.
    pub fn selectionRect(self: *const Layout, k: u32, a: u32, b: u32) ?Rect {
        const line = self.lines.items[k];
        const from = @max(a, line.start);
        const to = @min(b, line.end);
        if (from >= to and !(from == to and a < b and line.start == line.end and a <= line.start and b >= line.end)) return null;
        const x0 = self.xOn(k, from);
        const x1 = self.xOn(k, to);
        return .{ .x = x0, .y = line.y, .width = @max(0, x1 - x0), .height = line.height };
    }

    /// The edge of the grapheme after rune i.
    pub fn nextBoundary(self: *const Layout, i: u32) u32 {
        const n = self.runeCount();
        if (i >= n) return n;
        var r = i + 1;
        const first = self.runeAt(i);
        if (isRegional(first) and r < n and isRegional(self.runeAt(r))) r += 1;
        while (r < n) {
            const c = self.runeAt(r);
            if (extends(c)) {
                r += 1;
            } else if (self.runeAt(r - 1) == 0x200d) {
                r += 1;
            } else break;
        }
        return r;
    }

    /// The edge of the grapheme before rune i.
    pub fn previousBoundary(self: *const Layout, i: u32) u32 {
        if (i == 0) return 0;
        var r: u32 = 0;
        var last: u32 = 0;
        // From the start of the line, graphemes forward.
        const k = self.lineOf(i, .upstream);
        r = self.lines.items[k].start;
        if (r >= i) r = 0;
        while (r < i) {
            last = r;
            r = self.nextBoundary(r);
        }
        return last;
    }

    pub fn runeAt(self: *const Layout, i: u32) u21 {
        const at = self.byteOf(i);
        return decode(self.text.items[at..@min(self.text.items.len, at + sequenceLength(self.text.items[at]))]);
    }

    /// The objects of the layout: where each object rune sits.
    pub fn objectRect(self: *const Layout, p: Piece) ?Rect {
        const o = self.spans.items[p.span].style.object orelse return null;
        const line = self.lines.items[p.line];
        return .{ .x = line.x + p.x, .y = line.y + line.baseline - o.height, .width = o.width, .height = o.height };
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}
fn sequenceLength(byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(byte) catch 1;
}
fn decode(bytes: []const u8) u21 {
    return std.unicode.utf8Decode(bytes) catch 0xfffd;
}
fn lastCodepoint(text: []const u8) u21 {
    var start = text.len - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return decode(text[start..]);
}
/// Characters a line may break before or after, as in CJK text.
pub fn breaksAround(codepoint: u21) bool {
    return switch (codepoint) {
        0x1100...0x115f, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xa000...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f, 0xff00...0xff60, 0xffe0...0xffe6, 0x20000...0x3fffd => true,
        else => false,
    };
}
/// Marks that extend the grapheme before them.
fn extends(c: u21) bool {
    return switch (c) {
        0x0300...0x036f, 0x0483...0x0489, 0x0591...0x05bd, 0x0610...0x061a, 0x064b...0x065f, 0x0670, 0x06d6...0x06dc, 0x0900...0x0903, 0x093a...0x094f, 0x0951...0x0957, 0x0962, 0x0963, 0x0e31, 0x0e34...0x0e3a, 0x0e47...0x0e4e, 0x1ab0...0x1aff, 0x1dc0...0x1dff, 0x200c, 0x200d, 0x20d0...0x20ff, 0xfe00...0xfe0f, 0xfe20...0xfe2f, 0x1f3fb...0x1f3ff, 0xe0020...0xe007f, 0xe0100...0xe01ef => true,
        else => false,
    };
}
fn isRegional(c: u21) bool {
    return c >= 0x1f1e6 and c <= 0x1f1ff;
}
