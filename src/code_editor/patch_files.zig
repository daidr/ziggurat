//! A patch shown with the files it was made from: the comparison a diff
//! view displays (`document_diff_view.Inbox.publish`) whose changes are the
//! patch's runs of - and + lines, as `git diff` aligned them with its own
//! options (`--patience`, `--histogram`), not what comparing the texts
//! would find. The unchanged lines between them are ordinary common lines,
//! so they collapse and expand as in any comparison, numbered as the
//! files' lines. `recompare` follows an edit of the new file, comparing
//! again only the lines around it, so git's other changes stay as it found
//! them.
const std = @import("std");
const document = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");
const patch = @import("patch.zig");

/// The comparison of the files `a` and `b` whose changes are `file`'s runs
/// of - and + lines. It fails, and makes nothing, when the patch is binary
/// (`error.BinaryPatch`) or does not make `b` from `a`
/// (`error.PatchMismatch`, or `apply`'s errors): the files moved on since
/// the patch, so show its hunks alone (`patch.Partial`). Use it in place of
/// `diff.compare` with a Job's two Readers. The caller owns the result.
pub fn compareFiles(allocator: std.mem.Allocator, file: patch.FilePatch, a: document.Reader, b: document.Reader) !diff.Result {
    if (file.binary) return error.BinaryPatch;
    const old = try readAll(allocator, a);
    defer allocator.free(old);
    const new = try readAll(allocator, b);
    defer allocator.free(new);
    const made = try file.apply(allocator, old);
    defer allocator.free(made);
    if (!std.mem.eql(u8, made, new)) return error.PatchMismatch;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    for (file.hunks) |hunk| try patchRuns(allocator, &runs, hunk, hunkLine(hunk.old_start, hunk.old_lines), hunkLine(hunk.new_start, hunk.new_lines));
    return result(allocator, runs.items, old, new, a, b);
}

/// The comparison of `a` and `b` after an edit of the new file, from
/// `previous`, the comparison of `a` with `previous_b`, the new file before
/// the edit: the lines `previous_b` and `b` differ in, with a few unchanged
/// lines around them and the changes they touch, are compared again, and
/// the other changes move with the edit, as git found them. The caller
/// owns the result.
pub fn recompare(allocator: std.mem.Allocator, previous: *const diff.Result, a: document.Reader, previous_b: document.Reader, b: document.Reader) !diff.Result {
    const old = try readAll(allocator, a);
    defer allocator.free(old);
    const before = try readAll(allocator, previous_b);
    defer allocator.free(before);
    const new = try readAll(allocator, b);
    defer allocator.free(new);
    const old_lines = try lineStarts(allocator, old);
    defer allocator.free(old_lines);
    const before_lines = try lineStarts(allocator, before);
    defer allocator.free(before_lines);
    const new_lines = try lineStarts(allocator, new);
    defer allocator.free(new_lines);
    const n_before = before_lines.len - 1;
    const n_new = new_lines.len - 1;
    // The lines the edit changed: before[from..before_to] became
    // new[from..new_to].
    var from: usize = 0;
    while (from < @min(n_before, n_new) and std.mem.eql(u8, line(before, before_lines, from), line(new, new_lines, from))) from += 1;
    var tail: usize = 0;
    while (tail < n_before - from and tail < n_new - from and std.mem.eql(u8, line(before, before_lines, n_before - 1 - tail), line(new, new_lines, n_new - 1 - tail))) tail += 1;
    // Grow the lines compared again by a few around the edit, and until no
    // change in them crosses their edges, in the new file before the edit.
    var low = from -| pad;
    var high = @min(n_before, n_before - tail + pad);
    var grown = true;
    while (grown) {
        grown = false;
        for (previous.hunks) |hunk| if (place(hunk, low, high) == .inside and (hunk.b.lines.start < low or hunk.b.lines.end > high)) {
            low = @min(low, hunk.b.lines.start);
            high = @max(high, hunk.b.lines.end);
            grown = true;
        };
    }
    // The old lines the window pairs with, and how far the lines after it move.
    var before_offset: isize = 0;
    var through_offset: isize = 0;
    for (previous.hunks) |hunk| {
        const change = @as(isize, @intCast(hunk.a.lines.end - hunk.a.lines.start)) - @as(isize, @intCast(hunk.b.lines.end - hunk.b.lines.start));
        switch (place(hunk, low, high)) {
            .before => {
                before_offset += change;
                through_offset += change;
            },
            .inside => through_offset += change,
            .after => {},
        }
    }
    const moved: isize = @as(isize, @intCast(n_new)) - @as(isize, @intCast(n_before));
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    for (previous.hunks) |hunk| if (place(hunk, low, high) == .before) try runs.append(allocator, .{ .a = hunk.a.lines, .b = hunk.b.lines });
    try compareLines(allocator, &runs, old, old_lines, shift(low, before_offset), shift(high, through_offset), new, new_lines, low, shift(high, moved));
    for (previous.hunks) |hunk| if (place(hunk, low, high) == .after) try runs.append(allocator, .{ .a = hunk.a.lines, .b = .{ .start = shift(hunk.b.lines.start, moved), .end = shift(hunk.b.lines.end, moved) } });
    return result(allocator, runs.items, old, new, a, b);
}

