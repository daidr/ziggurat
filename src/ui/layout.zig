const std = @import("std");
pub const Rect = @import("input.zig").Rect;
pub const Size = struct { width: f32 = 0, height: f32 = 0 };
pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Insets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    pub fn all(value: f32) Insets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};
pub const Axis = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between };
pub const Overflow = enum { visible, clip };
pub const Error = error{ InvalidGeometry, InvalidConstraints, GeometryOverflow, TooManyItems, OutputTooSmall };
pub const max_items = 256;

pub const Constraints = struct {
    min: Size = .{},
    max: Size = .{ .width = std.math.inf(f32), .height = std.math.inf(f32) },
    pub fn valid(self: Constraints) bool {
        return validSize(self.min) and !std.math.isNan(self.max.width) and !std.math.isNan(self.max.height) and self.max.width >= self.min.width and self.max.height >= self.min.height;
    }
    pub fn constrain(self: Constraints, size: Size) Size {
        return .{ .width = std.math.clamp(size.width, self.min.width, self.max.width), .height = std.math.clamp(size.height, self.min.height, self.max.height) };
    }
};

pub const Item = struct {
    preferred: Size,
    /// Intrinsic content floor. The main-axis maximum may cap the automatic
    /// floor; main_minimum explicitly replaces it, including an explicit zero.
    content_minimum: Size = .{},
    main_minimum: ?f32 = null,
    /// Percentage of the complete inner main extent, before subtracting gaps.
    /// Intrinsic measure ignores this when no parent main extent is known.
    main_max_percent: ?f32 = null,
    constraints: Constraints = .{},
    grow: f32 = 0,
    shrink: f32 = 1,
    alignment: ?Align = null,
    /// Cross-start to baseline in DIP. Participating items use their preferred
    /// cross extent, overriding ordinary alignment, and share one baseline.
    baseline: ?f32 = null,
};
pub const Options = struct {
    axis: Axis = .column,
    padding: Insets = .{},
    gap: f32 = 0,
    alignment: Align = .stretch,
    justify: Justify = .start,
    overflow: Overflow = .clip,
};
pub const Result = struct {
    inner: Rect,
    content_size: Size,
    overflow: Size,
    clip: ?Rect,
};
pub const Measurement = struct { minimum: Size, preferred: Size };

pub fn validSize(size: Size) bool {
    return nonnegative(size.width) and nonnegative(size.height);
}
pub fn validRect(rect: Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and validSize(.{ .width = rect.width, .height = rect.height });
}
fn nonnegative(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}
fn scalar(value: f64) Error!f32 {
    if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.GeometryOverflow;
    return @floatCast(value);
}
fn mainSize(axis: Axis, size: Size) f64 {
    return if (axis == .row) size.width else size.height;
}
fn crossSize(axis: Axis, size: Size) f64 {
    return if (axis == .row) size.height else size.width;
}

/// Intersection uses half-open rectangles; a disjoint result has zero area.
/// Inputs must have finite coordinates and nonnegative finite dimensions.
pub fn intersect(a: Rect, b: Rect) Rect {
    const left: f64 = @max(a.x, b.x);
    const top: f64 = @max(a.y, b.y);
    const right = @min(@as(f64, a.x) + a.width, @as(f64, b.x) + b.width);
    const bottom = @min(@as(f64, a.y) + a.height, @as(f64, b.y) + b.height);
    return .{ .x = @floatCast(left), .y = @floatCast(top), .width = @floatCast(@max(0, right - left)), .height = @floatCast(@max(0, bottom - top)) };
}

pub fn inset(bounds: Rect, padding: Insets) Error!Rect {
    if (!validRect(bounds) or !nonnegative(padding.top) or !nonnegative(padding.right) or !nonnegative(padding.bottom) or !nonnegative(padding.left)) return error.InvalidGeometry;
    return .{
        .x = try scalar(@as(f64, bounds.x) + @min(bounds.width, padding.left)),
        .y = try scalar(@as(f64, bounds.y) + @min(bounds.height, padding.top)),
        .width = @floatCast(@max(0, @as(f64, bounds.width) - padding.left - padding.right)),
        .height = @floatCast(@max(0, @as(f64, bounds.height) - padding.top - padding.bottom)),
    };
}

