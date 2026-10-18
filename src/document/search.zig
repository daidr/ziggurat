const std = @import("std");
const readers = @import("reader.zig");
const selections = @import("selections.zig");
pub const Range = selections.Range;
pub const Replacement = selections.Replacement;
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
};
pub const Case = enum { exact, ascii_insensitive };
pub const Options = struct { case: Case = .exact, overlapping: bool = false, cancellation: ?*const Cancellation = null };
pub const Result = union(enum) { match: Range, yielded, done };
pub const Progress = struct { next_byte: usize, scanned_bytes: usize, comparisons: u64 };

/// Allocation-free incremental literal search. Reader, pattern and caller KMP
/// scratch outlive the iterator; scratch belongs exclusively to this iterator.
/// Construction is O(pattern bytes). A step counts comparisons, including
/// fallback comparisons; crossing a leaf also walks at most 64 tree levels.
pub const Iterator = struct {
    reader: readers.Reader,
    cursor: readers.Cursor,
    pattern: []const u8,
    prefix: []usize,
    options: Options,
    revision: u64,
    start: usize,
    position: usize,
    end: usize,
    part: []const u8 = &.{},
    offset: usize = 0,
    matched: usize = 0,
    comparisons: u64 = 0,
    completed_bytes: usize = 0,
    pub fn init(reader: readers.Reader, range: Range, pattern: []const u8, scratch: []usize, options: Options) !Iterator {
        if (pattern.len == 0) return error.EmptyPattern;
        if (pattern.len > 65536 or scratch.len < pattern.len) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        const cursor = try reader.cursor(range);
        if (options.cancellation) |cancel| if (cancel.requested.load(.acquire)) return error.Cancelled;
        const prefix = scratch[0..pattern.len];
        prefix[0] = 0;
        var matched: usize = 0;
        for (pattern[1..], 1..) |byte, at| {
            while (matched > 0 and fold(pattern[matched], options.case) != fold(byte, options.case)) matched = prefix[matched - 1];
            if (fold(pattern[matched], options.case) == fold(byte, options.case)) matched += 1;
            prefix[at] = matched;
        }
        return .{ .reader = reader, .cursor = cursor, .pattern = pattern, .prefix = prefix, .options = options, .revision = try reader.version(), .start = range.start, .position = range.start, .end = range.end };
    }
    pub fn progress(self: *const Iterator) Progress {
        return .{ .next_byte = self.position, .scanned_bytes = self.completed_bytes + (self.position - self.start), .comparisons = self.comparisons };
    }
    /// Explicitly seek another scalar-boundary range on the same immutable
    /// Reader. Keeps the prepared prefix and cumulative comparisons/scan bytes;
    /// does not allocate or rebuild the prefix. Failure leaves this iterator
    /// unchanged. Cursor construction walks at most the fixed tree depth.
    pub fn restart(self: *Iterator, range: Range) !void {
        const cursor = try self.reader.cursor(range);
        if (self.options.cancellation) |cancel| if (cancel.requested.load(.acquire)) return error.Cancelled;
        const completed = std.math.add(usize, self.completed_bytes, self.position - self.start) catch return error.CapacityExceeded;
        // Preflight the full range so every future progress query is safe.
        _ = std.math.add(usize, completed, range.end - range.start) catch return error.CapacityExceeded;
        self.cursor = cursor;
        self.completed_bytes = completed;
        self.start = range.start;
        self.position = range.start;
        self.end = range.end;
        self.part = &.{};
        self.offset = 0;
        self.matched = 0;
    }
    pub fn step(self: *Iterator, max_comparisons: usize) !Result {
        _ = try self.reader.version();
        if (max_comparisons == 0) return error.InvalidBudget;
        var work: usize = 0;
        while (true) {
            if (work % 256 == 0) if (self.options.cancellation) |cancel| if (cancel.requested.load(.acquire)) return error.Cancelled;
            if (self.position == self.end) return .done;
            if (work == max_comparisons) return .yielded;
            if (self.offset == self.part.len) {
                const next = (try self.cursor.next()).?;
                std.debug.assert(next.start == self.position);
                self.part = next.bytes;
                self.offset = 0;
            }
            const equal = fold(self.pattern[self.matched], self.options.case) == fold(self.part[self.offset], self.options.case);
            work += 1;
            self.comparisons +|= 1;
            if (!equal and self.matched > 0) {
                self.matched = self.prefix[self.matched - 1];
                continue;
            }
            if (equal) self.matched += 1;
            self.offset += 1;
            self.position += 1;
            if (self.matched == self.pattern.len) {
                const result: Range = .{ .start = self.position - self.pattern.len, .end = self.position };
                self.matched = if (self.options.overlapping) self.prefix[self.matched - 1] else 0;
                return .{ .match = result };
            }
        }
    }
};
fn fold(byte: u8, case: Case) u8 {
    return if (case == .ascii_insensitive and byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

/// Caller owns both result and edit buffers. The document validates revision,
/// scalar boundaries and strict non-overlap before committing one undo version.
pub fn replaceMatches(document: anytype, revision: u64, matches: []const Range, replacement: []const u8, edits: []Replacement) !void {
    if (matches.len > edits.len) return error.CapacityExceeded;
    for (matches, edits[0..matches.len]) |range, *edit| edit.* = .{ .range = range, .text = replacement };
    try document.replaceMany(revision, edits[0..matches.len]);
}
