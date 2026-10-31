//! Tokenizers for languages the general lexer does not fit: JSON's keys,
//! TOML's tables, CSS, markup with the scripts and styles inside it,
//! Markdown with the code of its fenced blocks, and diffs.
const std = @import("std");
const syntax = @import("root.zig");
const lex = @import("lexer.zig");
const languages = @import("languages.zig");

const TokenKind = syntax.TokenKind;
const Token = syntax.Token;
const Output = syntax.Output;
const Tokenizer = syntax.Tokenizer;
const isIdentByte = lex.isIdentByte;

/// Give the tokens of the current line covering start..end kind k,
/// splitting those that reach past them. When the buffer has no room for a
/// split the neighbouring token keeps its kind over the gap.
pub fn relabel(out: *Output, start: usize, end: usize, kind: TokenKind) void {
    if (start >= end) return;
    const tokens = out.buffer[out.base..out.len];
    var first: usize = 0;
    while (first < tokens.len and tokens[first].end <= start) first += 1;
    if (first == tokens.len) return;
    var last = first;
    while (last + 1 < tokens.len and tokens[last].end < end) last += 1;
    const first_start: usize = if (first == 0) 0 else tokens[first - 1].end;
    const head = first_start < start;
    const tail = tokens[last].end > end;
    var replacement: [3]Token = undefined;
    var count: usize = 0;
    if (head) {
        replacement[count] = .{ .end = @intCast(start), .kind = tokens[first].kind };
        count += 1;
    }
    replacement[count] = .{ .end = @intCast(@min(end, tokens[last].end)), .kind = kind };
    count += 1;
    if (tail) {
        replacement[count] = tokens[last];
        count += 1;
    }
    const removed = last - first + 1;
    const after = out.len - (out.base + last + 1);
    if (out.len - removed + count > out.buffer.len) {
        // No room to split: color the whole affected run.
        tokens[last].kind = kind;
        for (tokens[first..last]) |*token| token.kind = kind;
        merge(out);
        return;
    }
    const at = out.base + first;
    const tail_from = out.base + last + 1;
    if (count > removed) {
        std.mem.copyBackwards(Token, out.buffer[at + count .. at + count + after], out.buffer[tail_from .. tail_from + after]);
    } else if (count < removed) {
        std.mem.copyForwards(Token, out.buffer[at + count .. at + count + after], out.buffer[tail_from .. tail_from + after]);
    }
    @memcpy(out.buffer[at .. at + count], replacement[0..count]);
    out.len = out.len - removed + count;
    merge(out);
}

/// Join adjacent tokens of one kind.
fn merge(out: *Output) void {
    if (out.len <= out.base + 1) return;
    var write = out.base;
    for (out.buffer[out.base + 1 .. out.len]) |token| {
        if (out.buffer[write].kind == token.kind) {
            out.buffer[write].end = token.end;
        } else {
            write += 1;
            out.buffer[write] = token;
        }
    }
    out.len = write + 1;
}

/// JSON: strings before colons are keys.
pub const Json = struct {
    lexer: lex.Lexer,

    pub fn tokenizer(self: *const Json) Tokenizer {
        return .{ .context = self, .call = call };
    }
    fn call(context: *const anyopaque, line: []const u8, state: u64, out: *Output) u64 {
        const self: *const Json = @ptrCast(@alignCast(context));
        const base = out.base;
        out.base = out.len;
        defer out.base = base;
        const next = self.lexer.tokenize(line, state, out);
        var i: usize = 0;
        var from: usize = 0;
        while (i < out.len - out.base) {
            const toks = out.buffer[out.base..out.len];
            if (toks[i].kind != .string) {
                from = toks[i].end;
                i += 1;
                continue;
            }
            // A string with its escapes.
            const start = from;
            var k = i;
            while (k + 1 < toks.len and (toks[k + 1].kind == .string or toks[k + 1].kind == .escape)) k += 1;
            const end: usize = toks[k].end;
            var p = end;
            while (p < line.len and (line[p] == ' ' or line[p] == '\t')) p += 1;
            if (p < line.len and line[p] == ':') {
                relabel(out, start, end, .property);
                // Continue after the relabeled run.
                const after = out.buffer[out.base..out.len];
                i = 0;
                while (i < after.len and after[i].end < end) i += 1;
                if (i < after.len) i += 1;
            } else i = k + 1;
            from = end;
        }
        return next;
    }
};

