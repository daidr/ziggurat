//! A tokenizer for the languages most code is in: identifiers and keywords,
//! numbers, strings with escapes and interpolations, line and block
//! comments, operators and punctuation, configured per language. Its state,
//! which fits in 40 bits so that Markdown can carry it for fenced code,
//! packs:
//!
//!     bits 0-7    the mode: 0 code, 1+k in block comment k, 32+j in string j
//!     bits 8-15   the depth of nested block comments
//!     bits 16-39  up to three strings an interpolation is inside, 8 bits
//!                 each: the string's index plus one, and the braces open
//!                 in the interpolation
const std = @import("std");
const syntax = @import("root.zig");

const TokenKind = syntax.TokenKind;
const Output = syntax.Output;

/// A kind of string literal.
pub const LexString = struct {
    open: []const u8,
    close: []const u8,
    /// Starts escape sequences; 0 for raw strings.
    escape: u8 = 0,
    /// The string continues past the end of a line.
    multiline: bool = false,
    /// Enclose code inside the string, as `${` and `}`.
    interp_open: []const u8 = "",
    interp_close: []const u8 = "",
    /// An identifier that must come right before `open`, as `f` before a
    /// formatted string.
    prefix: []const u8 = "",
    /// `$name` inside the string is a variable, as shells mark them.
    dollar: bool = false,
    kind: TokenKind = .string,
};

/// A sorted keyword table built at compile time by `words`.
pub const Words = struct {
    pub const Entry = struct { word: []const u8, kind: TokenKind };
    entries: []const Entry = &.{},

    pub fn get(self: Words, word: []const u8) ?TokenKind {
        var low: usize = 0;
        var high = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.entries[middle].word, word)) {
                .eq => return self.entries[middle].kind,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }
};

/// Make a keyword table: each string lists space-separated words of the
/// kind before it, as `.{ .keyword, "if else", .type, "int" }`. A word
/// listed again takes its last kind.
pub fn words(comptime spec: anytype) Words {
    @setEvalBranchQuota(1_000_000);
    const entries = comptime blk: {
        var count: usize = 0;
        for (spec) |item| {
            if (@TypeOf(item) == TokenKind or @TypeOf(item) == @TypeOf(.enum_literal)) continue;
            var it = std.mem.tokenizeScalar(u8, item, ' ');
            while (it.next()) |_| count += 1;
        }
        var list: [count]Words.Entry = undefined;
        var len: usize = 0;
        var kind: TokenKind = .text;
        for (spec) |item| {
            if (@TypeOf(item) == TokenKind or @TypeOf(item) == @TypeOf(.enum_literal)) {
                kind = item;
                continue;
            }
            var it = std.mem.tokenizeScalar(u8, item, ' ');
            outer: while (it.next()) |word| {
                for (list[0..len]) |*entry| if (std.mem.eql(u8, entry.word, word)) {
                    entry.kind = kind;
                    continue :outer;
                };
                list[len] = .{ .word = word, .kind = kind };
                len += 1;
            }
        }
        const sorted = list[0..len];
        std.mem.sort(Words.Entry, sorted, {}, struct {
            fn less(_: void, a: Words.Entry, b: Words.Entry) bool {
                return std.mem.order(u8, a.word, b.word) == .lt;
            }
        }.less);
        var final: [len]Words.Entry = undefined;
        @memcpy(&final, sorted);
        break :blk final;
    };
    return .{ .entries = &entries };
}

