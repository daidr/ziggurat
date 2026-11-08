//! Finds web, mail and file addresses, and file paths, in a line of cells,
//! so the view can underline the one under the pointer and open it. Links set by the
//! program with OSC 8 come from the cells themselves and need no search.
const std = @import("std");
const screen = @import("screen.zig");

pub const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "mailto:" };

pub const Found = struct {
    /// First and one past the last column.
    start: u16,
    end: u16,
    /// The address, written into the caller's buffer.
    uri: []const u8,
};

/// A byte of a URL: anything but spaces, quotes, angle brackets, backticks,
/// controls and bytes beyond ASCII. A URL sends what is not ASCII encoded,
/// so it ends at the first such character: the CJK text or full-width
/// punctuation that often follows one without a space.
fn urlByte(byte: u8) bool {
    return switch (byte) {
        0...0x20, 0x7f...0xff, '<', '>', '"', '\'', '`' => false,
        else => true,
    };
}

/// A web, FTP, file or mail address at `text[i..]`: its end, or null.
fn urlAt(text: []const u8, i: usize) ?usize {
    for (schemes) |scheme| {
        if (!std.mem.startsWith(u8, text[i..], scheme)) continue;
        var end = i + scheme.len;
        while (end < text.len and urlByte(text[end])) end += 1;
        if (end > i + scheme.len) return end;
    }
    return null;
}

/// Punctuation Chinese and Japanese prose ends a clause with: a path
/// printed there has no space around it. A quoted path may hold them.
const prose_delimiters = "，。；：！？、（）【】《》「」『』";

fn decode(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + len > text.len) return .{ .cp = text[i], .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = len };
}

fn proseDelimiter(cp: u21) bool {
    var view = std.unicode.Utf8View.initUnchecked(prose_delimiters).iterator();
    while (view.nextCodepoint()) |d| if (d == cp) return true;
    return false;
}

/// Whether the code point ends an unquoted token: spaces, quotes, angle
/// brackets, backticks, controls and the punctuation of prose.
fn tokenEnd(cp: u21) bool {
    return switch (cp) {
        0...0x20, 0x7f, '"', '\'', '<', '>', '`', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => proseDelimiter(cp),
    };
}

/// A letter or digit of any script, as far as paths go: ASCII ones, and
/// code points beyond ASCII that are not spaces, punctuation or symbols.
fn letterOrDigit(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
    return switch (cp) {
        0x80...0xbf, 0xd7, 0xf7, 0x2000...0x2bff, 0x3000...0x303f, 0xfe30...0xfe6f, 0xff00...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => false,
        else => !proseDelimiter(cp),
    };
}

fn letter(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphabetic(@intCast(cp));
    return letterOrDigit(cp) and !(cp >= 0xff10 and cp <= 0xff19);
}

