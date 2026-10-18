const std = @import("std");

pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Shape = enum { bar, block, underline };
pub const Style = struct {
    shape: Shape = .bar,
    thickness: f32 = 1,
    /// Explicit geometry policy for EOF, empty lines and zero-advance cells.
    terminal_width: f32 = 1,
    block_alpha: u8 = 96,
    unfocused: enum { hidden, outline } = .hidden,
    enabled: bool = true,
    /// Host visual activity, combined with the editor's actual focus/binding.
    active: bool = true,

    pub fn validate(self: Style) !void {
        if (!std.math.isFinite(self.thickness) or self.thickness <= 0 or self.thickness > 65536 or
            !std.math.isFinite(self.terminal_width) or self.terminal_width <= 0 or self.terminal_width > 65536) return error.InvalidCaretStyle;
    }
};
pub const Paint = struct { rect: Rect, alpha: u8 = 255 };
pub const Marks = struct { items: [4]Paint = undefined, len: usize = 0 };
pub const Work = struct {
    remaining: usize,
    used: usize = 0,
    pub fn take(self: *Work, amount: usize) !void {
        if (amount > self.remaining) return error.CaretWorkCapacityExceeded;
        self.remaining -= amount;
        self.used += amount;
    }
};

/// Temporary logical-order index over borrowed immutable advance spans.
/// The same span slice must remain alive and unchanged until close. Neither
/// Index nor Query retains a layout or makes a native call.
pub const Index = struct {
    order: []u32,
    address: usize,
    pub fn init(allocator: std.mem.Allocator, spans: anytype, work: *Work) !Index {
        if (spans.len > std.math.maxInt(u32)) return error.CaretCellCapacityExceeded;
        const order = try allocator.alloc(u32, spans.len);
        errdefer allocator.free(order);
        for (spans, order, 0..) |span, *slot, i| {
            try work.take(1);
            if (span.start >= span.end or !valid(span.rect)) return error.InvalidCaretCell;
            slot.* = @intCast(i);
        }
        var result: Index = .{ .order = order, .address = @intFromPtr(spans.ptr) };
        var first = order.len / 2;
        while (first > 0) {
            first -= 1;
            try result.sift(spans, first, order.len, work);
        }
        var end = order.len;
        while (end > 1) {
            end -= 1;
            try work.take(1);
            std.mem.swap(u32, &order[0], &order[end]);
            try result.sift(spans, 0, end, work);
        }
        return result;
    }
    pub fn close(self: *Index, allocator: std.mem.Allocator) void {
        const order = self.order;
        self.order = &.{};
        self.address = 0;
        allocator.free(order);
    }
    fn less(spans: anytype, a: u32, b: u32, work: *Work) !bool {
        try work.take(1);
        const x = spans[a];
        const y = spans[b];
        if (x.start != y.start) return x.start < y.start;
        return a < b;
    }
    fn sift(self: *Index, spans: anytype, begin: usize, end: usize, work: *Work) !void {
        var at = begin;
        while (at < end / 2) {
            var child = at * 2 + 1;
            if (child + 1 < end and try less(spans, self.order[child], self.order[child + 1], work)) child += 1;
            if (!try less(spans, self.order[at], self.order[child], work)) break;
            try work.take(1);
            std.mem.swap(u32, &self.order[at], &self.order[child]);
            at = child;
        }
    }
    /// Complete cells of the following logical grapheme, confined to the
    /// native caret's visual line. If that affinity has no edge in this cell,
    /// return no cells: the caller uses its explicit terminal width instead.
    pub fn query(self: *const Index, spans: anytype, start: usize, end: usize, line: usize, x: f32, work: *Work) !Query {
        if (self.address == 0 or spans.len != self.order.len or @intFromPtr(spans.ptr) != self.address) return error.StaleCaretCells;
        if (start > end or !std.math.isFinite(x)) return error.InvalidCaretCell;
        var low: usize = 0;
        var high = self.order.len;
        while (low < high) {
            try work.take(1);
            const middle = low + (high - low) / 2;
            if (spans[self.order[middle]].start < start) low = middle + 1 else high = middle;
        }
        const first = low;
        var touches = false;
        while (low < self.order.len) : (low += 1) {
            try work.take(1);
            const span = spans[self.order[low]];
            if (span.start != start) break;
            if (span.end == end and span.line == line and span.rect.width > 0 and span.rect.height > 0 and
                x >= span.rect.x and x <= span.rect.x + span.rect.width) touches = true;
        }
        return .{ .indices = if (touches) self.order[first..low] else &.{}, .line = line, .end = end };
    }
};
pub const Query = struct {
    indices: []const u32,
    line: usize,
    end: usize,
    at: usize = 0,
    pub fn next(self: *Query, spans: anytype, work: *Work) !?Rect {
        while (self.at < self.indices.len) {
            try work.take(1);
            const span = spans[self.indices[self.at]];
            self.at += 1;
            if (span.end == self.end and span.line == self.line and span.rect.width > 0 and span.rect.height > 0)
                return .{ .x = span.rect.x, .y = span.rect.y, .width = span.rect.width, .height = span.rect.height };
        }
        return null;
    }
};

