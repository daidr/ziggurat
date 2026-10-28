//! HTML for attributed text, as browsers, mail and word processors paste
//! it, and attributed text from the HTML they copy.
const std = @import("std");
const tx = @import("text.zig");
const md = @import("ziggurat_markdown");
const image_size = @import("image_size.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Text = tx.Text;
const Attributes = tx.Attributes;
const ParagraphStyle = tx.ParagraphStyle;
const Color = tx.Color;

// ---- Writing --------------------------------------------------------------

/// Writes `t` as HTML: paragraphs, headings, lists (task lists with check
/// boxes), quotations and blocks of code, and runs in the tags and styles
/// of their attributes.
pub fn write(t: *const Text, w: *Writer) Writer.Error!void {
    try w.writeAll("<meta charset=\"utf-8\">");
    try writeBlocks(t, w, 0, t.paragraphCount(), false);
}

/// `t` as HTML, allocated.
pub fn html(allocator: Allocator, t: *const Text) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    write(t, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn styleOf(t: *const Text, p: u32, unquote: bool) ParagraphStyle {
    var s = t.para(p).style;
    if (unquote) s.quote = false;
    return s;
}

/// Writes paragraphs `from` up to `to` as HTML blocks; those of a quotation
/// in a blockquote, whatever they are. `unquote` reads them without their
/// quotation, inside one.
fn writeBlocks(t: *const Text, w: *Writer, from: u32, to: u32, unquote: bool) Writer.Error!void {
    // The lists open: their tags.
    var open: [tx.max_indent + 1][]const u8 = undefined;
    var depth_open: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const st = styleOf(t, i, unquote);
        if (st.list == .none or st.quote) {
            try closeLists(w, &open, &depth_open, 0);
        }
        const align_attr = switch (st.@"align") {
            .center => " style=\"text-align:center\"",
            .end => " style=\"text-align:right\"",
            .start => "",
        };
        if (st.quote) {
            var j = i;
            while (j < to and styleOf(t, j, unquote).quote) j += 1;
            try w.writeAll("<blockquote>");
            try writeBlocks(t, w, i, j, true);
            try w.writeAll("</blockquote>");
            i = j - 1;
        } else if (st.list != .none) {
            const tag: []const u8 = if (st.list == .numbers) "ol" else "ul";
            const depth: usize = @as(usize, st.indent) + 1;
            if (depth_open >= depth and !std.mem.eql(u8, open[depth - 1], tag)) try closeLists(w, &open, &depth_open, depth - 1);
            if (depth_open >= depth) {
                try closeLists(w, &open, &depth_open, depth);
                try w.writeAll("</li>");
            } else {
                while (depth_open < depth) {
                    try w.print("<{s}>", .{tag});
                    open[depth_open] = tag;
                    depth_open += 1;
                    if (depth_open < depth) try w.writeAll("<li>");
                }
            }
            try w.print("<li{s}>", .{align_attr});
            if (st.list == .tasks) try w.writeAll(if (st.checked) "<input type=\"checkbox\" checked disabled> " else "<input type=\"checkbox\" disabled> ");
            try writeRuns(t, w, i);
        } else if (st.code_block) {
            try w.writeAll("<pre><code>");
            while (i < to and styleOf(t, i, unquote).code_block) : (i += 1) {
                try escape(w, t.para(i).text());
                if (i + 1 < to and styleOf(t, i + 1, unquote).code_block) try w.writeByte('\n');
            }
            i -= 1;
            try w.writeAll("</code></pre>");
        } else {
            var tag_buffer: [2]u8 = undefined;
            const tag = blockTag(st, &tag_buffer);
            try w.print("<{s}{s}>", .{ tag, align_attr });
            if (t.para(i).n == 0) try w.writeAll("<br>");
            try writeRuns(t, w, i);
            try w.print("</{s}>", .{tag});
        }
    }
    try closeLists(w, &open, &depth_open, 0);
}

fn closeLists(w: *Writer, open: []const []const u8, depth: *usize, to: usize) Writer.Error!void {
    while (depth.* > to) {
        depth.* -= 1;
        try w.print("</li></{s}>", .{open[depth.*]});
    }
}

/// p, or h1 to h6.
fn blockTag(st: ParagraphStyle, buffer: *[2]u8) []const u8 {
    if (st.heading == 0) return "p";
    buffer.* = .{ 'h', '0' + @as(u8, @min(st.heading, 6)) };
    return buffer;
}

/// Writes the runs of paragraph p: a link around the tags of the formats,
/// and a span with the styles of fonts and colors.
fn writeRuns(t: *const Text, w: *Writer, p: u32) Writer.Error!void {
    var it = t.para(p).iterator();
    var pending: ?tx.RunIterator.Item = it.next();
    while (pending) |item| {
        const link = safeLink(item.run.attributes.link);
        if (link.len > 0) {
            try w.writeAll("<a href=\"");
            try escape(w, link);
            try w.writeAll("\">");
            var cur: ?tx.RunIterator.Item = item;
            while (cur) |c| {
                if (!std.mem.eql(u8, c.run.attributes.link, item.run.attributes.link)) break;
                try writeRun(w, c.run);
                cur = it.next();
            }
            try w.writeAll("</a>");
            pending = cur;
            continue;
        }
        try writeRun(w, item.run);
        pending = it.next();
    }
}

fn writeRun(w: *Writer, r: tx.Run) Writer.Error!void {
    const a = r.attributes;
    if (a.attachment) |at| {
        const size = at.size();
        try w.writeAll("<img src=\"");
        try escape(w, at.url);
        try w.writeAll("\" alt=\"");
        try escape(w, at.name);
        try w.print("\" width=\"{d}\" height=\"{d}\">", .{ @as(i64, @intFromFloat(size.width + 0.5)), @as(i64, @intFromFloat(size.height + 0.5)) });
        return;
    }
    var style_buffer: [512]u8 = undefined;
    var style: Writer = .fixed(&style_buffer);
    var any = false;
    if (a.font.len > 0) {
        style.writeAll("font-family:") catch {};
        writeCssFamily(&style, a.font) catch {};
        any = true;
    }
    if (a.size > 0) {
        if (any) style.writeByte(';') catch {};
        style.print("font-size:{d}px", .{a.size}) catch {};
        any = true;
    }
    if (a.color.set()) {
        if (any) style.writeByte(';') catch {};
        style.writeAll("color:") catch {};
        writeCssColor(&style, a.color) catch {};
        any = true;
    }
    if (a.background.set()) {
        if (any) style.writeByte(';') catch {};
        style.writeAll("background-color:") catch {};
        writeCssColor(&style, a.background) catch {};
        any = true;
    }
    if (a.weight > 0 and a.weight != 400 and a.weight != 700) {
        if (any) style.writeByte(';') catch {};
        style.print("font-weight:{d}", .{a.weight}) catch {};
        any = true;
    }
    var tags: [5][]const u8 = undefined;
    var n: usize = 0;
    if (a.weight == 700) {
        tags[n] = "b";
        n += 1;
    }
    if (a.italic) {
        tags[n] = "i";
        n += 1;
    }
    if (a.underline) {
        tags[n] = "u";
        n += 1;
    }
    if (a.strikethrough) {
        tags[n] = "s";
        n += 1;
    }
    if (a.code) {
        tags[n] = "code";
        n += 1;
    }
    if (any) {
        try w.writeAll("<span style=\"");
        try escape(w, style.buffered());
        try w.writeAll("\">");
    }
    for (tags[0..n]) |tag| try w.print("<{s}>", .{tag});
    try escape(w, r.text);
    var k = n;
    while (k > 0) {
        k -= 1;
        try w.print("</{s}>", .{tags[k]});
    }
    if (any) try w.writeAll("</span>");
}

/// Escapes text and attribute values.
pub fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: ?[]const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => "&#34;",
            '\'' => "&#39;",
            else => null,
        };
        if (rep) |value| {
            try w.writeAll(s[start..i]);
            try w.writeAll(value);
            start = i + 1;
        }
    }
    try w.writeAll(s[start..]);
}

