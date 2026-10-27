const std = @import("std");
const rt = @import("root.zig");

const testing = std.testing;
const Text = rt.Text;
const Attributes = rt.Attributes;

fn expectString(t: *const Text, want: []const u8) !void {
    const s = try t.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(want, s);
}

test "a text of paragraphs keeps its runs, styles and newlines" {
    var t = try Text.of(testing.allocator, &.{
        .{ .style = .{ .heading = 1 }, .runs = &.{.{ .text = "Groceries" }} },
        .{ .style = .{ .list = .tasks }, .runs = &.{ .{ .text = "Milk " }, .{ .text = "now", .attributes = .{ .weight = 700 } } } },
    });
    defer t.deinit();
    try testing.expectEqual(@as(u32, 2), t.paragraphCount());
    try testing.expectEqual(@as(u32, 18), t.len());
    try expectString(&t, "Groceries\nMilk now");
    try testing.expectEqual(@as(u8, 1), t.paragraphStyleAt(3).heading);
    try testing.expectEqual(rt.ListKind.tasks, t.paragraphStyleAt(9 + 1).list);
    try testing.expect(t.attributesAt(15).bold());
    try testing.expect(!t.attributesAt(14).bold());
    // The end of the text takes what typing gets there: bold, extending.
    try testing.expect(t.attributesAt(18).bold());
    const r = t.paragraphRange(12);
    try testing.expectEqual(@as(u32, 10), r.start);
    try testing.expectEqual(@as(u32, 18), r.end);
}

test "replace joins and splits paragraphs as word processors do" {
    var t = try Text.of(testing.allocator, &.{
        .{ .style = .{ .heading = 2 }, .runs = &.{.{ .text = "Title" }} },
        .{ .runs = &.{.{ .text = "Body" }} },
    });
    defer t.deinit();
    // Deleting the newline after a heading keeps the heading.
    try t.delete(5, 6);
    try expectString(&t, "TitleBody");
    try testing.expectEqual(@as(u32, 1), t.paragraphCount());
    try testing.expectEqual(@as(u8, 2), t.paragraphStyleAt(0).heading);
    // A newline splits it; both halves keep the style.
    try t.replaceString(5, 5, "\n", .{});
    try testing.expectEqual(@as(u32, 2), t.paragraphCount());
    try testing.expectEqual(@as(u8, 2), t.paragraphStyleAt(6).heading);
    try t.replaceString(2, 2, "ü€", .{ .italic = true });
    try expectString(&t, "Tiü€tle\nBody");
    try testing.expect(t.attributesAt(3).italic);
    try testing.expect(!t.attributesAt(4).italic);
}

test "slice and replace with a text carry attributes and styles" {
    var t = try Text.of(testing.allocator, &.{
        .{ .runs = &.{ .{ .text = "a " }, .{ .text = "link", .attributes = .{ .link = "https://example.com" } } } },
        .{ .style = .{ .quote = true }, .runs = &.{.{ .text = "quoted" }} },
    });
    defer t.deinit();
    var s = try t.slice(testing.allocator, 2, 9);
    defer s.deinit();
    try expectString(&s, "link\nqu");
    try testing.expectEqualStrings("https://example.com", s.attributesAt(1).link);
    try testing.expect(s.paragraphStyleAt(6).quote);
    var u = try Text.initString(testing.allocator, "start ");
    defer u.deinit();
    try u.replace(6, 6, &s);
    try expectString(&u, "start link\nqu");
    try testing.expectEqualStrings("https://example.com", u.attributesAt(7).link);
    try testing.expect(u.paragraphStyleAt(12).quote);
    try testing.expect(!u.paragraphStyleAt(0).quote);
}

const Bold = struct {
    on: bool,
    pub fn change(self: Bold, a: *Attributes) void {
        a.weight = if (self.on) 700 else 0;
    }
};

