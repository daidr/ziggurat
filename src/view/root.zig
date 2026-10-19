//! Declarative views over the immediate UI recorder. A build function
//! describes the whole tree from application state; Host measures it with
//! flex layout and records the resulting frame. Widgets bind directly to
//! application values and report activation as ordinary return values.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");

pub const layout = ui.layout;
pub const Rect = ui.Rect;
pub const Size = layout.Size;
pub const Insets = layout.Insets;
pub const Axis = layout.Axis;
pub const Align = layout.Align;
pub const Justify = layout.Justify;
pub const Range = ui.Range;
pub const ValueChange = ui.ValueChange;
pub const Theme = ui.Theme;
pub const Point = layout.Point;
pub const ScrollModel = ui.scroll.ScrollModel;
pub const Track = ui.grid.Track;
pub const MeterBands = ui.widgets.MeterBands;

pub const Error = error{ TooManyNodes, TextFull, NestingTooDeep, UnbalancedContainer, NotContainer, Busy, InvalidRange, InvalidValue, InvalidText, InvalidSplit } || layout.Error;

pub const max_depth = 32;
/// Scroll containers Host can route wheel input to in one frame.
pub const max_scroll_regions = 16;
/// Thickness of a split's draggable divider, in DIP.
pub const split_divider: f32 = 6;
const none = std.math.maxInt(u32);
const root_seed: u64 = 0x5a1f_7c3d_9b2e_4a61;

/// Appearance and participation of one node. Container fields are ignored on
/// leaves; leaf sizes come from their content and the active theme metrics.
pub const Style = struct {
    /// Stable identity for a node whose position among its siblings changes.
    key: ?u64 = null,
    /// Child spacing and placement for containers; a grid uses `gap` between
    /// both rows and columns.
    gap: f32 = 0,
    padding: Insets = .{},
    alignment: Align = .stretch,
    justify: Justify = .start,
    clip: bool = false,
    /// Participation in the parent's flex line.
    grow: f32 = 0,
    shrink: f32 = 1,
    self_align: ?Align = null,
    /// Columns a grid child spans, counted from its automatic position.
    column_span: u8 = 1,
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    max_height: f32 = std.math.inf(f32),
    /// Decoration painted behind a container's children.
    background: ?u32 = null,
    border: ?u32 = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    /// Text color for text nodes; widgets use the theme palette.
    color: ?u32 = null,
    enabled: bool = true,
    /// Accessible name for a progress indicator, which has no visible label.
    name: []const u8 = "",
};

/// Derive a stable key from text, for example a list item's identifier.
pub fn key(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6b65_79, text);
}

/// Single-line text extent in DIP for the fixed label font. The default is a
/// conservative estimate; applications may supply exact text layout.
pub const Measurer = struct {
    context: ?*anyopaque = null,
    measure: *const fn (?*anyopaque, []const u8) Size = estimate,

    pub const line_height: f32 = 24;
    pub fn estimate(_: ?*anyopaque, text: []const u8) Size {
        var width: f32 = 0;
        var view = std.unicode.Utf8View.init(text) catch return .{ .width = @as(f32, @floatFromInt(text.len)) * 9, .height = line_height };
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| width += if (codepoint >= 0x1100) 16 else 9;
        return .{ .width = width, .height = line_height };
    }
};

pub const Kind = enum { column, row, radio_group, segmented, tab_list, toolbar, breadcrumbs, accordion, split, scroll, grid, text, badge, spacer, button, link, checkbox, radio, segment, tab, disclosure, toggle_switch, progress, meter, slider, stepper, rating, embed };

/// A leaf that measures, places and paints itself, for content the view
/// layer does not model, such as an editable text field. The context must
/// stay valid while any pass that emits it runs.
pub const Embed = struct {
    context: *anyopaque,
    /// Content size for the current theme; called during arrange.
    measure: *const fn (*anyopaque, Theme) layout.Measurement,
    /// Final window bounds and stable node id after each arranged frame. It
    /// runs inside paint, so it must not prepare, allocate or block; defer
    /// such work to the input phase.
    place: ?*const fn (*anyopaque, u64, Rect) void = null,
    paint: *const fn (*anyopaque, *ui.Frame, u64, Rect) anyerror!void,
};

pub const Node = struct {
    kind: Kind,
    id: u64,
    style: Style,
    text: []const u8 = "",
    checked: bool = false,
    fraction: f32 = 0,
    value: f64 = 0,
    range: Range = .{ .minimum = 0, .maximum = 1 },
    /// Preferred band of a meter.
    bands: MeterBands = .{},
    radio_group: ?u64 = null,
    /// Nearest enclosing toolbar, breadcrumb trail or accordion, the
    /// accessible parent of the controls inside it.
    semantic_parent: u64 = ui.accessibility.root_id,
    /// Direction a split lays out its two panes.
    axis: Axis = .column,
    /// Application-owned scroll state of a scroll container.
    scroll: ?*ScrollModel = null,
    /// Column tracks of a grid, borrowed until the pass is arranged.
    tracks: []const Track = &.{},
    embed: ?Embed = null,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next_sibling: u32 = none,
    child_count: u32 = 0,
    /// One past the last descendant, in build order.
    end: u32 = 0,
    measured: layout.Measurement = .{ .minimum = .{}, .preferred = .{} },
    /// Preferred size of a scroll container's content.
    content: Size = .{},
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn isContainer(self: *const Node) bool {
        return switch (self.kind) {
            .column, .row, .radio_group, .segmented, .tab_list, .toolbar, .breadcrumbs, .accordion, .split, .scroll, .grid => true,
            else => false,
        };
    }
    /// True when the node clips its descendants to its bounds.
    pub fn clips(self: *const Node) bool {
        return self.kind == .scroll or (self.style.clip and self.isContainer());
    }
};

/// Caller-owned fixed storage. Nothing in build, layout or paint allocates.
pub const Buffers = struct {
    nodes: []Node,
    text: []u8,
    items: []layout.Item,
    rects: []Rect,
};

/// Static storage for a bounded tree, kept at a stable address by its owner.
pub fn Storage(comptime node_capacity: usize, comptime text_capacity: usize) type {
    return struct {
        const Self = @This();
        nodes: [node_capacity]Node = undefined,
        text: [text_capacity]u8 = undefined,
        items: [node_capacity]layout.Item = undefined,
        rects: [node_capacity]Rect = undefined,
        pub fn buffers(self: *Self) Buffers {
            return .{ .nodes = &self.nodes, .text = &self.text, .items = &self.items, .rects = &self.rects };
        }
    };
}

pub const Event = union(enum) {
    action: u64,
    value: struct { id: u64, change: ValueChange },
    /// Wheel movement in DIP over a scroll container; positive y scrolls down.
    scroll: struct { id: u64, delta: Point },
};

