const std = @import("std");
const layout = @import("layout.zig");
pub const Rect = layout.Rect;
pub const Size = layout.Size;
pub const max_tracks = 64;
pub const max_items = 256;
pub const Error = error{ InvalidGeometry, InvalidTrack, InvalidPlacement, PlacementOverlap, GridFull, TooManyTracks, TooManyItems, OutputTooSmall, GeometryOverflow };

/// A fixed track has equal min/max. fr == 0 uses preferred content sizing;
/// positive fr shares remaining space after intrinsic minimum constraints.
pub const Track = struct {
    min: f32 = 0,
    max: f32 = std.math.inf(f32),
    fr: f32 = 0,
    pub fn fixed(size: f32) Track {
        return .{ .min = size, .max = size };
    }
    pub fn fraction(weight: f32) Track {
        return .{ .fr = weight };
    }
    pub fn minmax(minimum: f32, maximum: f32, weight: f32) Track {
        return .{ .min = minimum, .max = maximum, .fr = weight };
    }
};
pub const Item = struct {
    row: usize,
    column: usize,
    row_span: usize = 1,
    column_span: usize = 1,
    minimum: Size = .{},
    preferred: Size = .{},
    align_x: ?layout.Align = null,
    align_y: ?layout.Align = null,
};
pub const Span = union(enum) { count: usize, to_end };
pub const AutoItem = struct {
    row: ?usize = null,
    column: ?usize = null,
    row_span: Span = .{ .count = 1 },
    column_span: Span = .{ .count = 1 },
    minimum: Size = .{},
    preferred: Size = .{},
    align_x: ?layout.Align = null,
    align_y: ?layout.Align = null,
};
pub const Placement = struct { row: usize, column: usize, row_span: usize, column_span: usize };
pub const PlacementMetrics = struct { candidate_positions: usize = 0, row_masks: usize = 0 };
pub const PlacementOptions = struct { reject_explicit_overlap: bool = false };
pub const PlacementResult = struct {
    row_count: usize,
    column_count: usize,
    occupancy: [max_tracks]u64,
    metrics: PlacementMetrics,
};
pub const AutoOptions = struct {
    layout: Options = .{},
    implicit_column: Track = .{},
    implicit_row: Track = .{},
    placement: PlacementOptions = .{},
};
pub const AutoResult = struct { layout: Result, placement: PlacementResult };
pub const Measurement = struct { minimum: Size, preferred: Size };
pub const HeightMeasurement = struct { minimum: f32 = 0, preferred: f32 };
pub const Measurer = struct {
    context: *anyopaque,
    intrinsic: *const fn (*anyopaque, usize) anyerror!Measurement,
    constrained_height: *const fn (*anyopaque, usize, f32) anyerror!HeightMeasurement,
};
pub const Options = struct {
    padding: layout.Insets = .{},
    column_gap: f32 = 0,
    row_gap: f32 = 0,
    align_x: layout.Align = .stretch,
    align_y: layout.Align = .stretch,
    justify_columns: layout.Justify = .start,
    justify_rows: layout.Justify = .start,
    overflow: layout.Overflow = .clip,
};
pub const Metrics = struct {
    item_visits: usize = 0,
    track_visits: usize = 0,
    capacity_comparisons: usize = 0,
};
pub const Result = struct {
    inner: Rect,
    content_size: Size,
    overflow: Size,
    clip: ?Rect,
    /// Fixed/max-constrained cells may be smaller than an item's minimum.
    unmet_minimum_items: usize,
    metrics: Metrics,
    column_count: usize,
    row_count: usize,
    column_widths: [max_tracks]f32 = @splat(0),
    row_heights: [max_tracks]f32 = @splat(0),
};
const Axis = struct {
    tracks: []const Track,
    sizes: [max_tracks]f64 = @splat(0),
    positions: [max_tracks]f64 = @splat(0),
    gap: f64,
    used: f64 = 0,
};
const Candidate = struct { index: usize, capacity: f64, weight: f64 };
const SortContext = struct {
    metrics: *Metrics,
    fn lessThan(self: SortContext, a: Candidate, b: Candidate) bool {
        self.metrics.capacity_comparisons += 1;
        return a.capacity / a.weight < b.capacity / b.weight;
    }
};
const Growth = enum { minimum, preferred, fraction };

fn mask(column: usize, count: usize) u64 {
    if (count == 64) return std.math.maxInt(u64);
    return ((@as(u64, 1) << @as(u6, @intCast(count))) - 1) << @as(u6, @intCast(column));
}
fn fits(occupancy: *const [max_tracks]u64, row: usize, count: usize, bits: u64, metrics: *PlacementMetrics) bool {
    if (row >= max_tracks or count > max_tracks - row) return false;
    for (occupancy[row..][0..count]) |used| {
        metrics.row_masks += 1;
        if (used & bits != 0) return false;
    }
    return true;
}
fn occupy(occupancy: *[max_tracks]u64, placement: Placement) void {
    const bits = mask(placement.column, placement.column_span);
    for (occupancy[placement.row..][0..placement.row_span]) |*row| row.* |= bits;
}
fn resolveSpan(span: Span, start: usize, configured: usize, limit: usize) ?usize {
    if (start >= limit) return null;
    const count = switch (span) {
        .count => |value| value,
        .to_end => if (start < configured) configured - start else return null,
    };
    return if (count > 0 and count <= limit - start) count else null;
}
fn placementAt(item: AutoItem, row: usize, column: usize, column_count: usize, configured_columns: usize, configured_rows: usize) ?Placement {
    return .{ .row = row, .column = column, .row_span = resolveSpan(item.row_span, row, configured_rows, max_tracks) orelse return null, .column_span = resolveSpan(item.column_span, column, configured_columns, column_count) orelse return null };
}