/// How many unchanged lines around an edit `recompare` compares again.
const pad = 3;

const Run = struct { a: diff.LineRange, b: diff.LineRange };

/// The line, from 0, a hunk's side starts at, from its start and count in
/// the header: a side of no lines names the line before where it is.
fn hunkLine(start: usize, count: usize) usize {
    return if (count == 0) start else start -| 1;
}

/// Append the changes of `hunk`, its runs of - and + lines, whose first
/// lines are lines `old_line` and `new_line` of the files.
fn patchRuns(allocator: std.mem.Allocator, runs: *std.ArrayList(Run), hunk: patch.Hunk, old_line: usize, new_line: usize) !void {
    var old_at = old_line;
    var new_at = new_line;
    var open = false;
    for (hunk.lines) |text| {
        if (text.len == 0 or text[0] == '\\') continue;
        const changed = text[0] == '-' or text[0] == '+';
        if (!changed) open = false else if (!open) {
            try runs.append(allocator, .{ .a = .{ .start = old_at, .end = old_at }, .b = .{ .start = new_at, .end = new_at } });
            open = true;
        }
        if (text[0] != '+') old_at += 1;
        if (text[0] != '-') new_at += 1;
        if (open) {
            const run = &runs.items[runs.items.len - 1];
            if (text[0] == '-') run.a.end += 1 else run.b.end += 1;
        }
    }
}

/// Where a change is from new lines `low..high` compared again: a change
/// with no new lines at either edge is inside, as are those meeting them.
fn place(hunk: diff.Hunk, low: usize, high: usize) enum { before, inside, after } {
    const start = hunk.b.lines.start;
    const end = hunk.b.lines.end;
    if (end < low or (end == low and start < low)) return .before;
    if (start > high or (start == high and end > high)) return .after;
    return .inside;
}

fn shift(value: usize, by: isize) usize {
    return @intCast(@as(isize, @intCast(value)) + by);
}

