//! Incremental highlighting with a line tokenizer. The highlighter keeps
//! the state each line starts in. After an edit it tokenizes the lines that
//! follow again until one starts in the state it started in before, a
//! bounded number of lines per call, so typing re-lexes only what changed
//! and the lines shown are ready first.
//!
//! A source is any value with `lineCount() !usize` and
//! `readLine(index, buffer) !SourceLine`; `SliceLines` reads a byte slice.
const std = @import("std");
const syntax = @import("root.zig");

const Token = syntax.Token;
const Tokenizer = syntax.Tokenizer;

/// One line of a source without its line break. `length` is the full
/// length; a line longer than the buffer it was read into is left plain.
pub const SourceLine = struct { text: []const u8, length: usize };

/// Lines of an in-memory text split at LF; a trailing CR stays in the line.
pub const SliceLines = struct {
    text: []const u8,

    pub fn lineCount(self: SliceLines) !usize {
        return std.mem.count(u8, self.text, "\n") + 1;
    }
    pub fn readLine(self: SliceLines, index: usize, buffer: []u8) !SourceLine {
        var it = std.mem.splitScalar(u8, self.text, '\n');
        var at: usize = 0;
        while (it.next()) |line| : (at += 1) {
            if (at != index) continue;
            const count = @min(line.len, buffer.len);
            @memcpy(buffer[0..count], line[0..count]);
            return .{ .text = buffer[0..count], .length = line.len };
        }
        return error.InvalidLine;
    }
    pub fn byteLength(self: SliceLines) !usize {
        return self.text.len;
    }
    /// The byte offset line `index` starts at.
    pub fn lineStart(self: SliceLines, index: usize) !usize {
        if (index == 0) return 0;
        var seen: usize = 0;
        for (self.text, 0..) |c, i| if (c == '\n') {
            seen += 1;
            if (seen == index) return i + 1;
        };
        return error.InvalidLine;
    }
    /// The line holding byte `offset`; the end of the text is on the last.
    pub fn lineAt(self: SliceLines, offset: usize) !usize {
        if (offset > self.text.len) return error.InvalidOffset;
        return std.mem.count(u8, self.text[0..offset], "\n");
    }
};