/// TOML: tables are types and keys properties.
pub const Toml = struct {
    lexer: lex.Lexer,

    pub fn tokenizer(self: *const Toml) Tokenizer {
        return .{ .context = self, .call = call };
    }
    fn call(context: *const anyopaque, line: []const u8, state: u64, out: *Output) u64 {
        const self: *const Toml = @ptrCast(@alignCast(context));
        const base = out.base;
        out.base = out.len;
        defer out.base = base;
        const next = self.lexer.tokenize(line, state, out);
        if (state != 0) return next;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const start = line.len - trimmed.len;
        if (std.mem.startsWith(u8, trimmed, "[")) {
            if (std.mem.lastIndexOfScalar(u8, line, ']')) |end| {
                if (end > start) relabel(out, start, end + 1, .type);
            }
        } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (eq > start and std.mem.indexOfAny(u8, line[start..eq], "\"'#") == null) {
                const key = std.mem.trimEnd(u8, line[start..eq], " \t");
                relabel(out, start, start + key.len, .property);
            }
        }
        return next;
    }
};

/// CSS, SCSS and Less: selectors, at-rules, properties and their values.
/// The state packs the mode (bits 0-3: 1 a comment) and how many blocks the
/// line starts in (bits 8-15).
pub const css = Tokenizer{ .context = &css_marker, .call = cssTokenize };
const css_marker: u8 = 0;