/// A color as CSS.
pub fn writeCssColor(w: *Writer, c: Color) Writer.Error!void {
    if (c.a == 255) return w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
    const alpha = @as(f32, @floatFromInt(c.a)) / 255;
    var buffer: [16]u8 = undefined;
    try w.print("rgba({d},{d},{d},{s})", .{ c.r, c.g, c.b, formatAlpha(alpha, &buffer) });
}

/// Three significant digits, as CSS takes an alpha.
fn formatAlpha(alpha: f32, buffer: *[16]u8) []const u8 {
    const scaled: u32 = @intFromFloat(@round(alpha * 1000));
    if (scaled >= 1000) return "1";
    var digits = std.fmt.bufPrint(buffer, "0.{d:0>3}", .{scaled}) catch return "1";
    while (digits.len > 2 and digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    if (std.mem.eql(u8, digits, "0.")) return "0";
    return digits;
}

pub fn cssColorString(c: Color, buffer: []u8) []const u8 {
    var w: Writer = .fixed(buffer);
    writeCssColor(&w, c) catch {};
    return w.buffered();
}

/// A family as CSS, quoted when it has a space.
fn writeCssFamily(w: *Writer, f: []const u8) Writer.Error!void {
    if (std.mem.indexOfAny(u8, f, " ,") != null and std.mem.indexOfAny(u8, f, "\"'") == null) return w.print("'{s}'", .{f});
    try w.writeAll(f);
}

/// A CSS color: #rgb, #rrggbb, #rrggbbaa, rgb() and rgba().
pub fn parseCssColor(input: []const u8) ?Color {
    var buffer: [64]u8 = undefined;
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buffer.len) return null;
    const s = std.ascii.lowerString(&buffer, trimmed);
    if (std.mem.eql(u8, s, "transparent") or std.mem.eql(u8, s, "inherit") or std.mem.eql(u8, s, "initial")) return null;
    if (s[0] == '#') {
        var h = s[1..];
        var expanded: [6]u8 = undefined;
        if (h.len == 3) {
            expanded = .{ h[0], h[0], h[1], h[1], h[2], h[2] };
            h = &expanded;
        }
        if (h.len != 6 and h.len != 8) return null;
        const v = std.fmt.parseInt(u32, h, 16) catch return null;
        if (h.len == 8) return .{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) };
        return Color.rgb(v);
    }
    var inner: []const u8 = undefined;
    if (std.mem.startsWith(u8, s, "rgba(")) inner = s[5..] else if (std.mem.startsWith(u8, s, "rgb(")) inner = s[4..] else return null;
    if (std.mem.endsWith(u8, inner, ")")) inner = inner[0 .. inner.len - 1];
    var c = [4]f64{ 0, 0, 0, 1 };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, inner, ", /");
    while (it.next()) |part| {
        if (count == 4) break;
        const percent = std.mem.endsWith(u8, part, "%");
        var f = std.fmt.parseFloat(f64, if (percent) part[0 .. part.len - 1] else part) catch return null;
        if (percent) {
            f = f / 100 * 255;
            if (count == 3) f /= 255;
        }
        c[count] = f;
        count += 1;
    }
    if (count < 3 or c[3] <= 0) return null;
    const byte = struct {
        fn of(v: f64) u8 {
            return @intFromFloat(std.math.clamp(v, 0, 255));
        }
    }.of;
    return .{ .r = byte(c[0]), .g = byte(c[1]), .b = byte(c[2]), .a = @intFromFloat(@round(std.math.clamp(c[3], 0, 1) * 255)) };
}

