//! Markdown for attributed text, CommonMark with GitHub's extensions, and
//! attributed text from Markdown.
const std = @import("std");
const zio = @import("ziggurat_io");
const tx = @import("text.zig");
const md = @import("ziggurat_markdown");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Text = tx.Text;
const Attributes = tx.Attributes;
const ParagraphStyle = tx.ParagraphStyle;

// ---- Writing --------------------------------------------------------------

/// Writes `t` as CommonMark with GitHub's extensions: headings, lists and
/// task lists, quotations, fenced blocks of code, **bold**, *italic*,
/// ~~strikethrough~~, `code`, links and images; underlines are HTML's <u>,
/// which Markdown keeps. Body paragraphs are apart by a blank line, so
/// that they stay paragraphs; alignment, fonts and colors have no Markdown
/// and are left out.
pub fn write(allocator: Allocator, t: *const Text, w: *Writer) !void {
    // The items of the numbered lists open, by level.
    var numbers: [tx.max_indent + 1]u32 = @splat(0);
    var levels: usize = 0;
    var prev_list = false;
    const count = t.paragraphCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const p = t.para(i);
        const st = p.style;
        if (i > 0 and !(st.list != .none and prev_list)) {
            try w.writeAll("\n\n");
        } else if (i > 0) try w.writeByte('\n');
        prev_list = st.list != .none;
        if (st.list == .none) levels = 0;
        const quote: []const u8 = if (st.quote) "> " else "";
        if (st.code_block) {
            var fence_len: usize = 3;
            var k = i;
            while (k < count and t.para(k).style.code_block) : (k += 1) {
                while (containsRun(t.para(k).text(), '`', fence_len)) fence_len += 1;
            }
            try w.print("{s}", .{quote});
            try w.splatByteAll('`', fence_len);
            try w.writeByte('\n');
            while (i < count and t.para(i).style.code_block) : (i += 1) {
                try w.print("{s}{s}\n", .{ quote, t.para(i).text() });
            }
            i -= 1;
            try w.print("{s}", .{quote});
            try w.splatByteAll('`', fence_len);
            continue;
        }
        if (st.heading > 0) {
            try w.writeAll(quote);
            try w.splatByteAll('#', @min(st.heading, 6));
            try w.writeByte(' ');
        } else if (st.list != .none) {
            const level: usize = st.indent;
            while (levels <= level) : (levels += 1) numbers[levels] = 0;
            levels = level + 1;
            try w.writeAll(quote);
            try w.splatBytesAll("    ", level);
            switch (st.list) {
                .numbers => {
                    numbers[level] += 1;
                    try w.print("{d}. ", .{numbers[level]});
                },
                .tasks => {
                    try w.writeAll(if (st.checked) "- [x] " else "- [ ] ");
                    numbers[level] = 0;
                },
                else => {
                    try w.writeAll("- ");
                    numbers[level] = 0;
                },
            }
        } else try w.writeAll(quote);
        const runs = try paragraphRuns(allocator, p);
        defer allocator.free(runs);
        if (st.heading > 0) {
            // A heading's closing #s are not its text: escape them.
            var h: Writer.Allocating = .init(allocator);
            defer h.deinit();
            try writeRuns(allocator, runs, &h.writer);
            const s = h.written();
            const k = std.mem.trimEnd(u8, s, "#").len;
            try w.writeAll(s[0..k]);
            if (k < s.len) try w.writeByte('\\');
            try w.writeAll(s[k..]);
            continue;
        }
        try writeRuns(allocator, runs, w);
    }
}

/// `t` as Markdown, allocated.
pub fn markdown(allocator: Allocator, t: *const Text) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(allocator, t, &out.writer) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |e| e,
    };
    return out.toOwnedSlice();
}

fn containsRun(s: []const u8, c: u8, n: usize) bool {
    var run: usize = 0;
    for (s) |b| {
        if (b == c) {
            run += 1;
            if (run >= n) return true;
        } else run = 0;
    }
    return false;
}

fn paragraphRuns(allocator: Allocator, p: *const tx.Para) ![]tx.Run {
    var out: std.ArrayList(tx.Run) = .empty;
    errdefer out.deinit(allocator);
    var it = p.iterator();
    while (it.next()) |item| try out.append(allocator, item.run);
    return out.toOwnedSlice(allocator);
}

