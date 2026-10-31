const std = @import("std");
const regex = @import("snippet_regex.zig");
const Range = regex.Range;
pub const Limits = struct { source_bytes: usize = 4096, parts: usize = 256, bytes: usize = 1024 * 1024, work: usize = 1024 * 1024, cancellation: ?*const std.atomic.Value(bool) = null };
const Part = struct {
    kind: enum { literal, capture, upcase, downcase, capitalize, conditional },
    index: usize = 0,
    value: Range = .{ .start = 0, .end = 0 },
    alternative: Range = .{ .start = 0, .end = 0 },
};
/// Immutable linear owner. Capture offsets remain UTF16 code-unit offsets;
/// literals are copied and never point into the caller's format string.
pub const Format = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    parts: []Part,
    literals: []u16,
    fallback: bool,
    owned_bytes: usize,
    peak_bytes: usize,
    compile_work: usize,
    live: bool = true,
    pub fn compile(allocator: std.mem.Allocator, source: []const u8, limits: Limits) !Format {
        if (limits.source_bytes > 65536 or limits.parts == 0 or limits.parts > 4096 or limits.bytes < @sizeOf(Format) or limits.bytes > 64 * 1024 * 1024 or limits.work == 0 or limits.work > 128 * 1024 * 1024) return error.InvalidLimits;
        var work: regex.Work = .{ .limit = limits.work, .cancellation = limits.cancellation };
        try work.charge(0);
        if (source.len > limits.source_bytes) return error.CapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        var budget: Budget = .{ .child = allocator, .limit = limits.bytes - @sizeOf(Format) };
        var builder: Builder = .{ .allocator = budget.allocator(), .source = source, .limits = limits, .work = work };
        var builder_live = true;
        defer if (builder_live) builder.deinit();
        var result = builder.build(allocator, &budget) catch |err| return if (err == error.OutOfMemory and budget.denied) error.CapacityExceeded else err;
        errdefer result.deinit() catch unreachable;
        builder_live = false;
        builder.deinit();
        try builder.work.charge(0);
        return result;
    }
    fn check(self: *const Format) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (!self.live) return error.Closed;
    }
    pub fn deinit(self: *Format) !void {
        try self.check();
        self.live = false;
        const allocator = self.allocator;
        const parts = self.parts;
        const literals = self.literals;
        self.parts = &.{};
        self.literals = &.{};
        allocator.free(parts);
        allocator.free(literals);
    }
    /// Appends into caller scratch only. No allocator, callbacks or regex
    /// evaluation occur here; a failed candidate must not be published.
    pub fn append(self: *const Format, output: *Output, input: []const u16, match: ?regex.Match, work: *regex.Work) !void {
        try self.check();
        for (self.parts) |part| {
            try work.charge(1);
            const captured = if (match) |value| value.capture(part.index) else null;
            const text: []const u16 = if (captured) |range| blk: {
                if (range.start > range.end or range.end > input.len) return error.InvalidCapture;
                break :blk input[range.start..range.end];
            } else &.{};
            switch (part.kind) {
                .literal => try output.append(self.literals[part.value.start..part.value.end], work),
                .capture => try output.append(text, work),
                .conditional => {
                    const range = if (text.len != 0) part.value else part.alternative;
                    try output.append(self.literals[range.start..range.end], work);
                },
                .upcase, .downcase, .capitalize => {
                    try work.charge(text.len * 2);
                    if (text.len > output.buffer.len - output.len) return error.OutputCapacityExceeded;
                    for (text) |unit| if (unit > 127) return error.UnsupportedCaseMapping;
                    for (text, 0..) |unit, index| output.buffer[output.len + index] = switch (part.kind) {
                        .upcase => std.ascii.toUpper(@intCast(unit)),
                        .downcase => std.ascii.toLower(@intCast(unit)),
                        .capitalize => if (index == 0) std.ascii.toUpper(@intCast(unit)) else unit,
                        else => unreachable,
                    };
                    output.len += text.len;
                },
            }
        }
    }
};
/// Reusable UTF16 candidate output. An isolated surrogate is rejected before
/// touching the UTF8 destination, even when a non-u regex split a scalar.
pub const Output = struct {
    buffer: []u16,
    len: usize = 0,
    pub fn append(self: *Output, units: []const u16, work: *regex.Work) !void {
        try work.charge(units.len);
        if (units.len > self.buffer.len - self.len) return error.OutputCapacityExceeded;
        @memcpy(self.buffer[self.len..][0..units.len], units);
        self.len += units.len;
    }
    pub fn utf8Into(self: *const Output, destination: []u8, work: *regex.Work) ![]const u8 {
        try work.charge(self.len * 2);
        var bytes: usize = 0;
        var index: usize = 0;
        while (index < self.len) {
            const cp = try scalar(self.buffer[0..self.len], &index);
            bytes = std.math.add(usize, bytes, try std.unicode.utf8CodepointSequenceLength(@intCast(cp))) catch return error.OutputCapacityExceeded;
        }
        if (bytes > destination.len) return error.OutputCapacityExceeded;
        try work.charge(bytes);
        index = 0;
        var at: usize = 0;
        while (index < self.len) {
            const cp = try scalar(self.buffer[0..self.len], &index);
            at += try std.unicode.utf8Encode(@intCast(cp), destination[at..]);
        }
        return destination[0..at];
    }
};
fn scalar(input: []const u16, at: *usize) !u32 {
    const first = input[at.*];
    at.* += 1;
    if (first >= 0xd800 and first <= 0xdbff) {
        if (at.* == input.len) return error.UnsupportedSurrogateResult;
        const second = input[at.*];
        if (second < 0xdc00 or second > 0xdfff) return error.UnsupportedSurrogateResult;
        at.* += 1;
        return 0x10000 + ((@as(u32, first) - 0xd800) << 10) + second - 0xdc00;
    }
    if (first >= 0xdc00 and first <= 0xdfff) return error.UnsupportedSurrogateResult;
    return first;
}
const Builder = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    limits: Limits,
    work: regex.Work,
    at: usize = 0,
    parts: std.ArrayList(Part) = .empty,
    literals: std.ArrayList(u16) = .empty,
    fallback: bool = false,
    fn deinit(self: *Builder) void {
        self.parts.deinit(self.allocator);
        self.literals.deinit(self.allocator);
    }
    fn add(self: *Builder, part: Part) !void {
        try self.work.charge(1);
        if (self.parts.items.len == self.limits.parts) return error.CapacityExceeded;
        try self.parts.append(self.allocator, part);
    }
    fn take(self: *Builder, value: u8) bool {
        if (self.at < self.source.len and self.source[self.at] == value) {
            self.at += 1;
            return true;
        }
        return false;
    }
    fn number(self: *Builder) !usize {
        const begin = self.at;
        var index: usize = 0;
        while (self.at < self.source.len and std.ascii.isDigit(self.source[self.at])) : (self.at += 1) {
            try self.work.charge(1);
            index = std.math.mul(usize, index, 10) catch return error.InvalidFormat;
            index = std.math.add(usize, index, self.source[self.at] - '0') catch return error.InvalidFormat;
            if (index > 65535) return error.InvalidFormat;
        }
        if (begin == self.at) return error.InvalidFormat;
        return index;
    }
    fn text(self: *Builder, conditional: bool, colon: bool) !Range {
        const begin = self.literals.items.len;
        while (self.at < self.source.len) {
            const byte = self.source[self.at];
            if (conditional and (byte == '}' or (colon and byte == ':'))) break;
            if (byte == '$') {
                if (!conditional) break;
                // Branches are literal in this slice; nested capture/format
                // expressions are rejected instead of silently losing intent.
                if (self.at + 1 < self.source.len and (self.source[self.at + 1] == '{' or std.ascii.isDigit(self.source[self.at + 1]))) return error.UnsupportedNestedFormat;
            }
            if (byte == '\\') {
                self.at += 1;
                if (self.at == self.source.len or std.mem.indexOfScalar(u8, "\\/$}:$", self.source[self.at]) == null) return error.InvalidEscape;
            }
            const length = try std.unicode.utf8ByteSequenceLength(self.source[self.at]);
            try self.work.charge(length + 1);
            const cp = try std.unicode.utf8Decode(self.source[self.at..][0..length]);
            self.at += length;
            if (cp <= 0xffff) {
                try self.literals.append(self.allocator, @intCast(cp));
            } else {
                try self.literals.append(self.allocator, @intCast(0xd800 + ((cp - 0x10000) >> 10)));
                try self.literals.append(self.allocator, @intCast(0xdc00 + ((cp - 0x10000) & 1023)));
            }
        }
        return .{ .start = begin, .end = self.literals.items.len };
    }
    fn build(self: *Builder, child: std.mem.Allocator, budget: *const Budget) !Format {
        try self.work.charge(self.source.len);
        while (self.at < self.source.len) {
            if (!self.take('$')) {
                const value = try self.text(false, false);
                if (value.start != value.end) try self.add(.{ .kind = .literal, .value = value });
                continue;
            }
            const braced = self.take('{');
            var part: Part = .{ .kind = .capture, .index = try self.number() };
            if (braced) {
                if (self.take(':')) {
                    if (self.take('/')) {
                        const begin = self.at;
                        while (self.at < self.source.len and self.source[self.at] != '}') : (self.at += 1) try self.work.charge(1);
                        const name = self.source[begin..self.at];
                        part.kind = if (std.mem.eql(u8, name, "upcase")) .upcase else if (std.mem.eql(u8, name, "downcase")) .downcase else if (std.mem.eql(u8, name, "capitalize")) .capitalize else return error.UnsupportedFormat;
                    } else {
                        part.kind = .conditional;
                        if (self.take('+')) {
                            part.value = try self.text(true, false);
                        } else if (self.take('?')) {
                            part.value = try self.text(true, true);
                            if (!self.take(':')) return error.InvalidFormat;
                            part.alternative = try self.text(true, false);
                        } else {
                            _ = self.take('-');
                            part.alternative = try self.text(true, false);
                        }
                        self.fallback = self.fallback or part.alternative.start != part.alternative.end;
                    }
                }
                if (!self.take('}')) return error.InvalidFormat;
            }
            try self.add(part);
        }
        const parts = try self.parts.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(parts);
        const literals = try self.literals.toOwnedSlice(self.allocator);
        return .{ .allocator = child, .owner = std.Thread.getCurrentId(), .parts = parts, .literals = literals, .fallback = self.fallback, .owned_bytes = @sizeOf(Format) + parts.len * @sizeOf(Part) + literals.len * 2, .peak_bytes = budget.peak + @sizeOf(Format), .compile_work = self.work.used };
    }
};
const Budget = struct {
    child: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
    }
    fn alloc(ptr: *anyopaque, bytes: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        if (bytes > self.limit -| self.live) {
            self.denied = true;
            return null;
        }
        const result = self.child.rawAlloc(bytes, alignment, ret) orelse return null;
        self.live += bytes;
        self.peak = @max(self.peak, self.live);
        return result;
    }
    fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ptr));
        self.child.rawFree(bytes, alignment, ret);
        self.live -= bytes.len;
    }
};