const Share = struct {
    index: usize,
    capacity: f64,
    weight: f64,
    fn less(_: void, a: Share, b: Share) bool {
        return a.capacity / a.weight < b.capacity / b.weight;
    }
};

// Weighted saturation is O(n log n), with bounded caller-independent scratch.
fn distribute(items: []const Item, minimums: []const f64, maximums: []const f64, lengths: []f64, amount: f64, growing: bool) void {
    var scratch: [max_items]Share = undefined;
    var count: usize = 0;
    for (items, 0..) |item, index| {
        const w: f64 = if (growing) item.grow else @as(f64, item.shrink) * lengths[index];
        const capacity = if (growing) maximums[index] - lengths[index] else lengths[index] - minimums[index];
        if (w == 0 or capacity <= 0) continue;
        scratch[count] = .{ .index = index, .capacity = capacity, .weight = w };
        count += 1;
    }
    const shares = scratch[0..count];
    std.sort.heap(Share, shares, {}, Share.less);
    var suffix_weight: [max_items + 1]f64 = undefined;
    suffix_weight[count] = 0;
    var reverse = count;
    while (reverse > 0) {
        reverse -= 1;
        suffix_weight[reverse] = suffix_weight[reverse + 1] + shares[reverse].weight;
    }
    var remaining = amount;
    var first: usize = 0;
    while (first < count) : (first += 1) {
        const share = shares[first];
        if (share.capacity > remaining / suffix_weight[first] * share.weight) break;
        lengths[share.index] += if (growing) share.capacity else -share.capacity;
        remaining = @max(0, remaining - share.capacity);
    }
    const weight = suffix_weight[first];
    if (weight > 0) for (shares[first..]) |share| {
        const change = @min(share.capacity, remaining / weight * share.weight);
        lengths[share.index] += if (growing) change else -change;
    };
}

const Resolved = struct {
    minimum: f64,
    maximum: f64,
    preferred: f64,
    cross_minimum: f64,
    cross_maximum: f64,
    cross_preferred: f64,
};

fn resolve(axis: Axis, item: Item, parent_main: ?f64) Error!Resolved {
    if (!validSize(item.preferred) or !validSize(item.content_minimum) or !item.constraints.valid() or !nonnegative(item.grow) or !nonnegative(item.shrink)) return error.InvalidConstraints;
    if (item.main_minimum) |value| if (!nonnegative(value)) return error.InvalidConstraints;
    if (item.main_max_percent) |value| if (!nonnegative(value)) return error.InvalidConstraints;
    if (item.baseline) |value| if (!nonnegative(value) or value > crossSize(axis, item.constraints.max)) return error.InvalidConstraints;

    var maximum = mainSize(axis, item.constraints.max);
    if (parent_main) |available| {
        if (item.main_max_percent) |percent| maximum = @min(maximum, available * (@as(f64, percent) / 100));
    }
    // Explicit minima win a resolved maximum. The automatic content floor
    // alone is capped by it; ordinary absolute Constraints remain validated.
    const minimum = @max(mainSize(axis, item.constraints.min), if (item.main_minimum) |value| value else @min(mainSize(axis, item.content_minimum), maximum));
    maximum = @max(minimum, maximum);
    const cross_maximum = crossSize(axis, item.constraints.max);
    const cross_minimum = @max(@max(crossSize(axis, item.constraints.min), @min(crossSize(axis, item.content_minimum), cross_maximum)), item.baseline orelse 0);
    return .{
        .minimum = minimum,
        .maximum = maximum,
        .preferred = std.math.clamp(mainSize(axis, item.preferred), minimum, maximum),
        .cross_minimum = cross_minimum,
        .cross_maximum = cross_maximum,
        .cross_preferred = std.math.clamp(crossSize(axis, item.preferred), cross_minimum, cross_maximum),
    };
}

