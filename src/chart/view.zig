//! Charts as leaves of declarative views. A build function describes the
//! chart's marks over the axes it gives; the leaf lays the plot out, paints
//! grid lines, bars, points, rules, labels and the legend with the frame's
//! primitives, and paints lines, areas and pie slices from coverage masks
//! prepared for the plot's size. Preparation runs as a posted task after
//! paint, never inside paint, and only when the data, the plot's size or
//! the scale changed, so an unchanged chart paints without allocating.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const vector = @import("ziggurat_vector");
const chart = @import("ziggurat_chart");

pub const Span = chart.Span;
pub const Curve = chart.Curve;
pub const Color = ui.Color;

/// One thing drawn in the plot's area, in fractions of it. Slices are
/// borrowed: keep them valid and unchanged until the next build, since a
/// preparation posted after paint reads them.
pub const Mark = union(enum) {
    /// A box over a stretch along x and up y: a bar or a band.
    bar: struct { x: Span, y: Span, color: Color, radius: f32 = 0 },
    /// A dot of `size` DIPs centered on a point.
    point: struct { x: f32, y: f32, color: Color, size: f32 = 6 },
    /// A vertical line across the plot.
    rule_x: struct { x: f32, color: Color, width: f32 = 1 },
    /// A horizontal line across the plot.
    rule_y: struct { y: f32, color: Color, width: f32 = 1 },
    /// A stroked line through points; NaN breaks it.
    line: struct { xs: []const f32, ys: []const f32, color: Color, curve: Curve = .linear, width: f32 = 2 },
    /// The area between `lo` (or the bottom) and `hi`; NaN breaks it.
    area: struct { xs: []const f32, hi: []const f32, lo: ?[]const f32 = null, color: Color, curve: Curve = .linear },
    /// A slice of a pie centered in the plot; radii are fractions of half
    /// the plot's shorter side.
    sector: struct { slice: chart.Slice, color: Color, inner: f32 = 0, outer: f32 = 1 },
    /// Text anchored at a point, as a value over a bar.
    label: struct { x: f32, y: f32, text: []const u8, h: chart.Anchor = .center, v: chart.Anchor = .end, color: ?u32 = null },

    fn prepared(self: Mark) bool {
        return switch (self) {
            .line, .area, .sector => true,
            else => false,
        };
    }
};

pub const LegendPlacement = enum { none, top, bottom };

/// What the pointer does to the plot beyond choosing points.
pub const Interaction = struct {
    /// What a primary drag across the plot does: nothing, or brush a
    /// stretch along x or y, or a box.
    brush: ?chart.Directions = null,
    /// A finished brush zooms into what it covers instead of staying as
    /// `Chart.brush`.
    brush_zooms: bool = false,
    /// Directions the wheel zooms, around the pointer, and a drag pans: a
    /// plain drag without a brush, or a drag with Shift held as it began.
    /// The horizontal wheel pans along x. The keys `+` and `-` zoom while
    /// the chart has focus, and a double press or `0` shows the whole plot
    /// again.
    zoom: ?chart.Directions = null,
    /// The closest zoom, as the shortest span of the whole plot shown.
    min_span: f32 = 0.01,
    /// How much one wheel notch, 48 DIP, zooms in.
    wheel_factor: f32 = 1.25,
};

pub const Grid = struct {
    /// Lines across the plot at the left (or right) axis ticks.
    horizontal: bool = true,
    /// Lines up the plot at the bottom (or top) axis ticks.
    vertical: bool = false,
};

pub const Options = struct {
    /// Accessible name of the chart, read as an image.
    name: []const u8 = "",
    /// Preferred size before the parent's flex layout applies.
    width: f32 = 320,
    height: f32 = 200,
    /// Room between the axis labels and the plot's area.
    gap: f32 = 6,
    grid: Grid = .{},
    /// Grid line color; defaults to the theme's border.
    grid_color: ?u32 = null,
    /// Axis, label and legend text color; defaults to the theme's text.
    label_color: ?u32 = null,
    legend: LegendPlacement = .top,
    legend_options: chart.LegendOptions = .{},
    /// Room between the legend and the plot.
    legend_gap: f32 = 8,
    measurer: view.Measurer = .{},
    interaction: Interaction = .{},
};

/// Prepared coverage of one line, area or slice.
pub const Slot = struct {
    prepared: ?*vector.Prepared = null,
    /// What the coverage was prepared from, and what the last paint needs.
    key: u64 = 0,
    wanted: u64 = 0,
    width: f32 = 0,
    height: f32 = 0,
    scale: f32 = 0,
    zoom: chart.Zoom = .{},
};

pub const Buffers = struct {
    marks: []Mark,
    /// One per line, area or slice mark.
    slots: []Slot,
    legend: []chart.LegendSlot,
};

/// Fixed storage for a chart, kept at a stable address by its owner.
pub fn Storage(comptime marks: usize, comptime paths: usize, comptime legend_items: usize) type {
    return struct {
        const Self = @This();
        marks: [marks]Mark = undefined,
        slots: [paths]Slot = @as([paths]Slot, @splat(.{})),
        legend: [legend_items]chart.LegendSlot = undefined,
        pub fn buffers(self: *Self) Buffers {
            return .{ .marks = &self.marks, .slots = &self.slots, .legend = &self.legend };
        }
    };
}

pub const Error = error{ TooManyMarks, TooManyPaths, TooManyLegendItems };

/// Describes a point for assistive technology, "March: 42 sales": write
/// into `buffer` and return the written part.
pub const Describe = struct {
    context: ?*const anyopaque = null,
    call: *const fn (context: ?*const anyopaque, index: usize, buffer: []u8) []const u8,
};

/// Longest point description kept, in bytes.
pub const max_description = 128;

