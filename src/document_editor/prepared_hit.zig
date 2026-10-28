//! Immutable Prepared hit routing. Readers borrow existing validated geometry;
//! this module owns no window, text model, allocator, native SDK or global state.
const std = @import("std");

pub const Rect = extern struct { x: f32, y: f32, width: f32, height: f32 };
pub const Point = struct { x: f32, y: f32 };
pub const Mode = enum(u32) { ordinary, projected };
pub const Stop = extern struct { x: f32, affinity: u32, position: u64 };
pub const Line = extern struct { y: f32, height: f32, first: u32, count: u32 };
pub const Block = extern struct { first: u32, count: u32, y: f64, end: f64 };
pub const Placement = extern struct { block: u32, reserved: u32 = 0, y: f64, native_top: f64, height: f64 };
pub const Result = extern struct { position: u64, affinity: u32, reserved: u32 = 0 };
pub const Selection = struct { block: usize, line: usize, stop: usize };
pub const NativeLine = struct { y: f32, height: f32 };

/// Pointers borrow immutable arrays. A successful constructor must validate and
/// own all arrays before passing this descriptor to an unchecked query reader.
pub const Packet = extern struct {
    bounds: Rect,
    scroll_x: f64,
    mode: u32,
    block_count: u32,
    line_count: u32,
    stop_count: u32,
    placement_count: u32,
    reserved: u32 = 0,
    blocks: ?[*]const Block,
    lines: ?[*]const Line,
    stops: ?[*]const Stop,
    placements: ?[*]const Placement,
};
pub const Limits = struct { blocks: usize = 24, lines: usize = 4096, stops: usize = 32768, placements: usize = 768, work: u64 = 1024 * 1024, position: u64 = std.math.maxInt(u64) };
pub const Work = struct {
    remaining: u64,
    pub fn take(self: *Work, amount: usize) !void {
        if (amount > self.remaining) return error.WorkLimit;
        self.remaining -= @intCast(amount);
    }
};

pub fn nativeLineAt(reader: anytype, block: usize, y: f32) !usize {
    @setFloatMode(.strict);
    var low: usize = 0;
    var high = try reader.lineCount(block);
    if (high == 0) return error.InvalidParagraphMetrics;
    const count = high;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const line = try reader.nativeLine(block, middle);
        const end: f32 = line.y + line.height;
        if (y >= end) low = middle + 1 else high = middle;
    }
    return @min(low, count - 1);
}

pub fn nearestStop(stops: anytype, x: f32) !usize {
    @setFloatMode(.strict);
    const count = stops.len();
    if (count == 0) return error.InvalidParagraphMetrics;
    var low: usize = 0;
    var high = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (stops.at(middle).x < x) low = middle + 1 else high = middle;
    }
    var selected = @min(low, count - 1);
    if (selected > 0 and @abs(@as(f64, stops.at(selected - 1).x) - x) <= @abs(@as(f64, stops.at(selected).x) - x)) selected -= 1;
    return selected;
}

/// Selects only a real stop. The live reader applies its existing single
/// selected-result normalization; an owned packet already has that payload.
pub fn select(reader: anytype, point: Point) !Selection {
    @setFloatMode(.strict);
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidPoint;
    const bounds = reader.bounds();
    const local_y = @as(f64, point.y) - bounds.y;
    const x: f32 = @floatCast(@as(f64, point.x) - bounds.x + reader.scrollX());
    if (!std.math.isFinite(x)) return error.InvalidPoint;
    var block: usize = undefined;
    var native_y: f32 = undefined;
    switch (reader.mode()) {
        .ordinary => {
            const count = reader.blockCount();
            if (count == 0) return error.InvalidParagraphMetrics;
            block = count - 1;
            for (0..count) |at| {
                // Preserve the original ordinary comparison expression; its
                // two f32 operands must not be pre-rebased into another type.
                if (point.y - bounds.y < reader.block(at).end) {
                    block = at;
                    break;
                }
            }
            native_y = @floatCast(local_y - reader.block(block).y);
        },
        .projected => {
            const count = reader.placementCount();
            if (count == 0) return error.InvalidParagraphMetrics;
            var chosen: usize = 0;
            var closest = std.math.inf(f64);
            for (0..count) |at| {
                const placement = reader.placement(at);
                const distance = if (local_y < placement.y) placement.y - local_y else @max(0, local_y - placement.y - placement.height);
                if (distance < closest) {
                    chosen = at;
                    closest = distance;
                }
            }
            const placement = reader.placement(chosen);
            block = placement.block;
            native_y = @floatCast(placement.native_top + local_y - placement.y);
            if (local_y <= placement.y or local_y >= placement.y + placement.height) {
                const before = local_y <= placement.y;
                var found = false;
                for (0..try reader.lineCount(block)) |at| {
                    const line = try reader.nativeLine(block, at);
                    const center = @as(f64, line.y) + @as(f64, line.height) * 0.5;
                    if (center < placement.native_top or center >= placement.native_top + placement.height) continue;
                    native_y = @floatCast(center);
                    found = true;
                    if (before) break;
                }
                if (!found) return error.InvalidParagraphMetrics;
            }
        },
    }
    if (!std.math.isFinite(native_y)) return error.InvalidPoint;
    const line = try nativeLineAt(reader, block, native_y);
    return .{ .block = block, .line = line, .stop = try nearestStop(try reader.lineStops(block, line), x) };
}