/// The description of one tree. Build passes run either to deliver a single
/// input event to the widget that owns its id, or to produce a frame.
pub const View = struct {
    buffers: Buffers,
    len: u32 = 0,
    text_len: usize = 0,
    stack: [max_depth + 1]u32 = undefined,
    depth: usize = 0,
    event: ?Event = null,
    consumed: bool = false,

    pub fn init(buffers: Buffers) View {
        return .{ .buffers = buffers };
    }

    /// Start a pass with an implicit root column.
    pub fn reset(self: *View, root_style: Style, event: ?Event) void {
        self.len = 1;
        self.text_len = 0;
        self.depth = 1;
        self.stack[0] = 0;
        self.event = event;
        self.consumed = false;
        self.buffers.nodes[0] = .{ .kind = .column, .id = root_seed, .style = root_style, .end = 1 };
    }

    pub fn root(self: *const View) *const Node {
        return &self.buffers.nodes[0];
    }
    pub fn nodes(self: *const View) []const Node {
        return self.buffers.nodes[0..self.len];
    }

    /// The part of `node` left visible by its own bounds and every clipping
    /// ancestor after arrange, or null when none of it can be seen or hit.
    pub fn visible(self: *const View, node: *const Node) ?Rect {
        const all = self.nodes();
        var rect = node.bounds;
        var parent = node.parent;
        while (parent < all.len) : (parent = all[parent].parent) {
            const ancestor = &all[parent];
            if (ancestor.clips()) rect = intersect(rect, ancestor.bounds) orelse return null;
        }
        if (!(rect.width > 0 and rect.height > 0)) return null;
        return rect;
    }

    fn identity(self: *View, parent: *const Node, kind: Kind, style: Style) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(parent.id);
        if (style.key) |value| {
            hasher.update("k");
            hasher.update(std.mem.asBytes(&value));
        } else hasher.update(std.mem.asBytes(&parent.child_count));
        hasher.update(@tagName(kind));
        const id = hasher.final();
        // Zero is the semantic root and is never a control id.
        return if (id == 0) 1 else id;
    }

    fn append(self: *View, kind: Kind, style: Style) Error!*Node {
        if (self.depth == 0) return error.UnbalancedContainer;
        if (self.len >= self.buffers.nodes.len) return error.TooManyNodes;
        const parent_index = self.stack[self.depth - 1];
        const parent = &self.buffers.nodes[parent_index];
        if (parent.child_count >= layout.max_items) return error.TooManyItems;
        const index = self.len;
        self.buffers.nodes[index] = .{ .kind = kind, .id = self.identity(parent, kind, style), .style = style, .parent = parent_index, .end = index + 1, .semantic_parent = switch (parent.kind) {
            .toolbar, .breadcrumbs, .accordion => parent.id,
            else => parent.semantic_parent,
        } };
        if (parent.last_child == none) parent.first_child = index else self.buffers.nodes[parent.last_child].next_sibling = index;
        parent.last_child = index;
        parent.child_count += 1;
        self.len += 1;
        return &self.buffers.nodes[index];
    }

    fn copy(self: *View, value: []const u8) Error![]const u8 {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        if (self.buffers.text.len - self.text_len < value.len) return error.TextFull;
        const out = self.buffers.text[self.text_len..][0..value.len];
        @memcpy(out, value);
        self.text_len += value.len;
        return out;
    }

    fn take(self: *View, id: u64) ?Event {
        const event = self.event orelse return null;
        const target = switch (event) {
            .action => |value| value,
            .value => |value| value.id,
            .scroll => |value| value.id,
        };
        if (target != id) return null;
        self.event = null;
        self.consumed = true;
        return event;
    }

    pub fn begin(self: *View, axis: Axis, style: Style) Error!void {
        _ = try self.open(if (axis == .column) .column else .row, style);
    }
    fn open(self: *View, kind: Kind, style: Style) Error!*Node {
        if (self.depth > max_depth) return error.NestingTooDeep;
        const node = try self.append(kind, style);
        self.stack[self.depth] = @intCast(node - self.buffers.nodes.ptr);
        self.depth += 1;
        return node;
    }
    pub fn column(self: *View, style: Style) Error!void {
        return self.begin(.column, style);
    }
    pub fn row(self: *View, style: Style) Error!void {
        return self.begin(.row, style);
    }
    pub fn end(self: *View) Error!void {
        if (self.depth <= 1) return error.UnbalancedContainer;
        self.depth -= 1;
        const index = self.stack[self.depth];
        const node = &self.buffers.nodes[index];
        if (node.kind == .split and node.child_count != 2) return error.InvalidSplit;
        node.end = self.len;
    }

    pub fn text(self: *View, value: []const u8, style: Style) Error!void {
        const node = try self.append(.text, style);
        node.text = try self.copy(value);
    }
    /// Format directly into the view's text storage.
    pub fn textf(self: *View, comptime format: []const u8, args: anytype, style: Style) Error!void {
        const node = try self.append(.text, style);
        const out = std.fmt.bufPrint(self.buffers.text[self.text_len..], format, args) catch return error.TextFull;
        if (!std.unicode.utf8ValidateSlice(out)) return error.InvalidText;
        self.text_len += out.len;
        node.text = out;
    }
    /// Flexible empty space; grows by default.
    pub fn spacer(self: *View, style: Style) Error!void {
        var value = style;
        if (value.grow == 0 and value.width == null and value.height == null) value.grow = 1;
        _ = try self.append(.spacer, value);
    }

    /// True once for the pass that delivers this button's activation.
    pub fn button(self: *View, label: []const u8, style: Style) Error!bool {
        const node = try self.append(.button, style);
        node.text = try self.copy(label);
        return self.take(node.id) != null;
    }
    /// Underlined accent text; true once for the pass that delivers its
    /// activation. What it opens is up to the application.
    pub fn link(self: *View, label: []const u8, style: Style) Error!bool {
        const node = try self.append(.link, style);
        node.text = try self.copy(label);
        return self.take(node.id) != null;
    }
    /// A short status label on a rounded background (`Style.background`,
    /// accent by default). It is static text, not a control.
    pub fn badge(self: *View, value: []const u8, style: Style) Error!void {
        const node = try self.append(.badge, style);
        node.text = try self.copy(value);
    }
    /// A labelled expander bound to `expanded`, flipped on activation; true
    /// when it changed. Build the content after it while `expanded` is set.
    pub fn disclosure(self: *View, expanded: *bool, label: []const u8, style: Style) Error!bool {
        return self.toggle(.disclosure, expanded, label, style);
    }
    /// Toggles the bound value on activation; true when it changed.
    pub fn checkbox(self: *View, checked: *bool, label: []const u8, style: Style) Error!bool {
        return self.toggle(.checkbox, checked, label, style);
    }
    pub fn toggleSwitch(self: *View, checked: *bool, label: []const u8, style: Style) Error!bool {
        return self.toggle(.toggle_switch, checked, label, style);
    }
    fn toggle(self: *View, kind: Kind, checked: *bool, label: []const u8, style: Style) Error!bool {
        const node = try self.append(kind, style);
        node.text = try self.copy(label);
        const changed = self.take(node.id) != null;
        if (changed) checked.* = !checked.*;
        node.checked = checked.*;
        return changed;
    }
    /// Starts a column of mutually exclusive radios bound to one value. The
    /// group carries the accessible `name`; close it with `end`.
    pub fn radioGroup(self: *View, style: Style) Error!void {
        _ = try self.open(.radio_group, style);
    }
    /// Starts a vertically scrolling column that clips its children. The
    /// application owns `model`; wheel input over the container moves it and
    /// arrange clamps it to the content. Close it with `end`.
    pub fn scroll(self: *View, model: *ScrollModel, style: Style) Error!void {
        const node = try self.open(.scroll, style);
        node.scroll = model;
        if (self.take(node.id)) |event| if (event == .scroll) {
            _ = model.scrollBy(event.scroll.delta) catch return error.InvalidValue;
        };
    }
    /// Starts a grid with the given column tracks. Children fill cells row by
    /// row, each spanning `Style.column_span` columns; rows size to content.
    /// `columns` must stay valid until the pass is arranged. Close it with `end`.
    pub fn grid(self: *View, columns: []const Track, style: Style) Error!void {
        if (columns.len == 0 or columns.len > ui.grid.max_tracks) return error.InvalidValue;
        const node = try self.open(.grid, style);
        node.tracks = columns;
    }
    /// Selects `option` on activation; true when the selection changed.
    pub fn radio(self: *View, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        return self.choice(.radio, .radio_group, T, selected, option, label, style);
    }
    /// Starts a row of joined segments bound to one value, announced as a
    /// radio group named by `Style.name`. Close it with `end`.
    pub fn segmented(self: *View, style: Style) Error!void {
        _ = try self.open(.segmented, style);
    }
    /// Selects `option` on activation; true when the selection changed.
    pub fn segment(self: *View, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        return self.choice(.segment, .segmented, T, selected, option, label, style);
    }
    /// Starts a row of tabs bound to one value. The list carries the
    /// accessible `name`; the application builds the selected tab's content
    /// after it. Close it with `end`.
    pub fn tabs(self: *View, style: Style) Error!void {
        _ = try self.open(.tab_list, style);
    }
    /// Selects `option` on activation; true when the selection changed.
    pub fn tab(self: *View, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        return self.choice(.tab, .tab_list, T, selected, option, label, style);
    }
    /// Starts a row of tool controls under one accessible `name`. Controls
    /// inside it, however deeply nested, report the toolbar as their parent.
    /// Close it with `end`.
    pub fn toolbar(self: *View, style: Style) Error!void {
        _ = try self.open(.toolbar, style);
    }
    /// Starts a row of links leading to the current page, announced as a
    /// navigation region named by `Style.name`. A separator is drawn in the
    /// gap between items (16 DIP unless `Style.gap` is set); the current
    /// page is usually plain text at the end. Close it with `end`.
    pub fn breadcrumbs(self: *View, style: Style) Error!void {
        var value = style;
        if (value.gap == 0) value.gap = 16;
        _ = try self.open(.breadcrumbs, value);
    }
    /// Starts a column of sections of which at most one is open, grouped
    /// under `Style.name`. Build each section's content after its header
    /// while it is open. Close it with `end`.
    pub fn accordion(self: *View, style: Style) Error!void {
        _ = try self.open(.accordion, style);
    }
    /// An accordion header for `option`: activation opens it and closes the
    /// open one, or closes it when it is already open. True when `open`
    /// changed. Announced as an expander.
    pub fn section(self: *View, comptime T: type, open_section: *?T, option: T, label: []const u8, style: Style) Error!bool {
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.kind != .accordion) return error.NotContainer;
        const node = try self.append(.disclosure, style);
        node.text = try self.copy(label);
        const selected = if (open_section.*) |current| std.meta.eql(current, option) else false;
        const changed = self.take(node.id) != null;
        if (changed) open_section.* = if (selected) null else option;
        node.checked = if (open_section.*) |current| std.meta.eql(current, option) else false;
        return changed;
    }
    /// Starts two panes along `axis` separated by a draggable divider. The
    /// first pane takes `fraction` of the length, kept within `limits`, which
    /// must lie in 0..1; pointer drags, arrow keys and accessibility clients
    /// move it. Build exactly two children, then close it with `end`. True
    /// when the divider moved in this pass.
    pub fn split(self: *View, axis: Axis, fraction: *f64, limits: Range, style: Style) Error!bool {
        limits.validate() catch return error.InvalidRange;
        if (limits.minimum < 0 or limits.maximum > 1) return error.InvalidRange;
        const node = try self.open(.split, style);
        node.axis = axis;
        node.range = limits;
        var changed = false;
        if (self.take(node.id)) |event| if (event == .value) {
            const next = limits.apply(fraction.*, event.value.change) catch return error.InvalidValue;
            changed = next != fraction.*;
            fraction.* = next;
        };
        if (!std.math.isFinite(fraction.*)) return error.InvalidValue;
        fraction.* = std.math.clamp(fraction.*, limits.minimum, limits.maximum);
        node.value = fraction.*;
        return changed;
    }
    /// The divider strip between a split's arranged panes.
    pub fn divider(self: *const View, node: *const Node) ?Rect {
        if (node.kind != .split or node.first_child == none) return null;
        const first = self.buffers.nodes[node.first_child].bounds;
        return if (node.axis == .column)
            .{ .x = first.x, .y = first.y + first.height, .width = first.width, .height = split_divider }
        else
            .{ .x = first.x + first.width, .y = first.y, .width = split_divider, .height = first.height };
    }
    fn choice(self: *View, kind: Kind, container: Kind, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.kind != container) return error.NotContainer;
        const group = parent.id;
        const node = try self.append(kind, style);
        node.text = try self.copy(label);
        node.radio_group = group;
        var changed = false;
        if (self.take(node.id) != null and !std.meta.eql(selected.*, option)) {
            selected.* = option;
            changed = true;
        }
        node.checked = std.meta.eql(selected.*, option);
        return changed;
    }
    pub fn progress(self: *View, fraction: f32, style: Style) Error!void {
        if (!std.math.isFinite(fraction)) return error.InvalidValue;
        const node = try self.append(.progress, style);
        node.fraction = std.math.clamp(fraction, 0, 1);
    }
    /// A read-only gauge of `value` within `range`, such as storage in use,
    /// named by `Style.name`. Values outside `bands` use the caution color.
    pub fn meter(self: *View, value: f64, range: Range, bands: MeterBands, style: Style) Error!void {
        range.validate() catch return error.InvalidRange;
        bands.validate(range) catch return error.InvalidRange;
        if (!std.math.isFinite(value)) return error.InvalidValue;
        const node = try self.append(.meter, style);
        node.range = range;
        node.bands = bands;
        node.value = std.math.clamp(value, range.minimum, range.maximum);
    }
    /// A score from 0 to `count` marks (at most `ui.widgets.max_rating`),
    /// set by pointer or arrow keys and named by `Style.name`; Home clears
    /// it. True when it changed.
    pub fn rating(self: *View, value: *u8, count: u8, style: Style) Error!bool {
        if (count == 0 or count > ui.widgets.max_rating) return error.InvalidRange;
        const range: Range = .{ .minimum = 0, .maximum = @floatFromInt(count), .step = 1 };
        const node = try self.append(.rating, style);
        node.range = range;
        var changed = false;
        if (self.take(node.id)) |event| if (event == .value) {
            const next = range.apply(@floatFromInt(value.*), event.value.change) catch return error.InvalidValue;
            const score: u8 = @intFromFloat(@round(next));
            changed = score != value.*;
            value.* = score;
        };
        value.* = @min(value.*, count);
        node.value = @floatFromInt(value.*);
        return changed;
    }
    /// Applies pointer and keyboard changes to the bound value; true when it changed.
    pub fn slider(self: *View, value: *f64, range: Range, style: Style) Error!bool {
        return self.ranged(.slider, value, range, style);
    }
    fn ranged(self: *View, kind: Kind, value: *f64, range: Range, style: Style) Error!bool {
        range.validate() catch return error.InvalidRange;
        const node = try self.append(kind, style);
        node.range = range;
        var changed = false;
        if (self.take(node.id)) |event| if (event == .value) {
            const next = range.apply(value.*, event.value.change) catch return error.InvalidValue;
            changed = next != value.*;
            value.* = next;
        };
        value.* = std.math.clamp(value.*, range.minimum, range.maximum);
        node.value = value.*;
        return changed;
    }

    /// A value field with decrement and increment buttons; true when it changed.
    pub fn stepper(self: *View, value: *f64, range: Range, style: Style) Error!bool {
        return self.ranged(.stepper, value, range, style);
    }

    /// Add a self-describing leaf; see `Embed`.
    pub fn embed(self: *View, content: Embed, style: Style) Error!void {
        const node = try self.append(.embed, style);
        node.embed = content;
    }

    /// Validate balance after the build function returns.
    pub fn finish(self: *View) Error!void {
        if (self.depth != 1) return error.UnbalancedContainer;
        self.buffers.nodes[0].end = self.len;
    }

    fn intrinsic(node: *const Node, theme: Theme, measurer: Measurer) layout.Measurement {
        if (node.embed) |content| return content.measure(content.context, theme);
        const metrics = theme.metrics;
        const text_size = if (node.text.len > 0) measurer.measure(measurer.context, node.text) else Size{ .width = 0, .height = Measurer.line_height };
        const size: Size = switch (node.kind) {
            .text => text_size,
            .spacer => .{},
            .button, .tab, .segment => .{ .width = text_size.width + 2 * (metrics.content_inset + 8), .height = @max(text_size.height, metrics.indicator_size) + 2 * metrics.content_inset },
            .link => .{ .width = text_size.width + 2 * metrics.content_inset, .height = text_size.height + 2 * metrics.content_inset },
            .badge => .{ .width = text_size.width + 2 * (metrics.content_inset + 4), .height = text_size.height + metrics.content_inset },
            .disclosure => .{ .width = metrics.indicator_size + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .checkbox, .radio => .{ .width = metrics.indicator_size + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .toggle_switch => .{ .width = metrics.indicator_size * 1.7 + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .progress, .meter => .{ .width = 160, .height = 12 },
            .rating => .{ .width = @as(f32, @floatCast(node.range.maximum)) * Measurer.line_height, .height = Measurer.line_height + metrics.content_inset },
            .slider => .{ .width = 200, .height = metrics.thumb_size + 2 * metrics.content_inset },
            .stepper => .{ .width = 4 * (Measurer.line_height + metrics.content_inset), .height = Measurer.line_height + metrics.content_inset },
            .column, .row, .radio_group, .segmented, .tab_list, .toolbar, .breadcrumbs, .accordion, .split, .scroll, .grid, .embed => unreachable,
        };
        const minimum: Size = switch (node.kind) {
            .progress, .meter, .slider, .spacer => .{ .width = 0, .height = size.height },
            else => size,
        };
        return .{ .minimum = minimum, .preferred = size };
    }

    fn options(node: *const Node) layout.Options {
        const axis: Axis = switch (node.kind) {
            .row, .segmented, .tab_list, .toolbar, .breadcrumbs => .row,
            .split => node.axis,
            else => .column,
        };
        return .{ .axis = axis, .padding = node.style.padding, .gap = if (node.kind == .split) split_divider else node.style.gap, .alignment = node.style.alignment, .justify = node.style.justify, .overflow = if (node.clips()) .clip else .visible };
    }
    fn gridOptions(node: *const Node) ui.grid.AutoOptions {
        const style = node.style;
        return .{ .layout = .{ .padding = style.padding, .column_gap = style.gap, .row_gap = style.gap, .align_x = style.alignment, .align_y = style.alignment, .overflow = if (style.clip) .clip else .visible } };
    }
    /// Grid cells for the children of `parent`, from their flex items.
    fn gridItems(self: *const View, parent: *const Node, items: []const layout.Item, out: []ui.grid.AutoItem, use_preferred_minimum: bool) []ui.grid.AutoItem {
        var child = parent.first_child;
        var i: usize = 0;
        while (child != none) : (child = self.buffers.nodes[child].next_sibling) {
            const node = &self.buffers.nodes[child];
            const value = items[i];
            out[i] = .{
                .column_span = .{ .count = @max(1, node.style.column_span) },
                .minimum = if (use_preferred_minimum) value.preferred else value.content_minimum,
                .preferred = value.preferred,
                .align_x = value.alignment,
                .align_y = value.alignment,
            };
            i += 1;
        }
        return out[0..i];
    }
    /// A grid's content size with every cell at its minimum or preferred size.
    fn measureGrid(self: *const View, node: *const Node, items: []const layout.Item) Error!layout.Measurement {
        var cells: [ui.grid.max_items]ui.grid.AutoItem = undefined;
        var rects: [ui.grid.max_items]Rect = undefined;
        var placements: [ui.grid.max_items]ui.grid.Placement = undefined;
        const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        var result: layout.Measurement = undefined;
        inline for (.{ false, true }, 0..) |preferred, pass| {
            const measured = ui.grid.computeAuto(zero, node.tracks, &.{}, self.gridItems(node, items, &cells, preferred), gridOptions(node), &rects, &placements) catch |err| return gridError(err);
            if (pass == 0) result.minimum = measured.layout.content_size else result.preferred = measured.layout.content_size;
        }
        return result;
    }
    fn gridError(err: ui.grid.Error) Error {
        return switch (err) {
            error.TooManyItems, error.GridFull, error.TooManyTracks => error.TooManyItems,
            error.OutputTooSmall => error.OutputTooSmall,
            else => error.InvalidValue,
        };
    }

    fn item(node: *const Node) layout.Item {
        const style = node.style;
        var preferred = node.measured.preferred;
        var minimum = node.measured.minimum;
        var constraints: layout.Constraints = .{ .min = .{ .width = style.min_width, .height = style.min_height }, .max = .{ .width = style.max_width, .height = style.max_height } };
        if (style.width) |width| {
            preferred.width = width;
            minimum.width = @min(minimum.width, width);
            constraints.min.width = width;
            constraints.max.width = width;
        }
        if (style.height) |height| {
            preferred.height = height;
            minimum.height = @min(minimum.height, height);
            constraints.min.height = height;
            constraints.max.height = height;
        }
        constraints.max.width = @max(constraints.max.width, constraints.min.width);
        constraints.max.height = @max(constraints.max.height, constraints.min.height);
        return .{ .preferred = preferred, .content_minimum = minimum, .constraints = constraints, .grow = style.grow, .shrink = style.shrink, .alignment = style.self_align };
    }

    fn childItems(self: *View, parent: *const Node, cursor: *usize) Error![]layout.Item {
        const start = cursor.*;
        if (self.buffers.items.len - start < parent.child_count) return error.TooManyItems;
        var child = parent.first_child;
        var at = start;
        while (child != none) : (child = self.buffers.nodes[child].next_sibling) {
            self.buffers.items[at] = item(&self.buffers.nodes[child]);
            at += 1;
        }
        cursor.* = at;
        return self.buffers.items[start..at];
    }

    /// Measure bottom-up, then place every node within `bounds`.
    pub fn arrange(self: *View, bounds: Rect, theme: Theme, measurer: Measurer) Error!void {
        const all = self.buffers.nodes[0..self.len];
        // Children always follow their parent, so reverse order is post-order.
        var index = all.len;
        while (index > 0) {
            index -= 1;
            const node = &all[index];
            if (!node.isContainer()) {
                node.measured = intrinsic(node, theme, measurer);
                continue;
            }
            var cursor: usize = 0;
            const items = try self.childItems(node, &cursor);
            if (node.kind == .grid) {
                node.measured = try self.measureGrid(node, items);
                continue;
            }
            node.measured = try layout.measure(options(node), items);
            if (node.kind == .scroll) {
                // The viewport may shrink to nothing; its content keeps its size.
                node.content = node.measured.preferred;
                node.measured.minimum.height = 0;
            }
        }
        all[0].bounds = bounds;
        var cursor: usize = 0;
        for (all) |*node| {
            if (!node.isContainer() or node.child_count == 0) continue;
            const start = cursor;
            const items = try self.childItems(node, &cursor);
            if (self.buffers.rects.len < cursor) return error.OutputTooSmall;
            const rects = self.buffers.rects[start..cursor];
            switch (node.kind) {
                .grid => {
                    var cells: [ui.grid.max_items]ui.grid.AutoItem = undefined;
                    var placements: [ui.grid.max_items]ui.grid.Placement = undefined;
                    _ = ui.grid.computeAuto(node.bounds, node.tracks, &.{}, self.gridItems(node, items, &cells, false), gridOptions(node), rects, &placements) catch |err| return gridError(err);
                },
                .scroll => {
                    const model = node.scroll.?;
                    const viewport: Size = .{ .width = node.bounds.width, .height = node.bounds.height };
                    _ = model.setSizes(viewport, .{ .width = viewport.width, .height = node.content.height }) catch return error.InvalidValue;
                    const content: Rect = .{ .x = node.bounds.x, .y = node.bounds.y - model.offset.y, .width = viewport.width, .height = @max(viewport.height, node.content.height) };
                    _ = try layout.arrange(content, options(node), items, rects);
                },
                .split => splitPanes(node, rects),
                else => _ = try layout.arrange(node.bounds, options(node), items, rects),
            }
            var child = node.first_child;
            var i: usize = 0;
            while (child != none) : (child = all[child].next_sibling) {
                all[child].bounds = rects[i];
                i += 1;
            }
        }
    }

    /// Both panes fill the cross axis; the first takes `value` of the length
    /// left after the divider.
    fn splitPanes(node: *const Node, rects: []Rect) void {
        const p = node.style.padding;
        const b = node.bounds;
        const inner: Rect = .{ .x = b.x + p.left, .y = b.y + p.top, .width = @max(0, b.width - p.left - p.right), .height = @max(0, b.height - p.top - p.bottom) };
        const vertical = node.axis == .column;
        const available = @max(0, (if (vertical) inner.height else inner.width) - split_divider);
        const first: f32 = @round(available * @as(f32, @floatCast(node.value)));
        const second = available - first;
        if (vertical) {
            rects[0] = .{ .x = inner.x, .y = inner.y, .width = inner.width, .height = first };
            rects[1] = .{ .x = inner.x, .y = inner.y + first + split_divider, .width = inner.width, .height = second };
        } else {
            rects[0] = .{ .x = inner.x, .y = inner.y, .width = first, .height = inner.height };
            rects[1] = .{ .x = inner.x + first + split_divider, .y = inner.y, .width = second, .height = inner.height };
        }
    }

    /// Record the arranged tree. `target` is a ui.Frame or any value with the
    /// same recording methods.
    pub fn paint(self: *const View, target: anytype) !void {
        const all = self.buffers.nodes[0..self.len];
        const theme = target.currentTheme();
        var clips: [max_depth + 1]u32 = undefined;
        var clip_depth: usize = 0;
        for (all, 0..) |*node, at| {
            while (clip_depth > 0 and all[clips[clip_depth - 1]].end <= at) {
                clip_depth -= 1;
                try target.popClip();
                paintScrollIndicator(&all[clips[clip_depth]], target, theme);
            }
            const bounds = node.bounds;
            const style = node.style;
            const control: ui.widgets.Options = .{ .enabled = style.enabled, .name = style.name, .semantic_parent = node.semantic_parent };
            switch (node.kind) {
                .column, .row, .radio_group, .segmented, .tab_list, .toolbar, .breadcrumbs, .accordion, .split, .scroll, .grid => {
                    switch (node.kind) {
                        .radio_group, .segmented => try target.radioGroup(node.id, bounds, style.name),
                        .tab_list => try target.tabList(node.id, bounds, style.name),
                        .toolbar => try target.toolbar(node.id, bounds, style.name),
                        .breadcrumbs => try target.navigation(node.id, bounds, style.name, node.semantic_parent),
                        .accordion => try target.group(node.id, bounds, style.name, node.semantic_parent),
                        else => {},
                    }
                    if (style.background) |color| target.roundedRect(bounds, style.radius, ui.Color.rgb(color));
                    if (style.border) |color| target.strokeRect(bounds, style.radius, style.border_width, ui.Color.rgb(color));
                    if (node.kind == .breadcrumbs) self.paintSeparators(node, target, theme);
                    if (node.kind == .split) {
                        const p = style.padding;
                        const area: Rect = .{ .x = bounds.x + p.left, .y = bounds.y + p.top, .width = @max(0, bounds.width - p.left - p.right), .height = @max(0, bounds.height - p.top - p.bottom) };
                        try target.splitter(node.id, area, self.divider(node).?, node.value, node.range, .{ .control = control, .vertical = node.axis == .column });
                    }
                    if (node.clips() and node.child_count > 0) {
                        try target.pushClip(bounds);
                        clips[clip_depth] = @intCast(at);
                        clip_depth += 1;
                    }
                },
                .text => target.label(bounds, node.text, style.color orelse if (style.enabled) theme.palette.text else theme.palette.disabled_text),
                .spacer => {},
                .button => try target.buttonWithOptions(node.id, bounds, node.text, control),
                .link => try target.link(node.id, bounds, node.text, control),
                .badge => {
                    const pad = theme.metrics.content_inset + 4;
                    target.roundedRect(bounds, bounds.height / 2, ui.Color.rgb(style.background orelse theme.palette.accent));
                    target.label(.{ .x = bounds.x + pad, .y = bounds.y, .width = @max(0, bounds.width - 2 * pad), .height = bounds.height }, node.text, style.color orelse theme.palette.on_accent);
                },
                .disclosure => try target.disclosure(node.id, bounds, node.text, node.checked, control),
                .checkbox => try target.checkbox(node.id, bounds, node.text, node.checked, control),
                .radio => {
                    var radio_options = control;
                    radio_options.radio_group = node.radio_group;
                    try target.radio(node.id, bounds, node.text, node.checked, radio_options);
                },
                .segment => {
                    var segment_options = control;
                    segment_options.radio_group = node.radio_group;
                    try target.segment(node.id, bounds, node.text, node.checked, segment_options);
                },
                .tab => {
                    var tab_options = control;
                    tab_options.radio_group = node.radio_group;
                    try target.tab(node.id, bounds, node.text, node.checked, tab_options);
                },
                .toggle_switch => try target.toggleSwitch(node.id, bounds, node.text, node.checked, control),
                .progress => try target.progress(node.id, bounds, node.fraction, control),
                .meter => try target.meter(node.id, bounds, node.value, node.range, .{ .control = control, .bands = node.bands }),
                .rating => try target.rating(node.id, bounds, node.value, @intFromFloat(node.range.maximum), control),
                .slider => try target.slider(node.id, bounds, node.value, node.range, .{ .control = control }),
                .stepper => try target.stepper(node.id, bounds, node.value, node.range, control),
                .embed => {
                    const content = node.embed.?;
                    if (@TypeOf(target) == *ui.Frame) try content.paint(content.context, target, node.id, bounds) else try target.embedded(node.id, bounds);
                },
            }
        }
        while (clip_depth > 0) {
            clip_depth -= 1;
            try target.popClip();
            paintScrollIndicator(&all[clips[clip_depth]], target, theme);
        }
    }

    /// A muted slash centred in each gap between breadcrumb items.
    fn paintSeparators(self: *const View, node: *const Node, target: anytype, theme: Theme) void {
        var child = node.first_child;
        while (child != none) {
            const left = self.buffers.nodes[child].bounds;
            child = self.buffers.nodes[child].next_sibling;
            if (child == none) break;
            const right = self.buffers.nodes[child].bounds;
            const glyph = Measurer.estimate(null, "/").width;
            const middle = (left.x + left.width + right.x) / 2;
            target.label(.{ .x = middle - glyph / 2, .y = left.y, .width = glyph, .height = left.height }, "/", theme.palette.disabled_text);
        }
    }

    /// A thin, non-interactive thumb along the right edge while content overflows.
    fn paintScrollIndicator(node: *const Node, target: anytype, theme: Theme) void {
        const model = node.scroll orelse return;
        const b = node.bounds;
        if (b.width < 8 or b.height < 8) return;
        const track: Rect = .{ .x = b.x + b.width - 6, .y = b.y + 2, .width = 4, .height = b.height - 4 };
        const bar = (model.scrollbar(.vertical, track, 16) catch return) orelse return;
        target.roundedRect(bar.thumb, 2, ui.Color.rgb(theme.palette.track));
    }
};

/// A type-erased build function bound to its application state.
pub const Build = struct {
    state: *anyopaque,
    call: *const fn (*anyopaque, *View) anyerror!void,

    pub fn bind(state: anytype, comptime build: fn (@TypeOf(state), *View) anyerror!void) Build {
        const State = @TypeOf(state);
        const Thunk = struct {
            fn call(ptr: *anyopaque, view: *View) anyerror!void {
                const typed: State = @ptrCast(@alignCast(ptr));
                return build(typed, view);
            }
        };
        return .{ .state = @ptrCast(state), .call = Thunk.call };
    }

    /// Run one complete pass into `view`, optionally delivering `event`.
    pub fn run(self: Build, view: *View, root_style: Style, event: ?Event) anyerror!void {
        view.reset(root_style, event);
        try self.call(self.state, view);
        try view.finish();
    }
};

fn intersect(a: Rect, b: Rect) ?Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    if (!(x1 > x0 and y1 > y0)) return null;
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

pub const Harness = @import("harness.zig").Harness;
pub const Query = @import("harness.zig").Query;

pub const Options = struct {
    /// Style of the implicit root column, which fills the window.
    root: Style = .{ .padding = Insets.all(24), .gap = 12, .alignment = .start },
    /// Window background; defaults to the theme background.
    background: ?u32 = null,
    measurer: Measurer = .{},
};

/// Owns the ui.Context for one window. Keep Host at a stable address from
/// attach through the Context's detach, like any Context.
pub const Host = struct {
    context: ui.Context,
    view: View,
    build: Build,
    options: Options,
    building: bool = false,
    /// The first error from the most recent pass, kept for diagnostics.
    last_error: ?anyerror = null,
    frames: usize = 0,
    /// Visible scroll containers of the last frame, in paint order.
    scroll_regions: [max_scroll_regions]struct { id: u64, bounds: Rect } = undefined,
    scroll_region_count: usize = 0,

    pub fn init(state: anytype, comptime build: fn (@TypeOf(state), *View) anyerror!void, buffers: Buffers, options: Options) Host {
        return .{
            .context = ui.Context.init(undefined, draw, onAction),
            .view = View.init(buffers),
            .build = Build.bind(state, build),
            .options = options,
        };
    }

    pub fn attach(self: *Host, window: z.Window) !void {
        self.context.state = self;
        self.context.on_value = onValue;
        self.context.on_input = onInput;
        try self.context.attach(window);
    }

    /// Run one build pass. Event passes record nothing; they only let the
    /// owning widget update application state immediately, so successive
    /// inputs are never merged by repaint coalescing.
    pub fn pass(self: *Host, event: ?Event) anyerror!void {
        if (self.building) return error.Busy;
        self.building = true;
        defer self.building = false;
        try self.build.run(&self.view, self.options.root, event);
    }

    fn deliver(self: *Host, event: Event) void {
        self.pass(event) catch |err| {
            self.last_error = err;
        };
    }
    fn onAction(ptr: *anyopaque, id: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.deliver(.{ .action = id });
    }
    fn onValue(ptr: *anyopaque, id: u64, change: ValueChange) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.deliver(.{ .value = .{ .id = id, .change = change } });
    }
    /// Route a wheel event to the innermost visible scroll container under it.
    fn onInput(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (event != .wheel) return false;
        const wheel = event.wheel;
        var index = self.scroll_region_count;
        while (index > 0) {
            index -= 1;
            const region = self.scroll_regions[index];
            const b = region.bounds;
            if (wheel.position.x < b.x or wheel.position.y < b.y or wheel.position.x >= b.x + b.width or wheel.position.y >= b.y + b.height) continue;
            self.deliver(.{ .scroll = .{ .id = region.id, .delta = .{ .x = wheel.delta.x, .y = wheel.delta.y } } });
            return self.view.consumed;
        }
        return false;
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        frame.clear(self.options.background orelse theme.palette.background);
        self.render(frame, theme) catch |err| {
            self.last_error = err;
            // A failed frame keeps the previously committed one.
            frame.failure = frame.failure orelse err;
            return;
        };
        self.frames += 1;
    }
    fn render(self: *Host, frame: *ui.Frame, theme: Theme) anyerror!void {
        try self.pass(null);
        try self.view.arrange(frame.sourceBounds(), theme, self.options.measurer);
        try self.view.paint(frame);
        for (self.view.nodes()) |*node| {
            const content = node.embed orelse continue;
            if (content.place) |place| place(content.context, node.id, node.bounds);
        }
        self.scroll_region_count = 0;
        for (self.view.nodes()) |*node| {
            if (node.kind != .scroll or self.scroll_region_count == max_scroll_regions) continue;
            const bounds = self.view.visible(node) orelse continue;
            self.scroll_regions[self.scroll_region_count] = .{ .id = node.id, .bounds = bounds };
            self.scroll_region_count += 1;
        }
    }
};

const Recorder = struct {
    const Call = struct { kind: Kind, id: u64, bounds: Rect, checked: bool = false };
    calls: [64]Call = undefined,
    len: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    fills: usize = 0,
    chooser: u64 = 0,
    fn push(self: *Recorder, kind: Kind, id: u64, bounds: Rect, checked: bool) void {
        self.calls[self.len] = .{ .kind = kind, .id = id, .bounds = bounds, .checked = checked };
        self.len += 1;
    }
    pub fn currentTheme(_: *const Recorder) Theme {
        return .{};
    }
    pub fn roundedRect(self: *Recorder, _: Rect, _: f32, _: ui.Color) void {
        self.fills += 1;
    }
    pub fn strokeRect(self: *Recorder, _: Rect, _: f32, _: f32, _: ui.Color) void {
        self.fills += 1;
    }
    pub fn pushClip(self: *Recorder, _: Rect) !void {
        self.clip_depth += 1;
        self.max_clip_depth = @max(self.max_clip_depth, self.clip_depth);
    }
    pub fn popClip(self: *Recorder) !void {
        if (self.clip_depth == 0) return error.ClipStackEmpty;
        self.clip_depth -= 1;
    }
    pub fn label(self: *Recorder, bounds: Rect, _: []const u8, _: u32) void {
        self.push(.text, 0, bounds, false);
    }
    pub fn buttonWithOptions(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: ui.widgets.Options) !void {
        self.push(.button, id, bounds, false);
    }
    pub fn checkbox(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, _: ui.widgets.Options) !void {
        self.push(.checkbox, id, bounds, checked);
    }
    pub fn radioGroup(self: *Recorder, id: u64, _: Rect, _: []const u8) !void {
        self.chooser = id;
    }
    pub fn radio(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, options: ui.widgets.Options) !void {
        if (options.radio_group == null or options.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.radio, id, bounds, checked);
    }
    pub fn link(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: ui.widgets.Options) !void {
        self.push(.link, id, bounds, false);
    }
    pub fn segment(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, options: ui.widgets.Options) !void {
        if (options.radio_group == null or options.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.segment, id, bounds, checked);
    }
    pub fn disclosure(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, _: ui.widgets.Options) !void {
        self.push(.disclosure, id, bounds, checked);
    }
    pub fn tabList(self: *Recorder, id: u64, _: Rect, _: []const u8) !void {
        self.chooser = id;
    }
    pub fn tab(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, options: ui.widgets.Options) !void {
        if (options.radio_group == null or options.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.tab, id, bounds, checked);
    }
    pub fn toolbar(self: *Recorder, id: u64, bounds: Rect, _: []const u8) !void {
        self.push(.toolbar, id, bounds, false);
    }
    pub fn navigation(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.breadcrumbs, id, bounds, false);
    }
    pub fn group(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.accordion, id, bounds, false);
    }
    pub fn meter(self: *Recorder, id: u64, bounds: Rect, _: f64, _: Range, _: ui.widgets.MeterOptions) !void {
        self.push(.meter, id, bounds, false);
    }
    pub fn rating(self: *Recorder, id: u64, bounds: Rect, _: f64, _: u8, _: ui.widgets.Options) !void {
        self.push(.rating, id, bounds, false);
    }
    pub fn splitter(self: *Recorder, id: u64, _: Rect, divider: Rect, _: f64, _: Range, _: ui.widgets.SplitterOptions) !void {
        self.push(.split, id, divider, false);
    }
    pub fn toggleSwitch(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, _: ui.widgets.Options) !void {
        self.push(.toggle_switch, id, bounds, checked);
    }
    pub fn progress(self: *Recorder, id: u64, bounds: Rect, _: f32, _: ui.widgets.Options) !void {
        self.push(.progress, id, bounds, false);
    }
    pub fn slider(self: *Recorder, id: u64, bounds: Rect, _: f64, _: Range, _: ui.widgets.RangeOptions) !void {
        self.push(.slider, id, bounds, false);
    }
    pub fn stepper(self: *Recorder, id: u64, bounds: Rect, _: f64, _: Range, _: ui.widgets.Options) !void {
        self.push(.stepper, id, bounds, false);
    }
    pub fn embedded(self: *Recorder, id: u64, bounds: Rect) !void {
        self.push(.embed, id, bounds, false);
    }
};

