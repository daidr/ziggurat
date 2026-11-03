//! Declarative view nodes for a parsed Markdown tree. `build` runs inside
//! an application's view build function and adds the document as columns,
//! rows, text, links and checkboxes through the public view API, wrapping
//! paragraphs at the width it is given. Links activate like any view link
//! and are reported back with their destination; task checkboxes can be
//! made interactive. Code blocks draw through an optional monospace face.
const std = @import("std");
const md = @import("ziggurat_markdown");
const view = @import("ziggurat_view");

const View = view.View;
const Style = view.Style;
const Error = view.Error;
const none = md.none;

/// Colors that replace the ones derived from `Options.theme`.
pub const Colors = struct {
    text: ?u32 = null,
    heading: ?u32 = null,
    emphasis: ?u32 = null,
    strong: ?u32 = null,
    strikethrough: ?u32 = null,
    code: ?u32 = null,
    code_background: ?u32 = null,
    quote: ?u32 = null,
    rule: ?u32 = null,
    image: ?u32 = null,
};

/// Monospace drawing for code blocks, such as `ziggurat_markdown_code`.
pub const CodeFace = struct {
    context: *anyopaque,
    /// An embed that measures and draws code block `index` of `tree`, or
    /// null to show it as plain lines. The embed's context must stay valid
    /// while any pass that emits it runs.
    embed: *const fn (*anyopaque, md.Tree, u32) ?view.Embed,
};

/// Styled text for paragraphs, headings and table cells, such as
/// `ziggurat_markdown_rich`, which draws emphasis, strong text, struck
/// text and inline code in their own fonts and lines.
pub const RichFace = struct {
    context: *anyopaque,
    /// An embed that shows the inline content of block `index` of `tree`
    /// wrapped at `width` in `color`, or null to build it from view text and
    /// links. The embed's context must stay valid while any pass that emits
    /// it runs.
    embed: *const fn (*anyopaque, md.Tree, u32, f32, u32) ?view.Embed,
};

pub const Options = struct {
    /// Width that paragraphs wrap at, in DIP. Nested blocks subtract their
    /// indentation from it.
    width: f32 = 640,
    /// Measures text runs while wrapping; use the one the view host uses.
    measurer: view.Measurer = .{},
    /// The theme the view is drawn with, for default colors.
    theme: view.Theme = .{},
    colors: Colors = .{},
    /// Space between blocks, and between the items of a loose list.
    gap: f32 = 12,
    /// Space between the items of a tight list.
    tight_gap: f32 = 4,
    /// Width of a list item's marker column.
    indent: f32 = 28,
    /// Task checkboxes the reader can toggle; otherwise they are disabled.
    interactive_tasks: bool = false,
    code: ?CodeFace = null,
    rich: ?RichFace = null,
    /// The least weight of link text, so links read as links where color
    /// alone does not, in a gray print theme or to a colorblind reader;
    /// stronger text keeps its weight. `.regular` sets no floor.
    link_weight: view.Font.Weight = .regular,
    /// Scroll to the heading with this slug, with or without its `#`, when
    /// the document first shows, when another document replaces it and
    /// when the anchor changes: a docs reader opens `guide.md#install` at
    /// its heading. `anchor_state` remembers what was shown; without it the
    /// anchor is ignored. An app routing `#a-heading` links sets this from
    /// the link's activation.
    anchor: []const u8 = "",
    /// Scrolls to `anchor` again when it changes, for the same heading
    /// asked for twice.
    anchor_version: u64 = 0,
    anchor_state: ?*AnchorState = null,
};

