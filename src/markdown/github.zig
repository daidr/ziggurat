//! What GitHub's comments read beyond its Markdown: alerts, decided once
//! the blocks are parsed, and mentions and references to issues, found
//! in the text of each paragraph once its inlines are, as extended
//! autolinks are: never in code, links or images. Whether the person,
//! team or issue exists is for a view to resolve.
const std = @import("std");
const md = @import("root.zig");

const Builder = md.Builder;
const Error = md.Error;
const none = md.none;

/// The longest GitHub login.
const max_login = 39;
/// The longest repository name.
const max_repository = 100;
/// The most digits of an issue number.
const max_digits = 10;

/// Makes the top-level block quotes whose first line is an alert's marker
/// alerts: the marker's line leaves the quote's first paragraph, or the
/// paragraph leaves the quote when the marker is all it holds and another
/// block follows it. A quote of the marker alone stays a quote.
pub fn alerts(b: *Builder) void {
    var at = b.nodes[0].first_child;
    while (at != none) : (at = b.nodes[at].next) {
        const quote = &b.nodes[at];
        if (quote.kind != .block_quote) continue;
        const first = quote.first_child;
        if (first == none or b.nodes[first].kind != .paragraph) continue;
        const paragraph = &b.nodes[first];
        const text = paragraph.text;
        const line_end = std.mem.indexOfScalar(u8, text, '\n');
        const alert = md.Alert.ofLine(text[0 .. line_end orelse text.len]);
        if (alert == .none) continue;
        if (line_end) |end| {
            paragraph.text = text[end + 1 ..];
            paragraph.line += 1;
        } else {
            if (paragraph.next == none) continue;
            quote.first_child = paragraph.next;
            paragraph.text = "";
            paragraph.next = none;
        }
        quote.alert = alert;
    }
}

/// Splits the mentions and references out of the text below `block`, a
/// paragraph, heading or table cell, into nodes of their own.
pub fn references(b: *Builder, block: u32) Error!void {
    try scan(b, block);
}

fn scan(b: *Builder, parent: u32) Error!void {
    var at = b.nodes[parent].first_child;
    while (at != none) {
        switch (b.nodes[at].kind) {
            .link, .image => at = b.nodes[at].next,
            .text => {
                const last = try merge(b, parent, at);
                at = b.nodes[try split(b, parent, last, false)].next;
            },
            .emphasis, .strong, .strikethrough => {
                try scan(b, at);
                at = b.nodes[at].next;
            },
            else => at = b.nodes[at].next,
        }
    }
}

/// Joins the run of text siblings from `first` into it when the run may
/// hold a mention or a reference, as the parse splits text at the bytes
/// that may start other syntax (`a&#64;b` is three texts). Returns the
/// text node the run is now.
fn merge(b: *Builder, parent: u32, first: u32) Error!u32 {
    var last = first;
    var interesting = triggers(b.nodes[first].text, b.options);
    while (b.nodes[last].next != none and b.nodes[b.nodes[last].next].kind == .text) {
        last = b.nodes[last].next;
        interesting = interesting or triggers(b.nodes[last].text, b.options);
    }
    if (last == first or !interesting) return if (last == first) first else last;
    const start = b.mark();
    var at = first;
    while (true) : (at = b.nodes[at].next) {
        try b.write(b.nodes[at].text);
        if (at == last) break;
    }
    const node = &b.nodes[first];
    node.text = b.since(start);
    node.next = b.nodes[last].next;
    if (b.nodes[parent].last_child == last) b.nodes[parent].last_child = first;
    return first;
}

/// Whether `text` holds a byte that may start a mention or a reference,
/// of those `options` reads.
fn triggers(text: []const u8, options: md.ParseOptions) bool {
    if (options.mentions and std.mem.indexOfScalar(u8, text, '@') != null) return true;
    if (!options.references) return false;
    if (std.mem.indexOfScalar(u8, text, '#') != null) return true;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, from, '-')) |at| : (from = at + 1) if (isGh(text, at)) return true;
    // A text may end in GH, its hyphen in the next one.
    return text.len >= 2 and text[text.len - 2] | 0x20 == 'g' and text[text.len - 1] | 0x20 == 'h';
}

/// Splits text node `index` at its mentions and references, which a word
/// precedes when `word_before`, and returns the last node of the text.
fn split(b: *Builder, parent: u32, index: u32, word_before: bool) Error!u32 {
    var at = index;
    var before = word_before;
    while (true) {
        const data = b.nodes[at].text;
        const found = find(data, before, b.options) orelse return at;
        var mark = at;
        if (found.start == 0) {
            b.nodes[at].kind = found.kind;
            b.nodes[at].text = data[0..found.end];
        } else {
            b.nodes[at].text = data[0..found.start];
            mark = try insertAfter(b, parent, at, .{ .kind = found.kind, .text = data[found.start..found.end] });
        }
        if (found.end == data.len) return mark;
        at = try insertAfter(b, parent, mark, .{ .kind = .text, .text = data[found.end..] });
        before = endsInWord(data[0..found.end]);
    }
}

fn insertAfter(b: *Builder, parent: u32, after: u32, node: md.Node) Error!u32 {
    const index = try b.add(none, node);
    b.nodes[index].parent = parent;
    b.nodes[index].next = b.nodes[after].next;
    b.nodes[after].next = index;
    if (b.nodes[parent].last_child == after) b.nodes[parent].last_child = index;
    return index;
}

