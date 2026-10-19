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

pub const Error = error{ TooManyNodes, TextFull, NestingTooDeep, UnbalancedContainer, NotContainer, Busy, InvalidRange, InvalidValue, InvalidText } || layout.Error;

pub const max_depth = 32;
const none = std.math.maxInt(u32);
const root_seed: u64 = 0x5a1f_7c3d_9b2e_4a61;

/// Appearance and participation of one node. Container fields are ignored on
/// leaves; leaf sizes come from their content and the active theme metrics.
pub const Style = struct {
    /// Stable identity for a node whose position among its siblings changes.
    key: ?u64 = null,
    /// Child spacing and placement for containers.
    gap: f32 = 0,
    padding: Insets = .{},
    alignment: Align = .stretch,
    justify: Justify = .start,
    clip: bool = false,
    /// Participation in the parent's flex line.
    grow: f32 = 0,
    shrink: f32 = 1,
    self_align: ?Align = null,
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

pub const Kind = enum { column, row, radio_group, text, spacer, button, checkbox, radio, toggle_switch, progress, slider };

pub const Node = struct {
    kind: Kind,
    id: u64,
    style: Style,
    text: []const u8 = "",
    checked: bool = false,
    fraction: f32 = 0,
    value: f64 = 0,
    range: Range = .{ .minimum = 0, .maximum = 1 },
    radio_group: ?u64 = null,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next_sibling: u32 = none,
    child_count: u32 = 0,
    /// One past the last descendant, in build order.
    end: u32 = 0,
    measured: layout.Measurement = .{ .minimum = .{}, .preferred = .{} },
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn isContainer(self: *const Node) bool {
        return self.kind == .column or self.kind == .row or self.kind == .radio_group;
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
        self.buffers.nodes[index] = .{ .kind = kind, .id = self.identity(parent, kind, style), .style = style, .parent = parent_index, .end = index + 1 };
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
        };
        if (target != id) return null;
        self.event = null;
        self.consumed = true;
        return event;
    }

    pub fn begin(self: *View, axis: Axis, style: Style) Error!void {
        if (self.depth > max_depth) return error.NestingTooDeep;
        const node = try self.append(if (axis == .column) .column else .row, style);
        self.stack[self.depth] = @intCast(node - self.buffers.nodes.ptr);
        self.depth += 1;
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
        self.buffers.nodes[index].end = self.len;
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
        if (self.depth > max_depth) return error.NestingTooDeep;
        const node = try self.append(.radio_group, style);
        self.stack[self.depth] = @intCast(node - self.buffers.nodes.ptr);
        self.depth += 1;
    }
    /// Selects `option` on activation; true when the selection changed.
    pub fn radio(self: *View, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.kind != .radio_group) return error.NotContainer;
        const group = parent.id;
        const node = try self.append(.radio, style);
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
    /// Applies pointer and keyboard changes to the bound value; true when it changed.
    pub fn slider(self: *View, value: *f64, range: Range, style: Style) Error!bool {
        range.validate() catch return error.InvalidRange;
        const node = try self.append(.slider, style);
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

    /// Validate balance after the build function returns.
    pub fn finish(self: *View) Error!void {
        if (self.depth != 1) return error.UnbalancedContainer;
        self.buffers.nodes[0].end = self.len;
    }

    fn intrinsic(node: *const Node, theme: Theme, measurer: Measurer) layout.Measurement {
        const metrics = theme.metrics;
        const text_size = if (node.text.len > 0) measurer.measure(measurer.context, node.text) else Size{ .width = 0, .height = Measurer.line_height };
        const size: Size = switch (node.kind) {
            .text => text_size,
            .spacer => .{},
            .button => .{ .width = text_size.width + 2 * (metrics.content_inset + 8), .height = @max(text_size.height, metrics.indicator_size) + 2 * metrics.content_inset },
            .checkbox, .radio => .{ .width = metrics.indicator_size + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .toggle_switch => .{ .width = metrics.indicator_size * 1.7 + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .progress => .{ .width = 160, .height = 12 },
            .slider => .{ .width = 200, .height = metrics.thumb_size + 2 * metrics.content_inset },
            .column, .row, .radio_group => unreachable,
        };
        const minimum: Size = switch (node.kind) {
            .progress, .slider, .spacer => .{ .width = 0, .height = size.height },
            else => size,
        };
        return .{ .minimum = minimum, .preferred = size };
    }

    fn options(node: *const Node) layout.Options {
        return .{ .axis = if (node.kind == .row) .row else .column, .padding = node.style.padding, .gap = node.style.gap, .alignment = node.style.alignment, .justify = node.style.justify, .overflow = if (node.style.clip) .clip else .visible };
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
            node.measured = try layout.measure(options(node), items);
        }
        all[0].bounds = bounds;
        var cursor: usize = 0;
        for (all) |*node| {
            if (!node.isContainer() or node.child_count == 0) continue;
            const start = cursor;
            const items = try self.childItems(node, &cursor);
            if (self.buffers.rects.len < cursor) return error.OutputTooSmall;
            const rects = self.buffers.rects[start..cursor];
            _ = try layout.arrange(node.bounds, options(node), items, rects);
            var child = node.first_child;
            var i: usize = 0;
            while (child != none) : (child = all[child].next_sibling) {
                all[child].bounds = rects[i];
                i += 1;
            }
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
            }
            const bounds = node.bounds;
            const style = node.style;
            const control: ui.widgets.Options = .{ .enabled = style.enabled, .name = style.name };
            switch (node.kind) {
                .column, .row, .radio_group => {
                    if (node.kind == .radio_group) try target.radioGroup(node.id, bounds, style.name);
                    if (style.background) |color| target.roundedRect(bounds, style.radius, ui.Color.rgb(color));
                    if (style.border) |color| target.strokeRect(bounds, style.radius, style.border_width, ui.Color.rgb(color));
                    if (style.clip and node.child_count > 0) {
                        try target.pushClip(bounds);
                        clips[clip_depth] = @intCast(at);
                        clip_depth += 1;
                    }
                },
                .text => target.label(bounds, node.text, style.color orelse if (style.enabled) theme.palette.text else theme.palette.disabled_text),
                .spacer => {},
                .button => try target.buttonWithOptions(node.id, bounds, node.text, control),
                .checkbox => try target.checkbox(node.id, bounds, node.text, node.checked, control),
                .radio => {
                    var radio_options = control;
                    radio_options.radio_group = node.radio_group;
                    try target.radio(node.id, bounds, node.text, node.checked, radio_options);
                },
                .toggle_switch => try target.toggleSwitch(node.id, bounds, node.text, node.checked, control),
                .progress => try target.progress(node.id, bounds, node.fraction, control),
                .slider => try target.slider(node.id, bounds, node.value, node.range, .{ .control = control }),
            }
        }
        while (clip_depth > 0) : (clip_depth -= 1) try target.popClip();
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
    }
};

const Recorder = struct {
    const Call = struct { kind: Kind, id: u64, bounds: Rect, checked: bool = false };
    calls: [64]Call = undefined,
    len: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    fills: usize = 0,
    group: u64 = 0,
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
        self.group = id;
    }
    pub fn radio(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, options: ui.widgets.Options) !void {
        if (options.radio_group == null or options.radio_group.? != self.group) return error.MissingGroup;
        self.push(.radio, id, bounds, checked);
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

test "estimate measures wide codepoints wider" {
    const narrow = Measurer.estimate(null, "ab");
    const wide = Measurer.estimate(null, "计数");
    try std.testing.expect(wide.width > narrow.width);
    try std.testing.expectEqual(Measurer.line_height, wide.height);
}