pub const Highlighter = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    /// The state line i starts in.
    states: std.ArrayList(u64) = .empty,
    /// A hash of line i's text when it was tokenized; 0 when unknown.
    hashes: std.ArrayList(u64) = .empty,
    /// How many lines from the top start in states known right. `confirmed`
    /// is how many would be, were the edits since the last pass to leave
    /// the states after them unchanged: a pass that tokenizes past the
    /// edits into a line starting as it did confirms the lines up to it.
    frontier: usize = 1,
    confirmed: usize = 1,
    /// The last line an edit changed, -1 for none.
    dirty: isize = -1,
    /// Lines in the source at the last pass, for `sync`.
    line_count: usize = 1,
    line_buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, tokenizer: Tokenizer) !Highlighter {
        const buffer = try allocator.alloc(u8, syntax.max_line);
        errdefer allocator.free(buffer);
        var self: Highlighter = .{ .allocator = allocator, .tokenizer = tokenizer, .line_buffer = buffer };
        try self.states.append(allocator, 0);
        return self;
    }
    pub fn deinit(self: *Highlighter) void {
        self.states.deinit(self.allocator);
        self.hashes.deinit(self.allocator);
        self.allocator.free(self.line_buffer);
        self.* = undefined;
    }

    /// Forget every state, as for a new text or tokenizer.
    pub fn reset(self: *Highlighter, tokenizer: Tokenizer) void {
        self.tokenizer = tokenizer;
        self.states.shrinkRetainingCapacity(1);
        self.states.items[0] = 0;
        self.hashes.clearRetainingCapacity();
        self.frontier = 1;
        self.confirmed = 1;
        self.dirty = -1;
    }

    /// Follow an edit that replaced lines `start..old_end` (inclusive) with
    /// `start..new_end`: the states of the lines after it move with them,
    /// and those from `start + 1` on are known again only after a pass.
    pub fn edit(self: *Highlighter, start: usize, old_end: usize, new_end: usize) !void {
        std.debug.assert(old_end >= start and new_end >= start);
        const removed = old_end - start;
        const added = new_end - start;
        const from = start + 1;
        if (from < self.states.items.len) {
            const stop = @min(self.states.items.len, from + removed);
            try self.states.replaceRange(self.allocator, from, stop - from, &.{});
            @memset(try self.states.addManyAt(self.allocator, @min(from, self.states.items.len), added), 0);
        }
        if (start < self.hashes.items.len) {
            self.hashes.items[start] = 0;
            if (from < self.hashes.items.len) {
                const stop = @min(self.hashes.items.len, from + removed);
                try self.hashes.replaceRange(self.allocator, from, stop - from, &.{});
                @memset(try self.hashes.addManyAt(self.allocator, @min(from, self.hashes.items.len), added), 0);
            }
        }
        self.frontier = @min(self.frontier, start + 1);
        if (old_end < self.confirmed) {
            self.confirmed = self.confirmed + added - removed;
        } else self.confirmed = @min(self.confirmed, start + 1);
        const old: isize = @intCast(old_end);
        const delta: isize = @as(isize, @intCast(added)) - @as(isize, @intCast(removed));
        if (self.dirty > old) self.dirty += delta;
        self.dirty = @max(self.dirty, @as(isize, @intCast(new_end)));
        self.line_count = self.line_count + added - removed;
    }

    /// Find what changed in `source` since the last pass by the hashes of the
    /// lines tokenized, for hosts that do not report edits, and follow it.
    pub fn sync(self: *Highlighter, source: anytype) !void {
        const count = try source.lineCount();
        const known = self.hashes.items.len;
        var first: usize = 0;
        while (first < known and first < count) : (first += 1) {
            const value = self.hashes.items[first];
            if (value == 0 or value != try self.hashLine(source, first)) break;
        }
        if (first == known and known <= count) {
            self.line_count = count;
            return;
        }
        // Lines matching from the end of those hashed, assuming the lines
        // past them moved by the change in line count; their hashes verify
        // it, and lines past the hashed ones keep no state.
        const old_count = @max(self.line_count, known);
        const delta = @as(isize, @intCast(count)) - @as(isize, @intCast(old_count));
        var same: usize = 0;
        while (same + first + 1 < known) : (same += 1) {
            const old_line = known - 1 - same;
            const new_line = @as(isize, @intCast(old_line)) + delta;
            if (new_line <= @as(isize, @intCast(first)) or new_line >= @as(isize, @intCast(count))) break;
            const value = self.hashes.items[old_line];
            if (value == 0 or value != try self.hashLine(source, @intCast(new_line))) break;
        }
        const old_end = known -| (1 + same);
        const new_end = @as(isize, @intCast(old_end)) + delta;
        if (same > 0 and old_end >= first and new_end >= @as(isize, @intCast(first))) {
            try self.edit(first, old_end, @intCast(new_end));
        } else {
            self.states.shrinkRetainingCapacity(@min(self.states.items.len, first + 1));
            self.hashes.shrinkRetainingCapacity(@min(self.hashes.items.len, first));
            self.frontier = @min(self.frontier, first + 1);
            self.confirmed = @min(self.confirmed, first + 1);
            self.dirty = -1;
        }
        self.line_count = count;
    }

    fn hashLine(self: *Highlighter, source: anytype, index: usize) !u64 {
        const line = try source.readLine(index, self.line_buffer);
        return lineHash(line);
    }

    /// Work toward the states of the lines up to `last`, tokenizing at most
    /// `budget` lines, and report whether they are ready. Call it before
    /// showing lines, and again later while it reports false.
    pub fn highlight(self: *Highlighter, source: anytype, last_line: usize, budget: usize) !bool {
        const count = try source.lineCount();
        self.line_count = count;
        const last = @min(last_line, count -| 1);
        if (self.states.items.len > count) self.states.shrinkRetainingCapacity(count);
        if (self.hashes.items.len > count) self.hashes.shrinkRetainingCapacity(count);
        if (self.states.items.len == 0) try self.states.append(self.allocator, 0);
        self.frontier = @max(1, @min(self.frontier, self.states.items.len));
        self.confirmed = @min(self.confirmed, self.states.items.len);
        // Whatever way the pass ends, the lines it leaves known are those
        // confirmed: lines past where it stopped wait for the next.
        defer {
            self.confirmed = self.frontier;
            if (@as(isize, @intCast(self.frontier)) > self.dirty) self.dirty = -1;
        }
        var work: usize = 0;
        var scratch: [512]Token = undefined;
        outer: while (self.frontier <= last) {
            var i = self.frontier - 1;
            while (i <= last) : (i += 1) {
                if (work == budget) return false;
                work += 1;
                const line = try source.readLine(i, self.line_buffer);
                var out = syntax.Output.init(&scratch);
                const end = if (line.length > line.text.len) self.states.items[i] else self.tokenizer.tokenize(line.text, self.states.items[i], &out);
                try self.setHash(i, lineHash(line));
                if (i + 1 < self.states.items.len) {
                    if (self.states.items[i + 1] == end and @as(isize, @intCast(i + 1)) > self.dirty and self.confirmed > i + 2) {
                        // The lines after start as they did, up to those
                        // confirmed before the edits.
                        self.frontier = self.confirmed;
                        continue :outer;
                    }
                    self.states.items[i + 1] = end;
                } else try self.states.append(self.allocator, end);
                self.frontier = i + 2;
            }
        }
        return true;
    }

    fn setHash(self: *Highlighter, index: usize, value: u64) !void {
        if (index < self.hashes.items.len) {
            self.hashes.items[index] = value;
            return;
        }
        while (self.hashes.items.len < index) try self.hashes.append(self.allocator, 0);
        try self.hashes.append(self.allocator, value);
    }

    /// The state line `index` starts in, and whether a pass confirmed it.
    /// Unconfirmed lines start in the state they had before the edits since,
    /// which is usually right.
    pub fn stateOf(self: *const Highlighter, index: usize) struct { state: u64, final: bool } {
        if (index < self.states.items.len) return .{ .state = self.states.items[index], .final = index < self.frontier };
        return .{ .state = 0, .final = false };
    }

    /// Tokenize line `index`, whose text is `text`, into `buffer`. `final` is
    /// false while the tokens are a guess made before `highlight` confirmed
    /// the line's start state.
    pub fn tokens(self: *const Highlighter, index: usize, text: []const u8, buffer: []Token) struct { tokens: []Token, final: bool } {
        const start = self.stateOf(index);
        const result = syntax.tokenizeLine(self.tokenizer, text, start.state, buffer);
        return .{ .tokens = result.tokens, .final = start.final };
    }
};

fn lineHash(line: SourceLine) u64 {
    var hasher = std.hash.Wyhash.init(line.length);
    hasher.update(line.text);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}