const Found = struct { start: usize, end: usize, kind: md.Kind };

/// The first mention or reference in `data`, which a word precedes when
/// `word_before`.
fn find(data: []const u8, word_before: bool, options: md.ParseOptions) ?Found {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        switch (data[i]) {
            '@' => if (options.mentions and !wordAt(data, i, word_before)) {
                if (scanMention(data, i + 1)) |end| return .{ .start = i, .end = end, .kind = .mention };
            },
            '#' => if (options.references) {
                var from = i;
                if (wordAt(data, i, word_before)) from = repositoryBefore(data, i, word_before) orelse continue;
                if (scanNumber(data, i + 1)) |end| return .{ .start = from, .end = end, .kind = .reference };
            },
            // GH-123, found at its hyphen.
            '-' => if (options.references and isGh(data, i) and !wordAt(data, i - 2, word_before)) {
                if (scanNumber(data, i + 1)) |end| return .{ .start = i - 2, .end = end, .kind = .reference };
            },
            else => {},
        }
    }
    return null;
}

fn wordAt(data: []const u8, i: usize, word_before: bool) bool {
    return if (i == 0) word_before else endsInWord(data[0..i]);
}

/// The end of the login, or team, at `data[i..]` after an `@`: a login is
/// letters, digits and hyphens from a letter or a digit, and a team a
/// login, a slash and its name. No word follows it, nor a dot and a word,
/// as in `@example.com`.
fn scanMention(data: []const u8, i: usize) ?usize {
    var j = i;
    if (j >= data.len or !std.ascii.isAlphanumeric(data[j])) return null;
    while (j < data.len and (std.ascii.isAlphanumeric(data[j]) or data[j] == '-')) j += 1;
    if (j - i > max_login) return null;
    if (j + 1 < data.len and data[j] == '/' and std.ascii.isAlphanumeric(data[j + 1])) {
        j += 2;
        while (j < data.len and (std.ascii.isAlphanumeric(data[j]) or data[j] == '-' or data[j] == '_')) j += 1;
    }
    if (startsWithWord(data[j..]) or (j + 1 < data.len and data[j] == '.' and std.ascii.isAlphanumeric(data[j + 1]))) return null;
    return j;
}

/// The end of the issue number at `data[i..]`: up to `max_digits` digits
/// from 1 to 9 on, which no word follows.
fn scanNumber(data: []const u8, i: usize) ?usize {
    var j = i;
    if (j >= data.len or data[j] < '1' or data[j] > '9') return null;
    while (j < data.len and std.ascii.isDigit(data[j])) j += 1;
    if (j - i > max_digits or startsWithWord(data[j..])) return null;
    return j;
}

/// Where `owner/name` ending at `data[hash]`, a `#`, begins: no word,
/// slash or dot precedes it.
fn repositoryBefore(data: []const u8, hash: usize, word_before: bool) ?usize {
    var j = hash;
    while (j > 0 and hash - j < max_repository and isRepositoryByte(data[j - 1])) j -= 1;
    if (j == hash or j == 0 or data[j - 1] != '/') return null;
    const slash = j - 1;
    var k = slash;
    while (k > 0 and slash - k < max_login and (std.ascii.isAlphanumeric(data[k - 1]) or data[k - 1] == '-')) k -= 1;
    if (k == slash or !std.ascii.isAlphanumeric(data[k])) return null;
    if (k == 0) return if (word_before) null else 0;
    const c = data[k - 1];
    if (c == '/' or c == '.' or endsInWord(data[0..k])) return null;
    return k;
}

fn isRepositoryByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

/// Whether `data[i]`, a hyphen, follows GH, in any case.
fn isGh(data: []const u8, i: usize) bool {
    return i >= 2 and data[i - 2] | 0x20 == 'g' and data[i - 1] | 0x20 == 'h';
}

/// Whether `codepoint` is of a word: a letter, a digit or `_`. Beyond
/// ASCII, every codepoint but spaces, punctuation and symbols counts.
fn isWordCodepoint(codepoint: u21) bool {
    if (codepoint < 0x80) return std.ascii.isAlphanumeric(@intCast(codepoint)) or codepoint == '_';
    return switch (codepoint) {
        0x80...0xbf, // Latin-1 controls, punctuation and symbols
        0xd7,
        0xf7,
        0x2000...0x2bff, // punctuation, symbols, arrows, shapes
        0x3000...0x303f, // CJK punctuation
        0xfe30...0xfe4f,
        0xff00...0xff0f,
        0xff1a...0xff20,
        0xff3b...0xff40,
        0xff5b...0xff65,
        0x1f000...0x1faff, // emoji and pictographs
        => false,
        else => true,
    };
}

fn endsInWord(text: []const u8) bool {
    if (text.len == 0) return false;
    var start = text.len - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80 and text.len - start < 4) start -= 1;
    const codepoint = std.unicode.utf8Decode(text[start..]) catch return false;
    return isWordCodepoint(codepoint);
}

fn startsWithWord(text: []const u8) bool {
    if (text.len == 0) return false;
    const width = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (width > text.len) return false;
    const codepoint = std.unicode.utf8Decode(text[0..width]) catch return false;
    return isWordCodepoint(codepoint);
}
