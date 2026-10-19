const std = @import("std");
const layout = @import("layout.zig");
const access = @import("accessibility.zig");
const input = @import("input.zig");
pub const Range = input.Range;
pub const ValueChange = input.ValueChange;
pub const Chord = input.Chord;

pub const Options = struct {
    enabled: bool = true,
    semantic_parent: u64 = access.root_id,
    /// Radios with the same explicit group share a Tab stop and arrow navigation.
    radio_group: ?u64 = null,
    /// Accessible name for a progress indicator, which has no visible label.
    name: []const u8 = "",
    shortcut: ?Chord = null,
};
pub const RangeOptions = struct { control: Options = .{}, vertical: bool = false };
pub const RangeSliderIds = struct { group: u64, low: u64, high: u64 };
pub const RangeSliderOptions = struct {
    name: []const u8 = "",
    low_name: []const u8 = "Minimum",
    high_name: []const u8 = "Maximum",
    low: Options = .{},
    high: Options = .{},
    vertical: bool = false,
};
pub const SplitterOptions = struct { control: Options = .{}, vertical: bool = false };
pub const Kind = enum { button, checkbox, radio, toggle_switch, progress, tab };
const Snapshot = struct {
    hits: usize,
    commands: usize,
    text: usize,
    semantics: usize,
    semantic_text: usize,
    fn init(frame: anytype) Snapshot {
        const context = frame.context;
        const has_semantics = comptime @TypeOf(context.semantic_tree) != void;
        return .{ .hits = context.input_state.checkpoint(), .commands = context.command_buffer.len, .text = context.command_buffer.text_len, .semantics = if (has_semantics) context.semantic_tree.len else 0, .semantic_text = if (has_semantics) context.semantic_tree.used else 0 };
    }
    fn restore(self: Snapshot, frame: anytype) void {
        const context = frame.context;
        context.input_state.rollback(self.hits);
        context.command_buffer.len = self.commands;
        context.command_buffer.text_len = self.text;
        if (comptime @TypeOf(context.semantic_tree) != void) {
            context.semantic_tree.len = self.semantics;
            context.semantic_tree.used = self.semantic_text;
            if (context.semantic_tree.mapped) |snapshot| snapshot.semantic_len = self.semantics;
        }
    }
};

fn absolute(frame: anytype, bounds: layout.Rect) layout.Rect {
    return .{ .x = bounds.x + frame.offset.x, .y = bounds.y + frame.offset.y, .width = bounds.width, .height = bounds.height };
}

/// The same visual/hit/semantic transaction, with optional identity metadata
/// bound only to the one successfully appended button hit.
pub fn emitClickButton(frame: anytype, target: input.pointer_clicks.kernel.Target, bounds: layout.Rect, text: []const u8, options: Options) !void {
    const before = Snapshot.init(frame);
    errdefer before.restore(frame);
    try emit(frame, .button, target.id, bounds, text, false, 0, options);
    if (frame.context.input_state.checkpoint() != before.hits + 1) return error.InvalidBinding;
    try frame.context.input_state.bindClickTarget(before.hits, target.id, target);
}
fn inset(bounds: layout.Rect, amount: f32) layout.Rect {
    const x = @min(amount, bounds.width / 2);
    const y = @min(amount, bounds.height / 2);
    return .{ .x = bounds.x + x, .y = bounds.y + y, .width = @max(0, bounds.width - 2 * x), .height = @max(0, bounds.height - 2 * y) };
}
fn fill(frame: anytype, bounds: layout.Rect, color: u32) !void {
    try frame.context.command_buffer.fill(absolute(frame, bounds), color);
}
fn outline(frame: anytype, bounds: layout.Rect, width: f32, color: u32) !void {
    const w = @min(width, @min(bounds.width, bounds.height) / 2);
    try fill(frame, .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = w }, color);
    try fill(frame, .{ .x = bounds.x, .y = bounds.y + bounds.height - w, .width = bounds.width, .height = w }, color);
    try fill(frame, .{ .x = bounds.x, .y = bounds.y + w, .width = w, .height = @max(0, bounds.height - 2 * w) }, color);
    try fill(frame, .{ .x = bounds.x + bounds.width - w, .y = bounds.y + w, .width = w, .height = @max(0, bounds.height - 2 * w) }, color);
}
fn disk(frame: anytype, bounds: layout.Rect, color: u32) !void {
    // Seven bounded strips avoid a separate backend-specific drawing primitive.
    const edges = [_]f32{ 0.28, 0.12, 0.03, 0, 0.03, 0.12, 0.28 };
    for (edges, 0..) |edge, i| try fill(frame, .{ .x = bounds.x + bounds.width * edge, .y = bounds.y + bounds.height * @as(f32, @floatFromInt(i)) / 7, .width = bounds.width * (1 - 2 * edge), .height = bounds.height / 7 }, color);
}