const TestState = struct {
    count: usize = 0,
    enabled: bool = false,
    volume: f64 = 0.5,
    choice: enum { a, b } = .a,
    items: []const []const u8 = &.{ "one", "two" },
    fn build(self: *TestState, v: *View) anyerror!void {
        try v.textf("Count: {d}", .{self.count}, .{});
        try v.row(.{ .gap = 8, .alignment = .center });
        if (try v.button("Increment", .{})) self.count += 1;
        try v.spacer(.{});
        if (try v.button("Reset", .{ .enabled = self.count > 0 })) self.count = 0;
        try v.end();
        _ = try v.toggleSwitch(&self.enabled, "Enabled", .{});
        _ = try v.slider(&self.volume, .{ .minimum = 0, .maximum = 1, .step = 0.1 }, .{ .self_align = .stretch });
        try v.radioGroup(.{ .name = "Choice" });
        _ = try v.radio(@TypeOf(self.choice), &self.choice, .a, "A", .{});
        _ = try v.radio(@TypeOf(self.choice), &self.choice, .b, "B", .{});
        try v.end();
        try v.column(.{ .clip = true, .background = 0xeeeeee });
        for (self.items) |name| try v.text(name, .{ .key = key(name) });
        try v.end();
    }
};

fn testPass(view: *View, state: *TestState, event: ?Event) !void {
    view.reset((Options{}).root, event);
    try state.build(view);
    try view.finish();
}
fn findId(view: *const View, kind: Kind, nth: usize) u64 {
    var seen: usize = 0;
    for (view.nodes()) |node| if (node.kind == kind) {
        if (seen == nth) return node.id;
        seen += 1;
    };
    unreachable;
}

