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

/// How a scroll bar looks: the widths of its track and thumb, the thumb's
/// corners and shortest length, whether it runs to the ends of its edge,
/// and the colors of the track and of the thumb at rest, hovered and
/// dragged, as a code editor's bar of a square thumb over a track. A
/// theme's (`Theme.scrollbar`) styles every bar; a view's own takes its
/// place. The zero style draws as bars always have: a rounded thumb
/// `Bar.thickness` wide, `Bar.margin` clear of the edge and its ends, in
/// the theme's track color, with no track.
pub const Style = struct {
    /// How wide the bar is across, its track included; 0 is the thumb's
    /// width and `Bar.margin` on each side.
    track_width: f32 = 0,
    /// How wide the thumb is across, centered in the track; 0 is
    /// `Bar.thickness`.
    thumb_width: f32 = 0,
    /// The thumb's corner radius; null rounds its ends whole.
    radius: ?f32 = null,
    /// Square corners, as a radius of 0.
    square: bool = false,
    /// The thumb's shortest length; 0 is `Bar.min_thumb`.
    min_length: f32 = 0,
    /// The track and thumb run to the ends of the edge, with no margin.
    flush: bool = false,
    /// Colors (0xAARRGGBB, an alpha of 0 is opaque): the track's, drawn
    /// along the whole bar when set, and the thumb's at rest, while the
    /// pointer is over the bar and while it is dragged. Null keeps the
    /// theme's track color for the thumb, and the rest color for a state
    /// without one.
    track: ?u32 = null,
    thumb: ?u32 = null,
    thumb_hovered: ?u32 = null,
    thumb_dragged: ?u32 = null,

    /// The thumb's width across.
    pub fn thumbWidth(self: Style) f32 {
        return if (self.thumb_width > 0) self.thumb_width else Bar.thickness;
    }
    /// The bar's width across.
    pub fn trackWidth(self: Style) f32 {
        return if (self.track_width > 0) @max(self.track_width, self.thumbWidth()) else self.thumbWidth() + 2 * Bar.margin;
    }
    /// The space left clear at the bar's two ends.
    pub fn endMargin(self: Style) f32 {
        return if (self.flush) 0 else Bar.margin;
    }
    pub fn minLength(self: Style) f32 {
        return if (self.min_length > 0) self.min_length else Bar.min_thumb;
    }
    /// Whether every field is its zero, as a bar that takes the theme's.
    pub fn isDefault(self: Style) bool {
        return std.meta.eql(self, Style{});
    }
    /// A color of the style as one to paint with.
    pub fn color(value: u32) Color {
        const alpha: u8 = @intCast(value >> 24);
        return .{ .r = @intCast((value >> 16) & 0xff), .g = @intCast((value >> 8) & 0xff), .b = @intCast(value & 0xff), .a = if (alpha == 0) 255 else alpha };
    }
};
const Color = @import("geometry.zig").Color;

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
    /// Its look and geometry; the zero style is the bars' usual one, which
    /// `Frame.scrollbar` replaces with the theme's.
    style: Style = .{},

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
    /// The track the thumb moves along, as wide as the thumb.
    pub fn track(self: Bar) Rect {
        const b = self.box;
        const across = self.style.thumbWidth();
        const inset = (self.style.trackWidth() - across) / 2;
        const ends = self.style.endMargin();
        if (self.axis == .horizontal) return .{ .x = b.x + ends, .y = b.y + b.height - inset - across, .width = @max(0, b.width - 2 * ends), .height = across };
        return .{ .x = if (self.leading) b.x + inset else b.x + b.width - inset - across, .y = b.y + ends, .width = across, .height = @max(0, b.height - 2 * ends) };
    }
    /// The whole bar along its edge, as wide as `Style.trackWidth`, where a
    /// style's track color paints.
    pub fn trough(self: Bar) Rect {
        const b = self.box;
        const across = self.style.trackWidth();
        if (self.axis == .horizontal) return .{ .x = b.x, .y = b.y + b.height - across, .width = b.width, .height = across };
        return .{ .x = if (self.leading) b.x else b.x + b.width - across, .y = b.y, .width = across, .height = b.height };
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
        return model.scrollbar(self.axis, self.track(), self.style.minLength()) catch null;
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
        const reach = @max(strip, self.style.trackWidth());
        if (self.axis == .horizontal) return point.y >= b.y + b.height - reach;
        return if (self.leading) point.x < b.x + reach else point.x >= b.x + b.width - reach;
    }
    /// Paint the thumb into `target`, anything with `roundedRect`, in
    /// `color`, if the bar has somewhere to scroll.
    pub fn paint(self: Bar, target: anytype, color: anytype, dragging: bool) void {
        self.paintStyled(target, color, .{ .dragging = dragging });
    }
    pub const State = struct { dragging: bool = false, hovered: bool = false };
    /// Paint the track the style colors and the thumb, in the style's color
    /// for `state` or else `rest`, if the bar has somewhere to scroll.
    pub fn paintStyled(self: Bar, target: anytype, rest: anytype, state: State) void {
        if (!self.scrolls()) return;
        const style = self.style;
        if (style.track) |value| self.paintTrack(target, Style.color(value));
        const box = self.thumb(state.dragging) orelse return;
        const chosen = if (state.dragging) style.thumb_dragged orelse style.thumb_hovered orelse style.thumb else if (state.hovered) style.thumb_hovered orelse style.thumb else style.thumb;
        target.roundedRect(box, self.thumbRadius(box), if (chosen) |value| Style.color(value) else rest);
    }
    /// Paint the whole bar in `color`, as a style's track color does.
    pub fn paintTrack(self: Bar, target: anytype, color: anytype) void {
        target.roundedRect(self.trough(), 0, color);
    }
    /// The thumb's corner radius for its `box`.
    pub fn thumbRadius(self: Bar, box: Rect) f32 {
        if (self.style.square) return 0;
        const across = if (self.axis == .horizontal) box.height else box.width;
        return if (self.style.radius) |value| @min(value, across / 2) else across / 2;
    }
};

