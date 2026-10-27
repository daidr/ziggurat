//! Inline content of one paragraph, heading or table cell. Text runs,
//! delimiter runs and brackets are appended as a flat list of children;
//! closing brackets turn into links and images, and delimiter runs are
//! matched into emphasis, strong emphasis and strikethrough in place.
//! Bounded stacks keep the work linear in the input; runs and brackets
//! past them stay literal text.
const std = @import("std");
const md = @import("root.zig");
const entities = @import("entities.zig");

const Builder = md.Builder;
const Error = md.Error;
const none = md.none;

const max_delimiters = 256;
const max_brackets = 64;

const Delimiter = struct {
    node: u32,
    byte: u8,
    count: usize,
    original: usize,
    can_open: bool,
    can_close: bool,
    removed: bool = false,
};

const Bracket = struct {
    node: u32,
    image: bool,
    active: bool = true,
    bottom: usize,
    /// Offset just after the opening bracket.
    start: usize,
};

pub fn parse(b: *Builder, block: u32) Error!void {
    var parser: Parser = .{ .b = b, .block = block, .raw = b.nodes[block].text };
    b.nodes[block].text = "";
    try parser.run();
}

const Parser = struct {
    b: *Builder,
    block: u32,
    raw: []const u8,
    pos: usize = 0,
    delimiters: [max_delimiters]Delimiter = undefined,
    delimiter_len: usize = 0,
    brackets: [max_brackets]Bracket = undefined,
    bracket_len: usize = 0,

    fn add(self: *Parser, node: md.Node) Error!u32 {
        return self.b.add(self.block, node);
    }
    fn text(self: *Parser, value: []const u8) Error!u32 {
        return self.add(.{ .kind = .text, .text = value });
    }

    fn run(self: *Parser) Error!void {
        const raw = self.raw;
        while (self.pos < raw.len) {
            const byte = raw[self.pos];
            switch (byte) {
                '\n' => try self.lineBreak(),
                '\\' => try self.escape(),
                '`' => try self.codeSpan(),
                '*', '_', '~' => try self.delimiterRun(),
                '[' => try self.openBracket(false, 1),
                '!' => if (self.pos + 1 < raw.len and raw[self.pos + 1] == '[') try self.openBracket(true, 2) else try self.plain(),
                ']' => try self.closeBracket(),
                '<' => if (!try self.angleAutolink()) {
                    _ = try self.text(raw[self.pos..][0..1]);
                    self.pos += 1;
                },
                '&' => try self.entity(),
                else => try self.plain(),
            }
        }
        self.processEmphasis(0);
        self.removeEmpty();
    }

    fn special(byte: u8) bool {
        return switch (byte) {
            '\n', '\\', '`', '*', '_', '~', '[', ']', '!', '<', '&' => true,
            else => false,
        };
    }
    /// A run of ordinary text, ending before the next special byte or
    /// before an extended autolink.
    fn plain(self: *Parser) Error!void {
        const raw = self.raw;
        const start = self.pos;
        if (try self.extendedAutolink(start)) return;
        var at = start + 1;
        while (at < raw.len and !special(raw[at])) : (at += 1) {
            if (isAutolinkBoundary(raw[at - 1]) and std.ascii.isAlphanumeric(raw[at]) and extendedLength(raw, at) != null) break;
        }
        self.pos = at;
        _ = try self.text(raw[start..at]);
    }

    fn lineBreak(self: *Parser) Error!void {
        var hard = false;
        const last = self.b.nodes[self.block].last_child;
        if (last != none and self.b.nodes[last].kind == .text) {
            const node = &self.b.nodes[last];
            const kept = std.mem.trimEnd(u8, node.text, " ");
            hard = node.text.len - kept.len >= 2;
            node.text = kept;
        }
        _ = try self.add(.{ .kind = if (hard) .hard_break else .soft_break });
        self.pos += 1;
        self.skipLeadingSpaces();
    }
    fn skipLeadingSpaces(self: *Parser) void {
        while (self.pos < self.raw.len and (self.raw[self.pos] == ' ' or self.raw[self.pos] == '\t')) self.pos += 1;
    }

    fn escape(self: *Parser) Error!void {
        const raw = self.raw;
        if (self.pos + 1 < raw.len and raw[self.pos + 1] == '\n') {
            _ = try self.add(.{ .kind = .hard_break });
            self.pos += 2;
            self.skipLeadingSpaces();
            return;
        }
        if (self.pos + 1 < raw.len and isPunctuation(raw[self.pos + 1])) {
            _ = try self.text(raw[self.pos + 1 ..][0..1]);
            self.pos += 2;
            return;
        }
        _ = try self.text(raw[self.pos..][0..1]);
        self.pos += 1;
    }

    fn codeSpan(self: *Parser) Error!void {
        const raw = self.raw;
        const open = runLength(raw, self.pos, '`');
        var at = self.pos + open;
        while (std.mem.indexOfScalarPos(u8, raw, at, '`')) |found| {
            const close = runLength(raw, found, '`');
            if (close == open) {
                var content = raw[self.pos + open .. found];
                if (std.mem.indexOfScalar(u8, content, '\n') != null) {
                    const start = self.b.mark();
                    for (content) |byte| try self.b.writeByte(if (byte == '\n') ' ' else byte);
                    content = self.b.since(start);
                }
                if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ' and std.mem.indexOfNone(u8, content, " ") != null)
                    content = content[1 .. content.len - 1];
                _ = try self.add(.{ .kind = .code, .text = content });
                self.pos = found + close;
                return;
            }
            at = found + close;
        }
        _ = try self.text(raw[self.pos..][0..open]);
        self.pos += open;
    }

    fn delimiterRun(self: *Parser) Error!void {
        const raw = self.raw;
        const byte = raw[self.pos];
        const count = runLength(raw, self.pos, byte);
        const node = try self.text(raw[self.pos..][0..count]);
        const before = previousCodepoint(raw, self.pos);
        const after = nextCodepoint(raw, self.pos + count);
        self.pos += count;
        if (byte == '~' and count > 2) return;
        if (self.delimiter_len == max_delimiters) return;
        const left = !isWhitespace(after) and (!isPunctuationCodepoint(after) or isWhitespace(before) or isPunctuationCodepoint(before));
        const right = !isWhitespace(before) and (!isPunctuationCodepoint(before) or isWhitespace(after) or isPunctuationCodepoint(after));
        var can_open = left;
        var can_close = right;
        if (byte == '_') {
            can_open = left and (!right or isPunctuationCodepoint(before));
            can_close = right and (!left or isPunctuationCodepoint(after));
        }
        if (!can_open and !can_close) return;
        self.delimiters[self.delimiter_len] = .{ .node = node, .byte = byte, .count = count, .original = count, .can_open = can_open, .can_close = can_close };
        self.delimiter_len += 1;
    }

    fn openBracket(self: *Parser, image: bool, width: usize) Error!void {
        const node = try self.text(self.raw[self.pos..][0..width]);
        self.pos += width;
        if (self.bracket_len == max_brackets) return;
        self.brackets[self.bracket_len] = .{ .node = node, .image = image, .bottom = self.delimiter_len, .start = self.pos };
        self.bracket_len += 1;
    }

    fn closeBracket(self: *Parser) Error!void {
        const raw = self.raw;
        if (self.bracket_len == 0 or !self.brackets[self.bracket_len - 1].active) {
            if (self.bracket_len > 0) self.bracket_len -= 1;
            _ = try self.text(raw[self.pos..][0..1]);
            self.pos += 1;
            return;
        }
        const opener = self.brackets[self.bracket_len - 1];
        const after = self.pos + 1;
        var target: ?Target = null;
        if (after < raw.len and raw[after] == '(') target = try inlineTarget(self.b, raw, after + 1);
        if (target == null) {
            var label = raw[opener.start..self.pos];
            var end = after;
            if (after < raw.len and raw[after] == '[') {
                if (linkLabel(raw, after)) |found| {
                    if (found.label.len > 0) label = found.label;
                    end = found.end;
                } else if (after + 1 < raw.len and raw[after + 1] == ']') end = after + 2;
            }
            if (label.len <= 999) if (self.b.lookup(label)) |definition| {
                target = .{ .url = definition.url, .title = definition.title, .end = end };
            };
        }
        self.bracket_len -= 1;
        const found = target orelse {
            _ = try self.text(raw[self.pos..][0..1]);
            self.pos += 1;
            return;
        };
        const nodes = self.b.nodes;
        const link = &nodes[opener.node];
        // Everything after the opening bracket becomes the label.
        const first = link.next;
        link.* = .{ .kind = if (opener.image) .image else .link, .parent = self.block, .url = found.url, .title = found.title };
        const owner = &nodes[self.block];
        if (first != none) {
            link.first_child = first;
            link.last_child = owner.last_child;
            var at = first;
            while (at != none) : (at = nodes[at].next) nodes[at].parent = opener.node;
            link.next = none;
            owner.last_child = opener.node;
        }
        self.processEmphasis(opener.bottom);
        self.delimiter_len = opener.bottom;
        // Links cannot contain other links.
        if (!opener.image) for (self.brackets[0..self.bracket_len]) |*bracket| {
            if (!bracket.image) bracket.active = false;
        };
        self.pos = found.end;
    }

    fn processEmphasis(self: *Parser, bottom: usize) void {
        const nodes = self.b.nodes;
        // Lowest opener index worth searching, per byte, closer length mod
        // 3 and whether the closer can also open.
        var floor: [3][3][2]usize = undefined;
        for (&floor) |*a| for (a) |*b| {
            b.* = .{ bottom, bottom };
        };
        var closer = bottom;
        while (closer < self.delimiter_len) {
            const c = &self.delimiters[closer];
            if (c.removed or !c.can_close) {
                closer += 1;
                continue;
            }
            const slot = &floor[byteSlot(c.byte)][c.original % 3][@intFromBool(c.can_open)];
            var found: ?usize = null;
            var at = closer;
            while (at > slot.*) {
                at -= 1;
                const o = &self.delimiters[at];
                if (o.removed or o.byte != c.byte or !o.can_open) continue;
                if (c.byte == '~') {
                    if (o.count != c.count) continue;
                } else if ((o.can_close or c.can_open) and (o.original + c.original) % 3 == 0 and !(o.original % 3 == 0 and c.original % 3 == 0)) continue;
                found = at;
                break;
            }
            const opener_index = found orelse {
                slot.* = closer;
                if (!c.can_open) c.removed = true;
                closer += 1;
                continue;
            };
            const o = &self.delimiters[opener_index];
            const used: usize = if (c.byte == '~') c.count else if (o.count >= 2 and c.count >= 2) 2 else 1;
            const kind: md.Kind = if (c.byte == '~') .strikethrough else if (used == 2) .strong else .emphasis;
            self.wrap(o.node, c.node, kind) catch {
                // Out of nodes: leave the rest of the runs as text.
                self.delimiter_len = bottom;
                return;
            };
            const opener_node = &nodes[o.node];
            const closer_node = &nodes[c.node];
            opener_node.text = opener_node.text[0 .. opener_node.text.len - used];
            closer_node.text = closer_node.text[used..];
            o.count -= used;
            c.count -= used;
            for (self.delimiters[opener_index + 1 .. closer]) |*between| between.removed = true;
            if (o.count == 0) o.removed = true;
            if (c.count == 0) {
                c.removed = true;
                closer += 1;
            }
        }
    }
    /// Move the siblings between `opener` and `closer` into a new node.
    fn wrap(self: *Parser, opener: u32, closer: u32, kind: md.Kind) Error!void {
        const b = self.b;
        if (b.len == b.nodes.len) return error.TooManyNodes;
        const nodes = b.nodes;
        const index = b.len;
        b.len += 1;
        nodes[index] = .{ .kind = kind, .parent = nodes[opener].parent, .next = closer };
        const first = nodes[opener].next;
        if (first != closer) {
            nodes[index].first_child = first;
            var at = first;
            while (true) : (at = nodes[at].next) {
                nodes[at].parent = index;
                if (nodes[at].next == closer) break;
            }
            nodes[at].next = none;
            nodes[index].last_child = at;
        }
        nodes[opener].next = index;
    }

    /// Drop text runs left empty by matched delimiters.
    fn removeEmpty(self: *Parser) void {
        const nodes = self.b.nodes;
        var walker = (md.Tree{ .nodes = nodes[0..self.b.len], .text = "" }).walk(self.block);
        while (walker.next()) |event| {
            if (!event.entering or !nodes[event.index].kind.isContainer()) continue;
            const owner = &nodes[event.index];
            var previous: u32 = none;
            var at = owner.first_child;
            while (at != none) : (at = nodes[at].next) {
                if (nodes[at].kind == .text and nodes[at].text.len == 0) {
                    if (previous == none) owner.first_child = nodes[at].next else nodes[previous].next = nodes[at].next;
                } else previous = at;
            }
            owner.last_child = previous;
        }
    }

    fn angleAutolink(self: *Parser) Error!bool {
        const raw = self.raw;
        const close = std.mem.indexOfScalarPos(u8, raw, self.pos + 1, '>') orelse return false;
        const content = raw[self.pos + 1 .. close];
        var url: []const u8 = undefined;
        if (isUriAutolink(content)) {
            url = content;
        } else if (isEmail(content)) {
            const start = self.b.mark();
            try self.b.write("mailto:");
            try self.b.write(content);
            url = self.b.since(start);
        } else return false;
        const link = try self.add(.{ .kind = .link, .url = url, .autolink = true });
        _ = try self.b.add(link, .{ .kind = .text, .text = content });
        self.pos = close + 1;
        return true;
    }

    fn extendedAutolink(self: *Parser, at: usize) Error!bool {
        if (at > 0 and !isAutolinkBoundary(self.raw[at - 1])) return false;
        const found = extendedLength(self.raw, at) orelse return false;
        const content = self.raw[at..][0..found.len];
        const start = self.b.mark();
        try self.b.write(found.prefix);
        try self.b.write(content);
        const link = try self.add(.{ .kind = .link, .url = self.b.since(start), .autolink = true });
        _ = try self.b.add(link, .{ .kind = .text, .text = content });
        self.pos = at + found.len;
        return true;
    }

    fn entity(self: *Parser) Error!void {
        const start = self.b.mark();
        if (try decodeEntity(self.b, self.raw, self.pos)) |end| {
            _ = try self.text(self.b.since(start));
            self.pos = end;
            return;
        }
        _ = try self.text(self.raw[self.pos..][0..1]);
        self.pos += 1;
    }
};

