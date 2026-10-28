//! Flyouts: borderless popup windows placed beside an anchor, such as the
//! panel a notification-area icon opens, a list a button drops down or a
//! hover card. A flyout has no frame, taskbar entry or background of its own;
//! its content draws all of it.
//!
//! The anchor is a rectangle of an owner window's client area, a rectangle
//! of the desktop, or a notification-area icon. The flyout goes on the side
//! its `Placement` names, lined up with the anchor's start, center or end;
//! where the work area of the display has no room for it there, it flips to
//! the other side or end if that has room, then slides back into the work
//! area, then shrinks to fit it. A flyout of an owner stays above it, follows
//! it as it moves or resizes, and closes with it; the others float above
//! other applications' windows.
//!
//! A focusable flyout takes the keyboard as it shows and closes, as the user
//! closing it, when another window takes the keyboard or, on Linux, when the
//! user presses outside it; `on_close` may keep it open. Any flyout closes so
//! on an Escape its content leaves unconsumed. A flyout that is not focusable
//! never takes the keyboard and stays until closed: tooltips, hover cards or
//! the suggestions of a text field, which close it as they see fit.
//!
//! Every call runs on the App's main thread. Keep a Flyout at a stable address
//! from `open` until its window's `on_closed`, which the Flyout forwards.
const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const desktop = @import("desktop.zig");
const Tray = @import("root.zig").Tray;

/// The side of the anchor a flyout goes to.
pub const Side = enum { bottom, top, right, left };
/// How a flyout lines up with its anchor along that side: their left or top
/// edges (start), their centers, or their right or bottom edges (end).
pub const Alignment = enum { start, center, end };
/// Where a flyout goes from its anchor: `bottom_start` is below it with
/// their left edges lined up.
pub const Placement = enum {
    bottom_start,
    bottom,
    bottom_end,
    top_start,
    top,
    top_end,
    right_start,
    right,
    right_end,
    left_start,
    left,
    left_end,

    pub fn side(self: Placement) Side {
        return @fromBackingInt(@intCast(@backingInt(self) / 3));
    }
    pub fn alignment(self: Placement) Alignment {
        return @fromBackingInt(@intCast(@backingInt(self) % 3));
    }
};

pub const Anchor = union(enum) {
    /// A rectangle of the owner's client area in DIPs, such as the box of
    /// the element that opens the flyout, or a point (an empty rectangle),
    /// such as the pointer's. The owner owns the flyout.
    window: struct { owner: z.Window, rect: z.Rect },
    /// A rectangle in native desktop coordinates, as `desktop.Monitor`
    /// reports them. The flyout has no owner.
    screen: desktop.Rect,
    /// A notification-area icon, as the panel of an application that lives
    /// there: beside the icon where the shell tells where it is, otherwise in
    /// the middle of the primary display's work area. The flyout has no owner.
    tray: *Tray,
};

pub const Options = struct {
    anchor: Anchor,
    placement: Placement = .bottom_start,
    /// Distance between the anchor and the flyout, in DIPs.
    gap: f32 = 0,
    /// Size in DIPs.
    width: u32 = 200,
    height: u32 = 200,
    focusable: bool = false,
    /// Creates the flyout without showing it; `show` shows it.
    hidden: bool = false,
    /// The system's popup shadow, where it has one.
    shadow: bool = false,
    title: []const u8 = "",
    /// The displays to place against instead of the system's, in the same
    /// coordinates, for hosts without a display server and tests.
    displays: ?[]const desktop.Monitor = null,
    /// Borrowed contexts remain valid through on_closed, as for windows.
    on_close: ?z.CloseHandler = null,
    on_closed: ?z.ClosedHandler = null,
};

