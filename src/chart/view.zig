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
        slots: [paths]Slot = [_]Slot{.{}} ** paths,
        legend: [legend_items]chart.LegendSlot = undefined,
        pub fn buffers(self: *Self) Buffers {
            return .{ .marks = &self.marks, .slots = &self.slots, .legend = &self.legend };
        }
    };
}

pub const Error = error{ TooManyMarks, TooManyPaths, TooManyLegendItems };

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
        return .{ .context = self, .measure = measure, .place = place, .paint = paint };
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
        self.scale = frame.size.scale;
        if (a.width > 0 and a.height > 0) {
            const grid = ui.Color.rgb(self.options.grid_color orelse theme.palette.border);
            if (self.options.grid.horizontal) for (if (self.axes.left.len > 0) self.axes.left else self.axes.right) |tick| {
                if (tick.at < 0 or tick.at > 1) continue;
                frame.roundedRect(rect(chart.ruleY(a, tick.at, 1)), 0, grid);
            };
            if (self.options.grid.vertical) for (if (self.axes.bottom.len > 0) self.axes.bottom else self.axes.top) |tick| {
                if (tick.at < 0 or tick.at > 1) continue;
                frame.roundedRect(rect(chart.ruleX(a, tick.at, 1)), 0, grid);
            };
            var slot_index: usize = 0;
            for (self.marks()) |mark| switch (mark) {
                .bar => |m| frame.roundedRect(rect(chart.rect(a, m.x, m.y)), m.radius, m.color),
                .point => |m| frame.roundedRect(rect(chart.point(a, m.x, m.y, m.size, m.size)), m.size / 2, m.color),
                .rule_x => |m| frame.roundedRect(rect(chart.ruleX(a, m.x, m.width)), 0, m.color),
                .rule_y => |m| frame.roundedRect(rect(chart.ruleY(a, m.y, m.width)), 0, m.color),
                .label => |m| {
                    const size = measureText(self, m.text);
                    frame.label(rect(chart.anchor(a, m.x, m.y, m.h, m.v, size)), m.text, m.color orelse text_color);
                },
                .line, .area, .sector => {
                    const slot = &self.buffers.slots[slot_index];
                    slot_index += 1;
                    slot.wanted = key(mark, a.width, a.height, frame.size.scale);
                    const color = switch (mark) {
                        .line => |m| m.color,
                        .area => |m| m.color,
                        .sector => |m| m.color,
                        else => unreachable,
                    };
                    // Until the posted preparation lands, a mask prepared for
                    // another size or scale is not painted.
                    const prepared = slot.prepared orelse continue;
                    if (slot.width != a.width or slot.height != a.height or slot.scale != frame.size.scale) continue;
                    try frame.coverage(.{ .x = a.x, .y = a.y }, try prepared.view(), color);
                },
            };
        }
        for (std.meta.tags(chart.Side)) |side| for (self.axes.get(side)) |*tick| {
            const size = measureText(self, tick.label());
            const box = plot.label(side, tick.*, size, self.options.gap) orelse continue;
            frame.label(rect(box), tick.label(), text_color);
        };
        for (arranged.legend, self.legend_items) |slot, item| {
            frame.roundedRect(rect(slot.swatch), 2, ui.Color.rgb(item.color));
            frame.label(rect(slot.label), item.label, text_color);
        }
        try frame.semantic(.{ .id = id, .role = .image, .name = self.options.name, .value = self.value, .bounds = bounds });
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
            const wanted = key(mark, a.width, a.height, self.scale);
            if (slot.prepared != null and slot.key == wanted) continue;
            self.release(slot);
            // A failed or empty preparation is not retried until the mark,
            // the size or the scale changes.
            slot.key = wanted;
            slot.wanted = wanted;
            if (!(a.width >= 1 and a.height >= 1)) continue;
            self.prepareSlot(slot, mark, wanted) catch |err| {
                self.last_error = self.last_error orelse err;
            };
        }
    }

    fn prepareSlot(self: *Chart, slot: *Slot, mark: Mark, wanted: u64) !void {
        const a = self.area;
        const prepared = try self.prepareMark(mark, a.width, a.height) orelse return;
        errdefer prepared.close() catch {};
        try self.host.context.uploadCoverage(try prepared.view());
        slot.* = .{ .prepared = prepared, .key = wanted, .wanted = wanted, .width = a.width, .height = a.height, .scale = self.scale };
    }

    fn prepareMark(self: *Chart, mark: Mark, width: f32, height: f32) !?*vector.Prepared {
        const local: chart.Rect = .{ .width = width, .height = height };
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

fn point(p: chart.Point) vector.Point {
    return .{ .x = p.x, .y = p.y };
}

fn rect(r: chart.Rect) view.Rect {
    return .{ .x = r.x, .y = r.y, .width = @max(0, r.width), .height = @max(0, r.height) };
}

/// Identifies what a mask is prepared from: its geometry, data, the plot's
/// size and the scale, but not its color.
pub fn key(mark: Mark, width: f32, height: f32, scale: f32) u64 {
    var h = std.hash.Wyhash.init(0x6368_6172_74);
    h.update(std.mem.asBytes(&width));
    h.update(std.mem.asBytes(&height));
    h.update(std.mem.asBytes(&scale));
    h.update(&.{@intFromEnum(std.meta.activeTag(mark))});
    switch (mark) {
        .line => |m| {
            h.update(std.mem.sliceAsBytes(m.xs));
            h.update(std.mem.sliceAsBytes(m.ys));
            h.update(&.{@intFromEnum(m.curve)});
            h.update(std.mem.asBytes(&m.width));
        },
        .area => |m| {
            h.update(std.mem.sliceAsBytes(m.xs));
            h.update(std.mem.sliceAsBytes(m.hi));
            if (m.lo) |lo| h.update(std.mem.sliceAsBytes(lo)) else h.update("bottom");
            h.update(&.{@intFromEnum(m.curve)});
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

test "keys follow data, size and scale but not color" {
    const xs = [_]f32{ 0, 0.5, 1 };
    var ys = [_]f32{ 0, 1, 0 };
    const red = Color.rgb(0xff0000);
    const first = key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 1);
    try std.testing.expectEqual(first, key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = Color.rgb(0x00ff00) } }, 100, 50, 1));
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 51, 1));
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 2));
    try std.testing.expect(first != key(.{ .area = .{ .xs = &xs, .hi = &ys, .color = red } }, 100, 50, 1));
    ys[1] = 0.5;
    try std.testing.expect(first != key(.{ .line = .{ .xs = &xs, .ys = &ys, .color = red } }, 100, 50, 1));
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
    try std.testing.expectError(error.TooManyLegendItems, c.setLegend(&[_]chart.LegendItem{.{ .label = "x", .color = 0 }} ** 5));
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
