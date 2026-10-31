const std = @import("std");
const z = @import("ziggurat");
const rt = @import("ziggurat_rich_text");
const ed = @import("editor.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Text = rt.Text;
const Document = rt.Document;
const Editor = ed.Editor;
const Attributes = rt.Attributes;

/// An editor of doc in a box of 500×400, laid out, the caret at the end.
fn tester(doc: *Document, options: ed.Options) !Editor {
    var e = Editor.init(undefined, gpa, doc, options);
    e.bounds = .{ .x = 0, .y = 0, .width = 500, .height = 400 };
    try e.layoutNow();
    return e;
}

fn ctrl(e: *Editor, k: z.KeyCode) void {
    _ = e.handle(.{ .key_input = .{ .key = k, .modifiers = .{ .control = true } } });
}
fn ctrlShift(e: *Editor, k: z.KeyCode) void {
    _ = e.handle(.{ .key_input = .{ .key = k, .modifiers = .{ .control = true, .shift = true } } });
}
fn press(e: *Editor, k: z.KeyCode) void {
    _ = e.handle(.{ .key_input = .{ .key = k } });
}
fn typeText(e: *Editor, s: []const u8) void {
    _ = e.handle(.{ .text_input = .{ .text = s, .producer = .application } });
}
/// Types s a rune at a time, as a keyboard does.
fn typeRunes(e: *Editor, s: []const u8) void {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |r| typeText(e, r);
}
fn compose(e: *Editor, s: []const u8) void {
    _ = e.handle(.{ .text_preedit = .{ .text = s, .selection_start = s.len, .selection_end = s.len } });
}
fn select(e: *Editor, doc: *Document, a: u32, b: u32) !void {
    doc.setSelection(a, b);
    try e.layoutNow();
}

/// The runs of a text, marked: *bold*, _italic_, ~underline~, `code`,
/// [link], joined by "|".
fn runsOf(t: *const Text) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var last: ?Attributes = null;
    var parts: usize = 0;
    var it = t.rangeRuns(0, t.len());
    while (it.next()) |item| {
        const a = item.run.attributes;
        if (last != null and last.?.eql(a)) {
            try pending.appendSlice(gpa, item.run.text);
            continue;
        }
        if (last) |l| {
            if (parts > 0) try out.writer.writeByte('|');
            try mark(&out.writer, pending.items, l);
            parts += 1;
        }
        pending.clearRetainingCapacity();
        try pending.appendSlice(gpa, item.run.text);
        last = a;
    }
    if (last) |l| {
        if (parts > 0) try out.writer.writeByte('|');
        try mark(&out.writer, pending.items, l);
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

fn expectRuns(doc: *Document, want: []const u8) !void {
    const got = try runsOf(&doc.text);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectString(doc: *Document, want: []const u8) !void {
    const s = try doc.text.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings(want, s);
}

fn empty() !Document {
    return Document.init(gpa, try Text.init(gpa));
}

test "typing takes the typing attributes, and continues bold at its end only" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeText(&e, "plain ");
    ctrl(&e, .b);
    typeText(&e, "bold");
    ctrl(&e, .b);
    typeText(&e, " more");
    try expectRuns(&doc, "plain |*bold*| more");
    try testing.expect(e.takeChanged());
    try select(&e, &doc, 10, 10);
    typeText(&e, "er");
    try select(&e, &doc, 6, 6);
    typeText(&e, "x");
    try expectRuns(&doc, "plain x|*bolder*| more");
}

test "typing at the edges of a link does not continue it" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{.{ .runs = &.{ .{ .text = "see " }, .{ .text = "docs", .attributes = .{ .link = "https://x" } }, .{ .text = " now" } } }}));
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 8, 8);
    typeText(&e, "!");
    try select(&e, &doc, 6, 6);
    typeText(&e, "o");
    try expectRuns(&doc, "see |[doocs]|! now");
}

test "a format at a caret is no step of undo, and moving forgets it" {
    var doc = try Document.initString(gpa, "hello");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    ctrl(&e, .b);
    try testing.expect(!doc.canUndo());
    try testing.expectEqual(rt.FormatState.on, doc.formatting().bold);
    press(&e, .left);
    try testing.expectEqual(rt.FormatState.off, doc.formatting().bold);
}