/// Keep Chart at a stable address while the view emits it and until
/// `deinit`; the posted preparation refers to it.
pub const Chart = struct {
    host: *view.Host,
    allocator: std.mem.Allocator,
    buffers: Buffers,
    options: Options,
    axes: chart.Axes = .{},
    legend_items: []const chart.LegendItem = &.{},
    /// Accessible value, such as the description of the selected point.
    value: []const u8 = "",
    mark_len: usize = 0,
    path_len: usize = 0,
    /// The plot's area of the last paint, in window DIPs.
    area: chart.Rect = .{},
    scale: f32 = 1,
    queued: bool = false,
    /// Reused across preparations; grown only while preparing.
    commands: std.ArrayListUnmanaged(chart.Command) = .empty,
    outline: std.ArrayListUnmanaged(vector.Command) = .empty,
    /// The first error from deferred preparation, for diagnostics.
    last_error: ?anyerror = null,
    /// The point the pointer or the keyboard chose among `points`; it
    /// persists across builds. Read `selection.index` in the build function
    /// to show the choice with marks.
    selection: chart.Selection = .{},
    /// Fractions along the plot, in ascending order, that the selection
    /// chooses among; empty leaves the chart without input. Borrowed.
    points: []const f32 = &.{},
    describe: ?Describe = null,
    /// The leaf's bounds of the last paint, in window DIPs.
    bounds: chart.Rect = .{},
    description: [max_description]u8 = undefined,
    /// What part of the plot shows; marks and ticks stay in fractions of
    /// the whole plot and the chart places them for it. Set it to zoom from
    /// the application; read it to pick ticks for what shows (`rebase`).
    zoom: chart.Zoom = .{},
    /// The part of the plot the last finished brush covers, in fractions of
    /// the whole plot, until a press without a drag clears it.
    brush: ?chart.Brush = null,
    /// What the pointer pressing the plot does, and where it began, in
    /// fractions of what shows.
    press: enum { none, brush, pan } = .none,
    press_from: chart.Point = .{},
    press_to: chart.Point = .{},
    dragged: bool = false,

    pub fn init(host: *view.Host, allocator: std.mem.Allocator, buffers: Buffers, options: Options) Chart {
        return .{ .host = host, .allocator = allocator, .buffers = buffers, .options = options };
    }

    /// Start describing the chart for this build over `axes`, borrowed.
    pub fn begin(self: *Chart, axes: chart.Axes) void {
        self.axes = axes;
        self.mark_len = 0;
        self.path_len = 0;
        self.legend_items = &.{};
        self.value = "";
        self.points = &.{};
        self.describe = null;
    }

    /// Let the pointer and the keyboard choose among the points at `xs`,
    /// borrowed fractions along the plot in ascending order: the point
    /// nearest the pointer while it is over the plot's area, none once it
    /// leaves. The chart becomes a Tab stop where the left and right arrows,
    /// Home and End move the choice and Escape clears it. `describe` tells
    /// assistive technology about a point, read as the chart's value and
    /// announced as the keys reach it.
    pub fn select(self: *Chart, xs: []const f32, describe: ?Describe) void {
        self.points = xs;
        self.describe = describe;
        if (self.selection.index) |i| if (i >= xs.len) {
            self.selection.index = null;
        };
    }

    /// The description of the chosen point, or empty.
    pub fn selected(self: *Chart) []const u8 {
        const index = self.selection.index orelse return "";
        const describe = self.describe orelse return "";
        const text = describe.call(describe.context, index, &self.description);
        const len = @min(text.len, max_description);
        std.mem.copyForwards(u8, self.description[0..len], text[0..len]);
        return self.description[0..len];
    }

    pub fn add(self: *Chart, mark: Mark) Error!void {
        if (self.mark_len == self.buffers.marks.len) return error.TooManyMarks;
        if (mark.prepared()) {
            if (self.path_len == self.buffers.slots.len) return error.TooManyPaths;
            self.path_len += 1;
        }
        self.buffers.marks[self.mark_len] = mark;
        self.mark_len += 1;
    }

    /// Show `items`, borrowed, as the legend.
    pub fn setLegend(self: *Chart, items: []const chart.LegendItem) Error!void {
        if (items.len > self.buffers.legend.len) return error.TooManyLegendItems;
        self.legend_items = items;
    }

    pub fn marks(self: *const Chart) []const Mark {
        return self.buffers.marks[0..self.mark_len];
    }

    /// The leaf to emit with `View.embed`. Give it a `Style.key` when
    /// siblings before it can change.
    pub fn embed(self: *Chart) view.Embed {
        const interactive = self.points.len > 0 or self.options.interaction.brush != null or self.options.interaction.zoom != null;
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .focusable = interactive, .input = if (interactive) input else null };
    }

    /// Show the whole plot and drop the brush. True when either changed.
    pub fn resetZoom(self: *Chart) bool {
        const brushed = self.brush != null;
        self.brush = null;
        const changed = self.zoom.reset() or brushed;
        if (changed) self.refresh();
        return changed;
    }

    /// The fraction along the plot's area of a point local to the leaf, or
    /// null outside the area.
    fn along(self: *const Chart, local: view.Point) ?f32 {
        const at = self.within(local) orelse return null;
        return at.x;
    }
    /// A point local to the leaf in fractions of the plot's area, x from its
    /// left and y from its bottom, or null outside the area.
    fn within(self: *const Chart, local: view.Point) ?chart.Point {
        const a = self.area;
        const px = self.bounds.x + local.x;
        const py = self.bounds.y + local.y;
        if (!(a.width > 0 and a.height > 0) or px < a.x or px > a.x + a.width or py < a.y or py > a.y + a.height) return null;
        return .{ .x = (px - a.x) / a.width, .y = 1 - (py - a.y) / a.height };
    }
    /// A point local to the leaf in fractions of the plot's area, held
    /// within it, for a drag that leaves it.
    fn clamped(self: *const Chart, local: view.Point) chart.Point {
        const a = self.area;
        if (!(a.width > 0 and a.height > 0)) return .{};
        return .{ .x = std.math.clamp((self.bounds.x + local.x - a.x) / a.width, 0, 1), .y = std.math.clamp(1 - (self.bounds.y + local.y - a.y) / a.height, 0, 1) };
    }

    /// Prepare masks for a changed zoom now, outside paint, so the next
    /// frame paints them at once.
    fn refresh(self: *Chart) void {
        if (self.host.context.window == null) return;
        self.prepareAll();
    }

    fn pointerDown(self: *Chart, press: view.PointerPress) bool {
        const at = self.within(press.position) orelse return false;
        const interaction = self.options.interaction;
        self.dragged = false;
        self.press = .none;
        // A double press shows the whole plot again.
        if (press.count >= 2 and (interaction.zoom != null or interaction.brush != null)) {
            _ = self.resetZoom();
            return true;
        }
        if (interaction.brush != null and !(press.modifiers.shift and interaction.zoom != null)) {
            self.press = .brush;
        } else if (interaction.zoom != null) self.press = .pan;
        self.press_from = at;
        self.press_to = at;
        // A press in the area takes the focus for the keys.
        return true;
    }
    fn pointerDrag(self: *Chart, drag: view.PointerDrag) bool {
        if (self.press == .none or !drag.dragging) return false;
        self.dragged = true;
        const to = self.clamped(drag.position);
        switch (self.press) {
            .none => unreachable,
            .brush => {
                const changed = !std.meta.eql(to, self.press_to);
                self.press_to = to;
                return changed;
            },
            .pan => {
                const a = self.area;
                if (!(a.width > 0 and a.height > 0)) return false;
                // What shows follows the pointer.
                if (!self.zoom.pan(self.options.interaction.zoom.?, -drag.delta.x / a.width, drag.delta.y / a.height)) return false;
                self.refresh();
                return true;
            },
        }
    }
    fn pointerUp(self: *Chart, local: view.Point) bool {
        const kind = self.press;
        self.press = .none;
        if (kind == .none) return false;
        if (!self.dragged) {
            // A press that did not drag clears the brush.
            const brushed = self.brush != null;
            self.brush = null;
            return brushed;
        }
        if (kind == .pan) return true;
        const interaction = self.options.interaction;
        const directions = interaction.brush.?;
        const to = self.clamped(local);
        var x: chart.Span = .{ .lo = @min(self.press_from.x, to.x), .hi = @max(self.press_from.x, to.x) };
        var y: chart.Span = .{ .lo = @min(self.press_from.y, to.y), .hi = @max(self.press_from.y, to.y) };
        if (directions == .y) x = .{ .lo = 0, .hi = 1 };
        if (directions == .x) y = .{ .lo = 0, .hi = 1 };
        if (interaction.brush_zooms) {
            self.brush = null;
            if (self.zoom.select(directions, x, y, interaction.min_span)) self.refresh();
            return true;
        }
        const shown = self.zoom;
        self.brush = .{ .x = .{ .lo = shown.wholeX(x.lo), .hi = shown.wholeX(x.hi) }, .y = .{ .lo = shown.wholeY(y.lo), .hi = shown.wholeY(y.hi) } };
        return true;
    }
    fn wheel(self: *Chart, scroll: view.PointerWheel) bool {
        const directions = self.options.interaction.zoom orelse return false;
        const at = self.within(scroll.position) orelse return false;
        const a = self.area;
        var changed = false;
        if (scroll.delta.y != 0) {
            const factor = std.math.pow(f32, self.options.interaction.wheel_factor, -scroll.delta.y / 48);
            changed = self.zoom.zoomAt(directions, factor, at, self.options.interaction.min_span);
        }
        if (scroll.delta.x != 0 and directions != .y) changed = self.zoom.pan(.x, scroll.delta.x / a.width, 0) or changed;
        if (changed) self.refresh();
        // A chart that zooms keeps the wheel from the containers around it.
        return true;
    }
    fn zoomKey(self: *Chart, key_input: z.KeyInput) ?bool {
        const directions = self.options.interaction.zoom orelse return null;
        // `+` is Shift and `=` on many layouts.
        if (key_input.modifiers.shift and key_input.key != .equal) return null;
        const factor: f32 = switch (key_input.key) {
            .equal, .add => self.options.interaction.wheel_factor,
            .minus, .subtract => 1 / self.options.interaction.wheel_factor,
            .digit0, .numpad0 => {
                _ = self.resetZoom();
                return true;
            },
            else => return null,
        };
        if (self.zoom.zoomAt(directions, factor, .{ .x = 0.5, .y = 0.5 }, self.options.interaction.min_span)) self.refresh();
        return true;
    }

    fn input(ptr: *anyopaque, _: u64, event: view.EmbedInput) bool {
        const self: *Chart = @ptrCast(@alignCast(ptr));
        switch (event) {
            .pointer_move => |local| {
                const at = self.along(local);
                return self.selection.pointer(if (at) |f| self.zoom.wholeX(f) else null, self.points).changed;
            },
            .pointer_leave => return self.selection.pointer(null, self.points).changed,
            .pointer_down => |press| return self.pointerDown(press),
            .pointer_drag => |drag| return self.pointerDrag(drag),
            .pointer_up => |local| return self.pointerUp(local),
            .pointer_cancel => {
                self.press = .none;
                return self.dragged;
            },
            .wheel => |scroll| return self.wheel(scroll),
            .key_up => return false,
            .key => |key_input| {
                const m = key_input.modifiers;
                if (m.control or m.alt or m.super) return false;
                if (self.zoomKey(key_input)) |taken| return taken;
                if (m.shift) return false;
                // Escape gives up a brush being dragged, then drops the
                // brush, before the choice.
                if (key_input.key == .escape and self.press == .brush and self.dragged) {
                    self.press = .none;
                    return true;
                }
                if (key_input.key == .escape and self.brush != null) {
                    self.brush = null;
                    return true;
                }
                const pressed: chart.Key = switch (key_input.key) {
                    .left => .left,
                    .right => .right,
                    .home => .home,
                    .end => .end,
                    .escape => if (self.selection.index == null) return false else .escape,
                    else => return false,
                };
                const change = self.selection.key(pressed, self.points.len);
                if (change.announce) {
                    const text = self.selected();
                    if (text.len > 0) self.host.announce(text);
                }
                return true;
            },
        }
    }

    /// Release prepared coverage. Call outside paint, before the Context
    /// detaches; the chart can be described and shown again afterwards.
    pub fn deinit(self: *Chart) void {
        for (self.buffers.slots) |*slot| self.release(slot);
        self.commands.deinit(self.allocator);
        self.outline.deinit(self.allocator);
        self.commands = .empty;
        self.outline = .empty;
    }

    fn release(self: *Chart, slot: *Slot) void {
        const prepared = slot.prepared orelse return;
        if (self.host.context.window != null) _ = self.host.context.releaseCoverage(prepared.identity) catch |err| {
            self.last_error = self.last_error orelse err;
        };
        prepared.close() catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        slot.* = .{};
    }

    fn measureText(context: ?*anyopaque, text: []const u8) chart.Size {
        const self: *Chart = @ptrCast(@alignCast(context.?));
        const size = self.options.measurer.measure(self.options.measurer.context, text);
        return .{ .width = size.width, .height = size.height };
    }
    fn measurer(self: *Chart) chart.Measure {
        return .{ .context = self, .call = measureText };
    }

    fn measure(ptr: *anyopaque, _: ui.Theme) view.layout.Measurement {
        const self: *Chart = @ptrCast(@alignCast(ptr));
        return .{ .minimum = .{ .width = 32, .height = 32 }, .preferred = .{ .width = self.options.width, .height = self.options.height } };
    }

    /// Where the legend and the plot go within `bounds`.
    pub fn arrange(self: *Chart, bounds: chart.Rect) struct { plot: chart.Layout, legend: []const chart.LegendSlot } {
        var plot_bounds = bounds;
        var slots: []const chart.LegendSlot = &.{};
        if (self.options.legend != .none and self.legend_items.len > 0) {
            const out = self.buffers.legend[0..self.legend_items.len];
            const size = chart.legend(bounds, self.legend_items, self.options.legend_options, self.measurer(), out) catch unreachable;
            const taken = size.height + self.options.legend_gap;
            if (self.options.legend == .bottom) {
                const top = bounds.y + @max(0, bounds.height - size.height);
                for (out) |*slot| {
                    slot.swatch.y += top - bounds.y;
                    slot.label.y += top - bounds.y;
                }
            } else plot_bounds.y += taken;
            plot_bounds.height = @max(0, plot_bounds.height - taken);
            slots = out;
        }
        return .{ .plot = chart.layout(plot_bounds, self.axes, self.options.gap, self.measurer()), .legend = slots };
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, id: u64, bounds: view.Rect) anyerror!void {
        const self: *Chart = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        const text_color = self.options.label_color orelse theme.palette.text;
        const arranged = self.arrange(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height });
        const plot = arranged.plot;
        const a = plot.area;
        self.area = a;
        self.bounds = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height };
        self.scale = frame.size.scale;
        if (a.width > 0 and a.height > 0) {
            const grid = ui.Color.rgb(self.options.grid_color orelse theme.palette.border);
            const zoom = self.zoom;
            if (self.options.grid.horizontal) for (if (self.axes.left.len > 0) self.axes.left else self.axes.right) |tick| {
                const at = zoom.shownY(tick.at);
                if (!inside(at)) continue;
                frame.roundedRect(rect(chart.ruleY(a, at, 1)), 0, grid);
            };
            if (self.options.grid.vertical) for (if (self.axes.bottom.len > 0) self.axes.bottom else self.axes.top) |tick| {
                const at = zoom.shownX(tick.at);
                if (!inside(at)) continue;
                frame.roundedRect(rect(chart.ruleX(a, at, 1)), 0, grid);
            };
            // Marks are placed in the whole plot's box for what shows, and
            // clipped to the area.
            const whole = zoom.place(a);
            try frame.pushClip(rect(a));
            defer frame.popClip() catch {};
            var slot_index: usize = 0;
            for (self.marks()) |mark| switch (mark) {
                .bar => |m| frame.roundedRect(rect(chart.rect(whole, m.x, m.y)), m.radius, m.color),
                .point => |m| frame.roundedRect(rect(chart.point(whole, m.x, m.y, m.size, m.size)), m.size / 2, m.color),
                .rule_x => |m| frame.roundedRect(rect(chart.ruleX(whole, m.x, m.width)), 0, m.color),
                .rule_y => |m| frame.roundedRect(rect(chart.ruleY(whole, m.y, m.width)), 0, m.color),
                .label => |m| {
                    const size = measureText(self, m.text);
                    frame.label(rect(chart.anchor(whole, m.x, m.y, m.h, m.v, size)), m.text, m.color orelse text_color);
                },
                .line, .area, .sector => {
                    const slot = &self.buffers.slots[slot_index];
                    slot_index += 1;
                    slot.wanted = key(mark, a.width, a.height, frame.size.scale, zoomOf(mark, zoom));
                    const color = switch (mark) {
                        .line => |m| m.color,
                        .area => |m| m.color,
                        .sector => |m| m.color,
                        else => unreachable,
                    };
                    // Until the posted preparation lands, a mask prepared for
                    // another size or scale is not painted.
                    const prepared = slot.prepared orelse continue;
                    if (slot.width != a.width or slot.height != a.height or slot.scale != frame.size.scale or !std.meta.eql(slot.zoom, zoomOf(mark, zoom))) continue;
                    try frame.coverage(.{ .x = a.x, .y = a.y }, try prepared.view(), color);
                },
            };
            if (self.brushShown()) |box| {
                var fill = ui.Color.rgb(theme.palette.accent);
                fill.a = 0x30;
                frame.roundedRect(rect(box), 0, fill);
                fill.a = 0xa0;
                frame.strokeRect(rect(box), 0, 1, fill);
            }
        }
        for (std.meta.tags(chart.Side)) |side| for (self.axes.get(side)) |*tick| {
            var shown = tick.*;
            shown.at = switch (side) {
                .left, .right => self.zoom.shownY(tick.at),
                .top, .bottom => self.zoom.shownX(tick.at),
            };
            const size = measureText(self, tick.label());
            const box = plot.label(side, shown, size, self.options.gap) orelse continue;
            frame.label(rect(box), tick.label(), text_color);
        };
        for (arranged.legend, self.legend_items) |slot, item| {
            frame.roundedRect(rect(slot.swatch), 2, ui.Color.rgb(item.color));
            frame.label(rect(slot.label), item.label, text_color);
        }
        const value = if (self.value.len > 0) self.value else self.selected();
        const focused = self.points.len > 0 and frame.context.input_state.focused == id;
        if (focused and a.width > 0 and a.height > 0) frame.strokeRect(rect(.{ .x = a.x - 2, .y = a.y - 2, .width = a.width + 4, .height = a.height + 4 }), 3, 2, ui.Color.rgb(theme.palette.focus));
        try frame.semantic(.{ .id = id, .role = .image, .name = self.options.name, .value = value, .bounds = bounds, .focused = focused });
    }

    /// The box the brush covers in what shows, while it is dragged or once
    /// it is finished, clipped to the plot's area.
    fn brushShown(self: *const Chart) ?chart.Rect {
        const a = self.area;
        const directions = self.options.interaction.brush orelse return null;
        var x: chart.Span = undefined;
        var y: chart.Span = undefined;
        if (self.press == .brush and self.dragged) {
            x = .{ .lo = @min(self.press_from.x, self.press_to.x), .hi = @max(self.press_from.x, self.press_to.x) };
            y = .{ .lo = @min(self.press_from.y, self.press_to.y), .hi = @max(self.press_from.y, self.press_to.y) };
        } else if (self.brush) |b| {
            const shown = self.zoom;
            x = .{ .lo = shown.shownX(b.x.lo), .hi = shown.shownX(b.x.hi) };
            y = .{ .lo = shown.shownY(b.y.lo), .hi = shown.shownY(b.y.hi) };
        } else return null;
        if (directions == .y) x = .{ .lo = 0, .hi = 1 };
        if (directions == .x) y = .{ .lo = 0, .hi = 1 };
        x = .{ .lo = std.math.clamp(x.lo, 0, 1), .hi = std.math.clamp(x.hi, 0, 1) };
        y = .{ .lo = std.math.clamp(y.lo, 0, 1), .hi = std.math.clamp(y.hi, 0, 1) };
        if (!(x.hi > x.lo) or !(y.hi > y.lo)) return null;
        return chart.rect(a, x, y);
    }

    fn place(ptr: *anyopaque, _: u64, _: view.Rect) void {
        const self: *Chart = @ptrCast(@alignCast(ptr));
        if (self.queued or !self.stale()) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.queued = true;
    }

    fn stale(self: *const Chart) bool {
        for (self.buffers.slots[0..self.path_len]) |slot| if (slot.key != slot.wanted) return true;
        for (self.buffers.slots[self.path_len..]) |slot| if (slot.prepared != null) return true;
        return false;
    }

    /// Posted after paint: prepare the masks the last paint wanted, release
    /// unused ones, repaint.
    fn run(ptr: *anyopaque) void {
        const self: *Chart = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const window = self.host.context.window orelse return;
        self.prepareAll();
        window.invalidate();
    }

    /// Prepare every stale mask now; call outside paint. The posted task
    /// does this on its own after a paint that found stale masks.
    pub fn prepareAll(self: *Chart) void {
        for (self.buffers.slots[self.path_len..]) |*slot| self.release(slot);
        const a = self.area;
        var slot_index: usize = 0;
        for (self.marks()) |mark| {
            if (!mark.prepared()) continue;
            const slot = &self.buffers.slots[slot_index];
            slot_index += 1;
            // Data may have changed since paint; prepare for what it is now.
            const zoom = zoomOf(mark, self.zoom);
            const wanted = key(mark, a.width, a.height, self.scale, zoom);
            if (slot.prepared != null and slot.key == wanted) continue;
            self.release(slot);
            // A failed or empty preparation is not retried until the mark,
            // the size or the scale changes.
            slot.key = wanted;
            slot.wanted = wanted;
            if (!(a.width >= 1 and a.height >= 1)) continue;
            self.prepareSlot(slot, mark, wanted, zoom) catch |err| {
                self.last_error = self.last_error orelse err;
            };
        }
    }

    fn prepareSlot(self: *Chart, slot: *Slot, mark: Mark, wanted: u64, zoom: chart.Zoom) !void {
        const a = self.area;
        const prepared = try self.prepareMark(mark, a.width, a.height, zoom) orelse return;
        errdefer prepared.close() catch {};
        try self.host.context.uploadCoverage(try prepared.view());
        slot.* = .{ .prepared = prepared, .key = wanted, .wanted = wanted, .width = a.width, .height = a.height, .scale = self.scale, .zoom = zoom };
    }

    fn prepareMark(self: *Chart, mark: Mark, width: f32, height: f32, zoom: chart.Zoom) !?*vector.Prepared {
        const local = zoom.place(.{ .width = width, .height = height });
        if (self.commands.capacity < 64) try self.commands.ensureTotalCapacity(self.allocator, 64);
        while (true) {
            self.commands.expandToCapacity();
            var path = chart.Path.init(self.commands.items);
            const built = switch (mark) {
                .line => |m| chart.line(&path, local, m.xs, m.ys, m.curve),
                .area => |m| chart.area(&path, local, m.xs, m.lo, m.hi, m.curve),
                .sector => |m| blk: {
                    const radius = @min(width, height) / 2;
                    break :blk chart.sector(&path, .{ .x = width / 2, .y = height / 2 }, m.inner * radius, m.outer * radius, m.slice);
                },
                else => unreachable,
            };
            built catch |err| switch (err) {
                error.PathFull => {
                    try self.commands.ensureTotalCapacity(self.allocator, self.commands.capacity * 2);
                    continue;
                },
            };
            self.commands.items.len = path.len;
            break;
        }
        const items = self.commands.items;
        if (items.len == 0) return null;
        self.outline.clearRetainingCapacity();
        try self.outline.ensureTotalCapacity(self.allocator, items.len);
        for (items) |command| self.outline.appendAssumeCapacity(switch (command) {
            .move => |p| .{ .move = point(p) },
            .line => |p| .{ .line = point(p) },
            .cubic => |c| .{ .cubic = .{ .first = point(c.c1), .second = point(c.c2), .end = point(c.to) } },
            .close => .close,
        });
        const count = self.outline.items.len;
        const source = try vector.Path.create(self.allocator, self.outline.items, .{ .commands = @min(65536, count), .bytes = @min(16 * 1024 * 1024, count * @sizeOf(vector.Command) + 4096) });
        defer source.close() catch {};
        const stroke_width: f32 = switch (mark) {
            .line => |m| m.width,
            else => 0,
        };
        // Strokes and antialiasing may spill past the area's edges.
        const margin = stroke_width + 2;
        return try source.prepare(self.allocator, .{
            .main_thread = std.Thread.getCurrentId(),
            .viewport = .{ .x = -margin, .y = -margin, .width = width + 2 * margin, .height = height + 2 * margin },
            .scale = self.scale,
            .style = if (mark == .line) .{ .stroke = .{ .width = stroke_width, .cap = .round, .join = .round } } else .{ .fill = .nonzero },
        });
    }
};

