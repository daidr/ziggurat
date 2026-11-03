const std = @import("std");
const layout = @import("layout.zig");
const access = @import("accessibility.zig");
const input = @import("input.zig");
const drawing = @import("ziggurat_drawing_resources");
const commands = @import("commands.zig");
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
    /// Help or error text announced with the control, such as a form
    /// field's hint; it is not drawn.
    description: []const u8 = "",
    /// The value fails the application's validation.
    invalid: bool = false,
    /// A form needs a value before it can be submitted.
    required: bool = false,
    /// A checkbox is partly checked: it is drawn with a dash and reports
    /// the indeterminate toggle state. `checked` is then false.
    mixed: bool = false,
    /// The font of a link's text; null is the interface font.
    font: ?commands.Font = null,
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
/// A meter's preferred band; a value below `low` or above `high` is drawn
/// with the caution color. Both bounds lie within the meter's range.
pub const MeterBands = struct {
    low: ?f64 = null,
    high: ?f64 = null,
    pub fn validate(self: MeterBands, spec: Range) error{InvalidRange}!void {
        inline for (.{ self.low, self.high }) |bound| if (bound) |value| if (!std.math.isFinite(value) or value < spec.minimum or value > spec.maximum) return error.InvalidRange;
        if (self.low != null and self.high != null and self.low.? > self.high.?) return error.InvalidRange;
    }
    pub fn contains(self: MeterBands, value: f64) bool {
        return !(if (self.low) |low| value < low else false) and !(if (self.high) |high| value > high else false);
    }
};
pub const MeterOptions = struct { control: Options = .{}, bands: MeterBands = .{} };
/// Most marks a rating offers.
pub const max_rating = 10;
pub const Kind = enum { button, checkbox, radio, toggle_switch, progress, tab, segment, link, disclosure, list_item, combo_box, nav_button, label_button };
/// Where a navigation button's chevron points.
pub const NavDirection = enum { back, forward, up, down };
pub const AvatarOptions = struct {
    /// Picture drawn instead of the initials, cropped to fill the bounds.
    image: ?drawing.ImageView = null,
    /// Fill behind the initials; derived from the name when null.
    color: ?u32 = null,
    semantic_parent: u64 = access.root_id,
};
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
/// A filled triangle pointing right, or down when `down`, from bounded strips.
fn triangle(frame: anytype, bounds: layout.Rect, down: bool, color: u32) !void {
    try chevron(frame, bounds, if (down) .down else .forward, color);
}
/// A filled triangle pointing along `direction`, from bounded strips.
fn chevron(frame: anytype, bounds: layout.Rect, direction: NavDirection, color: u32) !void {
    const strips: f32 = 6;
    for (0..6) |i| {
        const t = @as(f32, @floatFromInt(i)) / strips;
        const shrink = 0.5 * t;
        switch (direction) {
            .down => try fill(frame, .{ .x = bounds.x + bounds.width * shrink, .y = bounds.y + bounds.height * t, .width = bounds.width * (1 - 2 * shrink), .height = bounds.height / strips }, color),
            .up => try fill(frame, .{ .x = bounds.x + bounds.width * shrink, .y = bounds.y + bounds.height * (1 - t - 1 / strips), .width = bounds.width * (1 - 2 * shrink), .height = bounds.height / strips }, color),
            .forward => try fill(frame, .{ .x = bounds.x + bounds.width * t, .y = bounds.y + bounds.height * shrink, .width = bounds.width / strips, .height = bounds.height * (1 - 2 * shrink) }, color),
            .back => try fill(frame, .{ .x = bounds.x + bounds.width * (1 - t - 1 / strips), .y = bounds.y + bounds.height * shrink, .width = bounds.width / strips, .height = bounds.height * (1 - 2 * shrink) }, color),
        }
    }
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
    const combo = kind == .combo_box;
    const chooses = kind == .radio or kind == .tab or kind == .segment or kind == .list_item;
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
            .segment => .radio,
            .link => .link,
            .disclosure => .disclosure,
            .list_item => .list_item,
            .combo_box => .combo_box,
            .nav_button, .label_button => .button,
        },
        // A combo box is named by its label and reports the choice as its value.
        .name = if (kind == .progress or combo) options.name else text,
        .value = if (combo) text else "",
        .description = options.description,
        .bounds = bounds,
        .enabled = options.enabled,
        .focused = focus,
        .checked = checked,
        .mixed = kind == .checkbox and options.mixed,
        .invalid = options.invalid,
        .required = options.required,
        .read_only = kind == .progress or combo,
        .range_value = amount * 100,
    });
    const style = frame.currentTheme();
    const colors = style.palette;
    const metrics = style.metrics;
    const border: u32 = if (!options.enabled) colors.disabled_border else if (focus) colors.focus else colors.border;
    const foreground: u32 = if (options.enabled) colors.text else colors.disabled_text;
    const accent: u32 = if (options.enabled) colors.accent else colors.disabled_accent;
    switch (kind) {
        .button, .nav_button => {
            try fill(frame, bounds, border);
            try fill(frame, inset(bounds, metrics.border), if (options.enabled and context.input_state.active == id) colors.pressed else colors.control);
            // A navigation button carries a chevron its caller draws, not its name.
            if (kind == .nav_button) return;
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, foreground);
        },
        .progress => {
            try fill(frame, bounds, border);
            const inside = inset(bounds, metrics.border);
            try fill(frame, inside, colors.trough);
            try fill(frame, .{ .x = inside.x, .y = inside.y, .width = inside.width * amount, .height = inside.height }, accent);
        },
        .segment => {
            // Segments are joined buttons; the selected one is filled with the accent.
            try fill(frame, bounds, border);
            try fill(frame, inset(bounds, metrics.border), if (checked) accent else if (options.enabled and context.input_state.active == id) colors.pressed else colors.control);
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, if (checked and options.enabled) colors.on_accent else foreground);
        },
        .label_button => {
            // Plain text that acts as a button, such as a label that turns
            // into a text field when activated.
            if (options.enabled and context.input_state.active == id) try fill(frame, bounds, colors.pressed);
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, foreground);
            if (focus) try outline(frame, bounds, metrics.border, colors.focus);
        },
        .link => {
            const color: u32 = if (options.enabled) colors.accent else colors.disabled_text;
            const label = inset(bounds, metrics.content_inset);
            if (options.font) |font| try context.command_buffer.textFont(absolute(frame, label), text, color, font) else try context.command_buffer.text(absolute(frame, label), text, color);
            try fill(frame, .{ .x = label.x, .y = label.y + label.height - metrics.border, .width = label.width, .height = metrics.border }, color);
            if (focus) try outline(frame, bounds, metrics.border, colors.focus);
        },
        .disclosure => {
            const side = @min(@min(bounds.height, bounds.width), metrics.indicator_size);
            const mark: layout.Rect = .{ .x = bounds.x, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
            try triangle(frame, inset(mark, side / 4), checked, foreground);
            const label_x = @min(bounds.width, side + metrics.label_gap);
            try context.command_buffer.text(absolute(frame, .{ .x = bounds.x + label_x, .y = bounds.y, .width = bounds.width - label_x, .height = bounds.height }), text, foreground);
            if (focus) try outline(frame, bounds, metrics.border, colors.focus);
        },
        .list_item => {
            // A full-width row; the selected one is filled with the accent.
            if (checked) try fill(frame, bounds, accent) else if (options.enabled and context.input_state.active == id) try fill(frame, bounds, colors.pressed);
            if (focus) try outline(frame, bounds, metrics.border, if (checked) colors.on_accent else colors.focus);
            try context.command_buffer.text(absolute(frame, inset(bounds, metrics.content_inset)), text, if (checked and options.enabled) colors.on_accent else foreground);
        },
        .combo_box => {
            // A field showing the current choice with a chevron that points
            // down while closed and up while the list is open.
            try fill(frame, bounds, border);
            try fill(frame, inset(bounds, metrics.border), colors.field);
            const side = @min(bounds.height, metrics.indicator_size);
            const mark: layout.Rect = .{ .x = bounds.x + @max(0, bounds.width - side - metrics.content_inset / 2), .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
            try chevron(frame, inset(mark, side / 3), if (checked) .up else .down, foreground);
            const label = inset(bounds, metrics.content_inset);
            try context.command_buffer.text(absolute(frame, .{ .x = label.x, .y = label.y, .width = @max(0, mark.x - label.x), .height = label.height }), text, foreground);
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
                const mixed = kind == .checkbox and options.mixed and !checked;
                try fill(frame, inset(mark, metrics.border), if (checked or mixed) accent else colors.inset);
                if (mixed) {
                    const inner = inset(mark, metrics.indicator_inset);
                    const bar = @min(inner.height, 2 * metrics.border + 1);
                    try fill(frame, .{ .x = inner.x, .y = inner.y + (inner.height - bar) / 2, .width = inner.width, .height = bar }, colors.on_accent);
                } else if (kind == .toggle_switch) {
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
    try frame.semantic(.{ .id = id, .parent = options.semantic_parent, .role = role, .name = name, .description = options.description, .invalid = options.invalid, .required = options.required, .bounds = bounds, .enabled = options.enabled, .focused = options.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id, .range_value = value, .range_minimum = minimum, .range_maximum = maximum, .range_small_change = spec.smallChange(), .range_large_change = spec.largeChange() });
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

/// A read-only measurement within a known range, such as disk usage. Unlike
/// progress it reports the value itself, not completion.
pub fn emitMeter(frame: anytype, id: u64, bounds: layout.Rect, value: f64, spec: Range, options: MeterOptions) !void {
    if (id == access.root_id) return error.ReservedControlId;
    try spec.validate();
    try spec.validateValue(value);
    try options.bands.validate(spec);
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.semantic(.{ .id = id, .parent = options.control.semantic_parent, .role = .meter, .name = options.control.name, .description = options.control.description, .bounds = bounds, .enabled = options.control.enabled, .read_only = true, .range_value = value, .range_minimum = spec.minimum, .range_maximum = spec.maximum });
    const style = frame.currentTheme();
    const colors = style.palette;
    try fill(frame, bounds, if (options.control.enabled) colors.border else colors.disabled_border);
    const inside = inset(bounds, style.metrics.border);
    try fill(frame, inside, colors.trough);
    const color: u32 = if (!options.control.enabled) colors.disabled_accent else if (options.bands.contains(value)) colors.accent else colors.caution;
    try fill(frame, .{ .x = inside.x, .y = inside.y, .width = inside.width * valueFraction(spec, value), .height = inside.height }, color);
}

/// Square cells of a rating with `count` marks, left to right.
pub fn ratingMark(bounds: layout.Rect, count: u8, index: usize) layout.Rect {
    const side = @min(bounds.height, bounds.width / @as(f32, @floatFromInt(@max(1, count))));
    return .{ .x = bounds.x + side * @as(f32, @floatFromInt(index)), .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
}
/// A row of `count` marks for a whole-number score from 0 to `count`.
/// Pressing or dragging over a mark sets the score to that mark; arrow keys
/// step it and Home clears it. Announced as a slider.
pub fn emitRating(frame: anytype, id: u64, bounds: layout.Rect, value: f64, count: u8, options: Options) !void {
    if (frame.context.on_value == null) return error.MissingValueHandler;
    if (count == 0 or count > max_rating) return error.InvalidRange;
    const spec: Range = .{ .minimum = 0, .maximum = @floatFromInt(count), .step = 1 };
    try spec.validateValue(value);
    if (value != @round(value)) return error.InvalidValue;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    // Mark k covers the values that round to k, so the track starts half a
    // mark before the first one.
    const side = ratingMark(bounds, count, 0).width;
    const track: layout.Rect = .{ .x = bounds.x - side / 2, .y = bounds.y + bounds.height / 2, .width = side * @as(f32, @floatFromInt(count)), .height = 0 };
    try rangeRecord(frame, id, bounds, bounds, track, value, spec, spec.minimum, spec.maximum, options.name, options, false, .slider);
    const style = frame.currentTheme();
    const colors = style.palette;
    const focused = options.enabled and frame.context.input_state.focused == id;
    for (0..count) |index| {
        const mark = inset(ratingMark(bounds, count, index), 2);
        const filled = @as(f64, @floatFromInt(index)) < value;
        try disk(frame, mark, if (!options.enabled) colors.disabled_border else if (filled) colors.accent else colors.border);
        if (!filled) try disk(frame, inset(mark, style.metrics.border), colors.inset);
    }
    if (focused) try outline(frame, bounds, style.metrics.border, colors.focus);
}

/// A button whose chevron points along `direction`, named `name`.
pub fn emitNavButton(frame: anytype, id: u64, bounds: layout.Rect, direction: NavDirection, name: []const u8, options: Options) !void {
    const before = Snapshot.init(frame);
    errdefer before.restore(frame);
    try emit(frame, .nav_button, id, bounds, name, false, 0, options);
    const style = frame.currentTheme();
    const side = @min(@min(bounds.width, bounds.height) - 2 * style.metrics.content_inset, style.metrics.indicator_size);
    if (side <= 0) return;
    const mark: layout.Rect = .{ .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
    try chevron(frame, inset(mark, side / 6), direction, if (options.enabled) style.palette.text else style.palette.disabled_text);
}

/// Up to two initials: the first letter of the first two words, ASCII
/// letters uppercased. Writes into `out` and returns the used part.
pub fn initials(name: []const u8, out: *[8]u8) []const u8 {
    var len: usize = 0;
    var words: usize = 0;
    var start = true;
    var view = std.unicode.Utf8View.init(name) catch return out[0..0];
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const blank = slice.len == 1 and std.ascii.isWhitespace(slice[0]);
        if (blank) {
            start = true;
            continue;
        }
        if (!start) continue;
        start = false;
        if (words == 2 or len + slice.len > out.len) break;
        @memcpy(out[len..][0..slice.len], slice);
        if (slice.len == 1) out[len] = std.ascii.toUpper(out[len]);
        len += slice.len;
        words += 1;
    }
    return out[0..len];
}

/// A stable fill for an avatar without its own color.
pub fn avatarColor(name: []const u8) u32 {
    const colors = [_]u32{ 0x276aa5, 0x2e7d4f, 0x8e44ad, 0xa8530f, 0x00796b, 0xb03a5b, 0x5d6d7e, 0x6d4c41 };
    return colors[std.hash.Wyhash.hash(0x61_76, name) % colors.len];
}

/// A person or entity shown as a picture, or as initials on a disk. It is
/// an image to accessibility clients, named `name`, and takes no input.
pub fn emitAvatar(frame: anytype, id: u64, bounds: layout.Rect, name: []const u8, options: AvatarOptions) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.semantic(.{ .id = id, .parent = options.semantic_parent, .role = .image, .name = name, .bounds = bounds, .read_only = true });
    if (options.image) |picture| return frame.image(bounds, picture, .{ .fit = .cover });
    const colors = frame.currentTheme().palette;
    try disk(frame, bounds, options.color orelse avatarColor(name));
    var storage: [8]u8 = undefined;
    const letters = initials(name, &storage);
    if (letters.len == 0) return;
    // The fixed label font is 16px; centre the estimated run within the disk.
    var width: f32 = 0;
    var view = std.unicode.Utf8View.init(letters) catch unreachable;
    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| width += if (codepoint >= 0x1100) 16 else 10;
    const text: layout.Rect = .{ .x = bounds.x + @max(0, (bounds.width - width) / 2), .y = bounds.y + @max(0, (bounds.height - 22) / 2), .width = @min(width, bounds.width), .height = @min(22, bounds.height) };
    try frame.context.command_buffer.text(absolute(frame, text), letters, colors.on_accent);
}

/// A short hint shown near the control it describes. It takes no input
/// and is announced as a tooltip while drawn.
pub fn emitTooltip(frame: anytype, id: u64, bounds: layout.Rect, text: []const u8) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.semantic(.{ .id = id, .role = .tooltip, .name = text, .bounds = bounds, .read_only = true });
    const style = frame.currentTheme();
    try fill(frame, bounds, style.palette.text);
    try frame.context.command_buffer.text(absolute(frame, inset(bounds, tooltip_inset)), text, style.palette.background);
}
/// Space between a tooltip's edge and its text.
pub const tooltip_inset: f32 = 4;

/// Indentation of each tree level, in DIP.
pub const tree_indent: f32 = 16;
/// How an accessibility client changes a multiple-selection item or a tree
/// item's expansion. It arrives as `ValueChange.set` on the item's id,
/// because ordinary activation already means "select only this one".
pub const ItemRequest = enum(u8) { deselect = 0, add = 1, collapse = 2, expand = 3 };
/// One row of a tree or table. The collection's id goes in
/// `control.radio_group`, so its rows share one Tab stop on the row that has
/// the keyboard cursor.
pub const RowOptions = struct {
    control: Options = .{},
    /// Member of the selection.
    selected: bool = false,
    /// Holds the collection's keyboard cursor.
    cursor: bool = false,
    /// The collection lets several rows be selected at once.
    multiple: bool = false,
    /// Depth of a tree row, from 0.
    level: u16 = 0,
    /// A tree row's expansion; null for a leaf.
    expanded: ?bool = null,
    /// Room after the expander and before the label for an icon the
    /// caller draws, in DIP.
    lead: f32 = 0,
    /// Room at the end of the row for a count or badge the caller draws.
    trail: f32 = 0,
    /// A section heading: its label is drawn muted.
    heading: bool = false,
};
pub const SortDirection = enum { ascending, descending };
/// What marks a menu item: none, a check box's check or a radio's dot.
pub const MenuMark = enum { none, check, radio };
pub const MenuItemOptions = struct {
    control: Options = .{},
    mark: MenuMark = .none,
    /// A check box item is checked, or a radio item is the one chosen.
    checked: bool = false,
    /// Whether the submenu of an item that opens one shows; null for an
    /// item without one.
    expanded: ?bool = null,
    /// Drawn with the accent behind it, as the keys or the pointer are on it.
    highlighted: bool = false,
    /// The shortcut shown at the end of the item, which is also announced
    /// as its description, and its width in DIP.
    shortcut: []const u8 = "",
    shortcut_width: f32 = 0,
    /// Right to left: the mark at the right, the shortcut and the submenu
    /// arrow at the left.
    rtl: bool = false,
};
/// Room a menu item keeps for its mark, and for its submenu arrow.
pub const menu_mark_width: f32 = 20;

/// One item of a menu drawn in the window: a mark when checked, its label,
/// the shortcut at its end and an arrow when it opens a submenu. A
/// focusable control announced as a menu item, a check box item or a radio
/// item; the caller moves the highlight and the focus with it, and the
/// highlight is what shows where the keys are.
pub fn emitMenuItem(frame: anytype, id: u64, bounds: layout.Rect, label: []const u8, options: MenuItemOptions) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    const control = options.control;
    try frame.addControl(id, bounds, .{ .enabled = control.enabled, .shortcut = control.shortcut });
    const visible = visibleBounds(frame, bounds);
    const focused = control.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id;
    try frame.semantic(.{
        .id = id,
        .parent = control.semantic_parent,
        .role = switch (options.mark) {
            .none => .menu_item,
            .check => .menu_item_checkbox,
            .radio => .menu_item_radio,
        },
        .name = label,
        .description = if (control.description.len > 0) control.description else options.shortcut,
        .bounds = bounds,
        .enabled = control.enabled,
        .focused = focused,
        .checked = options.mark != .none and options.checked,
        .expanded = options.expanded,
    });
    const style = frame.currentTheme();
    const colors = style.palette;
    const metrics = style.metrics;
    const lit = options.highlighted and control.enabled;
    if (lit) try fill(frame, bounds, colors.accent);
    const foreground: u32 = if (!control.enabled) colors.disabled_text else if (lit) colors.on_accent else colors.text;
    const muted: u32 = if (lit) colors.on_accent else colors.disabled_text;
    const pad = metrics.content_inset;
    const height = bounds.height;
    const start_edge = if (options.rtl) bounds.x + bounds.width - pad - menu_mark_width else bounds.x + pad;
    const mark: layout.Rect = .{ .x = start_edge, .y = bounds.y, .width = menu_mark_width, .height = height };
    if (options.checked) switch (options.mark) {
        .none => {},
        .check => try frame.context.command_buffer.text(absolute(frame, .{ .x = mark.x + 3, .y = mark.y, .width = mark.width - 3, .height = mark.height }), "\u{2713}", foreground),
        .radio => {
            const side = @min(menu_mark_width, height) * 0.35;
            try disk(frame, .{ .x = mark.x + (mark.width - side) / 2, .y = mark.y + (height - side) / 2, .width = side, .height = side }, foreground);
        },
    };
    const arrow_room: f32 = if (options.expanded != null) menu_mark_width else 0;
    const trailing = arrow_room + (if (options.shortcut.len > 0) options.shortcut_width + metrics.label_gap else 0);
    const label_width = @max(0, bounds.width - 2 * pad - menu_mark_width - metrics.label_gap / 2 - trailing);
    const label_x = if (options.rtl) mark.x - metrics.label_gap / 2 - label_width else mark.x + menu_mark_width + metrics.label_gap / 2;
    try frame.context.command_buffer.text(absolute(frame, .{ .x = label_x, .y = bounds.y, .width = label_width, .height = height }), label, foreground);
    const end_edge = if (options.rtl) bounds.x + pad else bounds.x + bounds.width - pad;
    if (options.shortcut.len > 0) {
        const x = if (options.rtl) end_edge + arrow_room else end_edge - arrow_room - options.shortcut_width;
        try frame.context.command_buffer.text(absolute(frame, .{ .x = x, .y = bounds.y, .width = options.shortcut_width + 1, .height = height }), options.shortcut, muted);
    }
    if (options.expanded != null) {
        const side = @min(menu_mark_width, height) * 0.45;
        const x = if (options.rtl) end_edge + (arrow_room - side) / 2 else end_edge - arrow_room + (arrow_room - side) / 2;
        try chevron(frame, .{ .x = x, .y = bounds.y + (height - side) / 2, .width = side * 0.6, .height = side }, if (options.rtl) .back else .forward, if (control.enabled) muted else colors.disabled_text);
    }
}
pub const TokenOptions = struct {
    control: Options = .{},
    /// Accessible name of the remove button.
    remove_name: []const u8 = "Remove",
};

/// The disclosure triangle of a tree row at `level`; pressing it expands
/// or collapses the row without changing the selection.
pub fn treeExpander(bounds: layout.Rect, level: u16, indicator: f32) layout.Rect {
    const side = @min(bounds.height, indicator);
    const x = bounds.x + tree_indent * @as(f32, @floatFromInt(level));
    return .{ .x = x, .y = bounds.y + (bounds.height - side) / 2, .width = @max(0, @min(side, bounds.x + bounds.width - x)), .height = side };
}

fn rowRecord(frame: anytype, role: access.Role, id: u64, bounds: layout.Rect, name: []const u8, options: RowOptions) !bool {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const control = options.control;
    // The cursor row is the group's one selected peer, so Tab lands on it.
    try frame.addControl(id, bounds, .{ .enabled = control.enabled, .radio_group = control.radio_group, .selected = options.cursor, .shortcut = control.shortcut });
    const visible = visibleBounds(frame, bounds);
    const focused = control.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id;
    try frame.semantic(.{ .id = id, .parent = control.semantic_parent, .role = role, .name = name, .description = control.description, .bounds = bounds, .enabled = control.enabled, .focused = focused, .checked = options.selected, .multiple = options.multiple, .expanded = options.expanded });
    const colors = frame.currentTheme().palette;
    if (options.selected) try fill(frame, bounds, if (control.enabled) colors.accent else colors.disabled_accent) else if (control.enabled and frame.context.input_state.active == id) try fill(frame, bounds, colors.pressed);
    if (focused) try outline(frame, bounds, frame.currentTheme().metrics.border, if (options.selected) colors.on_accent else colors.focus);
    return focused;
}

/// A tree row: an indented label after a disclosure triangle when it has
/// children. Announced as a tree item, selected while `options.selected`,
/// expandable unless `options.expanded` is null.
pub fn emitTreeItem(frame: anytype, id: u64, bounds: layout.Rect, label: []const u8, options: RowOptions) !void {
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    _ = try rowRecord(frame, .tree_item, id, bounds, label, options);
    const style = frame.currentTheme();
    const colors = style.palette;
    const foreground: u32 = if (!options.control.enabled or (options.heading and !options.selected)) colors.disabled_text else if (options.selected) colors.on_accent else colors.text;
    const mark = treeExpander(bounds, options.level, style.metrics.indicator_size);
    if (options.expanded) |open| if (mark.width > 0) try triangle(frame, inset(mark, mark.height / 4), open, foreground);
    const label_x = @min(bounds.width, mark.x - bounds.x + mark.height + style.metrics.label_gap / 2 + @max(0, options.lead));
    const label_width = @max(0, bounds.width - label_x - @max(0, options.trail));
    try frame.context.command_buffer.text(absolute(frame, .{ .x = bounds.x + label_x, .y = bounds.y, .width = label_width, .height = bounds.height }), label, foreground);
}

/// The background, hit target and semantics of a table row; its cells are
/// recorded after it and draw over it. Named by `name`.
pub fn emitTableRow(frame: anytype, id: u64, bounds: layout.Rect, name: []const u8, options: RowOptions) !void {
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    _ = try rowRecord(frame, .table_row, id, bounds, name, options);
}

/// A column title that sorts its table on activation, with a chevron for
/// the current sort direction, announced as item status. A column that does
/// not sort takes no input. The header row paints the background.
pub fn emitColumnHeader(frame: anytype, id: u64, bounds: layout.Rect, title: []const u8, sort: ?SortDirection, sortable: bool, options: Options) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.addControl(id, bounds, .{ .enabled = options.enabled, .focusable = sortable, .pointer_enabled = sortable, .shortcut = if (sortable) options.shortcut else null });
    const visible = visibleBounds(frame, bounds);
    const focused = sortable and options.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id;
    try frame.semantic(.{ .id = id, .parent = options.semantic_parent, .role = .column_header, .name = title, .value = if (sort) |direction| @tagName(direction) else "", .description = options.description, .bounds = bounds, .enabled = options.enabled, .focused = focused, .read_only = true });
    const style = frame.currentTheme();
    const colors = style.palette;
    if (sortable and options.enabled and frame.context.input_state.active == id) try fill(frame, bounds, colors.pressed);
    const foreground: u32 = if (options.enabled) colors.text else colors.disabled_text;
    const side = @min(bounds.height, style.metrics.indicator_size) / 2;
    const mark: layout.Rect = .{ .x = bounds.x + @max(0, bounds.width - side), .y = bounds.y + (bounds.height - side) / 2, .width = @min(side, bounds.width), .height = side };
    if (sort) |direction| try chevron(frame, mark, if (direction == .ascending) .up else .down, foreground);
    const label_width = @max(0, (if (sort != null) mark.x - style.metrics.content_inset / 2 else bounds.x + bounds.width) - bounds.x);
    try frame.context.command_buffer.text(absolute(frame, .{ .x = bounds.x, .y = bounds.y, .width = label_width, .height = bounds.height }), title, foreground);
    if (focused) try outline(frame, bounds, style.metrics.border, colors.focus);
}

/// Width of a token's remove button, in DIP.
pub fn tokenRemoveWidth(bounds: layout.Rect) f32 {
    return @min(bounds.width / 2, bounds.height);
}
/// A token of a token field: a rounded chip with its label and a remove
/// button `remove_id` at its end. The chip takes focus and is announced as
/// a token; the button removes it.
pub fn emitToken(frame: anytype, id: u64, remove_id: u64, bounds: layout.Rect, label: []const u8, options: TokenOptions) !void {
    if (id == access.root_id or remove_id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    const control = options.control;
    const button_width = tokenRemoveWidth(bounds);
    const button: layout.Rect = .{ .x = bounds.x + bounds.width - button_width, .y = bounds.y, .width = button_width, .height = bounds.height };
    try frame.addControl(id, bounds, .{ .enabled = control.enabled, .radio_group = control.radio_group });
    // The remove button lies over the chip and takes presses first; it is
    // not a Tab stop of its own.
    try frame.addControl(remove_id, button, .{ .enabled = control.enabled, .focusable = false });
    const visible = visibleBounds(frame, bounds);
    const focused = control.enabled and visible.width > 0 and visible.height > 0 and frame.context.input_state.focused == id;
    try frame.semantic(.{ .id = id, .parent = control.semantic_parent, .role = .token, .name = label, .description = control.description, .bounds = bounds, .enabled = control.enabled, .focused = focused, .read_only = true });
    try frame.semantic(.{ .id = remove_id, .parent = id, .role = .button, .name = options.remove_name, .bounds = button, .enabled = control.enabled });
    const style = frame.currentTheme();
    const colors = style.palette;
    try fill(frame, bounds, if (focused) colors.focus else colors.border);
    try fill(frame, inset(bounds, style.metrics.border / 2), if (control.enabled and frame.context.input_state.active == remove_id) colors.pressed else colors.control);
    const foreground: u32 = if (control.enabled) colors.text else colors.disabled_text;
    const text = inset(.{ .x = bounds.x, .y = bounds.y, .width = @max(0, bounds.width - button_width), .height = bounds.height }, style.metrics.content_inset / 2);
    try frame.context.command_buffer.text(absolute(frame, .{ .x = text.x + style.metrics.content_inset / 2, .y = text.y, .width = @max(0, text.width - style.metrics.content_inset / 2), .height = text.height }), label, foreground);
    // A small cross from two bounded strips.
    const cross = inset(button, button.height * 0.32);
    const strips: usize = 5;
    for (0..strips) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(strips));
        const d = cross.width / @as(f32, @floatFromInt(strips));
        try fill(frame, .{ .x = cross.x + cross.width * t, .y = cross.y + cross.height * t, .width = d, .height = d }, foreground);
        try fill(frame, .{ .x = cross.x + cross.width * (1 - t) - d, .y = cross.y + cross.height * t, .width = d, .height = d }, foreground);
    }
}