/// Reserve explicit cells, then row-fixed items, then sparse row-major items.
/// Column-fixed and fully automatic items share a monotonically advancing cursor.
pub fn placeAuto(explicit_column_count: usize, explicit_row_count: usize, items: []const AutoItem, options: PlacementOptions, output: []Placement) Error!PlacementResult {
    if (explicit_column_count > max_tracks or explicit_row_count > max_tracks) return error.TooManyTracks;
    if (items.len > max_items) return error.TooManyItems;
    if (output.len < items.len) return error.OutputTooSmall;
    const configured_rows = @max(1, explicit_row_count);
    const configured_columns = @max(1, explicit_column_count);
    var column_count = configured_columns;
    for (items) |item| {
        _ = resolveSpan(item.row_span, item.row orelse 0, configured_rows, max_tracks) orelse return error.InvalidPlacement;
        const start = item.column orelse 0;
        const count = resolveSpan(item.column_span, start, configured_columns, max_tracks) orelse return error.InvalidPlacement;
        column_count = @max(column_count, start + count);
    }
    var occupancy: [max_tracks]u64 = @splat(0);
    var pending: [max_items]Placement = undefined;
    var row_count = explicit_row_count;
    var metrics: PlacementMetrics = .{};
    // Explicit cells take precedence even when declared after an automatic item.
    for (items, 0..) |item, i| {
        if (item.row == null or item.column == null) continue;
        const placement = placementAt(item, item.row.?, item.column.?, column_count, configured_columns, configured_rows).?;
        metrics.candidate_positions += 1;
        if (!fits(&occupancy, placement.row, placement.row_span, mask(placement.column, placement.column_span), &metrics) and options.reject_explicit_overlap) return error.PlacementOverlap;
        occupy(&occupancy, placement);
        pending[i] = placement;
        row_count = @max(row_count, placement.row + placement.row_span);
    }
    for (items, 0..) |item, i| {
        if (item.row == null or item.column != null) continue;
        var column: usize = 0;
        while (column < column_count) : (column += 1) {
            const placement = placementAt(item, item.row.?, column, column_count, configured_columns, configured_rows) orelse continue;
            metrics.candidate_positions += 1;
            if (!fits(&occupancy, placement.row, placement.row_span, mask(column, placement.column_span), &metrics)) continue;
            occupy(&occupancy, placement);
            pending[i] = placement;
            row_count = @max(row_count, placement.row + placement.row_span);
            break;
        } else return error.GridFull;
    }
    var cursor: usize = 0;
    for (items, 0..) |item, i| {
        if (item.row != null) continue;
        var position = cursor;
        var found = false;
        while (position < max_tracks * column_count) {
            const row = position / column_count;
            var column = position % column_count;
            if (item.column) |fixed_column| {
                if (fixed_column < column) {
                    position = (row + 1) * column_count + fixed_column;
                    continue;
                }
                column = fixed_column;
                position = row * column_count + column;
            }
            metrics.candidate_positions += 1;
            const placement = placementAt(item, row, column, column_count, configured_columns, configured_rows);
            if (placement != null and fits(&occupancy, row, placement.?.row_span, mask(column, placement.?.column_span), &metrics)) {
                occupy(&occupancy, placement.?);
                pending[i] = placement.?;
                row_count = @max(row_count, row + placement.?.row_span);
                cursor = position + placement.?.column_span;
                found = true;
                break;
            }
            position = if (item.column) |fixed_column| (row + 1) * column_count + fixed_column else position + 1;
        }
        if (!found) return error.GridFull;
    }
    @memcpy(output[0..items.len], pending[0..items.len]);
    return .{ .row_count = row_count, .column_count = column_count, .occupancy = occupancy, .metrics = metrics };
}

/// Combine placement and solving as a single output transaction. Explicit
/// tracks are preserved; new tracks use the caller's implicit constraints.
pub fn computeAuto(bounds: Rect, columns: []const Track, rows: []const Track, items: []const AutoItem, options: AutoOptions, output: []Rect, placement_output: []Placement) Error!AutoResult {
    _ = try geometry(bounds, options.layout);
    if (columns.len > max_tracks) return error.TooManyTracks;
    if (columns.len > 0) try validateTracks(columns);
    if (rows.len > max_tracks) return error.TooManyTracks;
    if (rows.len > 0) try validateTracks(rows);
    try validateTracks(&.{options.implicit_row});
    try validateTracks(&.{options.implicit_column});
    if (items.len > max_items) return error.TooManyItems;
    if (output.len < items.len or placement_output.len < items.len) return error.OutputTooSmall;
    var placements: [max_items]Placement = undefined;
    var placed = try placeAuto(columns.len, rows.len, items, options.placement, &placements);
    // An empty content-sized row makes an empty auto grid a valid solver input.
    placed.row_count = @max(1, placed.row_count);
    var resolved_columns: [max_tracks]Track = undefined;
    @memcpy(resolved_columns[0..columns.len], columns);
    @memset(resolved_columns[columns.len..placed.column_count], options.implicit_column);
    var resolved_rows: [max_tracks]Track = undefined;
    @memcpy(resolved_rows[0..rows.len], rows);
    @memset(resolved_rows[rows.len..placed.row_count], options.implicit_row);
    var resolved_items: [max_items]Item = undefined;
    for (items, placements[0..items.len], 0..) |item, placement, i| resolved_items[i] = .{
        .row = placement.row,
        .column = placement.column,
        .row_span = placement.row_span,
        .column_span = placement.column_span,
        .minimum = item.minimum,
        .preferred = item.preferred,
        .align_x = item.align_x,
        .align_y = item.align_y,
    };
    var rectangles: [max_items]Rect = undefined;
    const result = try compute(bounds, resolved_columns[0..placed.column_count], resolved_rows[0..placed.row_count], resolved_items[0..items.len], options.layout, &rectangles);
    @memcpy(output[0..items.len], rectangles[0..items.len]);
    @memcpy(placement_output[0..items.len], placements[0..items.len]);
    return .{ .layout = result, .placement = placed };
}