/// The zoom a mark is placed for: pie slices stay whole, centered.
fn zoomOf(mark: Mark, zoom: chart.Zoom) chart.Zoom {
    return if (mark == .sector) .{} else zoom;
}

/// A fraction of what shows that lies within it, allowing for rounding.
fn inside(at: f32) bool {
    const eps = 1e-4;
    return at >= -eps and at <= 1 + eps;
}

fn point(p: chart.Point) vector.Point {
    return .{ .x = p.x, .y = p.y };
}

fn rect(r: chart.Rect) view.Rect {
    return .{ .x = r.x, .y = r.y, .width = @max(0, r.width), .height = @max(0, r.height) };
}

/// Identifies what a mask is prepared from: its geometry, data, the plot's
/// size, the scale and the zoom, but not its color.
pub fn key(mark: Mark, width: f32, height: f32, scale: f32, zoom: chart.Zoom) u64 {
    var h = std.hash.Wyhash.init(0x6368_6172_74);
    h.update(std.mem.asBytes(&width));
    h.update(std.mem.asBytes(&height));
    h.update(std.mem.asBytes(&scale));
    h.update(std.mem.asBytes(&zoom));
    h.update(&.{@backingInt(std.meta.activeTag(mark))});
    switch (mark) {
        .line => |m| {
            h.update(std.mem.sliceAsBytes(m.xs));
            h.update(std.mem.sliceAsBytes(m.ys));
            h.update(&.{@backingInt(m.curve)});
            h.update(std.mem.asBytes(&m.width));
        },
        .area => |m| {
            h.update(std.mem.sliceAsBytes(m.xs));
            h.update(std.mem.sliceAsBytes(m.hi));
            if (m.lo) |lo| h.update(std.mem.sliceAsBytes(lo)) else h.update("bottom");
            h.update(&.{@backingInt(m.curve)});
        },
        .sector => |m| {
            h.update(std.mem.asBytes(&m.slice));
            h.update(std.mem.asBytes(&m.inner));
            h.update(std.mem.asBytes(&m.outer));
        },
        else => {},
    }
    // 0 marks a slot that was never prepared.
    return h.final() | 1;
}

