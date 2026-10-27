const std = @import("std");
const rt = @import("root.zig");

const testing = std.testing;
const Text = rt.Text;
const Attributes = rt.Attributes;
const ParagraphStyle = rt.ParagraphStyle;
const Paragraph = rt.Paragraph;
const Run = rt.Run;
const gpa = testing.allocator;

/// A text of every kind of paragraph and run.
fn sample() !Text {
    const bold: Attributes = .{ .weight = 700 };
    return Text.of(gpa, &.{
        .{ .style = .{ .heading = 1 }, .runs = &.{.{ .text = "Trip" }} },
        .{ .runs = &.{ .{ .text = "Land at " }, .{ .text = "10:40", .attributes = bold }, .{ .text = " near the " }, .{ .text = "castle", .attributes = .{ .link = "https://x.org/a" } }, .{ .text = ", " }, .{ .text = "slowly", .attributes = .{ .italic = true } }, .{ .text = "." } } },
        .{ .style = .{ .list = .tasks, .checked = true }, .runs = &.{.{ .text = "Passport" }} },
        .{ .style = .{ .list = .tasks }, .runs = &.{.{ .text = "Adapter" }} },
        .{ .style = .{ .list = .numbers }, .runs = &.{.{ .text = "One" }} },
        .{ .style = .{ .list = .numbers, .indent = 1 }, .runs = &.{.{ .text = "Inner" }} },
        .{ .style = .{ .list = .numbers }, .runs = &.{.{ .text = "Two" }} },
        .{ .style = .{ .quote = true }, .runs = &.{.{ .text = "A quote" }} },
        .{ .style = .{ .code_block = true }, .runs = &.{.{ .text = "a := 1" }} },
        .{ .style = .{ .code_block = true }, .runs = &.{.{ .text = "b := 2" }} },
        .{ .style = .{ .@"align" = .center }, .runs = &.{ .{ .text = "mid", .attributes = .{ .underline = true, .strikethrough = true } }, .{ .text = " and " }, .{ .text = "x()", .attributes = .{ .code = true } } } },
    });
}

/// The runs of t, marked: *bold*, _italic_, ~underline~, `code`, [link].
fn runsOf(t: *const Text) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    var it = t.rangeRuns(0, t.len());
    var last: ?Attributes = null;
    var parts: usize = 0;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    while (it.next()) |item| {
        const a = item.run.attributes;
        if (last != null and last.?.eql(a)) {
            try pending.appendSlice(gpa, item.run.text);
            continue;
        }
        if (last) |l| {
            if (parts > 0) try w.writeByte('|');
            try mark(w, pending.items, l);
            parts += 1;
        }
        pending.clearRetainingCapacity();
        try pending.appendSlice(gpa, item.run.text);
        last = a;
    }
    if (last) |l| {
        if (parts > 0) try w.writeByte('|');
        try mark(w, pending.items, l);
    }
    return out.toOwnedSlice();
}

fn mark(w: *std.Io.Writer, s: []const u8, a: Attributes) !void {
    if (a.link.len > 0) try w.writeByte('[');
    if (a.code) try w.writeByte('`');
    if (a.underline) try w.writeByte('~');
    if (a.italic) try w.writeByte('_');
    if (a.bold()) try w.writeByte('*');
    try w.writeAll(s);
    if (a.bold()) try w.writeByte('*');
    if (a.italic) try w.writeByte('_');
    if (a.underline) try w.writeByte('~');
    if (a.code) try w.writeByte('`');
    if (a.link.len > 0) try w.writeByte(']');
}