pub const Flyout = struct {
    window: ?z.Window = null,
    anchor: Anchor = undefined,
    placement: Placement = .bottom_start,
    gap: f32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    displays: ?[]const desktop.Monitor = null,
    on_closed: ?z.ClosedHandler = null,

    /// Creates the flyout's window, places it and, unless `hidden`, shows
    /// it. Attach content to `window` before or after it shows. Fails with
    /// AlreadyOpen while an earlier window of this Flyout is open.
    pub fn open(self: *Flyout, app: *z.App, options: Options) !z.Window {
        app.assertOwner();
        if (self.isOpen()) return error.AlreadyOpen;
        try validate(options.gap, options.width, options.height);
        const owner: ?z.Window = switch (options.anchor) {
            .window => |value| owner: {
                if (value.owner.app != app) return error.ForeignApp;
                try validateRect(value.rect);
                break :owner value.owner;
            },
            else => null,
        };
        const window = try app.createWindow(.{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .decoration = .borderless,
            .resizable = false,
            .owner = owner,
            .popup = .{
                .focusable = options.focusable,
                .topmost = owner == null,
                .shadow = options.shadow,
                .handler = .{ .context = self, .dismiss = dismissed, .owner_moved = ownerMoved },
            },
            .on_close = options.on_close,
            .on_closed = .{ .context = self, .notify = closed },
        });
        self.* = .{
            .window = window,
            .anchor = options.anchor,
            .placement = options.placement,
            .gap = options.gap,
            .width = options.width,
            .height = options.height,
            .displays = options.displays,
            .on_closed = options.on_closed,
        };
        self.place() catch |err| {
            _ = window.destroy() catch {};
            return err;
        };
        if (!options.hidden) window.show();
        return window;
    }

    /// Whether the flyout's window is open, closing included.
    pub fn isOpen(self: *const Flyout) bool {
        const window = self.window orelse return false;
        return !window.isClosed();
    }

    pub fn show(self: *Flyout) void {
        if (self.window) |window| window.show();
    }

    /// Closes the flyout as the application, which `on_close` may cancel.
    pub fn close(self: *Flyout) !z.CloseResult {
        const window = self.window orelse return .closed;
        return window.requestClose();
    }

    /// Opens the flyout, or closes it when it is open: the click of the
    /// notification-area icon or the button that opens it.
    pub fn toggle(self: *Flyout, app: *z.App, options: Options) !void {
        if (self.isOpen()) {
            _ = try self.close();
            return;
        }
        _ = try self.open(app, options);
    }

    /// Places the flyout against another anchor of the same kind, and of the
    /// same owner for a window anchor.
    pub fn setAnchor(self: *Flyout, anchor: Anchor) !void {
        if (!self.isOpen()) return error.Closed;
        if (std.meta.activeTag(anchor) != std.meta.activeTag(self.anchor)) return error.AnchorKindChanged;
        if (anchor == .window) {
            if (!std.meta.eql(anchor.window.owner, self.anchor.window.owner)) return error.AnchorOwnerChanged;
            try validateRect(anchor.window.rect);
        }
        self.anchor = anchor;
        try self.place();
    }

    /// Resizes the flyout, such as to the size its content measured, and
    /// places it again.
    pub fn setSize(self: *Flyout, width: u32, height: u32) !void {
        if (!self.isOpen()) return error.Closed;
        try validate(self.gap, width, height);
        self.width = width;
        self.height = height;
        try self.place();
    }

    /// Places the flyout where it goes now.
    pub fn place(self: *Flyout) !void {
        const window = self.window orelse return error.Closed;
        if (window.isClosed()) return error.Closed;
        var staging: [desktop.max_monitors]desktop.Monitor = undefined;
        const displays = self.displays orelse staging[0 .. desktop.monitors(window.app, &staging) catch |err| {
            // Without displays to place against, keep the size only. Some
            // builds report no other failure, so this is not a switch.
            if (err == error.UnsupportedCapability) return window.setClientBounds(.{ .width = self.width, .height = self.height });
            return err;
        }];
        if (displays.len == 0) return window.setClientBounds(.{ .width = self.width, .height = self.height });
        const anchor: ?Box = switch (self.anchor) {
            .window => |value| anchor: {
                const bounds = try value.owner.clientBounds();
                // Wayland reports no positions; its compositor places windows.
                const origin = bounds.position orelse return window.setClientBounds(.{ .width = self.width, .height = self.height });
                const scale = nativeScale((try value.owner.contentSize()).scale);
                break :anchor .{
                    .x = origin.x + round(value.rect.x * scale),
                    .y = origin.y + round(value.rect.y * scale),
                    .width = round(value.rect.width * scale),
                    .height = round(value.rect.height * scale),
                };
            },
            .screen => |rect| Box.of(rect),
            .tray => |tray| if (tray.iconRect()) |rect| Box.of(rect) else null,
        };
        const result: Box = if (anchor) |rect| result: {
            const monitor = monitorFor(rect, displays);
            const scale = nativeScale(monitor.scale);
            const size: Size = .{ .width = round(@as(f32, @floatFromInt(self.width)) * scale), .height = round(@as(f32, @floatFromInt(self.height)) * scale) };
            break :result placeBeside(rect, size, Box.of(monitor.work_area), self.placement, round(self.gap * scale)).box;
        } else result: {
            const monitor = primary(displays);
            const scale = nativeScale(monitor.scale);
            const size: Size = .{ .width = round(@as(f32, @floatFromInt(self.width)) * scale), .height = round(@as(f32, @floatFromInt(self.height)) * scale) };
            break :result centered(size, Box.of(monitor.work_area));
        };
        const monitor = monitorFor(result, displays);
        const scale = nativeScale(monitor.scale);
        try window.setClientBounds(.{
            .position = .{ .x = result.x, .y = result.y },
            .width = dips(result.width, scale),
            .height = dips(result.height, scale),
        });
    }

    fn dismissed(ptr: *anyopaque, window: z.Window) void {
        const self: *Flyout = @ptrCast(@alignCast(ptr));
        // A press on its own icon: the icon's click toggles the flyout.
        if (self.anchor == .tray and self.anchor.tray.pointerOverIcon()) return;
        _ = window.requestCloseFrom(.user) catch |err| window.report(.{ .domain = .core, .operation = .window_destroy, .err = err });
    }
    fn ownerMoved(ptr: *anyopaque, _: z.Window) void {
        const self: *Flyout = @ptrCast(@alignCast(ptr));
        self.place() catch |err| if (self.window) |window| window.report(.{ .severity = .warning, .domain = .core, .operation = .window_update, .err = err });
    }
    fn closed(ptr: *anyopaque, window: z.Window) void {
        const self: *Flyout = @ptrCast(@alignCast(ptr));
        if (self.window) |current| if (std.meta.eql(current, window)) {
            self.window = null;
        };
        if (self.on_closed) |handler| handler.notify(handler.context, window);
    }
};