/// A code point of a file name: letters and digits of any script, '_',
/// '.', '@', '+' and '-'.
fn nameChar(cp: u21) bool {
    return letterOrDigit(cp) or cp == '_' or cp == '.' or cp == '@' or cp == '+' or cp == '-';
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn digitsEnd(text: []const u8, i: usize) usize {
    var end = i;
    while (end < text.len and isDigit(text[end])) end += 1;
    return end;
}

/// `:line` or `:line:col` at `text[i..]`: its end, else `i`.
fn lineSuffix(text: []const u8, i: usize) usize {
    var end = i;
    for (0..2) |_| {
        if (end >= text.len or text[end] != ':') break;
        const digits = digitsEnd(text, end + 1);
        if (digits == end + 1) break;
        end = digits;
    }
    return end;
}

/// The end of a run of name code points at `text[i..]`.
fn namesEnd(text: []const u8, i: usize) usize {
    var end = i;
    while (end < text.len) {
        const d = decode(text, end);
        if (!nameChar(d.cp)) break;
        end += d.len;
    }
    return end;
}

/// A path inside a token that is not one as a whole, at `text[i..]`: its
/// end, or null. Absolute or from `~`, `./` or `../` up to a ':', names
/// joined by slashes, or a file name with an extension; each may end in
/// `:line` or `:line:col`. As main.go:12 in grep's main.go:12:code,
/// build/app.js in --out=build/app.js and /usr/bin in PATH=/usr/bin:/bin.
fn pathInToken(text: []const u8, i: usize) ?usize {
    for ([_][]const u8{ "~/", "../", "./", "/" }) |prefix| {
        if (!std.mem.startsWith(u8, text[i..], prefix)) continue;
        var end = i + prefix.len;
        while (end < text.len and text[end] != ':' and !tokenEnd(decode(text, end).cp)) end += decode(text, end).len;
        if (end > i + prefix.len) return lineSuffix(text, end);
    }
    // Names joined by slashes.
    const name_end = namesEnd(text, i);
    if (name_end > i) {
        var end = name_end;
        var segments: usize = 0;
        while (end < text.len and text[end] == '/') {
            const seg = namesEnd(text, end + 1);
            if (seg == end + 1) break;
            end = seg;
            segments += 1;
        }
        if (segments > 0) {
            if (end < text.len and text[end] == '/') end += 1;
            return lineSuffix(text, end);
        }
    }
    // A file name with an extension: the last dot followed by letters,
    // digits or '_' of the run, which starts with no dot.
    if (name_end > i and text[i] != '.') {
        var dot = name_end;
        while (dot > i + 1) {
            dot -= 1;
            if (text[dot] != '.') continue;
            var ext_end = dot + 1;
            while (ext_end < name_end) {
                const d = decode(text, ext_end);
                if (!(letterOrDigit(d.cp) or d.cp == '_')) break;
                ext_end += d.len;
            }
            if (ext_end > dot + 1) return lineSuffix(text, ext_end);
        }
    }
    return null;
}

/// The place in the file a path ends with: `:line[:col][:]` (compilers,
/// grep), `(line[,col])` (TypeScript, MSBuild) or `#Lline[Ccol]`
/// (GitHub). `start` is where it begins in the name.
const Place = struct { start: usize, line: u32, col: u32 = 0, colon: bool = false };

fn number(text: []const u8) u32 {
    return std.fmt.parseInt(u32, text, 10) catch std.math.maxInt(u32);
}

fn placeOf(name: []const u8) ?Place {
    for (0..name.len) |start| {
        const rest = name[start..];
        if (rest[0] == ':') {
            const line_end = digitsEnd(rest, 1);
            if (line_end == 1) continue;
            var place: Place = .{ .start = start, .line = number(rest[1..line_end]) };
            var end = line_end;
            if (end + 1 < rest.len and rest[end] == ':' and isDigit(rest[end + 1])) {
                const col_end = digitsEnd(rest, end + 1);
                place.col = number(rest[end + 1 .. col_end]);
                end = col_end;
            }
            if (end < rest.len and rest[end] == ':') {
                place.colon = true;
                end += 1;
            }
            if (end == rest.len) return place;
        } else if (rest[0] == '(') {
            const line_end = digitsEnd(rest, 1);
            if (line_end == 1) continue;
            var place: Place = .{ .start = start, .line = number(rest[1..line_end]) };
            var end = line_end;
            if (end + 1 < rest.len and rest[end] == ',' and isDigit(rest[end + 1])) {
                const col_end = digitsEnd(rest, end + 1);
                place.col = number(rest[end + 1 .. col_end]);
                end = col_end;
            }
            if (end + 1 == rest.len and rest[end] == ')') return place;
        } else if (std.mem.startsWith(u8, rest, "#L")) {
            const line_end = digitsEnd(rest, 2);
            if (line_end == 2) continue;
            var place: Place = .{ .start = start, .line = number(rest[2..line_end]) };
            var end = line_end;
            if (end + 1 < rest.len and rest[end] == 'C' and isDigit(rest[end + 1])) {
                const col_end = digitsEnd(rest, end + 1);
                place.col = number(rest[end + 1 .. col_end]);
                end = col_end;
            }
            if (end == rest.len) return place;
        }
    }
    return null;
}

/// `text` up to a closing bracket it did not open, as the ) of
/// "(image.png)已保存".
fn balanced(text: []const u8) usize {
    var depth: [3]usize = .{ 0, 0, 0 };
    for (text, 0..) |byte, i| {
        if (std.mem.indexOfScalar(u8, "([{", byte)) |k| {
            depth[k] += 1;
        } else if (std.mem.indexOfScalar(u8, ")]}", byte)) |k| {
            if (depth[k] == 0) return i;
            depth[k] -= 1;
        }
    }
    return text.len;
}

/// The index of the ( that opens the ) `text` ends with.
fn opening(text: []const u8) ?usize {
    var depth: usize = 0;
    var i = text.len;
    while (i > 0) {
        i -= 1;
        switch (text[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The path a token, or a quoted run, prints: its bytes in the token,
/// `start` up to `end`, and the path written as `path:line:col` into
/// `out`, or null.
const PathOf = struct { start: usize, end: usize, path: []const u8 };

fn pathOf(token: []const u8, out: []u8) ?PathOf {
    var a: usize = 0;
    var b: usize = token.len;
    const quoted = token[0] == '"' or token[0] == '\'';
    if (!quoted) {
        // Brackets and emphasis around a path are not part of it, nor is
        // the call a path is the argument of, as write(notes.md); a
        // bracket the path opens is, as icon_(copy).png.
        while (a < token.len and std.mem.indexOfScalar(u8, "([{*", token[a]) != null) a += 1;
        // The name of an option or a variable the path is the value of,
        // as --out=build/app.js or PATH=/usr/bin, is not part of it.
        if (std.mem.indexOfScalar(u8, token[a..], '=')) |i| if (std.mem.indexOfScalar(u8, token[a..][0..i], '/') == null) {
            a += i + 1;
        };
        b = a + balanced(token[a..]);
        if (b > a and token[b - 1] == ')' and placeOf(token[a..b]) == null) {
            if (opening(token[a..b])) |i| if (i > 0) {
                a += i + 1;
                b -= 1;
            };
        }
        while (b > a and std.mem.indexOfScalar(u8, ",;.!?]", token[b - 1]) != null) b -= 1;
        if (placeOf(token[a..b]) == null) b = a + trim(token[a..b]);
        if (b <= a) return null;
    }
    var name = token[a..b];
    var line: u32 = 0;
    var col: u32 = 0;
    if (placeOf(name)) |place| {
        name = name[0..place.start];
        line = place.line;
        col = place.col;
        // The colon after main.go:12:3: ends a compiler's location.
        if (place.colon) b -= 1;
    }
    if (quoted) {
        if (name.len < 2) return null;
        name = name[1 .. name.len - 1];
    }
    if (name.len == 0 or std.mem.indexOfAny(u8, name, ":\x00\r\n") != null) return null;
    var has_letter_or_digit = false;
    var has_letter = false;
    var index: usize = 0;
    while (index < name.len) {
        const d = decode(name, index);
        if (letterOrDigit(d.cp)) has_letter_or_digit = true;
        if (letter(d.cp)) has_letter = true;
        index += d.len;
    }
    if (!has_letter_or_digit) return null;
    // Words are not paths: a name without a slash takes a letter, and an
    // extension or a line, so that version 1.2.3 and 12:30 are neither.
    if (std.mem.indexOfScalar(u8, name, '/') == null) {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        if (!has_letter or (line == 0 and (dot == null or dot.? == name.len - 1))) return null;
    }
    var writer: std.Io.Writer = .fixed(out);
    writer.writeAll(name) catch return null;
    if (line > 0) {
        writer.print(":{d}", .{line}) catch return null;
        if (col > 0) writer.print(":{d}", .{col}) catch return null;
    }
    return .{ .start = a, .end = b, .path = writer.buffered() };
}

/// A quoted run opening at `text[i]`, with the place after it, as
/// "main.py":12: its end, or null. A quote between letters or digits, as
/// in don't, is an apostrophe and opens nothing, and the inside of a
/// quoted path neither starts nor ends with a space.
fn quotedAt(text: []const u8, i: usize) ?usize {
    const quote = text[i];
    if (quote != '"' and quote != '\'') return null;
    if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) return null;
    const close = std.mem.indexOfScalarPos(u8, text, i + 1, quote) orelse return null;
    const inner = text[i + 1 .. close];
    if (inner.len == 0 or std.mem.indexOfAny(u8, inner, "\r\n") != null) return null;
    if (std.mem.trim(u8, inner, " \t").len != inner.len) return null;
    var end = close + 1;
    end = lineSuffix(text, end);
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return end;
}

/// The file path printed in `text`, whose bytes are in `columns`, at
/// column `col`: absolute, from `~`, `./` or `../`, with a slash, or a
/// file name with an extension or a line. The place in the file is
/// written path:line:col however it was printed (`:line:col`,
/// `(line,col)`, `#LlineCcol`), and a quoted path, spaces and all, loses
/// its quotes.
fn pathFind(text: []const u8, columns: []const u16, col: u16, out: []u8) ?Found {
    const Span = struct {
        fn of(cols: []const u16, start: usize, end: usize, column: u16) ?[2]u16 {
            if (end <= start or end > cols.len) return null;
            if (cols[start] <= column and column <= cols[end - 1]) return .{ cols[start], cols[end - 1] + 1 };
            return null;
        }
    };
    // A quoted path first, as it may hold spaces and what tokens end at.
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const end = quotedAt(text, i) orelse continue;
        if (pathOf(text[i..end], out)) |found| {
            if (Span.of(columns, i + found.start, i + found.end, col)) |span| return .{ .start = span[0], .end = span[1], .uri = found.path };
            i = end - 1;
        }
    }
    // Then runs of anything but spaces, quotes and prose punctuation.
    i = 0;
    while (i < text.len) {
        if (tokenEnd(decode(text, i).cp)) {
            i += decode(text, i).len;
            continue;
        }
        const start = i;
        while (i < text.len and !tokenEnd(decode(text, i).cp)) i += decode(text, i).len;
        const token = text[start..i];
        if (pathOf(token, out)) |found| {
            if (Span.of(columns, start + found.start, start + found.end, col)) |span| return .{ .start = span[0], .end = span[1], .uri = found.path };
            continue;
        }
        var j: usize = 0;
        while (j < token.len) {
            const end = pathInToken(token, j) orelse {
                j += decode(token, j).len;
                continue;
            };
            if (pathOf(token[j..end], out)) |found| {
                if (Span.of(columns, start + j + found.start, start + j + found.end, col)) |span| return .{ .start = span[0], .end = span[1], .uri = found.path };
            }
            j = end;
        }
    }
    return null;
}

pub const Kind = enum { url, path };

/// The address covering column `col` of `cells`, if any. `buffer` holds
/// the line's text while searching and the address after.
pub fn at(cells: []const screen.Cell, col: u16, buffer: []u8) ?Found {
    return find(cells, col, buffer, .url);
}

/// The file path covering column `col`, as `at` finds addresses.
pub fn pathUnder(cells: []const screen.Cell, col: u16, buffer: []u8) ?Found {
    return find(cells, col, buffer, .path);
}

fn find(cells: []const screen.Cell, col: u16, buffer: []u8, kind: Kind) ?Found {
    // Text of the line, and the column each byte came from.
    var columns: [1024]u16 = undefined;
    var len: usize = 0;
    for (cells, 0..) |cell, x| {
        if (cell.wide == .spacer) continue;
        const cp: u21 = if (cell.cp == 0) ' ' else cell.cp;
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &bytes) catch continue;
        if (len + n > buffer.len or len + n > columns.len) break;
        @memcpy(buffer[len..][0..n], bytes[0..n]);
        for (0..n) |i| columns[len + i] = @intCast(x);
        len += n;
    }
    const text = buffer[0..len];
    if (kind == .path) {
        var path: [1024]u8 = undefined;
        const found = pathFind(text, columns[0..len], col, &path) orelse return null;
        if (found.uri.len > buffer.len) return null;
        @memcpy(buffer[0..found.uri.len], found.uri);
        return .{ .start = found.start, .end = found.end, .uri = buffer[0..found.uri.len] };
    }
    // Leftmost matches, one after another.
    var i: usize = 0;
    while (i < text.len) {
        const matched = urlAt(text, i) orelse {
            i += 1;
            continue;
        };
        const begin = i;
        i = matched;
        const end = trim(text[begin..matched]) + begin;
        if (end <= begin) continue;
        const first = columns[begin];
        const last = columns[end - 1];
        if (col < first or col > last) continue;
        const uri = text[begin..end];
        std.mem.copyForwards(u8, buffer[0..uri.len], uri);
        return .{ .start = first, .end = last + 1, .uri = buffer[0..uri.len] };
    }
    return null;
}

/// Length without what likely ends the sentence around an address rather
/// than the address: punctuation, and closing brackets it did not open.
fn trim(uri: []const u8) usize {
    var end = uri.len;
    while (end > 0) {
        const last = uri[end - 1];
        switch (last) {
            '.', ',', ';', ':', '!', '?' => end -= 1,
            ')', ']', '}' => {
                const open: u8 = switch (last) {
                    ')' => '(',
                    ']' => '[',
                    else => '{',
                };
                if (std.mem.count(u8, uri[0..end], &.{open}) >= std.mem.count(u8, uri[0..end], &.{last})) break;
                end -= 1;
            },
            else => break,
        }
    }
    return end;
}

fn cellsOf(text: []const u8, out: []screen.Cell) []screen.Cell {
    var len: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |cp| {
        const wide = @import("width.zig").of(cp) == 2;
        out[len] = .{ .cp = cp, .wide = if (wide) .wide else .narrow };
        len += 1;
        if (wide) {
            out[len] = .{ .wide = .spacer };
            len += 1;
        }
    }
    return out[0..len];
}

test "addresses under a column, trimmed of punctuation" {
    var cells: [128]screen.Cell = undefined;
    var buffer: [256]u8 = undefined;
    const line = cellsOf("see https://example.com/a_(b), or 中 mailto:x@y.z.", &cells);
    const found = at(line, 10, &buffer).?;
    try std.testing.expectEqualStrings("https://example.com/a_(b)", found.uri);
    try std.testing.expectEqual(@as(u16, 4), found.start);
    try std.testing.expectEqual(@as(u16, 29), found.end);
    try std.testing.expect(at(line, 2, &buffer) == null);
    try std.testing.expect(at(line, 29, &buffer) == null);
    // Columns after a wide character count both of its cells.
    const mail = at(line, 40, &buffer).?;
    try std.testing.expectEqualStrings("mailto:x@y.z", mail.uri);
    try std.testing.expectEqual(@as(u16, 37), mail.start);
    const quoted = cellsOf("x<http://a.b/c>y (https://q.r)", &cells);
    try std.testing.expectEqualStrings("http://a.b/c", at(quoted, 5, &buffer).?.uri);
    try std.testing.expectEqualStrings("https://q.r", at(quoted, 20, &buffer).?.uri);
    // Addresses need not start a word.
    try std.testing.expectEqualStrings("https://no", at(cellsOf("xhttps://no", &cells), 5, &buffer).?.uri);
    try std.testing.expect(at(cellsOf("ssh://host", &cells), 3, &buffer) == null);
}

test "an address ends at its first character beyond ASCII" {
    var cells: [128]screen.Cell = undefined;
    var buffer: [256]u8 = undefined;
    const cases = [_]struct { line: []const u8, col: u16, uri: []const u8 }{
        .{ .line = "https://example.com/a的说明", .col = 3, .uri = "https://example.com/a" },
        .{ .line = "https://example.com/a，然后", .col = 3, .uri = "https://example.com/a" },
        .{ .line = "见https://example.com/a。", .col = 4, .uri = "https://example.com/a" },
        .{ .line = "（https://example.com/a）", .col = 4, .uri = "https://example.com/a" },
        .{ .line = "https://example.com/%E4%BD%A0", .col = 3, .uri = "https://example.com/%E4%BD%A0" },
        .{ .line = "mailto:me@x.org，谢谢", .col = 3, .uri = "mailto:me@x.org" },
    };
    for (cases) |case| {
        const found = at(cellsOf(case.line, &cells), case.col, &buffer) orelse return error.TestExpectedAddress;
        try std.testing.expectEqualStrings(case.uri, found.uri);
    }
    // Text beyond ASCII after an address is not part of it.
    const line = cellsOf("https://a.b/c中文", &cells);
    try std.testing.expectEqual(@as(u16, 13), at(line, 2, &buffer).?.end);
    try std.testing.expect(at(line, 14, &buffer) == null);
}

test "file paths under a column" {
    var cells: [128]screen.Cell = undefined;
    var buffer: [256]u8 = undefined;
    const cases = [_]struct { line: []const u8, col: u16, path: ?[]const u8 }{
        .{ .line = "open /abs/path.txt now", .col = 8, .path = "/abs/path.txt" },
        .{ .line = "see ~/notes.md.", .col = 6, .path = "~/notes.md" },
        .{ .line = "in ./a.go and", .col = 4, .path = "./a.go" },
        .{ .line = "../up/x", .col = 1, .path = "../up/x" },
        .{ .line = "error src/app.go:12:3: oops", .col = 8, .path = "src/app.go:12:3" },
        .{ .line = "main.go:250 here", .col = 2, .path = "main.go:250" },
        .{ .line = "dir/sub/ end", .col = 1, .path = "dir/sub/" },
        .{ .line = "just words here", .col = 6, .path = null },
        .{ .line = "main.go alone", .col = 2, .path = "main.go" },
        .{ .line = "write(notes.md)", .col = 8, .path = "notes.md" },
        .{ .line = "notes.md (new file +2)", .col = 2, .path = "notes.md" },
        .{ .line = "See notes.md.", .col = 7, .path = "notes.md" },
        .{ .line = "notes.md:2:3", .col = 2, .path = "notes.md:2:3" },
        .{ .line = "version 1.2.3 ok", .col = 9, .path = null },
        .{ .line = "v1.2 ok", .col = 1, .path = "v1.2" },
        .{ .line = "(see /tmp/x)", .col = 7, .path = "/tmp/x" },
    };
    for (cases) |case| {
        const found = pathUnder(cellsOf(case.line, &cells), case.col, &buffer);
        errdefer std.debug.print("line {s}\n", .{case.line});
        if (case.path) |path| {
            try std.testing.expectEqualStrings(path, found.?.uri);
            if (std.mem.eql(u8, case.line, "write(notes.md)")) {
                try std.testing.expectEqual(@as(u16, 6), found.?.start);
                try std.testing.expectEqual(@as(u16, 14), found.?.end);
            }
        } else try std.testing.expect(found == null);
    }
}

test "paths in prose, quoted paths and places in the file" {
    var cells: [256]screen.Cell = undefined;
    var buffer: [512]u8 = undefined;
    // Each row, a text the column is on, and the path expected there.
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "error: src/main.go:42:5: failed", "main", "src/main.go:42:5" },
        .{ "at (./src/main.ts(12,3))", "main", "./src/main.ts:12:3" },
        .{ "src/app.ts(12): error TS2304", "app", "src/app.ts:12" },
        .{ "see ~/work/中文.go#L8C2", "中文", "~/work/中文.go:8:2" },
        .{ "see src/app.go#L12 for it", "app", "src/app.go:12" },
        .{ "File \"/tmp/my project/中文.go\":13:2", "project", "/tmp/my project/中文.go:13:2" },
        .{ "open \"/tmp/my notes/a.md\" now", "notes", "/tmp/my notes/a.md" },
        .{ "File '/usr/lib/x y.py', line 7", "lib", "/usr/lib/x y.py" },
        .{ "文件 src/日本.go:4 有错", "日本", "src/日本.go:4" },
        .{ "已保存新版图标 (assets/branding/terminal-icon.png)，使用新版", "terminal", "assets/branding/terminal-icon.png" },
        .{ "terminal-icon.prompt.txt)也已保存。", "prompt", "terminal-icon.prompt.txt" },
        .{ "已保存（assets/branding/中文.png），继续", "中文", "assets/branding/中文.png" },
        .{ "见：src/main.go:42:5，错误", "main", "src/main.go:42:5" },
        .{ "已保存 (assets/icon_(copy).png)，继续", "icon", "assets/icon_(copy).png" },
        .{ "文件 \"assets/图标（新版），副本.png\"，已保存", "新版", "assets/图标（新版），副本.png" },
        .{ "(../README.md),", "README", "../README.md" },
        .{ "Makefile:4", "Make", "Makefile:4" },
        .{ "目录 /tmp/project/", "project", "/tmp/project/" },
        .{ "main.go:0", "main", "main.go" },
        .{ "src/a.go:12:code", "a.go", "src/a.go:12" },
        .{ "--out=build/app.js", "app", "build/app.js" },
        .{ "PATH=/usr/bin:/sbin", "usr", "/usr/bin" },
        .{ "PATH=/usr/bin:/sbin", "sbin", "/sbin" },
        .{ "PATH=/usr/bin:/sbin", "PATH", "" },
        .{ "don't open src/a.go, it's broken", "src", "src/a.go" },
        .{ "don't open src/a.go, it's broken", "open", "" },
        .{ "don't open src/a.go, it's broken", "broken", "" },
        .{ "say \" a/b.go \" twice", "a/b", "a/b.go" },
        .{ "meet at 12:30 today", "12", "" },
        .{ "and / or", "/", "" },
        .{ "已保存 (assets/x.png)，继续", "保存", "" },
        .{ "已保存 (assets/x.png)，继续", "，", "" },
    };
    for (cases) |case| {
        const line = cellsOf(case[0], &cells);
        // The column of the text: wide code points take two.
        const byte = std.mem.indexOf(u8, case[0], case[1]).?;
        var col: u16 = 0;
        var view = std.unicode.Utf8View.initUnchecked(case[0][0..byte]).iterator();
        while (view.nextCodepoint()) |cp| col += if (@import("width.zig").of(cp) == 2) 2 else 1;
        const found = pathUnder(line, col, &buffer);
        errdefer std.debug.print("{s} at {s}: {?s}\n", .{ case[0], case[1], if (found) |f| f.uri else null });
        if (case[2].len == 0) {
            try std.testing.expect(found == null);
        } else try std.testing.expectEqualStrings(case[2], found.?.uri);
    }
}
