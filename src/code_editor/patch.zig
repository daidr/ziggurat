//! Unified diffs, as `git diff`, `git format-patch` and `diff -u` print
//! them: `parse` reads the files a diff changes, with renames, modes and
//! new and deleted files; `FilePatch.apply` applies one to the old file's
//! text; `Partial` makes the texts a diff view shows of a patch without the
//! files, as a pull request's diff arrives: its hunks' lines one after
//! another, numbered as in the files, each hunk under its header. Each
//! hunk is highlighted on its own, from the start of its first line, as
//! `git diff` colors it (`Partial.old_starts` and `new_starts` are the
//! highlighter's restarts, `syntax.Highlighter.setRestarts`), so that a
//! comment or a string the hunk before ends in does not go on into it.
//! The highlighter moves them with the edits since
//! (`syntax.Highlighter.restartLines`, `Highlighting.restarts`), so that
//! highlighting of the host's own can start the hunks as well. With the
//! files too, `compareFiles` makes the comparison a diff view shows of
//! them whose changes are the patch's.
const std = @import("std");
const patch_files = @import("patch_files.zig");

/// The comparison of a patch's files whose changes are its runs of - and +
/// lines, as git aligned them, and the comparison after an edit of the new
/// file that keeps them (`patch_files.zig`).
pub const compareFiles = patch_files.compareFiles;
pub const recompare = patch_files.recompare;

test {
    _ = patch_files;
}

/// A hunk of a `FilePatch`: lines from `old_start` (from 1) of the old file,
/// `old_lines` of them, and `new_start` and `new_lines` of the new.
pub const Hunk = struct {
    old_start: usize,
    old_lines: usize,
    new_start: usize,
    new_lines: usize,
    /// What follows the second @@, as the function the hunk is in.
    section: []const u8 = "",
    /// The hunk's lines with their first character: a space for a line of
    /// both, - for one deleted, + for one added. A line "\ No newline at
    /// end of file" follows the line it is about.
    lines: []const []const u8 = &.{},
};

/// The change of one file in a unified diff.
pub const FilePatch = struct {
    /// The file's names before and after, without git's a/ and b/;
    /// `old_name` is empty for a file added, `new_name` for one deleted.
    old_name: []const u8 = "",
    new_name: []const u8 = "",
    /// git's file modes, as "100644", when given.
    old_mode: []const u8 = "",
    new_mode: []const u8 = "",
    /// A change git shows no lines of.
    binary: bool = false,
    hunks: []const Hunk = &.{},

    /// The name to pick a language by: the new one, else the old.
    pub fn name(self: FilePatch) []const u8 {
        return if (self.new_name.len > 0) self.new_name else self.old_name;
    }

    /// Apply the patch to the old file's text and return the new file's,
    /// checking that the lines of both and those deleted are there. The
    /// caller owns the result.
    pub fn apply(self: FilePatch, allocator: std.mem.Allocator, old: []const u8) ![]u8 {
        if (self.binary) return error.BinaryPatch;
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(allocator);
        var eol = true;
        if (old.len > 0) {
            var it = std.mem.splitScalar(u8, old, '\n');
            while (it.next()) |line| try lines.append(allocator, line);
            if (lines.items[lines.items.len - 1].len == 0) _ = lines.pop() else eol = false;
        }
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(allocator);
        var at: usize = 0;
        // Whether the new text ends with a newline: as the old does, unless
        // a hunk reaching the end says.
        var new_eol = eol;
        var touched_end = false;
        for (self.hunks) |hunk| {
            const start = if (hunk.old_lines == 0) hunk.old_start else hunk.old_start -| 1;
            if (start < at or start > lines.items.len) return error.HunkOutOfPlace;
            try out.appendSlice(allocator, lines.items[at..start]);
            at = start;
            var last_new: ?usize = null;
            for (hunk.lines, 0..) |line, k| {
                if (line.len == 0 or line[0] == '\\') continue;
                if (line[0] != '+') {
                    if (at >= lines.items.len or !std.mem.eql(u8, lines.items[at], line[1..])) return error.HunkMismatch;
                    at += 1;
                }
                if (line[0] != '-') {
                    try out.append(allocator, line[1..]);
                    last_new = k;
                }
            }
            if (at == lines.items.len) {
                touched_end = true;
                new_eol = if (last_new) |k| !(k + 1 < hunk.lines.len and std.mem.startsWith(u8, hunk.lines[k + 1], "\\")) else true;
            }
        }
        try out.appendSlice(allocator, lines.items[at..]);
        if (!touched_end) new_eol = eol;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        for (out.items, 0..) |line, index| {
            if (index > 0) try result.append(allocator, '\n');
            try result.appendSlice(allocator, line);
        }
        if (new_eol and out.items.len > 0) try result.append(allocator, '\n');
        return result.toOwnedSlice(allocator);
    }
};

