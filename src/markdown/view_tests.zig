const std = @import("std");
const md = @import("ziggurat_markdown");
const view = @import("ziggurat_view");
const mv = @import("view.zig");

const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const equalStrings = std.testing.expectEqualStrings;

const Doc = struct {
    tree: md.Tree,
    options: mv.Options = .{},
    last: ?mv.Activation = null,
    fn build(self: *Doc, v: *view.View) anyerror!void {
        if (try mv.build(v, self.tree, self.options, .{})) |activation| self.last = activation;
    }
};

var parsed: md.Storage(512, 8192) = .{};
var storage: view.Storage(1024, 16384) = .{};

fn harness(doc: *Doc) view.Harness {
    return view.Harness.init(doc, Doc.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 2000 } });
}

test "blocks map to view nodes" {
    var doc: Doc = .{ .tree = try md.parse(
        \\# Title
        \\
        \\Some *text* with a [link](https://example.com/a) and `code`.
        \\
        \\> quoted
        \\
        \\1. one
        \\2. two
        \\
        \\- [x] done
        \\- [ ] todo
        \\
        \\```zig
        \\const a = 1;
        \\
        \\const b = 2;
        \\```
        \\
        \\| A | B |
        \\| - | -: |
        \\| 1 | 2 |
        \\
        \\***
    , parsed.buffers()) };
    var h = harness(&doc);
    try h.render();
    _ = try h.find(.{ .kind = .text, .text = "Title" });
    _ = try h.find(.{ .kind = .text, .text = "text" });
    _ = try h.find(.{ .kind = .text, .text = "code" });
    _ = try h.find(.{ .kind = .text, .text = "quoted" });
    _ = try h.find(.{ .kind = .text, .text = "1." });
    _ = try h.find(.{ .kind = .text, .text = "2." });
    _ = try h.find(.{ .kind = .text, .text = "const a = 1;" });
    _ = try h.find(.{ .kind = .text, .text = "const b = 2;" });
    _ = try h.find(.{ .kind = .text, .text = "A" });
    _ = try h.find(.{ .kind = .text, .text = "2" });
    try equal(@as(usize, 2), h.count(.{ .kind = .grid }));
    try equal(@as(usize, 2), h.count(.{ .kind = .checkbox }));
    const done = try h.find(.{ .kind = .checkbox, .name = "done" });
    try expect(done.checked and !done.style.enabled);
    try expect(!(try h.find(.{ .kind = .checkbox, .name = "todo" })).checked);

    // Emphasis keeps its run in an italic font; body text uses the label font.
    const emphasis = try h.find(.{ .kind = .text, .text = "text" });
    const plain = try h.find(.{ .kind = .text, .text = "Some " });
    try expect(plain.style.font == null);
    try expect(emphasis.style.font.?.italic and emphasis.style.font.?.weight == .regular);
    try expect(std.meta.eql(view.Font.code, (try h.find(.{ .kind = .text, .text = "code" })).style.font.?));
    try expect(std.meta.eql(view.Font.code, (try h.find(.{ .kind = .text, .text = "const a = 1;" })).style.font.?));
    try expect(std.meta.eql(view.Font.heading1, (try h.find(.{ .kind = .text, .text = "Title" })).style.font.?));
    try expect((try h.find(.{ .kind = .text, .text = "A" })).style.font.?.weight == .semibold);

    try h.click(.{ .kind = .link, .text = "link" });
    try equalStrings("https://example.com/a", doc.last.?.link);
}

test "inline styles combine with the block font" {
    var doc: Doc = .{ .tree = try md.parse("## A **b *c*** `d`\n\n***e*** ~~f~~", parsed.buffers()) };
    var h = harness(&doc);
    try h.render();
    const heading = (try h.find(.{ .kind = .text, .text = "A " })).style.font.?;
    try expect(std.meta.eql(view.Font.heading2, heading));
    const strong = (try h.find(.{ .kind = .text, .text = "b " })).style.font.?;
    try expect(strong.size == heading.size and strong.weight == .bold and !strong.italic);
    const both = (try h.find(.{ .kind = .text, .text = "c" })).style.font.?;
    try expect(both.size == heading.size and both.weight == .bold and both.italic);
    const code = (try h.find(.{ .kind = .text, .text = "d" })).style.font.?;
    try expect(code.monospace and code.size < heading.size and code.weight == .bold);
    const e = (try h.find(.{ .kind = .text, .text = "e" })).style.font.?;
    try expect(e.size == view.Font.body.size and e.weight == .bold and e.italic);
    try expect((try h.find(.{ .kind = .text, .text = "f" })).style.font == null);

    // Larger fonts wrap sooner: heading 1 measures twice the body width.
    doc.tree = try md.parse("# alpha beta\n\nalpha beta", parsed.buffers());
    doc.options.width = 100;
    try h.render();
    _ = try h.find(.{ .kind = .text, .text = "alpha" });
    _ = try h.find(.{ .kind = .text, .text = "beta" });
    _ = try h.find(.{ .kind = .text, .text = "alpha beta" });
}

test "paragraphs wrap at the given width" {
    var doc: Doc = .{ .tree = try md.parse("alpha beta gamma delta epsilon zeta eta theta", parsed.buffers()), .options = .{ .width = 100 } };
    var h = harness(&doc);
    try h.render();
    // The estimating measurer gives 9 DIP per character.
    try equal(@as(usize, 5), h.count(.{ .kind = .text }));
    _ = try h.find(.{ .kind = .text, .text = "alpha beta" });
    _ = try h.find(.{ .kind = .text, .text = "gamma delta" });
    _ = try h.find(.{ .kind = .text, .text = "epsilon" });
    _ = try h.find(.{ .kind = .text, .text = "zeta eta" });
    _ = try h.find(.{ .kind = .text, .text = "theta" });
    for (h.nodes()) |node| if (node.kind == .text) try expect(node.bounds.width <= 100);

    doc.tree = try md.parse("中文段落可以在任意两个字之间换行", parsed.buffers());
    doc.options.width = 64;
    try h.render();
    _ = try h.find(.{ .kind = .text, .text = "中文段落" });
    _ = try h.find(.{ .kind = .text, .text = "之间换行" });

    doc.tree = try md.parse("abcdefghijklmnopqrstuvwxyz", parsed.buffers());
    doc.options.width = 90;
    try h.render();
    _ = try h.find(.{ .kind = .text, .text = "abcdefghij" });
    _ = try h.find(.{ .kind = .text, .text = "uvwxyz" });

    doc.tree = try md.parse("one  \ntwo\nthree", parsed.buffers());
    doc.options.width = 640;
    try h.render();
    _ = try h.find(.{ .kind = .text, .text = "one" });
    _ = try h.find(.{ .kind = .text, .text = "two" });
    _ = try h.find(.{ .kind = .text, .text = "three" });
}

test "wrapped links and interactive tasks report activations" {
    const source = "see [a long link label](/target) here\n\n- [ ] task one\n";
    var doc: Doc = .{ .tree = try md.parse(source, parsed.buffers()), .options = .{ .width = 120, .interactive_tasks = true } };
    var h = harness(&doc);
    try h.render();
    try expect(h.count(.{ .kind = .link }) >= 2);
    try h.click(.{ .kind = .link, .nth = 1 });
    try equalStrings("/target", doc.last.?.link);

    try h.click(.{ .kind = .checkbox });
    const task = doc.last.?.task;
    try expect(task.checked);
    const item = doc.tree.get(task.node);
    var copy: [64]u8 = undefined;
    @memcpy(copy[0..source.len], source);
    const offset = mv.taskOffset(copy[0..source.len], item.line).?;
    mv.toggleTask(copy[0..source.len], offset, task.checked);
    try expect(std.mem.indexOf(u8, copy[0..source.len], "- [x] task one") != null);
    try equal(@as(?usize, null), mv.taskOffset(source, 0));
}

const FakeFace = struct {
    calls: usize = 0,
    fn measure(_: *anyopaque, _: view.Theme) view.layout.Measurement {
        return .{ .minimum = .{ .width = 10, .height = 10 }, .preferred = .{ .width = 300, .height = 40 } };
    }
    fn paint(_: *anyopaque, _: *@import("ziggurat_ui").Frame, _: u64, _: view.Rect) anyerror!void {}
    fn embed(context: *anyopaque, tree: md.Tree, index: u32) ?view.Embed {
        const self: *FakeFace = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (!std.mem.eql(u8, tree.get(index).url, "zig")) return null;
        return .{ .context = context, .measure = measure, .paint = paint };
    }
};

test "code blocks use the monospace face when it has one" {
    var face: FakeFace = .{};
    var doc: Doc = .{ .tree = try md.parse("```zig\nconst a = 1;\n```\n\n```\nplain\n```", parsed.buffers()), .options = .{ .code = .{ .context = &face, .embed = FakeFace.embed } } };
    var h = harness(&doc);
    try h.render();
    try equal(@as(usize, 1), h.count(.{ .kind = .embed }));
    try equal(@as(usize, 0), h.count(.{ .kind = .text, .text = "const a = 1;" }));
    _ = try h.find(.{ .kind = .text, .text = "plain" });
    try equal(@as(usize, 2), face.calls);
    const embed = try h.find(.{ .kind = .embed });
    try equal(@as(f32, 300), embed.bounds.width);
}

test "long documents nest containers below the child limit" {
    var big: md.Storage(4096, 32768) = .{};
    var source: [3000]u8 = undefined;
    var len: usize = 0;
    for (0..300) |index| {
        const line = try std.fmt.bufPrint(source[len..], "{d}\n\n", .{index % 10});
        len += line.len;
    }
    var doc: Doc = .{ .tree = try md.parse(source[0..len], big.buffers()) };
    var nodes: view.Storage(2048, 16384) = .{};
    var h = view.Harness.init(&doc, Doc.build, nodes.buffers(), .{});
    try h.render();
    try equal(@as(usize, 300), h.count(.{ .kind = .text }));
}

const Scrolled = struct {
    tree: md.Tree,
    options: mv.Options = .{},
    model: view.ScrollModel = .{},
    state: mv.AnchorState = .{},
    last: ?mv.Activation = null,
    fn build(self: *Scrolled, v: *view.View) anyerror!void {
        var options = self.options;
        options.anchor_state = &self.state;
        try v.scroll(&self.model, .{ .height = 160 });
        if (try mv.build(v, self.tree, options, .{})) |activation| self.last = activation;
        try v.end();
    }
};

var long_source: [4096]u8 = undefined;
fn document(first: []const u8, filler: []const u8, count: usize, last: []const u8) ![]const u8 {
    var len: usize = 0;
    for ([_][]const u8{ first, "\n\n" }) |piece| {
        @memcpy(long_source[len..][0..piece.len], piece);
        len += piece.len;
    }
    for (0..count) |_| {
        @memcpy(long_source[len..][0..filler.len], filler);
        len += filler.len;
    }
    @memcpy(long_source[len..][0..last.len], last);
    len += last.len;
    return long_source[0..len];
}

test "headings take GitHub's slugs" {
    var buffer: [mv.max_slug]u8 = undefined;
    try equalStrings("getting-started", mv.slug("Getting Started", &buffer));
    try equalStrings("whats-new-in-v2_0", mv.slug(" What's new in v2_0? ", &buffer));
    try equalStrings("安装-zig", mv.slug("安装 Zig", &buffer));
    const tree = try md.parse("# Intro\n\n## Getting *Started*\n\ntext", parsed.buffers());
    try equal(@as(?u32, null), mv.headingNamed(tree, "#text"));
    const index = mv.headingNamed(tree, "#getting-started").?;
    try equal(@as(u8, 2), tree.get(index).level);
    try equal(index, mv.headingNamed(tree, "Getting-Started").?);
}

test "an anchor scrolls to its heading when the document shows, changes or is asked again" {
    var doc: Scrolled = .{ .tree = try md.parse(try document("# Intro", "A paragraph before the destination.\n\n", 30, "# Target\n\nDestination.\n"), parsed.buffers()), .options = .{ .anchor = "#target" } };
    var h = view.Harness.init(&doc, Scrolled.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 160 } });
    try h.render();
    try expect(doc.model.offset.y > 0);
    // The heading comes just into view.
    const target = try h.boundsOf(.{ .kind = .text, .text = "Target" });
    const port = try h.boundsOf(.{ .kind = .scroll });
    try expect(target.y >= port.y and target.y + target.height <= port.y + port.height);

    // An unchanged anchor lets the reader scroll away.
    doc.model.offset.y = 0;
    try h.render();
    try equal(@as(f32, 0), doc.model.offset.y);
    doc.options.anchor_version += 1;
    try h.render();
    try expect(doc.model.offset.y > 0);

    // Another document takes the same anchor.
    doc.model.offset.y = 0;
    doc.tree = try md.parse(try document("# Another document", "Different text before the target.\n\n", 20, "# Target\n\nNew destination.\n"), parsed.buffers());
    try h.render();
    try expect(doc.model.offset.y > 0);

    // An anchor naming no heading moves nothing.
    doc.model.offset.y = 0;
    doc.options.anchor = "missing";
    try h.render();
    try equal(@as(f32, 0), doc.model.offset.y);
}

