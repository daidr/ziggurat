//! Pointer areas: containers that report the pointer over them, as custom
//! controls, canvases and rows that open context menus need. A build reads
//! the area's hover, press, clicks, double clicks, secondary and middle
//! clicks and the pointer's position from what `View.pointerArea` returns.
//!
//! The host routes the pointer here after the controls: a press that lands
//! on a control inside an area belongs to the control, so a button in a row
//! clicks the button and not the row. The innermost area under the press
//! takes it. Primary clicks, secondary clicks and middle clicks count when
//! the button comes up over the area that it went down on; a double click
//! counts as the second press goes down, within `double_press_time` and
//! `double_press_distance` of the first.
//!
//! The pointer's shape follows the same order from the innermost node out:
//! the first node that sets `Style.cursor` gives it, and a control that does
//! not set one shows the default arrow.
const std = @import("std");
const z = @import("ziggurat");
const view = @import("root.zig");

const View = view.View;
const Style = view.Style;
const Error = view.Error;
const Rect = view.Rect;
const Point = view.Point;
const Cursor = view.Cursor;
const Area = view.Overlay.Area;

pub const Button = enum { primary, secondary, middle };

/// What a pointer area learned in a pass of its own.
pub const PointerEvent = struct {
    /// Node id of the area.
    id: u64,
    phase: Phase,
    button: Button,
    /// 1 for a single press, 2 for the second of a double press, and so on.
    clicks: u8 = 1,
    /// A release over the area, which counts as a click.
    inside: bool = false,
    modifiers: z.KeyModifiers = .{},
    /// Where it happened, relative to the area's bounds.
    position: Point = .{},
    pub const Phase = enum { press, release, cancel };
};

pub const Options = struct {
    /// Repaint as the pointer moves over the area, so `position` follows
    /// it; without it the area repaints only as the pointer enters and
    /// leaves.
    track: bool = false,
};

/// The pointer over an area, as of this pass.
pub const PointerArea = struct {
    id: u64,
    /// Window bounds of the area in the last arranged pass, or null before
    /// its first.
    bounds: ?Rect = null,
    /// The pointer is over it and nothing that floats above covers it.
    hovered: bool = false,
    /// A button went down on it and the pointer is still over it.
    pressed: bool = false,
    /// The pointer relative to `bounds` while it is hovered.
    position: ?Point = null,
    /// A primary click came up over it in this pass.
    clicked: bool = false,
    /// The press count of that click: 1, then 2 for a double click and so on.
    clicks: u8 = 0,
    /// The second press of a double click went down on it in this pass.
    double_clicked: bool = false,
    /// A secondary click came up over it in this pass, as for a context menu.
    right_clicked: bool = false,
    /// A middle click came up over it in this pass.
    middle_clicked: bool = false,
    /// A button went down on it in this pass.
    pressed_now: ?Button = null,
    /// Modifier keys held as the button of this pass's press or click went
    /// down.
    modifiers: z.KeyModifiers = .{},
};

/// The press a pointer area follows until its release.
pub const Press = struct { id: u64, button: Button, clicks: u8, modifiers: z.KeyModifiers };
pub const Last = struct { id: u64 = 0, button: Button = .primary, time: u64 = 0, at: Point = .{}, count: u8 = 0 };

fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}
fn inside(inner: Rect, outer: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height;
}
fn local(bounds: Rect, point: Point) Point {
    return .{ .x = point.x - bounds.x, .y = point.y - bounds.y };
}

/// False when a shown list or popover covers `rect` at `point`: input there
/// reaches only what lies inside them.
fn reaches(v: *const View, rect: Rect, point: Point) bool {
    if (v.overlay.popup) |list| if (contains(list.rect, point) and !inside(rect, list.rect)) return false;
    if (v.overlay.popover) |panel| if (contains(panel.rect, point) and !inside(rect, panel.rect)) return false;
    return true;
}

fn entry(v: *const View, id: u64) ?*const Area {
    for (v.overlay.areas[0..v.overlay.area_count]) |*area| if (area.id == id) return area;
    return null;
}
fn hovering(v: *const View, area: *const Area) bool {
    const point = v.pointer orelse return false;
    return contains(area.rect, point) and reaches(v, area.rect, point);
}

/// The innermost pointer area at `point` that input reaches.
fn areaAt(v: *const View, point: Point) ?*const Area {
    var best: ?*const Area = null;
    for (v.overlay.areas[0..v.overlay.area_count]) |*area| {
        if (!contains(area.rect, point) or !reaches(v, area.rect, point)) continue;
        if (best == null or area.index > best.?.index) best = area;
    }
    return best;
}