test "undo brings back the attributes deleted, and the selection" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{.{ .runs = &.{ .{ .text = "a " }, .{ .text = "bold", .attributes = .{ .weight = 700 } }, .{ .text = " word" } } }}));
    defer doc.deinit();
    var before = try doc.text.clone(gpa);
    defer before.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 2, 6);
    press(&e, .backspace);
    try expectString(&doc, "a  word");
    ctrl(&e, .z);
    try testing.expect(doc.text.eql(&before));
    try testing.expectEqual(rt.Selection{ .anchor = 2, .caret = 6 }, doc.selection());
    ctrlShift(&e, .z);
    try expectString(&doc, "a  word");
}

test "formats undo one at a time" {
    var doc = try Document.initString(gpa, "one two");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 4, 7);
    ctrl(&e, .i);
    ctrl(&e, .u);
    try expectRuns(&doc, "one |~_two_~");
    ctrl(&e, .z);
    try expectRuns(&doc, "one |_two_");
    try testing.expectEqual(rt.Selection{ .anchor = 4, .caret = 7 }, doc.selection());
}

test "lists continue, leave, indent and outdent" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "- milk");
    press(&e, .enter);
    typeRunes(&e, "eggs");
    press(&e, .enter);
    try expectString(&doc, "milk\neggs\n");
    for (0..3) |p| try testing.expectEqual(rt.ListKind.bullets, doc.text.para(@intCast(p)).style.list);
    // Enter on an empty item leaves the list.
    press(&e, .enter);
    try expectString(&doc, "milk\neggs\n");
    try testing.expectEqual(rt.ListKind.none, doc.text.paragraphStyleAt(doc.text.len()).list);
    // Tab indents an item, Backspace at its start outdents it, then takes
    // it out of the list.
    try select(&e, &doc, 5, 5);
    press(&e, .tab);
    try testing.expectEqual(@as(u8, 1), doc.text.paragraphStyleAt(5).indent);
    press(&e, .backspace);
    press(&e, .backspace);
    const st = doc.text.paragraphStyleAt(5);
    try testing.expectEqual(rt.ListKind.none, st.list);
    try testing.expectEqual(@as(u8, 0), st.indent);
}

test "headings by shortcut, which undo takes back to what was typed" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "## Title");
    press(&e, .enter);
    typeRunes(&e, "body");
    try expectString(&doc, "Title\nbody");
    try testing.expectEqual(@as(u8, 2), doc.text.paragraphStyleAt(0).heading);
    try testing.expectEqual(@as(u8, 0), doc.text.paragraphStyleAt(7).heading);

    var doc2 = try empty();
    defer doc2.deinit();
    var e2 = try tester(&doc2, .{});
    defer e2.deinit();
    typeRunes(&e2, "# ");
    ctrl(&e2, .z);
    try expectString(&doc2, "# ");
    try testing.expectEqual(@as(u8, 0), doc2.text.paragraphStyleAt(0).heading);
}

test "inline shortcuts format what their marks hold" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "a **big** and `x` then");
    try expectRuns(&doc, "a |*big*| and |`x`| then");
}

test "an underscore inside a word is no mark" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "snake_case_name and _this_");
    try expectRuns(&doc, "snake_case_name and |_this_");
}

test "a composition commits in the typing attributes" {
    var doc = try Document.initString(gpa, "ab");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    ctrl(&e, .b);
    compose(&e, "ni");
    compose(&e, "你");
    compose(&e, "");
    typeText(&e, "你");
    try expectRuns(&doc, "ab|*你*");
}

test "the editor follows the commands the application runs" {
    var doc = try Document.initString(gpa, "first\nsecond");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    doc.setSelection(0, 3);
    try doc.toggleBold();
    try doc.setHeading(1);
    try e.layoutNow();
    try expectRuns(&doc, "*fir*|st\nsecond");
    try testing.expectEqual(@as(u8, 1), doc.text.paragraphStyleAt(0).heading);
    typeText(&e, "X");
    try expectRuns(&doc, "*X*|st\nsecond");
}