test "ids are stable across passes and distinct per node" {
    var storage: Storage(64, 1024) = .{};
    var view = View.init(storage.buffers());
    var state: TestState = .{};
    try testPass(&view, &state, null);
    var first: [64]u64 = undefined;
    for (view.nodes(), 0..) |node, i| {
        try std.testing.expect(node.id != 0);
        first[i] = node.id;
        for (view.nodes()[0..i]) |other| try std.testing.expect(other.id != node.id);
    }
    const len = view.len;
    state.count = 7;
    try testPass(&view, &state, null);
    try std.testing.expectEqual(len, view.len);
    for (view.nodes(), 0..) |node, i| try std.testing.expectEqual(first[i], node.id);
}

test "keyed nodes keep identity when siblings move" {
    var storage: Storage(64, 1024) = .{};
    var view = View.init(storage.buffers());
    var state: TestState = .{ .items = &.{ "one", "two" } };
    try testPass(&view, &state, null);
    const two = view.nodes()[view.len - 1].id;
    state.items = &.{ "zero", "one", "two" };
    try testPass(&view, &state, null);
    try std.testing.expectEqual(two, view.nodes()[view.len - 1].id);
}

test "events reach exactly the widget that owns the id" {
    var storage: Storage(64, 1024) = .{};
    var view = View.init(storage.buffers());
    var state: TestState = .{};
    try testPass(&view, &state, null);
    const increment = findId(&view, .button, 0);
    const toggle = findId(&view, .toggle_switch, 0);
    const slide = findId(&view, .slider, 0);
    const second = findId(&view, .radio, 1);
    try testPass(&view, &state, .{ .action = increment });
    try testPass(&view, &state, .{ .action = increment });
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expect(view.consumed);
    try testPass(&view, &state, .{ .action = toggle });
    try std.testing.expect(state.enabled);
    try testPass(&view, &state, .{ .value = .{ .id = slide, .change = .{ .steps = 2 } } });
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), state.volume, 1e-9);
    try testPass(&view, &state, .{ .value = .{ .id = slide, .change = .maximum } });
    try std.testing.expectEqual(@as(f64, 1), state.volume);
    try testPass(&view, &state, .{ .action = second });
    try std.testing.expectEqual(.b, state.choice);
    // A stale id changes nothing.
    try testPass(&view, &state, .{ .action = 12345 });
    try std.testing.expect(!view.consumed);
    try std.testing.expectEqual(@as(usize, 2), state.count);
}