/// Native desktop units per DIP for flyout sizes: physical pixels on Windows,
/// where monitors scale; GDK logical coordinates, which are DIPs, elsewhere.
fn nativeScale(scale: f32) f32 {
    if (builtin.os.tag != .windows or !std.math.isFinite(scale) or scale <= 0) return 1;
    return scale;
}
fn round(value: f32) i32 {
    return @intFromFloat(std.math.clamp(@round(value), -1e9, 1e9));
}
fn dips(native: i32, scale: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(@max(native, 1))) / scale), 1, 32768));
}
fn validate(gap: f32, width: u32, height: u32) !void {
    if (!std.math.isFinite(gap) or @abs(gap) > 4096) return error.InvalidGeometry;
    if (width == 0 or height == 0 or width > 32768 or height > 32768) return error.InvalidSize;
}
fn validateRect(rect: z.Rect) !void {
    const limit = 1e6;
    if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidGeometry;
    if (@abs(rect.x) > limit or @abs(rect.y) > limit or rect.width < 0 or rect.height < 0 or rect.width > limit or rect.height > limit) return error.InvalidGeometry;
}

/// A rectangle in native desktop units.
pub const Box = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn of(rect: desktop.Rect) Box {
        return .{ .x = rect.x, .y = rect.y, .width = @intCast(@min(rect.width, std.math.maxInt(i32))), .height = @intCast(@min(rect.height, std.math.maxInt(i32))) };
    }
};
pub const Size = struct { width: i32, height: i32 };
pub const Placed = struct { box: Box, flipped_x: bool, flipped_y: bool };