fn validateOptions(options: Options) Error!void {
    if (!nonnegative(options.gap) or !nonnegative(options.padding.top) or !nonnegative(options.padding.right) or !nonnegative(options.padding.bottom) or !nonnegative(options.padding.left)) return error.InvalidGeometry;
}

fn makeSize(axis: Axis, main: f64, cross: f64) Error!Size {
    return .{ .width = try scalar(if (axis == .row) main else cross), .height = try scalar(if (axis == .row) cross else main) };
}

/// Intrinsic sizes for an unknown parent main extent. Percentages are not
/// resolved from the result, so measuring an auto-sized parent has no cycle.
/// A later arrange resolves percentages once against its definite bounds.
pub fn measure(options: Options, items: []const Item) Error!Measurement {
    if (items.len > max_items) return error.TooManyItems;
    try validateOptions(options);
    const padding_main = if (options.axis == .row) @as(f64, options.padding.left) + options.padding.right else @as(f64, options.padding.top) + options.padding.bottom;
    const padding_cross = if (options.axis == .row) @as(f64, options.padding.top) + options.padding.bottom else @as(f64, options.padding.left) + options.padding.right;
    const gaps = if (items.len > 1) @as(f64, options.gap) * @as(f64, @floatFromInt(items.len - 1)) else 0;
    var minimum_main = padding_main + gaps;
    var preferred_main = minimum_main;
    var minimum_cross: f64 = 0;
    var preferred_cross: f64 = 0;
    var ascent: f64 = 0;
    var minimum_descent: f64 = 0;
    var preferred_descent: f64 = 0;
    for (items) |item| {
        const value = try resolve(options.axis, item, null);
        minimum_main += value.minimum;
        preferred_main += value.preferred;
        if (item.baseline) |baseline| {
            ascent = @max(ascent, baseline);
            minimum_descent = @max(minimum_descent, value.cross_minimum - baseline);
            preferred_descent = @max(preferred_descent, value.cross_preferred - baseline);
        } else {
            minimum_cross = @max(minimum_cross, value.cross_minimum);
            preferred_cross = @max(preferred_cross, value.cross_preferred);
        }
    }
    return .{
        .minimum = try makeSize(options.axis, minimum_main, padding_cross + @max(minimum_cross, ascent + minimum_descent)),
        .preferred = try makeSize(options.axis, preferred_main, padding_cross + @max(preferred_cross, ascent + preferred_descent)),
    };
}

