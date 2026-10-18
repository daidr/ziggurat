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