test "the format menu's commands" {
    var doc = try Document.initString(gpa, "one two");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 0, 3);
    try testing.expect(e.runCommand(.bold));
    try testing.expect(e.runCommand(.align_center));
    try expectRuns(&doc, "*one*| two");
    try testing.expectEqual(rt.Align.center, doc.text.paragraphStyleAt(0).@"align");
}

test "edges of formats as word processors have them" {
    const bold: Attributes = .{ .weight = 700 };
    const link: Attributes = .{ .link = "https://x" };
    const Case = struct { paras: []const rt.Paragraph, caret: u32, keys: enum { enter_x, backspace_x, x }, want: []const u8 };
    const cases = [_]Case{
        .{ .paras = &.{ .{ .runs = &.{ .{ .text = "plain " }, .{ .text = "bold", .attributes = bold } } }, .{ .runs = &.{.{ .text = "next" }} } }, .caret = 10, .keys = .enter_x, .want = "plain |*bold\nx\n*|next" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "plain " }, .{ .text = "B", .attributes = bold } } }}, .caret = 7, .keys = .backspace_x, .want = "plain |*x*" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "see " }, .{ .text = "docs", .attributes = link } } }}, .caret = 4, .keys = .x, .want = "see x|[docs]" },
        .{ .paras = &.{.{ .runs = &.{ .{ .text = "docs", .attributes = link }, .{ .text = " now" } } }}, .caret = 0, .keys = .x, .want = "x|[docs]| now" },
    };
    for (cases) |c| {
        var doc = Document.init(gpa, try Text.of(gpa, c.paras));
        defer doc.deinit();
        var e = try tester(&doc, .{});
        defer e.deinit();
        try select(&e, &doc, c.caret, c.caret);
        switch (c.keys) {
            .enter_x => press(&e, .enter),
            .backspace_x => press(&e, .backspace),
            .x => {},
        }
        typeRunes(&e, "x");
        try expectRuns(&doc, c.want);
    }
}

test "typing a word is one step of undo" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "abc");
    ctrl(&e, .z);
    try expectString(&doc, "");
}

test "undo takes back what an input method committed, not the typing before" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    typeRunes(&e, "hello");
    press(&e, .left);
    press(&e, .right);
    compose(&e, "ni");
    typeText(&e, "你");
    try expectString(&doc, "hello你");
    ctrl(&e, .z);
    try expectString(&doc, "hello");
}

test "a composition the application's selection drops leaves the caret there" {
    var doc = try empty();
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    const start = e.caret_rect.?;
    typeRunes(&e, "abc");
    compose(&e, "nihao");
    try select(&e, &doc, 0, 0);
    try testing.expectEqual(start.x, e.caret_rect.?.x);
    typeText(&e, "z");
    try expectString(&doc, "zabc");
}

test "Enter at the start of a checked task keeps it checked, an empty item above" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{.{ .style = .{ .list = .tasks, .checked = true }, .runs = &.{.{ .text = "done" }} }}));
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 0, 0);
    press(&e, .enter);
    try expectString(&doc, "\ndone");
    try testing.expect(!doc.text.paragraphStyleAt(0).checked);
    try testing.expect(doc.text.paragraphStyleAt(1).checked);
}

fn click(e: *Editor, x: f32, y: f32) void {
    _ = e.handle(.{ .pointer_down = .{ .position = .{ .x = x, .y = y } } });
    _ = e.handle(.{ .pointer_up = .{ .position = .{ .x = x, .y = y } } });
}

fn hoverAt(e: *Editor, x: f32, y: f32) ed.Cursor {
    _ = e.handle(.{ .pointer_move = .{ .x = x, .y = y } });
    return e.cursor;
}

fn find(e: *Editor, want: ed.Cursor) ?[2]f32 {
    var y: f32 = 2;
    while (y < 80) : (y += 2) {
        var x: f32 = 0;
        while (x < 200) : (x += 2) if (hoverAt(e, x, y) == want) return .{ x, y };
    }
    return null;
}