test "arrange places rows and columns with flex layout" {
    var storage: Storage(64, 1024) = .{};
    var view = View.init(storage.buffers());
    var state: TestState = .{};
    try testPass(&view, &state, null);
    try view.arrange(.{ .x = 0, .y = 0, .width = 640, .height = 480 }, .{}, .{});
    const nodes = view.nodes();
    try std.testing.expectEqual(@as(f32, 24), nodes[1].bounds.x);
    try std.testing.expectEqual(@as(f32, 24), nodes[1].bounds.y);
    const row_node = nodes[2];
    try std.testing.expectEqual(Kind.row, row_node.kind);
    try std.testing.expectEqual(nodes[1].bounds.y + nodes[1].bounds.height + 12, row_node.bounds.y);
    // The spacer pushes Reset to the row's far edge when the row stretches.
    const reset = nodes[row_node.first_child + 2];
    try std.testing.expectEqual(Kind.button, reset.kind);
    try std.testing.expectApproxEqAbs(row_node.bounds.x + row_node.bounds.width, reset.bounds.x + reset.bounds.width, 0.01);
    const slider_node = nodes[findIndex(&view, .slider)];
    try std.testing.expectApproxEqAbs(@as(f32, 640 - 48), slider_node.bounds.width, 0.01);
    for (nodes) |node| try std.testing.expect(layout.validRect(node.bounds));
}
fn findIndex(view: *const View, kind: Kind) usize {
    for (view.nodes(), 0..) |node, i| if (node.kind == kind) return i;
    unreachable;
}

