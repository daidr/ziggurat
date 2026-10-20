//! Block structure, one line at a time: open containers are matched in
//! order, new containers and leaves start on what remains, and a leaf
//! that does not start becomes paragraph text. Paragraph, heading and
//! table cell content is copied into the text buffer for the inline pass.
const std = @import("std");
const md = @import("root.zig");
const inlines = @import("inlines.zig");

const Builder = md.Builder;
const Kind = md.Kind;
const Error = md.Error;

pub fn parse(builder: *Builder, source: []const u8) Error!void {
    var parser: Parser = .{ .b = builder };
    parser.open[0] = .{ .node = 0, .kind = .document };
    parser.len = 1;
    var start: usize = 0;
    while (start < source.len) {
        var end = start;
        while (end < source.len and source[end] != '\n' and source[end] != '\r') end += 1;
        try parser.line(source[start..end]);
        parser.line_number += 1;
        end += if (end + 1 < source.len and source[end] == '\r' and source[end + 1] == '\n') 2 else 1;
        start = end;
    }
    try parser.closeTo(1);
}

/// The unconsumed part of one source line. Tabs advance to the next
/// multiple of four columns; a container may consume part of one.
const Line = struct {
    bytes: []const u8,
    pos: usize = 0,
    column: usize = 0,
    /// Columns of a tab before `pos` that are still unconsumed.
    partial: usize = 0,

    fn indent(self: Line) usize {
        var columns = self.partial;
        var column = self.column + self.partial;
        for (self.bytes[self.pos..]) |byte| switch (byte) {
            ' ' => {
                columns += 1;
                column += 1;
            },
            '\t' => {
                const width = 4 - column % 4;
                columns += width;
                column += width;
            },
            else => break,
        };
        return columns;
    }
    fn nonspace(self: Line) usize {
        var pos = self.pos;
        while (pos < self.bytes.len and (self.bytes[pos] == ' ' or self.bytes[pos] == '\t')) pos += 1;
        return pos;
    }
    /// The byte after leading whitespace, or 0 at the end of the line.
    fn peek(self: Line) u8 {
        const pos = self.nonspace();
        return if (pos < self.bytes.len) self.bytes[pos] else 0;
    }
    fn blank(self: Line) bool {
        return self.nonspace() == self.bytes.len;
    }
    /// Text after leading whitespace.
    fn content(self: Line) []const u8 {
        return self.bytes[self.nonspace()..];
    }
    fn advance(self: *Line, columns: usize) void {
        var left = columns;
        while (left > 0) {
            if (self.partial > 0) {
                const take = @min(self.partial, left);
                self.partial -= take;
                self.column += take;
                left -= take;
                continue;
            }
            if (self.pos >= self.bytes.len) return;
            if (self.bytes[self.pos] == '\t') {
                const width = 4 - self.column % 4;
                self.pos += 1;
                if (width <= left) {
                    self.column += width;
                    left -= width;
                } else {
                    self.column += left;
                    self.partial = width - left;
                    left = 0;
                }
            } else {
                self.pos += 1;
                self.column += 1;
                left -= 1;
            }
        }
    }
    fn skipWhitespace(self: *Line) void {
        self.advance(self.indent());
    }
    /// Consume one byte after the whitespace, and then one column of
    /// whitespace if any follows, as a block quote marker does.
    fn marker(self: *Line) void {
        self.skipWhitespace();
        self.advance(1);
        if (self.pos < self.bytes.len and (self.bytes[self.pos] == ' ' or self.bytes[self.pos] == '\t')) self.advance(1);
    }
};

const Open = struct {
    node: u32,
    kind: Kind,
    /// Columns a list item's continuation lines are indented by.
    indent: usize = 0,
    /// Fence byte, run length and opening indentation of a fenced code block.
    fence: u8 = 0,
    fence_len: usize = 0,
    fence_indent: usize = 0,
    /// Text offset of a paragraph's or code block's content.
    start: usize = 0,
    lines: u32 = 0,
    /// A list item whose marker ended its first line.
    blank_start: bool = false,
};

const ListMarker = struct { ordered: bool, start: u32, marker: u8, width: usize };