/// What a view's anchor last applied to, kept by the application with the
/// view across passes.
pub const AnchorState = struct {
    shown: bool = false,
    anchor: u64 = 0,
    version: u64 = 0,
    /// The document's text when the anchor was last weighed, as a hash and
    /// a length, to tell more of it from another one.
    text: u64 = 0,
    length: usize = 0,

    /// Whether `options` asks to scroll for `tree`, remembering it.
    fn due(self: *AnchorState, tree: md.Tree, options: Options) bool {
        const anchor = std.hash.Wyhash.hash(0, options.anchor);
        // Another text, not more of the same one, as a streamed document.
        const replaced = !self.shown or tree.text.len < self.length or std.hash.Wyhash.hash(0, tree.text[0..self.length]) != self.text;
        const changed = replaced or anchor != self.anchor or options.anchor_version != self.version;
        self.* = .{ .shown = true, .anchor = anchor, .version = options.anchor_version, .text = std.hash.Wyhash.hash(0, tree.text), .length = tree.text.len };
        return changed and options.anchor.len > 0;
    }
};

/// The longest heading slug compared; longer ones are cut there.
pub const max_slug = 256;

/// The anchor of a heading of `text`, as GitHub makes it, written into
/// `buffer`: in lower case, spaces as hyphens, without ASCII punctuation.
pub fn slug(text: []const u8, buffer: *[max_slug]u8) []const u8 {
    var len: usize = 0;
    for (std.mem.trim(u8, text, " \t")) |byte| {
        if (len == buffer.len) break;
        const out: ?u8 = switch (byte) {
            ' ' => '-',
            '-', '_', '0'...'9', 'a'...'z' => byte,
            'A'...'Z' => byte + 32,
            // Letters of other scripts stay as they are.
            0x80...0xff => byte,
            else => null,
        };
        if (out) |value| {
            buffer[len] = value;
            len += 1;
        }
    }
    return buffer[0..len];
}

/// The index of the first heading of `tree` whose slug is `name`, with or
/// without its `#`.
pub fn headingNamed(tree: md.Tree, name: []const u8) ?u32 {
    const wanted = if (std.mem.startsWith(u8, name, "#")) name[1..] else name;
    for (tree.nodes, 0..) |node, index| {
        if (node.kind != .heading) continue;
        var text: [max_slug]u8 = undefined;
        var buffer: [max_slug]u8 = undefined;
        if (std.ascii.eqlIgnoreCase(slug(tree.plainText(@intCast(index), &text), &buffer), wanted[0..@min(wanted.len, max_slug)])) return @intCast(index);
    }
    return null;
}

pub const Activation = union(enum) {
    /// Destination of the activated link, borrowed from the tree.
    link: []const u8,
    /// A task checkbox the reader toggled; `checked` is its new state.
    /// `toggleTask` applies it to the source.
    task: struct { node: u32, checked: bool },
};

/// Containers stop at this many children; longer runs nest in columns.
const chunk = 128;

/// Add `tree` to `v` as one column. Returns the link or task the pass
/// delivered, if any.
pub fn build(v: *View, tree: md.Tree, options: Options, style: Style) Error!?Activation {
    var builder: Builder = .{ .v = v, .tree = tree, .options = options, .colors = resolve(options) };
    if (options.anchor_state) |state| if (state.due(tree, options)) {
        builder.reveal = headingNamed(tree, options.anchor) orelse none;
    };
    var outer = style;
    if (outer.gap == 0) outer.gap = options.gap;
    try v.column(outer);
    try builder.children(0, options.width, outer.gap);
    try v.end();
    return builder.activation;
}

const Resolved = struct { text: u32, heading: u32, emphasis: u32, strong: u32, strikethrough: u32, code: u32, code_background: u32, quote: u32, rule: u32, image: u32 };
fn resolve(options: Options) Resolved {
    const p = options.theme.palette;
    const c = options.colors;
    return .{
        .text = c.text orelse p.text,
        .heading = c.heading orelse p.text,
        .emphasis = c.emphasis orelse p.text,
        .strong = c.strong orelse p.text,
        .strikethrough = c.strikethrough orelse p.disabled_text,
        .code = c.code orelse p.text,
        .code_background = c.code_background orelse p.field,
        .quote = c.quote orelse p.disabled_text,
        .rule = c.rule orelse p.disabled_border,
        .image = c.image orelse p.disabled_text,
    };
}

