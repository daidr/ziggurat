//! Line numbers in a gutter before each side's text, and the segments a
//! comparison of parts of two files shows, as a patch's hunks: each side's
//! records numbered as the lines of the file they are, a line over the
//! first record of each segment but the first.
const std = @import("std");

pub const Side = enum(u1) { a, b };

/// Which line of the file each record of a side is, from 0, and whether a
/// record starts a segment. `context` must outlive the parameters using it.
pub const Numbering = struct {
    context: *const anyopaque,
    line: *const fn (*const anyopaque, Side, usize) usize,
    starts: ?*const fn (*const anyopaque, Side, usize) bool = null,
    /// The header of the segment a record is in, as a patch's hunk header
    /// (`@@ -12,7 +12,8 @@ func main`), shown in a band over its first
    /// row; null shows none.
    header: ?*const fn (*const anyopaque, Side, usize) ?[]const u8 = null,

    pub fn lineOf(self: Numbering, side: Side, record: usize) usize {
        return self.line(self.context, side, record);
    }
    pub fn startsSegment(self: Numbering, side: Side, record: usize) bool {
        const starts = self.starts orelse return false;
        return starts(self.context, side, record);
    }
    pub fn headerOf(self: Numbering, side: Side, record: usize) ?[]const u8 {
        const header = self.header orelse return null;
        return header(self.context, side, record);
    }
};

/// The segments of two texts made of parts of two files, as the hunks of
/// a patch (`code_editor.patch.Partial`: `old_starts`, `new_starts`,
/// `old_file`, `new_file`): the record of each text each segment starts
/// at, ascending, and the line of its file that record is, from 0.
pub const Segments = struct {
    a_starts: []const usize,
    b_starts: []const usize,
    a_lines: []const usize,
    b_lines: []const usize,
    /// Each segment's header, as `Partial.headers`; empty shows none.
    headers: []const []const u8 = &.{},

    /// Numbers the records as their files' lines. The Segments must stay
    /// at this address while the numbering is used.
    pub fn numbering(self: *const Segments) Numbering {
        return .{ .context = self, .line = lineFn, .starts = startsFn, .header = if (self.headers.len > 0) headerFn else null };
    }
    /// The line of the file record `record` of `side` is, from 0.
    pub fn line(self: *const Segments, side: Side, record: usize) usize {
        const firsts = if (side == .a) self.a_starts else self.b_starts;
        const lines = if (side == .a) self.a_lines else self.b_lines;
        const segment = segmentOf(firsts, record) orelse return record;
        return lines[segment] + (record - firsts[segment]);
    }
    /// Whether record `record` of `side` starts a segment after the first.
    pub fn starts(self: *const Segments, side: Side, record: usize) bool {
        const list = if (side == .a) self.a_starts else self.b_starts;
        for (list[@min(1, list.len)..]) |start| if (start == record) return true;
        return false;
    }
    /// The header of the segment record `record` of `side` is in.
    pub fn headerOf(self: *const Segments, side: Side, record: usize) ?[]const u8 {
        const segment = segmentOf(if (side == .a) self.a_starts else self.b_starts, record) orelse return null;
        return if (segment < self.headers.len) self.headers[segment] else null;
    }
    fn headerFn(context: *const anyopaque, side: Side, record: usize) ?[]const u8 {
        const self: *const Segments = @ptrCast(@alignCast(context));
        return self.headerOf(side, record);
    }
    fn lineFn(context: *const anyopaque, side: Side, record: usize) usize {
        const self: *const Segments = @ptrCast(@alignCast(context));
        return self.line(side, record);
    }
    fn startsFn(context: *const anyopaque, side: Side, record: usize) bool {
        const self: *const Segments = @ptrCast(@alignCast(context));
        return self.starts(side, record);
    }
};

/// The segment record `record` is in: the last that starts at or before
/// it, or null before the first.
fn segmentOf(starts: []const usize, record: usize) ?usize {
    var low: usize = 0;
    var high = starts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] <= record) low = middle + 1 else high = middle;
    }
    return if (low == 0) null else low - 1;
}

/// The decimal digits of `value`, at least one.
pub fn digits(value: usize) usize {
    var count: usize = 1;
    var rest = value;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

/// The width of a gutter showing numbers of `count` digits in a font of
/// `size` DIP, with room on both sides.
pub fn width(count: usize, size: f32) f32 {
    return @as(f32, @floatFromInt(@max(count, 2))) * size * advance + size;
}
/// The advance of a digit, as a share of the font size: digits are as
/// wide as each other in the fonts that set code.
pub const advance: f32 = 0.62;

test "segments number their records as the lines of the files they are" {
    const segments: Segments = .{ .a_starts = &.{ 0, 3 }, .b_starts = &.{ 0, 4 }, .a_lines = &.{ 9, 40 }, .b_lines = &.{ 9, 41 } };
    try std.testing.expectEqual(@as(usize, 9), segments.line(.a, 0));
    try std.testing.expectEqual(@as(usize, 11), segments.line(.a, 2));
    try std.testing.expectEqual(@as(usize, 40), segments.line(.a, 3));
    try std.testing.expectEqual(@as(usize, 12), segments.line(.b, 3));
    try std.testing.expectEqual(@as(usize, 42), segments.line(.b, 5));
    const numbering = segments.numbering();
    try std.testing.expect(!numbering.startsSegment(.a, 0));
    try std.testing.expect(numbering.startsSegment(.a, 3));
    try std.testing.expect(!numbering.startsSegment(.a, 4));
    try std.testing.expect(numbering.startsSegment(.b, 4));
    try std.testing.expectEqual(@as(usize, 42), numbering.lineOf(.b, 5));
    try std.testing.expect(numbering.headerOf(.a, 2) == null);
    const headed: Segments = .{ .a_starts = segments.a_starts, .b_starts = segments.b_starts, .a_lines = segments.a_lines, .b_lines = segments.b_lines, .headers = &.{ "@@ -10,3 +10,4 @@", "@@ -41,2 +42,2 @@ fn f()" } };
    try std.testing.expectEqualStrings("@@ -10,3 +10,4 @@", headed.numbering().headerOf(.a, 2).?);
    try std.testing.expectEqualStrings("@@ -41,2 +42,2 @@ fn f()", headed.numbering().headerOf(.b, 4).?);
    try std.testing.expectEqual(@as(usize, 1), digits(0));
    try std.testing.expectEqual(@as(usize, 3), digits(100));
    try std.testing.expect(width(3, 10) > width(2, 10));
}
