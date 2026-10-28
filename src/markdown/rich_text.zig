//! Styled paragraphs for `ziggurat_markdown_view`. `RichBlocks` turns the
//! inline content of paragraphs, headings and table cells into rich text
//! spans ahead of time: emphasis in italics, strong text in bold, struck
//! text with a line through it, inline code in a fixed-pitch font on a
//! rounded background, and headings larger by level. Blocks with links or
//! images keep the view's text and link nodes, so their links stay
//! reachable from the keyboard.
//!
//! Math within text (`md.ParseOptions.math`) shows as its TeX in a
//! fixed-pitch font, or, with `Options.inline_math`, as an object the
//! application draws, standing on the text's baseline and reaching below
//! it as far as the formula does.
//!
//! `prepare` measures and allocates, so it runs on the main thread outside
//! the view build and paint: after parsing, and again when the theme or the
//! measurer changes. The view build then only wraps prepared blocks at the
//! width it gives them.
const std = @import("std");
const md = @import("ziggurat_markdown");
const mv = @import("ziggurat_markdown_view");
const view = @import("ziggurat_view");
const rich = @import("ziggurat_view_rich_text");

/// Draws math within text: `measure` gives the box of a formula from its
/// TeX and the size of the text around it in DIP, or null to show the TeX;
/// `paint` draws it in that box. Both run on the main thread; `measure`
/// runs in `prepare`, `paint` as the view paints.
pub const InlineMath = struct {
    context: *anyopaque,
    measure: *const fn (context: *anyopaque, tex: []const u8, size: f32) ?rich.Object,
    paint: *const fn (context: *anyopaque, frame: *rich.Frame, tex: []const u8, box: view.Rect) anyerror!void,
};

pub const Options = struct {
    /// Measures runs; use the one the view host uses.
    measurer: view.Measurer = .{},
    /// The font of body text.
    font: view.Font = .{},
    /// Text size of headings, from level 1 to 6.
    heading_sizes: [6]f32 = .{ 28, 24, 20, 18, 16, 16 },
    heading_weight: view.Font.Weight = .semibold,
    /// The theme the view is drawn with, for code colors.
    theme: view.Theme = .{},
    /// Inline code colors; null takes the theme's text and field colors.
    code: ?u32 = null,
    code_background: ?u32 = null,
    /// Draws math within text; without it, math shows as its TeX.
    inline_math: ?InlineMath = null,
    /// The color of math shown as its TeX; null takes the theme's muted
    /// text color.
    math: ?u32 = null,
};

pub const RichBlocks = struct {
    const Entry = struct {
        node: u32,
        /// Content hash, telling a reparsed tree apart.
        hash: u64,
        spans: []rich.Span,
        text: rich.RichText,
        /// The TeX of each span that is drawn math, by span; empty for the
        /// others.
        tex: [][]const u8,
        math: ?InlineMath,

        fn paintObject(context: *anyopaque, frame: *rich.Frame, span: usize, box: view.Rect) anyerror!void {
            const self: *Entry = @ptrCast(@alignCast(context));
            const math = self.math orelse return;
            if (span < self.tex.len and self.tex[span].len > 0) try math.paint(math.context, frame, self.tex[span], box);
        }
    };
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) RichBlocks {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *RichBlocks) void {
        self.release();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drop every prepared block; their blocks fall back to view text.
    pub fn release(self: *RichBlocks) void {
        for (self.entries.items) |entry| {
            entry.text.deinit();
            self.allocator.free(entry.spans);
            self.allocator.free(entry.tex);
            self.allocator.destroy(entry);
        }
        self.entries.clearRetainingCapacity();
    }

    /// Replace the prepared blocks with those of `tree`, which must stay
    /// valid while the view shows them: the spans borrow its text.
    pub fn prepare(self: *RichBlocks, tree: md.Tree, options: Options) !void {
        self.release();
        errdefer self.release();
        var spans: std.ArrayList(rich.Span) = .empty;
        defer spans.deinit(self.allocator);
        var tex: std.ArrayList([]const u8) = .empty;
        defer tex.deinit(self.allocator);
        for (tree.nodes, 0..) |node, index| {
            switch (node.kind) {
                .paragraph, .heading, .table_cell => {},
                else => continue,
            }
            spans.clearRetainingCapacity();
            tex.clearRetainingCapacity();
            var font = options.font;
            if (node.kind == .heading) {
                font.size = options.heading_sizes[@min(@max(node.level, 1), 6) - 1];
                font.weight = options.heading_weight;
            }
            if (!try collect(self.allocator, tree, @intCast(index), options, font.size, &spans, &tex)) continue;
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            const owned_tex = try self.allocator.dupe([]const u8, tex.items);
            errdefer self.allocator.free(owned_tex);
            entry.* = .{ .node = @intCast(index), .hash = hashOf(tree, @intCast(index)), .spans = try self.allocator.dupe(rich.Span, spans.items), .tex = owned_tex, .math = options.inline_math, .text = rich.RichText.init(self.allocator, .{ .measurer = options.measurer, .font = font }) };
            if (options.inline_math != null) entry.text.options.objects = .{ .context = entry, .paint = Entry.paintObject };
            errdefer {
                entry.text.deinit();
                self.allocator.free(entry.spans);
            }
            try entry.text.setSpans(entry.spans);
            try self.entries.append(self.allocator, entry);
        }
    }

    pub fn face(self: *RichBlocks) mv.RichFace {
        return .{ .context = self, .embed = embed };
    }

    fn embed(context: *anyopaque, tree: md.Tree, index: u32, width: f32, color: u32) ?view.Embed {
        const self: *RichBlocks = @ptrCast(@alignCast(context));
        const entry = self.find(index) orelse return null;
        if (entry.hash != hashOf(tree, index)) return null;
        entry.text.options.color = color;
        if (entry.text.options.width != width) entry.text.setWidth(width);
        return entry.text.embed();
    }

    fn find(self: *const RichBlocks, index: u32) ?*Entry {
        var low: usize = 0;
        var high = self.entries.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.entries.items[middle].node < index) low = middle + 1 else high = middle;
        }
        if (low < self.entries.items.len and self.entries.items[low].node == index) return self.entries.items[low];
        return null;
    }
};