pub const PacketReader = struct {
    packet: *const Packet,
    pub fn mode(self: PacketReader) Mode {
        return @fromBackingInt(@intCast(self.packet.mode));
    }
    pub fn bounds(self: PacketReader) Rect {
        return self.packet.bounds;
    }
    pub fn scrollX(self: PacketReader) f64 {
        return self.packet.scroll_x;
    }
    pub fn blockCount(self: PacketReader) usize {
        return self.packet.block_count;
    }
    pub fn block(self: PacketReader, at: usize) Block {
        return self.packet.blocks.?[at];
    }
    pub fn placementCount(self: PacketReader) usize {
        return self.packet.placement_count;
    }
    pub fn placement(self: PacketReader, at: usize) Placement {
        return self.packet.placements.?[at];
    }
    pub fn lineCount(self: PacketReader, at: usize) !usize {
        return self.block(at).count;
    }
    pub fn nativeLine(self: PacketReader, at: usize, line: usize) !NativeLine {
        const value = self.packet.lines.?[self.block(at).first + line];
        return .{ .y = value.y, .height = value.height };
    }
    pub fn lineStops(self: PacketReader, at: usize, line: usize) !PacketStops {
        const value = self.packet.lines.?[self.block(at).first + line];
        return .{ .items = self.packet.stops.?[value.first..][0..value.count] };
    }
};
pub const PacketStops = struct {
    items: []const Stop,
    pub fn len(self: PacketStops) usize {
        return self.items.len;
    }
    pub fn at(self: PacketStops, index: usize) Stop {
        return self.items[index];
    }
};

fn finite(value: f64) bool {
    return std.math.isFinite(value) and @abs(value) <= 1e12;
}
/// Construction-only complete validation, before an immutable owned copy can
/// be queried. Counts and quotas are checked before any array is dereferenced.
pub fn validate(packet: *const Packet, limits: Limits) !void {
    @setFloatMode(.strict);
    if (packet.block_count > limits.blocks or packet.line_count > limits.lines or packet.stop_count > limits.stops or packet.placement_count > limits.placements) return error.CapacityExceeded;
    if (packet.mode > 1 or packet.reserved != 0 or packet.block_count == 0 or packet.line_count == 0 or packet.stop_count == 0 or
        packet.blocks == null or packet.lines == null or packet.stops == null or (packet.placement_count != 0 and packet.placements == null) or
        (packet.mode == 0 and packet.placement_count != 0) or (packet.mode == 1 and packet.placement_count == 0)) return error.InvalidHit;
    const b = packet.bounds;
    if (!finite(b.x) or !finite(b.y) or !finite(b.width) or !finite(b.height) or b.width <= 0 or b.height <= 0 or !finite(packet.scroll_x) or packet.scroll_x < 0 or packet.scroll_x > 16 * 1024 * 1024) return error.InvalidHit;
    var work: Work = .{ .remaining = limits.work };
    var covered_lines: usize = 0;
    var covered_stops: usize = 0;
    for (packet.blocks.?[0..packet.block_count]) |item| {
        try work.take(1);
        if (item.first != covered_lines or item.count == 0 or item.count > packet.line_count - covered_lines or !finite(item.y) or !finite(item.end) or item.end <= item.y) return error.InvalidHit;
        var last_end: f32 = -std.math.inf(f32);
        for (packet.lines.?[item.first..][0..item.count]) |line| {
            try work.take(1);
            const end: f32 = line.y + line.height;
            if (!finite(line.y) or !finite(line.height) or line.height <= 0 or !finite(end) or end < last_end or line.first != covered_stops or line.count > packet.stop_count - covered_stops) return error.InvalidHit;
            last_end = end;
            var last_x: f32 = -std.math.inf(f32);
            for (packet.stops.?[line.first..][0..line.count]) |stop| {
                try work.take(1);
                if (!finite(stop.x) or stop.x < last_x or stop.affinity > 1 or stop.position > limits.position) return error.InvalidHit;
                last_x = stop.x;
            }
            covered_stops += line.count;
        }
        covered_lines += item.count;
    }
    if (covered_lines != packet.line_count or covered_stops != packet.stop_count) return error.InvalidHit;
    if (packet.placements) |items| for (items[0..packet.placement_count]) |placement| {
        try work.take(1);
        if (placement.block >= packet.block_count or placement.reserved != 0 or !finite(placement.y) or !finite(placement.native_top) or !finite(placement.height) or placement.height <= 0 or !finite(placement.y + placement.height) or !finite(placement.native_top + placement.height)) return error.InvalidHit;
    };
}