/// A link's URL, or "" for one that runs a script where a browser opens
/// it: javascript:, vbscript: and data:, as browsers read them, with spaces
/// before and tabs or newlines within.
pub fn safeLink(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and s[start] <= ' ') start += 1;
    while (end > start and s[end - 1] <= ' ') end -= 1;
    const link = s[start..end];
    var scheme: [16]u8 = undefined;
    var n: usize = 0;
    for (link) |c| {
        if (c == '\t' or c == '\n' or c == '\r') continue;
        if (n == scheme.len) break;
        scheme[n] = std.ascii.toLower(c);
        n += 1;
    }
    for ([_][]const u8{ "javascript:", "vbscript:", "data:" }) |bad| {
        if (std.mem.startsWith(u8, scheme[0..n], bad)) return "";
    }
    return link;
}

// ---- Reading --------------------------------------------------------------

/// The attributed text of an HTML document or fragment, as a paste from a
/// browser, mail or a word processor brings: paragraphs, headings, lists,
/// task lists, quotations, blocks of code, alignment, bold, italic,
/// underline, strikethrough, code, links and images. Fonts, sizes and
/// colors are left out, so that what is pasted takes the editor's.
pub fn parse(allocator: Allocator, s: []const u8) !Text {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    var b: Builder = .{ .arena = arena_state.allocator(), .owner = allocator };
    try b.run(s);
    try b.flush();
    // Trailing empty paragraphs are the document's margins.
    var paras = b.paras.items;
    while (paras.len > 1 and paras[paras.len - 1].runs.len == 0) paras = paras[0 .. paras.len - 1];
    if (paras.len == 0) return Text.init(allocator);
    return Text.of(allocator, paras);
}

