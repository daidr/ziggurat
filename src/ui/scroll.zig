const std = @import("std");
const layout = @import("layout.zig");
pub const Rect = layout.Rect;
pub const Size = layout.Size;
pub const Point = layout.Point;
pub const Axis = enum { horizontal, vertical };
pub const Error = error{InvalidGeometry};

pub const Scrollbar = struct {
    axis: Axis,
    track: Rect,
    thumb: Rect,
    max_offset: f32,

    /// Convert a dragged thumb's leading edge, in viewport DIP, to content offset.
    pub fn offsetForThumb(self: Scrollbar, leading: f32) Error!f32 {
        if (!std.math.isFinite(leading)) return error.InvalidGeometry;
        const origin = if (self.axis == .horizontal) self.track.x else self.track.y;
        const travel = if (self.axis == .horizontal) self.track.width - self.thumb.width else self.track.height - self.thumb.height;
        if (travel <= 0) return 0;
        const fraction = std.math.clamp((@as(f64, leading) - origin) / travel, 0, 1);
        return @floatCast(fraction * self.max_offset);
    }
};

/// The scroll bar of a view that scrolls itself rather than through a view
/// scroll container, as a terminal, a rich text editor or a virtual table
/// does, laid out and painted as a container's, so that every bar of an
/// application looks alike and follows the theme. Paint it with
/// `Frame.scrollbar`, and map a drag of its thumb with `thumb` and
/// `offsetAt`.
pub const Bar = struct {
    /// The view the bar runs along: at its right edge, or its left one when
    /// `leading`, or its bottom for a horizontal bar.
    box: Rect,
    axis: Axis = .vertical,
    /// Along the left edge, for right-to-left content.
    leading: bool = false,
    /// The length of the content the view shows, of all of it, and how far
    /// it is scrolled, in any one unit, as rows of a terminal's scrollback.
    /// The bar shows nothing unless `content` is longer than `view`.
    view: f32,
    content: f32,
    offset: f32,

    /// How thick a thumb is, and how much thicker while dragged, toward
    /// the content.
    pub const thickness: f32 = 4;
    pub const widen: f32 = 2;
    /// Space between the thumb and the box's edges.
    pub const margin: f32 = 2;
    pub const min_thumb: f32 = 16;
    /// How far from its edge the bar takes the pointer.
    pub const strip: f32 = 12;

    /// Whether the content is longer than the view, so the bar shows.
    pub fn scrolls(self: Bar) bool {
        return std.math.isFinite(self.view) and std.math.isFinite(self.content) and self.content > self.view + 0.5;
    }
    /// The track the thumb moves along.
    pub fn track(self: Bar) Rect {
        const b = self.box;
        if (self.axis == .horizontal) return .{ .x = b.x + margin, .y = b.y + b.height - margin - thickness, .width = @max(0, b.width - 2 * margin), .height = thickness };
        return .{ .x = if (self.leading) b.x + margin else b.x + b.width - margin - thickness, .y = b.y + margin, .width = thickness, .height = @max(0, b.height - 2 * margin) };
    }
    /// The bar's geometry, null when it has nowhere to scroll.
    pub fn geometry(self: Bar) ?Scrollbar {
        if (!self.scrolls() or !std.math.isFinite(self.offset)) return null;
        const reach = self.content - self.view;
        var model: ScrollModel = .{};
        const view_size: Size = if (self.axis == .horizontal) .{ .width = @max(0, self.view), .height = 0 } else .{ .width = 0, .height = @max(0, self.view) };
        const content_size: Size = if (self.axis == .horizontal) .{ .width = self.content, .height = 0 } else .{ .width = 0, .height = self.content };
        model.viewport = view_size;
        model.content = content_size;
        const at = std.math.clamp(self.offset, 0, reach);
        if (self.axis == .horizontal) model.offset.x = at else model.offset.y = at;
        return model.scrollbar(self.axis, self.track(), min_thumb) catch null;
    }
    /// The thumb's box, wider toward the content while `dragging`; null
    /// when the bar has nowhere to scroll.
    pub fn thumb(self: Bar, dragging: bool) ?Rect {
        var box = (self.geometry() orelse return null).thumb;
        if (dragging) {
            if (self.axis == .horizontal) {
                box.y -= widen;
                box.height += widen;
            } else if (self.leading) {
                box.width += widen;
            } else {
                box.x -= widen;
                box.width += widen;
            }
        }
        return box;
    }
    /// The offset that brings the thumb's start, its top or its left, to
    /// `start`, within the content, as the thumb is dragged.
    pub fn offsetAt(self: Bar, start: f32) f32 {
        const bar = self.geometry() orelse return 0;
        return bar.offsetForThumb(start) catch self.offset;
    }
    /// Whether `point` is on the strip along the bar's edge, while it has
    /// somewhere to scroll.
    pub fn hit(self: Bar, point: Point) bool {
        if (!self.scrolls()) return false;
        const b = self.box;
        if (point.x < b.x or point.x >= b.x + b.width or point.y < b.y or point.y >= b.y + b.height) return false;
        if (self.axis == .horizontal) return point.y >= b.y + b.height - strip;
        return if (self.leading) point.x < b.x + strip else point.x >= b.x + b.width - strip;
    }
    /// Paint the thumb into `target`, anything with `roundedRect`, in
    /// `color`, if the bar has somewhere to scroll.
    pub fn paint(self: Bar, target: anytype, color: anytype, dragging: bool) void {
        const box = self.thumb(dragging) orelse return;
        const across = if (self.axis == .horizontal) box.height else box.width;
        target.roundedRect(box, across / 2, color);
    }
};

