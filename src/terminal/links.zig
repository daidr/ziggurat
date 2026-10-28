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

/// A byte of a URL: anything but spaces, quotes, angle brackets, backticks
/// and controls.
fn urlByte(byte: u8) bool {
    return switch (byte) {
        0...0x20, 0x7f, '<', '>', '"', '\'', '`' => false,
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

fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
/// A byte of a file name: word characters, '.', '@', '+' and '-'.
fn nameByte(byte: u8) bool {
    return word(byte) or byte == '.' or byte == '@' or byte == '+' or byte == '-';
}
/// A byte of an absolute path: anything but spaces, quotes, angle
/// brackets, backticks, controls and ':'.
fn absoluteByte(byte: u8) bool {
    return urlByte(byte) and byte != ':';
}

/// `:line` or `:line:col` at `text[i..]`: its end, else `i`.
fn lineSuffix(text: []const u8, i: usize) usize {
    var end = i;
    for (0..2) |_| {
        if (end >= text.len or text[end] != ':') break;
        var digits = end + 1;
        while (digits < text.len and std.ascii.isDigit(text[digits])) digits += 1;
        if (digits == end + 1) break;
        end = digits;
    }
    return end;
}

/// A file path at `text[i..]`: absolute, from `~`, `./` or `../`, with a
/// slash, or a file name with an extension; each may end in `:line` or
/// `:line:col`. Its end, or null.
fn pathAt(text: []const u8, i: usize) ?usize {
    // Absolute, or from ~, ../ or ./.
    for ([_][]const u8{ "~/", "../", "./", "/" }) |prefix| {
        if (!std.mem.startsWith(u8, text[i..], prefix)) continue;
        var end = i + prefix.len;
        while (end < text.len and absoluteByte(text[end])) end += 1;
        if (end > i + prefix.len) return lineSuffix(text, end);
    }
    // Names joined by slashes.
    var end = i;
    while (end < text.len and nameByte(text[end])) end += 1;
    const name_end = end;
    if (end > i) {
        var segments: usize = 0;
        while (end < text.len and text[end] == '/') {
            var seg = end + 1;
            while (seg < text.len and nameByte(text[seg])) seg += 1;
            if (seg == end + 1) break;
            end = seg;
            segments += 1;
        }
        if (segments > 0) {
            if (end < text.len and text[end] == '/') end += 1;
            return lineSuffix(text, end);
        }
    }
    // A file name with an extension, and maybe a line.
    var stem_end = name_end;
    while (stem_end > i and !word(text[stem_end - 1])) stem_end -= 1;
    if (stem_end > i and text[i] != '.') {
        const dot = std.mem.lastIndexOfScalar(u8, text[i + 1 .. stem_end], '.') orelse return null;
        const ext = text[i + 1 + dot + 1 .. stem_end];
        if (ext.len == 0) return null;
        for (ext) |b| if (!word(b)) return null;
        const suffix = lineSuffix(text, stem_end);
        // Dotted numbers, such as version 1.2.3, are no file names.
        if (suffix == stem_end) {
            for (text[i..stem_end]) |b| if (std.ascii.isAlphabetic(b)) return suffix;
            return null;
        }
        return suffix;
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
    // Leftmost matches, one after another.
    var i: usize = 0;
    while (i < text.len) {
        const matched = switch (kind) {
            .url => urlAt(text, i),
            .path => pathAt(text, i),
        } orelse {
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
        if (case.path) |path| {
            try std.testing.expectEqualStrings(path, found.?.uri);
            if (std.mem.eql(u8, case.line, "write(notes.md)")) {
                try std.testing.expectEqual(@as(u16, 6), found.?.start);
                try std.testing.expectEqual(@as(u16, 14), found.?.end);
            }
        } else try std.testing.expect(found == null);
    }
}