fn cssTokenize(_: *const anyopaque, line: []const u8, state: u64, out: *Output) u64 {
    var mode: u64 = state & 0xf;
    var depth: u64 = state >> 8 & 0xff;
    const n = line.len;
    // After a property's colon, until ; or }.
    var value = false;
    var i: usize = 0;
    while (i < n) {
        const c = line[i];
        if (mode == 1) {
            if (std.mem.indexOf(u8, line[i..], "*/")) |end| {
                out.add(i + end + 2, .comment);
                i += end + 2;
                mode = 0;
            } else {
                out.add(n, .comment);
                i = n;
            }
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            out.add(i + 1, .text);
            i += 1;
        } else if (std.mem.startsWith(u8, line[i..], "/*")) {
            mode = 1;
            out.add(i + 2, .comment);
            i += 2;
        } else if (std.mem.startsWith(u8, line[i..], "//") and (i == 0 or line[i - 1] != ':')) {
            out.add(n, .comment);
            i = n;
        } else if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < n and line[j] != c) {
                if (line[j] == '\\') j += 1;
                j += 1;
            }
            out.add(@min(n, j + 1), .string);
            i = @min(n, j + 1);
        } else if (c == '{') {
            depth = @min(depth + 1, 255);
            value = false;
            out.add(i + 1, .punctuation);
            i += 1;
        } else if (c == '}') {
            depth -|= 1;
            value = false;
            out.add(i + 1, .punctuation);
            i += 1;
        } else if (c == ';') {
            value = false;
            out.add(i + 1, .punctuation);
            i += 1;
        } else if (c == '@') {
            var j = i + 1;
            while (j < n and (isIdentByte(line[j]) or line[j] == '-')) j += 1;
            out.add(j, .keyword);
            i = j;
        } else if (c == '$' and i + 1 < n and (isIdentByte(line[i + 1]) or line[i + 1] == '-')) {
            var j = i + 1;
            while (j < n and (isIdentByte(line[j]) or line[j] == '-')) j += 1;
            out.add(j, .variable);
            i = j;
        } else if (c == '#' and value) {
            var j = i + 1;
            while (j < n and isIdentByte(line[j])) j += 1;
            out.add(j, .number);
            i = j;
        } else if ((c >= '0' and c <= '9') or ((c == '.' or c == '-' or c == '+') and i + 1 < n and line[i + 1] >= '0' and line[i + 1] <= '9' and value)) {
            var j = i + 1;
            while (j < n and ((line[j] >= '0' and line[j] <= '9') or line[j] == '.')) j += 1;
            // The unit.
            while (j < n and ((line[j] >= 'a' and line[j] <= 'z') or line[j] == '%')) j += 1;
            out.add(j, .number);
            i = j;
        } else if (isIdentByte(c) or c == '-' or c >= 0x80) {
            var j = i;
            while (j < n and (isIdentByte(line[j]) or line[j] == '-' or line[j] >= 0x80)) j += 1;
            var k = j;
            while (k < n and (line[k] == ' ' or line[k] == '\t')) k += 1;
            var kind: TokenKind = .tag;
            if (value and k < n and line[k] == '(') {
                kind = .function;
            } else if (value) {
                kind = .constant;
                if (std.mem.startsWith(u8, line[i..], "--")) kind = .variable;
            } else if (depth > 0 and k < n and line[k] == ':' and !cssSelectorAhead(line[k..])) {
                kind = .property;
            } else if (std.mem.startsWith(u8, line[i..], "--")) kind = .variable;
            out.add(j, kind);
            i = j;
        } else if (c == ':' and !value and depth > 0 and !cssSelectorAhead(line[i..])) {
            value = true;
            out.add(i + 1, .punctuation);
            i += 1;
        } else if (c == ':') {
            // A pseudo-class or element.
            var j = i + 1;
            while (j < n and (line[j] == ':' or isIdentByte(line[j]) or line[j] == '-')) j += 1;
            out.add(j, .keyword);
            i = j;
        } else if ((c == '.' or c == '#') and !value and i + 1 < n and (isIdentByte(line[i + 1]) or line[i + 1] == '-')) {
            var j = i + 1;
            while (j < n and (isIdentByte(line[j]) or line[j] == '-')) j += 1;
            out.add(j, .type);
            i = j;
        } else if (c == '!' and std.mem.startsWith(u8, line[i..], "!important")) {
            out.add(i + 10, .keyword);
            i += 10;
        } else {
            out.add(i + 1, if (std.mem.indexOfScalar(u8, "(),[]", c) != null) .punctuation else .operator);
            i += 1;
        }
    }
    return mode | depth << 8;
}

/// What follows a colon is a selector continuing to a block, as
/// `a:hover {`, rather than a value.
fn cssSelectorAhead(s: []const u8) bool {
    const brace = std.mem.indexOfScalar(u8, s, '{') orelse return false;
    const semi = std.mem.indexOfScalar(u8, s, ';') orelse return true;
    return brace < semi;
}

