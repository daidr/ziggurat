//! Markdown documents as a bounded node tree: the CommonMark block and
//! inline structure plus the GitHub tables, task list items,
//! strikethrough and extended autolinks. Pure Zig with caller-owned fixed
//! storage; parsing never allocates, recurses over input nesting or reads
//! anything but its source. Raw HTML is kept as literal text.
const std = @import("std");
const blocks = @import("blocks.zig");
const inlines = @import("inlines.zig");
pub const html = @import("html.zig");
pub const entities = @import("entities.zig");

/// No node.
pub const none = std.math.maxInt(u32);
/// Deepest nesting of block quotes and list items.
pub const max_depth = 32;
/// Link reference definitions one document can declare.
pub const max_definitions = 128;
/// Columns of one table; cells past this are dropped.
pub const max_columns = 64;

pub const Error = error{ TooManyNodes, TextFull, NestingTooDeep, TooManyDefinitions, InvalidText };

pub const Kind = enum(u8) {
    document,
    paragraph,
    heading,
    thematic_break,
    block_quote,
    list,
    list_item,
    code_block,
    table,
    table_row,
    table_cell,
    text,
    soft_break,
    hard_break,
    emphasis,
    strong,
    strikethrough,
    code,
    link,
    image,

    /// True for kinds that hold child nodes, even when a node has none.
    pub fn isContainer(self: Kind) bool {
        return switch (self) {
            .thematic_break, .code_block, .text, .soft_break, .hard_break, .code => false,
            else => true,
        };
    }
    /// True for kinds that describe document structure rather than runs
    /// of text inside a paragraph, heading or table cell.
    pub fn isBlock(self: Kind) bool {
        return @backingInt(self) <= @backingInt(Kind.table_cell);
    }
};

pub const Alignment = enum(u8) { none, left, center, right };
pub const Task = enum(u8) { none, unchecked, checked };

pub const Node = struct {
    kind: Kind = .text,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    /// Content of a text run, code span or code block. Code block content
    /// keeps its line feeds, including the final one.
    text: []const u8 = "",
    /// Destination of a link or image; the first word of a fenced code
    /// block's info string.
    url: []const u8 = "",
    /// Title of a link or image; the full info string of a code block.
    title: []const u8 = "",
    /// Heading level, 1 to 6.
    level: u8 = 0,
    /// List numbering, its first number and marker character (`-`, `+`,
    /// `*`, `.` or `)`).
    ordered: bool = false,
    start: u32 = 1,
    marker: u8 = 0,
    /// A list without blank lines between or inside its items; its
    /// paragraphs are shown without paragraph spacing.
    tight: bool = true,
    /// Checkbox of a task list item.
    task: Task = .none,
    /// Column alignment of a table cell.
    alignment: Alignment = .none,
    /// The first row of a table and its cells.
    header: bool = false,
    /// A code block opened with a fence rather than indentation.
    fenced: bool = false,
    /// A link written as a bare address.
    autolink: bool = false,
    /// Zero-based source line a block starts on.
    line: u32 = 0,
};

/// Caller-owned storage for one parsed document. Text holds the copied
/// block content and decoded inline text that nodes point into.
pub const Buffers = struct {
    nodes: []Node,
    text: []u8,
};

pub fn Storage(comptime node_capacity: usize, comptime text_capacity: usize) type {
    return struct {
        const Self = @This();
        nodes: [node_capacity]Node = undefined,
        text: [text_capacity]u8 = undefined,
        pub fn buffers(self: *Self) Buffers {
            return .{ .nodes = &self.nodes, .text = &self.text };
        }
    };
}

/// A parsed document. It borrows the buffers it was parsed into, so it
/// stays valid until they are reused; it does not borrow the source.
pub const Tree = struct {
    nodes: []const Node,
    /// Used part of the text buffer.
    text: []const u8,

    pub fn root(self: Tree) *const Node {
        return &self.nodes[0];
    }
    pub fn get(self: Tree, index: u32) *const Node {
        return &self.nodes[index];
    }
    pub fn indexOf(self: Tree, node: *const Node) u32 {
        return @intCast(node - self.nodes.ptr);
    }
    pub fn children(self: Tree, index: u32) Children {
        return .{ .tree = self, .at = self.nodes[index].first_child };
    }
    /// Depth-first enter and exit events below and including `index`.
    pub fn walk(self: Tree, index: u32) Walker {
        return .{ .tree = self, .top = index, .at = index };
    }
    /// Concatenated text content below `index`: text runs, code spans and
    /// code blocks, with a space for each line break.
    pub fn plainText(self: Tree, index: u32, out: []u8) []const u8 {
        var len: usize = 0;
        var walker = self.walk(index);
        while (walker.next()) |event| {
            if (!event.entering) continue;
            const node = self.get(event.index);
            const piece = switch (node.kind) {
                .text, .code, .code_block => node.text,
                .soft_break, .hard_break => " ",
                else => continue,
            };
            const take = @min(piece.len, out.len - len);
            @memcpy(out[len..][0..take], piece[0..take]);
            len += take;
            if (take < piece.len) break;
        }
        return out[0..utf8Prefix(out[0..len])];
    }
};

/// Longest prefix that does not end inside a UTF-8 sequence.
pub fn utf8Prefix(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var start = bytes.len - 1;
    var back: usize = 0;
    while (start > 0 and back < 3 and bytes[start] & 0xc0 == 0x80) : (back += 1) start -= 1;
    const width = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return start;
    return if (start + width <= bytes.len) bytes.len else start;
}

pub const Children = struct {
    tree: Tree,
    at: u32,
    pub fn next(self: *Children) ?u32 {
        if (self.at == none) return null;
        const index = self.at;
        self.at = self.tree.nodes[index].next;
        return index;
    }
};

