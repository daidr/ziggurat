//! Moving a shell's cursor to a cell clicked on the command it is editing:
//! the arrow keys that take it there, counted over the rows the prompt and
//! its input take, as the shell holds them.

const std = @import("std");
const screen_module = @import("screen.zig");
const Screen = screen_module.Screen;
const Cell = screen_module.Cell;

/// A row of the prompt and its input: its cells, whether it soft-wraps into
/// the next, and how many columns its text takes (blanks after it are not
/// the input's).
pub const Row = struct {
    cells: []const Cell,
    wrap: bool,
    end: usize,

    pub fn init(cells: []const Cell, wrap: bool) Row {
        var end: usize = 0;
        for (cells, 0..) |cell, x| {
            if (cell.wide != .spacer and cell.cp != 0 and cell.cp != ' ') end = x + 1;
        }
        return .{ .cells = cells, .wrap = wrap, .end = end };
    }
};

/// The arrows from column `cx` of `rows[cy]` to column `col` of `rows[row]`:
/// a direction and how many characters lie between, counted over the rows
/// between as the shell holds them, a row's text and the line break after
/// it unless it soft-wraps (its blanks then too). A click past the end of a
/// row's text moves to its end and no further, as a Right arrow at the end
/// of the input would accept a shell's suggestion (zsh-autosuggestions,
/// fish).
pub fn steps(rows: []const Row, cx: usize, cy: usize, col: usize, row: usize) isize {
    return offset(rows, cx, cy, col, row) - offset(rows, cx, cy, cx, cy);
}

/// How many columns of row `y` the shell's text takes: all when it wraps,
/// and up to the cursor on the cursor's row, where blanks typed before it
/// are text.
fn rowEnd(rows: []const Row, cx: usize, cy: usize, y: usize) usize {
    const r = rows[y];
    if (r.wrap) return std.math.maxInt(usize);
    if (y == cy) return @max(r.end, cx);
    return r.end;
}

/// The characters before column `x` of row `y`.
fn offset(rows: []const Row, cx: usize, cy: usize, x: usize, y: usize) isize {
    var n: isize = 0;
    for (rows[0..y], 0..) |r, i| {
        n += characters(r.cells, rowEnd(rows, cx, cy, i));
        if (!r.wrap) n += 1; // the line break
    }
    n += characters(rows[y].cells, @min(x, rowEnd(rows, cx, cy, y)));
    return n;
}

/// The characters that start before column `end`: a wide one counts once.
fn characters(cells: []const Cell, end: usize) isize {
    var n: isize = 0;
    for (cells[0..@min(end, cells.len)]) |cell| {
        if (cell.wide != .spacer) n += 1;
    }
    return n;
}

/// Write the arrow keys for `count` steps (Right when positive, Left when
/// negative), the application's (`ESC O`) when the shell set DECCKM, the
/// normal ones (`CSI`) otherwise, to `send` in pieces.
pub fn sendArrows(count: isize, application: bool, context: anytype, comptime send: fn (@TypeOf(context), []const u8) anyerror!void) !void {
    const key: u8 = if (count < 0) 'D' else 'C';
    const arrow = [3]u8{ 0x1b, if (application) 'O' else '[', key };
    var buffer: [3 * 128]u8 = undefined;
    var left = @abs(count);
    while (left > 0) {
        const n: usize = @intCast(@min(left, buffer.len / 3));
        for (0..n) |i| @memcpy(buffer[i * 3 ..][0..3], &arrow);
        try send(context, buffer[0 .. n * 3]);
        left -= n;
    }
}

fn testRows(screen: *const Screen, top: usize, bottom: usize, out: []Row) []Row {
    for (top..bottom + 1, 0..) |y, i| out[i] = .init(screen.row(y), screen.wrapped(y));
    return out[0 .. bottom - top + 1];
}

fn testScreen(cols: u16, bytes: []const u8) !Screen {
    var s = try Screen.init(std.testing.allocator, .{ .cols = cols, .rows = 6 });
    for (bytes) |b| switch (b) {
        '\n' => {
            s.carriageReturn();
            s.lineFeed();
        },
        else => s.print(b),
    };
    return s;
}

test "arrows move within a row and stop at the end of its text" {
    var s = try testScreen(20, "$ echo hi");
    defer s.deinit();
    var storage: [4]Row = undefined;
    const rows = testRows(&s, 0, 0, &storage);
    // The cursor is after "hi" (column 9).
    try std.testing.expectEqual(@as(isize, -7), steps(rows, 9, 0, 2, 0));
    try std.testing.expectEqual(@as(isize, 0), steps(rows, 9, 0, 15, 0));
    // From the start of "echo", past the end stops at the end.
    try std.testing.expectEqual(@as(isize, 7), steps(rows, 2, 0, 18, 0));
}

test "arrows count over the rows a long command wraps onto" {
    var s = try testScreen(10, "$ abcdefghijklmno");
    defer s.deinit();
    var storage: [4]Row = undefined;
    const rows = testRows(&s, 0, 1, &storage);
    try std.testing.expect(rows[0].wrap);
    // The cursor is at column 7 of the second row; column 3 of the first
    // is "b".
    try std.testing.expectEqual(@as(isize, -14), steps(rows, 7, 1, 3, 0));
    try std.testing.expectEqual(@as(isize, 14), steps(rows, 3, 0, 7, 1));
}

test "arrows cross the line breaks of a multiline command" {
    var s = try testScreen(20, "$ if true\n> then");
    defer s.deinit();
    var storage: [4]Row = undefined;
    const rows = testRows(&s, 0, 1, &storage);
    // From the end of "then" to after "if": "then" and "> " (6), the line
    // break, then " true" (5).
    try std.testing.expectEqual(@as(isize, -12), steps(rows, 6, 1, 4, 0));
    // A click past the end of the first row stops at its end, before the
    // line break.
    try std.testing.expectEqual(@as(isize, -7), steps(rows, 6, 1, 15, 0));
}

test "a wide character takes one arrow" {
    var s = try testScreen(20, "$ ");
    defer s.deinit();
    s.print(0x4e2d); // a wide character
    s.print('x');
    var storage: [1]Row = undefined;
    const rows = testRows(&s, 0, 0, &storage);
    try std.testing.expectEqual(@as(isize, -2), steps(rows, 5, 0, 2, 0));
    try std.testing.expectEqual(@as(isize, -1), steps(rows, 5, 0, 4, 0));
}

test "arrows go out as the cursor keys' mode asks" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const Sink = struct {
        list: *std.ArrayList(u8),
        fn send(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(std.testing.allocator, bytes);
        }
    };
    try sendArrows(-2, false, Sink{ .list = &out }, Sink.send);
    try sendArrows(1, true, Sink{ .list = &out }, Sink.send);
    try std.testing.expectEqualStrings("\x1b[D\x1b[D\x1bOC", out.items);
    out.clearRetainingCapacity();
    try sendArrows(300, false, Sink{ .list = &out }, Sink.send);
    try std.testing.expectEqual(@as(usize, 900), out.items.len);
}