test "an arrow over a task's box, which a click checks, an I-beam over text, a hand over links" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{
        .{ .style = .{ .list = .tasks }, .runs = &.{.{ .text = "milk" }} },
        .{ .runs = &.{ .{ .text = "see " }, .{ .text = "the site", .attributes = .{ .link = "https://example.com" } } } },
    }));
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    const box = find(&e, .arrow) orelse return error.NoArrow;
    click(&e, box[0], box[1]);
    try testing.expect(doc.text.paragraphStyleAt(0).checked);
    try testing.expectEqual(ed.Cursor.text, hoverAt(&e, box[0] + 60, box[1]));
    try testing.expect(find(&e, .pointer) != null);
}

test "a click away from a task's box does not check it" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{.{ .style = .{ .list = .tasks }, .runs = &.{.{ .text = "todo" }} }}));
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    var x: f32 = 0;
    while (x < 40) : (x += 2) click(&e, x, 300);
    try testing.expect(!doc.text.paragraphStyleAt(0).checked);
}

test "a block of code's last line gets its room below back" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{
        .{ .style = .{ .code_block = true }, .runs = &.{.{ .text = "code" }} },
        .{ .style = .{ .code_block = true } },
        .{ .runs = &.{.{ .text = "after" }} },
    }));
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 5, 5);
    press(&e, .enter);
    try select(&e, &doc, doc.text.len(), doc.text.len());
    const got = e.caret_rect.?;
    var fresh = Document.init(gpa, try doc.text.clone(gpa));
    defer fresh.deinit();
    var f = try tester(&fresh, .{});
    defer f.deinit();
    try testing.expectEqual(f.caret_rect.?.y, got.y);
}

test "Ctrl+Up and Ctrl+Down move by paragraphs" {
    var doc = try Document.initString(gpa, "one two\nthree four\nfive");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 12, 12);
    ctrl(&e, .up);
    try testing.expectEqual(@as(u32, 8), doc.caret);
    ctrl(&e, .up);
    try testing.expectEqual(@as(u32, 0), doc.caret);
    ctrl(&e, .down);
    try testing.expectEqual(@as(u32, 8), doc.caret);
}

const Opened = struct {
    urls: [8][64]u8 = undefined,
    lens: [8]usize = @splat(0),
    n: usize = 0,
    fn call(context: ?*anyopaque, url: []const u8) void {
        const self: *Opened = @ptrCast(@alignCast(context.?));
        @memcpy(self.urls[self.n][0..url.len], url);
        self.lens[self.n] = url.len;
        self.n += 1;
    }
};

test "only safe links open" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{
        .{ .runs = &.{.{ .text = "run", .attributes = .{ .link = "calc" } }} },
        .{ .runs = &.{.{ .text = "site", .attributes = .{ .link = "https://example.com" } }} },
    }));
    defer doc.deinit();
    var opened: Opened = .{};
    var e = try tester(&doc, .{ .open_url = .{ .context = &opened, .call = Opened.call } });
    defer e.deinit();
    var y: f32 = 2;
    while (y < 80) : (y += 6) {
        if (hoverAt(&e, 14, y) == .pointer) click(&e, 14, y);
    }
    try testing.expect(opened.n > 0);
    for (0..opened.n) |i| try testing.expectEqualStrings("https://example.com", opened.urls[i][0..opened.lens[i]]);
}

const Board = struct {
    rich: std.ArrayList(u8) = .empty,
    html: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    fn deinit(self: *Board) void {
        self.rich.deinit(gpa);
        self.html.deinit(gpa);
        self.text.deinit(gpa);
    }
    fn write(context: ?*anyopaque, c: ed.Copied) anyerror!void {
        const self: *Board = @ptrCast(@alignCast(context.?));
        self.rich.clearRetainingCapacity();
        try self.rich.appendSlice(gpa, c.rich);
        self.html.clearRetainingCapacity();
        try self.html.appendSlice(gpa, c.html);
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(gpa, c.text);
    }
    fn read(context: ?*anyopaque, e: *Editor, match_style: bool) anyerror!void {
        const self: *Board = @ptrCast(@alignCast(context.?));
        e.paste(.{ .rich = self.rich.items, .html = self.html.items, .text = self.text.items }, match_style);
    }
};