/// One transaction covers hit identity, copied semantics and paint commands.
/// The application owns all values; drawing never toggles or selects them.
pub fn emit(frame: anytype, kind: Kind, id: u64, bounds: layout.Rect, text: []const u8, checked: bool, fraction: f32, options: Options) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    if (!std.math.isFinite(fraction)) return error.InvalidProgress;
    const context = frame.context;
    const hit_length = context.input_state.checkpoint();
    const command_length = context.command_buffer.len;
    const text_length = context.command_buffer.text_len;
    const has_semantics = comptime @TypeOf(context.semantic_tree) != void;
    const semantic_length = if (has_semantics) context.semantic_tree.len else 0;
    const semantic_used = if (has_semantics) context.semantic_tree.used else 0;
    errdefer {
        context.input_state.rollback(hit_length);
        context.command_buffer.len = command_length;
        context.command_buffer.text_len = text_length;
        if (has_semantics) {
            context.semantic_tree.len = semantic_length;
            context.semantic_tree.used = semantic_used;
            if (context.semantic_tree.mapped) |snapshot| snapshot.semantic_len = semantic_length;
        }
    }
    const absolute_bounds = absolute(frame, bounds);
    const visible = if (frame.clipBounds()) |clip| layout.intersect(absolute_bounds, clip) else absolute_bounds;
    const interactive = kind != .progress;
    const chooses = kind == .radio or kind == .tab;
    try frame.addControl(id, bounds, .{ .enabled = options.enabled, .focusable = interactive, .pointer_enabled = interactive, .radio_group = if (chooses) options.radio_group else null, .selected = checked, .shortcut = options.shortcut });
    const focus = interactive and options.enabled and visible.width > 0 and visible.height > 0 and context.input_state.focused == id;
    const amount = std.math.clamp(fraction, 0, 1);
    try frame.semantic(.{
        .id = id,
        .parent = if (chooses) options.radio_group orelse options.semantic_parent else options.semantic_parent,
        .role = switch (kind) {
            .button => .button,
            .checkbox => .checkbox,
            .radio => .radio,
            .toggle_switch => .toggle_switch,
            .progress => .progress,
            .tab => .tab,
        },
        .name = if (kind == .progress) options.name else text,
        .bounds = bounds,
        .enabled = options.enabled,
        .focused = focus,
        .checked = checked,
        .read_only = kind == .progress,
        .range_value = amount * 100,
    });
    const style = frame.currentTheme();
    const colors = style.palette;
    const metrics = style.metrics;
    const border: u32 = if (!options.enabled) colors.disabled_border else if (focus) colors.focus else colors.border;
    const foreground: u32 = if (options.enabled) colors.text else colors.disabled_text;
    const accent: u32 = if (options.enabled) colors.accent else colors.disabled_accent;
    switch (kind) {
        .button => {
            try fill(frame, bounds, border);
            try fill(frame, inset(bounds, metrics.border), if (options.enabled and context.input_state.active == id) colors.pressed else colors.control);
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, foreground);
        },
        .progress => {
            try fill(frame, bounds, border);
            const inside = inset(bounds, metrics.border);
            try fill(frame, inside, colors.trough);
            try fill(frame, .{ .x = inside.x, .y = inside.y, .width = inside.width * amount, .height = inside.height }, accent);
        },
        .tab => {
            // The selected tab carries an accent bar along its bottom edge.
            if (checked) try fill(frame, bounds, colors.control);
            if (focus) try outline(frame, bounds, metrics.border, colors.focus);
            if (checked) {
                const bar = @min(bounds.height, 2 * metrics.border + 1);
                try fill(frame, .{ .x = bounds.x, .y = bounds.y + bounds.height - bar, .width = bounds.width, .height = bar }, accent);
            }
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, foreground);
        },
        else => {
            const side = @min(@min(bounds.height, bounds.width), metrics.indicator_size);
            const width = if (kind == .toggle_switch) @min(bounds.width, side * 1.7) else side;
            const mark: layout.Rect = .{ .x = bounds.x, .y = bounds.y + (bounds.height - side) / 2, .width = width, .height = side };
            if (kind == .radio) {
                try disk(frame, mark, border);
                try disk(frame, inset(mark, metrics.border), colors.inset);
                if (checked) try disk(frame, inset(mark, metrics.indicator_inset), accent);
            } else {
                try fill(frame, mark, border);
                try fill(frame, inset(mark, metrics.border), if (checked) accent else colors.inset);
                if (kind == .toggle_switch) {
                    const inner = inset(mark, metrics.border + 1);
                    const thumb = @min(inner.width, inner.height);
                    try fill(frame, .{ .x = if (checked) inner.x + inner.width - thumb else inner.x, .y = inner.y, .width = thumb, .height = inner.height }, if (checked) colors.on_accent else border);
                } else if (checked) try fill(frame, inset(mark, metrics.indicator_inset), colors.on_accent);
            }
            const label_x = @min(bounds.width, width + metrics.label_gap);
            try context.command_buffer.text(absolute(frame, .{ .x = bounds.x + label_x, .y = bounds.y, .width = bounds.width - label_x, .height = bounds.height }), text, foreground);
        },
    }
}