/// Files a diff changes, in the arena that holds them.
pub const Patch = struct {
    arena: std.heap.ArenaAllocator,
    files: []const FilePatch,

    pub fn deinit(self: *Patch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Where `parse` stopped: the line, from 1, of the diff it could not read.
pub const Diagnostic = struct { line: usize = 0 };

/// Read the files a unified diff changes, in order. The patch keeps copies
/// of what it needs from `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, diagnostic: ?*Diagnostic) !Patch {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Lines split at \n alone: the lines of a file with \r\n endings keep
    // their \r, as apply needs, and only the headers lose it.
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, try a.dupe(u8, text), '\n');
    while (split.next()) |line| try lines.append(a, line);
    var files: std.ArrayList(FilePatch) = .empty;
    var hunks: std.ArrayList(Hunk) = .empty;
    var current: ?*FilePatch = null;
    const all = lines.items;
    var i: usize = 0;
    errdefer if (diagnostic) |out| {
        out.line = i + 1;
    };
    while (i < all.len) : (i += 1) {
        const line = std.mem.trimEnd(u8, all[i], "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            current = try beginFile(a, &files, &hunks, current);
            if (gitNames(a, line["diff --git ".len..])) |names| {
                current.?.old_name = names[0];
                current.?.new_name = names[1];
            }
        } else if (current != null and std.mem.startsWith(u8, line, "new file mode ")) {
            current.?.old_name = "";
            current.?.new_mode = line["new file mode ".len..];
        } else if (current != null and std.mem.startsWith(u8, line, "deleted file mode ")) {
            current.?.new_name = "";
            current.?.old_mode = line["deleted file mode ".len..];
        } else if (current != null and std.mem.startsWith(u8, line, "old mode ")) {
            current.?.old_mode = line["old mode ".len..];
        } else if (current != null and std.mem.startsWith(u8, line, "new mode ")) {
            current.?.new_mode = line["new mode ".len..];
        } else if (current != null and (std.mem.startsWith(u8, line, "rename from ") or std.mem.startsWith(u8, line, "copy from "))) {
            current.?.old_name = unquote(a, line[std.mem.indexOf(u8, line, "from ").? + 5 ..]);
        } else if (current != null and (std.mem.startsWith(u8, line, "rename to ") or std.mem.startsWith(u8, line, "copy to "))) {
            current.?.new_name = unquote(a, line[std.mem.indexOf(u8, line, "to ").? + 3 ..]);
        } else if (current != null and (std.mem.startsWith(u8, line, "Binary files ") or std.mem.eql(u8, line, "GIT binary patch"))) {
            current.?.binary = true;
        } else if (std.mem.startsWith(u8, line, "--- ") and i + 1 < all.len and std.mem.startsWith(u8, all[i + 1], "+++ ")) {
            if (current == null or hunks.items.len > 0) current = try beginFile(a, &files, &hunks, current);
            const old = patchName(a, line[4..], "a/");
            if (old.len > 0 or current.?.old_name.len == 0) current.?.old_name = old;
            const new = patchName(a, std.mem.trimEnd(u8, all[i + 1], "\r")[4..], "b/");
            if (new.len > 0 or current.?.new_name.len == 0) current.?.new_name = new;
            i += 1;
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            if (current == null) current = try beginFile(a, &files, &hunks, current);
            var hunk = try parseHeader(line);
            const header = i;
            // The hunk's lines, as many as its header counts.
            var old_left: isize = @intCast(hunk.old_lines);
            var new_left: isize = @intCast(hunk.new_lines);
            var body: std.ArrayList([]const u8) = .empty;
            while (i + 1 < all.len and (old_left > 0 or new_left > 0 or std.mem.startsWith(u8, all[i + 1], "\\"))) {
                var next = all[i + 1];
                if (std.mem.startsWith(u8, next, "\\")) {} else if (std.mem.startsWith(u8, next, "+")) {
                    new_left -= 1;
                } else if (std.mem.startsWith(u8, next, "-")) {
                    old_left -= 1;
                } else if (std.mem.startsWith(u8, next, " ") or next.len == 0 or std.mem.eql(u8, next, "\r")) {
                    // An empty line is a blank line of both, as some tools
                    // strip the space.
                    if (!std.mem.startsWith(u8, next, " ")) next = try std.mem.concat(a, u8, &.{ " ", next });
                    old_left -= 1;
                    new_left -= 1;
                } else {
                    i += 1;
                    return error.UnexpectedLine;
                }
                i += 1;
                if (old_left < 0 or new_left < 0) return error.HunkTooLong;
                try body.append(a, next);
            }
            if (old_left > 0 or new_left > 0) {
                i = header;
                return error.HunkTooShort;
            }
            hunk.lines = body.items;
            try hunks.append(a, hunk);
        }
    }
    if (current) |file| file.hunks = hunks.items;
    return .{ .arena = arena, .files = files.items };
}