/// A Markdown mark around runs, from the outside in. Code is a span of
/// each run, fenced as its backticks need.
const Mark = struct {
    kind: u8, // 'a', 'b', 'i', 's', 'u'
    url: []const u8 = "",

    fn eql(a: Mark, b: Mark) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.url, b.url);
    }
    /// The mark's opening, as HTML when `as_html`: what Markdown cannot
    /// open or close where it is.
    fn open(self: Mark, as_html: bool) []const u8 {
        return switch (self.kind) {
            'a' => "[",
            'b' => if (as_html) "<strong>" else "**",
            'i' => if (as_html) "<em>" else "*",
            's' => if (as_html) "<del>" else "~~",
            'u' => "<u>",
            else => "",
        };
    }
    fn writeClose(self: Mark, as_html: bool, w: *Writer) Writer.Error!void {
        switch (self.kind) {
            'a' => {
                try w.writeAll("](");
                try writeUrl(w, self.url);
                try w.writeByte(')');
            },
            'u' => try w.writeAll("</u>"),
            'b' => try w.writeAll(if (as_html) "</strong>" else "**"),
            'i' => try w.writeAll(if (as_html) "</em>" else "*"),
            's' => try w.writeAll(if (as_html) "</del>" else "~~"),
            else => {},
        }
    }
};

fn marksOf(a: Attributes, out: *[5]Mark) []Mark {
    var n: usize = 0;
    if (a.link.len > 0) {
        out[n] = .{ .kind = 'a', .url = a.link };
        n += 1;
    }
    if (a.bold()) {
        out[n] = .{ .kind = 'b' };
        n += 1;
    }
    if (a.italic) {
        out[n] = .{ .kind = 'i' };
        n += 1;
    }
    if (a.strikethrough) {
        out[n] = .{ .kind = 's' };
        n += 1;
    }
    if (a.underline) {
        out[n] = .{ .kind = 'u' };
        n += 1;
    }
    return out[0..n];
}

/// Names a mark written in Markdown: the run it opens at and its kind.
const DelimKey = struct { run: usize, kind: u8 };

/// Where a mark's delimiters are in what renderRuns wrote.
const Delim = struct {
    key: DelimKey,
    char: u8,
    open: usize,
    close: usize,
    length: usize,

    /// Whether the delimiters can open and close where they are, as
    /// CommonMark's rules of flanking say.
    fn flanks(self: Delim, s: []const u8) bool {
        return canFlank(s, self.open, self.length, self.char, true) and canFlank(s, self.close, self.length, self.char, false);
    }
};

fn canFlank(s: []const u8, at: usize, n: usize, c: u8, left: bool) bool {
    var from = at;
    var to = at + n;
    while (from > 0 and s[from - 1] == c) from -= 1;
    while (to < s.len and s[to] == c) to += 1;
    var before: u21 = ' ';
    var after: u21 = ' ';
    if (from > 0) before = lastRune(s[0..from]);
    if (to < s.len) after = tx.decodeAt(s, to).rune;
    if (!left) std.mem.swap(u21, &before, &after);
    // Left-flanking: not before whitespace, and not before punctuation
    // unless after whitespace or punctuation; right-flanking mirrored.
    return !isSpace(after) and (!isPunct(after) or isSpace(before) or isPunct(before));
}

fn lastRune(s: []const u8) u21 {
    var start = s.len - 1;
    while (start > 0 and s[start] & 0xc0 == 0x80) start -= 1;
    return tx.decodeAt(s, start).rune;
}