test "keys follow data, size, scale and zoom but not color" {
    const xs = [_]f32{ 0, 0.5, 1 };
    var ys = [_]f32{ 0, 1, 0 };
    const red = Color.rgb(0xff0000);
    const first = key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 1, .{});
    try std.testing.expectEqual(first, key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = Color.rgb(0x00ff00) } }, 100, 50, 1, .{}));
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 51, 1, .{}));
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 2, .{}));
    try std.testing.expect(first != key(.{ .area = .{ .xs = &xs, .hi = &ys, .color = red } }, 100, 50, 1, .{}));
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 1, .{ .x = .{ .lo = 0, .hi = 0.5 } }));
    ys[1] = 0.5;
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 1, .{}));
}

test "the legend takes room above or below the plot" {
    var storage: Storage(4, 2, 4) = .{};
    var c = Chart.init(undefined, std.testing.allocator, storage.buffers(), .{ .legend_options = .{ .swatch = 10 } });
    const labels = [_][]const u8{ "a", "b" };
    var ticks: [2]chart.Tick = undefined;
    c.begin(.{ .bottom = try chart.Band.init(&labels).ticks(&ticks) });
    try c.setLegend(&.{ .{ .label = "Sales", .color = 0x336699 }, .{ .label = "Costs", .color = 0x993366 } });
    const bounds: chart.Rect = .{ .x = 0, .y = 0, .width = 400, .height = 200 };
    const top = c.arrange(bounds);
    // The default measurer's lines are 24 high.
    try std.testing.expectEqual(@as(f32, 24 + 8), top.plot.area.y);
    try std.testing.expectEqual(@as(f32, 200 - 32 - 24 - 6), top.plot.area.height);
    try std.testing.expectEqual(@as(f32, 0), top.legend[0].label.y);
    c.options.legend = .bottom;
    const bottom = c.arrange(bounds);
    try std.testing.expectEqual(@as(f32, 0), bottom.plot.area.y);
    try std.testing.expectEqual(@as(f32, 200 - 24), bottom.legend[1].label.y);
    c.options.legend = .none;
    try std.testing.expectEqual(@as(usize, 0), c.arrange(bounds).legend.len);
    try std.testing.expectError(error.TooManyLegendItems, c.setLegend(&@as([5]chart.LegendItem, @splat(.{ .label = "x", .color = 0 }))));
}

