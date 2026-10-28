//! Styled paragraphs for `ziggurat_markdown_view`. `RichBlocks` turns the
//! inline content of paragraphs, headings and table cells into rich text
//! spans ahead of time: emphasis in italics, strong text in bold, struck
//! text with a line through it, inline code in a fixed-pitch font on a
//! rounded background, and headings larger by level. Blocks with links or
//! images keep the view's text and link nodes, so their links stay
//! reachable from the keyboard.
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
};

pub const RichBlocks = struct {
    const Entry = struct {
        node: u32,
        /// Content hash, telling a reparsed tree apart.
        hash: u64,
        spans: []rich.Span,
        text: rich.RichText,
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
        for (tree.nodes, 0..) |node, index| {
            switch (node.kind) {
                .paragraph, .heading, .table_cell => {},
                else => continue,
            }
            spans.clearRetainingCapacity();
            if (!try collect(self.allocator, tree, @intCast(index), options, &spans)) continue;
            var font = options.font;
            if (node.kind == .heading) {
                font.size = options.heading_sizes[@min(@max(node.level, 1), 6) - 1];
                font.weight = options.heading_weight;
            }
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.* = .{ .node = @intCast(index), .hash = hashOf(tree, @intCast(index)), .spans = try self.allocator.dupe(rich.Span, spans.items), .text = rich.RichText.init(self.allocator, .{ .measurer = options.measurer, .font = font }) };
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

/// Append the spans of block `index`'s inline content; false when it holds
/// a link or image.
fn collect(allocator: std.mem.Allocator, tree: md.Tree, index: u32, options: Options, spans: *std.ArrayList(rich.Span)) !bool {
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
            else => {},
        }
        if (span.text.len != 0) try spans.append(allocator, span);
    }
    return true;
}

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