/// Begin a new file, giving the one before its hunks.
fn beginFile(a: std.mem.Allocator, files: *std.ArrayList(FilePatch), hunks: *std.ArrayList(Hunk), current: ?*FilePatch) !*FilePatch {
    if (current) |file| file.hunks = try hunks.toOwnedSlice(a);
    hunks.* = .empty;
    try files.append(a, .{});
    // Each file is kept by address until the next starts.
    return &files.items[files.items.len - 1];
}

fn parseHeader(line: []const u8) !Hunk {
    const rest = line[3..];
    const end = std.mem.indexOf(u8, rest, " @@") orelse return error.MalformedHunkHeader;
    var fields = std.mem.tokenizeAny(u8, rest[0..end], " \t");
    const old = fields.next() orelse return error.MalformedHunkHeader;
    const new = fields.next() orelse return error.MalformedHunkHeader;
    if (fields.next() != null or old[0] != '-' or new[0] != '+') return error.MalformedHunkHeader;
    const old_range = try hunkRange(old[1..]);
    const new_range = try hunkRange(new[1..]);
    return .{ .old_start = old_range[0], .old_lines = old_range[1], .new_start = new_range[0], .new_lines = new_range[1], .section = std.mem.trim(u8, rest[end + 3 ..], " \t") };
}
fn hunkRange(text: []const u8) ![2]usize {
    const comma = std.mem.indexOfScalar(u8, text, ',');
    const first = std.fmt.parseInt(usize, text[0 .. comma orelse text.len], 10) catch return error.MalformedHunkHeader;
    const count = if (comma) |at| std.fmt.parseInt(usize, text[at + 1 ..], 10) catch return error.MalformedHunkHeader else 1;
    return .{ first, count };
}