pub const Event = struct { index: u32, entering: bool };

/// Iterates without recursion, so deeply nested input cannot exhaust the
/// stack. Leaves are entered only; containers are entered and exited.
pub const Walker = struct {
    tree: Tree,
    top: u32,
    at: u32,
    entering: bool = true,
    started: bool = false,

    pub fn next(self: *Walker) ?Event {
        const nodes = self.tree.nodes;
        if (!self.started) {
            self.started = true;
            return .{ .index = self.at, .entering = true };
        }
        if (self.at == none) return null;
        const node = &nodes[self.at];
        if (self.entering) {
            if (node.first_child != none) {
                self.at = node.first_child;
                return .{ .index = self.at, .entering = true };
            }
            if (node.kind.isContainer()) {
                self.entering = false;
                return .{ .index = self.at, .entering = false };
            }
        }
        if (self.at == self.top) {
            self.at = none;
            return null;
        }
        if (node.next != none) {
            self.at = node.next;
            self.entering = true;
            return .{ .index = self.at, .entering = true };
        }
        self.at = node.parent;
        self.entering = false;
        return .{ .index = self.at, .entering = false };
    }
};

pub const Definition = struct { label: []const u8, url: []const u8, title: []const u8 };

/// Parse state shared by the block and inline passes.
pub const Builder = struct {
    nodes: []Node,
    len: u32 = 0,
    text: []u8,
    text_len: usize = 0,
    definitions: [max_definitions]Definition = undefined,
    definition_len: usize = 0,

    pub fn add(self: *Builder, parent: u32, node: Node) Error!u32 {
        if (self.len == self.nodes.len) return error.TooManyNodes;
        const index = self.len;
        self.len += 1;
        var value = node;
        value.parent = parent;
        self.nodes[index] = value;
        if (parent != none) {
            const owner = &self.nodes[parent];
            if (owner.last_child == none) owner.first_child = index else self.nodes[owner.last_child].next = index;
            owner.last_child = index;
        }
        return index;
    }
    /// Remove `index`, the last child of its parent, from the tree.
    pub fn unlinkLast(self: *Builder, index: u32) void {
        const owner = &self.nodes[self.nodes[index].parent];
        if (owner.first_child == index) {
            owner.first_child = none;
            owner.last_child = none;
            return;
        }
        var at = owner.first_child;
        while (self.nodes[at].next != index) at = self.nodes[at].next;
        self.nodes[at].next = none;
        owner.last_child = at;
    }
    pub fn mark(self: *const Builder) usize {
        return self.text_len;
    }
    pub fn since(self: *const Builder, start: usize) []const u8 {
        return self.text[start..self.text_len];
    }
    pub fn write(self: *Builder, bytes: []const u8) Error!void {
        if (self.text.len - self.text_len < bytes.len) return error.TextFull;
        @memcpy(self.text[self.text_len..][0..bytes.len], bytes);
        self.text_len += bytes.len;
    }
    pub fn writeByte(self: *Builder, byte: u8) Error!void {
        return self.write(&.{byte});
    }
    pub fn writeSpaces(self: *Builder, count: usize) Error!void {
        if (self.text.len - self.text_len < count) return error.TextFull;
        @memset(self.text[self.text_len..][0..count], ' ');
        self.text_len += count;
    }
    pub fn writeCodepoint(self: *Builder, codepoint: u21) Error!void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch std.unicode.utf8Encode(0xfffd, &bytes) catch unreachable;
        return self.write(bytes[0..len]);
    }
    pub fn define(self: *Builder, definition: Definition) Error!void {
        if (self.lookup(definition.label) != null) return;
        if (self.definition_len == max_definitions) return error.TooManyDefinitions;
        self.definitions[self.definition_len] = definition;
        self.definition_len += 1;
    }
    pub fn lookup(self: *const Builder, label: []const u8) ?Definition {
        for (self.definitions[0..self.definition_len]) |definition| if (sameLabel(definition.label, label)) return definition;
        return null;
    }
};

/// Labels match after trimming, collapsing whitespace runs and folding
/// ASCII case.
pub fn sameLabel(a: []const u8, b: []const u8) bool {
    var left: LabelIterator = .{ .bytes = a };
    var right: LabelIterator = .{ .bytes = b };
    while (true) {
        const x = left.next();
        const y = right.next();
        if (x == null or y == null) return x == null and y == null;
        if (x.? != y.?) return false;
    }
}
const LabelIterator = struct {
    bytes: []const u8,
    at: usize = 0,
    started: bool = false,
    fn next(self: *LabelIterator) ?u8 {
        var space = false;
        while (self.at < self.bytes.len and isSpace(self.bytes[self.at])) : (self.at += 1) space = true;
        if (self.at == self.bytes.len) return null;
        if (space and self.started) return ' ';
        self.started = true;
        const byte = self.bytes[self.at];
        self.at += 1;
        return std.ascii.toLower(byte);
    }
    fn isSpace(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
    }
};

/// Parse UTF-8 `source` into `buffers`. A line feed, carriage return or
/// both end a line; NUL becomes U+FFFD.
pub fn parse(source: []const u8, buffers: Buffers) Error!Tree {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidText;
    var builder: Builder = .{ .nodes = buffers.nodes, .text = buffers.text };
    _ = try builder.add(none, .{ .kind = .document });
    try blocks.parse(&builder, source);
    const block_count = builder.len;
    var index: u32 = 0;
    while (index < block_count) : (index += 1) switch (builder.nodes[index].kind) {
        .paragraph, .heading, .table_cell => try inlines.parse(&builder, index),
        else => {},
    };
    return .{ .nodes = builder.nodes[0..builder.len], .text = builder.text[0..builder.text_len] };
}

test {
    _ = @import("tests.zig");
}