pub fn query(packet: *const Packet, point: Point) !Result {
    const reader: PacketReader = .{ .packet = packet };
    const selected = try select(reader, point);
    const stop = (try reader.lineStops(selected.block, selected.line)).at(selected.stop);
    return .{ .position = stop.position, .affinity = stop.affinity };
}

comptime {
    if (@sizeOf(Stop) != 16 or @sizeOf(Line) != 16 or @sizeOf(Block) != 24 or @sizeOf(Placement) != 32 or @sizeOf(Result) != 16) @compileError("Prepared hit record ABI");
    if (@sizeOf(usize) == 8 and @sizeOf(Packet) != 80) @compileError("Prepared hit packet ABI");
}

test "ordinary native coordinates preserve the off-viewport leading stop" {
    const blocks = [_]Block{.{ .first = 0, .count = 1, .y = 0, .end = 28 }};
    const lines = [_]Line{.{ .y = 0, .height = 28, .first = 0, .count = 3 }};
    const stops = [_]Stop{ .{ .x = 0, .position = 0, .affinity = 1 }, .{ .x = 15, .position = 1, .affinity = 1 }, .{ .x = 30, .position = 2, .affinity = 1 } };
    const packet: Packet = .{ .bounds = .{ .x = 8, .y = 8, .width = 160, .height = 48 }, .scroll_x = 1, .mode = 0, .block_count = 1, .line_count = 1, .stop_count = 3, .placement_count = 0, .blocks = &blocks, .lines = &lines, .stops = &stops, .placements = null };
    try validate(&packet, .{});
    try std.testing.expectEqual(@as(u64, 0), (try query(&packet, .{ .x = 8, .y = 22 })).position);
    try std.testing.expectEqual(@as(u64, 1), (try query(&packet, .{ .x = 16, .y = 22 })).position);
}

test "projected placement ties and boundary clamps retain the first route" {
    const blocks = [_]Block{.{ .first = 0, .count = 2, .y = 0, .end = 20 }};
    const lines = [_]Line{ .{ .y = 0, .height = 10, .first = 0, .count = 2 }, .{ .y = 10, .height = 10, .first = 2, .count = 2 } };
    const stops = [_]Stop{ .{ .x = 0, .position = 0, .affinity = 1 }, .{ .x = 10, .position = 1, .affinity = 1 }, .{ .x = 0, .position = 2, .affinity = 1 }, .{ .x = 10, .position = 3, .affinity = 1 } };
    var placements = [_]Placement{ .{ .block = 0, .y = 0, .native_top = 0, .height = 10 }, .{ .block = 0, .y = 10, .native_top = 10, .height = 10 } };
    var packet: Packet = .{ .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 80 }, .scroll_x = 0, .mode = 1, .block_count = 1, .line_count = 2, .stop_count = 4, .placement_count = 2, .blocks = &blocks, .lines = &lines, .stops = &stops, .placements = &placements };
    try validate(&packet, .{});
    try std.testing.expectEqual(@as(u64, 0), (try query(&packet, .{ .x = 0, .y = 10 })).position);
    try std.testing.expectEqual(@as(u64, 2), (try query(&packet, .{ .x = 0, .y = 10.000001 })).position);
    placements[1].y = 20;
    try std.testing.expectEqual(@as(u64, 0), (try query(&packet, .{ .x = 0, .y = 15 })).position);
    try std.testing.expectEqual(@as(u64, 2), (try query(&packet, .{ .x = 0, .y = 15.000001 })).position);
    packet.mode = 0;
    packet.placement_count = 0;
    try validate(&packet, .{});
    try std.testing.expectEqual(@as(u64, 2), (try query(&packet, .{ .x = 0, .y = 10 })).position);
}