fn byteSlot(byte: u8) usize {
    return switch (byte) {
        '*' => 0,
        '_' => 1,
        else => 2,
    };
}

fn runLength(raw: []const u8, start: usize, byte: u8) usize {
    var end = start;
    while (end < raw.len and raw[end] == byte) end += 1;
    return end - start;
}

pub fn isPunctuation(byte: u8) bool {
    return switch (byte) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}
fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}
/// ASCII punctuation and the common Unicode punctuation and symbol blocks.
fn isPunctuationCodepoint(codepoint: u21) bool {
    if (codepoint < 0x80) return isPunctuation(@intCast(codepoint));
    return switch (codepoint) {
        0xa1...0xbf, 0xd7, 0xf7, 0x2010...0x2027, 0x2030...0x205e, 0x20a0...0x20cf, 0x2100...0x2bff, 0x3001...0x303f, 0xfe30...0xfe4f, 0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => true,
        else => false,
    };
}
/// The codepoint before `at`; a line start counts as whitespace.
fn previousCodepoint(raw: []const u8, at: usize) u21 {
    if (at == 0) return '\n';
    var start = at - 1;
    while (start > 0 and raw[start] & 0xc0 == 0x80) start -= 1;
    return std.unicode.utf8Decode(raw[start..at]) catch 0xfffd;
}
fn nextCodepoint(raw: []const u8, at: usize) u21 {
    if (at >= raw.len) return '\n';
    const len = std.unicode.utf8ByteSequenceLength(raw[at]) catch return 0xfffd;
    if (at + len > raw.len) return 0xfffd;
    return std.unicode.utf8Decode(raw[at..][0..len]) catch 0xfffd;
}