const Parser = struct {
    b: *Builder,
    open: [md.max_depth + 2]Open = undefined,
    len: usize = 0,
    line_number: u32 = 0,
    blank_before: bool = false,
    columns: usize = 0,
    aligns: [md.max_columns]md.Alignment = undefined,

    fn tip(self: *Parser) *Open {
        return &self.open[self.len - 1];
    }
    fn nodeOf(self: *Parser, open: *const Open) *md.Node {
        return &self.b.nodes[open.node];
    }
    /// Room for `count` more containers within the nesting limit.
    fn room(self: *const Parser, count: usize) bool {
        return self.len + count <= md.max_depth + 1;
    }

    fn push(self: *Parser, kind: Kind, fields: md.Node) Error!*Open {
        while (self.tip().kind == .list and kind != .list_item) try self.pop();
        const parent = self.tip().*;
        // A blank line between two blocks of one item loosens its list.
        if (parent.kind == .list_item and self.blank_before and self.b.nodes[parent.node].first_child != md.none)
            self.b.nodes[self.b.nodes[parent.node].parent].tight = false;
        var value = fields;
        value.kind = kind;
        value.line = self.line_number;
        const index = try self.b.add(parent.node, value);
        self.open[self.len] = .{ .node = index, .kind = kind, .start = self.b.mark() };
        self.len += 1;
        return self.tip();
    }
    fn pop(self: *Parser) Error!void {
        const open = self.open[self.len - 1];
        self.len -= 1;
        switch (open.kind) {
            .paragraph => {
                const raw = std.mem.trimRight(u8, self.b.since(open.start), " \t\n");
                const rest = try inlines.definitions(self.b, raw);
                if (rest.len == 0) self.b.unlinkLast(open.node) else self.b.nodes[open.node].text = rest;
            },
            .code_block => {
                var text = self.b.since(open.start);
                if (open.fence == 0) {
                    // Trailing blank lines are not part of indented code.
                    const last = std.mem.lastIndexOfNone(u8, text, " \t\n");
                    text = if (last) |at| text[0 .. std.mem.indexOfScalarPos(u8, text, at, '\n').? + 1] else "";
                }
                self.b.nodes[open.node].text = text;
            },
            else => {},
        }
    }
    fn closeTo(self: *Parser, keep: usize) Error!void {
        while (self.len > keep) try self.pop();
    }
    /// Close what `matched` did not match, and a matched paragraph that a
    /// new block interrupts.
    fn closeLeaf(self: *Parser, matched: usize) Error!void {
        try self.closeTo(if (self.open[matched - 1].kind == .paragraph) matched - 1 else matched);
    }
    fn copy(self: *Parser, bytes: []const u8) Error!void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, 0)) |at| {
            try self.b.write(rest[0..at]);
            try self.b.write("\u{fffd}");
            rest = rest[at + 1 ..];
        }
        try self.b.write(rest);
    }
    fn copyRest(self: *Parser, l: *const Line) Error!void {
        try self.b.writeSpaces(l.partial);
        try self.copy(l.bytes[l.pos..]);
        try self.b.writeByte('\n');
    }
    fn appendParagraph(self: *Parser, l: *Line) Error!void {
        l.skipWhitespace();
        l.partial = 0;
        try self.copy(l.bytes[l.pos..]);
        try self.b.writeByte('\n');
        self.tip().lines += 1;
    }

    fn line(self: *Parser, bytes: []const u8) Error!void {
        var l: Line = .{ .bytes = bytes };
        var matched: usize = 1;
        while (matched < self.len) : (matched += 1) {
            const open = &self.open[matched];
            switch (open.kind) {
                .block_quote => if (l.indent() <= 3 and l.peek() == '>') l.marker() else break,
                .list => {},
                .list_item => if (l.blank()) {
                    if (open.blank_start and self.b.nodes[open.node].first_child == md.none) break;
                } else if (l.indent() >= open.indent) l.advance(open.indent) else break,
                .code_block => if (open.fence == 0) {
                    if (l.indent() >= 4) l.advance(4) else if (l.blank()) l.skipWhitespace() else break;
                },
                .paragraph => if (l.blank()) break,
                .table => if (l.blank() or startsBlock(l)) break,
                else => break,
            }
        }
        const all_matched = matched == self.len;
        if (all_matched and self.tip().kind == .code_block) {
            const open = self.tip();
            self.blank_before = false;
            if (open.fence != 0) {
                if (closesFence(l, open.*)) return self.pop();
                l.advance(@min(open.fence_indent, l.indent()));
            }
            return self.copyRest(&l);
        }

        var opened = false;
        while (true) {
            const deepest = self.open[matched - 1].kind;
            if (deepest == .code_block or deepest == .table) break;
            const in_paragraph = deepest == .paragraph and !opened;
            const indent = l.indent();
            if (indent >= 4) {
                if (self.tip().kind == .paragraph or l.blank()) break;
                try self.closeLeaf(matched);
                _ = try self.push(.code_block, .{});
                l.advance(4);
                self.blank_before = false;
                return self.copyRest(&l);
            }
            const first = l.peek();
            if (first == '>' and self.room(1)) {
                try self.closeLeaf(matched);
                _ = try self.push(.block_quote, .{});
                l.marker();
                opened = true;
                matched = self.len;
                continue;
            }
            if (atxHeading(l.content())) |heading| {
                try self.closeLeaf(matched);
                const open = try self.push(.heading, .{ .level = heading.level });
                try self.copy(heading.text);
                self.b.nodes[open.node].text = self.b.since(open.start);
                self.blank_before = false;
                return self.pop();
            }
            if (fence(l.content())) |info| {
                try self.closeLeaf(matched);
                const open = try self.push(.code_block, .{ .fenced = true });
                open.fence = info.byte;
                open.fence_len = info.len;
                open.fence_indent = indent;
                const node = self.nodeOf(open);
                node.title = try inlines.decode(self.b, info.info);
                node.url = node.title[0 .. std.mem.indexOfAny(u8, node.title, " \t") orelse node.title.len];
                open.start = self.b.mark();
                self.blank_before = false;
                return;
            }
            if (in_paragraph) if (setext(l.content())) |level| {
                const open = self.tip().*;
                self.len -= 1;
                const raw = std.mem.trimRight(u8, self.b.since(open.start), " \t\n");
                const rest = try inlines.definitions(self.b, raw);
                if (rest.len > 0) {
                    const node = &self.b.nodes[open.node];
                    node.kind = .heading;
                    node.level = level;
                    node.text = rest;
                    self.blank_before = false;
                    return;
                }
                // Only definitions: the underline is read as other content.
                self.b.unlinkLast(open.node);
                matched = self.len;
                continue;
            };
            if (thematicBreak(l.content())) {
                try self.closeLeaf(matched);
                _ = try self.push(.thematic_break, .{});
                self.blank_before = false;
                return self.pop();
            }
            if (in_paragraph and self.tip().lines == 1 and try self.table(l.content())) {
                self.blank_before = false;
                return;
            }
            if (listMarker(l.content())) |list_marker| {
                var after = l;
                after.skipWhitespace();
                after.advance(list_marker.width);
                const empty = after.blank();
                if (in_paragraph and (empty or (list_marker.ordered and list_marker.start != 1))) break;
                if (!self.room(2)) break;
                try self.closeLeaf(matched);
                const current = self.tip();
                const same = current.kind == .list and sameList(self.nodeOf(current).*, list_marker);
                if (current.kind == .list and !same) try self.pop();
                if (same) {
                    if (self.blank_before) self.nodeOf(current).tight = false;
                } else _ = try self.push(.list, .{ .ordered = list_marker.ordered, .start = list_marker.start, .marker = list_marker.marker });
                var spaces = after.indent();
                if (empty or spaces >= 5) spaces = 1;
                if (!empty) after.advance(spaces);
                const item = try self.push(.list_item, .{});
                item.indent = indent + list_marker.width + spaces;
                item.blank_start = empty;
                l = after;
                opened = true;
                matched = self.len;
                continue;
            }
            break;
        }

        if (!opened and !all_matched and self.tip().kind == .paragraph and !l.blank()) {
            self.blank_before = false;
            return self.appendParagraph(&l);
        }
        try self.closeTo(matched);
        if (l.blank()) {
            // A marker ending its line and a blank line inside a block quote
            // do not separate list content.
            self.blank_before = !opened and self.tip().kind != .block_quote;
            return;
        }
        switch (self.tip().kind) {
            .paragraph => try self.appendParagraph(&l),
            .table => try self.row(l.content(), false),
            else => {
                const task = self.taskMarker(&l);
                _ = try self.push(.paragraph, .{});
                if (task != .none) self.b.nodes[self.b.nodes[self.tip().node].parent].task = task;
                try self.appendParagraph(&l);
            },
        }
        self.blank_before = false;
    }

    /// A `[ ]` or `[x]` and whitespace opening the first paragraph of a
    /// list item on its marker line, which is consumed.
    fn taskMarker(self: *Parser, l: *Line) md.Task {
        const current = self.tip();
        if (current.kind != .list_item or current.blank_start or self.nodeOf(current).first_child != md.none) return .none;
        const text = l.content();
        if (text.len < 4 or text[0] != '[' or text[2] != ']' or (text[3] != ' ' and text[3] != '\t')) return .none;
        const task: md.Task = switch (text[1]) {
            ' ' => .unchecked,
            'x', 'X' => .checked,
            else => return .none,
        };
        if (std.mem.trim(u8, text[4..], " \t").len == 0) return .none;
        l.skipWhitespace();
        l.advance(3);
        return task;
    }

    /// Turn the one-line paragraph at the tip into a table header when
    /// `delimiter` is a delimiter row with as many cells.
    fn table(self: *Parser, delimiter: []const u8) Error!bool {
        var cells: [md.max_columns][]const u8 = undefined;
        const open = self.tip();
        const header = std.mem.trimRight(u8, self.b.since(open.start), " \t\n");
        if (std.mem.indexOfScalar(u8, delimiter, '|') == null and std.mem.indexOfScalar(u8, header, '|') == null) return false;
        const count = splitCells(delimiter, &cells);
        if (count == 0) return false;
        var aligns: [md.max_columns]md.Alignment = undefined;
        for (cells[0..count], 0..) |cell, index| {
            if (cell.len == 0) return false;
            const left = cell[0] == ':';
            const right = cell[cell.len - 1] == ':';
            const dashes = cell[@intFromBool(left) .. cell.len - @intFromBool(right and cell.len > 1)];
            if (dashes.len == 0 or std.mem.indexOfNone(u8, dashes, "-") != null) return false;
            aligns[index] = if (left and right) .center else if (left) .left else if (right) .right else .none;
        }
        if (splitCells(header, &cells) != count) return false;
        self.columns = count;
        self.aligns = aligns;
        open.kind = .table;
        const node = self.nodeOf(open);
        node.kind = .table;
        node.text = "";
        try self.row(header, true);
        return true;
    }
    fn row(self: *Parser, text: []const u8, header: bool) Error!void {
        var cells: [md.max_columns][]const u8 = undefined;
        const count = splitCells(text, &cells);
        const table_node = self.tip().node;
        const row_node = try self.b.add(table_node, .{ .kind = .table_row, .header = header, .line = self.line_number });
        for (0..self.columns) |index| {
            const start = self.b.mark();
            // An escaped pipe stays in its cell, even inside a code span.
            if (index < count) {
                var rest = cells[index];
                while (std.mem.indexOf(u8, rest, "\\|")) |at| {
                    try self.copy(rest[0..at]);
                    try self.b.writeByte('|');
                    rest = rest[at + 2 ..];
                }
                try self.copy(rest);
            }
            _ = try self.b.add(row_node, .{ .kind = .table_cell, .header = header, .alignment = self.aligns[index], .text = self.b.since(start), .line = self.line_number });
        }
    }
};