/// Persistent DIP state. Changes are explicit; no clocks, allocations or timers.
pub const ScrollModel = struct {
    offset: Point = .{},
    viewport: Size = .{},
    content: Size = .{},

    pub fn maxOffset(self: *const ScrollModel) Point {
        return .{ .x = @max(0, self.content.width - self.viewport.width), .y = @max(0, self.content.height - self.viewport.height) };
    }
    pub fn setSizes(self: *ScrollModel, viewport: Size, content: Size) Error!bool {
        if (!layout.validSize(viewport) or !layout.validSize(content)) return error.InvalidGeometry;
        const changed = !std.meta.eql(self.viewport, viewport) or !std.meta.eql(self.content, content);
        self.viewport = viewport;
        self.content = content;
        return (try self.setOffset(self.offset)) or changed;
    }
    pub fn setOffset(self: *ScrollModel, requested: Point) Error!bool {
        if (!std.math.isFinite(requested.x) or !std.math.isFinite(requested.y)) return error.InvalidGeometry;
        return self.clampTo(requested.x, requested.y);
    }
    pub fn scrollBy(self: *ScrollModel, delta: Point) Error!bool {
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y)) return error.InvalidGeometry;
        return self.clampTo(@as(f64, self.offset.x) + delta.x, @as(f64, self.offset.y) + delta.y);
    }
    fn clampTo(self: *ScrollModel, x: f64, y: f64) bool {
        const limit = self.maxOffset();
        const next: Point = .{ .x = @floatCast(std.math.clamp(x, 0, limit.x)), .y = @floatCast(std.math.clamp(y, 0, limit.y)) };
        const changed = !std.meta.eql(self.offset, next);
        self.offset = next;
        return changed;
    }
    /// Reveal a content rectangle with the minimum offset change. An oversized
    /// rectangle aligns its leading edge; a zero-size rectangle represents a caret.
    pub fn ensureVisible(self: *ScrollModel, rect: Rect) Error!bool {
        if (!layout.validRect(rect)) return error.InvalidGeometry;
        const x = reveal(self.offset.x, self.viewport.width, rect.x, rect.width);
        const y = reveal(self.offset.y, self.viewport.height, rect.y, rect.height);
        return self.clampTo(x, y);
    }
    fn reveal(offset: f64, viewport: f64, start: f64, length: f64) f64 {
        if (length > viewport or start < offset) return start;
        if (start + length > offset + viewport) return start + length - viewport;
        return offset;
    }
    pub fn contentPoint(self: *const ScrollModel, viewport_point: Point) Point {
        return .{ .x = viewport_point.x + self.offset.x, .y = viewport_point.y + self.offset.y };
    }
    /// Null means there is no scroll range or no usable track. The caller owns
    /// placement, hit testing and rendering of the returned thumb.
    pub fn scrollbar(self: *const ScrollModel, axis: Axis, track: Rect, min_thumb: f32) Error!?Scrollbar {
        if (!layout.validRect(track) or !std.math.isFinite(min_thumb) or min_thumb < 0) return error.InvalidGeometry;
        const viewport: f64 = if (axis == .horizontal) self.viewport.width else self.viewport.height;
        const content: f64 = if (axis == .horizontal) self.content.width else self.content.height;
        const offset: f64 = if (axis == .horizontal) self.offset.x else self.offset.y;
        const length: f64 = if (axis == .horizontal) track.width else track.height;
        const thickness = if (axis == .horizontal) track.height else track.width;
        if (content <= viewport or length <= 0 or thickness <= 0) return null;
        const thumb_length = std.math.clamp(length * viewport / content, @min(min_thumb, length), length);
        const start = (length - thumb_length) * offset / (content - viewport);
        var thumb = track;
        if (axis == .horizontal) {
            thumb.x = @floatCast(@as(f64, track.x) + start);
            thumb.width = @floatCast(thumb_length);
        } else {
            thumb.y = @floatCast(@as(f64, track.y) + start);
            thumb.height = @floatCast(thumb_length);
        }
        return .{ .axis = axis, .track = track, .thumb = thumb, .max_offset = @floatCast(content - viewport) };
    }
};

