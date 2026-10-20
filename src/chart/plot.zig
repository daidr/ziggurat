//! Layout of a plot with axes around it, placement of marks in the plot's
//! area, legends, and the selection that the pointer and the keyboard move.
const std = @import("std");
const scale = @import("scale.zig");
const shape = @import("shape.zig");
const Rect = shape.Rect;
const Point = shape.Point;
const Span = scale.Span;
const Tick = scale.Tick;

pub const Size = struct { width: f32 = 0, height: f32 = 0 };

/// Measures one line of label text in DIPs.
pub const Measure = struct {
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, text: []const u8) Size,
};

/// A side of a plot, where an axis goes.
pub const Side = enum { left, right, top, bottom };

/// The ticks along the sides of a plot, whose labels go beside it: a
/// scale's ticks, or ticks of your own. Borrowed.
pub const Axes = struct {
    left: []const Tick = &.{},
    right: []const Tick = &.{},
    top: []const Tick = &.{},
    bottom: []const Tick = &.{},

    pub fn get(self: Axes, side: Side) []const Tick {
        return switch (side) {
            .left => self.left,
            .right => self.right,
            .top => self.top,
            .bottom => self.bottom,
        };
    }
};

/// Where the plot's area and its axes went.
pub const Layout = struct {
    area: Rect,
    /// The band each axis takes beside the area, empty for an axis
    /// without ticks.
    left: Rect = .{},
    right: Rect = .{},
    top: Rect = .{},
    bottom: Rect = .{},

    /// The box of a tick's label on `side`, centered on its tick, or null
    /// for a tick outside the plot.
    pub fn label(self: Layout, side: Side, tick: Tick, size: Size, gap: f32) ?Rect {
        const eps = 1e-4;
        if (tick.at < -eps or tick.at > 1 + eps) return null;
        const at = @max(0, @min(1, tick.at));
        return switch (side) {
            .left => .{ .x = self.area.x - gap - size.width, .y = shape.y(self.area, at) - size.height / 2, .width = size.width, .height = size.height },
            .right => .{ .x = self.area.x + self.area.width + gap, .y = shape.y(self.area, at) - size.height / 2, .width = size.width, .height = size.height },
            .top => .{ .x = shape.x(self.area, at) - size.width / 2, .y = self.area.y - gap - size.height, .width = size.width, .height = size.height },
            .bottom => .{ .x = shape.x(self.area, at) - size.width / 2, .y = self.area.y + self.area.height + gap, .width = size.width, .height = size.height },
        };
    }
};

/// Lay a plot out in `bounds`: each axis with ticks takes the room its
/// widest (or tallest) label needs, `gap` keeps the labels away from the
/// area, and the area takes the rest.
pub fn layout(bounds: Rect, axes: Axes, gap: f32, measure: Measure) Layout {
    var widest: [4]f32 = .{ 0, 0, 0, 0 };
    inline for (.{ Side.left, Side.right, Side.top, Side.bottom }, 0..) |side, i| {
        const ticks = axes.get(side);
        for (ticks) |*tick| {
            const size = measure.call(measure.context, tick.label());
            widest[i] = @max(widest[i], if (side == .left or side == .right) size.width else size.height);
        }
        if (ticks.len > 0) widest[i] += gap;
    }
    const left = widest[0];
    const right = widest[1];
    const top = widest[2];
    const bottom = widest[3];
    const area: Rect = .{
        .x = bounds.x + left,
        .y = bounds.y + top,
        .width = @max(0, bounds.width - left - right),
        .height = @max(0, bounds.height - top - bottom),
    };
    return .{
        .area = area,
        .left = .{ .x = bounds.x, .y = area.y, .width = left, .height = area.height },
        .right = .{ .x = area.x + area.width, .y = area.y, .width = right, .height = area.height },
        .top = .{ .x = area.x, .y = bounds.y, .width = area.width, .height = top },
        .bottom = .{ .x = area.x, .y = area.y + area.height, .width = area.width, .height = bottom },
    };
}

/// The box over the stretch `sx` along the plot's area and `sy` up it: a
/// bar, a band of a range, a cell of a heat map.
pub fn rect(area: Rect, sx: Span, sy: Span) Rect {
    const x0 = @min(sx.lo, sx.hi);
    const x1 = @max(sx.lo, sx.hi);
    const y0 = @min(sy.lo, sy.hi);
    const y1 = @max(sy.lo, sy.hi);
    return .{ .x = shape.x(area, x0), .y = shape.y(area, y1), .width = (x1 - x0) * area.width, .height = (y1 - y0) * area.height };
}

/// A `width` by `height` box centered on the point at `fx` along the area
/// and `fy` up it: a dot of a scatter plot.
pub fn point(area: Rect, fx: f32, fy: f32, width: f32, height: f32) Rect {
    return .{ .x = shape.x(area, fx) - width / 2, .y = shape.y(area, fy) - height / 2, .width = width, .height = height };
}

/// A vertical line of `width` across the area at `fx` along it.
pub fn ruleX(area: Rect, fx: f32, width: f32) Rect {
    return .{ .x = shape.x(area, fx) - width / 2, .y = area.y, .width = width, .height = area.height };
}

/// A horizontal line of `height` across the area at `fy` up it.
pub fn ruleY(area: Rect, fy: f32, height: f32) Rect {
    return .{ .x = area.x, .y = shape.y(area, fy) - height / 2, .width = area.width, .height = height };
}

