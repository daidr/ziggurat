const std = @import("std");
const d = @import("ziggurat_document");

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }
    fn check(self: *const Cancellation) !void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};
pub const Limits = struct {
    text_bytes: usize = 1024 * 1024,
    lines: usize = 65536,
    bytes: usize = 4 * 1024 * 1024,
    work_bytes: usize = 4 * 1024 * 1024,
    cancellation: ?*const Cancellation = null,
    pub fn validate(self: Limits) !void {
        if (self.text_bytes == 0 or self.text_bytes > 64 * 1024 * 1024 or self.lines == 0 or self.lines > 1024 * 1024 or self.bytes < @sizeOf(State) or self.bytes > 32 * 1024 * 1024 or self.work_bytes == 0 or self.work_bytes > 128 * 1024 * 1024) return error.InvalidLimits;
    }
};
pub const Stats = struct { bytes: usize, lines: usize, scanned_bytes: usize };
const Line = struct { start: u32, end: u32, utf16_start: u32, utf16_end: u32 };
/// Immutable line metadata over an explicitly borrowed Reader. The Reader's
/// owner retains its lease and Snapshot until Map.close; Map never releases it.
/// CR, LF and CRLF delimit LSP lines independently of Document's LF aggregates.
/// Construction is explicit two-pass preparation, suitable for a host worker.
/// A host may transfer exclusive ownership; queries/close never overlap and
/// the allocator supports both the preparation and final release threads.
pub const Map = opaque {
    pub fn create(allocator: std.mem.Allocator, reader: d.Reader, limits: Limits) !*Map {
        try limits.validate();
        if (limits.cancellation) |cancellation| try cancellation.check();
        const length = try reader.byteLength();
        if (length > limits.text_bytes) return error.TextCapacityExceeded;
        if (length > limits.work_bytes / 2) return error.WorkCapacityExceeded;
        const count = try scan(reader, null, limits.lines, limits.cancellation);
        const bytes = @sizeOf(State) + count * @sizeOf(Line);
        if (bytes > limits.bytes) return error.PositionCapacityExceeded;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        const lines = try allocator.alloc(Line, count);
        errdefer allocator.free(lines);
        std.debug.assert(try scan(reader, lines, count, limits.cancellation) == count);
        state.* = .{ .allocator = allocator, .reader = reader, .lines = lines, .length = length, .bytes = bytes };
        return @ptrCast(state);
    }
    pub fn toPosition(self: *const Map, byte: usize) !Position {
        const state = cast(@constCast(self));
        try state.check();
        const units = try state.reader.utf16Offset(byte);
        var low: usize = 0;
        var high = state.lines.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (state.lines[middle].start <= byte) low = middle + 1 else high = middle;
        }
        const index = low - 1;
        const line = state.lines[index];
        if (byte > line.end) return error.InsideLineEnding;
        return .{ .line = @intCast(index), .character = @intCast(units - line.utf16_start) };
    }
    /// LSP clamps a character past a line's content to that line's end.
    /// A position between a UTF-16 surrogate pair remains an explicit error.
    pub fn toByte(self: *const Map, position: Position) !usize {
        const state = cast(@constCast(self));
        try state.check();
        if (position.line >= state.lines.len or position.character > 0x7fffffff) return error.InvalidPosition;
        const line = state.lines[position.line];
        const units = line.utf16_start + @min(position.character, line.utf16_end - line.utf16_start);
        return state.reader.byteOffsetFromUtf16(units);
    }
    pub fn toRange(self: *const Map, range: Range) !d.Range {
        const start = try self.toByte(range.start);
        const end = try self.toByte(range.end);
        if (start > end) return error.InvalidRange;
        return .{ .start = start, .end = end };
    }
    pub fn fromRange(self: *const Map, range: d.Range) !Range {
        if (range.start > range.end) return error.InvalidRange;
        return .{ .start = try self.toPosition(range.start), .end = try self.toPosition(range.end) };
    }
    pub fn stats(self: *const Map) !Stats {
        const state = cast(@constCast(self));
        try state.check();
        return .{ .bytes = state.bytes, .lines = state.lines.len, .scanned_bytes = state.length * 2 };
    }
    pub fn matches(self: *const Map, reader: d.Reader) !bool {
        const state = cast(@constCast(self));
        try state.check();
        _ = try reader.version();
        return state.reader.slot == reader.slot and state.reader.generation == reader.generation;
    }
    pub fn close(self: *Map) !void {
        const state = cast(self);
        if (state.closing) return error.Closed;
        state.closing = true;
        const allocator = state.allocator;
        allocator.free(state.lines);
        allocator.destroy(state);
    }
};
const State = struct {
    allocator: std.mem.Allocator,
    reader: d.Reader,
    lines: []Line,
    length: usize,
    bytes: usize,
    closing: bool = false,
    fn check(self: *const State) !void {
        if (self.closing) return error.Closed;
        _ = try self.reader.version();
    }
};
fn cast(map: *Map) *State {
    return @ptrCast(@alignCast(map));
}
fn append(output: ?[]Line, count: *usize, limit: usize, line: Line) !void {
    if (count.* == limit) return error.LineCapacityExceeded;
    if (output) |lines| lines[count.*] = line;
    count.* += 1;
}
fn scan(reader: d.Reader, output: ?[]Line, limit: usize, cancellation: ?*const Cancellation) !usize {
    if (cancellation) |cancel| try cancel.check();
    const length = try reader.byteLength();
    var cursor = try reader.cursor(.{ .start = 0, .end = length });
    var count: usize = 0;
    var start: u32 = 0;
    var utf16_start: u32 = 0;
    var units: u32 = 0;
    var cr = false;
    while (try cursor.next()) |segment| {
        if (cancellation) |cancel| try cancel.check();
        var at: usize = 0;
        while (at < segment.bytes.len) {
            const byte: u32 = @intCast(segment.start + at);
            const first = segment.bytes[at];
            const width = try std.unicode.utf8ByteSequenceLength(first);
            const scalar = try std.unicode.utf8Decode(segment.bytes[at..][0..width]);
            if (scalar == '\n' and cr) {
                units += 1;
                start = byte + 1;
                utf16_start = units;
            } else if (scalar == '\r' or scalar == '\n') {
                try append(output, &count, limit, .{ .start = start, .end = byte, .utf16_start = utf16_start, .utf16_end = units });
                units += 1;
                start = byte + 1;
                utf16_start = units;
            } else units += if (scalar > 0xffff) @as(u32, 2) else 1;
            cr = scalar == '\r';
            at += width;
        }
    }
    try append(output, &count, limit, .{ .start = start, .end = @intCast(length), .utf16_start = utf16_start, .utf16_end = units });
    return count;
}