test "scroll clamps on content shrink and reports whether invalidation is needed" {
    var model: ScrollModel = .{};
    try std.testing.expect(try model.setSizes(.{ .width = 100, .height = 100 }, .{ .width = 300, .height = 500 }));
    try std.testing.expect(try model.scrollBy(.{ .x = 500, .y = 150 }));
    try std.testing.expectEqual(Point{ .x = 200, .y = 150 }, model.offset);
    try std.testing.expect(!(try model.scrollBy(.{ .x = 10 })));
    try std.testing.expect(try model.setSizes(.{ .width = 100, .height = 100 }, .{ .width = 50, .height = 120 }));
    try std.testing.expectEqual(Point{ .x = 0, .y = 20 }, model.offset);
    try std.testing.expectError(error.InvalidGeometry, model.scrollBy(.{ .y = std.math.nan(f32) }));
    try std.testing.expectEqual(Point{ .x = 0, .y = 20 }, model.offset);
}

test "ensure visible handles caret trailing edge and oversized content" {
    var model: ScrollModel = .{};
    _ = try model.setSizes(.{ .width = 100, .height = 80 }, .{ .width = 500, .height = 500 });
    _ = try model.ensureVisible(.{ .x = 150, .y = 100, .width = 20, .height = 20 });
    try std.testing.expectEqual(Point{ .x = 70, .y = 40 }, model.offset);
    _ = try model.ensureVisible(.{ .x = 20, .y = 10, .width = 200, .height = 200 });
    try std.testing.expectEqual(Point{ .x = 20, .y = 10 }, model.offset);
    _ = try model.ensureVisible(.{ .x = 400, .y = 400, .width = 0, .height = 0 });
    try std.testing.expectEqual(Point{ .x = 300, .y = 320 }, model.offset);
}

test "scrollbar thumb and drag offset agree including clamped minimum thumb" {
    var model: ScrollModel = .{};
    _ = try model.setSizes(.{ .height = 100 }, .{ .height = 1000 });
    _ = try model.setOffset(.{ .y = 450 });
    const bar = (try model.scrollbar(.vertical, .{ .x = 90, .y = 5, .width = 10, .height = 100 }, 20)).?;
    try std.testing.expectEqual(@as(f32, 20), bar.thumb.height);
    try std.testing.expectEqual(@as(f32, 45), bar.thumb.y);
    try std.testing.expectEqual(@as(f32, 450), try bar.offsetForThumb(bar.thumb.y));
    try std.testing.expectEqual(@as(f32, 900), try bar.offsetForThumb(500));
    try std.testing.expectEqual(@as(f32, 0), try bar.offsetForThumb(-100));
    _ = try model.setSizes(.{ .height = 100 }, .{ .height = 50 });
    try std.testing.expect((try model.scrollbar(.vertical, bar.track, 20)) == null);
}

test "a self-scrolling view's bar lays out, drags and hits as a container's" {
    const bar: Bar = .{ .box = .{ .x = 10, .y = 20, .width = 100, .height = 104 }, .view = 4, .content = 24, .offset = 20 };
    const thumb = bar.thumb(false).?;
    // At the bottom, a sixth of the track long, along the right edge.
    try std.testing.expectEqual(@as(f32, 10 + 100 - 2 - 4), thumb.x);
    try std.testing.expectEqual(@as(f32, 4), thumb.width);
    try std.testing.expectApproxEqAbs(@as(f32, 20 + 2 + 100), thumb.y + thumb.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 6.0), thumb.height, 0.001);
    const wide = bar.thumb(true).?;
    try std.testing.expectEqual(thumb.x - Bar.widen, wide.x);
    try std.testing.expectEqual(thumb.width + Bar.widen, wide.width);
    // Dragged to its track's top, then past its bottom.
    try std.testing.expectEqual(@as(f32, 0), bar.offsetAt(0));
    try std.testing.expectEqual(@as(f32, 20), bar.offsetAt(500));
    try std.testing.expectApproxEqAbs(@as(f32, 10), bar.offsetAt(22 + (100 - thumb.height) / 2), 0.001);
    try std.testing.expect(bar.hit(.{ .x = 105, .y = 50 }));
    try std.testing.expect(!bar.hit(.{ .x = 60, .y = 50 }));
    const left: Bar = .{ .box = bar.box, .leading = true, .view = 4, .content = 24, .offset = 0 };
    try std.testing.expectEqual(@as(f32, 12), left.thumb(false).?.x);
    try std.testing.expect(left.hit(.{ .x = 12, .y = 50 }));
    // Nowhere to scroll: nothing shows or hits.
    const short: Bar = .{ .box = bar.box, .view = 4, .content = 4, .offset = 0 };
    try std.testing.expect(short.thumb(false) == null and !short.hit(.{ .x = 105, .y = 50 }));
}
