const std = @import("std");
const document = @import("ziggurat_document");

pub const Cancellation = document.search.Cancellation;
pub const Limits = struct {
    bytes: usize = 16 * 1024 * 1024,
    lines: usize = 131072,
    distance: usize = 512,
    work: u64 = 64 * 1024 * 1024,
    pub fn validate(self: Limits) !void {
        if (self.bytes == 0 or self.bytes > 1024 * 1024 * 1024 or self.lines == 0 or self.lines > 1048576 or self.distance > 8192 or self.work == 0) return error.InvalidLimits;
    }
};
pub const Options = struct { limits: Limits = .{}, cancellation: ?*const Cancellation = null };
pub const LineRange = struct { start: usize, end: usize };
pub const Side = struct { lines: LineRange, bytes: document.Range };
/// Half-open original coordinates. Replacing a.bytes with b.bytes transforms
/// the first input into the second; intervening bytes are identical.
pub const Hunk = struct { a: Side, b: Side };
pub const Stamp = struct { revision: u64, text_version: u64, bytes: usize };
pub const Stats = struct {
    lines_a: usize = 0,
    lines_b: usize = 0,
    distance: usize = 0,
    hash_bytes: u64 = 0,
    compared_bytes: u64 = 0,
    frontier_steps: u64 = 0,
    trace_cells: u64 = 0,
    work: u64 = 0,
    peak_bytes: usize = 0,
};
/// Owning immutable metadata, independent of both Reader lifetimes. No source
/// text is retained. Stamps do not establish document identity: the host keeps
/// that association and rejects stale worker deliveries before using ranges.
pub const Result = struct {
    allocator: std.mem.Allocator,
    storage: []Hunk,
    hunks: []const Hunk,
    a: Stamp,
    b: Stamp,
    stats: Stats,
    owned: bool = true,
    pub fn isOwned(self: *const Result) bool {
        return self.owned;
    }
    /// Explicit move, including a legitimate zero-hunk result. Failure keeps
    /// the source unchanged; the returned value has the release responsibility.
    pub fn take(self: *Result) !Result {
        if (!self.owned) return error.ResultMoved;
        const result = self.*;
        self.owned = false;
        self.storage = &.{};
        self.hunks = &.{};
        return result;
    }
    pub fn deinit(self: *Result) void {
        if (!self.owned) return;
        const allocator = self.allocator;
        const storage = self.storage;
        self.owned = false;
        self.storage = &.{};
        self.hunks = &.{};
        allocator.free(storage);
    }
};
const Line = struct { start: usize, end: usize, hash: u64 };
const Index = struct {
    storage: []Line,
    lines: []const Line,
    bytes: usize,
    fn boundary(self: Index, line: usize) usize {
        return if (line == self.lines.len) self.bytes else self.lines[line].start;
    }
    fn side(self: Index, first: usize, end: usize) Side {
        return .{ .lines = .{ .start = first, .end = end }, .bytes = .{ .start = self.boundary(first), .end = self.boundary(end) } };
    }
};
const Edit = struct { a: usize, b: usize, insertion: bool };
const Step = struct { x: i32, insertion: bool };
const Work = struct {
    options: Options,
    allocator: std.mem.Allocator,
    live: usize = 0,
    stats: Stats = .{},
    fn charge(self: *Work, amount: usize) !void {
        if (self.options.cancellation) |cancel| if (cancel.requested.load(.acquire)) return error.Cancelled;
        if (amount > self.options.limits.work - self.stats.work) return error.WorkLimitExceeded;
        self.stats.work += amount;
    }
    fn alloc(self: *Work, comptime T: type, count: usize) ![]T {
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.CapacityExceeded;
        if (bytes > self.options.limits.bytes - self.live) return error.CapacityExceeded;
        const result = try self.allocator.alloc(T, count);
        self.live += bytes;
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.live);
        return result;
    }
    fn free(self: *Work, comptime T: type, storage: []T) void {
        self.live -= @sizeOf(T) * storage.len;
        self.allocator.free(storage);
    }
    fn index(self: *Work, reader: document.Reader) !Index {
        const length = try reader.byteLength();
        const capacity = try reader.lineCount();
        if (capacity - 1 > self.options.limits.lines) return error.LineLimitExceeded;
        // A trailing LF is not a synthetic extra diff record.
        const storage = try self.alloc(Line, @min(capacity, self.options.limits.lines));
        errdefer self.free(Line, storage);
        var cursor = try reader.cursor(.{ .start = 0, .end = length });
        var start: usize = 0;
        var count: usize = 0;
        var hash: u64 = 14695981039346656037;
        while (try cursor.next()) |segment| {
            try self.charge(segment.bytes.len);
            self.stats.hash_bytes += segment.bytes.len;
            for (segment.bytes, segment.start..) |byte, at| {
                hash = (hash ^ byte) *% 1099511628211;
                if (byte == '\n') {
                    if (count == storage.len) return error.LineLimitExceeded;
                    storage[count] = .{ .start = start, .end = at + 1, .hash = hash };
                    count += 1;
                    start = at + 1;
                    hash = 14695981039346656037;
                }
            }
        }
        if (start != length) {
            if (count == storage.len) return error.LineLimitExceeded;
            storage[count] = .{ .start = start, .end = length, .hash = hash };
            count += 1;
        }
        return .{ .storage = storage, .lines = storage[0..count], .bytes = length };
    }
    fn equal(self: *Work, a: document.Reader, b: document.Reader, left: Line, right: Line) !bool {
        try self.charge(1);
        if (left.hash != right.hash or left.end - left.start != right.end - right.start) return false;
        // Hashes only reject. Confirm all equal bytes, including line endings.
        var ca = try a.cursor(.{ .start = left.start, .end = left.end });
        var cb = try b.cursor(.{ .start = right.start, .end = right.end });
        var pa: []const u8 = &.{};
        var pb: []const u8 = &.{};
        while (true) {
            if (pa.len == 0) pa = if (try ca.next()) |part| part.bytes else return true;
            if (pb.len == 0) pb = (try cb.next()).?.bytes;
            const size = @min(pa.len, pb.len);
            try self.charge(size);
            self.stats.compared_bytes += size;
            if (!std.mem.eql(u8, pa[0..size], pb[0..size])) return false;
            pa = pa[size..];
            pb = pb[size..];
        }
    }
};