/// Exactly one intrinsic and one allocated-width measurement per item. The
/// second callback supplies heights only, so it cannot create a width feedback
/// loop. Callback costs and failures are explicit; caller output stays atomic.
pub fn computeMeasured(bounds: Rect, columns: []const Track, rows: []const Track, items: []const AutoItem, options: AutoOptions, measurer: Measurer, output: []Rect, placement_output: []Placement) anyerror!AutoResult {
    _ = try geometry(bounds, options.layout);
    if (items.len > max_items) return error.TooManyItems;
    if (output.len < items.len or placement_output.len < items.len) return error.OutputTooSmall;
    // Reject structural failures before calling application measurement code.
    if (columns.len > max_tracks) return error.TooManyTracks;
    if (columns.len > 0) try validateTracks(columns);
    if (rows.len > 0) try validateTracks(rows);
    try validateTracks(&.{options.implicit_row});
    try validateTracks(&.{options.implicit_column});
    var placements: [max_items]Placement = undefined;
    _ = try placeAuto(columns.len, rows.len, items, options.placement, &placements);
    var measured_items: [max_items]AutoItem = undefined;
    for (items, 0..) |item, i| {
        const measured = try measurer.intrinsic(measurer.context, i);
        if (!layout.validSize(measured.minimum) or !layout.validSize(measured.preferred)) return error.InvalidGeometry;
        measured_items[i] = item;
        measured_items[i].minimum = measured.minimum;
        measured_items[i].preferred = measured.preferred;
    }
    var rectangles: [max_items]Rect = undefined;
    _ = try computeAuto(bounds, columns, rows, measured_items[0..items.len], options, &rectangles, &placements);
    for (measured_items[0..items.len], rectangles[0..items.len], 0..) |*item, rectangle, i| {
        const measured = try measurer.constrained_height(measurer.context, i, rectangle.width);
        if (!validScalar(measured.minimum) or !validScalar(measured.preferred)) return error.InvalidGeometry;
        item.minimum.height = measured.minimum;
        item.preferred.height = measured.preferred;
    }
    const result = try computeAuto(bounds, columns, rows, measured_items[0..items.len], options, &rectangles, &placements);
    @memcpy(output[0..items.len], rectangles[0..items.len]);
    @memcpy(placement_output[0..items.len], placements[0..items.len]);
    return result;
}