/// HTML and XML: tags, attributes, comments, entities and, in HTML, the
/// scripts and styles inside it with their own tokenizers. The state packs
/// the mode (bits 0-3), what the tag being lexed opens (bits 4-5: 1 a
/// script, 2 a style), and the state of the script or style (bits 16-55).
pub const Markup = struct {
    html: bool = false,
    script: ?Tokenizer = null,
    style: ?Tokenizer = null,

    pub fn tokenizer(self: *const Markup) Tokenizer {
        return .{ .context = self, .call = call };
    }
    fn call(context: *const anyopaque, line: []const u8, state: u64, out: *Output) u64 {
        const self: *const Markup = @ptrCast(@alignCast(context));
        return self.tokenize(line, state, out);
    }

    const ml_text = 0;
    const ml_tag = 1;
    const ml_comment = 2;
    const ml_double = 3;
    const ml_single = 4;
    const ml_cdata = 5;
    const ml_script = 6;
    const ml_style = 7;

    pub fn tokenize(self: *const Markup, line: []const u8, state: u64, out: *Output) u64 {
        var mode: u64 = state & 0xf;
        var embed: u64 = state >> 4 & 3;
        var inner: u64 = state >> 16;
        const n = line.len;
        var i: usize = 0;
        while (i < n) {
            switch (mode) {
                ml_script, ml_style => {
                    const tag: []const u8 = if (mode == ml_style) "</style" else "</script";
                    const tokenizer_value = if (mode == ml_style) self.style else self.script;
                    const end = indexFold(line[i..], tag);
                    const stop = if (end) |value| i + value else n;
                    if (tokenizer_value) |inner_tokenizer| if (stop > i) {
                        var scratch: [256]Token = undefined;
                        var sub = Output.init(&scratch);
                        inner = inner_tokenizer.tokenize(line[i..stop], inner, &sub) & 0xffffffffff;
                        for (sub.items()) |token| out.add(i + token.end, token.kind);
                    };
                    out.add(stop, .text);
                    i = stop;
                    if (end != null) {
                        mode = ml_text;
                        inner = 0;
                    }
                },
                ml_comment => {
                    if (std.mem.indexOf(u8, line[i..], "-->")) |end| {
                        out.add(i + end + 3, .comment);
                        i += end + 3;
                        mode = ml_text;
                    } else {
                        out.add(n, .comment);
                        i = n;
                    }
                },
                ml_cdata => {
                    if (std.mem.indexOf(u8, line[i..], "]]>")) |end| {
                        out.add(i + end + 3, .string);
                        i += end + 3;
                        mode = ml_text;
                    } else {
                        out.add(n, .string);
                        i = n;
                    }
                },
                ml_double, ml_single => {
                    const quote: u8 = if (mode == ml_single) '\'' else '"';
                    if (std.mem.indexOfScalar(u8, line[i..], quote)) |end| {
                        out.add(i + end + 1, .string);
                        i += end + 1;
                        mode = ml_tag;
                    } else {
                        out.add(n, .string);
                        i = n;
                    }
                },
                ml_tag => {
                    const c = line[i];
                    if (c == '>') {
                        out.add(i + 1, .punctuation);
                        i += 1;
                        mode = switch (embed) {
                            1 => ml_script,
                            2 => ml_style,
                            else => ml_text,
                        };
                        embed = 0;
                    } else if (c == '/' and i + 1 < n and line[i + 1] == '>') {
                        out.add(i + 2, .punctuation);
                        i += 2;
                        mode = ml_text;
                        embed = 0;
                    } else if (c == '"') {
                        out.add(i + 1, .string);
                        i += 1;
                        mode = ml_double;
                    } else if (c == '\'') {
                        out.add(i + 1, .string);
                        i += 1;
                        mode = ml_single;
                    } else if (c == '=') {
                        out.add(i + 1, .operator);
                        i += 1;
                    } else if (c == ' ' or c == '\t' or c == '\r') {
                        out.add(i + 1, .text);
                        i += 1;
                    } else {
                        var j = i;
                        while (j < n and std.mem.indexOfScalar(u8, " \t\r=>/\"'", line[j]) == null) j += 1;
                        if (j == i) j += 1;
                        out.add(j, .attribute);
                        i = j;
                    }
                },
                else => {
                    const c = line[i];
                    if (std.mem.startsWith(u8, line[i..], "<!--")) {
                        out.add(i + 4, .comment);
                        i += 4;
                        mode = ml_comment;
                    } else if (std.mem.startsWith(u8, line[i..], "<![CDATA[")) {
                        out.add(i + 9, .string);
                        i += 9;
                        mode = ml_cdata;
                    } else if (c == '<' and i + 1 < n and (line[i + 1] == '!' or line[i + 1] == '?')) {
                        var j = i + 2;
                        while (j < n and line[j] != '>' and line[j] != ' ') j += 1;
                        out.add(j, .meta);
                        i = j;
                        mode = ml_tag;
                    } else if (c == '<' and i + 1 < n and (line[i + 1] == '/' or lex.identStart(line[i + 1 ..], ""))) {
                        out.add(i + 1, .punctuation);
                        var j = i + 1;
                        if (line[j] == '/') {
                            out.add(j + 1, .punctuation);
                            j += 1;
                        }
                        var k = j;
                        while (k < n and (isIdentByte(line[k]) or line[k] == '-' or line[k] == ':' or line[k] == '.')) k += 1;
                        out.add(k, .tag);
                        embed = 0;
                        if (self.html and line[i + 1] != '/') {
                            if (std.ascii.eqlIgnoreCase(line[j..k], "script")) embed = 1;
                            if (std.ascii.eqlIgnoreCase(line[j..k], "style")) embed = 2;
                        }
                        i = k;
                        mode = ml_tag;
                    } else if (c == '&') {
                        var j = i + 1;
                        while (j < n and j - i < 32 and (isIdentByte(line[j]) or line[j] == '#')) j += 1;
                        if (j < n and line[j] == ';') {
                            out.add(j + 1, .escape);
                            i = j + 1;
                        } else {
                            out.add(i + 1, .text);
                            i += 1;
                        }
                    } else {
                        var j = i + 1;
                        while (j < n and line[j] != '<' and line[j] != '&') j += 1;
                        out.add(j, .text);
                        i = j;
                    }
                },
            }
        }
        return mode | embed << 4 | inner << 16;
    }
};