fn expectRuns(t: *const Text, want: []const u8) !void {
    const got = try runsOf(t);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectRunsOf(t: *const Text, start: u32, end: u32, want: []const u8) !void {
    var s = try t.slice(gpa, start, end);
    defer s.deinit();
    try expectRuns(&s, want);
}

fn expectString(t: *const Text, want: []const u8) !void {
    const s = try t.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings(want, s);
}

/// The paragraphs of t, their styles and runs, to compare.
fn dump(t: *const Text) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    var p: u32 = 0;
    while (p < t.paragraphCount()) : (p += 1) {
        const q = t.para(p);
        const s = q.style;
        try w.print("h{d} l{s} c{} i{d} a{s} q{} b{}:", .{ s.heading, @tagName(s.list), s.checked, s.indent, @tagName(s.@"align"), s.quote, s.code_block });
        var it = q.iterator();
        while (it.next()) |item| {
            const a = item.run.attributes;
            try w.print(" \"{s}\"{{w{d} i{} u{} s{} c{} l{s}}}", .{ item.run.text, a.weight, a.italic, a.underline, a.strikethrough, a.code, a.link });
            if (a.attachment) |at| try w.print("[{s} {s}]", .{ at.name, at.url });
        }
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn expectSame(got: *const Text, want: *const Text) !void {
    const a = try dump(got);
    defer gpa.free(a);
    const b = try dump(want);
    defer gpa.free(b);
    try testing.expectEqualStrings(b, a);
}

test "Markdown of every kind of paragraph and run" {
    var t = try sample();
    defer t.deinit();
    const got = try rt.toMarkdown(gpa, &t);
    defer gpa.free(got);
    try testing.expectEqualStrings(
        \\# Trip
        \\
        \\Land at **10:40** near the [castle](https://x.org/a), *slowly*.
        \\
        \\- [x] Passport
        \\- [ ] Adapter
        \\1. One
        \\    1. Inner
        \\2. Two
        \\
        \\> A quote
        \\
        \\```
        \\a := 1
        \\b := 2
        \\```
        \\
        \\~~<u>mid</u>~~ and `x()`
    , got);
    var plain = try Text.initString(gpa, "# not a heading");
    defer plain.deinit();
    const escaped = try rt.toMarkdown(gpa, &plain);
    defer gpa.free(escaped);
    try testing.expectEqualStrings("\\# not a heading", escaped);
}

test "HTML round trip keeps text, runs and styles" {
    var in = try sample();
    defer in.deinit();
    const h = try rt.toHtml(gpa, &in);
    defer gpa.free(h);
    var out = try rt.parseHtml(gpa, h);
    defer out.deinit();
    try expectSame(&out, &in);
}

test "foreign HTML pastes its formats" {
    // As an online word processor copies: a bold wrapper made normal,
    // spans styled.
    const docs = "<meta charset=\"utf-8\"><b style=\"font-weight:normal;\" id=\"docs-internal-guid-1\"><p dir=\"ltr\"><span style=\"font-size:11pt;font-family:Arial;font-weight:700;\">Bold</span><span style=\"font-size:11pt;\"> and </span><span style=\"font-style:italic;\">italic</span></p><ul><li><p><span>item</span></p></li></ul></b>";
    var t = try rt.parseHtml(gpa, docs);
    defer t.deinit();
    try expectString(&t, "Bold and italic\nitem");
    try expectRunsOf(&t, 0, 15, "*Bold*| and |_italic_");
    try testing.expectEqual(rt.ListKind.bullets, t.paragraphStyleAt(17).list);
    // Whitespace collapses; scripts and styles are left out.
    var u = try rt.parseHtml(gpa, "<style>p{}</style><p>  a \n  b  </p><script>x()</script><p>c<br>d</p>");
    defer u.deinit();
    try expectString(&u, "a b\nc\nd");
}

test "JSON round trip" {
    var in = try sample();
    defer in.deinit();
    const j = try rt.toJson(gpa, &in, "copy-1");
    defer gpa.free(j);
    var parsed = (try rt.clip.parse(gpa, j)).?;
    defer parsed.text.deinit();
    try testing.expectEqualStrings("copy-1", parsed.copy());
    try testing.expect(parsed.text.eql(&in));
}

test "RTF as a desktop editor copies it" {
    const rtf = "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n" ++
        "{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n" ++
        "{\\colortbl;\\red255\\green255\\blue255;}\n" ++
        "\\pard\\tx560\\pardirnatural\\partightenfactor0\n" ++
        "\\f0\\fs24 \\cf0 Plain \\b bold\\b0  and \\i italic\\i0 , caf\\'e9 \\u8364 ? {\\field{\\*\\fldinst{HYPERLINK \"https://go.dev\"}}{\\fldrslt site}} end.\\\n" ++
        "\\pard\\qc centered\\\n" ++
        "\\pard\\tx220\\li720\\fi-720\\pardirnatural\\partightenfactor0\n" ++
        "\\ls1\\ilvl0{\\listtext\t\\uc0舦 \t}one\\\n" ++
        "{\\listtext\t\\uc0舦 \t}two\\\n" ++
        "}";
    var t = try rt.parseRtf(gpa, rtf);
    defer t.deinit();
    try expectString(&t, "Plain bold and italic, café € site end.\ncentered\none\ntwo");
    try expectRunsOf(&t, 0, 39, "Plain |*bold*| and |_italic_|, café € |[site]| end.");
    try testing.expectEqual(rt.Align.center, t.paragraphStyleAt(45).@"align");
    try testing.expectEqual(rt.ListKind.bullets, t.paragraphStyleAt(t.len()).list);
}

test "RTF lists of pntext, cells, hidden text and bookmark links" {
    var t = try rt.parseRtf(gpa,
        \\{\rtf1{\pntext\f1\'B7\tab}{\*\pn\pnlvlblt{\pntxtb\'B7}}one\par{\pntext 1.\tab}{\*\pn\pnlvlbody}first\par
        \\e\_mail vis{\v hid}ible\par alpha\cell beta\cell\row {\field{\*\fldinst HYPERLINK \\l "top"}{\fldrslt up}}\par}
    );
    defer t.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var p: u32 = 0;
    while (p < t.paragraphCount()) : (p += 1) {
        if (p > 0) try out.writer.writeByte('|');
        try out.writer.print("{d}:{s}", .{ @intFromEnum(t.para(p).style.list), t.para(p).text() });
    }
    try testing.expectEqualStrings("1:one|2:first|0:e\u{2011}mail visible|0:alpha\tbeta\t|0:up", out.written());
    try testing.expectEqualStrings("#top", t.attributesAt(t.len() - 1).link);
}

fn markdownOf(paragraphs: []const Paragraph) ![]u8 {
    var t = try Text.of(gpa, paragraphs);
    defer t.deinit();
    return rt.toMarkdown(gpa, &t);
}

test "Markdown escapes what it would read as more than text" {
    const cases = [_]struct { paras: []const Paragraph, want: []const u8 }{
        .{ .paras = &.{.{ .style = .{ .list = .bullets }, .runs = &.{.{ .text = "# not a heading" }} }}, .want = "- \\# not a heading" },
        .{ .paras = &.{.{ .style = .{ .list = .numbers }, .runs = &.{.{ .text = "> x" }} }}, .want = "1. \\> x" },
        .{ .paras = &.{.{ .style = .{ .heading = 2 }, .runs = &.{.{ .text = "Issue #" }} }}, .want = "## Issue \\#" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "---" }} }}, .want = "\\---" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "-" }} }}, .want = "\\-" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "    indented" }} }}, .want = "&#32;&#32;&#32;&#32;indented" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "Tom &amp; Jerry & co" }} }}, .want = "Tom \\&amp; Jerry & co" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "x!" }, .{ .text = "y", .attributes = .{ .link = "http://e" } } } }}, .want = "x\\![y](http://e)" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "a``b", .attributes = .{ .code = true } }} }}, .want = "```a``b```" },
        .{ .paras = &.{.{ .runs = &.{.{ .text = "`x", .attributes = .{ .code = true } }} }}, .want = "`` `x ``" },
        // Delimiters that cannot open or close where they are.
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "foo.", .attributes = .{ .weight = 700 } }, .{ .text = "bar" } } }}, .want = "<strong>foo.</strong>bar" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "x" }, .{ .text = "(y)", .attributes = .{ .italic = true } } } }}, .want = "x<em>(y)</em>" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "foo.", .attributes = .{ .weight = 700 } }, .{ .text = " bar" } } }}, .want = "**foo.** bar" },
    };
    for (cases) |c| {
        const got = try markdownOf(c.paras);
        defer gpa.free(got);
        testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("case {s}\n", .{c.want});
            return err;
        };
    }
}