fn validScalar(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}
fn scalar(value: f64) Error!f32 {
    if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.GeometryOverflow;
    return @floatCast(value);
}
const Geometry = struct { x: f64, y: f64, width: f64, height: f64 };
fn geometry(bounds: Rect, options: Options) Error!Geometry {
    if (!layout.validRect(bounds) or !validScalar(options.column_gap) or !validScalar(options.row_gap) or !validScalar(options.padding.left) or !validScalar(options.padding.right) or !validScalar(options.padding.top) or !validScalar(options.padding.bottom)) return error.InvalidGeometry;
    const result: Geometry = .{
        .x = @as(f64, bounds.x) + options.padding.left,
        .y = @as(f64, bounds.y) + options.padding.top,
        .width = @max(0, @as(f64, bounds.width) - options.padding.left - options.padding.right),
        .height = @max(0, @as(f64, bounds.height) - options.padding.top - options.padding.bottom),
    };
    _ = try scalar(result.x);
    _ = try scalar(result.y);
    _ = try scalar(result.x + result.width);
    _ = try scalar(result.y + result.height);
    _ = try scalar(@as(f64, options.padding.left) + options.padding.right);
    _ = try scalar(@as(f64, options.padding.top) + options.padding.bottom);
    return result;
}
fn validateTracks(tracks: []const Track) Error!void {
    if (tracks.len == 0) return error.InvalidTrack;
    if (tracks.len > max_tracks) return error.TooManyTracks;
    for (tracks) |track| if (!validScalar(track.min) or std.math.isNan(track.max) or track.max < track.min or !validScalar(track.fr)) return error.InvalidTrack;
}
fn spanSize(axis: *Axis, start: usize, count: usize, metrics: *Metrics) f64 {
    var sum: f64 = axis.gap * @as(f64, @floatFromInt(count - 1));
    for (axis.sizes[start..][0..count]) |value| {
        metrics.track_visits += 1;
        sum += value;
    }
    return sum;
}
/// Sort saturation thresholds once; each eligible track is then visited once.
/// Unlike repeated redistribution, work does not scale with pixel distances.
fn grow(axis: *Axis, start: usize, count: usize, amount: f64, mode: Growth, metrics: *Metrics) void {
    if (amount <= 0) return;
    var candidates: [max_tracks]Candidate = undefined;
    var len: usize = 0;
    for (start..start + count) |i| {
        metrics.track_visits += 1;
        const track = axis.tracks[i];
        if (track.max <= axis.sizes[i]) continue;
        if (mode == .preferred and track.fr > 0) continue;
        if (mode == .fraction and track.fr == 0) continue;
        const weight: f64 = if (mode == .fraction) track.fr else 1;
        candidates[len] = .{ .index = i, .capacity = @as(f64, track.max) - axis.sizes[i], .weight = weight };
        len += 1;
    }
    std.sort.pdq(Candidate, candidates[0..len], SortContext{ .metrics = metrics }, SortContext.lessThan);
    // Do not subtract capped large weights from a running sum: an extreme
    // ratio can erase a small remaining weight through floating point loss.
    var suffix_weights: [max_tracks + 1]f64 = @splat(0);
    var tail_index = len;
    while (tail_index > 0) {
        tail_index -= 1;
        suffix_weights[tail_index] = candidates[tail_index].weight + suffix_weights[tail_index + 1];
    }
    var remaining = amount;
    for (candidates[0..len], 0..) |candidate, i| {
        const weights = suffix_weights[i];
        if (candidate.capacity < remaining * candidate.weight / weights) {
            axis.sizes[candidate.index] += candidate.capacity;
            remaining = @max(0, remaining - candidate.capacity);
        } else {
            for (candidates[i..len]) |tail| {
                metrics.track_visits += 1;
                axis.sizes[tail.index] += remaining * tail.weight / weights;
            }
            break;
        }
    }
}
fn intrinsic(axis: *Axis, items: []const Item, horizontal: bool, mode: Growth, metrics: *Metrics) void {
    var spans: [max_tracks + 1]bool = @splat(false);
    for (items) |item| {
        metrics.item_visits += 1;
        spans[if (horizontal) item.column_span else item.row_span] = true;
    }
    for (1..axis.tracks.len + 1) |count| {
        if (!spans[count]) continue;
        // Constraints of equal span all see the same baseline. Taking each
        // track's largest proposed size preserves every individual request
        // while making declaration order irrelevant for overlapping spans.
        var planned = axis.sizes;
        metrics.track_visits += axis.tracks.len;
        for (items) |item| {
            metrics.item_visits += 1;
            if ((if (horizontal) item.column_span else item.row_span) != count) continue;
            const start = if (horizontal) item.column else item.row;
            const minimum = if (horizontal) item.minimum.width else item.minimum.height;
            const preferred = if (horizontal) item.preferred.width else item.preferred.height;
            const requested = if (mode == .minimum) minimum else @max(minimum, preferred);
            const deficit = @as(f64, requested) - spanSize(axis, start, count, metrics);
            if (deficit <= 0) continue;
            var proposal: Axis = .{ .tracks = axis.tracks, .sizes = undefined, .positions = undefined, .gap = axis.gap };
            for (start..start + count) |i| proposal.sizes[i] = axis.sizes[i];
            metrics.track_visits += count;
            grow(&proposal, start, count, deficit, mode, metrics);
            for (start..start + count) |i| planned[i] = @max(planned[i], proposal.sizes[i]);
            metrics.track_visits += count;
        }
        axis.sizes = planned;
        metrics.track_visits += axis.tracks.len;
    }
}
fn arrange(axis: *Axis, origin: f64, available: f64, justify: layout.Justify, metrics: *Metrics) void {
    var used = spanSize(axis, 0, axis.tracks.len, metrics);
    grow(axis, 0, axis.tracks.len, available - used, .fraction, metrics);
    used = spanSize(axis, 0, axis.tracks.len, metrics);
    const leftover = @max(0, available - used);
    var position = origin + switch (justify) {
        .center => leftover / 2,
        .end => leftover,
        else => 0,
    };
    if (justify == .space_between and axis.tracks.len > 1) axis.gap += leftover / @as(f64, @floatFromInt(axis.tracks.len - 1));
    for (axis.tracks, 0..) |_, i| {
        axis.positions[i] = position;
        position += axis.sizes[i] + axis.gap;
    }
    axis.used = spanSize(axis, 0, axis.tracks.len, metrics);
}
fn fitPreferred(axis: *Axis, minimums: *const [max_tracks]f64, available: f64, metrics: *Metrics) void {
    const used = spanSize(axis, 0, axis.tracks.len, metrics);
    if (used <= available) return;
    var flexible: f64 = 0;
    for (axis.tracks, 0..) |track, i| {
        metrics.track_visits += 1;
        if (track.fr == 0) flexible += @max(0, axis.sizes[i] - minimums[i]);
    }
    if (flexible == 0) return;
    const fraction = @min(1, (used - available) / flexible);
    for (axis.tracks, 0..) |track, i| {
        metrics.track_visits += 1;
        if (track.fr == 0) axis.sizes[i] = @max(minimums[i], axis.sizes[i] - (axis.sizes[i] - minimums[i]) * fraction);
    }
}
fn place(position: f64, extent: f64, preferred: f32, minimum: f32, alignment: layout.Align) struct { origin: f64, extent: f64 } {
    const size = if (alignment == .stretch) extent else @min(extent, @as(f64, @max(preferred, minimum)));
    return .{ .origin = position + switch (alignment) {
        .center => (extent - size) / 2,
        .end => extent - size,
        else => 0,
    }, .extent = size };
}