/// Where `needle`, in lower case, first is in s, ignoring ASCII case.
fn indexFold(s: []const u8, needle: []const u8) ?usize {
    if (s.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Markdown: headings, emphasis, code spans and blocks, links, lists and
/// quotes, and the code of fenced blocks in their language. The state packs
/// the fenced language's state (bits 0-39), an open fence (bit 40), its
/// fence character (bit 41 tildes) and length (bits 42-45), the block's
/// language (bits 46-53, its index in the language table plus one), and an
/// open HTML comment (bit 54).
pub const markdown = Tokenizer{ .context = &markdown_marker, .call = markdownTokenize };
const markdown_marker: u8 = 0;

const md_fence: u64 = 1 << 40;
const md_tilde: u64 = 1 << 41;
const md_comment: u64 = 1 << 54;
const md_inner: u64 = (1 << 40) - 1;

fn markdownTokenize(_: *const anyopaque, line: []const u8, start_state: u64, out: *Output) u64 {
    var state = start_state;
    const n = line.len;
    const trimmed = std.mem.trimStart(u8, line, " ");
    const indent = n - trimmed.len;
    if (state & md_comment != 0) {
        const end = std.mem.indexOf(u8, line, "-->") orelse {
            out.add(n, .comment);
            return state;
        };
        out.add(end + 3, .comment);
        state &= ~md_comment;
        _ = inline_(line, end + 3, out);
        return state;
    }
    if (state & md_fence != 0) {
        const ch: u8 = if (state & md_tilde != 0) '~' else '`';
        const length: usize = @intCast(state >> 42 & 0xf);
        var run: usize = 0;
        while (run < trimmed.len and trimmed[run] == ch) run += 1;
        if (indent < 4 and run >= length and std.mem.trim(u8, trimmed[run..], " \t\r").len == 0) {
            out.add(n, .punctuation);
            return 0;
        }
        const index: usize = @intCast(state >> 46 & 0xff);
        if (index > 0 and index <= languages.all.len) {
            if (languages.all[index - 1].tokenizer) |inner_tokenizer| {
                var inner = inner_tokenizer.tokenize(line, state & md_inner, out);
                if (inner > md_inner) inner = 0;
                out.add(n, .text);
                return (state & ~md_inner) | inner;
            }
        }
        out.add(n, .code);
        return state;
    }
    if (indent < 4 and (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~"))) {
        const ch = trimmed[0];
        var run: usize = 0;
        while (run < trimmed.len and trimmed[run] == ch) run += 1;
        const info = std.mem.trim(u8, trimmed[run..], " \t\r");
        if (ch == '`' and std.mem.indexOfScalar(u8, info, '`') != null) {
            _ = inline_(line, 0, out);
            return state;
        }
        out.add(indent + run, .punctuation);
        out.add(n, .type);
        var next: u64 = md_fence | @as(u64, @min(run, 15)) << 42;
        if (ch == '~') next |= md_tilde;
        var name = info;
        if (std.mem.indexOfAny(u8, name, " \t{")) |space| name = name[0..space];
        if (languages.named(name)) |language| {
            for (languages.all, 0..) |candidate, k| {
                if (candidate == language) next |= @as(u64, k + 1) << 46;
            }
        }
        return next;
    }
    if (indent < 4 and std.mem.startsWith(u8, trimmed, "#")) {
        var h: usize = 0;
        while (h < trimmed.len and trimmed[h] == '#') h += 1;
        if (h <= 6 and (h == trimmed.len or trimmed[h] == ' ' or trimmed[h] == '\t')) {
            out.add(n, .heading);
            return state;
        }
    } else if ((indent < 4 and trimmed.len > 0 and std.mem.trim(u8, trimmed, "=").len == 0) or
        (indent < 4 and trimmed.len > 1 and std.mem.trim(u8, trimmed, "- ").len == 0 and std.mem.count(u8, trimmed, "-") >= 2))
    {
        out.add(n, .heading);
        return state;
    } else if (indent < 4 and trimmed.len >= 3 and (std.mem.trim(u8, trimmed, "* ").len == 0 or std.mem.trim(u8, trimmed, "_ ").len == 0)) {
        out.add(n, .punctuation);
        return state;
    }
    var i = indent;
    out.add(i, .text);
    // Quotes and list markers.
    while (i < n and line[i] == '>') {
        out.add(i + 1, .punctuation);
        i += 1;
        while (i < n and line[i] == ' ') i += 1;
        out.add(i, .text);
    }
    if (i + 1 < n and (line[i] == '-' or line[i] == '*' or line[i] == '+') and line[i + 1] == ' ') {
        out.add(i + 1, .punctuation);
        i += 1;
    } else {
        var j = i;
        while (j < n and j - i < 9 and line[j] >= '0' and line[j] <= '9') j += 1;
        if (j > i and j + 1 < n and (line[j] == '.' or line[j] == ')') and line[j + 1] == ' ') {
            out.add(j + 1, .punctuation);
            i = j + 1;
        }
    }
    const rest = line[i..];
    const lead = std.mem.trimStart(u8, rest, " ");
    if (std.mem.startsWith(u8, lead, "[ ] ") or std.mem.startsWith(u8, lead, "[x] ") or std.mem.startsWith(u8, lead, "[X] ")) {
        const k = i + std.mem.indexOfScalar(u8, rest, '[').?;
        out.add(k, .text);
        out.add(k + 3, .keyword);
        i = k + 3;
    }
    if (inline_(line, i, out)) state |= md_comment;
    return state;
}

/// Markdown's inline syntax from i; reports whether an HTML comment stays
/// open at the end of the line.
fn inline_(line: []const u8, start: usize, out: *Output) bool {
    const n = line.len;
    var i = start;
    while (i < n) {
        const c = line[i];
        if (c == '\\' and i + 1 < n and std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!|<>~", line[i + 1]) != null) {
            out.add(i + 2, .escape);
            i += 2;
        } else if (c == '`') {
            var run: usize = 1;
            while (i + run < n and line[i + run] == '`') run += 1;
            const end = indexOfRun(line[i + run ..], '`', run) orelse {
                out.add(i + run, .text);
                i += run;
                continue;
            };
            out.add(i + run + end + run, .code);
            i += run + end + run;
        } else if (std.mem.startsWith(u8, line[i..], "<!--")) {
            const end = std.mem.indexOf(u8, line[i + 4 ..], "-->") orelse {
                out.add(n, .comment);
                return true;
            };
            out.add(i + 4 + end + 3, .comment);
            i += 4 + end + 3;
        } else if (c == '<' and i + 1 < n and (lex.identStart(line[i + 1 ..], "") or line[i + 1] == '/')) {
            const end = std.mem.indexOfScalar(u8, line[i..], '>') orelse {
                out.add(i + 1, .text);
                i += 1;
                continue;
            };
            const inside = line[i .. i + end];
            const kind: TokenKind = if (std.mem.indexOf(u8, inside, "://") != null or std.mem.indexOfScalar(u8, inside, '@') != null) .link else .tag;
            out.add(i + end + 1, kind);
            i += end + 1;
        } else if (c == '[' or (c == '!' and i + 1 < n and line[i + 1] == '[')) {
            const link_start = i;
            if (c == '!') i += 1;
            const close = (std.mem.indexOfScalar(u8, line[i..], ']') orelse {
                out.add(i + 1, .text);
                i += 1;
                continue;
            }) + i;
            out.add(link_start, .text);
            out.add(close + 1, .link);
            i = close + 1;
            if (i < n and (line[i] == '(' or line[i] == '[')) {
                const quote: u8 = if (line[i] == '[') ']' else ')';
                if (std.mem.indexOfScalar(u8, line[i..], quote)) |end| {
                    out.add(i + end + 1, .string);
                    i += end + 1;
                }
            }
        } else if (c == '*' or c == '_' or c == '~') {
            var run: usize = 1;
            while (i + run < n and line[i + run] == c) run += 1;
            if ((c == '~' and run < 2) or i + run >= n or line[i + run] == ' ' or (c == '_' and i > 0 and isIdentByte(line[i - 1]))) {
                out.add(i + run, .text);
                i += run;
                continue;
            }
            const end = std.mem.indexOf(u8, line[i + run ..], line[i .. i + run]) orelse 0;
            if (end == 0 or line[i + run + end - 1] == ' ') {
                out.add(i + run, .text);
                i += run;
                continue;
            }
            const kind: TokenKind = if (c == '~') .deleted else if (run >= 2) .strong else .emphasis;
            out.add(i + run + end + run, kind);
            i += run + end + run;
        } else if (std.mem.startsWith(u8, line[i..], "http://") or std.mem.startsWith(u8, line[i..], "https://")) {
            var j = i;
            while (j < n and line[j] != ' ' and line[j] != ')' and line[j] != '>') j += 1;
            out.add(j, .link);
            i = j;
        } else if (c == '|') {
            out.add(i + 1, .punctuation);
            i += 1;
        } else {
            var j = i + 1;
            while (j < n and std.mem.indexOfScalar(u8, "\\`<[!*_~h|", line[j]) == null) j += 1;
            out.add(j, .text);
            i = j;
        }
    }
    return false;
}

/// The first run of exactly `count` or more `c` in s, as the closing
/// backticks of a code span.
fn indexOfRun(s: []const u8, c: u8, count: usize) ?usize {
    var i: usize = 0;
    while (i + count <= s.len) : (i += 1) {
        var k: usize = 0;
        while (k < count and s[i + k] == c) k += 1;
        if (k == count) return i;
    }
    return null;
}

/// Unified diffs by the first characters of their lines.
pub const diff = Tokenizer{ .context = &diff_marker, .call = diffTokenize };
const diff_marker: u8 = 0;

fn diffTokenize(_: *const anyopaque, line: []const u8, _: u64, out: *Output) u64 {
    if (line.len == 0) return 0;
    const meta_prefixes = [_][]const u8{ "+++", "---", "diff ", "index ", "new file", "deleted file", "similarity", "rename ", "old mode", "new mode" };
    for (meta_prefixes) |prefix| if (std.mem.startsWith(u8, line, prefix)) {
        out.add(line.len, .meta);
        return 0;
    };
    if (std.mem.startsWith(u8, line, "@@")) {
        if (std.mem.indexOf(u8, line[2..], "@@")) |end| {
            out.add(end + 4, .keyword);
            if (end + 4 < line.len) out.add(line.len, .function);
            return 0;
        }
        out.add(line.len, .keyword);
        return 0;
    }
    const kind: TokenKind = switch (line[0]) {
        '+', '>' => .inserted,
        '-', '<' => .deleted,
        '\\' => .comment,
        else => .text,
    };
    out.add(line.len, kind);
    return 0;
}