/// Append the spans of block `index`'s inline content, and the TeX of each
/// that is drawn math; false when it holds a link or image.
fn collect(allocator: std.mem.Allocator, tree: md.Tree, index: u32, options: Options, size: f32, spans: *std.ArrayList(rich.Span), tex: *std.ArrayList([]const u8)) !bool {
    var emphasis: i32 = 0;
    var strong: i32 = 0;
    var struck: i32 = 0;
    var walker = tree.walk(index);
    _ = walker.next();
    while (walker.next()) |event| {
        const node = tree.get(event.index);
        const delta: i32 = if (event.entering) 1 else -1;
        var span: rich.Span = .{ .text = "", .italic = emphasis > 0, .weight = if (strong > 0) .bold else null, .strikethrough = struck > 0 };
        switch (node.kind) {
            .emphasis => emphasis += delta,
            .strong => strong += delta,
            .strikethrough => struck += delta,
            .link, .image => return false,
            .text => span.text = node.text,
            .soft_break => span.text = " ",
            .hard_break => span.text = "\n",
            .code => {
                span.text = node.text;
                span.monospace = true;
                span.size = options.font.size * 0.875;
                span.color = options.code orelse options.theme.palette.text;
                span.background = options.code_background orelse options.theme.palette.field;
                span.radius = 3;
            },
            .math => {
                // An object on the baseline the application draws, or the
                // TeX.
                const object = if (options.inline_math) |math| math.measure(math.context, node.text, size) else null;
                if (object) |o| if (o.width > 0 and std.math.isFinite(o.width)) {
                    span.text = object_replacement;
                    span.object = .{ .width = o.width, .height = @max(o.height, 0), .descent = @max(o.descent, 0) };
                    try spans.append(allocator, span);
                    try tex.append(allocator, node.text);
                    continue;
                };
                span.text = node.text;
                span.monospace = true;
                span.size = size * 0.875;
                span.color = options.math orelse options.theme.palette.disabled_text;
            },
            else => {},
        }
        if (span.text.len != 0) {
            try spans.append(allocator, span);
            try tex.append(allocator, "");
        }
    }
    return true;
}

const object_replacement = "\u{fffc}";

fn hashOf(tree: md.Tree, index: u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var walker = tree.walk(index);
    while (walker.next()) |event| {
        const node = tree.get(event.index);
        hasher.update(&.{ @backingInt(node.kind), @intFromBool(event.entering), node.level });
        hasher.update(node.text);
    }
    return hasher.final();
}

