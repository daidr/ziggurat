const std = @import("std");
const d = @import("ziggurat_document");
const diff = @import("ziggurat_document_diff");

/// Positional line pairing inside each changed line hunk. Ranges use original
/// UTF-8 document bytes and always end on Unicode scalar boundaries. They are
/// not grapheme boundaries: presentation expands them through cached layout.
pub const Span = struct { hunk: usize, line_a: usize, line_b: usize, a: d.Range, b: d.Range };
pub const Limits = struct {
    bytes: usize = 16 * 1024 * 1024,
    line_bytes: usize = 16384,
    line_scalars: usize = 8192,
    pairs: usize = 4096,
    spans: usize = 4096,
    cells: usize = 2 * 1024 * 1024,
    work: usize = 32 * 1024 * 1024,
};
pub const Options = struct { limits: Limits = .{}, cancellation: ?*const diff.Cancellation = null };
pub const Stats = struct { pairs: usize = 0, cells: usize = 0, work: usize = 0, peak_bytes: usize = 0, scalar_edits: usize = 0 };
pub const Result = struct {
    allocator: std.mem.Allocator,
    storage: []Span,
    spans: []const Span,
    a: diff.Stamp,
    b: diff.Stamp,
    stats: Stats,
    owned: bool = true,
    pub fn isOwned(self: *const Result) bool {
        return self.owned;
    }
    pub fn take(self: *Result) !Result {
        if (!self.owned) return error.ResultMoved;
        const output = self.*;
        self.owned = false;
        self.storage = &.{};
        self.spans = &.{};
        return output;
    }
    pub fn deinit(self: *Result) void {
        if (!self.owned) return;
        const allocator = self.allocator;
        const storage = self.storage;
        self.owned = false;
        self.storage = &.{};
        self.spans = &.{};
        allocator.free(storage);
    }
};

const Scalar = struct { value: u21, byte: usize };
const Builder = struct {
    allocator: std.mem.Allocator,
    options: Options,
    stats: Stats = .{},
    storage: []Span = &.{},
    count: usize = 0,
    live: usize = 0,
    fn cancelled(self: *const Builder) !void {
        if (self.options.cancellation) |value| if (value.requested.load(.acquire)) return error.Cancelled;
    }
    fn work(self: *Builder, amount: usize) !void {
        try self.cancelled();
        if (amount > self.options.limits.work -| self.stats.work) return error.WorkLimitExceeded;
        self.stats.work += amount;
    }
    fn alloc(self: *Builder, comptime T: type, count: usize) ![]T {
        try self.cancelled();
        const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.CapacityExceeded;
        if (bytes > self.options.limits.bytes -| self.live) return error.CapacityExceeded;
        const value = try self.allocator.alloc(T, count);
        self.live += bytes;
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.live);
        return value;
    }
    fn free(self: *Builder, value: anytype) void {
        self.live -= value.len * @sizeOf(@TypeOf(value[0]));
        self.allocator.free(value);
    }
    fn append(self: *Builder, span: Span) !void {
        if (self.count == self.options.limits.spans) return error.CapacityExceeded;
        if (self.count == self.storage.len) {
            const capacity = @min(self.options.limits.spans, @max(8, self.storage.len * 2));
            const next = try self.alloc(Span, capacity);
            @memcpy(next[0..self.count], self.storage[0..self.count]);
            self.free(self.storage);
            self.storage = next;
        }
        self.storage[self.count] = span;
        self.count += 1;
    }
    fn read(self: *Builder, reader: d.Reader, range: d.Range) ![]u8 {
        const length = range.end - range.start;
        if (length > self.options.limits.line_bytes) return error.CapacityExceeded;
        try self.work(length);
        const bytes = try self.alloc(u8, length);
        errdefer self.free(bytes);
        _ = try reader.read(range, bytes);
        return bytes;
    }
    fn scalars(self: *Builder, bytes: []const u8) ![]Scalar {
        var count: usize = 0;
        var at: usize = 0;
        while (at < bytes.len) {
            if (count == self.options.limits.line_scalars) return error.CapacityExceeded;
            at += try std.unicode.utf8ByteSequenceLength(bytes[at]);
            count += 1;
        }
        const output = try self.alloc(Scalar, count + 1);
        errdefer self.free(output);
        at = 0;
        for (output[0..count]) |*scalar| {
            const length = try std.unicode.utf8ByteSequenceLength(bytes[at]);
            scalar.* = .{ .value = try std.unicode.utf8Decode(bytes[at..][0..length]), .byte = at };
            at += length;
        }
        output[count] = .{ .value = 0, .byte = bytes.len };
        try self.work(count);
        return output;
    }
    fn pair(self: *Builder, a: d.Reader, b: d.Reader, hunk: usize, line_a: usize, line_b: usize) !void {
        try self.work(1);
        if (self.stats.pairs == self.options.limits.pairs) return error.CapacityExceeded;
        self.stats.pairs += 1;
        const ra = try record(a, line_a);
        const rb = try record(b, line_b);
        const bytes_a = try self.read(a, ra);
        defer self.free(bytes_a);
        const bytes_b = try self.read(b, rb);
        defer self.free(bytes_b);
        const sa = try self.scalars(bytes_a);
        defer self.free(sa);
        const sb = try self.scalars(bytes_b);
        defer self.free(sb);
        const na = sa.len - 1;
        const nb = sb.len - 1;
        var prefix: usize = 0;
        while (prefix < @min(na, nb) and sa[prefix].value == sb[prefix].value) : (prefix += 1) {}
        var suffix: usize = 0;
        while (suffix < @min(na, nb) - prefix and sa[na - 1 - suffix].value == sb[nb - 1 - suffix].value) : (suffix += 1) {}
        try self.work(prefix + suffix);
        const ma = na - prefix - suffix;
        const mb = nb - prefix - suffix;
        if (ma == 0 and mb == 0) return;
        const cells = std.math.mul(usize, ma + 1, mb + 1) catch return error.CapacityExceeded;
        if (cells > self.options.limits.cells -| self.stats.cells) return error.CellLimitExceeded;
        self.stats.cells += cells;
        try self.work(cells);
        const table = try self.alloc(u32, cells);
        defer self.free(table);
        @memset(table, 0);
        const stride = mb + 1;
        var i = ma;
        while (i != 0) {
            i -= 1;
            try self.cancelled();
            var j = mb;
            while (j != 0) {
                j -= 1;
                table[i * stride + j] = if (sa[prefix + i].value == sb[prefix + j].value) table[(i + 1) * stride + j + 1] + 1 else @max(table[(i + 1) * stride + j], table[i * stride + j + 1]);
            }
        }
        i = 0;
        var j: usize = 0;
        while (i != ma or j != mb) {
            if (i < ma and j < mb and sa[prefix + i].value == sb[prefix + j].value) {
                i += 1;
                j += 1;
                continue;
            }
            const start_a = i;
            const start_b = j;
            while (i != ma or j != mb) {
                if (i < ma and j < mb and sa[prefix + i].value == sb[prefix + j].value) break;
                // Equal-cost paths delete first, making repeated-text choices
                // deterministic. No similarity or per-codepoint advance guess.
                if (i < ma and (j == mb or table[(i + 1) * stride + j] >= table[i * stride + j + 1])) i += 1 else j += 1;
            }
            self.stats.scalar_edits += i - start_a + j - start_b;
            try self.append(.{ .hunk = hunk, .line_a = line_a, .line_b = line_b, .a = .{ .start = ra.start + sa[prefix + start_a].byte, .end = ra.start + sa[prefix + i].byte }, .b = .{ .start = rb.start + sb[prefix + start_b].byte, .end = rb.start + sb[prefix + j].byte } });
        }
    }
};