fn isUriAutolink(content: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, content, ':') orelse return false;
    if (colon < 2 or colon > 32 or !std.ascii.isAlphabetic(content[0])) return false;
    for (content[1..colon]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '.' and byte != '-') return false;
    for (content[colon + 1 ..]) |byte| if (byte <= ' ' or byte == '<' or byte == '>' or byte == 0x7f) return false;
    return true;
}
fn isEmail(content: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, content, '@') orelse return false;
    if (at == 0) return false;
    for (content[0..at]) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", byte) == null) return false;
    var labels = std.mem.splitScalar(u8, content[at + 1 ..], '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

fn isAutolinkBoundary(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '*', '_', '~', '(' => true,
        else => false,
    };
}

const Extended = struct { len: usize, prefix: []const u8 };
/// A bare `www.`, `http://` or `https://` address or an email address
/// starting at `at`, with trailing punctuation left out.
fn extendedLength(raw: []const u8, at: usize) ?Extended {
    const rest = raw[at..];
    var prefix: []const u8 = "";
    var domain_start: usize = 0;
    if (std.ascii.startsWithIgnoreCase(rest, "www.")) {
        prefix = "http://";
    } else if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
        domain_start = 8;
    } else if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
        domain_start = 7;
    } else return emailLength(rest);
    const domain_end = domainLength(rest[domain_start..]) orelse return null;
    if (domain_start == 0 and domain_end <= 4) return null;
    var end = domain_start + domain_end;
    while (end < rest.len and !std.ascii.isWhitespace(rest[end]) and rest[end] != '<') end += 1;
    end = trimTrailing(rest[0..end], domain_start + domain_end);
    return .{ .len = end, .prefix = prefix };
}
fn domainLength(text: []const u8) ?usize {
    var end: usize = 0;
    var underscore_last: u2 = 0;
    var segment: usize = 0;
    while (end < text.len) : (end += 1) {
        const byte = text[end];
        if (byte == '.') {
            if (segment == 0) break;
            underscore_last <<= 1;
            segment = 0;
        } else if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte >= 0x80) {
            if (byte == '_') underscore_last |= 1;
            segment += 1;
        } else break;
    }
    if (segment == 0 and end > 0 and text[end - 1] == '.') {
        end -= 1;
        underscore_last >>= 1;
    }
    if (end == 0 or underscore_last != 0) return null;
    return end;
}
/// Drop trailing punctuation, an unbalanced closing parenthesis and a
/// trailing entity reference from an extended autolink.
fn trimTrailing(text: []const u8, minimum: usize) usize {
    var end = text.len;
    while (end > minimum) {
        const byte = text[end - 1];
        if (std.mem.indexOfScalar(u8, "?!.,:*_~'\"", byte) != null) {
            end -= 1;
        } else if (byte == ')') {
            const open = std.mem.count(u8, text[0..end], "(");
            const close = std.mem.count(u8, text[0..end], ")");
            if (close <= open) break;
            end -= 1;
        } else if (byte == ';') {
            var start = end - 1;
            while (start > minimum and std.ascii.isAlphanumeric(text[start - 1])) start -= 1;
            if (start > minimum and text[start - 1] == '&') end = start - 1 else break;
        } else break;
    }
    return end;
}
fn emailLength(text: []const u8) ?Extended {
    var at: usize = 0;
    while (at < text.len and (std.ascii.isAlphanumeric(text[at]) or std.mem.indexOfScalar(u8, ".-_+", text[at]) != null)) at += 1;
    if (at == 0 or at >= text.len or text[at] != '@') return null;
    var end = at + 1;
    var dots: usize = 0;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-' or text[end] == '_' or (text[end] == '.' and end + 1 < text.len and std.ascii.isAlphanumeric(text[end + 1])))) : (end += 1) {
        if (text[end] == '.') dots += 1;
    }
    if (dots == 0 or text[end - 1] == '-' or text[end - 1] == '_') return null;
    return .{ .len = end, .prefix = "mailto:" };
}