/// Starts a pointer area laid out as a column; close it with `end`. What it
/// returns describes the pointer over it as of this pass. A disabled area
/// reports nothing but its bounds.
pub fn pointerArea(v: *View, options: Options, style: Style) Error!PointerArea {
    const node = try v.openNode(.pointer_area, style);
    node.track = options.track;
    var result: PointerArea = .{ .id = node.id };
    const known = entry(v, node.id);
    if (known) |area| result.bounds = area.bounds;
    const event = if (v.takeEvent(node.id)) |value| value.pointer else null;
    if (!node.style.enabled) return result;
    if (known) |area| if (hovering(v, area)) {
        result.hovered = true;
        result.position = local(area.bounds, v.pointer.?);
    };
    if (v.area_press) |held| result.pressed = held.id == node.id and result.hovered;
    if (event) |value| {
        result.modifiers = value.modifiers;
        switch (value.phase) {
            .press => {
                result.pressed_now = value.button;
                result.pressed = true;
                result.double_clicked = value.button == .primary and value.clicks == 2;
            },
            .release => if (value.inside) switch (value.button) {
                .primary => {
                    result.clicked = true;
                    result.clicks = value.clicks;
                },
                .secondary => result.right_clicked = true,
                .middle => result.middle_clicked = true,
            },
            .cancel => {},
        }
    }
    return result;
}

/// A button went down at `point` where no control took it: the innermost
/// pointer area there takes it, returning the pass to deliver, or null when
/// none is there. `now` counts double presses.
pub fn press(v: *View, point: Point, button: Button, modifiers: z.KeyModifiers, now: u64) ?view.Event {
    const area = areaAt(v, point) orelse {
        v.area_last.id = 0;
        return null;
    };
    const last = v.area_last;
    const again = last.id == area.id and last.button == button and now >= last.time and now - last.time <= view.double_press_time and distanceOf(last.at, point) <= view.double_press_distance;
    const count: u8 = if (again) last.count +| 1 else 1;
    v.area_last = .{ .id = area.id, .button = button, .time = now, .at = point, .count = count };
    v.area_press = .{ .id = area.id, .button = button, .clicks = count, .modifiers = modifiers };
    return .{ .pointer = .{ .id = area.id, .phase = .press, .button = button, .clicks = count, .modifiers = modifiers, .position = local(area.bounds, point) } };
}

/// `button` came up at `point`: the area it went down on learns whether it
/// was a click. Null when no area followed that button.
pub fn release(v: *View, point: Point, button: Button) ?view.Event {
    const held = v.area_press orelse return null;
    if (held.button != button) return null;
    v.area_press = null;
    const area = entry(v, held.id);
    const over = if (area) |value| contains(value.rect, point) and reaches(v, value.rect, point) else false;
    const bounds = if (area) |value| value.bounds else Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{ .pointer = .{ .id = held.id, .phase = .release, .button = button, .clicks = held.clicks, .inside = over, .modifiers = held.modifiers, .position = local(bounds, point) } };
}

/// The press was lost before its release, as when the window lost focus:
/// it counts as no click.
pub fn cancel(v: *View) ?view.Event {
    const held = v.area_press orelse return null;
    v.area_press = null;
    return .{ .pointer = .{ .id = held.id, .phase = .cancel, .button = held.button, .clicks = held.clicks, .modifiers = held.modifiers } };
}

/// The pointer moved to `point`, or left the window with null. True when an
/// area it enters or leaves, or a tracking area under it, should repaint.
pub fn moved(v: *View, point: ?Point) bool {
    v.pointer = point;
    var hasher = std.hash.Wyhash.init(0);
    for (v.overlay.areas[0..v.overlay.area_count]) |*area| {
        if (!hovering(v, area)) continue;
        hasher.update(std.mem.asBytes(&area.id));
        if (area.track) hasher.update(std.mem.asBytes(&point.?));
    }
    const signature = hasher.final();
    if (signature == v.area_signature) return false;
    v.area_signature = signature;
    return true;
}

/// The pointer's shape at `point`: from the innermost node there out, the
/// first that sets one, or the default when a control without one comes
/// first.
pub fn cursorAt(v: *const View, point: Point) Cursor {
    // Regions are in build order, so a later one that contains the point
    // lies inside or above an earlier one.
    var index = v.overlay.cursor_count;
    while (index > 0) {
        index -= 1;
        const region = &v.overlay.cursors[index];
        if (!contains(region.rect, point) or !reaches(v, region.rect, point)) continue;
        if (region.embed) |content| {
            if (content.cursor.?(content.context, region.id, local(region.bounds, point))) |shape| return shape;
            continue;
        }
        return region.cursor orelse .default;
    }
    return .default;
}

fn distanceOf(a: Point, b: Point) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}