fn visibleBounds(frame: anytype, bounds: layout.Rect) layout.Rect {
    const result = absolute(frame, bounds);
    return if (frame.clipBounds()) |clip| layout.intersect(result, clip) else result;
}
fn valueFraction(spec: Range, value: f64) f32 {
    return if (spec.maximum > spec.minimum) @floatCast((value - spec.minimum) / (spec.maximum - spec.minimum)) else 0;
}
fn sliderTrack(bounds: layout.Rect, vertical: bool, thumb_size: f32) layout.Rect {
    const thumb = @min(thumb_size, @min(bounds.width, bounds.height));
    return if (vertical) .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + thumb / 2, .width = 0, .height = @max(0, bounds.height - thumb) } else .{ .x = bounds.x + thumb / 2, .y = bounds.y + bounds.height / 2, .width = @max(0, bounds.width - thumb), .height = 0 };
}
fn sliderPosition(track: layout.Rect, vertical: bool, amount: f32) f32 {
    return if (vertical) track.y + track.height * (1 - amount) else track.x + track.width * amount;
}
fn paintThumb(frame: anytype, bounds: layout.Rect, track: layout.Rect, vertical: bool, amount: f32, enabled: bool, focused: bool) !void {
    const style = frame.currentTheme();
    const colors = style.palette;
    const size = @min(style.metrics.thumb_size, @min(bounds.width, bounds.height));
    const at = sliderPosition(track, vertical, amount);
    const rect: layout.Rect = if (vertical) .{ .x = bounds.x + (bounds.width - size) / 2, .y = at - size / 2, .width = size, .height = size } else .{ .x = at - size / 2, .y = bounds.y + (bounds.height - size) / 2, .width = size, .height = size };
    try fill(frame, rect, if (!enabled) colors.disabled_accent else if (focused) colors.focused_thumb_border else colors.accent);
    try fill(frame, inset(rect, style.metrics.border + @as(f32, if (focused) 1 else 0)), if (enabled) colors.thumb else colors.disabled_thumb);
}
fn paintTrack(frame: anytype, bounds: layout.Rect, track: layout.Rect, vertical: bool, from: f32, to: f32, enabled: bool) !void {
    const style = frame.currentTheme();
    const colors = style.palette;
    const width = @min(style.metrics.track_width, if (vertical) bounds.width else bounds.height);
    if (vertical) {
        try fill(frame, .{ .x = track.x - width / 2, .y = track.y, .width = width, .height = track.height }, colors.track);
        try fill(frame, .{ .x = track.x - width / 2, .y = sliderPosition(track, true, to), .width = width, .height = track.height * (to - from) }, if (enabled) colors.accent else colors.disabled_accent);
    } else {
        try fill(frame, .{ .x = track.x, .y = track.y - width / 2, .width = track.width, .height = width }, colors.track);
        try fill(frame, .{ .x = sliderPosition(track, false, from), .y = track.y - width / 2, .width = track.width * (to - from), .height = width }, if (enabled) colors.accent else colors.disabled_accent);
    }
}
fn rangeRecord(frame: anytype, id: u64, bounds: layout.Rect, hit_bounds: layout.Rect, track: layout.Rect, value: f64, spec: Range, minimum: f64, maximum: f64, name: []const u8, options: Options, vertical: bool, role: access.Role) !void {
    const stepper = role == .stepper;
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const width = @min(bounds.width / 4, bounds.height);
    try frame.addControl(id, hit_bounds, .{ .enabled = options.enabled, .focus_rect = bounds, .range = .{ .spec = spec, .track = track, .vertical = vertical, .kind = switch (role) {
        .stepper => .stepper,
        .splitter => .splitter,
        else => .slider,
    }, .step_buttons = if (stepper) .{ .decrement = .{ .x = bounds.x, .y = bounds.y, .width = width, .height = bounds.height }, .increment = .{ .x = bounds.x + bounds.width - width, .y = bounds.y, .width = width, .height = bounds.height } } else null }, .shortcut = options.shortcut });
    const visible = visibleBounds(frame, bounds);
    try frame.semantic(.{ .id = id, .parent = options.semantic_parent, .role = role, .name = name, .bounds = bounds, .enabled = options.enabled, .focused = options.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id, .range_value = value, .range_minimum = minimum, .range_maximum = maximum, .range_small_change = spec.smallChange(), .range_large_change = spec.largeChange() });
}
pub fn emitSlider(frame: anytype, id: u64, bounds: layout.Rect, value: f64, spec: Range, options: RangeOptions) !void {
    if (frame.context.on_value == null) return error.MissingValueHandler;
    try spec.validate();
    try spec.validateValue(value);
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    const track = sliderTrack(bounds, options.vertical, frame.currentTheme().metrics.thumb_size);
    try rangeRecord(frame, id, bounds, bounds, track, value, spec, spec.minimum, spec.maximum, options.control.name, options.control, options.vertical, .slider);
    const amount = valueFraction(spec, value);
    try paintTrack(frame, bounds, track, options.vertical, 0, amount, options.control.enabled);
    try paintThumb(frame, bounds, track, options.vertical, amount, options.control.enabled, frame.context.input_state.focused == id);
}
pub fn emitRangeSlider(frame: anytype, ids: RangeSliderIds, bounds: layout.Rect, values: input.Values, spec: Range, options: RangeSliderOptions) !void {
    if (frame.context.on_value == null) return error.MissingValueHandler;
    try spec.validate();
    try spec.validateValue(values.low);
    try spec.validateValue(values.high);
    if (values.low > values.high) return error.InvalidValue;
    if (ids.group == 0 or ids.low == 0 or ids.high == 0) return error.ReservedControlId;
    if (ids.group == ids.low or ids.group == ids.high or ids.low == ids.high) return error.DuplicateId;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.semantic(.{ .id = ids.group, .role = .group, .name = options.name, .bounds = bounds });
    const track = sliderTrack(bounds, options.vertical, frame.currentTheme().metrics.thumb_size);
    const low = valueFraction(spec, values.low);
    const high = valueFraction(spec, values.high);
    const split = sliderPosition(track, options.vertical, (low + high) / 2);
    const low_hit: layout.Rect = if (options.vertical) .{ .x = bounds.x, .y = split, .width = bounds.width, .height = @max(0, bounds.y + bounds.height - split) } else .{ .x = bounds.x, .y = bounds.y, .width = @max(0, split - bounds.x), .height = bounds.height };
    const high_hit: layout.Rect = if (options.vertical) .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = @max(0, split - bounds.y) } else .{ .x = split, .y = bounds.y, .width = @max(0, bounds.x + bounds.width - split), .height = bounds.height };
    var low_options = options.low;
    var high_options = options.high;
    low_options.semantic_parent = ids.group;
    high_options.semantic_parent = ids.group;
    try rangeRecord(frame, ids.low, bounds, low_hit, track, values.low, spec, spec.minimum, values.high, options.low_name, low_options, options.vertical, .slider);
    try rangeRecord(frame, ids.high, bounds, high_hit, track, values.high, spec, values.low, spec.maximum, options.high_name, high_options, options.vertical, .slider);
    try paintTrack(frame, bounds, track, options.vertical, low, high, options.low.enabled or options.high.enabled);
    try paintThumb(frame, bounds, track, options.vertical, low, options.low.enabled, frame.context.input_state.focused == ids.low);
    try paintThumb(frame, bounds, track, options.vertical, high, options.high.enabled, frame.context.input_state.focused == ids.high);
}
pub fn emitStepper(frame: anytype, id: u64, bounds: layout.Rect, value: f64, spec: Range, options: Options) !void {
    if (frame.context.on_value == null) return error.MissingValueHandler;
    try spec.validate();
    try spec.validateValue(value);
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try rangeRecord(frame, id, bounds, bounds, bounds, value, spec, spec.minimum, spec.maximum, options.name, options, false, .stepper);
    const style = frame.currentTheme();
    const colors = style.palette;
    try fill(frame, bounds, if (frame.context.input_state.focused == id and options.enabled) colors.focus else colors.disabled_border);
    try fill(frame, inset(bounds, style.metrics.border), colors.field);
    const width = @min(bounds.width / 4, bounds.height);
    const color: u32 = if (options.enabled) colors.text else colors.disabled_text;
    try frame.context.command_buffer.text(absolute(frame, .{ .x = bounds.x, .y = bounds.y, .width = width, .height = bounds.height }), "−", if (value <= spec.minimum) colors.disabled_accent else color);
    try frame.context.command_buffer.text(absolute(frame, .{ .x = bounds.x + bounds.width - width, .y = bounds.y, .width = width, .height = bounds.height }), "+", if (value >= spec.maximum) colors.disabled_accent else color);
    var storage: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&storage, "{d}", .{value}) catch try std.fmt.bufPrint(&storage, "{e}", .{value});
    try frame.context.command_buffer.text(absolute(frame, .{ .x = bounds.x + width, .y = bounds.y, .width = @max(0, bounds.width - 2 * width), .height = bounds.height }), text, color);
}