pub fn isSpace(r: u21) bool {
    return switch (r) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// Punctuation and symbols, as Markdown's flanking rules read them.
pub fn isPunct(r: u21) bool {
    if (r < 0x80) return switch (r) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
    return switch (r) {
        0xa1...0xbf, 0xd7, 0xf7, 0x2010...0x2027, 0x2030...0x205e, 0x20a0...0x20cf, 0x2100...0x214f, 0x2190...0x23ff, 0x2500...0x27bf, 0x2900...0x2bff, 0x2e00...0x2e7f, 0x3001...0x3003, 0x3008...0x3011, 0x3014...0x301f, 0xfe10...0xfe19, 0xfe30...0xfe6b, 0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65, 0x1f000...0x1faff => true,
        else => false,
    };
}

/// Writes runs with their marks, opening and closing them as they change,
/// whitespace outside them so that they flank words as CommonMark wants.
/// Where a delimiter cannot open or close, its mark is written as HTML,
/// which Markdown keeps: the runs written are read back to check, and
/// those still read otherwise are written in HTML whole. What would start
/// a block at the start of the paragraph is escaped.
fn writeRuns(allocator: Allocator, runs: []const tx.Run, w: *Writer) !void {
    var as_html: std.AutoHashMapUnmanaged(DelimKey, void) = .empty;
    defer as_html.deinit(allocator);
    var first = try render(allocator, runs, &as_html);
    defer first.deinit(allocator);
    if (first.delims.items.len > 0 and !try readsAs(allocator, first.s.items, runs)) {
        for (first.delims.items) |d| if (!d.flanks(first.s.items)) try as_html.put(allocator, d.key, {});
        if (as_html.count() > 0) {
            var second = try render(allocator, runs, &as_html);
            defer second.deinit(allocator);
            if (try readsAs(allocator, second.s.items, runs)) return w.writeAll(second.s.items) catch error.WriteFailed;
        }
        for (first.delims.items) |d| try as_html.put(allocator, d.key, {});
        var third = try render(allocator, runs, &as_html);
        defer third.deinit(allocator);
        return w.writeAll(third.s.items) catch error.WriteFailed;
    }
    w.writeAll(first.s.items) catch return error.WriteFailed;
}

const Rendered = struct {
    s: std.ArrayList(u8) = .empty,
    delims: std.ArrayList(Delim) = .empty,
    fn deinit(self: *Rendered, allocator: Allocator) void {
        self.s.deinit(allocator);
        self.delims.deinit(allocator);
    }
};

/// Writes runs, the marks of `as_html` in HTML, and where the delimiters
/// of the others are.
fn render(allocator: Allocator, runs: []const tx.Run, as_html: *const std.AutoHashMapUnmanaged(DelimKey, void)) !Rendered {
    var out: Rendered = .{};
    errdefer out.deinit(allocator);
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const b = &aw.writer;
    const Opened = struct { mark: Mark, key: DelimKey, at: usize };
    var open: std.ArrayList(Opened) = .empty;
    defer open.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var first = true;
    const Close = struct {
        fn to(o: *std.ArrayList(Opened), n: usize, wr: *Writer, h: *const std.AutoHashMapUnmanaged(DelimKey, void), delims: *std.ArrayList(Delim), alloc: Allocator) !void {
            while (o.items.len > n) {
                const item = o.pop().?;
                const as = h.contains(item.key);
                if (!as and (item.mark.kind == 'b' or item.mark.kind == 'i' or item.mark.kind == 's')) {
                    const text = item.mark.open(false);
                    try delims.append(alloc, .{ .key = item.key, .char = text[0], .open = item.at, .close = wr.end, .length = text.len });
                }
                try item.mark.writeClose(as, wr);
            }
        }
    };
    for (runs, 0..) |r, i| {
        if (r.attributes.attachment) |at| {
            try Close.to(&open, 0, b, as_html, &out.delims, allocator);
            try b.writeAll(pending.items);
            pending.clearRetainingCapacity();
            try b.writeAll("![");
            try escape(b, at.name);
            try b.writeAll("](");
            try writeUrl(b, at.url);
            try b.writeByte(')');
            first = false;
            continue;
        }
        const core = trimSpace(r.text);
        if (core.len == 0) {
            try pending.appendSlice(allocator, r.text);
            continue;
        }
        const lead_end = @intFromPtr(core.ptr) - @intFromPtr(r.text.ptr);
        const lead = r.text[0..lead_end];
        const trail = r.text[lead_end + core.len ..];
        var marks_buffer: [5]Mark = undefined;
        const want = marksOf(r.attributes, &marks_buffer);
        var k: usize = 0;
        while (k < open.items.len and k < want.len and open.items[k].mark.eql(want[k])) k += 1;
        try Close.to(&open, k, b, as_html, &out.delims, allocator);
        if (first) {
            // Spaces at the start would make a block of code.
            for (pending.items) |c| try writeLeadSpace(b, c);
            for (lead) |c| try writeLeadSpace(b, c);
            pending.clearRetainingCapacity();
        } else {
            try b.writeAll(pending.items);
            try b.writeAll(lead);
            pending.clearRetainingCapacity();
        }
        for (want[k..]) |m| {
            const key: DelimKey = .{ .run = i, .kind = m.kind };
            try open.append(allocator, .{ .mark = m, .key = key, .at = b.end });
            try b.writeAll(m.open(as_html.contains(key)));
        }
        if (r.attributes.code) {
            try writeCodeSpan(b, core);
        } else {
            var esc: Writer.Allocating = .init(allocator);
            defer esc.deinit();
            try escape(&esc.writer, core);
            var s = esc.written();
            var block_buffer: std.ArrayList(u8) = .empty;
            defer block_buffer.deinit(allocator);
            if (first) {
                try escapeBlockStart(allocator, s, &block_buffer);
                s = block_buffer.items;
            }
            if (std.mem.endsWith(u8, s, "!")) {
                // Not an image with a link after it.
                try b.writeAll(s[0 .. s.len - 1]);
                try b.writeAll("\\!");
            } else try b.writeAll(s);
        }
        first = false;
        try pending.appendSlice(allocator, trail);
    }
    try Close.to(&open, 0, b, as_html, &out.delims, allocator);
    try b.writeAll(pending.items);
    try out.s.appendSlice(allocator, aw.written());
    return out;
}

fn writeLeadSpace(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        ' ' => try w.writeAll("&#32;"),
        '\t' => try w.writeAll("&#9;"),
        else => try w.writeByte(c),
    }
}