test "copy and paste keep formats, and pasting matching the style drops them" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{.{ .runs = &.{ .{ .text = "a " }, .{ .text = "bold", .attributes = .{ .weight = 700 } }, .{ .text = " word" } } }}));
    defer doc.deinit();
    var board: Board = .{};
    defer board.deinit();
    var e = try tester(&doc, .{ .clipboard = .{ .context = &board, .write = Board.write, .read = Board.read } });
    defer e.deinit();
    try select(&e, &doc, 2, 6);
    ctrl(&e, .c);
    try testing.expectEqualStrings("bold", board.text.items);
    try select(&e, &doc, 11, 11);
    ctrl(&e, .v);
    try expectRuns(&doc, "a |*bold*| word|*bold*");
    try testing.expectEqual(@as(u32, 15), doc.caret);
    // Plain text in the typing attributes: bold, after bold.
    ctrlShift(&e, .v);
    try expectRuns(&doc, "a |*bold*| word|*boldbold*");
    // Another application's HTML.
    board.rich.clearRetainingCapacity();
    board.html.clearRetainingCapacity();
    try board.html.appendSlice(gpa, "<i>it</i>");
    ctrl(&e, .v);
    try expectRuns(&doc, "a |*bold*| word|*boldbold*|_it_");
    // Cut takes the selection to the clipboard.
    try select(&e, &doc, 0, 2);
    ctrl(&e, .x);
    try testing.expectEqualStrings("a ", board.text.items);
    try expectRuns(&doc, "*bold*| word|*boldbold*|_it_");
}

test "word and line keys, and a double click selecting a word" {
    var doc = try Document.initString(gpa, "one two three");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    ctrl(&e, .left);
    try testing.expectEqual(@as(u32, 8), doc.caret);
    ctrl(&e, .backspace);
    try expectString(&doc, "one three");
    press(&e, .home);
    try testing.expectEqual(@as(u32, 0), doc.caret);
    _ = e.handle(.{ .key_input = .{ .key = .end, .modifiers = .{ .shift = true } } });
    try testing.expectEqual(rt.Selection{ .anchor = 0, .caret = 9 }, doc.selection());
    ctrl(&e, .a);
    try testing.expectEqual(rt.Selection{ .anchor = 0, .caret = 9 }, doc.selection());
    // A double click on "three".
    const c = e.caret_rect.?;
    _ = e.handle(.{ .pointer_down = .{ .position = .{ .x = c.x - 5, .y = c.y + 4 }, .press = .{ .window_count = 2 } } });
    _ = e.handle(.{ .pointer_up = .{ .position = .{ .x = c.x - 5, .y = c.y + 4 } } });
    try testing.expectEqual(rt.Selection{ .anchor = 4, .caret = 9 }, doc.selection());
}

test "the input method reads the caret's paragraph in UTF-16 units" {
    var doc = try Document.initString(gpa, "a😀\nbé");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 4, 5);
    try testing.expectEqual(@as(usize, 4), e.units(3));
    try testing.expectEqual(@as(usize, 5), e.units(4));
    try testing.expectEqual(@as(u32, 4), e.runeOfUnits(5));
    try testing.expectEqual(@as(u32, 2), e.runeOfUnits(3));
}

test "a long text lays out only what is in view, and scrolls to the caret" {
    var t = try Text.init(gpa);
    for (0..2000) |i| {
        var buffer: [32]u8 = undefined;
        try t.append(try std.fmt.bufPrint(&buffer, "line {d}\n", .{i}), .{});
    }
    var doc = Document.init(gpa, t);
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try testing.expect(e.laid < 700);
    try testing.expect(e.scroll > 0);
    try select(&e, &doc, 0, 0);
    try testing.expectEqual(@as(f64, 0), e.scroll);
    _ = e.handle(.{ .wheel = .{ .position = .{ .x = 10, .y = 10 }, .delta = .{ .x = 0, .y = 300 } } });
    try testing.expect(e.scroll > 0);
}

test "list markers number by level" {
    var b: [20]u8 = undefined;
    try testing.expectEqualStrings("ab", ed.alphaNumber(28, &b));
    try testing.expectEqualStrings("xiv", ed.romanNumber(14, &b));
    try testing.expect(ed.safeToOpen("HTTPS://x.org"));
    try testing.expect(!ed.safeToOpen("calc"));
    try testing.expect(!ed.safeToOpen("file:///etc"));
    try testing.expect(!ed.safeToOpen("https://x\\y"));
}