/// One non-wrapping row or column. All sizes are DIP. No allocations occur.
/// Output storage belongs to the caller; use nested calls for container trees.
pub fn arrange(bounds: Rect, options: Options, items: []const Item, output: []Rect) Error!Result {
    if (items.len > max_items) return error.TooManyItems;
    if (output.len < items.len) return error.OutputTooSmall;
    try validateOptions(options);
    const inner = try inset(bounds, options.padding);
    _ = try scalar(@as(f64, bounds.x) + bounds.width);
    _ = try scalar(@as(f64, bounds.y) + bounds.height);
    const available = mainSize(options.axis, .{ .width = inner.width, .height = inner.height });
    const cross_available = crossSize(options.axis, .{ .width = inner.width, .height = inner.height });
    var lengths: [max_items]f64 = undefined;
    var minimums: [max_items]f64 = undefined;
    var maximums: [max_items]f64 = undefined;
    const gaps = if (items.len > 1) @as(f64, options.gap) * @as(f64, @floatFromInt(items.len - 1)) else 0;
    var total = gaps;
    var baseline: f64 = 0;
    for (items, 0..) |item, index| {
        const value = try resolve(options.axis, item, available);
        minimums[index] = value.minimum;
        maximums[index] = value.maximum;
        lengths[index] = value.preferred;
        total += lengths[index];
        if (item.baseline) |offset| baseline = @max(baseline, offset);
    }
    distribute(items, minimums[0..items.len], maximums[0..items.len], lengths[0..items.len], @abs(available - total), available >= total);
    total = gaps;
    // Saturating subtraction can lose a tiny floor beside a large preferred
    // extent. Preserve every hard bound, even if rounded shares leave overflow.
    for (lengths[0..items.len], minimums[0..items.len], maximums[0..items.len]) |*length, minimum, maximum| {
        length.* = std.math.clamp(length.*, minimum, maximum);
        total += length.*;
    }
    const free = @max(0, available - total);
    var cursor: f64 = switch (options.justify) {
        .center => free / 2,
        .end => free,
        else => 0,
    };
    const gap: f64 = options.gap + if (options.justify == .space_between and items.len > 1) free / @as(f64, @floatFromInt(items.len - 1)) else @as(f64, 0);
    var cross_extent: f64 = 0;
    var main_extent: f64 = 0;
    var pending: [max_items]Rect = undefined;
    for (items, 0..) |item, index| {
        const value = try resolve(options.axis, item, available);
        const alignment = item.alignment orelse options.alignment;
        const cross = if (item.baseline != null) value.cross_preferred else std.math.clamp(if (alignment == .stretch) cross_available else value.cross_preferred, value.cross_minimum, value.cross_maximum);
        const cross_free = @max(0, cross_available - cross);
        const cross_offset: f64 = if (item.baseline) |offset| baseline - offset else switch (alignment) {
            .center => cross_free / 2,
            .end => cross_free,
            else => 0,
        };
        cross_extent = @max(cross_extent, cross_offset + cross);
        main_extent = @max(main_extent, cursor + lengths[index]);
        pending[index] = .{
            .x = try scalar(@as(f64, inner.x) + if (options.axis == .row) cursor else cross_offset),
            .y = try scalar(@as(f64, inner.y) + if (options.axis == .row) cross_offset else cursor),
            .width = try scalar(if (options.axis == .row) lengths[index] else cross),
            .height = try scalar(if (options.axis == .row) cross else lengths[index]),
        };
        _ = try scalar(@as(f64, pending[index].x) + pending[index].width);
        _ = try scalar(@as(f64, pending[index].y) + pending[index].height);
        cursor += lengths[index] + gap;
    }
    const content_width = (if (options.axis == .row) main_extent else cross_extent) + options.padding.left + options.padding.right;
    const content_height = (if (options.axis == .row) cross_extent else main_extent) + options.padding.top + options.padding.bottom;
    const result: Result = .{
        .inner = inner,
        .content_size = .{ .width = try scalar(content_width), .height = try scalar(content_height) },
        .overflow = .{ .width = try scalar(@max(0, content_width - bounds.width)), .height = try scalar(@max(0, content_height - bounds.height)) },
        .clip = if (options.overflow == .clip) inner else null,
    };
    @memcpy(output[0..items.len], pending[0..items.len]);
    return result;
}

/// Bounded nested clipping storage, suitable for reuse during each draw.
pub fn ClipStack(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        items: [capacity]Rect = undefined,
        len: usize = 0,
        pub fn current(self: *const Self) ?Rect {
            return if (self.len == 0) null else self.items[self.len - 1];
        }
        pub fn push(self: *Self, bounds: Rect) error{ InvalidGeometry, ClipStackFull }!Rect {
            if (!validRect(bounds)) return error.InvalidGeometry;
            if (self.len == capacity) return error.ClipStackFull;
            const clip = if (self.current()) |parent| intersect(parent, bounds) else bounds;
            self.items[self.len] = clip;
            self.len += 1;
            return clip;
        }
        pub fn pop(self: *Self) error{ClipStackEmpty}!void {
            if (self.len == 0) return error.ClipStackEmpty;
            self.len -= 1;
        }
    };
}