fn stamp(reader: d.Reader) !diff.Stamp {
    return .{ .revision = try reader.version(), .text_version = try reader.committedTextVersion(), .bytes = try reader.byteLength() };
}
/// Include the actual line terminator. CR/LF/CRLF and terminal newline changes
/// therefore remain exact scalar edits, rather than being silently normalized.
pub fn record(reader: d.Reader, line: usize) !d.Range {
    const range = try reader.line(line);
    const end = if (line + 1 < try reader.lineCount()) (try reader.line(line + 1)).start else try reader.byteLength();
    return .{ .start = range.start, .end = end };
}
pub fn compare(allocator: std.mem.Allocator, a: d.Reader, b: d.Reader, lines: *const diff.Result, options: Options) !Result {
    const limits = options.limits;
    if (limits.bytes == 0 or limits.bytes > 1024 * 1024 * 1024 or limits.line_bytes == 0 or limits.line_bytes > 1024 * 1024 or limits.line_scalars == 0 or limits.line_scalars > 262144 or limits.pairs == 0 or limits.pairs > 131072 or limits.spans == 0 or limits.spans > 65536 or limits.cells == 0 or limits.cells > 64 * 1024 * 1024 or limits.work == 0 or limits.work > 1024 * 1024 * 1024) return error.InvalidLimits;
    if (!lines.isOwned()) return error.ResultMoved;
    const stamp_a = try stamp(a);
    const stamp_b = try stamp(b);
    if (!std.meta.eql(stamp_a, lines.a) or !std.meta.eql(stamp_b, lines.b)) return error.ForeignResult;
    var builder: Builder = .{ .allocator = allocator, .options = options };
    errdefer builder.free(builder.storage);
    try builder.cancelled();
    for (lines.hunks, 0..) |hunk, ordinal| {
        try builder.work(1);
        if (hunk.a.lines.start > hunk.a.lines.end or hunk.b.lines.start > hunk.b.lines.end or hunk.a.lines.end > lines.stats.lines_a or hunk.b.lines.end > lines.stats.lines_b) return error.InvalidResult;
        const count = @min(hunk.a.lines.end - hunk.a.lines.start, hunk.b.lines.end - hunk.b.lines.start);
        for (0..count) |offset| try builder.pair(a, b, ordinal, hunk.a.lines.start + offset, hunk.b.lines.start + offset);
    }
    try builder.cancelled();
    return .{ .allocator = allocator, .storage = builder.storage, .spans = builder.storage[0..builder.count], .a = stamp_a, .b = stamp_b, .stats = builder.stats };
}
test {
    _ = @import("intraline_test.zig");
}