const Target = struct { url: []const u8, title: []const u8, end: usize };

fn skipSpace(raw: []const u8, start: usize) usize {
    var at = start;
    while (at < raw.len and (raw[at] == ' ' or raw[at] == '\t' or raw[at] == '\n')) at += 1;
    return at;
}

/// `(destination "title")` after a closing bracket, from just past `(`.
fn inlineTarget(b: *Builder, raw: []const u8, start: usize) Error!?Target {
    var at = skipSpace(raw, start);
    var destination: []const u8 = "";
    if (at < raw.len and raw[at] != ')') {
        const found = linkDestination(raw, at) orelse return null;
        destination = found.text;
        at = found.end;
    }
    const before_title = at;
    at = skipSpace(raw, at);
    var title: []const u8 = "";
    if (at > before_title and at < raw.len and raw[at] != ')') {
        const found = linkTitle(raw, at) orelse return null;
        title = found.text;
        at = skipSpace(raw, found.end);
    }
    if (at >= raw.len or raw[at] != ')') return null;
    return .{ .url = try decode(b, destination), .title = try decode(b, title), .end = at + 1 };
}

const Span = struct { text: []const u8, end: usize };

fn linkDestination(raw: []const u8, start: usize) ?Span {
    if (raw[start] == '<') {
        var at = start + 1;
        while (at < raw.len) : (at += 1) switch (raw[at]) {
            '\\' => at += 1,
            '\n', '<' => return null,
            '>' => return .{ .text = raw[start + 1 .. at], .end = at + 1 },
            else => {},
        };
        return null;
    }
    var depth: usize = 0;
    var at = start;
    while (at < raw.len) : (at += 1) {
        const byte = raw[at];
        if (byte == '\\' and at + 1 < raw.len and isPunctuation(raw[at + 1])) {
            at += 1;
        } else if (byte == '(') {
            depth += 1;
            if (depth > 32) return null;
        } else if (byte == ')') {
            if (depth == 0) break;
            depth -= 1;
        } else if (byte <= ' ' or byte == 0x7f) break;
    }
    if (depth != 0 or at == start) return null;
    return .{ .text = raw[start..at], .end = at };
}