fn choose(n: i32, m: i32, k: i32, left: i32, right: i32) ?Step {
    const deletion = left >= 0 and left < n and left - (k - 1) >= 0 and left - (k - 1) <= m;
    const insertion = right >= 0 and right <= n and right - (k + 1) >= 0 and right - (k + 1) < m;
    if (deletion and (!insertion or left + 1 > right)) return .{ .x = left + 1, .insertion = false };
    if (insertion) return .{ .x = right, .insertion = true };
    return null;
}
fn rowStart(depth: usize) usize {
    return depth * (depth + 1) / 2;
}
fn previous(trace: []const i32, depth: usize, k: i32) i32 {
    const d: i32 = @intCast(depth);
    if (k < -d or k > d or @mod(k + d, 2) != 0) return -1;
    return trace[rowStart(depth) + @as(usize, @intCast(@divExact(k + d, 2)))];
}

/// Explicit synchronous work over two immutable leases. Hosts normally run it
/// on their own worker; this function starts no threads and releases no Reader.
/// Exact line equality and a shortest insert/delete script are guaranteed on
/// success. Exceeding distance, bytes or work fails without a partial Result.
pub fn compare(allocator: std.mem.Allocator, a: document.Reader, b: document.Reader, options: Options) !Result {
    try options.limits.validate();
    var work: Work = .{ .allocator = allocator, .options = options };
    try work.charge(0);
    const stamp_a: Stamp = .{ .revision = try a.version(), .text_version = try a.committedTextVersion(), .bytes = try a.byteLength() };
    const stamp_b: Stamp = .{ .revision = try b.version(), .text_version = try b.committedTextVersion(), .bytes = try b.byteLength() };
    const ia = try work.index(a);
    defer work.free(Line, ia.storage);
    const ib = try work.index(b);
    defer work.free(Line, ib.storage);
    work.stats.lines_a = ia.lines.len;
    work.stats.lines_b = ib.lines.len;
    // Preserve exact common context before searching. Apart from reducing
    // trace storage, this prevents a changed repeated line from drifting to a
    // distant equally minimal insertion/deletion at the end of the file.
    var prefix: usize = 0;
    while (prefix < @min(ia.lines.len, ib.lines.len) and try work.equal(a, b, ia.lines[prefix], ib.lines[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < ia.lines.len - prefix and suffix < ib.lines.len - prefix and try work.equal(a, b, ia.lines[ia.lines.len - suffix - 1], ib.lines[ib.lines.len - suffix - 1])) suffix += 1;
    const lines_a = ia.lines[prefix .. ia.lines.len - suffix];
    const lines_b = ib.lines[prefix .. ib.lines.len - suffix];
    const n: i32 = @intCast(lines_a.len);
    const m: i32 = @intCast(lines_b.len);
    const limit = @min(options.limits.distance, lines_a.len + lines_b.len);
    if (@abs(n - m) > limit) return error.DistanceLimitExceeded;
    const width = limit * 2 + 3;
    const frontier = try work.alloc(i32, width);
    defer work.free(i32, frontier);
    const trace = try work.alloc(i32, (limit + 1) * (limit + 2) / 2);
    defer work.free(i32, trace);
    try work.charge(frontier.len);
    @memset(frontier, -1);
    const origin: i32 = @intCast(limit + 1);
    var distance: ?usize = null;
    outer: for (0..limit + 1) |depth| {
        const d: i32 = @intCast(depth);
        var k: i32 = -d;
        while (k <= d) : (k += 2) {
            try work.charge(2);
            work.stats.frontier_steps += 1;
            work.stats.trace_cells += 1;
            const cell: usize = @intCast(origin + k);
            const slot = rowStart(depth) + @as(usize, @intCast(@divExact(k + d, 2)));
            const step = if (depth == 0) Step{ .x = 0, .insertion = false } else choose(n, m, k, frontier[cell - 1], frontier[cell + 1]) orelse {
                frontier[cell] = -1;
                trace[slot] = -1;
                continue;
            };
            var x = step.x;
            var y = x - k;
            while (x < n and y < m and try work.equal(a, b, lines_a[@intCast(x)], lines_b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            frontier[cell] = x;
            trace[slot] = x;
            if (x == n and y == m) {
                distance = depth;
                break :outer;
            }
        }
    }
    const d = distance orelse return error.DistanceLimitExceeded;
    work.stats.distance = d;
    const edits = try work.alloc(Edit, d);
    defer work.free(Edit, edits);
    var x = n;
    var y = m;
    var depth = d;
    while (depth != 0) {
        try work.charge(1);
        const k = x - y;
        const left = previous(trace, depth - 1, k - 1);
        const right = previous(trace, depth - 1, k + 1);
        const step = choose(n, m, k, left, right).?;
        const prev_x = if (step.insertion) right else left;
        const prev_y = prev_x - (if (step.insertion) k + 1 else k - 1);
        edits[depth - 1] = .{ .a = prefix + @as(usize, @intCast(prev_x)), .b = prefix + @as(usize, @intCast(prev_y)), .insertion = step.insertion };
        x = prev_x;
        y = prev_y;
        depth -= 1;
    }
    const hunks = try work.alloc(Hunk, d);
    errdefer work.free(Hunk, hunks);
    var count: usize = 0;
    for (edits) |edit| {
        try work.charge(1);
        const end_a = edit.a + @intFromBool(!edit.insertion);
        const end_b = edit.b + @intFromBool(edit.insertion);
        if (count != 0 and hunks[count - 1].a.lines.end == edit.a and hunks[count - 1].b.lines.end == edit.b) {
            hunks[count - 1].a = ia.side(hunks[count - 1].a.lines.start, end_a);
            hunks[count - 1].b = ib.side(hunks[count - 1].b.lines.start, end_b);
        } else {
            hunks[count] = .{ .a = ia.side(edit.a, end_a), .b = ib.side(edit.b, end_b) };
            count += 1;
        }
    }
    try work.charge(0);
    return .{ .allocator = allocator, .storage = hunks, .hunks = hunks[0..count], .a = stamp_a, .b = stamp_b, .stats = work.stats };
}

test {
    _ = @import("test.zig");
}

test "line hash collisions never establish equality" {
    const allocator = std.testing.allocator;
    const a = try document.Document.create(allocator, std.Thread.getCurrentId(), "aa\n", .{});
    defer a.close() catch unreachable;
    const b = try document.Document.create(allocator, std.Thread.getCurrentId(), "bb\n", .{});
    defer b.close() catch unreachable;
    const sa = try a.snapshot();
    defer sa.close() catch unreachable;
    const sb = try b.snapshot();
    defer sb.close() catch unreachable;
    const ra = try sa.borrowReader();
    defer ra.release() catch unreachable;
    const rb = try sb.borrowReader();
    defer rb.release() catch unreachable;
    var work: Work = .{ .allocator = allocator, .options = .{} };
    try std.testing.expect(!try work.equal(ra, rb, .{ .start = 0, .end = 3, .hash = 7 }, .{ .start = 0, .end = 3, .hash = 7 }));
    try std.testing.expectEqual(3, work.stats.compared_bytes);
}