/// Explicit placement; no implicit tracks, auto-placement, measuring or heap.
/// Minimums precede preferred sizing; equal-span constraints share a baseline.
/// Output is untouched on any error, including a late coordinate overflow.
pub fn compute(bounds: Rect, columns: []const Track, rows: []const Track, items: []const Item, options: Options, output: []Rect) Error!Result {
    const inner = try geometry(bounds, options);
    try validateTracks(columns);
    try validateTracks(rows);
    if (items.len > max_items) return error.TooManyItems;
    if (output.len < items.len) return error.OutputTooSmall;
    for (items) |item| {
        if (item.row >= rows.len or item.column >= columns.len or item.row_span == 0 or item.column_span == 0 or item.row_span > rows.len - item.row or item.column_span > columns.len - item.column) return error.InvalidPlacement;
        if (!layout.validSize(item.minimum) or !layout.validSize(item.preferred)) return error.InvalidGeometry;
    }
    const x = inner.x;
    const y = inner.y;
    const width = inner.width;
    const height = inner.height;
    var metrics: Metrics = .{};
    var horizontal: Axis = .{ .tracks = columns, .gap = options.column_gap };
    var vertical: Axis = .{ .tracks = rows, .gap = options.row_gap };
    for (columns, 0..) |track, i| horizontal.sizes[i] = track.min;
    for (rows, 0..) |track, i| vertical.sizes[i] = track.min;
    intrinsic(&horizontal, items, true, .minimum, &metrics);
    intrinsic(&vertical, items, false, .minimum, &metrics);
    const minimum_columns = horizontal.sizes;
    const minimum_rows = vertical.sizes;
    intrinsic(&horizontal, items, true, .preferred, &metrics);
    intrinsic(&vertical, items, false, .preferred, &metrics);
    fitPreferred(&horizontal, &minimum_columns, width, &metrics);
    fitPreferred(&vertical, &minimum_rows, height, &metrics);
    arrange(&horizontal, x, width, options.justify_columns, &metrics);
    arrange(&vertical, y, height, options.justify_rows, &metrics);
    var pending: [max_items]Rect = undefined;
    var unmet: usize = 0;
    for (items, 0..) |item, i| {
        const cell_width = spanSize(&horizontal, item.column, item.column_span, &metrics);
        const cell_height = spanSize(&vertical, item.row, item.row_span, &metrics);
        if (cell_width < item.minimum.width or cell_height < item.minimum.height) unmet += 1;
        const h = place(horizontal.positions[item.column], cell_width, item.preferred.width, item.minimum.width, item.align_x orelse options.align_x);
        const v = place(vertical.positions[item.row], cell_height, item.preferred.height, item.minimum.height, item.align_y orelse options.align_y);
        pending[i] = .{ .x = try scalar(h.origin), .y = try scalar(v.origin), .width = try scalar(h.extent), .height = try scalar(v.extent) };
        // Native backends also need representable far edges.
        _ = try scalar(h.origin + h.extent);
        _ = try scalar(v.origin + v.extent);
    }
    var result: Result = .{
        .inner = .{ .x = try scalar(x), .y = try scalar(y), .width = try scalar(width), .height = try scalar(height) },
        .content_size = .{ .width = try scalar(horizontal.used + options.padding.left + options.padding.right), .height = try scalar(vertical.used + options.padding.top + options.padding.bottom) },
        .overflow = .{ .width = try scalar(@max(0, horizontal.used + options.padding.left + options.padding.right - bounds.width)), .height = try scalar(@max(0, vertical.used + options.padding.top + options.padding.bottom - bounds.height)) },
        .clip = if (options.overflow == .clip) bounds else null,
        .unmet_minimum_items = unmet,
        .metrics = metrics,
        .column_count = columns.len,
        .row_count = rows.len,
    };
    for (horizontal.sizes[0..columns.len], 0..) |value, i| result.column_widths[i] = try scalar(value);
    for (vertical.sizes[0..rows.len], 0..) |value, i| result.row_heights[i] = try scalar(value);
    @memcpy(output[0..items.len], pending[0..items.len]);
    return result;
}