fn fixture(allocator: std.mem.Allocator) !void {
    const document = try d.Document.create(allocator, std.Thread.getCurrentId(), "中😀\r\na\rb\n", .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    const map = try Map.create(allocator, reader, .{});
    defer map.close() catch unreachable;
    try std.testing.expectEqual(@as(usize, 4), (try map.stats()).lines);
    try std.testing.expectEqual(Position{ .line = 0, .character = 1 }, try map.toPosition(3));
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, try map.toPosition(7));
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, try map.toPosition(9));
    try std.testing.expectEqual(Position{ .line = 2, .character = 0 }, try map.toPosition(11));
    try std.testing.expectEqual(Position{ .line = 3, .character = 0 }, try map.toPosition(13));
    try std.testing.expectError(error.InsideLineEnding, map.toPosition(8));
    try std.testing.expectError(error.InvalidBoundary, map.toPosition(4));
    try std.testing.expectError(error.InvalidBoundary, map.toByte(.{ .line = 0, .character = 2 }));
    try std.testing.expectEqual(@as(usize, 7), try map.toByte(.{ .line = 0, .character = 999 }));
    try std.testing.expectEqual(@as(usize, 11), try map.toByte(.{ .line = 2, .character = 0 }));
    try std.testing.expectError(error.InvalidPosition, map.toByte(.{ .line = 4, .character = 0 }));
    try std.testing.expectError(error.InvalidRange, map.toRange(.{ .start = .{ .line = 2, .character = 1 }, .end = .{ .line = 0, .character = 0 } }));
    try std.testing.expectError(error.ReadersAlive, snapshot.close());
}
test "UTF16 positions distinguish CR LF CRLF scalar and surrogate boundaries with exact ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, fixture, .{});
}

test "worker preparation transfers immutable metadata while the original Reader stays borrowed" {
    const document = try d.Document.create(std.testing.allocator, std.Thread.getCurrentId(), "😀\r\n" ** 1500, .{});
    defer document.close() catch unreachable;
    const snapshot = try document.snapshot();
    defer snapshot.close() catch unreachable;
    const reader = try snapshot.borrowReader();
    defer reader.release() catch unreachable;
    const Worker = struct {
        reader: d.Reader,
        map: ?*Map = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.map = Map.create(std.testing.allocator, self.reader, .{}) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .reader = reader };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    const map = worker.map.?;
    defer map.close() catch unreachable;
    for (0..1500) |line| {
        try std.testing.expectEqual(Position{ .line = @intCast(line), .character = 0 }, try map.toPosition(line * 6));
        try std.testing.expectEqual(@as(usize, line * 6 + 4), try map.toByte(.{ .line = @intCast(line), .character = 2 }));
    }
    try std.testing.expectError(error.LineCapacityExceeded, Map.create(std.testing.allocator, reader, .{ .lines = 10 }));
    try std.testing.expectError(error.PositionCapacityExceeded, Map.create(std.testing.allocator, reader, .{ .bytes = @sizeOf(State) }));
    try std.testing.expectError(error.WorkCapacityExceeded, Map.create(std.testing.allocator, reader, .{ .work_bytes = 100 }));
    var cancellation: Cancellation = .{};
    cancellation.request();
    try std.testing.expectError(error.Cancelled, Map.create(std.testing.allocator, reader, .{ .cancellation = &cancellation }));
}