/// Cells of a table row, trimmed, without the optional outer pipes.
fn splitCells(text: []const u8, out: *[md.max_columns][]const u8) usize {
    var rest = std.mem.trim(u8, text, " \t");
    if (rest.len > 0 and rest[0] == '|') rest = rest[1..];
    if (rest.len > 0 and rest[rest.len - 1] == '|' and !(rest.len > 1 and rest[rest.len - 2] == '\\')) rest = rest[0 .. rest.len - 1];
    if (std.mem.trim(u8, rest, " \t").len == 0 and std.mem.indexOfScalar(u8, text, '|') == null) return 0;
    var count: usize = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at <= rest.len) : (at += 1) {
        if (at < rest.len and rest[at] == '\\') {
            at += 1;
            continue;
        }
        if (at == rest.len or rest[at] == '|') {
            if (count < out.len) {
                out[count] = std.mem.trim(u8, rest[start..at], " \t");
                count += 1;
            }
            start = at + 1;
        }
    }
    return count;
}

fn sameList(list: md.Node, marker: ListMarker) bool {
    return list.ordered == marker.ordered and list.marker == marker.marker;
}

/// The first line of another block, which ends a table.
fn startsBlock(l: Line) bool {
    if (l.indent() > 3) return false;
    const text = l.content();
    return text[0] == '>' or atxHeading(text) != null or fence(text) != null or thematicBreak(text) or listMarker(text) != null;
}