/// Append the changes between old lines `old_from..old_to` and new lines
/// `new_from..new_to`, compared with their line feeds: a longest common
/// subsequence, deletions before insertions in each run.
fn compareLines(allocator: std.mem.Allocator, runs: *std.ArrayList(Run), old: []const u8, old_lines: []const usize, old_from: usize, old_to: usize, new: []const u8, new_lines: []const usize, new_from: usize, new_to: usize) !void {
    var a0 = old_from;
    var b0 = new_from;
    var a1 = old_to;
    var b1 = new_to;
    while (a0 < a1 and b0 < b1 and std.mem.eql(u8, line(old, old_lines, a0), line(new, new_lines, b0))) {
        a0 += 1;
        b0 += 1;
    }
    while (a1 > a0 and b1 > b0 and std.mem.eql(u8, line(old, old_lines, a1 - 1), line(new, new_lines, b1 - 1))) {
        a1 -= 1;
        b1 -= 1;
    }
    const n = a1 - a0;
    const m = b1 - b0;
    if (n == 0 and m == 0) return;
    if (n == 0 or m == 0 or (n + 1) * (m + 1) > max_cells) {
        try runs.append(allocator, .{ .a = .{ .start = a0, .end = a1 }, .b = .{ .start = b0, .end = b1 } });
        return;
    }
    // table[i][j]: the longest common lines of old[a0+i..] and new[b0+j..].
    const width = m + 1;
    const table = try allocator.alloc(u32, (n + 1) * width);
    defer allocator.free(table);
    @memset(table, 0);
    var i = n;
    while (i > 0) {
        i -= 1;
        var j = m;
        while (j > 0) {
            j -= 1;
            table[i * width + j] = if (std.mem.eql(u8, line(old, old_lines, a0 + i), line(new, new_lines, b0 + j))) table[(i + 1) * width + j + 1] + 1 else @max(table[(i + 1) * width + j], table[i * width + j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    var open = false;
    while (i < n or j < m) {
        if (i < n and j < m and std.mem.eql(u8, line(old, old_lines, a0 + i), line(new, new_lines, b0 + j))) {
            open = false;
            i += 1;
            j += 1;
            continue;
        }
        if (!open) {
            try runs.append(allocator, .{ .a = .{ .start = a0 + i, .end = a0 + i }, .b = .{ .start = b0 + j, .end = b0 + j } });
            open = true;
        }
        const run = &runs.items[runs.items.len - 1];
        if (i < n and (j == m or table[(i + 1) * width + j] >= table[i * width + j + 1])) {
            i += 1;
            run.a.end = a0 + i;
        } else {
            j += 1;
            run.b.end = b0 + j;
        }
    }
}
/// The most lines compared against each other in one window; more are one change.
const max_cells = 4 * 1024 * 1024;

/// Text of record `index`, with its line feed.
fn line(text: []const u8, starts: []const usize, index: usize) []const u8 {
    return text[starts[index]..starts[index + 1]];
}

/// The byte each record of `text` starts at, as `diff.compare` counts
/// them (no record after a final newline), and the text's length last.
fn lineStarts(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);
    for (text, 0..) |byte, at| if (byte == '\n') try starts.append(allocator, at + 1);
    if (starts.items[starts.items.len - 1] != text.len) try starts.append(allocator, text.len);
    return starts.toOwnedSlice(allocator);
}

fn readAll(allocator: std.mem.Allocator, reader: document.Reader) ![]u8 {
    const length = try reader.byteLength();
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    _ = try reader.read(.{ .start = 0, .end = length }, bytes);
    return bytes;
}

fn result(allocator: std.mem.Allocator, runs: []const Run, old: []const u8, new: []const u8, a: document.Reader, b: document.Reader) !diff.Result {
    const old_lines = try lineStarts(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try lineStarts(allocator, new);
    defer allocator.free(new_lines);
    const hunks = try allocator.alloc(diff.Hunk, runs.len);
    errdefer allocator.free(hunks);
    for (runs, hunks) |run, *hunk| {
        if (run.a.end >= old_lines.len or run.b.end >= new_lines.len) return error.PatchMismatch;
        hunk.* = .{ .a = .{ .lines = run.a, .bytes = .{ .start = old_lines[run.a.start], .end = old_lines[run.a.end] } }, .b = .{ .lines = run.b, .bytes = .{ .start = new_lines[run.b.start], .end = new_lines[run.b.end] } } };
    }
    return .{
        .allocator = allocator,
        .storage = hunks,
        .hunks = hunks,
        .a = .{ .revision = try a.version(), .text_version = try a.committedTextVersion(), .bytes = old.len },
        .b = .{ .revision = try b.version(), .text_version = try b.committedTextVersion(), .bytes = new.len },
        .stats = .{ .lines_a = old_lines.len - 1, .lines_b = new_lines.len - 1 },
    };
}

const Texts = struct {
    documents: [2]*document.Document,
    snapshots: [2]*document.Snapshot,
    readers: [2]document.Reader,
    fn init(old: []const u8, new: []const u8) !Texts {
        const allocator = std.testing.allocator;
        var self: Texts = undefined;
        for ([_][]const u8{ old, new }, 0..) |text, i| {
            self.documents[i] = try document.Document.create(allocator, std.Thread.getCurrentId(), text, .{});
            self.snapshots[i] = try self.documents[i].snapshot();
            self.readers[i] = try self.snapshots[i].borrowReader();
        }
        return self;
    }
    fn deinit(self: Texts) void {
        for (0..2) |i| {
            self.readers[i].release() catch unreachable;
            self.snapshots[i].close() catch unreachable;
            self.documents[i].close() catch unreachable;
        }
    }
};
fn expectChanges(expected: []const [4]usize, got: diff.Result) !void {
    try std.testing.expectEqual(expected.len, got.hunks.len);
    for (expected, got.hunks) |want, hunk| try std.testing.expectEqual(want, [4]usize{ hunk.a.lines.start, hunk.a.lines.end, hunk.b.lines.start, hunk.b.lines.end });
}
fn parsed(text: []const u8) !patch.Patch {
    return patch.parse(std.testing.allocator, text, null);
}

test "a patch with its files has git's runs as its changes" {
    // Comparing the texts would delete the second "x"; git deleted the first.
    var file = try parsed("--- a/x.txt\n+++ b/x.txt\n@@ -1,4 +1,2 @@\n-x\n-y\n x\n z\n");
    defer file.deinit();
    const texts = try Texts.init("x\ny\nx\nz\n", "x\nz\n");
    defer texts.deinit();
    var got = try compareFiles(std.testing.allocator, file.files[0], texts.readers[0], texts.readers[1]);
    defer got.deinit();
    try expectChanges(&.{.{ 0, 2, 0, 0 }}, got);
    try std.testing.expectEqual(document.Range{ .start = 0, .end = 4 }, got.hunks[0].a.bytes);
    try std.testing.expectEqual(@as(usize, 4), got.stats.lines_a);
    try std.testing.expectEqual(@as(usize, 2), got.stats.lines_b);
}

test "a patch with its files places sides of no lines after the line their header names" {
    const cases = [_]struct { patch: []const u8, old: []const u8, new: []const u8, want: []const [4]usize }{
        .{ .patch = "--- /dev/null\n+++ b/x.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n", .old = "", .new = "a\nb\n", .want = &.{.{ 0, 0, 0, 2 }} },
        .{ .patch = "--- a/x.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n", .old = "a\nb\n", .new = "", .want = &.{.{ 0, 2, 0, 0 }} },
        .{ .patch = "--- a/x.txt\n+++ b/x.txt\n@@ -2 +1,0 @@\n-b\n@@ -3,0 +3 @@\n+d\n", .old = "a\nb\nc\n", .new = "a\nc\nd\n", .want = &.{ .{ 1, 2, 1, 1 }, .{ 3, 3, 2, 3 } } },
    };
    for (cases) |case| {
        var file = try parsed(case.patch);
        defer file.deinit();
        const texts = try Texts.init(case.old, case.new);
        defer texts.deinit();
        var got = try compareFiles(std.testing.allocator, file.files[0], texts.readers[0], texts.readers[1]);
        defer got.deinit();
        try expectChanges(case.want, got);
    }
}

test "a patch of other files, or a binary one, makes no comparison" {
    var file = try parsed("--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n");
    defer file.deinit();
    for ([_][2][]const u8{ .{ "something else\n", "a\nc\n" }, .{ "a\nb\n", "a\nc\nmore\n" } }) |pair| {
        const texts = try Texts.init(pair[0], pair[1]);
        defer texts.deinit();
        if (compareFiles(std.testing.allocator, file.files[0], texts.readers[0], texts.readers[1])) |value| {
            var made = value;
            made.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const texts = try Texts.init("a", "b");
    defer texts.deinit();
    try std.testing.expectError(error.BinaryPatch, compareFiles(std.testing.allocator, .{ .new_name = "x.png", .binary = true }, texts.readers[0], texts.readers[1]));
}

test "an edit of the new file keeps git's other changes" {
    const tail = comptime blk: {
        var text: [200]u8 = undefined;
        for (0..40) |i| text[i * 5 ..][0..5].* = "same\n".*;
        break :blk text;
    };
    var file = try parsed("--- a/x.txt\n+++ b/x.txt\n@@ -1,5 +1,3 @@\n-x\n-y\n x\n z\n same\n");
    defer file.deinit();
    const texts = try Texts.init("x\ny\nx\nz\n" ++ tail, "x\nz\n" ++ tail);
    defer texts.deinit();
    var first = try compareFiles(std.testing.allocator, file.files[0], texts.readers[0], texts.readers[1]);
    defer first.deinit();
    const edited = try Texts.init("", "x\nz\n" ++ tail ++ "added\n");
    defer edited.deinit();
    var got = try recompare(std.testing.allocator, &first, texts.readers[0], texts.readers[1], edited.readers[1]);
    defer got.deinit();
    try expectChanges(&.{ .{ 0, 2, 0, 0 }, .{ 44, 44, 42, 43 } }, got);
    // An edit inside git's change compares the lines around it again.
    const inside = try Texts.init("", "x\nZ\n" ++ tail);
    defer inside.deinit();
    var again = try recompare(std.testing.allocator, &first, texts.readers[0], texts.readers[1], inside.readers[1]);
    defer again.deinit();
    try expectChanges(&.{.{ 1, 4, 1, 2 }}, again);
}