const bullets = [_][]const u8{ "•", "◦", "▪" };
const headings = [_]view.Font{ .heading1, .heading2, .heading3, .heading4, .heading5, .heading6 };
const header_font: view.Font = .{ .weight = .semibold };

const Builder = struct {
    v: *View,
    tree: md.Tree,
    options: Options,
    colors: Resolved,
    activation: ?Activation = null,
    list_depth: usize = 0,
    /// The heading to scroll into view, or none.
    reveal: u32 = none,

    /// The blocks below `parent`, nested in columns of `chunk` when long.
    fn children(self: *Builder, parent: u32, width: f32, gap: f32) Error!void {
        var count: usize = 0;
        var nested = false;
        var it = self.tree.children(parent);
        const total = blockCount(self.tree, parent);
        while (it.next()) |index| : (count += 1) {
            if (total > chunk and count % chunk == 0) {
                if (nested) try self.v.end();
                try self.v.column(.{ .gap = gap });
                nested = true;
            }
            try self.block(index, width);
        }
        if (nested) try self.v.end();
    }

    fn block(self: *Builder, index: u32, width: f32) Error!void {
        const node = self.tree.get(index);
        const v = self.v;
        switch (node.kind) {
            .paragraph => try self.flow(index, width, self.colors.text, .body),
            .heading => try self.flow(index, width, self.colors.heading, headings[@min(node.level, 6) -| 1]),
            .thematic_break => {
                try v.column(.{ .height = 1, .background = self.colors.rule, .self_align = .stretch });
                try v.end();
            },
            .block_quote => {
                try v.row(.{ .gap = 12, .alignment = .stretch });
                try v.column(.{ .width = 3, .background = self.colors.rule });
                try v.end();
                try v.column(.{ .gap = self.options.gap, .grow = 1 });
                const saved = self.colors.text;
                self.colors.text = self.colors.quote;
                try self.children(index, @max(1, width - 15), self.options.gap);
                self.colors.text = saved;
                try v.end();
                try v.end();
            },
            .list => try self.list(index, width),
            .code_block => try self.code(index, width),
            .table => try self.table(index, width),
            else => {},
        }
    }

    fn list(self: *Builder, index: u32, width: f32) Error!void {
        const v = self.v;
        const node = self.tree.get(index);
        const gap = if (node.tight) self.options.tight_gap else self.options.gap;
        const inner = @max(1, width - self.options.indent);
        try v.column(.{ .gap = gap });
        var number = node.start;
        var count: usize = 0;
        var it = self.tree.children(index);
        while (it.next()) |item_index| : (count += 1) {
            if (count > 0 and count % chunk == 0) {
                try v.end();
                try v.column(.{ .gap = gap });
            }
            const item = self.tree.get(item_index);
            try v.row(.{ .gap = 0, .alignment = .start });
            try v.row(.{ .width = self.options.indent, .justify = .start, .shrink = 0 });
            if (item.task != .none) {
                var checked = item.task == .checked;
                const name = firstText(self.tree, item_index);
                if (try v.checkbox(&checked, "", .{ .enabled = self.options.interactive_tasks, .name = if (name.len > 0) name else "task" }))
                    self.activation = .{ .task = .{ .node = item_index, .checked = checked } };
            } else if (node.ordered) {
                try v.textf("{d}{c}", .{ number, node.marker }, .{ .color = self.colors.text });
            } else try v.text(bullets[@min(self.list_depth, bullets.len - 1)], .{ .color = self.colors.text });
            try v.end();
            try v.column(.{ .gap = gap, .grow = 1 });
            self.list_depth += 1;
            try self.children(item_index, inner, gap);
            self.list_depth -= 1;
            try v.end();
            try v.end();
            number +%= 1;
        }
        try v.end();
    }

    fn code(self: *Builder, index: u32, width: f32) Error!void {
        const v = self.v;
        const node = self.tree.get(index);
        try v.column(.{ .padding = .all(8), .background = self.colors.code_background, .radius = 4, .clip = true, .self_align = .stretch, .max_width = width });
        if (self.options.code) |face| if (face.embed(face.context, self.tree, index)) |content| {
            try v.embed(content, .{});
            try v.end();
            return;
        };
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, node.text, "\n"), '\n');
        var count: usize = 0;
        while (lines.next()) |line| : (count += 1) {
            if (count > 0 and count % chunk == 0) {
                if (count > chunk) try v.end();
                try v.column(.{});
            }
            try v.text(if (line.len == 0) " " else line, .{ .color = self.colors.code, .font = .code, .shrink = 0 });
        }
        if (count > chunk) try v.end();
        try v.end();
    }

    fn table(self: *Builder, index: u32, width: f32) Error!void {
        const v = self.v;
        const first_row = self.tree.get(index).first_child;
        const columns = blockCount(self.tree, first_row);
        if (columns == 0) return;
        const tracks = equal_tracks[0..@min(columns, equal_tracks.len)];
        const cell_width = @max(1, width / @as(f32, @floatFromInt(tracks.len)) - 17);
        try v.column(.{ .border = self.colors.rule, .self_align = .stretch });
        var rows = self.tree.children(index);
        var count: usize = 0;
        while (rows.next()) |row_index| : (count += 1) {
            if (count > 0 and count % chunk == 0) {
                try v.end();
                try v.column(.{});
            }
            const row = self.tree.get(row_index);
            try v.grid(tracks, .{ .background = if (row.header) self.colors.code_background else null });
            var cells = self.tree.children(row_index);
            var column: usize = 0;
            while (cells.next()) |cell_index| : (column += 1) {
                if (column == tracks.len) break;
                const cell = self.tree.get(cell_index);
                const alignment: view.Align = switch (cell.alignment) {
                    .center => .center,
                    .right => .end,
                    else => .start,
                };
                try v.column(.{ .padding = .{ .top = 4, .bottom = 4, .left = 8, .right = 8 }, .border = self.colors.rule, .alignment = alignment });
                if (row.header)
                    try self.flow(cell_index, cell_width, self.colors.heading, header_font)
                else
                    try self.flow(cell_index, cell_width, self.colors.text, .body);
                try v.end();
            }
            try v.end();
        }
        try v.end();
    }

    /// Inline content of `index` as rows that fit `width`. Each row holds
    /// one node per run of one style; links stay activatable on every row
    /// they wrap onto.
    fn flow(self: *Builder, index: u32, width: f32, color: u32, font: view.Font) Error!void {
        if (self.options.rich) |face| if (face.embed(face.context, self.tree, index, width, color)) |content| {
            try self.v.embed(content, .{});
            if (index == self.reveal) self.v.scrollIntoView(self.v.lastNode().id);
            return;
        };
        var line: Line = .{ .b = self, .width = width, .base = color, .font = font };
        try self.v.column(.{ .gap = 2 });
        if (index == self.reveal) self.v.scrollIntoView(self.v.lastNode().id);
        var walker = self.tree.walk(index);
        _ = walker.next();
        while (walker.next()) |event| {
            const node = self.tree.get(event.index);
            const delta: i32 = if (event.entering) 1 else -1;
            switch (node.kind) {
                .emphasis => line.style.emphasis += delta,
                .strong => line.style.strong += delta,
                .strikethrough => line.style.strikethrough += delta,
                .image => line.style.image += delta,
                .link => line.link = if (event.entering) event.index else none,
                .text => try line.add(node.text, false),
                .code, .math => try line.add(node.text, true),
                .soft_break => try line.add(" ", false),
                .hard_break => try line.newLine(),
                else => {},
            }
        }
        try line.finish();
        try self.v.end();
    }
};