const Tag = enum {
    other,
    script,
    style,
    head,
    title,
    template,
    noscript,
    br,
    img,
    input,
    b,
    strong,
    i,
    em,
    cite,
    dfn,
    u,
    ins,
    s,
    strike,
    del,
    code,
    kbd,
    samp,
    tt,
    a,
    ul,
    ol,
    li,
    p,
    div,
    section,
    article,
    header,
    footer,
    main,
    aside,
    nav,
    figure,
    figcaption,
    tr,
    dt,
    dd,
    address,
    center,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    blockquote,
    pre,
    td,
    th,
    meta,
    link,
    hr,
    wbr,
    col,
    area,
    base,
    embed,
    source,
    track,
    param,
    html,
    body,
    table,
    tbody,
    thead,
    tfoot,

    fn of(name: []const u8) Tag {
        var buffer: [16]u8 = undefined;
        if (name.len > buffer.len) return .other;
        return std.meta.stringToEnum(Tag, std.ascii.lowerString(&buffer, name)) orelse .other;
    }
    fn isVoid(self: Tag) bool {
        return switch (self) {
            .br, .img, .input, .meta, .link, .hr, .wbr, .col, .area, .base, .embed, .source, .track, .param => true,
            else => false,
        };
    }
    /// Elements whose start closes an open paragraph.
    fn closesParagraph(self: Tag) bool {
        return switch (self) {
            .p, .div, .section, .article, .header, .footer, .main, .aside, .nav, .figure, .figcaption, .address, .center, .h1, .h2, .h3, .h4, .h5, .h6, .blockquote, .pre, .ul, .ol, .table, .hr => true,
            else => false,
        };
    }
};

const Attr = struct { name: []const u8, value: []const u8 };

const Element = struct {
    tag: Tag,
    name: []const u8,
    saved_style: ParagraphStyle,
    saved_lists: usize,
    a: Attributes,
    block: bool,
    pre: bool,
    list: bool,
};