test "codecs sanitize what pasted documents bring" {
    var parsed = (try rt.clip.parse(gpa, "{\"paragraphs\":[{\"style\":{\"list\":1,\"indent\":-1,\"heading\":99},\"runs\":[{\"text\":\"x\",\"attributes\":{\"link\":\" javascript:alert(1)\"}}]}]}")).?;
    defer parsed.text.deinit();
    const st = parsed.text.paragraphStyleAt(0);
    try testing.expectEqual(@as(u8, 0), st.indent);
    try testing.expectEqual(@as(u8, 6), st.heading);
    try testing.expectEqualStrings("", parsed.text.attributesAt(0).link);
    for ([_][]const u8{ "<a href=\" javascript:alert(1)\">x</a>", "<a href=\"java\tscript:alert(1)\">x</a>", "<a href=\"VBScript:x\">x</a>" }) |src| {
        var t = try rt.parseHtml(gpa, src);
        defer t.deinit();
        try testing.expectEqualStrings("", t.attributesAt(0).link);
    }
    var r = try rt.parseRtf(gpa, "{\\rtf1{\\field{\\*\\fldinst HYPERLINK \"javascript:alert(1)\"}{\\fldrslt x}}}");
    defer r.deinit();
    try testing.expectEqualStrings("", r.attributesAt(0).link);
    var evil = try Text.of(gpa, &.{.{ .runs = &.{.{ .text = "x", .attributes = .{ .link = "javascript:alert(1)" } }} }});
    defer evil.deinit();
    const h = try rt.toHtml(gpa, &evil);
    defer gpa.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "javascript") == null);
    var img = try rt.parseHtml(gpa, "<img src=\"x.png\" width=\"NaN\" height=\"-Inf\">");
    defer img.deinit();
    const at = img.attributesAt(0).attachment.?;
    try testing.expectEqual(@as(f32, 0), at.width);
    try testing.expectEqual(@as(f32, 0), at.height);
    const j = try rt.toJson(gpa, &img, "");
    gpa.free(j);
}