/// Where a flyout of `size` goes beside `anchor` in `work`. On each axis it
/// flips to the other side of the anchor, or to its other end, where it would
/// not fit and the flipped place would; then it slides along the edge it
/// would cross, back into the work area; then it shrinks to it.
pub fn placeBeside(anchor: Box, size: Size, work: Box, placement: Placement, gap: i32) Placed {
    const cross: i32 = @as(i32, @backingInt(placement.alignment())) - 1;
    // The point of the anchor the flyout goes to, the point of the flyout
    // that goes there (-1 left or top, 0 middle, 1 right or bottom), and the
    // offset between them.
    var anchor_x: i32 = cross;
    var anchor_y: i32 = cross;
    var window_x: i32 = cross;
    var window_y: i32 = cross;
    var dx: i32 = 0;
    var dy: i32 = 0;
    switch (placement.side()) {
        .bottom => {
            anchor_y = 1;
            window_y = -1;
            dy = gap;
        },
        .top => {
            anchor_y = -1;
            window_y = 1;
            dy = -gap;
        },
        .right => {
            anchor_x = 1;
            window_x = -1;
            dx = gap;
        },
        .left => {
            anchor_x = -1;
            window_x = 1;
            dx = -gap;
        },
    }
    var result: Placed = .{ .box = .{ .x = 0, .y = 0, .width = size.width, .height = size.height }, .flipped_x = false, .flipped_y = false };
    result.box.x, result.flipped_x = flip(work.x, work.width, anchor.x, anchor.width, size.width, anchor_x, window_x, dx);
    result.box.y, result.flipped_y = flip(work.y, work.height, anchor.y, anchor.height, size.height, anchor_y, window_y, dy);
    result.box.x, result.box.width = slide(work.x, work.width, result.box.x, result.box.width);
    result.box.y, result.box.height = slide(work.y, work.height, result.box.y, result.box.height);
    return result;
}

fn flip(bounds_position: i32, bounds_size: i32, rect_position: i32, rect_size: i32, size: i32, rect_sign: i32, window_sign: i32, offset: i32) struct { i32, bool } {
    const primary_position = rect_position + @divTrunc((1 + rect_sign) * rect_size, 2) + offset - @divTrunc((1 + window_sign) * size, 2);
    if (primary_position >= bounds_position and primary_position + size <= bounds_position + bounds_size) return .{ primary_position, false };
    const secondary = rect_position + @divTrunc((1 - rect_sign) * rect_size, 2) - offset - @divTrunc((1 - window_sign) * size, 2);
    if (secondary >= bounds_position and secondary + size <= bounds_position + bounds_size) return .{ secondary, true };
    return .{ primary_position, false };
}

/// Moves a span back into bounds, its start first when it is longer, then
/// cuts what still sticks out.
fn slide(bounds_position: i32, bounds_size: i32, position: i32, size: i32) struct { i32, i32 } {
    var start = position;
    var length = size;
    if (start + length > bounds_position + bounds_size) start = bounds_position + bounds_size - length;
    if (start < bounds_position) start = bounds_position;
    if (start + length > bounds_position + bounds_size) length = bounds_position + bounds_size - start;
    return .{ start, @max(length, 1) };
}

/// In the middle of the work area, as large as it fits.
pub fn centered(size: Size, work: Box) Box {
    const width = @min(size.width, work.width);
    const height = @min(size.height, work.height);
    return .{ .x = work.x + @divTrunc(work.width - width, 2), .y = work.y + @divTrunc(work.height - height, 2), .width = width, .height = height };
}

/// The display a flyout anchored at `rect` goes to: the one whose work area
/// overlaps it the most, else the one nearest to its center.
pub fn monitorFor(rect: Box, displays: []const desktop.Monitor) desktop.Monitor {
    std.debug.assert(displays.len != 0);
    var best: ?usize = null;
    var best_area: i64 = 0;
    for (displays, 0..) |display, index| {
        const area = overlap(Box.of(display.work_area), rect);
        if (area > best_area) {
            best = index;
            best_area = area;
        }
    }
    if (best) |index| return displays[index];
    const cx: i64 = @as(i64, rect.x) + @divTrunc(rect.width, 2);
    const cy: i64 = @as(i64, rect.y) + @divTrunc(rect.height, 2);
    var nearest: usize = 0;
    var nearest_distance: i64 = -1;
    for (displays, 0..) |display, index| {
        const bounds = Box.of(display.bounds);
        const dx = @max(@as(i64, bounds.x) - cx, 0, cx - (@as(i64, bounds.x) + bounds.width - 1));
        const dy = @max(@as(i64, bounds.y) - cy, 0, cy - (@as(i64, bounds.y) + bounds.height - 1));
        const distance = dx * dx + dy * dy;
        if (nearest_distance < 0 or distance < nearest_distance) {
            nearest = index;
            nearest_distance = distance;
        }
    }
    return displays[nearest];
}

fn primary(displays: []const desktop.Monitor) desktop.Monitor {
    for (displays) |display| if (display.primary) return display;
    return displays[0];
}

fn overlap(a: Box, b: Box) i64 {
    const width = @min(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width) - @max(a.x, b.x);
    const height = @min(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height) - @max(a.y, b.y);
    if (width <= 0 or height <= 0) return 0;
    return width * height;
}