/// The names of "diff --git a/x b/x".
fn gitNames(a: std.mem.Allocator, text: []const u8) ?[2][]const u8 {
    // Names git quotes, as C strings, when they hold spaces, quotes or
    // characters past ASCII.
    if (std.mem.startsWith(u8, text, "\"")) {
        const end = quotedEnd(text) orelse return null;
        const old = unquote(a, text[0..end]);
        const new = unquote(a, std.mem.trimStart(u8, text[end..], " "));
        return .{ trimPrefix(old, "a/"), trimPrefix(new, "b/") };
    }
    if (std.mem.indexOf(u8, text, " \"b/")) |at| return .{ trimPrefix(text[0..at], "a/"), trimPrefix(unquote(a, text[at + 1 ..]), "b/") };
    // The names are equal but for their prefixes unless renamed, which
    // rename lines then tell.
    if (text.len % 2 == 1) {
        const old = text[0 .. text.len / 2];
        const new = text[text.len / 2 + 1 ..];
        if (std.mem.eql(u8, trimPrefix(old, "a/"), trimPrefix(new, "b/"))) return .{ trimPrefix(old, "a/"), trimPrefix(new, "b/") };
    }
    if (std.mem.indexOf(u8, text, " b/")) |at| return .{ trimPrefix(text[0..at], "a/"), text[at + 3 ..] };
    return null;
}
fn trimPrefix(text: []const u8, prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, prefix)) text[prefix.len..] else text;
}
/// The length of the quoted string `text` starts with, quotes included.
fn quotedEnd(text: []const u8) ?usize {
    var at: usize = 1;
    while (at < text.len) : (at += 1) switch (text[at]) {
        '\\' => at += 1,
        '"' => return at + 1,
        else => {},
    };
    return null;
}
/// Unquote a name git quoted as a C string, as "a/\346\226\207.txt";
/// others, and those that do not unquote, as they are.
fn unquote(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (text.len < 2 or text[0] != '"' or text[text.len - 1] != '"') return text;
    const out = a.alloc(u8, text.len) catch return text;
    var length: usize = 0;
    var at: usize = 1;
    while (at < text.len - 1) : (at += 1) {
        var c = text[at];
        if (c == '\\') {
            at += 1;
            if (at >= text.len - 1) return text;
            c = switch (text[at]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'a' => 0x07,
                'b' => 0x08,
                'f' => 0x0c,
                'v' => 0x0b,
                '0'...'7' => blk: {
                    if (at + 2 >= text.len - 1) return text;
                    const value = std.fmt.parseInt(u8, text[at .. at + 3], 8) catch return text;
                    at += 2;
                    break :blk value;
                },
                else => text[at],
            };
        }
        out[length] = c;
        length += 1;
    }
    return out[0..length];
}
/// The name of a --- or +++ line, "" for /dev/null.
fn patchName(a: std.mem.Allocator, text: []const u8, prefix: []const u8) []const u8 {
    var value = text;
    if (std.mem.indexOfScalar(u8, value, '\t')) |at| value = value[0..at];
    value = std.mem.trim(u8, value, " \t\r");
    if (std.mem.eql(u8, value, "/dev/null")) return "";
    return trimPrefix(unquote(a, value), prefix);
}

/// A side of a patch's run of - and + lines in the texts `Partial` makes,
/// lines `start..end`.
pub const Lines = struct { start: usize, end: usize };
pub const Change = struct { old: Lines, new: Lines };
pub const Side = enum { old, new };