const Builder = struct {
    arena: Allocator,
    /// The allocator of the text built, which owns decoded images.
    owner: Allocator,
    paras: std.ArrayList(tx.Paragraph) = .empty,
    runs: std.ArrayList(tx.Run) = .empty,
    cur_style: ParagraphStyle = .{},
    started: bool = false,
    /// Set after whitespace, which collapses into one space.
    space: bool = true,
    lists: std.ArrayList(tx.ListKind) = .empty,
    style: ParagraphStyle = .{},
    pre: u32 = 0,
    stack: std.ArrayList(Element) = .empty,
    /// What a text run gets: the attributes of the elements open.
    a: Attributes = .{},
    /// Depth of elements whose text is not the document's.
    skip: u32 = 0,

    fn flush(self: *Builder) !void {
        if (!self.started) return;
        // Trailing whitespace of a paragraph is not shown.
        if (self.runs.items.len > 0 and self.pre == 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            last.text = std.mem.trimEnd(u8, last.text, " ");
            if (last.text.len == 0) _ = self.runs.pop();
        }
        try self.paras.append(self.arena, .{ .style = self.cur_style, .runs = try self.runs.toOwnedSlice(self.arena) });
        self.started = false;
        self.space = true;
    }

    fn begin(self: *Builder) void {
        if (!self.started) {
            self.cur_style = self.style;
            self.started = true;
        }
    }

    fn addRun(self: *Builder, s: []const u8, a: Attributes) !void {
        try self.runs.append(self.arena, .{ .text = s, .attributes = a });
    }

    fn text(self: *Builder, s: []const u8, a: Attributes) !void {
        if (self.skip > 0) return;
        if (self.pre > 0) {
            var it = std.mem.splitScalar(u8, s, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) {
                    self.begin();
                    try self.flush();
                }
                first = false;
                if (line.len > 0) {
                    self.begin();
                    try self.addRun(try self.arena.dupe(u8, line), a);
                }
            }
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (at < s.len) {
            const d = tx.decodeAt(s, at);
            at += d.len;
            switch (d.rune) {
                ' ', '\n', '\t', '\r', 0x0c => {
                    if (!self.space) {
                        try out.append(self.arena, ' ');
                        self.space = true;
                    }
                    continue;
                },
                else => {},
            }
            // A no-break space is a space a line keeps.
            if (d.rune == 0xa0) try out.append(self.arena, ' ') else try out.appendSlice(self.arena, s[at - d.len .. at]);
            self.space = false;
        }
        if (out.items.len == 0) return;
        self.begin();
        var value: []const u8 = out.items;
        if (self.runs.items.len == 0) {
            value = std.mem.trimStart(u8, value, " ");
            if (value.len == 0) return;
        }
        try self.addRun(value, a);
    }

    fn run(self: *Builder, s: []const u8) !void {
        var at: usize = 0;
        while (at < s.len) {
            if (s[at] == '<') {
                if (std.mem.startsWith(u8, s[at..], "<!--")) {
                    const end = std.mem.indexOfPos(u8, s, at + 4, "-->") orelse s.len;
                    at = @min(s.len, end + 3);
                    continue;
                }
                if (at + 1 < s.len and (s[at + 1] == '!' or s[at + 1] == '?')) {
                    at = (std.mem.indexOfScalarPos(u8, s, at, '>') orelse s.len - 1) + 1;
                    continue;
                }
                if (at + 1 < s.len and (std.ascii.isAlphabetic(s[at + 1]) or s[at + 1] == '/')) {
                    at = try self.tag(s, at);
                    continue;
                }
            }
            const end = std.mem.indexOfScalarPos(u8, s, at + 1, '<') orelse s.len;
            const decoded = try decodeEntities(self.arena, s[at..end]);
            try self.text(decoded, self.a);
            at = end;
        }
        // Close what is still open.
        while (self.stack.items.len > 0) try self.close();
    }

    /// Reads a tag at `at` and returns the offset after it.
    fn tag(self: *Builder, s: []const u8, start: usize) !usize {
        var at = start + 1;
        const closing = s[at] == '/';
        if (closing) at += 1;
        const name_start = at;
        while (at < s.len and !std.ascii.isWhitespace(s[at]) and s[at] != '>' and s[at] != '/') at += 1;
        const name = s[name_start..at];
        var attrs: std.ArrayList(Attr) = .empty;
        while (at < s.len and s[at] != '>') {
            while (at < s.len and (std.ascii.isWhitespace(s[at]) or s[at] == '/')) at += 1;
            if (at >= s.len or s[at] == '>') break;
            const an = at;
            while (at < s.len and !std.ascii.isWhitespace(s[at]) and s[at] != '=' and s[at] != '>' and s[at] != '/') at += 1;
            const attr_name = s[an..at];
            while (at < s.len and std.ascii.isWhitespace(s[at])) at += 1;
            var value: []const u8 = "";
            if (at < s.len and s[at] == '=') {
                at += 1;
                while (at < s.len and std.ascii.isWhitespace(s[at])) at += 1;
                if (at < s.len and (s[at] == '"' or s[at] == '\'')) {
                    const q = s[at];
                    const vs = at + 1;
                    const ve = std.mem.indexOfScalarPos(u8, s, vs, q) orelse s.len;
                    value = s[vs..ve];
                    at = @min(s.len, ve + 1);
                } else {
                    const vs = at;
                    while (at < s.len and !std.ascii.isWhitespace(s[at]) and s[at] != '>') at += 1;
                    value = s[vs..at];
                }
            }
            if (attr_name.len > 0) try attrs.append(self.arena, .{ .name = attr_name, .value = try decodeEntities(self.arena, value) });
            if (at == an) at += 1;
        }
        const end = @min(s.len, at + 1);
        const t = Tag.of(name);
        if (closing) {
            try self.closeTag(t, name);
            return end;
        }
        try self.open(t, name, attrs.items);
        // The text of a script or a style is not markup.
        if (t == .script or t == .style or t == .title or t == .template or t == .noscript) {
            var close_buffer: [16]u8 = undefined;
            const close_tag = std.fmt.bufPrint(&close_buffer, "</{s}", .{@tagName(t)}) catch return end;
            const rest = s[end..];
            var k: usize = 0;
            while (k + close_tag.len <= rest.len) : (k += 1) {
                if (std.ascii.eqlIgnoreCase(rest[k..][0..close_tag.len], close_tag)) break;
            }
            if (k + close_tag.len > rest.len) {
                try self.closeTag(t, name);
                return s.len;
            }
            return end + k;
        }
        return end;
    }

    fn attr(attrs: []const Attr, name: []const u8) ?[]const u8 {
        for (attrs) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        return null;
    }

    fn open(self: *Builder, t: Tag, name: []const u8, attrs: []const Attr) !void {
        // Implicit ends, as browsers close them.
        if (t.closesParagraph()) self.closeOpen(.p, &.{});
        if (t == .li) self.closeOpen(.li, &.{ .ul, .ol });
        if (t == .dt or t == .dd) {
            self.closeOpen(.dt, &.{});
            self.closeOpen(.dd, &.{});
        }
        var a = self.a;
        const saved = self.style;
        const saved_lists = self.lists.items.len;
        var block = false;
        var pre = false;
        var list = false;
        switch (t) {
            .script, .style, .head, .title, .template, .noscript => {
                self.skip += 1;
            },
            .br => {
                self.begin();
                try self.flush();
                return;
            },
            .img => {
                if (self.skip > 0) return;
                const src = attr(attrs, "src") orelse "";
                var at: tx.Attachment = .{ .name = attr(attrs, "alt") orelse "", .url = src };
                at.width = imageSide(attr(attrs, "width") orelse "");
                at.height = imageSide(attr(attrs, "height") orelse "");
                if (std.mem.startsWith(u8, src, "data:")) {
                    if (std.mem.indexOf(u8, src, ";base64,")) |k| {
                        const encoded = std.mem.trim(u8, src[k + 8 ..], " \t\r\n");
                        if (decodeBase64(self.arena, encoded)) |raw| {
                            if (image_size.of(raw)) |size| {
                                at.image = raw;
                                at.image_width = size.width;
                                at.image_height = size.height;
                                at.url = "";
                            }
                        } else |_| {}
                    }
                }
                const owned = try self.arena.create(tx.Attachment);
                owned.* = at;
                self.begin();
                var x = a.extending();
                x.attachment = owned;
                try self.addRun(tx.object_replacement_utf8, x);
                self.space = false;
                return;
            },
            .input => {
                if (self.skip > 0) return;
                if (std.ascii.eqlIgnoreCase(attr(attrs, "type") orelse "", "checkbox")) {
                    self.begin();
                    self.cur_style.list = .tasks;
                    self.cur_style.checked = attr(attrs, "checked") != null;
                    self.space = true;
                }
                return;
            },
            .b, .strong => a.weight = 700,
            .i, .em, .cite, .dfn => a.italic = true,
            .u, .ins => a.underline = true,
            .s, .strike, .del => a.strikethrough = true,
            .code, .kbd, .samp, .tt => if (self.pre == 0) {
                a.code = true;
            },
            .a => a.link = safeLink(attr(attrs, "href") orelse ""),
            .ul, .ol => {
                try self.flush();
                try self.lists.append(self.arena, if (t == .ol) .numbers else .bullets);
                list = true;
            },
            .li => {
                try self.flush();
                const kind: tx.ListKind = if (self.lists.items.len > 0) self.lists.items[self.lists.items.len - 1] else .bullets;
                self.style = .{ .list = kind, .indent = @intCast(@min(@max(self.lists.items.len, 1) - 1, tx.max_indent)), .@"align" = saved.@"align", .quote = saved.quote };
                block = true;
            },
            .p, .div, .section, .article, .header, .footer, .main, .aside, .nav, .figure, .figcaption, .tr, .dt, .dd, .address, .center => {
                try self.flush();
                block = true;
            },
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                try self.flush();
                self.style = .{ .heading = @backingInt(t) - @backingInt(Tag.h1) + 1, .@"align" = saved.@"align", .quote = saved.quote };
                block = true;
            },
            .blockquote => {
                try self.flush();
                self.style.quote = true;
                block = true;
            },
            .pre => {
                try self.flush();
                self.style = .{ .code_block = true, .indent = saved.indent, .quote = saved.quote };
                self.pre += 1;
                pre = true;
                block = true;
            },
            .td, .th => try self.text(" ", a),
            else => {},
        }
        if (attr(attrs, "style")) |css| a = applyCss(css, a, &self.style, block);
        if (block) {
            const al = attr(attrs, "align") orelse "";
            if (std.ascii.eqlIgnoreCase(al, "center")) self.style.@"align" = .center else if (std.ascii.eqlIgnoreCase(al, "right")) self.style.@"align" = .end;
        }
        if (t.isVoid()) return;
        try self.stack.append(self.arena, .{ .tag = t, .name = name, .saved_style = saved, .saved_lists = saved_lists, .a = self.a, .block = block, .pre = pre, .list = list });
        self.a = a;
    }

    /// Closes an open `t` unless one of `scopes` is open inside it.
    fn closeOpen(self: *Builder, t: Tag, scopes: []const Tag) void {
        var k = self.stack.items.len;
        while (k > 0) {
            k -= 1;
            const e = self.stack.items[k].tag;
            if (e == t) {
                while (self.stack.items.len > k) self.close() catch return;
                return;
            }
            for (scopes) |scope| if (e == scope) return;
            // A paragraph does not close across blocks it holds.
            if (t == .p and (e == .li or e == .blockquote or e == .td or e == .th or e == .div)) return;
        }
    }

    fn closeTag(self: *Builder, t: Tag, name: []const u8) !void {
        if (t == .br) {
            self.begin();
            try self.flush();
            return;
        }
        if (t == .p) {
            var open_p = false;
            for (self.stack.items) |e| if (e.tag == .p) {
                open_p = true;
            };
            // </p> without <p> is an empty paragraph, as browsers read it.
            if (!open_p) {
                self.begin();
                try self.flush();
                return;
            }
        }
        var k = self.stack.items.len;
        while (k > 0) {
            k -= 1;
            const e = self.stack.items[k];
            const same = if (t == .other) std.ascii.eqlIgnoreCase(e.name, name) else e.tag == t;
            if (same) {
                while (self.stack.items.len > k) try self.close();
                return;
            }
        }
    }

    /// Closes the innermost open element.
    fn close(self: *Builder) !void {
        const e = self.stack.pop().?;
        self.a = e.a;
        switch (e.tag) {
            .script, .style, .head, .title, .template, .noscript => self.skip -|= 1,
            else => {},
        }
        if (e.list) {
            self.lists.shrinkRetainingCapacity(e.saved_lists);
            try self.flush();
            self.style = e.saved_style;
            return;
        }
        if (e.block) {
            if (e.tag == .p and !self.started and self.pre == 0) {
                // An empty paragraph shows as one.
                self.begin();
            }
            try self.flush();
            self.style = e.saved_style;
        }
        if (e.pre) self.pre -|= 1;
    }
};