test "format changes runs and joins neighbours alike" {
    var t = try Text.initString(testing.allocator, "one two three");
    defer t.deinit();
    try testing.expect(try t.format(4, 7, Bold{ .on = true }));
    try testing.expectEqual(@as(usize, 3), t.paras.items[0].runs.items.len);
    try testing.expect(!try t.format(4, 7, Bold{ .on = true }));
    try testing.expect(try t.format(0, 13, Bold{ .on = false }));
    try testing.expectEqual(@as(usize, 1), t.paras.items[0].runs.items.len);
    var it = t.rangeRuns(0, 13);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "runs of a range give newlines on their own" {
    var t = try Text.initString(testing.allocator, "ab\ncd");
    defer t.deinit();
    var it = t.rangeRuns(1, 4);
    const a = it.next().?;
    try testing.expectEqualStrings("b", a.run.text);
    try testing.expectEqual(@as(u32, 1), a.start);
    const nl = it.next().?;
    try testing.expectEqualStrings("\n", nl.run.text);
    try testing.expectEqual(@as(u32, 2), nl.start);
    const c = it.next().?;
    try testing.expectEqualStrings("c", c.run.text);
    try testing.expect(it.next() == null);
}

test "attachments take one object replacement character" {
    const image: rt.Attachment = .{ .name = "cat", .width = 20, .height = 10 };
    var t = try Text.of(testing.allocator, &.{.{ .runs = &.{ .{ .text = "x" }, .{ .text = rt.object_replacement_utf8 ++ rt.object_replacement_utf8, .attributes = .{ .attachment = &image } } } }});
    defer t.deinit();
    // "x", each attachment, and the end.
    try testing.expectEqual(@as(usize, 4), t.paras.items[0].runs.items.len);
    try testing.expectEqualStrings("cat", t.attributesAt(1).attachment.?.name);
    try testing.expect(t.attributesAt(1).attachment != &image);
    const plain = try t.plainText(testing.allocator);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("x", plain);
}

var fake_now: i64 = 0;
fn fakeClock() i64 {
    return fake_now;
}

fn docString(d: *const rt.Document) ![]u8 {
    return d.text.string(testing.allocator);
}

fn expectDoc(d: *const rt.Document, want: []const u8) !void {
    const s = try docString(d);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(want, s);
}

const Typed = struct {
    at: u32,
    s: []const u8,
    fn run(c: Typed, e: *rt.Edit) !void {
        try e.replaceString(c.at, c.at, c.s, .{});
        e.select(c.at + 1, c.at + 1);
    }
};

test "undo takes back a step with its formats, and redo brings it again" {
    var d = try rt.Document.initString(testing.allocator, "hello world");
    defer d.deinit();
    d.clock = fakeClock;
    d.setSelection(0, 5);
    try d.toggleBold();
    try testing.expect(d.text.attributesAt(2).bold());
    try testing.expectEqual(rt.FormatState.on, d.formatting().bold);
    d.setSelection(3, 8);
    try testing.expectEqual(rt.FormatState.mixed, d.formatting().bold);
    try d.insertText("X\nY");
    try expectDoc(&d, "helX\nYrld");
    try testing.expectEqual(@as(u32, 6), d.selection().caret);
    try d.undo();
    try expectDoc(&d, "hello world");
    try testing.expectEqual(@as(u32, 3), d.selection().anchor);
    try testing.expectEqual(@as(u32, 8), d.selection().caret);
    try d.undo();
    try testing.expect(!d.text.attributesAt(2).bold());
    try testing.expect(!d.canUndo());
    try d.redo();
    try d.redo();
    try expectDoc(&d, "helX\nYrld");
    try testing.expect(d.text.attributesAt(2).bold());
    try testing.expect(!d.canRedo());
}

test "typing joins one step while it goes on" {
    var d = try rt.Document.initString(testing.allocator, "");
    defer d.deinit();
    d.clock = fakeClock;
    fake_now = 10_000;
    for ("abc", 0..) |c, i| {
        try d.editStep(.typing, Typed{ .at = @intCast(i), .s = &.{c} }, Typed.run);
        fake_now += 100;
    }
    fake_now += 5000;
    try d.editStep(.typing, Typed{ .at = 3, .s = "d" }, Typed.run);
    try expectDoc(&d, "abcd");
    try testing.expectEqual(@as(usize, 2), d.undo_steps.items.len);
    try d.undo();
    try expectDoc(&d, "abc");
    try d.undo();
    try expectDoc(&d, "");
}

test "commands at a caret set the typing attributes" {
    var d = try rt.Document.initString(testing.allocator, "ab");
    defer d.deinit();
    d.setSelection(1, 1);
    try d.toggleItalic();
    try testing.expect(d.typingAttributes().italic);
    try testing.expect(!d.text.attributesAt(0).italic);
    try d.insertText("x");
    try testing.expect(d.text.attributesAt(1).italic);
    // Moving the caret forgets them.
    d.setSelection(3, 3);
    try testing.expect(!d.typingAttributes().italic);
}

test "lists, quotations, blocks of code and headings toggle on paragraphs" {
    var d = try rt.Document.initString(testing.allocator, "one\ntwo\nthree");
    defer d.deinit();
    d.setSelection(1, 5);
    try d.toggleList(.bullets);
    try testing.expectEqual(rt.ListKind.bullets, d.text.para(0).style.list);
    try testing.expectEqual(rt.ListKind.bullets, d.text.para(1).style.list);
    try testing.expectEqual(rt.ListKind.none, d.text.para(2).style.list);
    try d.toggleList(.bullets);
    try testing.expectEqual(rt.ListKind.none, d.text.para(0).style.list);
    try d.indent(2);
    try testing.expectEqual(@as(u8, 2), d.text.para(1).style.indent);
    try d.indent(-5);
    try testing.expectEqual(@as(u8, 0), d.text.para(1).style.indent);
    try d.setHeading(2);
    try testing.expectEqual(@as(u8, 2), d.formatting().paragraph.heading);
    try d.toggleCodeBlock();
    try testing.expect(d.text.para(0).style.code_block);
    try testing.expectEqual(@as(u8, 0), d.text.para(0).style.heading);
    // A selection ending at the start of a paragraph leaves it.
    d.setSelection(0, 8);
    try d.toggleQuote();
    try testing.expect(d.text.para(1).style.quote);
    try testing.expect(!d.text.para(2).style.quote);
    d.setSelection(9, 9);
    try d.toggleList(.tasks);
    try d.toggleChecked(9);
    try testing.expect(d.text.para(2).style.checked);
}

test "links cover the selection, or the link at a caret" {
    var d = try rt.Document.initString(testing.allocator, "see docs here");
    defer d.deinit();
    d.setSelection(4, 8);
    try d.setLink("https://a.example");
    try testing.expectEqualStrings("https://a.example", d.formatting().link);
    d.setSelection(6, 6);
    try d.setLink("https://b.example");
    try testing.expectEqualStrings("https://b.example", d.text.attributesAt(4).link);
    try testing.expectEqualStrings("https://b.example", d.text.attributesAt(7).link);
    try testing.expectEqualStrings("", d.text.attributesAt(8).link);
    // At a caret outside a link, the URL goes in, linked to itself.
    d.setSelection(0, 0);
    try d.setLink("x.y");
    try expectDoc(&d, "x.ysee docs here");
    try testing.expectEqualStrings("x.y", d.text.attributesAt(1).link);
    // Typing at a link's edge does not continue it.
    d.setSelection(3, 3);
    try testing.expectEqualStrings("", d.typingAttributes().link);
}

test "typing at the end of a line linked whole does not continue the link" {
    var d = try rt.Document.initString(testing.allocator, "abc\nxyz");
    defer d.deinit();
    d.setSelection(0, 4);
    try d.setLink("u");
    d.setSelection(3, 3);
    try testing.expectEqualStrings("", d.typingAttributes().link);
}

test "a selection from a newline has the formats of the runes after it" {
    var t = try Text.of(testing.allocator, &.{
        .{ .runs = &.{.{ .text = "plain" }} },
        .{ .runs = &.{.{ .text = "BOLD", .attributes = .{ .weight = 700 } }} },
    });
    var d = rt.Document.init(testing.allocator, t);
    defer d.deinit();
    _ = &t;
    d.setSelection(5, 10);
    try testing.expectEqual(rt.FormatState.on, d.formatting().bold);
    try d.toggleBold();
    try testing.expect(!d.text.attributesAt(7).bold());
}

test "inserting over a selection leaves the caret after what it inserted" {
    var d = try rt.Document.initString(testing.allocator, "hello world");
    defer d.deinit();
    d.setSelection(6, 11);
    try d.insertText("there");
    try testing.expectEqual(rt.Selection{ .anchor = 11, .caret = 11 }, d.selection());
    d.setSelection(0, 1);
    var ab = try Text.initString(testing.allocator, "A\nB");
    defer ab.deinit();
    try d.insert(&ab);
    try testing.expectEqual(rt.Selection{ .anchor = 3, .caret = 3 }, d.selection());
}

test "formatting to the end formats what typing gets in a last empty paragraph" {
    var d = try rt.Document.initString(testing.allocator, "abc\n");
    defer d.deinit();
    d.setSelection(0, 4);
    try d.toggleBold();
    d.setSelection(4, 4);
    try testing.expect(d.typingAttributes().bold());
}

test "commands that change nothing make no step of undo" {
    var d = try rt.Document.initString(testing.allocator, "abc");
    defer d.deinit();
    d.setSelection(0, 3);
    const v = d.version;
    try d.setLink("");
    try d.toggleChecked(0);
    try testing.expectEqual(v, d.version);
    try testing.expect(!d.canUndo());
    for (0..200) |_| try d.insertText("x");
    const n = d.undo_steps.items.len;
    try d.edit({}, struct {
        fn f(_: void, _: *rt.Edit) !void {}
    }.f);
    try testing.expectEqual(n, d.undo_steps.items.len);
}

/// A rune of a naive attributed text, its attributes and the style of its
/// paragraph; 0 for the end of the text.
const Cell = struct { r: u21, a: Attributes, style: rt.ParagraphStyle };

fn naiveOf(allocator: std.mem.Allocator, t: *const Text) !std.ArrayList(Cell) {
    var out: std.ArrayList(Cell) = .empty;
    var i: u32 = 0;
    var p: u32 = 0;
    while (p < t.paragraphCount()) : (p += 1) {
        const q = t.para(p);
        var it = q.iterator();
        while (it.next()) |item| {
            var view = std.unicode.Utf8View.initUnchecked(item.run.text).iterator();
            while (view.nextCodepoint()) |c| {
                try out.append(allocator, .{ .r = c, .a = item.run.attributes, .style = q.style });
                i += 1;
            }
        }
        try out.append(allocator, .{ .r = if (i == t.len()) 0 else '\n', .a = t.attributesAt(i), .style = q.style });
        i += 1;
    }
    return out;
}

/// Gives every cell of a paragraph the style of its first.
fn normalizeNaive(cells: []Cell) void {
    var start: usize = 0;
    for (cells, 0..) |c, i| {
        if (c.r == '\n' or c.r == 0) {
            for (start..i + 1) |k| cells[k].style = cells[start].style;
            start = i + 1;
        }
    }
}

fn checkInvariants(t: *const Text) !void {
    var p: u32 = 0;
    while (p < t.paragraphCount()) : (p += 1) {
        const q = t.para(p);
        var sum: u32 = 0;
        for (q.runs.items, 0..) |r, k| {
            try testing.expect(r.n > 0);
            if (k > 0 and r.a.attachment == null) try testing.expect(!q.runs.items[k - 1].a.eql(r.a));
            sum += r.n;
        }
        try testing.expectEqual(rt.runeCount(q.text()), q.n);
        try testing.expectEqual(q.n + 1, sum);
        try testing.expect(std.mem.indexOfScalar(u8, q.text(), '\n') == null);
    }
}

fn compareNaive(t: *const Text, want: []const Cell) !void {
    try checkInvariants(t);
    var got = try naiveOf(testing.allocator, t);
    defer got.deinit(testing.allocator);
    try testing.expectEqual(want.len, got.items.len);
    for (got.items, want, 0..) |g, w, i| {
        if (!g.a.eql(w.a)) std.debug.print("rune {d}: attributes differ\n", .{i});
        try testing.expectEqual(w.r, g.r);
        try testing.expect(g.a.eql(w.a));
        try testing.expect(g.style.eql(w.style));
    }
}

const test_attrs = [_]Attributes{ .{}, .{ .weight = 700 }, .{ .italic = true }, .{ .link = "https://a" }, .{ .weight = 700, .italic = true }, .{ .color = rt.Color.rgb(0xc80000) } };
const test_styles = [_]rt.ParagraphStyle{ .{}, .{ .heading = 1 }, .{ .list = .bullets }, .{ .list = .numbers, .indent = 1 }, .{ .@"align" = .center } };

fn randomText(rng: std.Random) !Text {
    const words = [_][]const u8{ "a", "bc", "déf", "ghij", " ", "😀" };
    var paras: [4]rt.Paragraph = undefined;
    var runs: [4][3]rt.Run = undefined;
    const count = 1 + rng.uintLessThan(usize, 4);
    for (0..count) |k| {
        const n = rng.uintLessThan(usize, 4);
        for (0..@min(n, 3)) |i| runs[k][i] = .{ .text = words[rng.uintLessThan(usize, words.len)], .attributes = test_attrs[rng.uintLessThan(usize, test_attrs.len)] };
        paras[k] = .{ .style = test_styles[rng.uintLessThan(usize, test_styles.len)], .runs = runs[k][0..@min(n, 3)] };
    }
    return Text.of(testing.allocator, paras[0..count]);
}

const SetAttributes = struct {
    a: Attributes,
    pub fn change(self: SetAttributes, x: *Attributes) void {
        x.* = self.a;
    }
};
const SetStyle = struct {
    s: rt.ParagraphStyle,
    pub fn change(self: SetStyle, x: *rt.ParagraphStyle) void {
        x.* = self.s;
    }
};

test "random edits keep a text as a naive one of a cell a rune" {
    const gpa = testing.allocator;
    for (0..300) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed * 7 + 1);
        const rng = prng.random();
        var at = try randomText(rng);
        defer at.deinit();
        var model = try naiveOf(gpa, &at);
        defer model.deinit(gpa);
        // The texts the model's attributes point into.
        var held: std.ArrayList(Text) = .empty;
        defer {
            for (held.items) |*h| h.deinit();
            held.deinit(gpa);
        }
        try compareNaive(&at, model.items);
        for (0..30) |step| {
            const n = at.len();
            const a = rng.uintAtMost(u32, n);
            var z = a + rng.uintAtMost(u32, n - a);
            switch (rng.uintLessThan(u8, 4)) {
                0, 1 => {
                    var with = try randomText(rng);
                    if (rng.uintLessThan(u8, 3) == 0) {
                        // A piece of the text itself, as a paste.
                        const b = rng.uintAtMost(u32, n);
                        with.deinit();
                        with = try at.slice(gpa, b, b + rng.uintAtMost(u32, n - b));
                    }
                    var wm = try naiveOf(gpa, &with);
                    defer wm.deinit(gpa);
                    var next: std.ArrayList(Cell) = .empty;
                    try next.appendSlice(gpa, model.items[0..a]);
                    try next.appendSlice(gpa, wm.items[0 .. wm.items.len - 1]);
                    try next.appendSlice(gpa, model.items[z..]);
                    normalizeNaive(next.items);
                    model.deinit(gpa);
                    model = next;
                    try at.replace(a, z, &with);
                    try held.append(gpa, with);
                },
                2 => {
                    const attrs = test_attrs[rng.uintLessThan(usize, test_attrs.len)];
                    _ = try at.format(a, z, SetAttributes{ .a = attrs });
                    // To the end of the text, what typing gets there.
                    if (z == n and a < z) z += 1;
                    for (a..z) |i| {
                        model.items[i].a = attrs;
                        model.items[i].a.attachment = null;
                    }
                },
                else => {
                    const style = test_styles[rng.uintLessThan(usize, test_styles.len)];
                    const span = at.paragraphSpan(a, z);
                    _ = at.formatParagraphs(a, z, SetStyle{ .s = style });
                    var p: u32 = 0;
                    for (model.items) |*c| {
                        if (p >= span.first and p <= span.last) c.style = style;
                        if (c.r == '\n') p += 1;
                    }
                },
            }
            compareNaive(&at, model.items) catch |err| {
                std.debug.print("seed {d} step {d}\n", .{ seed, step });
                return err;
            };
        }
    }
}