test "grid combines fixed fractional minmax padding gap and spans" {
    const columns = [_]Track{ Track.fixed(40), Track.minmax(10, 50, 1), Track.fraction(2) };
    const rows = [_]Track{ Track.fixed(20), Track.fraction(1) };
    const items = [_]Item{
        .{ .row = 0, .column = 0, .column_span = 2 },
        .{ .row = 1, .column = 1, .column_span = 2, .preferred = .{ .width = 30, .height = 10 }, .align_x = .end, .align_y = .center },
    };
    var output: [2]Rect = undefined;
    const result = try compute(.{ .x = 10, .y = 20, .width = 250, .height = 100 }, &columns, &rows, &items, .{ .padding = layout.Insets.all(10), .column_gap = 5, .row_gap = 4 }, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 40), result.column_widths[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), result.column_widths[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 130), result.column_widths[2], 0.001);
    try std.testing.expectEqual(Rect{ .x = 20, .y = 30, .width = 95, .height = 20 }, output[0]);
    try std.testing.expectEqual(Rect{ .x = 220, .y = 77, .width = 30, .height = 10 }, output[1]);
    try std.testing.expectEqual(@as(usize, 0), result.unmet_minimum_items);
}
test "grid span content limits overflow and transactional errors" {
    const columns = [_]Track{ Track.minmax(0, 20, 0), Track.minmax(0, 100, 0) };
    const rows = [_]Track{Track.fixed(20)};
    const items = [_]Item{.{ .row = 0, .column = 0, .column_span = 2, .minimum = .{ .width = 150 }, .preferred = .{ .width = 200 } }};
    var output = [_]Rect{.{ .x = -1, .y = -1, .width = 1, .height = 1 }};
    const result = try compute(.{ .x = 0, .y = 0, .width = 100, .height = 10 }, &columns, &rows, &items, .{ .column_gap = 5 }, &output);
    try std.testing.expectEqual(@as(f32, 125), result.content_size.width);
    try std.testing.expectEqual(@as(f32, 25), result.overflow.width);
    try std.testing.expectEqual(@as(usize, 1), result.unmet_minimum_items);
    const previous = output;
    const invalid = [_]Item{.{ .row = 0, .column = 0, .column_span = std.math.maxInt(usize) }};
    try std.testing.expectError(error.InvalidPlacement, compute(result.inner, &columns, &rows, &invalid, .{}, &output));
    try std.testing.expectEqualSlices(Rect, &previous, &output);
    const too_large = [_]Track{Track.fixed(std.math.floatMax(f32))} ** 2;
    try std.testing.expectError(error.GeometryOverflow, compute(result.inner, &too_large, &rows, &items, .{}, &output));
    try std.testing.expectEqualSlices(Rect, &previous, &output);
}
test "maximum grid has bounded work independent of viewport magnitudes" {
    var tracks: [max_tracks]Track = undefined;
    for (&tracks, 0..) |*track, i| track.* = Track.minmax(0, @as(f32, @floatFromInt(i + 1)) * 10, @as(f32, @floatFromInt(i % 4 + 1)));
    var items: [max_items]Item = undefined;
    for (&items, 0..) |*item, i| item.* = .{ .row = i % 32, .column = i % 32, .row_span = 32, .column_span = 32, .minimum = .{ .width = 20, .height = 10 }, .preferred = .{ .width = 100, .height = 50 } };
    var output: [max_items]Rect = undefined;
    const first = try compute(.{ .x = 0, .y = 0, .width = 10000, .height = 8000 }, &tracks, &tracks, &items, .{ .column_gap = 2, .row_gap = 1 }, &output);
    const huge = try compute(.{ .x = 0, .y = 0, .width = 1e20, .height = 1e20 }, &tracks, &tracks, &items, .{ .column_gap = 2, .row_gap = 1 }, &output);
    try std.testing.expect(first.metrics.track_visits < max_items * max_tracks * 20);
    try std.testing.expect(first.metrics.capacity_comparisons < max_items * max_tracks * 20);
    try std.testing.expect(huge.metrics.track_visits < max_items * max_tracks * 20);
    try std.testing.expect(huge.metrics.capacity_comparisons < max_items * max_tracks * 20);
    try std.testing.expect(first.metrics.item_visits < max_items * max_tracks * 5);
    for (output) |bounds| try std.testing.expect(layout.validRect(bounds));
}

test "overlapping span constraints are invariant under all declaration permutations" {
    const tracks = [_]Track{ .{}, .{}, .{} };
    const rows = [_]Track{Track.fixed(20)};
    const items = [_]Item{
        .{ .row = 0, .column = 0, .column_span = 2, .minimum = .{ .width = 100 } },
        .{ .row = 0, .column = 1, .column_span = 2, .minimum = .{ .width = 200 } },
        .{ .row = 0, .column = 0, .column_span = 3, .preferred = .{ .width = 400 } },
        .{ .row = 0, .column = 0, .minimum = .{ .width = 50 } },
    };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 300, .height = 20 };
    var baseline_output: [4]Rect = undefined;
    const baseline = try compute(bounds, &tracks, &rows, &items, .{}, &baseline_output);
    for (0..4) |a| for (0..4) |b| {
        if (a == b) continue;
        for (0..4) |c| {
            if (c == a or c == b) continue;
            const d = 6 - a - b - c;
            const permutation = [_]Item{ items[a], items[b], items[c], items[d] };
            var output: [4]Rect = undefined;
            const result = try compute(bounds, &tracks, &rows, &permutation, .{}, &output);
            try std.testing.expectEqualSlices(f32, &baseline.column_widths, &result.column_widths);
            try std.testing.expectEqual(baseline.content_size, result.content_size);
            for ([_]usize{ a, b, c, d }, 0..) |original, i| try std.testing.expectEqual(baseline_output[original], output[i]);
            try std.testing.expectEqual(@as(usize, 0), result.unmet_minimum_items);
        }
    };
    const two_tracks = tracks[0..2];
    const regression = [_]Item{ .{ .row = 0, .column = 0, .column_span = 2, .preferred = .{ .width = 100 } }, .{ .row = 0, .column = 1, .minimum = .{ .width = 100 } } };
    var regression_output: [2]Rect = undefined;
    const result = try compute(bounds, two_tracks, &rows, &regression, .{}, &regression_output);
    try std.testing.expectEqual(@as(f32, 100), result.content_size.width);
}

test "fraction saturation preserves tiny remaining weights" {
    const columns = [_]Track{ Track.minmax(0, 1, 1e30), Track.minmax(0, 100, 1e-30) };
    const rows = [_]Track{Track.fixed(10)};
    var output: [0]Rect = .{};
    const result = try compute(.{ .x = 0, .y = 0, .width = 50, .height = 10 }, &columns, &rows, &.{}, .{}, &output);
    try std.testing.expectEqual(@as(f32, 1), result.column_widths[0]);
    try std.testing.expectEqual(@as(f32, 49), result.column_widths[1]);
}

