//! Bracket matching outside strings and comments, by the tokens of the
//! lines, within a bounded scan. A source is any value with `lineCount`,
//! `readLine`, `lineStart`, `lineAt` and `byteLength`, as `SliceLines`.
const std = @import("std");
const syntax = @import("root.zig");
const Language = @import("languages.zig").Language;
const Highlighter = @import("highlighter.zig").Highlighter;

const Token = syntax.Token;
const TokenKind = syntax.TokenKind;

/// A scan stops after this many lines or bytes from where it starts.
pub const scan_lines = 1000;
pub const scan_bytes = 64 << 10;

/// Byte offsets of an opening bracket and the closing one it matches.
pub const Pair = struct {
    open: usize,
    close: usize,
    /// The inside of the pair, between the brackets.
    pub fn inner(self: Pair) struct { start: usize, end: usize } {
        return .{ .start = self.open + 1, .end = self.close };
    }
};

/// A language's single-byte bracket pairs, apart from < and >, which are
/// more often operators.
pub const Pairs = struct {
    opens: [16]u8 = undefined,
    closes: [16]u8 = undefined,
    len: usize = 0,

    pub fn of(language: ?*const Language) Pairs {
        var self: Pairs = .{};
        const value = language orelse {
            self.opens[0..3].* = "([{".*;
            self.closes[0..3].* = ")]}".*;
            self.len = 3;
            return self;
        };
        for (value.brackets) |pair| {
            if (pair.open.len != 1 or pair.close.len != 1 or pair.open[0] == '<' or self.len == self.opens.len) continue;
            self.opens[self.len] = pair.open[0];
            self.closes[self.len] = pair.close[0];
            self.len += 1;
        }
        return self;
    }
    fn openIndex(self: *const Pairs, c: u8) ?usize {
        return std.mem.indexOfScalar(u8, self.opens[0..self.len], c);
    }
    fn closeIndex(self: *const Pairs, c: u8) ?usize {
        return std.mem.indexOfScalar(u8, self.closes[0..self.len], c);
    }
};

/// Whether a bracket in a token of `kind` counts.
pub fn bracketToken(kind: TokenKind) bool {
    return kind != .string and kind != .comment and kind != .regexp and kind != .escape and kind != .code;
}

/// Where a caret at `head` moves to go to the other bracket of `pair`: from
/// either side of a bracket to the same side of the other, inside or
/// outside the pair.
pub fn jumpTarget(head: usize, pair: Pair) usize {
    const inside = head >= pair.open + 1 and head <= pair.close;
    const at_close = head >= pair.close and head <= pair.close + 1;
    if (at_close and inside) return pair.open + 1;
    if (at_close) return pair.open;
    if (inside) return pair.close;
    return pair.close + 1;
}