const equal_tracks = @as([md.max_columns]view.Track, @splat(view.Track.fraction(1)));

fn blockCount(tree: md.Tree, parent: u32) usize {
    var count: usize = 0;
    var it = tree.children(parent);
    while (it.next()) |_| count += 1;
    return count;
}

/// The first text run below `index`, borrowed from the tree.
fn firstText(tree: md.Tree, index: u32) []const u8 {
    var walker = tree.walk(index);
    while (walker.next()) |event| {
        const node = tree.get(event.index);
        if (event.entering and node.kind == .text and node.text.len > 0) return node.text;
    }
    return "";
}

const InlineStyle = struct {
    emphasis: i32 = 0,
    strong: i32 = 0,
    strikethrough: i32 = 0,
    image: i32 = 0,
};

/// Greedy line filling over the runs of one block.
const Line = struct {
    b: *Builder,
    width: f32,
    base: u32,
    /// Font of the block's plain text; inline styles derive from it.
    font: view.Font,
    style: InlineStyle = .{},
    link: u32 = none,
    used: f32 = 0,
    open: bool = false,
    rows: usize = 0,
    /// Segments on the current row.
    segments: usize = 0,
    /// The column rows are added to, while rows nest in chunks.
    nested: bool = false,

    fn measure(self: *Line, text: []const u8, code: bool) f32 {
        return self.b.options.measurer.textSize(text, self.fontFor(code)).width;
    }
    /// Whether the current run is a link's.
    fn linked(self: *Line) bool {
        return self.link != none and self.style.image == 0;
    }
    /// The font of the current run; null for the body font. Link text is
    /// at least `Options.link_weight`.
    fn fontFor(self: *Line, code: bool) ?view.Font {
        var font = self.font;
        if (code) {
            font.size = font.size * view.Font.code.size / view.Font.body.size;
            font.monospace = true;
            font.italic = false;
        } else {
            if (self.style.strong > 0) lift(&font, .bold);
            if (self.style.emphasis > 0) font.italic = true;
        }
        if (self.linked()) lift(&font, self.b.options.link_weight);
        return if (std.meta.eql(font, view.Font.body)) null else font;
    }
    fn lift(font: *view.Font, weight: view.Font.Weight) void {
        if (@backingInt(font.weight) < @backingInt(weight)) font.weight = weight;
    }
    fn color(self: *Line, code: bool) u32 {
        const c = self.b.colors;
        if (code) return c.code;
        if (self.style.image > 0) return c.image;
        if (self.style.strikethrough > 0) return c.strikethrough;
        if (self.style.strong > 0) return c.strong;
        if (self.style.emphasis > 0) return c.emphasis;
        return self.base;
    }

    /// Add `text` in the current style, breaking it between words, or
    /// between any two characters of CJK text.
    fn add(self: *Line, text: []const u8, code: bool) Error!void {
        var start: usize = 0;
        // A row starts at its first visible character.
        if (self.used == 0) {
            while (start < text.len and text[start] == ' ') start += 1;
        }
        var at = start;
        // Width of text[start..at], not yet added as a segment.
        var pending: f32 = 0;
        while (at < text.len) {
            const end = nextBreak(text, at);
            const visible = std.mem.trimEnd(u8, text[at..end], " ");
            const visible_width = self.measure(visible, code);
            if (self.used + pending + visible_width > self.width and self.used + pending > 0) {
                const kept = std.mem.trimEnd(u8, text[start..at], " ");
                if (kept.len > 0) try self.segment(kept, code);
                try self.newLine();
                start = at;
                pending = 0;
            }
            if (self.used + pending == 0 and visible_width > self.width) {
                // A word wider than the row is split between characters.
                const stop_all = at + visible.len;
                var cut = at;
                while (true) {
                    var stop = cut + sequenceLength(text[cut]);
                    while (stop < stop_all) {
                        const next = stop + sequenceLength(text[stop]);
                        if (self.measure(text[cut..next], code) > self.width) break;
                        stop = next;
                    }
                    if (stop >= stop_all) break;
                    try self.segment(text[cut..stop], code);
                    try self.newLine();
                    cut = stop;
                }
                start = cut;
                pending = self.measure(text[cut..end], code);
                at = end;
                continue;
            }
            pending += self.measure(text[at..end], code);
            at = end;
        }
        if (start < text.len and !(self.used == 0 and std.mem.trim(u8, text[start..], " ").len == 0))
            try self.segment(text[start..], code);
    }

    fn row(self: *Line) Error!void {
        if (self.open) return;
        const v = self.b.v;
        if (self.rows > 0 and self.rows % chunk == 0) {
            if (self.nested) try v.end();
            try v.column(.{ .gap = 2 });
            self.nested = true;
        }
        try v.row(.{ .alignment = .center });
        self.open = true;
        self.rows += 1;
        self.segments = 0;
    }
    fn segment(self: *Line, text: []const u8, code: bool) Error!void {
        try self.row();
        const v = self.b.v;
        if (self.segments == chunk) {
            try self.newLine();
            try self.row();
        }
        self.segments += 1;
        self.used += self.measure(text, code);
        const color_value = self.color(code);
        if (self.linked()) {
            // Code in a link keeps its face and wash.
            const style: view.Style = if (code) .{ .font = self.fontFor(true), .background = self.b.colors.code_background, .radius = 3, .shrink = 0 } else .{ .font = self.fontFor(false), .shrink = 0 };
            if (try v.link(text, style)) self.b.activation = .{ .link = self.b.tree.get(self.link).url };
        } else if (code) {
            try v.row(.{ .background = self.b.colors.code_background, .radius = 3, .padding = .{ .left = 3, .right = 3 }, .shrink = 0 });
            try v.text(text, .{ .color = color_value, .font = self.fontFor(true) });
            try v.end();
        } else try v.text(text, .{ .color = color_value, .font = self.fontFor(false), .shrink = 0 });
    }
    fn newLine(self: *Line) Error!void {
        if (!self.open) try self.row();
        try self.b.v.end();
        self.open = false;
        self.used = 0;
    }
    fn finish(self: *Line) Error!void {
        if (self.open) {
            try self.b.v.end();
            self.open = false;
        }
        if (self.nested) try self.b.v.end();
    }
};