fn linkTitle(raw: []const u8, start: usize) ?Span {
    const open = raw[start];
    const close: u8 = switch (open) {
        '"', '\'' => open,
        '(' => ')',
        else => return null,
    };
    var at = start + 1;
    while (at < raw.len) : (at += 1) {
        const byte = raw[at];
        if (byte == '\\') {
            at += 1;
        } else if (byte == close) {
            return .{ .text = raw[start + 1 .. at], .end = at + 1 };
        } else if (open == '(' and byte == '(') return null;
    }
    return null;
}

const Label = struct { label: []const u8, end: usize };
/// `[label]` at `start`, at most 999 bytes, without unescaped brackets.
fn linkLabel(raw: []const u8, start: usize) ?Label {
    var at = start + 1;
    while (at < raw.len and at - start <= 1000) : (at += 1) switch (raw[at]) {
        '\\' => at += 1,
        '[' => return null,
        ']' => {
            const label = raw[start + 1 .. at];
            if (std.mem.trim(u8, label, " \t\n").len == 0) return if (label.len == 0) .{ .label = "", .end = at + 1 } else null;
            return .{ .label = label, .end = at + 1 };
        },
        else => {},
    };
    return null;
}

/// Consume link reference definitions at the start of paragraph text and
/// return what follows them.
pub fn definitions(b: *Builder, raw: []const u8) Error![]const u8 {
    var rest = raw;
    while (rest.len > 0 and rest[0] == '[') {
        const label = linkLabel(rest, 0) orelse break;
        if (label.label.len == 0 or label.end >= rest.len or rest[label.end] != ':') break;
        var at = skipOneLine(rest, label.end + 1) orelse break;
        if (at >= rest.len) break;
        const destination = linkDestination(rest, at) orelse break;
        if (destination.text.len == 0 and rest[at] != '<') break;
        at = destination.end;
        var title: []const u8 = "";
        var end = lineEnd(rest, at);
        // A title must be separated from the destination; one that does
        // not end its line leaves the definition without it.
        if (skipOneLine(rest, at)) |title_start| if (title_start > at and title_start < rest.len) if (linkTitle(rest, title_start)) |found| if (lineEnd(rest, found.end)) |title_end| {
            title = found.text;
            end = title_end;
        };
        if (end == null) break;
        try b.define(.{ .label = label.label, .url = try decode(b, destination.text), .title = try decode(b, title) });
        rest = rest[end.?..];
    }
    return rest;
}
/// Skip spaces and at most one line feed.
fn skipOneLine(raw: []const u8, start: usize) ?usize {
    var at = start;
    var lines: usize = 0;
    while (at < raw.len and (raw[at] == ' ' or raw[at] == '\t' or raw[at] == '\n')) : (at += 1) {
        if (raw[at] == '\n') {
            lines += 1;
            if (lines > 1) return null;
        }
    }
    return at;
}
/// Offset after the line feed when only spaces remain on the line.
fn lineEnd(raw: []const u8, start: usize) ?usize {
    var at = start;
    while (at < raw.len and (raw[at] == ' ' or raw[at] == '\t')) at += 1;
    if (at == raw.len) return at;
    return if (raw[at] == '\n') at + 1 else null;
}