pub fn Matcher(comptime Source: type) type {
    return struct {
        const Self = @This();
        source: Source,
        /// Tokens decide what is inside strings and comments; without a
        /// highlighter every bracket counts.
        highlighter: ?*const Highlighter = null,
        pairs: Pairs = Pairs.of(null),
        /// Scratch for one line and its tokens; longer lines are scanned
        /// only as far as the buffer holds them.
        line: []u8,
        tokens: []Token,

        const Line = struct { start: usize, text: []const u8, tokens: ?[]const Token };

        fn read(self: *Self, index: usize) !Line {
            const value = try self.source.readLine(index, self.line);
            const start = try self.source.lineStart(index);
            return .{ .start = start, .text = value.text, .tokens = self.lineTokens(index, value) };
        }
        /// Tokens of a line, or null when the whole line is code.
        fn lineTokens(self: *Self, index: usize, value: syntax.SourceLine) ?[]const Token {
            const highlighter = self.highlighter orelse return null;
            if (value.length > value.text.len) return null;
            const start = highlighter.stateOf(index);
            // A line starting in code without the characters that start
            // strings and comments is all code.
            if (start.state == 0 and std.mem.indexOfAny(u8, value.text, "\"'`/#*-<%;") == null) return null;
            return highlighter.tokens(index, value.text, self.tokens).tokens;
        }
        fn kindIn(tokens: ?[]const Token, at: usize) TokenKind {
            return syntax.kindAt(tokens orelse return .text, at);
        }

        fn byteAt(self: *Self, offset: usize) !?u8 {
            if (offset >= try self.source.byteLength()) return null;
            const line = try self.read(try self.source.lineAt(offset));
            const at = offset - line.start;
            return if (at < line.text.len) line.text[at] else '\n';
        }
        /// The kind of the token holding the byte before `offset`, or at it at
        /// the start of a line.
        fn tokenAt(self: *Self, offset: usize) !TokenKind {
            const line = try self.read(try self.source.lineAt(offset));
            return kindIn(line.tokens, (offset - line.start) -| 1);
        }

        /// The bracket matching the one at `offset`.
        pub fn match(self: *Self, offset: usize) !?Pair {
            const c = try self.byteAt(offset) orelse return null;
            if (self.pairs.openIndex(c)) |i| {
                const close = try self.scan(offset + 1, .forward, self.pairs.opens[i], self.pairs.closes[i]) orelse return null;
                return .{ .open = offset, .close = close };
            }
            if (self.pairs.closeIndex(c)) |i| {
                if (offset == 0) return null;
                const open = try self.scan(offset - 1, .backward, self.pairs.closes[i], self.pairs.opens[i]) orelse return null;
                return .{ .open = open, .close = offset };
            }
            return null;
        }

        const Direction = enum { forward, backward };

        /// From `offset` in `direction`, the unmatched `want`, counting the
        /// nested pairs of `same` and `want` and skipping strings and comments.
        fn scan(self: *Self, offset: usize, direction: Direction, same: u8, want: u8) !?usize {
            const length = try self.source.byteLength();
            if (offset >= length) return null;
            const first = try self.source.lineAt(offset);
            var depth: usize = 0;
            if (direction == .forward) {
                const stop = @min(first + scan_lines, try self.source.lineAt(@min(offset + scan_bytes, length)) + 1, try self.source.lineCount());
                var index = first;
                while (index < stop) : (index += 1) {
                    const line = try self.read(index);
                    var at: usize = if (offset >= line.start and offset <= line.start + line.text.len) offset - line.start else 0;
                    while (at < line.text.len) : (at += 1) {
                        const c = line.text[at];
                        if ((c != same and c != want) or !bracketToken(kindIn(line.tokens, at))) continue;
                        if (c == same) {
                            depth += 1;
                        } else if (depth == 0) {
                            return line.start + at;
                        } else depth -= 1;
                    }
                }
                return null;
            }
            const lowest = @max(first -| scan_lines, try self.source.lineAt(offset -| scan_bytes));
            var index = first + 1;
            while (index > lowest) {
                index -= 1;
                const line = try self.read(index);
                if (line.text.len == 0) continue;
                var at: usize = if (offset >= line.start and offset < line.start + line.text.len) offset - line.start else line.text.len - 1;
                while (true) : (at -= 1) {
                    const c = line.text[at];
                    if ((c == same or c == want) and bracketToken(kindIn(line.tokens, at))) {
                        if (c == same) {
                            depth += 1;
                        } else if (depth == 0) {
                            return line.start + at;
                        } else depth -= 1;
                    }
                    if (at == 0) break;
                }
            }
            return null;
        }

        /// The innermost pair around `start..end`, or touching it: the pair a
        /// bracket just before `end` closes, or one at `start` opens, when it
        /// holds the range, else the opening bracket before `start` and the
        /// closing one at or after `end`. A caret just after a closing
        /// bracket is in its pair.
        pub fn enclosing(self: *Self, start: usize, end: usize) !?Pair {
            const length = try self.source.byteLength();
            var best: ?Pair = null;
            if (end > 0) if (try self.byteAt(end - 1)) |c| if (self.pairs.closeIndex(c) != null and bracketToken(try self.tokenAt(end))) {
                if (try self.match(end - 1)) |pair| if (pair.open <= start) {
                    best = pair;
                };
            };
            if (start < length) if (try self.byteAt(start)) |c| if (self.pairs.openIndex(c) != null and bracketToken(try self.tokenAt(start + 1))) {
                if (try self.match(start)) |pair| if (pair.close + 1 >= end) {
                    if (best == null or pair.close - pair.open < best.?.close - best.?.open) best = pair;
                };
            };
            if (best) |pair| return pair;
            if (start == 0) return null;
            var from = start - 1;
            var tries: usize = 0;
            while (tries < 64) : (tries += 1) {
                const opener = try self.unmatchedOpener(from) orelse return null;
                if (try self.scan(opener.at + 1, .forward, self.pairs.opens[opener.which], self.pairs.closes[opener.which])) |close| {
                    if (close >= end) return .{ .open = opener.at, .close = close };
                }
                if (opener.at == 0) return null;
                from = opener.at - 1;
            }
            return null;
        }

        /// Back from `offset`, an opening bracket that the closing ones after
        /// it do not close, in one pass for every kind of bracket.
        fn unmatchedOpener(self: *Self, offset: usize) !?struct { at: usize, which: usize } {
            const length = try self.source.byteLength();
            const first = try self.source.lineAt(@min(offset, length));
            const lowest = @max(first -| scan_lines, try self.source.lineAt(offset -| scan_bytes));
            var stack: [256]u8 = undefined;
            var depth: usize = 0;
            var index = first + 1;
            while (index > lowest) {
                index -= 1;
                const raw = try self.source.readLine(index, self.line);
                // Brackets are rare: tokenize only lines holding some.
                if (std.mem.indexOfAny(u8, raw.text, self.pairs.opens[0..self.pairs.len]) == null and
                    std.mem.indexOfAny(u8, raw.text, self.pairs.closes[0..self.pairs.len]) == null) continue;
                const line_start = try self.source.lineStart(index);
                const tokens = self.lineTokens(index, raw);
                if (raw.text.len == 0) continue;
                var at: usize = if (offset >= line_start and offset < line_start + raw.text.len) offset - line_start else raw.text.len - 1;
                while (true) : (at -= 1) {
                    const c = raw.text[at];
                    const open = self.pairs.openIndex(c);
                    const close = self.pairs.closeIndex(c);
                    if ((open != null or close != null) and bracketToken(kindIn(tokens, at))) {
                        if (close != null) {
                            if (depth < stack.len) stack[depth] = c;
                            depth += 1;
                        } else if (depth > 0) {
                            if (depth <= stack.len and stack[depth - 1] == self.pairs.closes[open.?]) depth -= 1;
                        } else return .{ .at = line_start + at, .which = open.? };
                    }
                    if (at == 0) break;
                }
            }
            return null;
        }
    };
}