fn sequenceLength(byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(byte) catch 1;
}

/// End of the word at `at`: its non-space bytes and the spaces after
/// them, or one CJK character.
fn nextBreak(text: []const u8, at: usize) usize {
    var end = at;
    while (end < text.len and text[end] != ' ') {
        const len = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        const codepoint = std.unicode.utf8Decode(text[end..@min(text.len, end + len)]) catch 0;
        if (breaksAround(codepoint)) {
            if (end == at) end += len;
            break;
        }
        end += len;
    }
    while (end < text.len and text[end] == ' ') end += 1;
    return end;
}
fn breaksAround(codepoint: u21) bool {
    return switch (codepoint) {
        0x1100...0x115f, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xa000...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f, 0xff00...0xff60, 0xffe0...0xffe6, 0x20000...0x3fffd => true,
        else => false,
    };
}

/// Byte offset of the box character of the task list item that starts on
/// source line `line`, as `Node.line` records it, or null when that line
/// has no task marker.
pub fn taskOffset(source: []const u8, line: u32) ?usize {
    var start: usize = 0;
    var current: u32 = 0;
    while (current < line) : (current += 1) {
        const end = std.mem.indexOfAnyPos(u8, source, start, "\r\n") orelse return null;
        start = end + @as(usize, if (source[end] == '\r' and end + 1 < source.len and source[end + 1] == '\n') 2 else 1);
    }
    const end = std.mem.indexOfAnyPos(u8, source, start, "\r\n") orelse source.len;
    const text = source[start..end];
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "[")) |open| : (at = open + 1) {
        if (open + 2 < text.len and text[open + 2] == ']' and (text[open + 1] == ' ' or text[open + 1] == 'x' or text[open + 1] == 'X')) return start + open + 1;
    }
    return null;
}

/// Write `checked` into the task marker at `offset` from `taskOffset`.
pub fn toggleTask(source: []u8, offset: usize, checked: bool) void {
    source[offset] = if (checked) 'x' else ' ';
}

test {
    _ = @import("view_tests.zig");
}