test "a #heading link reaches the application, which routes it to the anchor" {
    var doc: Scrolled = .{ .tree = try md.parse(try document("[Jump](#target) [File](next.md)", "A paragraph before the destination.\n\n", 30, "# Target\n\nDestination.\n"), parsed.buffers()) };
    var h = view.Harness.init(&doc, Scrolled.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 160 } });
    try h.render();
    try h.click(.{ .kind = .link, .text = "File" });
    try equalStrings("next.md", doc.last.?.link);
    try equal(@as(f32, 0), doc.model.offset.y);
    try h.click(.{ .kind = .link, .text = "Jump" });
    try equalStrings("#target", doc.last.?.link);
    doc.options.anchor = doc.last.?.link;
    try h.render();
    try expect(doc.model.offset.y > 0);
}

test "link text keeps its block's font and takes the link weight as its least" {
    var doc: Doc = .{ .tree = try md.parse("## A [head](/h)\n\nSome [plain](/p), **[strong](/s)** and [`code`](/c).", parsed.buffers()) };
    var h = harness(&doc);
    try h.render();
    try expect(std.meta.eql(view.Font.heading2, (try h.find(.{ .kind = .link, .text = "head" })).style.font.?));
    try equal(@as(?view.Font, null), (try h.find(.{ .kind = .link, .text = "plain" })).style.font);
    const code = try h.find(.{ .kind = .link, .text = "code" });
    try expect(code.style.font.?.monospace);
    try expect(code.style.background != null);

    doc.options.link_weight = .semibold;
    try h.render();
    const heading = (try h.find(.{ .kind = .link, .text = "head" })).style.font.?;
    // Already bold: kept.
    try equal(view.Font.Weight.bold, heading.weight);
    try equal(view.Font.Weight.semibold, (try h.find(.{ .kind = .link, .text = "plain" })).style.font.?.weight);
    try equal(view.Font.Weight.bold, (try h.find(.{ .kind = .link, .text = "strong" })).style.font.?.weight);
    const lifted = (try h.find(.{ .kind = .link, .text = "code" })).style.font.?;
    try expect(lifted.monospace and lifted.weight == .semibold);
    // Plain text is not lifted.
    try equal(@as(?view.Font, null), (try h.find(.{ .kind = .text, .text = "Some " })).style.font);
}
