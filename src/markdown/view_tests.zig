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