test "marks and paths are bounded by the storage" {
    var storage: Storage(3, 1, 1) = .{};
    var c = Chart.init(undefined, std.testing.allocator, storage.buffers(), .{});
    c.begin(.{});
    const xs = [_]f32{ 0, 1 };
    const red = Color.rgb(0xff0000);
    try c.add(.{ .line = .{ .xs = &xs, .ys = &xs, .color = red } });
    try std.testing.expectError(error.TooManyPaths, c.add(.{ .area = .{ .xs = &xs, .hi = &xs, .color = red } }));
    try c.add(.{ .bar = .{ .x = .{ .lo = 0, .hi = 0.5 }, .y = .{ .lo = 0, .hi = 1 }, .color = red } });
    try c.add(.{ .point = .{ .x = 0.5, .y = 0.5, .color = red } });
    try std.testing.expectError(error.TooManyMarks, c.add(.{ .rule_y = .{ .y = 0.5, .color = red } }));
    try std.testing.expectEqual(@as(usize, 3), c.marks().len);
}

fn describePoint(_: ?*const anyopaque, index: usize, buffer: []u8) []const u8 {
    const names = [_][]const u8{ "one", "two", "three" };
    const text = names[index];
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

test "the pointer and the keys choose a point and announce it" {
    const Empty = struct {
        fn build(_: *u8, _: *view.View) anyerror!void {}
    };
    var state: u8 = 0;
    var view_storage: view.Storage(4, 64) = .{};
    var host = view.Host.init(&state, Empty.build, view_storage.buffers(), .{});
    var storage: Storage(1, 1, 1) = .{};
    var c = Chart.init(&host, std.testing.allocator, storage.buffers(), .{});
    c.begin(.{});
    try std.testing.expect(c.embed().input == null and !c.embed().focusable);
    const xs = [_]f32{ 0.1, 0.5, 0.9 };
    c.select(&xs, .{ .call = describePoint });
    try std.testing.expect(c.embed().input != null and c.embed().focusable);
    c.bounds = .{ .x = 10, .y = 10, .width = 220, .height = 120 };
    c.area = .{ .x = 30, .y = 10, .width = 200, .height = 100 };
    const embedded = c.embed();
    const send = struct {
        fn call(e: view.Embed, event: view.EmbedInput) bool {
            return e.input.?(e.context, 1, event);
        }
    }.call;
    // Local x 115 is window x 125, 0.475 along the area: the middle point.
    try std.testing.expect(send(embedded, .{ .pointer_move = .{ .x = 115, .y = 50 } }));
    try std.testing.expectEqual(@as(?usize, 1), c.selection.index);
    try std.testing.expectEqualStrings("two", c.selected());
    // Over the axis labels, left of the area, the pointer has left the plot.
    try std.testing.expect(send(embedded, .{ .pointer_move = .{ .x = 5, .y = 50 } }));
    try std.testing.expectEqual(@as(?usize, null), c.selection.index);
    try std.testing.expect(send(embedded, .{ .pointer_down = .{ .position = .{ .x = 100, .y = 50 } } }));
    try std.testing.expect(!send(embedded, .{ .pointer_down = .{ .position = .{ .x = 5, .y = 50 } } }));
    try std.testing.expect(send(embedded, .{ .pointer_move = .{ .x = 210, .y = 50 } }));
    try std.testing.expect(send(embedded, .pointer_leave));
    try std.testing.expectEqual(@as(?usize, null), c.selection.index);

    const serial = host.view.announcement_serial;
    try std.testing.expect(send(embedded, .{ .key = .{ .key = .right } }));
    try std.testing.expectEqual(@as(?usize, 0), c.selection.index);
    try std.testing.expectEqual(serial + 1, host.view.announcement_serial);
    try std.testing.expectEqualStrings("one", host.view.announcement[0..host.view.announcement_len]);
    try std.testing.expect(send(embedded, .{ .key = .{ .key = .end } }));
    try std.testing.expectEqualStrings("three", host.view.announcement[0..host.view.announcement_len]);
    // Staying at the last point announces nothing new.
    try std.testing.expect(send(embedded, .{ .key = .{ .key = .right } }));
    try std.testing.expectEqual(serial + 2, host.view.announcement_serial);
    try std.testing.expect(!send(embedded, .{ .key = .{ .key = .right, .modifiers = .{ .shift = true } } }));
    try std.testing.expect(!send(embedded, .{ .key = .{ .key = .a } }));
    try std.testing.expect(send(embedded, .{ .key = .{ .key = .escape } }));
    try std.testing.expectEqual(@as(?usize, null), c.selection.index);
    // With nothing chosen, Escape is left for others.
    try std.testing.expect(!send(embedded, .{ .key = .{ .key = .escape } }));
    // Fewer points drop a choice past them.
    c.selection.index = 2;
    c.select(xs[0..2], null);
    try std.testing.expectEqual(@as(?usize, null), c.selection.index);
    try std.testing.expectEqualStrings("", c.selected());
}

test "drags brush or pan the plot, the wheel zooms and a double press shows it whole" {
    const Plot = struct {
        chart: *Chart = undefined,
        fn build(self: *@This(), v: *view.View) anyerror!void {
            self.chart.begin(.{});
            try v.embed(self.chart.embed(), .{ .key = 1, .width = 220, .height = 120 });
        }
    };
    var state: Plot = .{};
    var view_storage: view.Storage(8, 64) = .{};
    var host = view.Host.init(&state, Plot.build, view_storage.buffers(), .{});
    var storage: Storage(1, 1, 1) = .{};
    var c = Chart.init(&host, std.testing.allocator, storage.buffers(), .{ .interaction = .{ .brush = .x, .zoom = .x } });
    state.chart = &c;
    var harness_storage: view.Storage(8, 64) = .{};
    var h = view.Harness.init(&state, Plot.build, harness_storage.buffers(), .{});
    try h.render();
    const leaf = (try h.find(.{ .key = 1 })).bounds;
    c.bounds = .{ .x = leaf.x, .y = leaf.y, .width = leaf.width, .height = leaf.height };
    // The plot's area, as a paint would lay it out without axes.
    c.area = .{ .x = leaf.x + 10, .y = leaf.y + 10, .width = 200, .height = 100 };
    const a = c.area;
    const mid = a.y + 50;

    // A drag across the plot brushes along x, in fractions of the plot.
    try h.drag(a.x + 40, mid, a.x + 120, mid + 30, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), c.brush.?.x.lo, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), c.brush.?.x.hi, 1e-5);
    try std.testing.expectEqual(chart.Span{ .lo = 0, .hi = 1 }, c.brush.?.y);
    try std.testing.expect(c.zoom.whole());
    // A press without a drag clears it.
    try h.press(a.x + 40, mid, .{});
    try h.release(a.x + 40, mid);
    try std.testing.expect(c.brush == null);

    // A wheel notch up zooms in around the pointer.
    try h.wheel(a.x + 50, mid, .{ .x = 0, .y = -48 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), c.zoom.x.hi - c.zoom.x.lo, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), c.zoom.shownX(0.25), 1e-5);
    // A drag with Shift pans: what shows follows the pointer.
    const before = c.zoom.x.lo;
    try h.press(a.x + 100, mid, .{ .shift = true });
    try h.moveTo(a.x + 80, mid);
    try h.release(a.x + 80, mid);
    try std.testing.expectApproxEqAbs(before + 0.1 * 0.8, c.zoom.x.lo, 1e-5);
    try std.testing.expect(c.brush == null);
    // A brush in a zoomed plot is kept in fractions of the whole plot.
    try h.drag(a.x, mid, a.x + 100, mid, 2);
    try std.testing.expectApproxEqAbs(c.zoom.x.lo, c.brush.?.x.lo, 1e-5);
    try std.testing.expectApproxEqAbs(c.zoom.wholeX(0.5), c.brush.?.x.hi, 1e-5);

    // A double press shows the whole plot again and drops the brush.
    try h.press(a.x + 40, mid, .{});
    try h.release(a.x + 40, mid);
    try h.press(a.x + 40, mid, .{});
    try h.release(a.x + 40, mid);
    try std.testing.expect(c.zoom.whole());
    try std.testing.expect(c.brush == null);

    // A brush that zooms selects what it covers.
    c.options.interaction.brush_zooms = true;
    try h.advance(view.double_press_time + 1);
    try h.drag(a.x + 50, mid, a.x + 150, mid, 2);
    try std.testing.expect(c.brush == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), c.zoom.x.lo, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), c.zoom.x.hi, 1e-5);
    // Escape gives up a brush being dragged.
    var context = ui.Context.init(&state, struct {
        fn draw(_: *anyopaque, _: *ui.Frame) void {}
    }.draw, struct {
        fn action(_: *anyopaque, _: u64) void {}
    }.action);
    try h.attachInput(&context);
    try h.press(a.x + 20, mid, .{});
    try h.moveTo(a.x + 60, mid);
    try std.testing.expect(try h.key(.{ .key = .escape }));
    try h.release(a.x + 60, mid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), c.zoom.x.lo, 1e-5);

    // The keys zoom while the chart has focus, and 0 shows it whole.
    try std.testing.expectEqual(c.embed().focusable, true);
    try h.focus(.{ .key = 1 });
    try std.testing.expect(try h.key(.{ .key = .minus }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), c.zoom.x.hi - c.zoom.x.lo, 1e-5);
    try std.testing.expect(try h.key(.{ .key = .equal, .modifiers = .{ .shift = true } }));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.zoom.x.hi - c.zoom.x.lo, 1e-5);
    try std.testing.expect(try h.key(.{ .key = .digit0 }));
    try std.testing.expect(c.zoom.whole());
}