pub const Lexer = struct {
    line_comments: []const []const u8 = &.{},
    block_comments: []const [2][]const u8 = &.{},
    nest_comments: bool = false,
    strings: []const LexString = &.{},
    words: Words = .{},
    /// Keywords are looked up in lower case, as SQL's.
    fold_case: bool = false,
    /// Characters other than letters, digits and _ in identifiers, as $.
    ident_chars: []const u8 = "",
    /// Capitalized identifiers are types.
    capital_types: bool = false,
    /// Identifiers before ( are functions.
    calls: bool = false,
    /// Identifiers and strings before : are properties, as JSON keys.
    keys: bool = false,
    /// Starts annotations, as @ in Java and Python; 0 for none.
    decorator: u8 = 0,
    /// # at the start of a line is a preprocessor line.
    directives: bool = false,
    /// /.../ where an expression may start is a regular expression.
    regexps: bool = false,
    /// $name is a variable, as in shells and PHP.
    variables: bool = false,
    operators: []const u8 = "",

    pub fn tokenizer(self: *const Lexer) syntax.Tokenizer {
        return .{ .context = self, .call = call };
    }
    fn call(context: *const anyopaque, line: []const u8, state: u64, out: *Output) u64 {
        const self: *const Lexer = @ptrCast(@alignCast(context));
        return self.tokenize(line, state, out);
    }

    pub fn tokenize(self: *const Lexer, line: []const u8, state: u64, out: *Output) u64 {
        var st: State = .{ .line = line, .out = out, .mode = @intCast(state & 0xff), .depth = @intCast(state >> 8 & 0xff), .stack = state >> 16 & 0xffffff, .regex_ok = true };
        var i: usize = 0;
        while (i < line.len) {
            if (st.mode >= mode_string) {
                i = self.inString(&st, i);
            } else if (st.mode >= mode_comment) {
                i = self.inComment(&st, i);
            } else {
                i = self.code(&st, i);
            }
        }
        if (st.mode >= mode_string and !self.strings[st.mode - mode_string].multiline) {
            st.mode = 0;
            st.stack = 0;
        }
        return @as(u64, st.mode) | @as(u64, st.depth & 0xff) << 8 | st.stack << 16;
    }

    fn inComment(self: *const Lexer, st: *State, i: usize) usize {
        const pair = self.block_comments[st.mode - mode_comment];
        const line = st.line;
        var j = i;
        while (j < line.len) {
            if (self.nest_comments and std.mem.startsWith(u8, line[j..], pair[0])) {
                st.depth += 1;
                j += pair[0].len;
                continue;
            }
            if (std.mem.startsWith(u8, line[j..], pair[1])) {
                j += pair[1].len;
                if (st.depth > 0) {
                    st.depth -= 1;
                    continue;
                }
                st.mode = 0;
                break;
            }
            j += 1;
        }
        st.out.add(j, .comment);
        return j;
    }

    /// A string's contents from i to its end, the end of the line, or an
    /// interpolation, which it enters.
    fn inString(self: *const Lexer, st: *State, i: usize) usize {
        const k = st.mode - mode_string;
        const s = &self.strings[k];
        const line = st.line;
        const n = line.len;
        var j = i;
        while (j < n) {
            const c = line[j];
            if (s.escape != 0 and c == s.escape) {
                st.out.add(j, s.kind);
                var e = @min(n, j + 2);
                if (j + 1 < n and line[j + 1] >= 0x80) e = @min(n, j + 1 + sequenceLength(line[j + 1]));
                st.out.add(e, .escape);
                j = e;
                continue;
            }
            if (std.mem.startsWith(u8, line[j..], s.close)) {
                st.out.add(j + s.close.len, s.kind);
                st.mode = 0;
                st.regex_ok = false;
                return j + s.close.len;
            }
            if (s.interp_open.len != 0 and std.mem.startsWith(u8, line[j..], s.interp_open)) {
                st.out.add(j, s.kind);
                const e = j + s.interp_open.len;
                st.out.add(e, .escape);
                if (st.stack >> 16 == 0) {
                    st.stack = st.stack << 8 | @as(u64, k + 1) << 3;
                    st.mode = 0;
                    st.regex_ok = true;
                    return e;
                }
                j = e;
                continue;
            }
            if (s.dollar and c == '$' and j + 1 < n and (isIdentByte(line[j + 1]) or line[j + 1] == '{')) {
                st.out.add(j, s.kind);
                const e = dollarEnd(line, j);
                st.out.add(e, .variable);
                j = e;
                continue;
            }
            j += 1;
        }
        st.out.add(n, s.kind);
        return n;
    }

    /// One token of code from i; returns where it ends.
    fn code(self: *const Lexer, st: *State, i: usize) usize {
        const line = st.line;
        const n = line.len;
        const c = line[i];
        const out = st.out;
        if (c == ' ' or c == '\t' or c == '\r' or c == 0x0c) {
            var j = i + 1;
            while (j < n and (line[j] == ' ' or line[j] == '\t' or line[j] == '\r' or line[j] == 0x0c)) j += 1;
            out.add(j, .text);
            return j;
        }
        // An interpolation's braces, and its end returning into its string.
        if (st.stack != 0) {
            const top = st.stack & 0xff;
            const index: usize = @intCast(top >> 3);
            if (index >= 1 and index <= self.strings.len) {
                const s = &self.strings[index - 1];
                const braces = top & 7;
                if (c == '{' and std.mem.eql(u8, s.interp_close, "}")) {
                    if (braces < 7) st.stack += 1;
                    out.add(i + 1, .punctuation);
                    return i + 1;
                }
                if ((braces == 0 or !std.mem.eql(u8, s.interp_close, "}")) and s.interp_close.len != 0 and std.mem.startsWith(u8, line[i..], s.interp_close)) {
                    st.stack >>= 8;
                    st.mode = mode_string + index - 1;
                    out.add(i + s.interp_close.len, .escape);
                    return i + s.interp_close.len;
                }
                if (c == '}' and braces > 0) {
                    st.stack -= 1;
                    out.add(i + 1, .punctuation);
                    return i + 1;
                }
            }
        }
        // Block comments first: one may start with a line comment's opener.
        for (self.block_comments, 0..) |pair, k| {
            if (std.mem.startsWith(u8, line[i..], pair[0])) {
                st.mode = mode_comment + k;
                st.depth = 0;
                out.add(i + pair[0].len, .comment);
                return i + pair[0].len;
            }
        }
        for (self.line_comments) |prefix| {
            if (std.mem.startsWith(u8, line[i..], prefix)) {
                out.add(n, .comment);
                return n;
            }
        }
        if (self.stringStart(st, i, "")) |j| return j;
        if (self.directives and c == '#' and std.mem.trimStart(u8, line[0..i], " \t").len == 0) {
            var j = i + 1;
            while (j < n and (line[j] == ' ' or line[j] == '\t')) j += 1;
            while (j < n and isIdentByte(line[j])) j += 1;
            out.add(j, .meta);
            return j;
        }
        if (self.decorator != 0 and c == self.decorator and i + 1 < n and identStart(line[i + 1 ..], self.ident_chars)) {
            var j = i + 1;
            while (j < n and (identPart(line[j..], self.ident_chars) or line[j] == '.')) j += sequenceLength(line[j]);
            out.add(@min(j, n), .meta);
            return @min(j, n);
        }
        if (self.variables and c == '$' and i + 1 < n) {
            const j = dollarEnd(line, i);
            if (j > i + 1) {
                out.add(j, .variable);
                st.prev_dot = false;
                st.regex_ok = false;
                return j;
            }
        }
        // Numbers.
        if (isDigit(c) or (c == '.' and i + 1 < n and isDigit(line[i + 1]) and !st.prev_dot)) {
            const hex = c == '0' and i + 1 < n and (line[i + 1] == 'x' or line[i + 1] == 'X');
            var j = i + 1;
            while (j < n) {
                const e = line[j];
                if (isDigit(e) or (e >= 'a' and e <= 'z') or (e >= 'A' and e <= 'Z') or e == '_') {
                    j += 1;
                    continue;
                }
                if (e == '.' and j + 1 < n and isDigit(line[j + 1])) {
                    j += 1;
                    continue;
                }
                if (e == '+' or e == '-') {
                    const before = line[j - 1];
                    if ((!hex and (before == 'e' or before == 'E')) or (hex and (before == 'p' or before == 'P'))) {
                        j += 1;
                        continue;
                    }
                }
                break;
            }
            out.add(j, .number);
            st.prev_dot = false;
            st.regex_ok = false;
            return j;
        }
        if (identStart(line[i..], self.ident_chars)) {
            var j = i;
            while (j < n and identPart(line[j..], self.ident_chars)) j += sequenceLength(line[j]);
            j = @min(j, n);
            const word = line[i..j];
            // A string's prefix, as f"…" or b"…".
            if (j < n and self.hasPrefixes()) {
                if (self.stringStart(st, j, word)) |k| return k;
            }
            var kind: TokenKind = .variable;
            var folded: [64]u8 = undefined;
            const lookup = if (self.fold_case and word.len <= folded.len) std.ascii.lowerString(&folded, word) else word;
            if (self.words.get(lookup)) |found| {
                if (!st.prev_dot) kind = found else kind = classify(self, st, line, j, word);
            } else kind = classify(self, st, line, j, word);
            out.add(j, kind);
            st.prev_dot = false;
            st.regex_ok = kind == .keyword;
            return j;
        }
        if (self.regexps and c == '/' and st.regex_ok and i + 1 < n and line[i + 1] != '/' and line[i + 1] != '*') {
            var j = i + 1;
            var class = false;
            while (j < n) {
                const e = line[j];
                if (e == '\\') {
                    j += 2;
                    continue;
                }
                if (e == '[') {
                    class = true;
                } else if (e == ']') {
                    class = false;
                } else if (e == '/' and !class) break;
                j += 1;
            }
            if (j < n) {
                j += 1;
                while (j < n and line[j] >= 'a' and line[j] <= 'z') j += 1;
                out.add(j, .regexp);
                st.regex_ok = false;
                return j;
            }
        }
        if (std.mem.indexOfScalar(u8, "()[]{},;", c) != null) {
            out.add(i + 1, .punctuation);
            st.prev_dot = false;
            st.regex_ok = c != ')' and c != ']' and c != '}';
            return i + 1;
        }
        if (c == '.') {
            out.add(i + 1, .punctuation);
            st.prev_dot = true;
            st.regex_ok = false;
            return i + 1;
        }
        if (std.mem.indexOfScalar(u8, self.operators, c) != null) {
            var j = i + 1;
            while (j < n and std.mem.indexOfScalar(u8, self.operators, line[j]) != null and !self.startsComment(line[j..])) j += 1;
            out.add(j, .operator);
            st.prev_dot = false;
            st.regex_ok = true;
            return j;
        }
        const j = @min(n, i + sequenceLength(c));
        out.add(j, .text);
        st.prev_dot = false;
        return j;
    }

    /// The kind of an identifier that is no keyword here, by what follows.
    fn classify(self: *const Lexer, st: *const State, line: []const u8, j: usize, word: []const u8) TokenKind {
        const n = line.len;
        var k = j;
        while (k < n and (line[k] == ' ' or line[k] == '\t')) k += 1;
        const next: u8 = if (k < n) line[k] else 0;
        if (self.keys and next == ':' and (k + 1 >= n or line[k + 1] != ':')) return .property;
        if (self.calls and (next == '(' or (next == '!' and k + 1 < n and line[k + 1] == '('))) return .function;
        if (st.prev_dot) return .property;
        if (self.capital_types and isUpper(word)) return .type;
        return .variable;
    }

    fn hasPrefixes(self: *const Lexer) bool {
        for (self.strings) |s| if (s.prefix.len != 0) return true;
        return false;
    }

    pub fn startsComment(self: *const Lexer, s: []const u8) bool {
        for (self.line_comments) |prefix| if (std.mem.startsWith(u8, s, prefix)) return true;
        for (self.block_comments) |pair| if (std.mem.startsWith(u8, s, pair[0])) return true;
        return false;
    }

    /// Starts a string at i after `prefix`, which it colors as the string.
    fn stringStart(self: *const Lexer, st: *State, i: usize, prefix: []const u8) ?usize {
        for (self.strings, 0..) |*s, k| {
            if (!std.mem.eql(u8, s.prefix, prefix) or !std.mem.startsWith(u8, st.line[i..], s.open)) continue;
            const e = i + s.open.len;
            st.out.add(e, s.kind);
            st.mode = mode_string + k;
            st.prev_dot = false;
            return e;
        }
        return null;
    }
};