pub fn terminal(native: anytype, width: f32) Rect {
    return .{ .x = native.x, .y = native.y, .width = width, .height = native.height };
}
pub fn filled(rect: Rect, style: Style, background: bool) Paint {
    var result = rect;
    if (style.shape == .bar) result.width = style.thickness;
    if (style.shape == .underline) {
        result.height = @min(style.thickness, rect.height);
        result.y = rect.y + rect.height - result.height;
    }
    return .{ .rect = result, .alpha = if (background) style.block_alpha else 255 };
}
/// Nonoverlapping inside edges: fractional alpha never compounds at corners.
pub fn outlined(rect: Rect, thickness: f32) Marks {
    var result: Marks = .{};
    const t = @min(thickness, @min(rect.width, rect.height));
    if (2 * t >= rect.width or 2 * t >= rect.height) {
        result.items[0] = .{ .rect = rect };
        result.len = 1;
    } else {
        result.items[0] = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = t } };
        result.items[1] = .{ .rect = .{ .x = rect.x, .y = rect.y + rect.height - t, .width = rect.width, .height = t } };
        result.items[2] = .{ .rect = .{ .x = rect.x, .y = rect.y + t, .width = t, .height = rect.height - 2 * t } };
        result.items[3] = .{ .rect = .{ .x = rect.x + rect.width - t, .y = rect.y + t, .width = t, .height = rect.height - 2 * t } };
        result.len = 4;
    }
    return result;
}
fn valid(rect: anytype) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and rect.width >= 0 and rect.height >= 0 and
        std.math.isFinite(rect.x + rect.width) and std.math.isFinite(rect.y + rect.height);
}
pub fn validateRect(rect: anytype) !void {
    if (!valid(rect)) return error.InvalidCaretCell;
}