test "row redistributes growth at max constraints and respects padding gap" {
    var output: [3]Rect = undefined;
    const result = try arrange(.{ .x = 10, .y = 20, .width = 150, .height = 60 }, .{ .axis = .row, .padding = Insets.all(10), .gap = 5 }, &.{
        .{ .preferred = .{ .width = 20, .height = 10 }, .grow = 1, .constraints = .{ .max = .{ .width = 30, .height = 40 } } },
        .{ .preferred = .{ .width = 20, .height = 10 }, .grow = 1 },
        .{ .preferred = .{ .width = 20, .height = 10 }, .grow = 1 },
    }, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 30), output[0].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), output[1].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 45), output[2].width, 0.001);
    try std.testing.expectEqual(@as(f32, 20), output[0].x);
    try std.testing.expectEqual(@as(f32, 40), output[1].height);
    try std.testing.expectEqual(@as(f32, 150), result.content_size.width);
    try std.testing.expectEqual(@as(f32, 0), result.overflow.width);
}

test "column shrink preserves minimums and reports unavoidable overflow" {
    var output: [2]Rect = undefined;
    const result = try arrange(.{ .x = 0, .y = 0, .width = 30, .height = 50 }, .{ .gap = 10 }, &.{
        .{ .preferred = .{ .width = 40, .height = 50 }, .constraints = .{ .min = .{ .width = 40, .height = 30 } } },
        .{ .preferred = .{ .width = 10, .height = 50 }, .constraints = .{ .min = .{ .height = 30 } } },
    }, &output);
    try std.testing.expectEqual(@as(f32, 30), output[0].height);
    try std.testing.expectEqual(@as(f32, 30), output[1].height);
    try std.testing.expectEqual(@as(f32, 20), result.overflow.height);
    try std.testing.expectEqual(@as(f32, 10), result.overflow.width);
    try std.testing.expectEqual(@as(f32, 30), result.clip.?.width);
}

test "growth preserves small weights after a large weighted item saturates" {
    var output: [2]Rect = undefined;
    _ = try arrange(.{ .x = 0, .y = 0, .width = 100, .height = 10 }, .{ .axis = .row }, &.{
        .{ .preferred = .{}, .grow = std.math.floatMax(f32), .constraints = .{ .max = .{ .width = 10 } } },
        .{ .preferred = .{}, .grow = 1 },
    }, &output);
    try std.testing.expectEqual(@as(f32, 10), output[0].width);
    try std.testing.expectEqual(@as(f32, 90), output[1].width);
}

test "layout rejects invalid geometry and undersized caller storage" {
    var output: [1]Rect = undefined;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expectError(error.InvalidGeometry, arrange(bounds, .{ .gap = std.math.nan(f32) }, &.{}, &output));
    try std.testing.expectError(error.OutputTooSmall, arrange(bounds, .{}, &.{.{ .preferred = .{} }}, &.{}));
    try std.testing.expectError(error.InvalidConstraints, arrange(bounds, .{}, &.{.{ .preferred = .{}, .constraints = .{ .min = .{ .width = 5 }, .max = .{ .width = 3 } } }}, &output));
}

test "nested clip intersections are bounded and empty edges stay empty" {
    var stack: ClipStack(2) = .{};
    _ = try stack.push(.{ .x = 0, .y = 0, .width = 50, .height = 40 });
    const clipped = try stack.push(.{ .x = 30, .y = 5, .width = 50, .height = 50 });
    try std.testing.expectEqual(@as(f32, 20), clipped.width);
    try std.testing.expectEqual(@as(f32, 35), clipped.height);
    try std.testing.expectError(error.ClipStackFull, stack.push(clipped));
    try stack.pop();
    try stack.pop();
    try std.testing.expectError(error.ClipStackEmpty, stack.pop());
    const empty = intersect(clipped, .{ .x = 50, .y = 5, .width = 10, .height = 20 });
    try std.testing.expectEqual(@as(f32, 0), empty.width);
}

test {
    _ = @import("layout_contract_tests.zig");
}