/// A draggable divider between two panes of `bounds`. `value` is the first
/// pane's share of the length left after the divider, within `spec`, which
/// lies in 0..1; `divider` is the strip that takes pointer input.
/// A vertical splitter divides top from bottom and grows downward.
pub fn emitSplitter(frame: anytype, id: u64, bounds: layout.Rect, divider: layout.Rect, value: f64, spec: Range, options: SplitterOptions) !void {
    if (frame.context.on_value == null) return error.MissingValueHandler;
    try spec.validate();
    if (spec.minimum < 0 or spec.maximum > 1) return error.InvalidRange;
    try spec.validateValue(value);
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    // The track spans the divider centre's positions from the minimum to
    // the maximum share, so a drag keeps the divider under the pointer.
    const extent = @max(0, if (options.vertical) bounds.height - divider.height else bounds.width - divider.width);
    const start = extent * @as(f32, @floatCast(spec.minimum));
    const length = extent * @as(f32, @floatCast(spec.maximum - spec.minimum));
    const track: layout.Rect = if (options.vertical) .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + divider.height / 2 + start, .width = 0, .height = length } else .{ .x = bounds.x + divider.width / 2 + start, .y = bounds.y + bounds.height / 2, .width = length, .height = 0 };
    try rangeRecord(frame, id, divider, divider, track, value, spec, spec.minimum, spec.maximum, options.control.name, options.control, options.vertical, .splitter);
    const style = frame.currentTheme();
    const colors = style.palette;
    const focused = options.control.enabled and frame.context.input_state.focused == id;
    const line = if (focused) 2 * style.metrics.border else style.metrics.border;
    const color: u32 = if (!options.control.enabled) colors.disabled_border else if (focused) colors.focus else colors.border;
    try fill(frame, if (options.vertical) .{ .x = divider.x, .y = divider.y + (divider.height - line) / 2, .width = divider.width, .height = @min(line, divider.height) } else .{ .x = divider.x + (divider.width - line) / 2, .y = divider.y, .width = @min(line, divider.width), .height = divider.height }, color);
}
