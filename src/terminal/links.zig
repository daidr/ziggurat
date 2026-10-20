//! Finds web, mail and file addresses in a line of cells, so the view can
//! underline the one under the pointer and open it. Links set by the
//! program with OSC 8 come from the cells themselves and need no search.
const std = @import("std");
const screen = @import("screen.zig");

pub const schemes = [_][]const u8{ "https://", "http://", "ftp://", "file://", "ssh://", "git://", "mailto:" };

pub const Found = struct {
    /// First and one past the last column.
    start: u16,
    end: u16,
    /// The address, written into the caller's buffer.
    uri: []const u8,
};

fn urlByte(byte: u8) bool {
    return switch (byte) {
        0...0x20, 0x7f, '<', '>', '"', '`', '{', '}', '|', '\\', '^' => false,
        else => true,
    };
}

/// The address covering column `col` of `cells`, if any. `buffer` holds
/// the line's text while searching and the address after.
pub fn at(cells: []const screen.Cell, col: u16, buffer: []u8) ?Found {
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
    for (schemes) |scheme| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, scheme)) |begin| {
            from = begin + scheme.len;
            // The scheme must start a word.
            if (begin > 0 and (std.ascii.isAlphanumeric(text[begin - 1]) or text[begin - 1] == '+' or text[begin - 1] == '.' or text[begin - 1] == '-')) continue;
            var end = from;
            while (end < text.len and urlByte(text[end])) end += 1;
            end = trim(text[begin..end]) + begin;
            if (end <= from) continue;
            const first = columns[begin];
            const last = columns[end - 1];
            if (col < first or col > last) continue;
            const uri = text[begin..end];
            std.mem.copyForwards(u8, buffer[0..uri.len], uri);
            return .{ .start = first, .end = last + 1, .uri = buffer[0..uri.len] };
        }
    }
    return null;
}

/// Length without trailing punctuation and closing brackets that have no
/// opening one inside the address.
fn trim(uri: []const u8) usize {
    var end = uri.len;
    while (end > 0) {
        const last = uri[end - 1];
        switch (last) {
            '.', ',', ';', ':', '!', '?', '\'', '*' => end -= 1,
            ')', ']' => {
                const open: u8 = if (last == ')') '(' else '[';
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
    try std.testing.expect(at(cellsOf("xhttps://no", &cells), 5, &buffer) == null);
}