fn closesFence(l: Line, open: Open) bool {
    if (l.indent() > 3) return false;
    const text = l.content();
    const run = std.mem.indexOfNone(u8, text, &.{open.fence}) orelse text.len;
    return run >= open.fence_len and std.mem.trim(u8, text[run..], " \t").len == 0;
}

const Heading = struct { level: u8, text: []const u8 };
fn atxHeading(text: []const u8) ?Heading {
    const level = std.mem.indexOfNone(u8, text, "#") orelse text.len;
    if (level == 0 or level > 6) return null;
    if (level < text.len and text[level] != ' ' and text[level] != '\t') return null;
    var content = std.mem.trim(u8, text[level..], " \t");
    // An optional closing run of `#` after whitespace.
    const kept = std.mem.trimRight(u8, content, "#");
    if (kept.len == 0) {
        content = "";
    } else if (kept[kept.len - 1] == ' ' or kept[kept.len - 1] == '\t') content = std.mem.trimRight(u8, kept, " \t");
    return .{ .level = @intCast(level), .text = content };
}

const Fence = struct { byte: u8, len: usize, info: []const u8 };
fn fence(text: []const u8) ?Fence {
    if (text.len < 3 or (text[0] != '`' and text[0] != '~')) return null;
    const len = std.mem.indexOfNone(u8, text, text[0..1]) orelse text.len;
    if (len < 3) return null;
    const info = std.mem.trim(u8, text[len..], " \t");
    if (text[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .byte = text[0], .len = len, .info = info };
}

fn setext(text: []const u8) ?u8 {
    if (text.len == 0 or (text[0] != '=' and text[0] != '-')) return null;
    const run = std.mem.indexOfNone(u8, text, text[0..1]) orelse text.len;
    if (std.mem.trim(u8, text[run..], " \t").len != 0) return null;
    return if (text[0] == '=') 1 else 2;
}

fn thematicBreak(text: []const u8) bool {
    if (text.len == 0 or (text[0] != '*' and text[0] != '-' and text[0] != '_')) return false;
    var count: usize = 0;
    for (text) |byte| {
        if (byte == text[0]) count += 1 else if (byte != ' ' and byte != '\t') return false;
    }
    return count >= 3;
}

fn listMarker(text: []const u8) ?ListMarker {
    if (text.len == 0) return null;
    var marker: ListMarker = undefined;
    if (text[0] == '-' or text[0] == '+' or text[0] == '*') {
        marker = .{ .ordered = false, .start = 1, .marker = text[0], .width = 1 };
    } else {
        const digits = std.mem.indexOfNone(u8, text, "0123456789") orelse text.len;
        if (digits == 0 or digits > 9 or digits == text.len or (text[digits] != '.' and text[digits] != ')')) return null;
        marker = .{ .ordered = true, .start = std.fmt.parseInt(u32, text[0..digits], 10) catch return null, .marker = text[digits], .width = digits + 1 };
    }
    if (marker.width < text.len and text[marker.width] != ' ' and text[marker.width] != '\t') return null;
    return marker;
}