fn trimSpace(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len) {
        const d = tx.decodeAt(s, a);
        if (!isSpace(d.rune)) break;
        a += d.len;
    }
    var z = s.len;
    while (z > a) {
        var start = z - 1;
        while (start > a and s[start] & 0xc0 == 0x80) start -= 1;
        if (!isSpace(tx.decodeAt(s, start).rune)) break;
        z = start;
    }
    return s[a..z];
}

/// Whether `s` reads back as `runs`, as far as Markdown keeps them.
fn readsAs(allocator: Allocator, s: []const u8, runs: []const tx.Run) !bool {
    var t = try parse(allocator, s);
    defer t.deinit();
    if (t.paragraphCount() != 1) return false;
    const got = try paragraphRuns(allocator, t.para(0));
    defer allocator.free(got);
    return sameMarks(got, runs);
}

const Marks = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
    under: bool = false,
    code: bool = false,
    link: []const u8 = "",
    name: []const u8 = "",
    url: []const u8 = "",
    fn of(a: Attributes) Marks {
        var m: Marks = .{ .bold = a.bold(), .italic = a.italic, .strike = a.strikethrough, .under = a.underline, .code = a.code, .link = a.link };
        if (a.attachment) |at| {
            m.name = at.name;
            m.url = at.url;
        }
        return m;
    }
    fn eql(a: Marks, b: Marks) bool {
        return a.bold == b.bold and a.italic == b.italic and a.strike == b.strike and a.under == b.under and a.code == b.code and
            std.mem.eql(u8, a.link, b.link) and std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.url, b.url);
    }
};

/// Walks the runes of runs with the marks Markdown keeps: none on
/// whitespace outside code, nor on the spaces ending the paragraph.
const MarkWalker = struct {
    runs: []const tx.Run,
    run: usize = 0,
    at: usize = 0,
    /// Runes left before the trailing spaces.
    left: usize,

    fn init(runs: []const tx.Run) MarkWalker {
        var total: usize = 0;
        for (runs) |r| total += tx.runeCount(r.text);
        // Spaces ending the paragraph do not show.
        var trailing: usize = 0;
        var k = runs.len;
        outer: while (k > 0) {
            k -= 1;
            const r = runs[k];
            var z = r.text.len;
            while (z > 0) {
                if (r.text[z - 1] != ' ' or r.attributes.code) break :outer;
                trailing += 1;
                z -= 1;
            }
        }
        return .{ .runs = runs, .left = total - trailing };
    }
    fn next(self: *MarkWalker) ?struct { rune: u21, marks: Marks } {
        if (self.left == 0) return null;
        while (self.run < self.runs.len and self.at >= self.runs[self.run].text.len) {
            self.run += 1;
            self.at = 0;
        }
        if (self.run >= self.runs.len) return null;
        const r = self.runs[self.run];
        const d = tx.decodeAt(r.text, self.at);
        self.at += d.len;
        self.left -= 1;
        var m = Marks.of(r.attributes);
        if (isSpace(d.rune) and !m.code) m = .{};
        return .{ .rune = d.rune, .marks = m };
    }
};

fn sameMarks(a: []const tx.Run, b: []const tx.Run) bool {
    var x = MarkWalker.init(a);
    var y = MarkWalker.init(b);
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null or q == null) return p == null and q == null;
        if (p.?.rune != q.?.rune or !p.?.marks.eql(q.?.marks)) return false;
    }
}

/// `s` as a code span, fenced by more backticks than any run of them in
/// it.
fn writeCodeSpan(w: *Writer, s: []const u8) Writer.Error!void {
    var longest: usize = 0;
    var n: usize = 0;
    for (s) |c| {
        if (c == '`') {
            n += 1;
            longest = @max(longest, n);
        } else n = 0;
    }
    try w.splatByteAll('`', longest + 1);
    const pad = std.mem.startsWith(u8, s, "`") or std.mem.endsWith(u8, s, "`");
    if (pad) try w.writeByte(' ');
    try w.writeAll(s);
    if (pad) try w.writeByte(' ');
    try w.splatByteAll('`', longest + 1);
}

/// Escapes what Markdown would read as marks.
pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s, 0..) |c, i| {
        switch (c) {
            '\\', '*', '_', '`', '[', ']', '<', '~' => try w.writeByte('\\'),
            // Not the start of an entity, as &amp; or &#38;.
            '&' => if (i + 1 < s.len and (s[i + 1] == '#' or std.ascii.isAlphabetic(s[i + 1]))) try w.writeByte('\\'),
            else => {},
        }
        try w.writeByte(c);
    }
}

/// Escapes the start of a body paragraph that Markdown would read as a
/// heading, a list, a quotation or a rule.
fn escapeBlockStart(allocator: Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    if (s.len > 0 and (s[0] == '#' or s[0] == '>' or s[0] == '-' or s[0] == '+' or s[0] == '=')) {
        try out.append(allocator, '\\');
        try out.appendSlice(allocator, s);
        return;
    }
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i > 0 and i < s.len and (s[i] == '.' or s[i] == ')')) {
        try out.appendSlice(allocator, s[0..i]);
        try out.append(allocator, '\\');
        try out.appendSlice(allocator, s[i..]);
        return;
    }
    try out.appendSlice(allocator, s);
}