test "explicit sizes and paint order with balanced clips" {
    var storage: Storage(64, 1024) = .{};
    var view = View.init(storage.buffers());
    var state: TestState = .{};
    try testPass(&view, &state, null);
    try view.arrange(.{ .x = 0, .y = 0, .width = 640, .height = 480 }, .{}, .{});
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(@as(usize, 0), recorder.clip_depth);
    try std.testing.expectEqual(@as(usize, 1), recorder.max_clip_depth);
    try std.testing.expectEqual(@as(usize, 1), recorder.fills);
    try std.testing.expectEqual(Kind.text, recorder.calls[0].kind);
    try std.testing.expectEqual(Kind.button, recorder.calls[1].kind);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 1 + 1 + 2 + 2), recorder.len);
    try std.testing.expect(recorder.calls[5].checked and !recorder.calls[6].checked);

    view.reset(.{}, null);
    try view.text("fixed", .{ .width = 50, .height = 10 });
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, .{}, .{});
    try std.testing.expectEqual(@as(f32, 50), view.nodes()[1].bounds.width);
    try std.testing.expectEqual(@as(f32, 10), view.nodes()[1].bounds.height);
}

test "capacity and balance failures are reported" {
    var storage: Storage(4, 8) = .{};
    var view = View.init(storage.buffers());
    view.reset(.{}, null);
    try std.testing.expectError(error.TextFull, view.text("too long for eight", .{}));
    view.reset(.{}, null);
    try view.row(.{});
    try std.testing.expectError(error.UnbalancedContainer, view.finish());
    view.reset(.{}, null);
    try std.testing.expectError(error.UnbalancedContainer, view.end());
    view.reset(.{}, null);
    try view.spacer(.{});
    try view.spacer(.{});
    try view.spacer(.{});
    try std.testing.expectError(error.TooManyNodes, view.spacer(.{}));
    view.reset(.{}, null);
    var zero: f64 = 0;
    try std.testing.expectError(error.InvalidRange, view.slider(&zero, .{ .minimum = 1, .maximum = 0 }, .{}));
    view.reset(.{}, null);
    var mode: u8 = 0;
    try std.testing.expectError(error.NotContainer, view.radio(u8, &mode, 1, "x", .{}));
    var depth: Storage(64, 8) = .{};
    view = View.init(depth.buffers());
    view.reset(.{}, null);
    for (0..max_depth) |_| try view.column(.{});
    try std.testing.expectError(error.NestingTooDeep, view.column(.{}));
}