pub const mode_comment = 1;
pub const mode_string = 32;

const State = struct {
    line: []const u8,
    out: *Output,
    mode: usize,
    depth: usize,
    stack: u64,
    /// The last token was a dot.
    prev_dot: bool = false,
    /// An expression may start.
    regex_ok: bool,
};

/// Where a $name, ${name} or $1 at i ends.
pub fn dollarEnd(line: []const u8, i: usize) usize {
    const n = line.len;
    var j = i + 1;
    if (j < n and line[j] == '{') {
        while (j < n and line[j] != '}') j += 1;
        return @min(n, j + 1);
    }
    if (j < n and std.mem.indexOfScalar(u8, "@*#?$!-0123456789", line[j]) != null) return j + 1;
    while (j < n and isIdentByte(line[j])) j += 1;
    return j;
}

pub fn isIdentByte(c: u8) bool {
    return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Bytes of the UTF-8 sequence a lead byte starts; 1 for invalid bytes.
pub fn sequenceLength(c: u8) usize {
    return std.unicode.utf8ByteSequenceLength(c) catch 1;
}

/// The scalar at the start of s, or null for an invalid sequence.
pub fn decode(s: []const u8) ?u21 {
    const length = std.unicode.utf8ByteSequenceLength(s[0]) catch return null;
    if (length > s.len) return null;
    return std.unicode.utf8Decode(s[0..length]) catch null;
}

/// Whether a scalar outside ASCII is a letter. Without Unicode tables this
/// excludes the punctuation, symbol, space, mark, emoji and private ranges,
/// so scripts' letters and ideographs count.
pub fn isLetter(c: u21) bool {
    if (c < 0x80) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    if (c < 0xc0) return c == 0xaa or c == 0xb5 or c == 0xba;
    if (c == 0xd7 or c == 0xf7) return false;
    if (isMark(c)) return false;
    return !((c >= 0x2000 and c <= 0x2bff) or (c >= 0x3000 and c <= 0x303f) or (c >= 0xe000 and c <= 0xf8ff) or
        (c >= 0xfe30 and c <= 0xfe4f) or (c >= 0xff00 and c <= 0xff20) or (c >= 0xff3b and c <= 0xff40) or
        (c >= 0xff5b and c <= 0xff65) or (c >= 0x1f000 and c <= 0x1faff) or c == 0xfeff);
}
/// Nonspacing combining marks of the common blocks.
pub fn isMark(c: u21) bool {
    return (c >= 0x300 and c <= 0x36f) or (c >= 0x483 and c <= 0x489) or (c >= 0x591 and c <= 0x5bd) or
        (c >= 0x610 and c <= 0x61a) or (c >= 0x64b and c <= 0x65f) or (c >= 0x1ab0 and c <= 0x1aff) or
        (c >= 0x1dc0 and c <= 0x1dff) or (c >= 0x20d0 and c <= 0x20ff) or (c >= 0xfe20 and c <= 0xfe2f);
}

pub fn identStart(s: []const u8, extra: []const u8) bool {
    const c = s[0];
    if (c < 0x80) {
        // - and . continue identifiers but start none.
        return c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c != '-' and c != '.' and std.mem.indexOfScalar(u8, extra, c) != null);
    }
    const scalar = decode(s) orelse return false;
    return isLetter(scalar);
}

pub fn identPart(s: []const u8, extra: []const u8) bool {
    const c = s[0];
    if (c < 0x80) return isIdentByte(c) or std.mem.indexOfScalar(u8, extra, c) != null;
    const scalar = decode(s) orelse return false;
    return isLetter(scalar) or isMark(scalar);
}

fn isUpper(word: []const u8) bool {
    if (word.len == 0) return false;
    const c = word[0];
    if (c < 0x80) return c >= 'A' and c <= 'Z';
    const scalar = decode(word) orelse return false;
    // Latin-1, Latin Extended-A pairs, Greek and Cyrillic capitals.
    return (scalar >= 0xc0 and scalar <= 0xde and scalar != 0xd7) or
        (scalar >= 0x100 and scalar <= 0x17f and scalar % 2 == 0) or
        (scalar >= 0x391 and scalar <= 0x3a9) or (scalar >= 0x400 and scalar <= 0x42f);
}