test "grid validates capacities and reports oversized padding" {
    const tracks = [_]Track{Track{}};
    var output = [_]Rect{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    const original = output;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const items = [_]Item{.{ .row = 0, .column = 0 }};
    const invalid = [_]Track{Track.fraction(std.math.nan(f32))};
    try std.testing.expectError(error.InvalidTrack, compute(bounds, &invalid, &tracks, &items, .{}, &output));
    try std.testing.expectError(error.OutputTooSmall, compute(bounds, &tracks, &tracks, &items, .{}, output[0..0]));
    try std.testing.expectError(error.InvalidGeometry, compute(bounds, &tracks, &tracks, &items, .{ .column_gap = -1 }, &output));
    try std.testing.expectEqualSlices(Rect, &original, &output);
    const result = try compute(bounds, &tracks, &tracks, &items, .{ .padding = layout.Insets.all(60) }, &output);
    try std.testing.expectEqual(@as(f32, 0), result.inner.width);
    try std.testing.expectEqual(@as(f32, 20), result.overflow.width);
    try std.testing.expectEqual(@as(f32, 20), result.overflow.height);
}

test "automatic placement mixes reserved cells row and column constraints and spans" {
    const items = [_]AutoItem{
        .{},
        .{ .row = 0, .column = 0, .column_span = .{ .count = 2 } },
        .{ .row = 1, .column_span = .{ .count = 2 } },
        .{ .column = 2 },
        .{ .column_span = .to_end },
        .{ .row = 0, .column = 0 }, // Explicit overlap is deliberately allowed.
    };
    var output: [items.len]Placement = undefined;
    const result = try placeAuto(3, 1, &items, .{}, &output);
    try std.testing.expectEqual(@as(usize, 3), result.row_count);
    try std.testing.expectEqual(Placement{ .row = 0, .column = 2, .row_span = 1, .column_span = 1 }, output[0]);
    try std.testing.expectEqual(Placement{ .row = 1, .column = 0, .row_span = 1, .column_span = 2 }, output[2]);
    try std.testing.expectEqual(Placement{ .row = 1, .column = 2, .row_span = 1, .column_span = 1 }, output[3]);
    try std.testing.expectEqual(Placement{ .row = 2, .column = 0, .row_span = 1, .column_span = 3 }, output[4]);
    const original = output;
    try std.testing.expectError(error.PlacementOverlap, placeAuto(3, 1, &items, .{ .reject_explicit_overlap = true }, &output));
    try std.testing.expectEqualSlices(Placement, &original, &output);
    const to_end = [_]AutoItem{.{ .row = 1, .column = 1, .row_span = .to_end, .column_span = .to_end }};
    _ = try placeAuto(4, 4, &to_end, .{}, output[0..1]);
    try std.testing.expectEqual(Placement{ .row = 1, .column = 1, .row_span = 3, .column_span = 3 }, output[0]);
}

test "implicit rows fit content and auto solve is an output transaction" {
    const columns = [_]Track{Track.fraction(1)};
    const items = [_]AutoItem{
        .{ .preferred = .{ .height = 10 } },
        .{ .preferred = .{ .height = 20 } },
        .{ .preferred = .{ .height = 30 } },
    };
    var output: [3]Rect = undefined;
    var placements: [3]Placement = undefined;
    const result = try computeAuto(.{ .x = 0, .y = 0, .width = 100, .height = 200 }, &columns, &.{}, &items, .{}, &output, &placements);
    try std.testing.expectEqual(@as(usize, 3), result.placement.row_count);
    try std.testing.expectEqual(@as(f32, 60), result.layout.content_size.height);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 30, .width = 100, .height = 30 }, output[2]);
    const old_output = output;
    const old_placements = placements;
    var invalid = items;
    invalid[2].preferred.width = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGeometry, computeAuto(result.layout.inner, &columns, &.{}, &invalid, .{}, &output, &placements));
    try std.testing.expectEqualSlices(Rect, &old_output, &output);
    try std.testing.expectEqualSlices(Placement, &old_placements, &placements);
}

test "automatic placement fills bounded occupancy and rejects overflow without writes" {
    const items: [max_items]AutoItem = @splat(.{ .column_span = .{ .count = 16 } });
    var output: [max_items]Placement = undefined;
    const result = try placeAuto(64, 0, &items, .{}, &output);
    try std.testing.expectEqual(@as(usize, 64), result.row_count);
    for (result.occupancy) |used| try std.testing.expectEqual(std.math.maxInt(u64), used);
    try std.testing.expect(result.metrics.candidate_positions <= max_tracks * max_tracks);
    try std.testing.expect(result.metrics.row_masks <= max_tracks * max_tracks);
    const original = output;
    const impossible: [65]AutoItem = @splat(.{ .column_span = .to_end });
    try std.testing.expectError(error.GridFull, placeAuto(64, 0, &impossible, .{}, output[0..65]));
    try std.testing.expectEqualSlices(Placement, &original, &output);
}