fn expectFormat(source: []const u8, text: []const u8, expected: []const u8) !void {
    var program = try regex.Program.compile(std.testing.allocator, "(.*)", "u", .{});
    defer program.deinit() catch unreachable;
    var workspace = try regex.Workspace.init(std.testing.allocator, .{});
    defer workspace.deinit() catch unreachable;
    var format = try Format.compile(std.testing.allocator, source, .{});
    defer format.deinit() catch unreachable;
    var work: regex.Work = .{ .limit = 1024 * 1024 };
    var cursor = try workspace.begin(&program, text, &work);
    defer cursor.end();
    var units: [4096]u16 = undefined;
    var bytes: [4096]u8 = undefined;
    var output: Output = .{ .buffer = &units };
    try format.append(&output, workspace.units(), try cursor.next(), &work);
    try std.testing.expectEqualStrings(expected, try output.utf8Into(&bytes, &work));
}
test "bounded format captures cases conditional truth and literal branches" {
    try expectFormat("${1:/upcase}/${1:/downcase}/${1:/capitalize}", "hELLo", "HELLO/hello/HELLo");
    try expectFormat("$0/${1}/${42}", "猫😀", "猫😀/猫😀/");
    try expectFormat("${1:+yes}:${1:?then:else}:${1:-fallback}:${1:other}", "x", "yes:then::");
    try expectFormat("${1:+yes}:${1:?then:else}:${1:-fallback}:${1:other}", "", ":else:fallback:other");
    try expectFormat("\\$1-\\/-${1:?猫\\:😀:x}", "x", "$1-/-猫:😀");
    try std.testing.expectError(error.UnsupportedCaseMapping, expectFormat("${1:/upcase}", "猫", ""));
    try std.testing.expectError(error.UnsupportedNestedFormat, Format.compile(std.testing.allocator, "${1:?${2}:x}", .{}));
    try std.testing.expectError(error.UnsupportedFormat, Format.compile(std.testing.allocator, "${1:/camelcase}", .{}));
}
test "no-match fallback requires a nonempty else branch" {
    for ([_]struct { []const u8, bool }{ .{ "$1", false }, .{ "${1:+yes}", false }, .{ "${1:-}", false }, .{ "${1:?yes:}", false }, .{ "${1:-no}", true }, .{ "${1:猫}", true }, .{ "${1:?yes:no}", true } }) |case| {
        var format = try Format.compile(std.testing.allocator, case[0], .{});
        defer format.deinit() catch unreachable;
        try std.testing.expectEqual(case[1], format.fallback);
    }
}
fn formatCandidate(allocator: std.mem.Allocator) !void {
    var format = try Format.compile(allocator, "pre-$1${2:/upcase}${3:?猫:😀}-post", .{});
    defer format.deinit() catch unreachable;
}
test "format candidate allocation failure and UTF16 output publication bounds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, formatCandidate, .{});
    try std.testing.expectError(error.CapacityExceeded, Format.compile(std.testing.allocator, "$1$2", .{ .parts = 1 }));
    var bytes: [8]u8 = @splat(0xaa);
    var work: regex.Work = .{ .limit = 100 };
    const broken: Output = .{ .buffer = @constCast(&[_]u16{0xd83d}), .len = 1 };
    try std.testing.expectError(error.UnsupportedSurrogateResult, broken.utf8Into(&bytes, &work));
    try std.testing.expectEqual(@as([8]u8, @splat(0xaa)), bytes);
    const valid: Output = .{ .buffer = @constCast(&[_]u16{ 0xd83d, 0xde00 }), .len = 2 };
    try std.testing.expectError(error.OutputCapacityExceeded, valid.utf8Into(bytes[0..3], &work));
    try std.testing.expectEqual(@as([8]u8, @splat(0xaa)), bytes);
}