test "same-X entered side and midpoint predecessor do not sort result payload" {
    const stops = [_]Stop{ .{ .x = 0, .position = 9, .affinity = 1 }, .{ .x = 0, .position = 1, .affinity = 0 }, .{ .x = 10, .position = 7, .affinity = 1 } };
    const reader: PacketStops = .{ .items = &stops };
    try std.testing.expectEqual(@as(usize, 0), try nearestStop(reader, 0));
    try std.testing.expectEqual(@as(usize, 1), try nearestStop(reader, 0.000001));
    try std.testing.expectEqual(@as(usize, 1), try nearestStop(reader, 5));
    try std.testing.expectEqual(@as(usize, 2), try nearestStop(reader, 5.000001));
}

test "construction rejects poisoned counts before pointers and enforces work" {
    var packet: Packet = .{ .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 80 }, .scroll_x = 0, .mode = 0, .block_count = 25, .line_count = 1, .stop_count = 1, .placement_count = 0, .blocks = @ptrFromInt(8), .lines = @ptrFromInt(8), .stops = @ptrFromInt(8), .placements = null };
    try std.testing.expectError(error.CapacityExceeded, validate(&packet, .{}));
    const blocks = [_]Block{.{ .first = 0, .count = 1, .y = 0, .end = 10 }};
    const lines = [_]Line{.{ .y = 0, .height = 10, .first = 0, .count = 1 }};
    const stops = [_]Stop{.{ .x = 0, .position = 0, .affinity = 1 }};
    packet.block_count = 1;
    packet.blocks = &blocks;
    packet.lines = &lines;
    packet.stops = &stops;
    try std.testing.expectError(error.WorkLimit, validate(&packet, .{ .work = 2 }));
    try validate(&packet, .{ .work = 3 });
    packet.line_count = 2;
    try std.testing.expectError(error.CapacityExceeded, validate(&packet, .{ .lines = 1 }));
    packet.line_count = 1;
    packet.mode = 7;
    try std.testing.expectError(error.InvalidHit, validate(&packet, .{}));
    packet.mode = 0;
    try std.testing.expectError(error.InvalidPoint, query(&packet, .{ .x = std.math.nan(f32), .y = 0 }));
}

test "fractional rebase rounds native coordinates before the midpoint decision" {
    const blocks = [_]Block{.{ .first = 0, .count = 1, .y = 0, .end = 10 }};
    const lines = [_]Line{.{ .y = 0, .height = 10, .first = 0, .count = 2 }};
    const stops = [_]Stop{ .{ .x = 0, .position = 0, .affinity = 1 }, .{ .x = 15, .position = 1, .affinity = 1 } };
    const packet: Packet = .{ .bounds = .{ .x = -8.25, .y = -3.5, .width = 80, .height = 40 }, .scroll_x = 1.375, .mode = 0, .block_count = 1, .line_count = 1, .stop_count = 2, .placement_count = 0, .blocks = &blocks, .lines = &lines, .stops = &stops, .placements = null };
    try validate(&packet, .{});
    const midpoint: f32 = -2.125;
    const adjacent = std.math.nextAfter(f32, midpoint, std.math.inf(f32));
    const after = std.math.nextAfter(f32, adjacent, std.math.inf(f32));
    try std.testing.expectEqual(@as(u64, 0), (try query(&packet, .{ .x = midpoint, .y = 0 })).position);
    try std.testing.expectEqual(@as(u64, 0), (try query(&packet, .{ .x = adjacent, .y = 0 })).position);
    try std.testing.expectEqual(@as(u64, 1), (try query(&packet, .{ .x = after, .y = 0 })).position);
}