/// The texts a diff view shows of a file's patch without the files: its
/// hunks' lines, one after another, not editable, and unchanged lines do
/// not collapse.
pub const Partial = struct {
    arena: std.heap.ArenaAllocator,
    old_text: []const u8,
    new_text: []const u8,
    /// The line of each text each hunk starts at, from 0: the lines that
    /// start in state 0 in the highlighter of the text.
    old_starts: []const usize,
    new_starts: []const usize,
    /// The line of the file each hunk starts at, from 0.
    old_file: []const usize,
    new_file: []const usize,
    /// Each hunk's header, as "@@ -1,3 +1,4 @@ func main()".
    headers: []const []const u8,
    /// The changes, the patch's runs of - and + lines as it says them, not
    /// what comparing the texts would find.
    changes: []const Change,
    /// Whether the old and the new file end without a newline, as the
    /// patch's "\ No newline at end of file" lines say of the line before
    /// them: a deleted line's the old file, an added line's the new, and a
    /// line of both both. The texts end without one either way, so a diff
    /// view marks these sides (`document_diff_view.Parameters.no_newline`).
    old_no_newline: bool = false,
    new_no_newline: bool = false,

    /// Which sides end without a newline, old then new.
    pub fn noNewline(self: *const Partial) [2]bool {
        return .{ self.old_no_newline, self.new_no_newline };
    }

    /// The texts of `patch`'s hunks' lines.
    pub fn init(allocator: std.mem.Allocator, patch: FilePatch) !Partial {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var old: std.ArrayList(u8) = .empty;
        var new: std.ArrayList(u8) = .empty;
        var old_starts: std.ArrayList(usize) = .empty;
        var new_starts: std.ArrayList(usize) = .empty;
        var old_file: std.ArrayList(usize) = .empty;
        var new_file: std.ArrayList(usize) = .empty;
        var headers: std.ArrayList([]const u8) = .empty;
        var changes: std.ArrayList(Change) = .empty;
        var old_line: usize = 0;
        var new_line: usize = 0;
        var old_no_newline = false;
        var new_no_newline = false;
        for (patch.hunks) |hunk| {
            var run: ?usize = null;
            var previous: u8 = 0;
            try old_starts.append(a, old_line);
            try new_starts.append(a, new_line);
            try old_file.append(a, hunk.old_start -| 1);
            try new_file.append(a, hunk.new_start -| 1);
            const header = try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{ hunk.old_start, hunk.old_lines, hunk.new_start, hunk.new_lines });
            try headers.append(a, if (hunk.section.len > 0) try std.mem.concat(a, u8, &.{ header, " ", hunk.section }) else header);
            for (hunk.lines) |line| {
                if (line.len > 0 and line[0] == '\\') {
                    old_no_newline = old_no_newline or previous == '-' or previous == ' ';
                    new_no_newline = new_no_newline or previous == '+' or previous == ' ';
                    continue;
                }
                if (line.len == 0) continue;
                previous = line[0];
                const changed = line[0] == '-' or line[0] == '+';
                if (!changed) run = null else if (run == null) {
                    try changes.append(a, .{ .old = .{ .start = old_line, .end = old_line }, .new = .{ .start = new_line, .end = new_line } });
                    run = changes.items.len - 1;
                }
                if (run) |index| {
                    if (line[0] == '-') changes.items[index].old.end += 1 else changes.items[index].new.end += 1;
                }
                const text = std.mem.trimEnd(u8, line[1..], "\r");
                if (line[0] != '+') {
                    if (old_line > 0) try old.append(a, '\n');
                    try old.appendSlice(a, text);
                    old_line += 1;
                }
                if (line[0] != '-') {
                    if (new_line > 0) try new.append(a, '\n');
                    try new.appendSlice(a, text);
                    new_line += 1;
                }
            }
        }
        return .{ .arena = arena, .old_text = old.items, .new_text = new.items, .old_starts = old_starts.items, .new_starts = new_starts.items, .old_file = old_file.items, .new_file = new_file.items, .headers = headers.items, .changes = changes.items, .old_no_newline = old_no_newline, .new_no_newline = new_no_newline };
    }
    pub fn deinit(self: *Partial) void {
        self.arena.deinit();
        self.* = undefined;
    }
    /// The line of the file, from 0, that line `line` of a side's text is.
    pub fn fileLine(self: *const Partial, side: Side, line: usize) usize {
        const starts = if (side == .old) self.old_starts else self.new_starts;
        const file = if (side == .old) self.old_file else self.new_file;
        if (starts.len == 0) return line;
        var k: usize = 0;
        while (k + 1 < starts.len and starts[k + 1] <= line) k += 1;
        return file[k] + line - starts[k];
    }
    /// The hunk line `line` of a side's text is in, and whether it is the
    /// hunk's first, which shows its header above it.
    pub fn hunkOf(self: *const Partial, side: Side, line: usize) struct { index: usize, first: bool } {
        const starts = if (side == .old) self.old_starts else self.new_starts;
        var k: usize = 0;
        while (k + 1 < starts.len and starts[k + 1] <= line) k += 1;
        return .{ .index = k, .first = starts.len > 0 and starts[k] == line };
    }
};

test "a git diff reads with renames, modes, new files and its hunks" {
    const text =
        \\diff --git a/old.go b/new.go
        \\similarity index 90%
        \\rename from old.go
        \\rename to new.go
        \\index 83db48f..bf269f4 100644
        \\--- a/old.go
        \\+++ b/new.go
        \\@@ -1,3 +1,4 @@ package main
        \\ package main
        \\-var a = 1
        \\+var a = 2
        \\+var b = 3
        \\
        \\diff --git a/added.txt b/added.txt
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/added.txt
        \\@@ -0,0 +1 @@
        \\+hello
        \\\ No newline at end of file
        \\diff --git "a/\346\226\207.txt" "b/\346\226\207.txt"
        \\old mode 100644
        \\new mode 100755
        \\
    ;
    var patch = try parse(std.testing.allocator, text, null);
    defer patch.deinit();
    try std.testing.expectEqual(@as(usize, 3), patch.files.len);
    const first = patch.files[0];
    try std.testing.expectEqualStrings("old.go", first.old_name);
    try std.testing.expectEqualStrings("new.go", first.new_name);
    try std.testing.expectEqual(@as(usize, 1), first.hunks.len);
    try std.testing.expectEqualStrings("package main", first.hunks[0].section);
    // The blank line at the end of the hunk is a line of both.
    try std.testing.expectEqual(@as(usize, 5), first.hunks[0].lines.len);
    try std.testing.expectEqualStrings(" ", first.hunks[0].lines[4]);
    const added = patch.files[1];
    try std.testing.expectEqualStrings("", added.old_name);
    try std.testing.expectEqualStrings("added.txt", added.new_name);
    try std.testing.expectEqualStrings("100644", added.new_mode);
    try std.testing.expectEqual(@as(usize, 1), added.hunks[0].new_lines);
    try std.testing.expectEqual(@as(usize, 2), added.hunks[0].lines.len);
    const moded = patch.files[2];
    try std.testing.expectEqualStrings("文.txt", moded.old_name);
    try std.testing.expectEqualStrings("100755", moded.new_mode);
    const applied = try added.apply(std.testing.allocator, "");
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqualStrings("hello", applied);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.HunkTooShort, parse(std.testing.allocator, "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a", &diagnostic));
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
}