/// Persistent DIP state. Changes are explicit; no clocks, allocations or timers.
pub const ScrollModel = struct {
    offset: Point = .{},
    viewport: Size = .{},
    content: Size = .{},
    /// How far the user scrolled since a snapping container last came to
    /// rest, for it to go on from (NaN: snap where it shows); 0 when it
    /// rests. See `view.Style.scroll_snap`.
    snap_delta: f32 = 0,
    /// A glide of the offset under way (`view.ScrollIntoView.glide`): from
    /// `glide_from` to `glide_to` down, over `glide_ns` from `glide_start`
    /// on the view's clock. The user scrolling stops it.
    glide_from: f32 = 0,
    glide_to: f32 = 0,
    glide_start: u64 = 0,
    glide_ns: u64 = 0,
    /// The glide's easing, as `ziggurat_animation.Easing` numbers it.
    glide_easing: u8 = 0,

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

test "a scroll bar's style lays out its track and thumb, and the zero style keeps the usual bar" {
    const box: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 200 };
    const plain: Bar = .{ .box = box, .view = 200, .content = 800, .offset = 0 };
    // The usual bar: a 4 DIP thumb 2 DIP clear of the edge and the ends.
    const track = plain.track();
    try std.testing.expectEqual(@as(f32, 100 - Bar.margin - Bar.thickness), track.x);
    try std.testing.expectEqual(@as(f32, Bar.margin), track.y);
    try std.testing.expectEqual(@as(f32, Bar.thickness), track.width);
    try std.testing.expectEqual(@as(f32, 200 - 2 * Bar.margin), track.height);
    // A code editor's: a 14 DIP bar of a 10 DIP square thumb, to the ends.
    var styled = plain;
    styled.style = .{ .track_width = 14, .thumb_width = 10, .square = true, .flush = true, .min_length = 30, .track = 0x202020, .thumb = 0x606060, .thumb_hovered = 0x808080, .thumb_dragged = 0xa0a0a0 };
    const lane = styled.track();
    try std.testing.expectEqual(@as(f32, 100 - 2 - 10), lane.x);
    try std.testing.expectEqual(@as(f32, 0), lane.y);
    try std.testing.expectEqual(@as(f32, 200), lane.height);
    try std.testing.expectEqual(@as(f32, 86), styled.trough().x);
    try std.testing.expect(styled.hit(.{ .x = 87, .y = 50 }));
    try std.testing.expect(!plain.hit(.{ .x = 87, .y = 50 }));
    const thumb = styled.thumb(false).?;
    try std.testing.expectEqual(@as(f32, 0), styled.thumbRadius(thumb));
    try std.testing.expectEqual(@as(f32, 2), plain.thumbRadius(plain.thumb(false).?));
    // A tiny view still has a thumb as long as the style's shortest.
    var long = styled;
    long.content = 100_000;
    try std.testing.expectApproxEqAbs(@as(f32, 30), long.thumb(false).?.height, 0.01);

    const Paint = struct {
        colors: [4]Color = undefined,
        count: usize = 0,
        fn roundedRect(self: *@This(), _: Rect, _: f32, color: Color) void {
            self.colors[self.count] = color;
            self.count += 1;
        }
    };
    var painted: Paint = .{};
    styled.paintStyled(&painted, Color.rgb(0xff0000), .{ .hovered = true });
    try std.testing.expectEqual(@as(usize, 2), painted.count);
    try std.testing.expectEqual(@as(u32, 0x202020), painted.colors[0].hex());
    try std.testing.expectEqual(@as(u32, 0x808080), painted.colors[1].hex());
    painted = .{};
    styled.paintStyled(&painted, Color.rgb(0xff0000), .{ .dragging = true });
    try std.testing.expectEqual(@as(u32, 0xa0a0a0), painted.colors[1].hex());
    // The zero style paints the thumb alone, in the color it is given.
    painted = .{};
    plain.paintStyled(&painted, Color.rgb(0xff0000), .{ .hovered = true });
    try std.testing.expectEqual(@as(usize, 1), painted.count);
    try std.testing.expectEqual(@as(u32, 0xff0000), painted.colors[0].hex());
}