/// The width or height an img's attribute gives, or 0.
fn imageSide(s: []const u8) f32 {
    var v = std.mem.trim(u8, s, " \t");
    if (std.mem.endsWith(u8, v, "px")) v = v[0 .. v.len - 2];
    const f = std.fmt.parseFloat(f32, v) catch return 0;
    return side(f);
}

/// `v` as an attachment's width or height: 0, for its picture's, unless it
/// is a size, not negative, infinite or not a number.
pub fn side(v: f32) f32 {
    if (!(v > 0) or v > 1e5) return 0;
    return v;
}

fn decodeBase64(allocator: Allocator, s: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(s);
    const out = try allocator.alloc(u8, n);
    try decoder.decode(out, s);
    return out;
}

/// Decodes character references.
pub fn decodeEntities(allocator: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < s.len) {
        if (s[at] == '&') {
            if (entityAt(s, at)) |e| {
                try out.appendSlice(allocator, e.text[0..e.len]);
                at = e.end;
                continue;
            }
        }
        try out.append(allocator, s[at]);
        at += 1;
    }
    return out.items;
}

const Entity = struct { text: [8]u8, len: usize, end: usize };

fn entityAt(s: []const u8, at: usize) ?Entity {
    var end = at + 1;
    while (end < s.len and end - at < 34 and (std.ascii.isAlphanumeric(s[end]) or s[end] == '#')) end += 1;
    const name = s[at + 1 .. end];
    if (name.len == 0) return null;
    const after = if (end < s.len and s[end] == ';') end + 1 else end;
    var e: Entity = .{ .text = undefined, .len = 0, .end = after };
    if (name[0] == '#') {
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0 or digits.len > 7) return null;
        const v = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        const cp: u21 = if (v == 0 or v > 0x10ffff or (v >= 0xd800 and v <= 0xdfff)) 0xfffd else @intCast(v);
        e.len = std.unicode.utf8Encode(cp, &e.text) catch return null;
        return e;
    }
    // Named references need their semicolon, but for the common few.
    const value = md.entities.lookup(name) orelse return null;
    if (after == end and !(std.mem.eql(u8, name, "amp") or std.mem.eql(u8, name, "lt") or std.mem.eql(u8, name, "gt") or std.mem.eql(u8, name, "nbsp") or std.mem.eql(u8, name, "quot"))) return null;
    if (value.len > e.text.len) return null;
    @memcpy(e.text[0..value.len], value);
    e.len = value.len;
    return e;
}