/// A URL as the destination of a link.
fn writeUrl(w: *Writer, u: []const u8) Writer.Error!void {
    if (std.mem.indexOfAny(u8, u, " ()<>") == null) return w.writeAll(u);
    try w.writeByte('<');
    for (u) |c| switch (c) {
        '<' => try w.writeAll("%3C"),
        '>' => try w.writeAll("%3E"),
        else => try w.writeByte(c),
    };
    try w.writeByte('>');
}

// ---- Reading --------------------------------------------------------------

/// The attributed text of Markdown, CommonMark with GitHub's extensions:
/// headings, lists and task lists, quotations, blocks of code, bold,
/// italic, strikethrough, code, links, images, and the HTML tags of these
/// marks and of underlines, <u>. A list item's paragraphs after its first
/// are indented under it; a table's rows are paragraphs of their cells
/// apart by tabs, the header's bold. HTML blocks read as HTML.
pub fn parse(allocator: Allocator, source: []const u8) !Text {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Reader = .{ .arena = arena, .owner = allocator };
    // HTML blocks at the top level read as HTML; the rest as Markdown.
    var segments = Segments{ .s = source };
    while (segments.next()) |segment| {
        if (segment.html) {
            var t = try html.parse(allocator, segment.text);
            defer t.deinit();
            var p: u32 = 0;
            while (p < t.paragraphCount()) : (p += 1) {
                const q = t.para(p);
                const runs = try paragraphRuns(arena, q);
                for (runs) |*run| run.text = try arena.dupe(u8, run.text);
                for (runs) |*run| run.attributes = try copyAttributes(arena, run.attributes);
                try r.paras.append(arena, .{ .style = q.style, .runs = runs });
            }
            continue;
        }
        try r.document(segment.text);
    }
    if (r.paras.items.len == 0) return Text.init(allocator);
    return Text.of(allocator, r.paras.items);
}

fn copyAttributes(arena: Allocator, a: Attributes) !Attributes {
    var out = a;
    out.font = try arena.dupe(u8, a.font);
    out.link = try arena.dupe(u8, a.link);
    out.tag = try arena.dupe(u8, a.tag);
    if (a.attachment) |at| {
        const copy = try arena.create(tx.Attachment);
        copy.* = at.*;
        copy.name = try arena.dupe(u8, at.name);
        copy.url = try arena.dupe(u8, at.url);
        copy.image = try arena.dupe(u8, at.image);
        out.attachment = copy;
    }
    return out;
}