/// Where a box of `size` anchored at a point goes: `start` puts its left
/// (horizontal) or top (vertical) edge on the point, `end` its right or
/// bottom edge, and `center` centers it there.
pub const Anchor = enum { start, center, end };

/// The box of `size` anchored at the point at `fx` along the area and `fy`
/// up it, as a label over a bar: `.center, .end` shows it above the point.
pub fn anchor(area: Rect, fx: f32, fy: f32, h: Anchor, v: Anchor, size: Size) Rect {
    const px = shape.x(area, fx);
    const py = shape.y(area, fy);
    const left = switch (h) {
        .start => px,
        .center => px - size.width / 2,
        .end => px - size.width,
    };
    const top = switch (v) {
        .start => py,
        .center => py - size.height / 2,
        .end => py - size.height,
    };
    return .{ .x = left, .y = top, .width = size.width, .height = size.height };
}

/// One entry of a legend: a swatch of the series' color and its name.
pub const LegendItem = struct { label: []const u8, color: u32 };

/// Where an entry of a legend went.
pub const LegendSlot = struct { swatch: Rect, label: Rect };

pub const LegendOptions = struct {
    /// Side of the square swatch.
    swatch: f32 = 10,
    /// Room between a swatch and its label.
    spacing: f32 = 6,
    /// Room between entries along a row, and between rows.
    gap: f32 = 16,
    row_gap: f32 = 4,
};

/// Lay legend entries out in rows that wrap within `bounds.width`, from its
/// top left. Writes a slot per item to `out` and returns the size taken.
pub fn legend(bounds: Rect, items: []const LegendItem, options: LegendOptions, measure: Measure, out: []LegendSlot) error{OutputTooSmall}!Size {
    if (out.len < items.len) return error.OutputTooSmall;
    var cursor_x: f32 = 0;
    var cursor_y: f32 = 0;
    var row_height: f32 = 0;
    var widest: f32 = 0;
    for (items, 0..) |item, i| {
        const text = measure.call(measure.context, item.label);
        const height = @max(options.swatch, text.height);
        const width = options.swatch + options.spacing + text.width;
        if (cursor_x > 0 and cursor_x + width > bounds.width) {
            cursor_x = 0;
            cursor_y += row_height + options.row_gap;
            row_height = 0;
        }
        const top = bounds.y + cursor_y;
        out[i] = .{
            .swatch = .{ .x = bounds.x + cursor_x, .y = top + (height - options.swatch) / 2, .width = options.swatch, .height = options.swatch },
            .label = .{ .x = bounds.x + cursor_x + options.swatch + options.spacing, .y = top + (height - text.height) / 2, .width = text.width, .height = text.height },
        };
        cursor_x += width;
        widest = @max(widest, cursor_x);
        cursor_x += options.gap;
        row_height = @max(row_height, height);
    }
    return .{ .width = widest, .height = if (items.len == 0) 0 else cursor_y + row_height };
}

/// A key the selection answers to.
pub const Key = enum { left, right, home, end, escape };

/// What a selection input changed.
pub const Change = struct {
    /// The choice differs from before the input.
    changed: bool = false,
    /// The keyboard moved the choice to a new point, which assistive
    /// technology should announce.
    announce: bool = false,
};

/// The point of a plot that the pointer and the keyboard choose among
/// points at fractions in ascending order: the one nearest the pointer
/// while it is over the plot, none once it leaves; the left and right
/// arrows, Home and End move the choice, and Escape clears it.
pub const Selection = struct {
    index: ?usize = null,
    hovering: bool = false,
    /// Where the pointer was, as a fraction along the plot.
    pointer_at: f32 = 0,
    /// The choice last announced.
    last: ?usize = null,

    /// Move the choice with a key among `count` points.
    pub fn key(self: *Selection, k: Key, count: usize) Change {
        const old = self.clampTo(count);
        if (count == 0) return .{ .changed = old != null };
        var target: ?usize = self.index;
        switch (k) {
            .right => target = if (self.index) |i| @min(count - 1, i + 1) else 0,
            .left => target = if (self.index) |i| i -| 1 else count - 1,
            .home => target = 0,
            .end => target = count - 1,
            .escape => {
                self.index = null;
                self.last = null;
                return .{ .changed = old != null };
            },
        }
        self.index = target;
        const announce = self.index != self.last;
        self.last = self.index;
        return .{ .changed = self.index != old, .announce = announce };
    }

    /// Follow the pointer at `f` along the plot, or null once it left; the
    /// pointer chooses as it comes and moves, not while it rests.
    pub fn pointer(self: *Selection, f: ?f32, xs: []const f32) Change {
        const old = self.clampTo(xs.len);
        if (f) |at| {
            if (xs.len > 0 and (!self.hovering or at != self.pointer_at)) self.index = shape.nearest(xs, at);
            self.hovering = true;
            self.pointer_at = at;
        } else if (self.hovering) {
            self.hovering = false;
            self.index = null;
        }
        self.last = self.index;
        return .{ .changed = self.index != old };
    }

    fn clampTo(self: *Selection, count: usize) ?usize {
        if (self.index) |i| if (i >= count) {
            self.index = null;
        };
        return self.index;
    }
};