/// Copy `raw` into the text buffer with backslash escapes and entity
/// references resolved.
pub fn decode(b: *Builder, raw: []const u8) Error![]const u8 {
    const start = b.mark();
    var at: usize = 0;
    while (at < raw.len) {
        const byte = raw[at];
        if (byte == '\\' and at + 1 < raw.len and isPunctuation(raw[at + 1])) {
            try b.writeByte(raw[at + 1]);
            at += 2;
        } else if (byte == '&') {
            if (try decodeEntity(b, raw, at)) |end| {
                at = end;
            } else {
                try b.writeByte('&');
                at += 1;
            }
        } else {
            try b.writeByte(byte);
            at += 1;
        }
    }
    return b.since(start);
}

/// Write the character an entity reference at `at` names and return the
/// offset after it, or null when it is not one.
fn decodeEntity(b: *Builder, raw: []const u8, at: usize) Error!?usize {
    const semicolon = std.mem.indexOfScalarPos(u8, raw, at + 1, ';') orelse return null;
    const name = raw[at + 1 .. semicolon];
    if (name.len == 0 or name.len > 32) return null;
    if (name[0] == '#') {
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0 or digits.len > @as(usize, if (hex) 6 else 7)) return null;
        const value = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch return null;
        const codepoint: u21 = if (value == 0 or value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) 0xfffd else @intCast(value);
        try b.writeCodepoint(codepoint);
        return semicolon + 1;
    }
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte)) return null;
    const value = entities.lookup(name) orelse return null;
    try b.write(value);
    return semicolon + 1;
}