/// Splits Markdown into runs of lines that are HTML blocks, which start
/// at the margin with a block tag and end at a blank line, and the rest.
const Segments = struct {
    s: []const u8,
    at: usize = 0,
    fence: bool = false,

    const Segment = struct { text: []const u8, html: bool };

    fn next(self: *Segments) ?Segment {
        if (self.at >= self.s.len) return null;
        const start = self.at;
        var html_block = false;
        while (self.at < self.s.len) {
            const line_end = std.mem.indexOfScalarPos(u8, self.s, self.at, '\n') orelse self.s.len;
            const line = self.s[self.at..line_end];
            const fence_line = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```") or std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "~~~");
            if (fence_line) self.fence = !self.fence;
            const blank = std.mem.trim(u8, line, " \t\r").len == 0;
            const starts_html = !self.fence and !fence_line and htmlBlockStart(line) and (self.at == 0 or self.at == start or self.previousBlank());
            if (starts_html and self.at > start) {
                // Markdown before the HTML block.
                return .{ .text = self.s[start..self.at], .html = false };
            }
            if (starts_html) html_block = true;
            self.at = @min(self.s.len, line_end + 1);
            if (html_block and blank) return .{ .text = self.s[start..self.at], .html = true };
        }
        return .{ .text = self.s[start..self.at], .html = html_block };
    }

    fn previousBlank(self: *const Segments) bool {
        if (self.at < 2) return true;
        var k = self.at - 1; // the newline ending the previous line
        var blank = true;
        while (k > 0) {
            k -= 1;
            const c = self.s[k];
            if (c == '\n') break;
            if (c != ' ' and c != '\t' and c != '\r') blank = false;
        }
        return blank;
    }
};

const block_tags = [_][]const u8{ "address", "article", "aside", "blockquote", "center", "details", "div", "dl", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "ul" };

/// Whether a line starts an HTML block: a block tag at the margin.
fn htmlBlockStart(line: []const u8) bool {
    if (line.len < 2 or line[0] != '<') return false;
    var at: usize = 1;
    if (line[at] == '/') at += 1;
    const name_start = at;
    while (at < line.len and std.ascii.isAlphanumeric(line[at])) at += 1;
    const name = line[name_start..at];
    if (name.len == 0 or (at < line.len and line[at] != '>' and line[at] != ' ' and line[at] != '/' and line[at] != '\t' and line[at] != '\r')) return false;
    for (block_tags) |tag| if (std.ascii.eqlIgnoreCase(tag, name)) return true;
    return false;
}

/// Inline HTML tags Markdown keeps, standing in its source for private
/// characters the tree's text then holds.
const sentinel_base: u21 = 0xe000;
const inline_tags = [_]struct { name: []const u8, which: u8 }{
    .{ .name = "u", .which = 0 },      .{ .name = "ins", .which = 0 },
    .{ .name = "s", .which = 1 },      .{ .name = "strike", .which = 1 },
    .{ .name = "del", .which = 1 },    .{ .name = "b", .which = 2 },
    .{ .name = "strong", .which = 2 }, .{ .name = "i", .which = 3 },
    .{ .name = "em", .which = 3 },     .{ .name = "br", .which = 4 },
};

/// Replaces the inline tags of `s` outside code with sentinels: an opening
/// tag of kind k becomes U+E000+2k, its closing tag U+E001+2k; other tags
/// go, as a browser shows none.
fn markTags(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var fence = false;
    var line_start = true;
    while (at < s.len) {
        if (line_start) {
            const rest = std.mem.trimStart(u8, s[at..], " ");
            if (std.mem.startsWith(u8, rest, "```") or std.mem.startsWith(u8, rest, "~~~")) fence = !fence;
            const indent = s.len - at - rest.len;
            if (fence or indent >= 4) {
                const end = std.mem.indexOfScalarPos(u8, s, at, '\n') orelse s.len;
                try out.appendSlice(arena, s[at..@min(s.len, end + 1)]);
                at = @min(s.len, end + 1);
                continue;
            }
        }
        const c = s[at];
        line_start = c == '\n';
        if (c == '\\' and at + 1 < s.len) {
            try out.appendSlice(arena, s[at .. at + 2]);
            line_start = s[at + 1] == '\n';
            at += 2;
            continue;
        }
        if (c == '`') {
            // A code span: copy through its closing run of backticks.
            var n: usize = 0;
            while (at + n < s.len and s[at + n] == '`') n += 1;
            var k = at + n;
            var closed: ?usize = null;
            while (k < s.len) {
                if (s[k] == '`') {
                    var m: usize = 0;
                    while (k + m < s.len and s[k + m] == '`') m += 1;
                    if (m == n) {
                        closed = k + m;
                        break;
                    }
                    k += m;
                } else k += 1;
            }
            const end = closed orelse at + n;
            try out.appendSlice(arena, s[at..end]);
            line_start = false;
            at = end;
            continue;
        }
        if (c == '<') {
            if (tagAt(s, at)) |t| {
                if (t.which) |which| {
                    var buffer: [4]u8 = undefined;
                    const rune: u21 = if (which == 4) sentinel_base + 8 else sentinel_base + 2 * @as(u21, which) + @intFromBool(t.closing);
                    const n = std.unicode.utf8Encode(rune, &buffer) catch unreachable;
                    try out.appendSlice(arena, buffer[0..n]);
                }
                at = t.end;
                continue;
            }
        }
        try out.append(arena, c);
        at += 1;
    }
    return out.items;
}

const TagAt = struct { which: ?u8, closing: bool, end: usize };

/// An inline HTML tag at `at`: a name of letters, attributes, and its end.
fn tagAt(s: []const u8, at: usize) ?TagAt {
    var k = at + 1;
    var closing = false;
    if (k < s.len and s[k] == '/') {
        closing = true;
        k += 1;
    }
    const name_start = k;
    while (k < s.len and std.ascii.isAlphanumeric(s[k])) k += 1;
    const name = s[name_start..k];
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return null;
    // Attributes, up to the end of the tag on its line.
    while (k < s.len and s[k] != '>') : (k += 1) {
        if (s[k] == '<' or s[k] == '\n') return null;
    }
    if (k >= s.len) return null;
    const between = s[name_start + name.len .. k];
    if (between.len > 0 and between[0] != ' ' and between[0] != '/' and between[0] != '\t') return null;
    var which: ?u8 = null;
    for (inline_tags) |tag| if (std.ascii.eqlIgnoreCase(tag.name, name)) {
        which = tag.which;
    };
    // Autolinks are not tags.
    if (std.mem.indexOfScalar(u8, s[at..k], ':') != null or std.mem.indexOfScalar(u8, s[at..k], '@') != null) return null;
    return .{ .which = which, .closing = closing, .end = k + 1 };
}