test {
    _ = @import("harness.zig");
}

test "embedded leaves measure themselves and paint in order" {
    const Box = struct {
        fn measure(_: *anyopaque, _: Theme) layout.Measurement {
            return .{ .minimum = .{ .width = 40, .height = 20 }, .preferred = .{ .width = 120, .height = 30 } };
        }
        fn paint(_: *anyopaque, _: *ui.Frame, _: u64, _: Rect) anyerror!void {}
    };
    var context: u8 = 0;
    const box: Embed = .{ .context = &context, .measure = Box.measure, .paint = Box.paint };
    var storage: Storage(8, 64) = .{};
    var view = View.init(storage.buffers());
    view.reset(.{}, null);
    try view.row(.{ .gap = 4 });
    try view.embed(box, .{});
    try view.embed(box, .{ .grow = 1 });
    try view.end();
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 300, .height = 100 }, .{}, .{});
    const nodes = view.nodes();
    try std.testing.expectEqual(@as(f32, 120), nodes[2].bounds.width);
    try std.testing.expectEqual(@as(f32, 30), nodes[2].bounds.height);
    try std.testing.expectEqual(@as(f32, 300 - 124), nodes[3].bounds.width);
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(@as(usize, 2), recorder.len);
    try std.testing.expectEqual(nodes[3].id, recorder.calls[1].id);
}

test "estimate measures wide codepoints wider" {
    const narrow = Measurer.estimate(null, "ab");
    const wide = Measurer.estimate(null, "计数");
    try std.testing.expect(wide.width > narrow.width);
    try std.testing.expectEqual(Measurer.line_height, wide.height);
}