test "font families of runs come from the first family of a CSS list" {
    const view = @import("ziggurat_view");
    var font: view.Font = .{};
    ed.applyFamily(&font, "'Courier New', monospace");
    try testing.expect(font.family != 0 and !font.monospace);
    const courier = font.family;
    font = .{};
    ed.applyFamily(&font, "\"courier new\"");
    try testing.expectEqual(courier, font.family);
    font = .{};
    ed.applyFamily(&font, "monospace, serif");
    try testing.expect(font.monospace and font.family == 0);
    font = .{};
    ed.applyFamily(&font, "sans-serif");
    try testing.expectEqual(@as(u8, 0), font.family);
}

test "each ideograph and kana is a word to the word keys" {
    var doc = try Document.initString(gpa, "中文abc かな def");
    defer doc.deinit();
    var e = try tester(&doc, .{});
    defer e.deinit();
    try select(&e, &doc, 0, 0);
    ctrl(&e, .right);
    try testing.expectEqual(@as(u32, 1), doc.caret);
    ctrl(&e, .right);
    try testing.expectEqual(@as(u32, 2), doc.caret);
    ctrl(&e, .right);
    try testing.expectEqual(@as(u32, 5), doc.caret);
    ctrl(&e, .right);
    try testing.expectEqual(@as(u32, 7), doc.caret);
    ctrl(&e, .left);
    try testing.expectEqual(@as(u32, 6), doc.caret);
    // Back to the start of "abc", over the space.
    ctrl(&e, .backspace);
    try expectString(&doc, "中文かな def");
    try testing.expectEqual(@as(u32, 2), doc.caret);
    ctrl(&e, .left);
    try testing.expectEqual(@as(u32, 1), doc.caret);
}

test "body paragraphs indent their first lines and take room between them" {
    var doc = Document.init(gpa, try Text.of(gpa, &.{
        .{ .runs = &.{.{ .text = "one" }} },
        .{ .runs = &.{.{ .text = "two" }} },
        .{ .style = .{ .heading = 2 }, .runs = &.{.{ .text = "Heading" }} },
        .{ .runs = &.{.{ .text = "three" }} },
        .{},
        .{ .runs = &.{.{ .text = "four" }} },
        .{ .style = .{ .@"align" = .center }, .runs = &.{.{ .text = "* * *" }} },
        .{ .runs = &.{.{ .text = "five" }} },
        .{ .runs = &.{.{ .text = "six" }} },
    }));
    defer doc.deinit();
    var e = try tester(&doc, .{ .theme = .{ .first_line_indent = 2, .paragraph_spacing = 1 } });
    defer e.deinit();
    const starts = [_]u32{ 0, 4, 8, 16, 22, 23, 28, 34, 39 };
    var xs: [starts.len]f32 = undefined;
    for (starts, &xs) |at, *x| {
        try select(&e, &doc, at, at);
        x.* = e.caret_rect.?.x;
    }
    // 2 ems of 14 DIP, after another body paragraph only.
    try testing.expectEqual(xs[0] + 28, xs[1]);
    for ([_]usize{ 3, 5, 7 }) |k| try testing.expectEqual(xs[0], xs[k]);
    try testing.expectEqual(xs[0] + 28, xs[8]);
    // Home and a click at the line's left go to the paragraph's start.
    try select(&e, &doc, 6, 6);
    press(&e, .home);
    try testing.expectEqual(@as(u32, 4), doc.caret);

    // The boxes of the paragraphs in view leave the room between them out.
    const boxes = try e.visibleParagraphs();
    try testing.expect(boxes.len >= 4);
    try testing.expectEqual(@as(usize, 0), boxes[0].index);
    try testing.expectEqual(@as(u32, 4), boxes[1].start);
    try testing.expectEqual(boxes[0].top + boxes[0].height + 14, boxes[1].top);
    // A body paragraph after a heading takes no spacing; the heading its
    // own room.
    try testing.expect(boxes[3].top > boxes[2].top + boxes[2].height);
    try testing.expectEqual(e.pad_y, boxes[0].top);
}