const Reader = struct {
    arena: Allocator,
    owner: Allocator,
    paras: std.ArrayList(tx.Paragraph) = .empty,
    tree: md.Tree = undefined,
    /// The inline HTML tags open, by the attribute they turn on: <u>, <s>,
    /// <b> and <i>.
    open: [4]u32 = @splat(0),

    fn document(self: *Reader, source: []const u8) !void {
        const marked = try markTags(self.arena, source);
        var node_capacity: usize = marked.len + 64;
        var text_capacity: usize = marked.len * 2 + 256;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            const nodes = try self.arena.alloc(md.Node, node_capacity);
            const text_buffer = try self.arena.alloc(u8, text_capacity);
            if (md.parse(marked, .{ .nodes = nodes, .text = text_buffer })) |tree| {
                self.tree = tree;
                break;
            } else |err| switch (err) {
                error.TooManyNodes, error.TextFull => {
                    if (attempts == 4) return err;
                    node_capacity *= 2;
                    text_capacity *= 2;
                },
                else => return err,
            }
        }
        try self.blocks(0, .{}, -1);
    }

    fn blocks(self: *Reader, index: u32, st: ParagraphStyle, depth: i32) anyerror!void {
        var it = self.tree.children(index);
        while (it.next()) |k| try self.block(k, st, depth);
    }

    fn block(self: *Reader, index: u32, style: ParagraphStyle, depth: i32) anyerror!void {
        var st = style;
        const n = self.tree.get(index);
        switch (n.kind) {
            .paragraph => try self.inlinePara(st, index, .{}),
            .heading => {
                st.heading = n.level;
                try self.inlinePara(st, index, .{});
            },
            .code_block => {
                st.code_block = true;
                st.heading = 0;
                var text = n.text;
                if (std.mem.endsWith(u8, text, "\n")) text = text[0 .. text.len - 1];
                if (n.text.len == 0) {
                    try self.paras.append(self.arena, .{ .style = st });
                    return;
                }
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |line| {
                    const runs: []const tx.Run = if (line.len > 0) try self.arena.dupe(tx.Run, &.{.{ .text = line }}) else &.{};
                    try self.paras.append(self.arena, .{ .style = st, .runs = runs });
                }
            },
            .block_quote => {
                st.quote = true;
                try self.blocks(index, st, depth);
            },
            .list => {
                const kind: tx.ListKind = if (n.ordered) .numbers else .bullets;
                var items = self.tree.children(index);
                while (items.next()) |item| {
                    var ist: ParagraphStyle = .{ .list = kind, .indent = levelOf(depth + 1), .quote = st.quote };
                    const task = self.taskOf(item);
                    if (task != .none) {
                        ist.list = .tasks;
                        ist.checked = task == .checked;
                    }
                    try self.listItem(item, ist, depth + 1);
                }
            },
            .table => {
                var rows = self.tree.children(index);
                while (rows.next()) |row| {
                    var runs: std.ArrayList(tx.Run) = .empty;
                    var a: Attributes = .{};
                    if (self.tree.get(row).header) a.weight = 700;
                    var cells = self.tree.children(row);
                    var first = true;
                    while (cells.next()) |cell| {
                        if (!first) try addRun(self.arena, &runs, .{ .text = "\t", .attributes = a });
                        first = false;
                        try self.inlines(&runs, cell, a);
                    }
                    try self.paras.append(self.arena, .{ .style = st, .runs = runs.items });
                }
            },
            .thematic_break => {},
            else => {},
        }
    }

    fn taskOf(self: *Reader, list_item: u32) md.Task {
        const n = self.tree.get(list_item);
        if (n.task != .none) return n.task;
        if (n.first_child != md.none) return self.tree.get(n.first_child).task;
        return .none;
    }

    fn levelOf(depth: i32) u8 {
        return @intCast(zio.asUnsigned(std.math.clamp(depth, 0, tx.max_indent)));
    }

    /// A list item: its first paragraph in the item's style, and what
    /// follows indented under it.
    fn listItem(self: *Reader, index: u32, ist: ParagraphStyle, depth: i32) !void {
        const under: ParagraphStyle = .{ .indent = levelOf(depth + 1), .quote = ist.quote };
        var first = true;
        var it = self.tree.children(index);
        while (it.next()) |k| {
            const kind = self.tree.get(k).kind;
            if (first) {
                first = false;
                if (kind == .paragraph or kind == .heading) {
                    try self.block(k, ist, depth);
                    continue;
                }
                // An item starting with code or a list has an empty line of
                // its own, as it shows.
                try self.paras.append(self.arena, .{ .style = ist });
            }
            try self.block(k, under, depth);
        }
        if (first) try self.paras.append(self.arena, .{ .style = ist });
    }

    /// A paragraph of inlines; a hard line break starts another, indented
    /// under a list item rather than an item of its own.
    fn inlinePara(self: *Reader, style: ParagraphStyle, index: u32, a: Attributes) !void {
        var st = style;
        var all: std.ArrayList(tx.Run) = .empty;
        self.open = @splat(0);
        try self.inlines(&all, index, a);
        var runs: std.ArrayList(tx.Run) = .empty;
        for (all.items) |r| {
            var rest = r.text;
            while (true) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const line = if (nl) |k| rest[0..k] else rest;
                if (line.len > 0) try runs.append(self.arena, .{ .text = line, .attributes = r.attributes });
                if (nl == null) break;
                try self.paras.append(self.arena, .{ .style = st, .runs = try runs.toOwnedSlice(self.arena) });
                if (st.list != .none) st = .{ .indent = @min(st.indent + 1, tx.max_indent), .quote = st.quote };
                rest = rest[nl.? + 1 ..];
            }
        }
        try self.paras.append(self.arena, .{ .style = st, .runs = runs.items });
    }

    fn inlines(self: *Reader, out: *std.ArrayList(tx.Run), index: u32, a: Attributes) anyerror!void {
        var it = self.tree.children(index);
        while (it.next()) |k| {
            const n = self.tree.get(k);
            var x = a;
            switch (n.kind) {
                .text => try self.addText(out, n.text, a),
                .soft_break => try self.add(out, " ", a),
                .hard_break => try self.add(out, "\n", a),
                .code => {
                    x.code = true;
                    try self.add(out, n.text, x);
                },
                .emphasis => {
                    x.italic = true;
                    try self.inlines(out, k, x);
                },
                .strong => {
                    x.weight = 700;
                    try self.inlines(out, k, x);
                },
                .strikethrough => {
                    x.strikethrough = true;
                    try self.inlines(out, k, x);
                },
                .link => {
                    x.link = html.safeLink(n.url);
                    try self.inlines(out, k, x);
                },
                .image => {
                    x = a.extending();
                    var alt: std.ArrayList(u8) = .empty;
                    try self.plain(&alt, k);
                    const at = try self.arena.create(tx.Attachment);
                    at.* = .{ .name = alt.items, .url = html.safeLink(n.url) };
                    x.attachment = at;
                    try out.append(self.arena, .{ .text = tx.object_replacement_utf8, .attributes = x });
                },
                else => try self.inlines(out, k, a),
            }
        }
    }

    fn plain(self: *Reader, out: *std.ArrayList(u8), index: u32) !void {
        var it = self.tree.children(index);
        while (it.next()) |k| {
            const n = self.tree.get(k);
            switch (n.kind) {
                .text, .code => try appendUnmarked(self.arena, out, n.text),
                .soft_break, .hard_break => try out.append(self.arena, ' '),
                else => try self.plain(out, k),
            }
        }
    }

    /// Text that may hold the sentinels of inline tags.
    fn addText(self: *Reader, out: *std.ArrayList(tx.Run), s: []const u8, a: Attributes) !void {
        var start: usize = 0;
        var at: usize = 0;
        while (at < s.len) {
            const d = tx.decodeAt(s, at);
            if (d.rune >= sentinel_base and d.rune <= sentinel_base + 8) {
                if (at > start) try self.add(out, s[start..at], a);
                const k = d.rune - sentinel_base;
                if (k == 8) {
                    try out.append(self.arena, .{ .text = "\n", .attributes = a });
                } else {
                    const which = k / 2;
                    if (k % 2 == 1) self.open[which] -|= 1 else self.open[which] += 1;
                }
                at += d.len;
                start = at;
                continue;
            }
            at += d.len;
        }
        if (start < s.len) try self.add(out, s[start..], a);
    }

    fn add(self: *Reader, out: *std.ArrayList(tx.Run), s: []const u8, attrs: Attributes) !void {
        var a = attrs;
        if (self.open[0] > 0) a.underline = true;
        if (self.open[1] > 0) a.strikethrough = true;
        if (self.open[2] > 0) a.weight = 700;
        if (self.open[3] > 0) a.italic = true;
        try addRun(self.arena, out, .{ .text = s, .attributes = a });
    }
};

fn appendUnmarked(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var at: usize = 0;
    while (at < s.len) {
        const d = tx.decodeAt(s, at);
        if (!(d.rune >= sentinel_base and d.rune <= sentinel_base + 8)) try out.appendSlice(arena, s[at .. at + d.len]);
        at += d.len;
    }
}

/// Appends r, joined to the last when their attributes are the same.
fn addRun(arena: Allocator, runs: *std.ArrayList(tx.Run), r: tx.Run) !void {
    if (runs.items.len > 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.attributes.eql(r.attributes) and r.attributes.attachment == null) {
            last.text = try std.mem.concat(arena, u8, &.{ last.text, r.text });
            return;
        }
    }
    try runs.append(arena, r);
}