/// The button at the end of an editable combo box that opens or closes its
/// list. It takes presses but not focus, which stays in the text input.
pub fn emitComboToggle(frame: anytype, id: u64, bounds: layout.Rect, expanded: bool, options: Options) !void {
    if (id == access.root_id) return error.ReservedControlId;
    if (!layout.validRect(bounds) or !layout.validRect(absolute(frame, bounds))) return error.InvalidGeometry;
    const snapshot = Snapshot.init(frame);
    errdefer snapshot.restore(frame);
    try frame.addControl(id, bounds, .{ .enabled = options.enabled, .focusable = false });
    try frame.semantic(.{ .id = id, .parent = options.semantic_parent, .role = .button, .name = options.name, .bounds = bounds, .enabled = options.enabled });
    const style = frame.currentTheme();
    const colors = style.palette;
    if (options.enabled and frame.context.input_state.active == id) try fill(frame, bounds, colors.pressed);
    const side = @min(bounds.height, bounds.width, style.metrics.indicator_size);
    const mark: layout.Rect = .{ .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .width = side, .height = side };
    try chevron(frame, inset(mark, side / 3), if (expanded) .up else .down, if (options.enabled) colors.text else colors.disabled_text);
}

test "initials take the first letter of two words" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("AL", initials("ada lovelace", &out));
    try std.testing.expectEqualStrings("G", initials("  grace ", &out));
    try std.testing.expectEqualStrings("李小", initials("李 小龙", &out));
    try std.testing.expectEqualStrings("", initials("", &out));
    try std.testing.expectEqual(avatarColor("Ada"), avatarColor("Ada"));
}