test "inline styles become spans and links keep view nodes" {
    var parsed: md.Storage(256, 4096) = .{};
    const tree = try md.parse(
        \\## Head *one*
        \\
        \\Plain *it* **bold** ~~gone~~ `code`
        \\next
        \\
        \\See [the guide](https://example.com).
    , parsed.buffers());
    var blocks = RichBlocks.init(std.testing.allocator);
    defer blocks.deinit();
    try blocks.prepare(tree, .{});
    try std.testing.expectEqual(@as(usize, 2), blocks.entries.items.len);
    const heading = blocks.entries.items[0];
    try std.testing.expectEqual(@as(f32, 24), heading.text.options.font.size);
    try std.testing.expect(heading.spans[1].italic);
    const paragraph = blocks.entries.items[1].spans;
    const texts = [_][]const u8{ "Plain ", "it", " ", "bold", " ", "gone", " ", "code", " ", "next" };
    try std.testing.expectEqual(texts.len, paragraph.len);
    for (texts, paragraph) |want, got| try std.testing.expectEqualStrings(want, got.text);
    try std.testing.expect(paragraph[1].italic);
    try std.testing.expectEqual(@as(?view.Font.Weight, .bold), paragraph[3].weight);
    try std.testing.expect(paragraph[5].strikethrough);
    try std.testing.expect(paragraph[7].monospace and paragraph[7].radius == 3 and paragraph[7].background != null);

    // The view shows prepared blocks as embeds wrapped at its width and the
    // block with a link as text and a link.
    const Doc = struct {
        tree: md.Tree,
        options: mv.Options,
        fn build(self: *@This(), v: *view.View) anyerror!void {
            _ = try mv.build(v, self.tree, self.options, .{});
        }
    };
    var doc: Doc = .{ .tree = tree, .options = .{ .width = 120, .rich = blocks.face() } };
    var storage: view.Storage(256, 4096) = .{};
    var h = view.Harness.init(&doc, Doc.build, storage.buffers(), .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 400 } });
    try h.render();
    try std.testing.expectEqual(@as(usize, 2), h.count(.{ .kind = .embed }));
    _ = try h.find(.{ .kind = .link, .text = "the guide" });
    try std.testing.expectEqual(@as(f32, 120), blocks.entries.items[1].text.options.width);
    try std.testing.expect(blocks.entries.items[1].text.lines.items.len > 1);

    // A reparsed tree with other text falls back until prepared again.
    var other: md.Storage(256, 4096) = .{};
    doc.tree = try md.parse("## Head *two*\n", other.buffers());
    try h.render();
    try std.testing.expectEqual(@as(usize, 0), h.count(.{ .kind = .embed }));
}

test "math within text stands on the baseline as the application draws it, or shows its TeX" {
    var parsed: md.Storage(256, 4096) = .{};
    const tree = try md.parseWith("water $H_2O$ boils", parsed.buffers(), .{ .math = true, .dollar_math = true });
    const Math = struct {
        painted: usize = 0,
        fn measure(_: *anyopaque, tex: []const u8, size: f32) ?rich.Object {
            if (std.mem.eql(u8, tex, "skip")) return null;
            return .{ .width = 30, .height = size, .descent = 10 };
        }
        fn paint(context: *anyopaque, _: *rich.Frame, tex: []const u8, box: view.Rect) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("H_2O", tex);
            try std.testing.expectEqual(@as(f32, 30), box.width);
            try std.testing.expectEqual(@as(f32, 16 + 10), box.height);
            self.painted += 1;
        }
    };
    var math: Math = .{};
    var blocks = RichBlocks.init(std.testing.allocator);
    defer blocks.deinit();
    try blocks.prepare(tree, .{ .inline_math = .{ .context = &math, .measure = Math.measure, .paint = Math.paint } });
    const entry = blocks.entries.items[0];
    try std.testing.expectEqual(@as(usize, 3), entry.spans.len);
    try std.testing.expectEqualStrings("\u{fffc}", entry.spans[1].text);
    const line = entry.text.textLines()[0];
    // The formula reaches 10 below the baseline, deeper than the text.
    try std.testing.expectEqual(@as(f32, 10), line.descent);
    var box: ?view.Rect = null;
    for (entry.text.runs.items) |run| if (entry.text.objectBox(run)) |b| {
        box = b;
    };
    try std.testing.expectEqual(line.baseline - 16, box.?.y);

    // Without the application's drawing, the TeX shows.
    try blocks.prepare(tree, .{});
    try std.testing.expectEqualStrings("H_2O", blocks.entries.items[0].spans[1].text);
    try std.testing.expect(blocks.entries.items[0].spans[1].monospace);
}