test "explicit two-stage measurements size rows at allocated widths and preserve failures" {
    const Probe = struct {
        intrinsic_calls: usize = 0,
        height_calls: usize = 0,
        fail: bool = false,
        fn intrinsic(ptr: *anyopaque, _: usize) !Measurement {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.intrinsic_calls += 1;
            return .{ .minimum = .{}, .preferred = .{ .width = 200, .height = 10 } };
        }
        fn height(ptr: *anyopaque, _: usize, width: f32) !HeightMeasurement {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.height_calls += 1;
            if (self.fail) return error.MeasurementFailed;
            try std.testing.expectEqual(@as(f32, 100), width);
            return .{ .preferred = 20 };
        }
    };
    var probe: Probe = .{};
    const measurer: Measurer = .{ .context = &probe, .intrinsic = Probe.intrinsic, .constrained_height = Probe.height };
    const columns = [_]Track{Track.fraction(1)};
    const items = [_]AutoItem{ .{}, .{} };
    var output: [2]Rect = undefined;
    var placements: [2]Placement = undefined;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const result = try computeMeasured(bounds, &columns, &.{}, &items, .{}, measurer, &output, &placements);
    try std.testing.expectEqual(@as(f32, 40), result.layout.content_size.height);
    try std.testing.expectEqual(@as(usize, 2), probe.intrinsic_calls);
    try std.testing.expectEqual(@as(usize, 2), probe.height_calls);
    const previous = output;
    const previous_placements = placements;
    probe.fail = true;
    try std.testing.expectError(error.MeasurementFailed, computeMeasured(bounds, &columns, &.{}, &items, .{}, measurer, &output, &placements));
    try std.testing.expectEqualSlices(Rect, &previous, &output);
    try std.testing.expectEqualSlices(Placement, &previous_placements, &placements);
    probe.intrinsic_calls = 0;
    probe.height_calls = 0;
    const invalid_options = [_]AutoOptions{
        .{ .layout = .{ .column_gap = -1 } },
        .{ .layout = .{ .padding = .{ .left = std.math.nan(f32) } } },
    };
    for (invalid_options) |options| try std.testing.expectError(error.InvalidGeometry, computeMeasured(bounds, &columns, &.{}, &items, options, measurer, &output, &placements));
    try std.testing.expectError(error.InvalidGeometry, computeMeasured(.{ .x = 0, .y = 0, .width = -1, .height = 10 }, &columns, &.{}, &items, .{}, measurer, &output, &placements));
    try std.testing.expectEqual(@as(usize, 0), probe.intrinsic_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.height_calls);
    try std.testing.expectEqualSlices(Rect, &previous, &output);
    try std.testing.expectEqualSlices(Placement, &previous_placements, &placements);
}

test "implicit columns grow for explicit positions and automatic spans without rebinding end spans" {
    const columns = [_]Track{Track.fixed(20)};
    const items = [_]AutoItem{
        .{ .row = 0, .column = 3, .preferred = .{ .width = 40, .height = 10 } },
        .{ .column_span = .{ .count = 3 }, .preferred = .{ .width = 60, .height = 20 } },
        .{ .row = 1, .column = 0, .column_span = .to_end, .preferred = .{ .height = 15 } },
    };
    var output: [items.len]Rect = undefined;
    var placements: [items.len]Placement = undefined;
    const result = try computeAuto(.{ .x = 0, .y = 0, .width = 300, .height = 200 }, &columns, &.{}, &items, .{}, &output, &placements);
    try std.testing.expectEqual(@as(usize, 4), result.placement.column_count);
    try std.testing.expectEqual(@as(usize, 2), result.placement.row_count);
    try std.testing.expectEqual(Placement{ .row = 0, .column = 0, .row_span = 1, .column_span = 3 }, placements[1]);
    try std.testing.expectEqual(@as(usize, 1), placements[2].column_span);
    try std.testing.expectEqual(@as(f32, 20), result.layout.column_widths[0]);
    try std.testing.expectEqual(@as(f32, 40), result.layout.column_widths[3]);
    try std.testing.expectEqual(@as(f32, 35), result.layout.content_size.height);

    const empty_tracks = try computeAuto(result.layout.inner, &.{}, &.{}, &.{}, .{}, output[0..0], placements[0..0]);
    try std.testing.expectEqual(@as(usize, 1), empty_tracks.placement.column_count);
    try std.testing.expectEqual(@as(usize, 1), empty_tracks.placement.row_count);
    try std.testing.expectEqual(@as(f32, 0), empty_tracks.layout.content_size.width);

    const previous = output;
    const previous_placements = placements;
    const oversized = [_]AutoItem{.{ .column = 63, .column_span = .{ .count = 2 } }};
    try std.testing.expectError(error.InvalidPlacement, computeAuto(result.layout.inner, &columns, &.{}, &oversized, .{}, &output, &placements));
    try std.testing.expectEqualSlices(Rect, &previous, &output);
    try std.testing.expectEqualSlices(Placement, &previous_placements, &placements);
    const invalid_implicit: AutoOptions = .{ .implicit_column = Track.fraction(std.math.nan(f32)) };
    try std.testing.expectError(error.InvalidTrack, computeAuto(result.layout.inner, &columns, &.{}, &items, invalid_implicit, &output, &placements));
    try std.testing.expectEqualSlices(Rect, &previous, &output);
    try std.testing.expectEqualSlices(Placement, &previous_placements, &placements);
}

test "content tracks fit available space while preserving intrinsic minimum constraints" {
    const tracks = [_]Track{ .{}, .{} };
    const rows = [_]Track{Track.fixed(20)};
    const items = [_]Item{
        .{ .row = 0, .column = 0, .minimum = .{ .width = 20 }, .preferred = .{ .width = 100 } },
        .{ .row = 0, .column = 1, .minimum = .{ .width = 40 }, .preferred = .{ .width = 200 } },
    };
    var rectangles: [2]Rect = undefined;
    const fitted = try compute(.{ .x = 0, .y = 0, .width = 150, .height = 20 }, &tracks, &rows, &items, .{}, &rectangles);
    try std.testing.expectApproxEqAbs(@as(f32, 50), fitted.column_widths[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), fitted.column_widths[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fitted.overflow.width, 0.001);
    const constrained = try compute(.{ .x = 0, .y = 0, .width = 30, .height = 20 }, &tracks, &rows, &items, .{}, &rectangles);
    try std.testing.expectEqual(@as(f32, 20), constrained.column_widths[0]);
    try std.testing.expectEqual(@as(f32, 40), constrained.column_widths[1]);
    try std.testing.expectEqual(@as(f32, 30), constrained.overflow.width);
    try std.testing.expectEqual(@as(usize, 0), constrained.unmet_minimum_items);
}
