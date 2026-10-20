//! Line-at-a-time syntax highlighting for code editors: token kinds, a
//! configurable lexer that covers most programming languages, dedicated
//! lexers for JSON, TOML, CSS, markup, Markdown and diffs, a table of known
//! languages, light and dark token themes, an incremental highlighter that
//! keeps the state each line starts in, bracket matching that skips strings
//! and comments, and the word searches multi-caret commands use.
//!
//! Everything here is pure Zig without native calls. Tokenizing writes into
//! caller buffers and never allocates; the incremental highlighter owns its
//! line states through an explicit allocator.
const std = @import("std");

pub const lexer = @import("lexer.zig");
pub const lexers = @import("lexers.zig");
pub const languages = @import("languages.zig");
pub const theme = @import("theme.zig");
pub const highlighter = @import("highlighter.zig");
pub const brackets = @import("brackets.zig");
pub const search = @import("search.zig");

pub const Lexer = lexer.Lexer;
pub const LexString = lexer.LexString;
pub const Language = languages.Language;
pub const BracketPair = languages.BracketPair;
pub const Theme = theme.Theme;
pub const TokenStyle = theme.TokenStyle;
pub const Highlighter = highlighter.Highlighter;
pub const SourceLine = highlighter.SourceLine;
pub const forFile = languages.forFile;
pub const named = languages.named;

/// What a token of code is, which a theme colors.
pub const TokenKind = enum(u8) {
    text,
    keyword,
    type,
    function,
    variable,
    property,
    constant,
    number,
    string,
    /// Escapes and interpolations in strings.
    escape,
    regexp,
    comment,
    operator,
    punctuation,
    /// HTML and XML elements.
    tag,
    /// Their attributes.
    attribute,
    /// Preprocessor lines, decorators, annotations.
    meta,
    heading,
    emphasis,
    strong,
    link,
    /// Code in prose, as Markdown's.
    code,
    inserted,
    deleted,
    invalid,
};
pub const token_kinds = @typeInfo(TokenKind).@"enum".fields.len;

/// A run of a line of one kind, from the end of the token before it, or the
/// start of the line, to `end`, a byte offset in the line.
pub const Token = struct { end: u32, kind: TokenKind };

/// Longer lines are left plain: their tokens are one text run and the state
/// passes through them unchanged.
pub const max_line = 10000;

/// A caller buffer that tokenizers append to. Adjacent tokens of one kind
/// merge. When the buffer is full the last token grows to cover the rest
/// of the line, so a short buffer degrades coloring, never correctness of
/// the byte coverage.
pub const Output = struct {
    buffer: []Token,
    len: usize = 0,
    /// Tokens before this index belong to an earlier line or caller and are
    /// never merged into or rewritten.
    base: usize = 0,

    pub fn init(buffer: []Token) Output {
        return .{ .buffer = buffer };
    }
    pub fn items(self: *const Output) []Token {
        return self.buffer[self.base..self.len];
    }
    /// The end of the last token, or 0.
    pub fn last(self: *const Output) usize {
        return if (self.len > self.base) self.buffer[self.len - 1].end else 0;
    }
    pub fn add(self: *Output, end: usize, kind: TokenKind) void {
        const value: u32 = @intCast(@min(end, std.math.maxInt(u32)));
        if (self.len > self.base) {
            const previous = &self.buffer[self.len - 1];
            if (previous.end >= value) return;
            if (previous.kind == kind or self.len == self.buffer.len) {
                previous.end = value;
                return;
            }
        } else if (self.buffer.len == 0) return;
        self.buffer[self.len] = .{ .end = value, .kind = kind };
        self.len += 1;
    }
};

/// Splits lines into tokens. `tokenize` appends the tokens of `line`, which
/// has no line break, starting in `state`, and returns the state the line
/// ends in, which the next line starts in: 0 at the start of the text, and
/// equal states for lines that continue alike, as inside a comment.
pub const Tokenizer = struct {
    context: *const anyopaque,
    call: *const fn (*const anyopaque, []const u8, u64, *Output) u64,

    pub fn tokenize(self: Tokenizer, line: []const u8, state: u64, out: *Output) u64 {
        if (line.len > max_line) {
            out.add(line.len, .text);
            return state;
        }
        return self.call(self.context, line, state, out);
    }
};

/// Tokenize one line into `buffer`, which also receives a trailing text run
/// for bytes a tokenizer left uncovered, so the tokens always reach the end
/// of the line.
pub fn tokenizeLine(tokenizer: Tokenizer, line: []const u8, state: u64, buffer: []Token) struct { tokens: []Token, state: u64 } {
    var out = Output.init(buffer);
    const next = tokenizer.tokenize(line, state, &out);
    if (out.last() < line.len) out.add(line.len, .text);
    return .{ .tokens = out.items(), .state = next };
}

/// The kind of the token holding byte `at` of a line, or text past them.
pub fn kindAt(tokens: []const Token, at: usize) TokenKind {
    for (tokens) |token| if (at < token.end) return token.kind;
    return .text;
}

test {
    _ = lexer;
    _ = lexers;
    _ = languages;
    _ = theme;
    _ = highlighter;
    _ = brackets;
    _ = search;
    _ = @import("tests.zig");
}