test "quoted lists, headings and code stay quoted through HTML" {
    var in = try Text.of(gpa, &.{
        .{ .style = .{ .quote = true, .heading = 2 }, .runs = &.{.{ .text = "QH" }} },
        .{ .style = .{ .quote = true, .list = .bullets }, .runs = &.{.{ .text = "item" }} },
        .{ .style = .{ .quote = true, .code_block = true }, .runs = &.{.{ .text = "code" }} },
        .{ .runs = &.{.{ .text = "after" }} },
    });
    defer in.deinit();
    const h = try rt.toHtml(gpa, &in);
    defer gpa.free(h);
    var out = try rt.parseHtml(gpa, h);
    defer out.deinit();
    try testing.expectEqual(@as(u32, 4), out.paragraphCount());
    for (0..4) |i| try testing.expectEqual(i < 3, out.para(@intCast(i)).style.quote);
}

test "Markdown reads back what it wrote" {
    var want = try sample();
    defer want.deinit();
    // Markdown has no alignment.
    for (want.paras.items) |*p| p.style.@"align" = .start;
    var in = try sample();
    defer in.deinit();
    const m = try rt.toMarkdown(gpa, &in);
    defer gpa.free(m);
    var got = try rt.parseMarkdown(gpa, m);
    defer got.deinit();
    try expectSame(&got, &want);
}

test "Markdown of lists, quotations, breaks, tables, inline HTML and images" {
    const bold: Attributes = .{ .weight = 700 };
    const cat: rt.Attachment = .{ .name = "a cat", .url = "cat.png" };
    const cases = [_]struct { src: []const u8, want: []const Paragraph }{
        .{ .src = "- item\n\n  more\n\n      code\n- next", .want = &.{
            .{ .style = .{ .list = .bullets }, .runs = &.{.{ .text = "item" }} },
            .{ .style = .{ .indent = 1 }, .runs = &.{.{ .text = "more" }} },
            .{ .style = .{ .indent = 1, .code_block = true }, .runs = &.{.{ .text = "code" }} },
            .{ .style = .{ .list = .bullets }, .runs = &.{.{ .text = "next" }} },
        } },
        .{ .src = "> - [x] done\n>   - nested", .want = &.{
            .{ .style = .{ .list = .tasks, .checked = true, .quote = true }, .runs = &.{.{ .text = "done" }} },
            .{ .style = .{ .list = .bullets, .indent = 1, .quote = true }, .runs = &.{.{ .text = "nested" }} },
        } },
        .{ .src = "a  \nb", .want = &.{ .{ .runs = &.{.{ .text = "a" }} }, .{ .runs = &.{.{ .text = "b" }} } } },
        .{ .src = "1. a\\\n   b", .want = &.{ .{ .style = .{ .list = .numbers }, .runs = &.{.{ .text = "a" }} }, .{ .style = .{ .indent = 1 }, .runs = &.{.{ .text = "b" }} } } },
        .{ .src = "| a | b |\n|---|---|\n| 1 | **2** |", .want = &.{
            .{ .runs = &.{.{ .text = "a\tb", .attributes = bold }} },
            .{ .runs = &.{ .{ .text = "1\t" }, .{ .text = "2", .attributes = bold } } },
        } },
        .{ .src = "x <u>under *it*</u> <b>b</b>", .want = &.{.{ .runs = &.{ .{ .text = "x " }, .{ .text = "under ", .attributes = .{ .underline = true } }, .{ .text = "it", .attributes = .{ .underline = true, .italic = true } }, .{ .text = " " }, .{ .text = "b", .attributes = bold } } }} },
        .{ .src = "![a *cat*](cat.png \"t\") [x](javascript:alert(1))", .want = &.{.{ .runs = &.{ .{ .text = rt.object_replacement_utf8, .attributes = .{ .attachment = &cat } }, .{ .text = " x" } } }} },
        .{ .src = "<div>html <b>block</b></div>\n\nafter", .want = &.{ .{ .runs = &.{ .{ .text = "html " }, .{ .text = "block", .attributes = bold } } }, .{ .runs = &.{.{ .text = "after" }} } } },
        .{ .src = "", .want = &.{} },
    };
    for (cases) |c| {
        var got = try rt.parseMarkdown(gpa, c.src);
        defer got.deinit();
        var want = try Text.of(gpa, c.want);
        defer want.deinit();
        expectSame(&got, &want) catch |err| {
            std.debug.print("source {s}\n", .{c.src});
            return err;
        };
    }
}