/// Applies the declarations of a style attribute to a run's attributes
/// and, for a block, its paragraph's style: weights, italics, lines and
/// alignment; fonts, sizes and colors are left out.
fn applyCss(style: []const u8, attrs: Attributes, ps: *ParagraphStyle, block: bool) Attributes {
    var a = attrs;
    var decls = std.mem.splitScalar(u8, style, ';');
    while (decls.next()) |decl| {
        const colon = std.mem.indexOfScalar(u8, decl, ':') orelse continue;
        var name_buffer: [32]u8 = undefined;
        var value_buffer: [64]u8 = undefined;
        const raw_name = std.mem.trim(u8, decl[0..colon], " \t\r\n");
        var raw_value = std.mem.trim(u8, decl[colon + 1 ..], " \t\r\n");
        if (raw_name.len > name_buffer.len or raw_value.len > value_buffer.len) continue;
        const name = std.ascii.lowerString(&name_buffer, raw_name);
        var value: []const u8 = std.ascii.lowerString(&value_buffer, raw_value);
        if (std.mem.endsWith(u8, value, "!important")) value = std.mem.trim(u8, value[0 .. value.len - 10], " ");
        raw_value = value;
        if (std.mem.eql(u8, name, "font-weight")) {
            if (std.mem.eql(u8, value, "bold") or std.mem.eql(u8, value, "bolder")) {
                a.weight = 700;
            } else if (std.mem.eql(u8, value, "normal") or std.mem.eql(u8, value, "lighter")) {
                a.weight = 0;
            } else if (std.fmt.parseInt(i32, value, 10)) |w| {
                a.weight = if (w >= 600) 700 else 0;
            } else |_| {}
        } else if (std.mem.eql(u8, name, "font-style")) {
            a.italic = std.mem.eql(u8, value, "italic") or std.mem.eql(u8, value, "oblique");
        } else if (std.mem.eql(u8, name, "text-decoration") or std.mem.eql(u8, name, "text-decoration-line")) {
            a.underline = a.underline or std.mem.indexOf(u8, value, "underline") != null;
            a.strikethrough = a.strikethrough or std.mem.indexOf(u8, value, "line-through") != null;
            if (std.mem.eql(u8, value, "none")) {
                a.underline = false;
                a.strikethrough = false;
            }
        } else if (std.mem.eql(u8, name, "text-align") and block) {
            if (std.mem.eql(u8, value, "center")) {
                ps.@"align" = .center;
            } else if (std.mem.eql(u8, value, "right") or std.mem.eql(u8, value, "end")) {
                ps.@"align" = .end;
            } else if (std.mem.eql(u8, value, "left") or std.mem.eql(u8, value, "start") or std.mem.eql(u8, value, "justify")) {
                ps.@"align" = .start;
            }
        }
    }
    return a;
}