test "putting a slice back where it came from changes nothing" {
    const gpa = testing.allocator;
    for (0..200) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed * 9 + 2);
        const rng = prng.random();
        var at = try randomText(rng);
        defer at.deinit();
        const n = at.len();
        const a = rng.uintAtMost(u32, n);
        const z = a + rng.uintAtMost(u32, n - a);
        var got = try at.clone(gpa);
        defer got.deinit();
        var piece = try at.slice(gpa, a, z);
        defer piece.deinit();
        try got.replace(a, z, &piece);
        if (!got.eql(&at)) {
            var p: u32 = 0;
            std.debug.print("seed {d} [{d},{d})\n", .{ seed, a, z });
            while (p < at.paragraphCount()) : (p += 1) {
                std.debug.print(" at {s} {any}\n", .{ at.para(p).text(), at.para(p).style });
                for (at.para(p).runs.items) |r| std.debug.print("   {d} w{d} i{} l{s}\n", .{ r.n, r.a.weight, r.a.italic, r.a.link });
            }
            p = 0;
            while (p < got.paragraphCount()) : (p += 1) {
                std.debug.print(" got {s} {any}\n", .{ got.para(p).text(), got.para(p).style });
                for (got.para(p).runs.items) |r| std.debug.print("   {d} w{d} i{} l{s}\n", .{ r.n, r.a.weight, r.a.italic, r.a.link });
            }
            return error.TestUnexpectedResult;
        }
    }
}