const TestSpan = struct { start: usize, end: usize, line: usize, rect: Rect };
test "logical index keeps all same-grapheme cells and actual visual line" {
    const spans = [_]TestSpan{
        .{ .start = 4, .end = 6, .line = 0, .rect = .{ .x = 0, .y = 0, .width = 5, .height = 10 } },
        .{ .start = 0, .end = 4, .line = 0, .rect = .{ .x = 5, .y = 0, .width = 3, .height = 10 } },
        .{ .start = 0, .end = 4, .line = 0, .rect = .{ .x = 9, .y = 0, .width = 2, .height = 10 } },
        .{ .start = 0, .end = 4, .line = 1, .rect = .{ .x = 0, .y = 10, .width = 8, .height = 10 } },
    };
    var work: Work = .{ .remaining = 1000 };
    var index = try Index.init(std.testing.allocator, &spans, &work);
    defer index.close(std.testing.allocator);
    var query = try index.query(&spans, 0, 4, 0, 8, &work);
    try std.testing.expectEqual(spans[1].rect, (try query.next(&spans, &work)).?);
    try std.testing.expectEqual(spans[2].rect, (try query.next(&spans, &work)).?);
    try std.testing.expectEqual(null, try query.next(&spans, &work));
    var wrapped = try index.query(&spans, 0, 4, 1, 8, &work);
    try std.testing.expectEqual(spans[3].rect, (try wrapped.next(&spans, &work)).?);
    var detached = try index.query(&spans, 0, 4, 0, 30, &work);
    try std.testing.expectEqual(null, try detached.next(&spans, &work));
}
test "more than sixteen cells are neither truncated nor merged" {
    var spans: [33]TestSpan = undefined;
    for (&spans, 0..) |*span, i| span.* = .{ .start = 0, .end = 5, .line = 0, .rect = .{ .x = @floatFromInt(i * 2), .y = 0, .width = 1, .height = 10 } };
    var work: Work = .{ .remaining = 10000 };
    var index = try Index.init(std.testing.allocator, &spans, &work);
    defer index.close(std.testing.allocator);
    var query = try index.query(&spans, 0, 5, 0, 0, &work);
    var count: usize = 0;
    while (try query.next(&spans, &work)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 33), count);
    work.remaining = 0;
    try std.testing.expectError(error.CaretWorkCapacityExceeded, index.query(&spans, 0, 5, 0, 0, &work));
}
test "style validates before paint and outline does not overlap corners" {
    try std.testing.expectError(error.InvalidCaretStyle, (Style{ .thickness = std.math.nan(f32) }).validate());
    try std.testing.expectError(error.InvalidCaretStyle, (Style{ .terminal_width = 0 }).validate());
    const rect: Rect = .{ .x = 2, .y = 3, .width = 8, .height = 20 };
    const marks = outlined(rect, 1);
    var area: f32 = 0;
    for (marks.items[0..marks.len]) |mark| area += mark.rect.width * mark.rect.height;
    try std.testing.expectEqual(@as(f32, 8 * 20 - 6 * 18), area);
    try std.testing.expectEqual(@as(f32, 22), filled(rect, .{ .shape = .underline }, false).rect.y);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    const spans = [_]TestSpan{.{ .start = 0, .end = 1, .line = 0, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 2 } }};
    var work: Work = .{ .remaining = 20 };
    var index = try Index.init(allocator, &spans, &work);
    defer index.close(allocator);
}
test "index OOM and work failure release candidate allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
    const spans = [_]TestSpan{.{ .start = 0, .end = 1, .line = 0, .rect = .{ .x = 0, .y = 0, .width = 1, .height = 2 } }};
    var work: Work = .{ .remaining = 0 };
    try std.testing.expectError(error.CaretWorkCapacityExceeded, Index.init(std.testing.allocator, &spans, &work));
}

test "logical index agrees with independent linear scan across shuffled cells" {
    var random = std.Random.DefaultPrng.init(0x6c656c6c);
    var spans: [97]TestSpan = undefined;
    for (0..20) |_| {
        for (&spans) |*span| {
            const start = random.random().uintLessThan(usize, 9) * 4;
            span.* = .{ .start = start, .end = start + 4, .line = random.random().uintLessThan(usize, 3), .rect = .{ .x = @floatFromInt(random.random().uintLessThan(u8, 5)), .y = 0, .width = 2, .height = 10 } };
        }
        var work: Work = .{ .remaining = 100000 };
        var index = try Index.init(std.testing.allocator, &spans, &work);
        defer index.close(std.testing.allocator);
        for (0..9) |g| for (0..3) |line| {
            var touches = false;
            for (spans) |span| if (span.start == g * 4 and span.line == line and span.rect.x == 0) {
                touches = true;
            };
            var query = try index.query(&spans, g * 4, g * 4 + 4, line, 0, &work);
            if (touches) for (spans) |span| if (span.start == g * 4 and span.line == line) {
                try std.testing.expectEqual(span.rect, (try query.next(&spans, &work)).?);
            };
            try std.testing.expectEqual(null, try query.next(&spans, &work));
        };
        index.close(std.testing.allocator);
        try std.testing.expectError(error.StaleCaretCells, index.query(&spans, 0, 4, 0, 0, &work));
    }
}