test "a patch applies to the old text, keeping or dropping its last newline" {
    var patch = try parse(std.testing.allocator,
        \\--- a/f
        \\+++ b/f
        \\@@ -1,3 +1,3 @@
        \\ one
        \\-two
        \\+2
        \\ three
        \\@@ -5,2 +5,2 @@
        \\ five
        \\-six
        \\+6
        \\\ No newline at end of file
        \\
    , null);
    defer patch.deinit();
    const new = try patch.files[0].apply(std.testing.allocator, "one\ntwo\nthree\nfour\nfive\nsix\n");
    defer std.testing.allocator.free(new);
    try std.testing.expectEqualStrings("one\n2\nthree\nfour\nfive\n6", new);
    try std.testing.expectError(error.HunkMismatch, patch.files[0].apply(std.testing.allocator, "one\nTWO\nthree\nfour\nfive\nsix\n"));
}

test "a patch's partial texts start each hunk on its own line, numbered as in the files" {
    var patch = try parse(std.testing.allocator,
        \\--- a/x.go
        \\+++ b/x.go
        \\@@ -1,2 +1,2 @@
        \\ a := 1
        \\-/* open
        \\+/* still open
        \\@@ -10,2 +10,3 @@ func f()
        \\ b := 2
        \\+c := 3
        \\ d := 4
        \\
    , null);
    defer patch.deinit();
    var partial = try Partial.init(std.testing.allocator, patch.files[0]);
    defer partial.deinit();
    try std.testing.expectEqualStrings("a := 1\n/* open\nb := 2\nd := 4", partial.old_text);
    try std.testing.expectEqualStrings("a := 1\n/* still open\nb := 2\nc := 3\nd := 4", partial.new_text);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, partial.old_starts);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, partial.new_starts);
    try std.testing.expectEqualStrings("@@ -10,2 +10,3 @@ func f()", partial.headers[1]);
    try std.testing.expectEqual(@as(usize, 2), partial.changes.len);
    try std.testing.expectEqual(Lines{ .start = 1, .end = 2 }, partial.changes[0].old);
    try std.testing.expectEqual(Lines{ .start = 3, .end = 4 }, partial.changes[1].new);
    try std.testing.expectEqual(@as(usize, 10), partial.fileLine(.new, 3));
    try std.testing.expectEqual(@as(usize, 1), partial.fileLine(.old, 1));
    try std.testing.expect(partial.hunkOf(.new, 2).first and partial.hunkOf(.new, 2).index == 1);
}

test "a patch's partial texts know which files end without a newline" {
    const cases = [_]struct { text: []const u8, sides: [2]bool }{
        .{ .text = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n", .sides = .{ true, false } },
        .{ .text = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n", .sides = .{ false, true } },
        .{ .text = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n\\ No newline at end of file\n", .sides = .{ true, true } },
        .{ .text = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n", .sides = .{ false, false } },
    };
    for (cases) |case| {
        var patch = try parse(std.testing.allocator, case.text, null);
        defer patch.deinit();
        var partial = try Partial.init(std.testing.allocator, patch.files[0]);
        defer partial.deinit();
        try std.testing.expectEqual(case.sides, partial.noNewline());
    }
}