test "random texts read back from their Markdown" {
    var prng: std.Random.DefaultPrng = .init(12);
    const rng = prng.random();
    const words = [_][]const u8{ "foo", "bar", "a", "x1", ".", ",", "!", "?", "(", ")", "-", "#", "*", "_", "`", "~", "[", "]", "<", ">", "&", "\\", "1.", "é", "\"", "'", ":", "/" };
    const links = [_][]const u8{ "https://e.org/0", "https://e.org/1", "https://e.org/2" };
    var failures: usize = 0;
    for (0..3000) |_| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var runs: std.ArrayList(Run) = .empty;
        for (0..1 + rng.uintLessThan(usize, 5)) |_| {
            var s: std.ArrayList(u8) = .empty;
            for (0..1 + rng.uintLessThan(usize, 3)) |k| {
                if (k > 0 and rng.boolean()) try s.append(arena, ' ');
                try s.appendSlice(arena, words[rng.uintLessThan(usize, words.len)]);
            }
            var a: Attributes = .{};
            if (rng.uintLessThan(u8, 3) == 0) a.weight = 700;
            if (rng.uintLessThan(u8, 3) == 0) a.italic = true;
            if (rng.uintLessThan(u8, 5) == 0) a.strikethrough = true;
            if (rng.uintLessThan(u8, 6) == 0) a.underline = true;
            if (rng.uintLessThan(u8, 6) == 0) a.link = links[rng.uintLessThan(usize, 3)];
            if (rng.uintLessThan(u8, 7) == 0) a = .{ .code = true };
            try runs.append(arena, .{ .text = s.items, .attributes = a });
        }
        // Only what shows the same: no spaces at the ends of a paragraph,
        // none at the ends of code, which a code span takes as padding.
        var normal: std.ArrayList(Run) = .empty;
        for (runs.items, 0..) |r, i| {
            var text = r.text;
            if (i == 0) text = std.mem.trimLeft(u8, text, " ");
            if (i == runs.items.len - 1) text = std.mem.trimRight(u8, text, " ");
            if (r.attributes.code) text = std.mem.trim(u8, text, " ");
            if (text.len == 0) continue;
            if (normal.items.len > 0 and normal.items[normal.items.len - 1].attributes.eql(r.attributes)) {
                normal.items[normal.items.len - 1].text = try std.mem.concat(arena, u8, &.{ normal.items[normal.items.len - 1].text, text });
                continue;
            }
            try normal.append(arena, .{ .text = text, .attributes = r.attributes });
        }
        var want = try Text.of(gpa, &.{.{ .runs = normal.items }});
        defer want.deinit();
        const m = try rt.toMarkdown(gpa, &want);
        defer gpa.free(m);
        var got = try rt.parseMarkdown(gpa, m);
        defer got.deinit();
        const a = try dump(&got);
        defer gpa.free(a);
        const b = try dump(&want);
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) {
            failures += 1;
            if (failures <= 5) std.debug.print("Markdown {s}\nreads\n{s}want\n{s}\n", .{ m, a, b });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
