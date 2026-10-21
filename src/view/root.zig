//! Declarative views over the immediate UI recorder. A build function
//! describes the whole tree from application state; Host measures it with
//! flex layout and records the resulting frame. Widgets bind directly to
//! application values and report activation as ordinary return values.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const animation = @import("ziggurat_animation");

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
pub const NavDirection = ui.widgets.NavDirection;
pub const ImageView = ui.drawing.ImageView;
pub const Font = ui.Font;
pub const SortDirection = ui.widgets.SortDirection;
pub const ItemRequest = ui.widgets.ItemRequest;

pub const Error = error{ InvalidField, TooManyNodes, TextFull, NestingTooDeep, UnbalancedContainer, NotContainer, Busy, InvalidRange, InvalidValue, InvalidText, InvalidSplit, SelectionFull } || layout.Error;

pub const max_depth = 32;
/// Options of the open popup that keyboard navigation can reach.
pub const max_popup_items = 64;
/// Controls with a tooltip that hover can find in one frame.
pub const max_tooltips = 32;
/// Combo boxes and suggestion inputs that keys can open in one frame.
pub const max_popup_anchors = 16;
/// Tallest a popup list grows before it clips, in DIP.
pub const max_popup_height: f32 = 280;
/// Space between a popup or tooltip and its anchor, in DIP.
pub const popup_gap: f32 = 4;
/// Distance of the toast stack from the window's bottom edge, in DIP.
pub const toast_margin: f32 = 16;
/// Popups, popovers and toast stacks painted over the tree in one frame.
const max_floating = 8;
/// Tree and table rows keyboard navigation can reach in one frame.
pub const max_collection_rows = 512;
/// Trees and tables keyboard navigation can reach in one frame.
pub const max_collections = 8;
/// Tokens keyboard navigation can reach in one frame.
pub const max_tokens = 64;
/// Token fields whose wrapped width is remembered between passes.
pub const max_token_fields = 4;
/// Bytes of one announcement kept for assistive technology.
pub const max_announcement = 256;
/// Embedded leaves with an input callback that one pass routes input to.
pub const max_interactive_embeds = 16;
/// Column tracks of all tables in one pass.
pub const max_table_tracks = 64;
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
    /// Font for text nodes, such as `.heading1` or `.code`; null is the
    /// 16 DIP label font that widgets use.
    font: ?Font = null,
    /// False disables the node; on a container it also disables every
    /// descendant.
    enabled: bool = true,
    /// Accessible name for a control without a visible label, such as a
    /// progress indicator, or for a named container.
    name: []const u8 = "",
    /// A backdrop effect painted in place of `background`: glass, a blur of
    /// what lies beneath the container, or a scroll edge. Effects need
    /// `Host.prepareBackdropEffects`; until then they draw an opaque fill.
    material: ?ui.BackdropEffect = null,
    /// Scroll edge effects over the top and bottom of a clipping container,
    /// such as a scroll container, painted above its children.
    edges: Edges = .{},
    /// Glass that bends what lies beneath a container through its rim,
    /// painted in place of `material` and `background` once
    /// `Host.prepareShaderEffects` has run; until then those draw.
    refraction: ?ui.effects.Glass = null,
    /// Opacity of the node and its descendants, composited as one layer.
    opacity: f32 = 1,
    /// Where the node and its descendants are drawn, moved, scaled or turned
    /// in perspective about `pose.origin` within the node's box. Hit
    /// testing, focus and semantics keep the arranged box.
    pose: ?ui.effects.Pose = null,
    /// A shader program that rewrites how the node and its descendants
    /// draw; see `ui.Frame.beginEffect`. Opacity and pose need
    /// `Host.prepareShaderEffects`; without it they and `effect` draw the
    /// content as it is.
    effect: ?ui.ShaderEffect = null,
};

/// How `View.presentColumn` brings content in and takes it out.
pub const Transition = struct {
    /// Pose and opacity of the content while hidden; it moves between them
    /// and its own style.
    hidden: ui.effects.Pose = .{ .y = 8 },
    hidden_opacity: f32 = 0,
    enter: animation.Motion = .{ .tween = .{ .duration_ns = 200 * std.time.ns_per_ms, .easing = .cubic_out } },
    exit: animation.Motion = .{ .tween = .{ .duration_ns = 150 * std.time.ns_per_ms, .easing = .smoothstep } },
    /// Enter on the first pass that shows the content, rather than appear
    /// already in place.
    appear: bool = true,
};
/// Whether content shown by `View.presentColumn` is in, coming in or going out,
/// kept by the application at a stable address across passes.
pub const Presence = struct {
    channel: ?animation.Channel = null,
    visible: bool = false,

    /// Progress at `now` from 0 (hidden) to 1 (shown), retargeting when
    /// `visible` changes. Springs may overshoot.
    pub fn update(self: *Presence, now: u64, visible: bool, transition: Transition, reduce_motion: bool) !f64 {
        if (self.channel == null) {
            self.channel = try animation.Channel.init(if (visible and !transition.appear) 1 else 0);
            self.visible = !visible;
        }
        const channel = &self.channel.?;
        if (channel.reduce_motion != reduce_motion) try channel.setReducedMotion(now, reduce_motion);
        if (visible != self.visible) {
            self.visible = visible;
            try channel.retarget(now, if (visible) 1 else 0, .{ .motion = if (visible) transition.enter else transition.exit });
        }
        return (try channel.advance(now)).value;
    }
    /// True while the content is coming in or going out.
    pub fn moving(self: *const Presence) bool {
        return if (self.channel) |channel| channel.run != null else false;
    }
};

/// Edge effects of a clipping container; see `Style.edges`.
pub const Edges = struct {
    top: ?ui.backdrop_effects.ScrollEdge = null,
    bottom: ?ui.backdrop_effects.ScrollEdge = null,
    /// Depth of each edge band in DIP.
    height: f32 = 24,
};
/// The system's accessibility appearance, chosen by the host from its
/// desktop preferences; see `Host.setPreferences`.
pub const Preferences = struct {
    /// Loading indicators hold a still pose and schedule no frames.
    reduce_motion: bool = false,
    /// Backdrop effects draw opaque fills.
    reduce_transparency: bool = false,
    high_contrast: bool = false,
};
pub const LoadingKind = ui.loading.Kind;
/// How a loading indicator looks and moves; see `View.loadingIndicator`.
pub const LoadingOptions = struct {
    /// Height in DIP; the width follows the indicator's aspect.
    size: f32 = ui.loading.default_size,
    /// RGB; null is the theme's text color.
    color: ?u32 = null,
    /// One cycle in nanoseconds; zero is the indicator's own.
    duration: u64 = 0,
    /// Hold the current pose; with a `timer` it resumes from there.
    paused: bool = false,
    /// Application-owned start and hold time. Without one, every indicator
    /// keeps the host's time, so indicators move in step.
    timer: ?*LoadingTimer = null,
    variant: ui.loading.Options = .{},
};
/// When one indicator started and where it was paused, kept by the
/// application at a stable address while the indicator is built.
pub const LoadingTimer = struct {
    start: ?u64 = null,
    held: ?u64 = null,
    /// Elapsed animation time at `now`, starting the timer on first use.
    pub fn elapsed(self: *LoadingTimer, now: u64, paused: bool) u64 {
        const start = self.start orelse blk: {
            self.start = now;
            break :blk now;
        };
        if (paused) {
            if (self.held == null) self.held = now -| start;
            return self.held.?;
        }
        if (self.held) |held| {
            self.start = now -| held;
            self.held = null;
        }
        return now -| self.start.?;
    }
};
/// Repaint interval of a moving loading indicator.
pub const loading_frame_interval: u64 = 16_666_667;
const Indicator = struct { kind: LoadingKind, phase: f64, color: ?u32, size: f32, variant: ui.loading.Options };

/// The label, help and error of a form field; see `View.field`.
pub const Field = struct {
    /// Hint drawn below the content and announced with its controls.
    help: []const u8 = "",
    /// Validation message; while set it replaces the help, is drawn in the
    /// caution color and marks the controls invalid.
    @"error": ?[]const u8 = null,
    /// Marks the label and the controls as needing a value.
    required: bool = false,
};

/// How a form field describes an embedded leaf to accessibility clients.
pub const Annotation = struct {
    /// The field's label, for a leaf without a name of its own.
    name: []const u8 = "",
    description: []const u8 = "",
    invalid: bool = false,
    required: bool = false,
};

pub const ToastOptions = struct {
    /// Label of an action button, such as "Undo"; empty for none.
    action: []const u8 = "",
    /// How long the message stays, counted from the first pass that shows
    /// it; 0 keeps it until dismissed.
    duration: u64 = 4 * std.time.ns_per_s,
};
/// Longest toast message and action label, in bytes.
pub const max_toast_message = 256;
pub const max_toast_action = 32;

/// Fixed queue of transient messages, owned by the application at a stable
/// address and shown with `View.toasts`. It copies the text it is given.
pub fn Toasts(comptime capacity: usize) type {
    if (capacity == 0) @compileError("a toast queue needs room for one message");
    return struct {
        const Self = @This();
        pub const Entry = struct {
            id: u64,
            message: [max_toast_message]u8 = undefined,
            message_len: usize = 0,
            action: [max_toast_action]u8 = undefined,
            action_len: usize = 0,
            duration: u64,
            /// The pass time it was first shown at, or null before that.
            shown: ?u64 = null,
        };
        entries: [capacity]Entry = undefined,
        len: usize = 0,
        next_id: u64 = 1,

        /// Queue a message and return its id; when the queue is full, the
        /// oldest message leaves first.
        pub fn show(self: *Self, message: []const u8, options: ToastOptions) error{ InvalidText, TextTooLong }!u64 {
            if (!std.unicode.utf8ValidateSlice(message) or !std.unicode.utf8ValidateSlice(options.action)) return error.InvalidText;
            if (message.len > max_toast_message or options.action.len > max_toast_action) return error.TextTooLong;
            if (self.len == capacity) self.removeAt(0);
            const id = self.next_id;
            self.next_id += 1;
            const entry = &self.entries[self.len];
            entry.* = .{ .id = id, .message_len = message.len, .action_len = options.action.len, .duration = options.duration };
            @memcpy(entry.message[0..message.len], message);
            @memcpy(entry.action[0..options.action.len], options.action);
            self.len += 1;
            return id;
        }
        /// Remove the message with `id`; false when it is already gone.
        pub fn dismiss(self: *Self, id: u64) bool {
            for (self.entries[0..self.len], 0..) |entry, index| if (entry.id == id) {
                self.removeAt(index);
                return true;
            };
            return false;
        }
        pub fn removeAt(self: *Self, index: usize) void {
            std.debug.assert(index < self.len);
            std.mem.copyForwards(Entry, self.entries[index .. self.len - 1], self.entries[index + 1 .. self.len]);
            self.len -= 1;
        }
        pub fn items(self: *const Self) []const Entry {
            return self.entries[0..self.len];
        }
    };
}

/// The selected items of a tree or table, kept by the application at a
/// stable address. Items are named by the application's own stable ids,
/// so the selection survives renames, reordering and collapsed branches.
pub const Selection = struct {
    pub const Mode = enum { single, multiple };
    mode: Mode = .single,
    /// Room for the selected ids; its length is the most that can be
    /// selected at once.
    storage: []u64,
    len: usize = 0,
    /// Where a Shift range starts.
    anchor: ?u64 = null,
    /// The item with the keyboard cursor, which holds the collection's Tab
    /// stop. In multiple mode it may be unselected.
    cursor: ?u64 = null,
    /// Counts changes to the selected set, so a build can tell it changed.
    version: u64 = 0,

    pub fn init(mode: Mode, storage: []u64) Selection {
        return .{ .mode = mode, .storage = storage };
    }
    pub fn items(self: *const Selection) []const u64 {
        return self.storage[0..self.len];
    }
    pub fn contains(self: *const Selection, id: u64) bool {
        return std.mem.indexOfScalar(u64, self.items(), id) != null;
    }
    pub fn clear(self: *Selection) void {
        if (self.len == 0) return;
        self.len = 0;
        self.version += 1;
    }
    /// Add `id`; in single mode it replaces the selected item.
    pub fn add(self: *Selection, id: u64) error{SelectionFull}!void {
        if (self.contains(id)) return;
        if (self.mode == .single) self.len = 0;
        if (self.len == self.storage.len) return error.SelectionFull;
        self.storage[self.len] = id;
        self.len += 1;
        self.version += 1;
    }
    /// Remove `id`; false when it was not selected.
    pub fn remove(self: *Selection, id: u64) bool {
        const index = std.mem.indexOfScalar(u64, self.items(), id) orelse return false;
        std.mem.copyForwards(u64, self.storage[index .. self.len - 1], self.storage[index + 1 .. self.len]);
        self.len -= 1;
        self.version += 1;
        return true;
    }
    /// Select only `id` and move the cursor and the anchor to it.
    pub fn set(self: *Selection, id: u64) error{SelectionFull}!void {
        if (!(self.len == 1 and self.storage[0] == id)) {
            self.clear();
            try self.add(id);
        }
        self.anchor = id;
        self.cursor = id;
    }
};

/// One table column: its title, its track in the row grid and whether its
/// header sorts the table.
pub const Column = struct {
    title: []const u8,
    /// Width of the column; fixed and fractional tracks line up across rows,
    /// while content-sized tracks are sized per row.
    track: Track = Track.fraction(1),
    sortable: bool = true,
};
/// The column a table is sorted by.
pub const Sort = struct { column: usize, direction: SortDirection = .ascending };

/// What a text input embedded in a combo box or token field reports to the
/// view, so keys the input needs are not taken by the list or the tokens.
pub const EmbedStatus = struct {
    /// An input method composition is in progress.
    composing: bool = false,
    /// The input holds no text.
    empty: bool = false,
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
    /// Extent of text in a font other than the label font. Without it,
    /// `measure` is scaled by the font size, and fixed-pitch text counts
    /// 0.6 em per character.
    measure_font: ?*const fn (?*anyopaque, []const u8, Font) Size = null,

    pub const line_height: f32 = 24;
    /// Extent of `text` in `font`, or in the label font when null.
    pub fn textSize(self: Measurer, text: []const u8, font: ?Font) Size {
        const value = font orelse return self.measure(self.context, text);
        if (self.measure_font) |callback| return callback(self.context, text, value);
        const scale = value.size / 16;
        const height = @max(line_height * scale, @ceil(value.size * 1.25));
        if (value.monospace) {
            const count = std.unicode.utf8CountCodepoints(text) catch text.len;
            return .{ .width = @as(f32, @floatFromInt(count)) * value.size * 0.6, .height = height };
        }
        const base = self.measure(self.context, text);
        const emphasis: f32 = if (value.weight == .regular) 1 else 1.05;
        return .{ .width = @ceil(base.width * scale * emphasis), .height = height };
    }
    pub fn estimate(_: ?*anyopaque, text: []const u8) Size {
        var width: f32 = 0;
        var view = std.unicode.Utf8View.init(text) catch return .{ .width = @as(f32, @floatFromInt(text.len)) * 9, .height = line_height };
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| width += if (codepoint >= 0x1100) 16 else 9;
        return .{ .width = width, .height = line_height };
    }
};

pub const Kind = enum { column, row, radio_group, segmented, tab_list, list_box, toolbar, breadcrumbs, accordion, field, fieldset, split, scroll, grid, search, popup, popover, toasts, toast, tree, tree_item, table, table_header, table_row, token_field, combo_field, drag_area, drag_source, drop_target, text, note, badge, spacer, button, link, nav_button, combo_box, popup_button, checkbox, radio, segment, tab, list_item, disclosure, toggle_switch, progress, meter, slider, stepper, rating, avatar, embed, tree_row, column_header, token, combo_toggle, loading };

/// Where a popover goes beside its anchor: below it by default, starting
/// at its left edge. It moves to the opposite side when that side has more
/// room and the panel does not fit, and it always stays within the window.
pub const Placement = struct {
    pub const Side = enum { bottom, top, left, right };
    /// How the panel lines up with the anchor along that side.
    pub const Alignment = enum { start, center, end };
    side: Side = .bottom,
    alignment: Alignment = .start,
    /// Space between the anchor and the panel, in DIP.
    gap: f32 = popup_gap,
    /// Make the panel at least as wide as the anchor.
    match_width: bool = false,
};

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
    /// The enclosing form field's description, or an empty one outside a
    /// field; called just before each `paint` under the same rules.
    annotate: ?*const fn (*anyopaque, Annotation) void = null,
    /// Composition and emptiness of an embedded text input, read by combo
    /// boxes, suggestion lists and token fields; called during passes and
    /// key routing, so it must not allocate or block.
    status: ?*const fn (*anyopaque) EmbedStatus = null,
    /// Register the leaf as a Tab stop under its node id, so it can hold
    /// focus and receive keys through `input`.
    focusable: bool = false,
    /// Pointer and key input over the leaf, in coordinates local to its
    /// bounds; keys arrive while it holds focus. True consumes the input and
    /// repaints the window. Runs on the main thread outside paint.
    input: ?*const fn (*anyopaque, u64, EmbedInput) bool = null,
};
/// An embedded leaf that consumed a press.
pub const EmbedPress = struct { id: u64, focusable: bool };
/// A primary press on an embedded leaf.
pub const PointerPress = struct {
    position: Point,
    /// 1 for a single press, 2 for the second of a double press, and so on.
    count: u8 = 1,
    modifiers: z.KeyModifiers = .{},
};
/// The pointer moving while it presses a leaf that took the press.
pub const PointerDrag = struct {
    position: Point,
    /// Where the press began.
    origin: Point,
    /// Movement since the previous drag input or the press.
    delta: Point,
    /// The pointer has gone `drag_threshold` from the origin during this
    /// press; it stays set once reached.
    dragging: bool,
};
/// A wheel or touchpad scroll over a leaf, in DIP; positive y scrolls down.
pub const PointerWheel = struct { position: Point, delta: Point };
pub const EmbedInput = union(enum) {
    pointer_move: Point,
    /// The pointer moved off the leaf, or another leaf took it.
    pointer_leave,
    /// A primary press. Taking it captures the pointer for the leaf: until
    /// the release, moves arrive as `pointer_drag` and the release as
    /// `pointer_up` wherever the pointer is, even outside the leaf or the
    /// window. A press the window loses instead, through focus loss or a
    /// cancelled capture, ends with `pointer_cancel`. A leaf that is no
    /// longer built loses its capture and sees nothing more.
    pointer_down: PointerPress,
    pointer_drag: PointerDrag,
    pointer_up: Point,
    pointer_cancel,
    /// Wheel input over the leaf; one it declines scrolls the containers
    /// around it.
    wheel: PointerWheel,
    key: z.KeyInput,
    /// A key released while the leaf holds focus, whether or not it took
    /// the press; releases of keys pressed while the window lacked the
    /// keyboard never come. Leaves that only edit can ignore it.
    key_up: z.KeyInput,
};

/// How far a press moves, in DIP, before it drags.
pub const drag_threshold: f32 = 4;
/// Longest gap between presses on one leaf that still counts them together.
pub const double_press_time: u64 = 500 * std.time.ns_per_ms;
/// Farthest a press may land from the previous one and still count with it.
pub const double_press_distance: f32 = 4;
/// How near the edge of a scroll container a drag scrolls it, in DIP.
pub const drag_scroll_edge: f32 = 32;
/// Drag areas, drag sources and drop targets input can reach in one frame.
pub const max_drag_regions = 32;
/// Containers whose items reorder by dragging, in one frame.
pub const max_reorder_lists = 4;
/// Items of those containers that a drag can reach in one frame.
pub const max_reorder_items = 256;

pub const DragPhase = enum {
    /// The press moved `drag_threshold` away from where it began.
    start,
    move,
    /// The pointer was released.
    end,
    /// The press was lost: Escape, a cancelled capture or focus loss.
    cancel,
};
/// A drag of a `draggable` area, delivered in its own pass.
pub const DragEvent = struct {
    id: u64,
    phase: DragPhase,
    origin: Point,
    position: Point,
    /// Movement since the previous drag event.
    delta: Point,
    modifiers: z.KeyModifiers = .{},
};
/// The drag of a `draggable` area, kept by the application at a stable
/// address. The view updates it in the pass of each drag event.
pub const Gesture = struct {
    /// A press moved past `drag_threshold` and has neither ended nor been
    /// cancelled.
    dragging: bool = false,
    /// Where the press began, in window DIP.
    origin: Point = .{},
    /// Where the pointer is now.
    position: Point = .{},
    /// Movement since the previous drag event.
    delta: Point = .{},
    /// Modifiers held when the press began.
    modifiers: z.KeyModifiers = .{},
    /// How far the pointer moved from the origin.
    pub fn translation(self: Gesture) Point {
        return .{ .x = self.position.x - self.origin.x, .y = self.position.y - self.origin.y };
    }
};

/// A value dragged within the window from a `dragSource` to a `dropTarget`:
/// `kind` tells targets what it is, as a type would, and `value` which one,
/// such as an item id.
pub const Payload = struct { kind: u64, value: u64 };
/// What a `dropTarget` takes: values of one kind from this window, and
/// files or text dragged in from other applications through `Host`.
pub const Accept = struct {
    kind: ?u64 = null,
    files: bool = false,
    text: bool = false,

    fn takes(self: Accept, offer: Offer) bool {
        if (offer.value) |payload| if (self.kind) |wanted| if (wanted == payload.kind) return true;
        return (self.files and offer.files) or (self.text and offer.text);
    }
};
/// What a drag over a target offers. Drags from other applications tell the
/// kinds of data before the drop, but not the data.
pub const Offer = struct { value: ?Payload = null, files: bool = false, text: bool = false };
/// What dropped on a target. Files are absolute UTF-8 paths separated by a
/// NUL byte. Bytes are borrowed for the pass that delivers them.
pub const Dropped = union(enum) {
    value: Payload,
    files: []const u8,
    text: []const u8,
};
pub const DropState = union(enum) {
    none,
    /// A drag the target takes is over it.
    over: Offer,
    /// Something dropped on it in this pass, at a window point.
    dropped: struct { data: Dropped, position: Point },
};
/// Items of a `reorder` container moving: the item at `from` goes before
/// the item at `to`, where the count of items means after the last. Both
/// count the items in build order before the move.
pub const Move = struct { from: usize, to: usize };

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
    /// A field's help or error text, which a note displays.
    note: []const u8 = "",
    /// A field with an error, or a note showing one.
    invalid: bool = false,
    required: bool = false,
    /// Index of the nearest enclosing form field.
    field: u32 = none,
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
    /// Hint shown on hover or focus, and announced as the description.
    tooltip: []const u8 = "",
    /// The node a popup or popover opens from, its previous sibling.
    anchor: u32 = none,
    /// Where a popover goes beside its anchor.
    placement: Placement = .{},
    /// A popup's option labels, to tell when suggestions change.
    signature: u64 = 0,
    /// The popup option keyboard navigation has reached.
    highlighted: bool = false,
    direction: NavDirection = .back,
    image: ?ImageView = null,
    /// The application's stable id of a tree or table row.
    item: u64 = 0,
    /// Depth of a tree row, from 0.
    level: u16 = 0,
    /// A tree row's expansion; null for a leaf.
    expanded: ?bool = null,
    /// The row holds its collection's keyboard cursor.
    cursor: bool = false,
    /// Selection of a tree or table.
    selection: ?*Selection = null,
    /// Index of the nearest enclosing tree or table.
    collection: u32 = none,
    /// Index of the nearest enclosing table row, whose selection colors
    /// its cell text.
    row: u32 = none,
    /// Sort direction of a column header, when the table is sorted by it.
    sort: ?SortDirection = null,
    /// What a drag source drags.
    payload: Payload = .{ .kind = 0, .value = 0 },
    /// What a drop target takes.
    accept: Accept = .{},
    /// The container's items reorder by dragging; see `View.reorder`.
    reorder: bool = false,
    /// A drag from a row of this tree or table selects the rows it crosses.
    drag_select: bool = false,
    /// A loading indicator's look and pose.
    indicator: ?Indicator = null,
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
            .column, .row, .radio_group, .segmented, .tab_list, .list_box, .toolbar, .breadcrumbs, .accordion, .field, .fieldset, .split, .scroll, .grid, .search, .popup, .popover, .toasts, .toast, .tree, .tree_item, .table, .table_header, .table_row, .token_field, .combo_field, .drag_area, .drag_source, .drop_target => true,
            else => false,
        };
    }
    /// True for a container laid out by `tracks`: a grid or a table's
    /// header and rows.
    pub fn isGrid(self: *const Node) bool {
        return self.kind == .grid or self.kind == .table_header or self.kind == .table_row;
    }
    /// True when the node clips its descendants to its bounds.
    pub fn clips(self: *const Node) bool {
        return self.kind == .scroll or self.kind == .popup or self.kind == .popover or (self.style.clip and self.isContainer());
    }
    /// True for a popup, popover or toast stack, placed over the flow
    /// instead of in it.
    pub fn floats(self: *const Node) bool {
        return self.kind == .popup or self.kind == .popover or self.kind == .toasts;
    }
    /// True for a popup or popover that is not shown in this pass.
    pub fn hidden(self: *const Node) bool {
        return (self.kind == .popup or self.kind == .popover) and !self.checked;
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
    /// A press or key on a tree or table row, taken by the collection.
    item: ItemEvent,
    /// A drag of a `draggable` area.
    drag: DragEvent,
    /// A drop on a `dropTarget`, at a window point.
    drop: struct { id: u64, data: Dropped, position: Point },
    /// Items of a `reorder` container dropped at another place.
    reorder: struct { id: u64, move: Move },
};

/// What a press or key does to a tree or table row.
pub const ItemOp = enum {
    /// Select only this item.
    select,
    /// Add it to or remove it from a multiple selection (Ctrl).
    toggle,
    /// Select from the anchor to it (Shift), replacing the selection.
    range,
    /// Add the items from the anchor to it (Ctrl+Shift).
    range_add,
    /// Move the keyboard cursor without selecting (Ctrl+arrow).
    cursor,
    expand,
    collapse,
    /// Enter on the row; `treeItem` and `tableRow` return true.
    activate,
    /// Select every built item of a multiple selection (Ctrl+A).
    select_all,
    /// A drag from the anchor over rows to this one: select from the anchor
    /// to it, replacing the selection, or with `ItemEvent.add` adding to
    /// the selection the drag began with.
    drag,
};
pub const ItemEvent = struct {
    /// Node id of the tree or table.
    collection: u64,
    /// The application's id of the row.
    item: u64,
    op: ItemOp,
    /// Where a range starts; null starts it at `item`.
    anchor: ?u64 = null,
    /// A `drag` keeps the selection it began with (Ctrl held at the press).
    add: bool = false,
};

/// Which popup is open and what keyboard navigation reached in it. It
/// belongs to the View and outlives passes; at most one popup is open.
pub const PopupState = struct {
    /// Combo box whose list the user opened.
    open: ?u64 = null,
    /// Option drawn as the keyboard choice; Enter picks it.
    highlight: ?u64 = null,
    /// Input whose suggestions were closed by Escape or a pick. They stay
    /// closed until their labels change or focus leaves them.
    dismissed: ?u64 = null,
    dismissed_signature: u64 = 0,
    /// Input whose suggestions were just picked; the next pass records the
    /// labels the pick produced, so they do not reopen the list.
    settle: ?u64 = null,
    /// Editable combo box whose list its button, Alt+Down or Down opened;
    /// it shows even when its options did not change.
    forced: ?u64 = null,
    /// Editable combo box holding focus. Gaining focus does not open its
    /// list; typing that changes the options does.
    within: ?u64 = null,
    /// Editable combo box whose button asked to close its list.
    close: ?u64 = null,
};

/// Hover and timing of the tooltip, kept by the View across passes.
pub const TooltipState = struct {
    /// Control under the pointer that has a tooltip.
    hover: ?u64 = null,
    /// Control whose tooltip is pending or shown, from hover or focus.
    target: ?u64 = null,
    /// When `target` was reached, in the View's clock.
    since: u64 = 0,
    /// Hidden by a press or Escape until the target changes.
    dismissed: bool = false,
};

/// Geometry of the last arranged pass that input routing needs between
/// passes, when node bounds are no longer current.
pub const Overlay = struct {
    pub const Popup = struct {
        id: u64,
        anchor: u64,
        combo: bool,
        rect: Rect,
        anchor_rect: Rect,
        signature: u64,
        /// The anchor is an editable combo box.
        editable: bool = false,
        /// Where focus returns when the list closes: the anchor, or the
        /// text input of an editable combo box or token field.
        input: u64,
    };
    pub const Region = struct { id: u64, rect: Rect };
    pub const Popover = struct { id: u64, anchor: u64, rect: Rect, anchor_rect: Rect };
    pub const Anchor = struct {
        id: u64,
        combo: bool,
        /// The text input inside an editable combo box or token field.
        input: ?u64 = null,
        /// An editable combo box's button.
        toggle: ?u64 = null,
        /// Reports the input's composition.
        embed: ?Embed = null,
    };
    pub const Row = struct {
        id: u64,
        item: u64,
        collection: u64,
        level: u16,
        expanded: ?bool,
        /// Index in `rows` of the tree row this one is nested under.
        parent: u32,
        bounds: Rect,
        /// Part left visible by clips; empty when scrolled out.
        rect: Rect,
        enabled: bool,
        /// Node index in build order.
        index: u32 = 0,
    };
    pub const Collection = struct {
        id: u64,
        tree: bool,
        multiple: bool,
        anchor: ?u64,
        page: usize,
        /// A drag from a row selects the rows it crosses.
        drag_select: bool = false,
        /// The nearest scroll container around it.
        scroll: ?u64 = null,
    };
    pub const Token = struct { id: u64, remove: u64, field: u64, rect: Rect, enabled: bool };
    pub const TokenField = struct { id: u64, input: ?u64, embed: ?Embed };
    pub const Interactive = struct { id: u64, bounds: Rect, rect: Rect, embed: Embed };
    /// A draggable area, drag source or drop target.
    pub const DragRegion = struct {
        pub const Role = enum { area, source, target };
        id: u64,
        /// Node index in build order, deeper nodes after their ancestors.
        index: u32,
        role: Role,
        bounds: Rect,
        /// Part left visible by clips.
        rect: Rect,
        payload: Payload = .{ .kind = 0, .value = 0 },
        accept: Accept = .{},
    };
    /// A container whose items reorder by dragging; its items are
    /// `reorder_items[first..][0..count]`.
    pub const ReorderList = struct { id: u64, axis: Axis, rect: Rect, first: u32, count: u32, scroll: ?u64 };
    pub const ReorderItem = struct { id: u64, index: u32, bounds: Rect, rect: Rect };
    popup: ?Popup = null,
    /// The shown popover painted last, which takes Escape and presses
    /// outside it.
    popover: ?Popover = null,
    /// Enabled options of the open popup, in build order.
    items: [max_popup_items]Region = undefined,
    item_count: usize = 0,
    /// Visible controls with a tooltip, in paint order.
    tips: [max_tooltips]Region = undefined,
    tip_count: usize = 0,
    /// Enabled combo boxes and suggestion inputs.
    anchors: [max_popup_anchors]Anchor = undefined,
    anchor_count: usize = 0,
    /// Tree and table rows in build order.
    rows: [max_collection_rows]Row = undefined,
    row_count: usize = 0,
    collections: [max_collections]Collection = undefined,
    collection_count: usize = 0,
    tokens: [max_tokens]Token = undefined,
    token_count: usize = 0,
    token_fields: [max_token_fields]TokenField = undefined,
    token_field_count: usize = 0,
    /// Visible enabled embedded leaves with an input callback, in paint order.
    embeds: [max_interactive_embeds]Interactive = undefined,
    embed_count: usize = 0,
    /// Enabled draggable areas, drag sources and drop targets in build order.
    regions: [max_drag_regions]DragRegion = undefined,
    region_count: usize = 0,
    lists: [max_reorder_lists]ReorderList = undefined,
    list_count: usize = 0,
    reorder_items: [max_reorder_items]ReorderItem = undefined,
    reorder_item_count: usize = 0,
    /// Visible scroll containers in paint order, which wheel input and
    /// drags near their edges scroll.
    scrolls: [max_scroll_regions]Region = undefined,
    scroll_count: usize = 0,
};

/// A press the view follows until its release: one an embedded leaf took,
/// or one on something the pointer drags, which drags once it moves
/// `drag_threshold`.
pub const Capture = struct {
    pub const Target = union(enum) {
        embed: u64,
        area: u64,
        source: struct { id: u64, payload: Payload },
        reorder: struct { list: u64, from: usize, to: usize },
        select: struct { collection: u64, item: u64, add: bool, last: u64 },
    };
    target: Target,
    origin: Point,
    position: Point,
    modifiers: z.KeyModifiers = .{},
    dragging: bool = false,
};

/// What the view did with pointer input it routed; the caller delivers the
/// events and applies the rest.
pub const PointerResult = struct {
    /// Taken; route it no further.
    consumed: bool = false,
    repaint: bool = false,
    /// Drop the press of the control under the pointer, so a drag does not
    /// end in its activation.
    cancel_press: bool = false,
    /// An embedded leaf that took a press and holds focus from now on.
    focus: ?u64 = null,
    /// An embedded leaf took the input and may have changed state it
    /// owns: a pass applies it before focus moves.
    settle: bool = false,
    /// Events to deliver in order, each in a pass of its own.
    events: [2]?Event = .{ null, null },

    fn push(self: *PointerResult, event: Event) void {
        for (&self.events) |*slot| if (slot.* == null) {
            slot.* = event;
            return;
        };
    }
};

/// What `View.routeKey` did with a key press.
pub const KeyRoute = union(enum) {
    /// Not a popup or tooltip key; route it normally.
    ignored,
    /// Consumed; the popup or tooltip changed.
    handled,
    /// The popup closed; route the key normally too, such as Tab.
    pass,
    /// Run a pass delivering this event, such as picking the highlight.
    deliver: Event,
};
/// What `View.pointerDown` did with a press.
pub const PointerRoute = enum { ignored, changed, consumed };

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
    /// A list item selected by input, revealed by the next `arrange`. It
    /// outlives `reset` so an event pass can hand it to the render pass.
    reveal: ?u64 = null,
    /// Monotonic time of this pass in nanoseconds, set by the host before
    /// each pass. Only differences are meaningful.
    now: u64 = 0,
    /// The earliest time a build asked to run again, or null; see `wakeAt`.
    wake: ?u64 = null,
    /// Keyboard focus at the start of this pass, set by the host.
    focus: ?u64 = null,
    /// A control the host should focus after this pass, such as a combo box
    /// whose list just closed.
    restore: ?u64 = null,
    /// A leaf a build asked to focus with `focusLeaf`.
    focus_request: ?u64 = null,
    /// The window has the keyboard, set by the host from focus events.
    window_focused: bool = true,
    /// Hover or focus time before a tooltip appears, in nanoseconds.
    tooltip_delay: u64 = 500 * std.time.ns_per_ms,
    preferences: Preferences = .{},
    /// Built-in programs for `Style.opacity`, `pose` and `refraction`, set
    /// by `Host.prepareShaderEffects`.
    effects: ?*const ui.effects.Library = null,
    popup: PopupState = .{},
    tip: TooltipState = .{},
    overlay: Overlay = .{},
    /// The interactive embedded leaf under the pointer.
    embed_hover: ?u64 = null,
    /// The press being followed, if any; it outlives passes.
    capture: ?Capture = null,
    /// The last press on an embedded leaf, to count double presses.
    last_press: struct { id: u64 = 0, time: u64 = 0, at: Point = .{}, count: u8 = 0 } = .{},
    /// The drop target under a drag within the window.
    drop_over: ?u64 = null,
    /// A drag from another application over the window.
    system_drag: ?struct { over: ?u64, files: bool, text: bool } = null,
    /// The selection a Ctrl drag over rows began with.
    drag_base: [max_collection_rows]u64 = undefined,
    drag_base_len: usize = 0,
    drag_base_taken: bool = false,
    /// What the last arrange paints for a drag: a copy of what moves, its
    /// label, the gap a reordered item goes to, and the target under it.
    drag_ghost: ?Rect = null,
    drag_label: []const u8 = "",
    insert_mark: ?Rect = null,
    drop_mark: ?Rect = null,
    /// Text for assistive technology to announce, and the serial that
    /// makes each announcement a new live region.
    announcement: [max_announcement]u8 = undefined,
    announcement_len: usize = 0,
    announcement_serial: u64 = 0,
    /// Node whose tooltip this pass shows, and where after arrange.
    tip_index: u32 = none,
    tip_rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// A suggestion was picked in this pass.
    picked: bool = false,
    /// The row event the collection that took it is applying in this pass.
    item_event: ?ItemEvent = null,
    /// A Shift range or select-all being applied in build order: rows from
    /// the first of `from` and `to` met through the second are selected; a
    /// null `from` selects every row.
    range: ?struct { collection: u64, from: ?u64, to: u64, inside: bool = false, done: bool = false } = null,
    /// Token field whose token was removed in this pass.
    removed_token: u32 = none,
    /// Popover that Escape or a press outside closed; the next pass that
    /// builds it clears its `open` flag.
    popover_dismiss: ?u64 = null,
    /// The popover shown in the last pass, which focus moved into when it
    /// opened, and whether focus was inside it at the end of that pass.
    popover_shown: ?u64 = null,
    popover_within: bool = false,
    /// A popover that opened in this pass, whose first control takes focus.
    popover_opened: ?u64 = null,
    /// Column tracks of this pass's tables.
    tracks: [max_table_tracks]Track = undefined,
    track_len: usize = 0,
    /// Widest single-column cell content of every table column, gathered
    /// from the header and all rows so they share column widths.
    track_minimum: [max_table_tracks]f32 = undefined,
    track_preferred: [max_table_tracks]f32 = undefined,
    /// Inner width each token field had at its last arrangement, so its
    /// tokens wrap at the right width when measured.
    flow_widths: [max_token_fields]struct { id: u64, width: f32 } = undefined,
    flow_count: usize = 0,

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
        self.wake = null;
        self.restore = null;
        self.picked = false;
        self.item_event = null;
        self.range = null;
        self.removed_token = none;
        self.popover_opened = null;
        self.track_len = 0;
        self.tip_index = none;
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
        if (node.hidden()) return null;
        // Popups and toasts are drawn over the flow, so the clips of their
        // own ancestors do not apply to them.
        var parent = if (node.floats()) none else node.parent;
        while (parent < all.len) : (parent = all[parent].parent) {
            const ancestor = &all[parent];
            if (ancestor.hidden()) return null;
            if (ancestor.clips()) rect = intersect(rect, ancestor.bounds) orelse return null;
            if (ancestor.floats()) break;
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
        if (!std.math.isFinite(style.opacity) or style.opacity < 0 or style.opacity > 1) return error.InvalidValue;
        if (style.pose) |pose| if (!pose.valid()) return error.InvalidValue;
        const index = self.len;
        var effective = style;
        effective.enabled = style.enabled and parent.style.enabled;
        self.buffers.nodes[index] = .{ .kind = kind, .id = self.identity(parent, kind, style), .style = effective, .parent = parent_index, .end = index + 1, .semantic_parent = switch (parent.kind) {
            .toolbar, .breadcrumbs, .accordion, .fieldset, .search, .toast, .table_header, .table_row, .token_field, .combo_field => parent.id,
            else => parent.semantic_parent,
        }, .field = if (parent.kind == .field) parent_index else parent.field, .collection = if (parent.kind == .tree or parent.kind == .table) parent_index else parent.collection, .row = if (parent.kind == .table_row) parent_index else parent.row };
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

    /// The event of this pass when it targets `id`, which it consumes; for
    /// composite controls built from embedded leaves that register
    /// controls of their own under ids they choose.
    pub fn takeEvent(self: *View, id: u64) ?Event {
        return self.take(id);
    }
    fn take(self: *View, id: u64) ?Event {
        const event = self.event orelse return null;
        const target = switch (event) {
            .action => |value| value,
            .value => |value| value.id,
            .scroll => |value| value.id,
            .item => |value| value.collection,
            .drag => |value| value.id,
            .drop => |value| value.id,
            .reorder => |value| value.id,
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
        // A popup or toast stack cannot open inside another one.
        if (kind == .popup or kind == .toasts) for (self.stack[1..self.depth]) |index| {
            if (self.buffers.nodes[index].floats()) return error.NotContainer;
        };
        const node = try self.append(kind, style);
        self.stack[self.depth] = @intCast(node - self.buffers.nodes.ptr);
        self.depth += 1;
        return node;
    }
    pub fn column(self: *View, style: Style) Error!void {
        return self.begin(.column, style);
    }
    /// Open a column that enters while `show` and exits after it turns
    /// false, moving between `transition.hidden` and `style`. Returns false
    /// once the content has gone; otherwise build its children and `end`
    /// it. Under reduced motion it appears and goes at once.
    pub fn presentColumn(self: *View, presence: *Presence, show: bool, transition: Transition, style: Style) Error!bool {
        if (!transition.hidden.valid() or !std.math.isFinite(transition.hidden_opacity)) return error.InvalidValue;
        const amount = presence.update(self.now, show, transition, self.preferences.reduce_motion) catch return error.InvalidValue;
        if (!show and !presence.moving()) return false;
        const t: f32 = @floatCast(amount);
        var shown = style;
        shown.opacity = std.math.clamp(style.opacity * (transition.hidden_opacity + (1 - transition.hidden_opacity) * t), 0, 1);
        const pose = ui.effects.Pose.mix(transition.hidden, style.pose orelse .{}, t);
        shown.pose = if (pose.isIdentity()) null else pose;
        try self.begin(.column, shown);
        if (presence.moving()) if (presence.channel.?.nextWake(self.now, loading_frame_interval) catch null) |deadline| self.wakeAt(deadline);
        return true;
    }
    pub fn row(self: *View, style: Style) Error!void {
        return self.begin(.row, style);
    }
    pub fn end(self: *View) Error!void {
        if (self.depth <= 1) return error.UnbalancedContainer;
        // An editable combo box ends with its button, inside it.
        if (self.buffers.nodes[self.stack[self.depth - 1]].kind == .combo_field) try self.comboToggle(self.stack[self.depth - 1]);
        self.depth -= 1;
        const index = self.stack[self.depth];
        const node = &self.buffers.nodes[index];
        if (node.kind == .split and node.child_count != 2) return error.InvalidSplit;
        if (node.kind == .popup) self.settlePopup(index);

        if (node.kind == .field) {
            // Only the label precedes the content.
            if (node.child_count < 2) return error.InvalidField;
            if (node.note.len > 0) {
                const note = try self.append(.note, .{});
                note.text = node.note;
                note.invalid = node.invalid;
            }
        }
        node.end = self.len;
        if (node.kind == .popover and node.checked) {
            if (self.popover_opened) |id| if (id == node.id) {
                self.popover_opened = null;
                // Focus moves into a popover as it opens, unless its
                // content asked for a control of its own.
                if (self.restore == null) if (self.firstFocusable(index)) |at| {
                    self.restore = self.buffers.nodes[at].id;
                };
            };
            if (self.popover_shown) |id| if (id == node.id) {
                self.popover_within = self.focusWithin(node);
            };
        }
        if (node.kind == .token_field and self.removed_token == index) {
            // After a removal, typing continues in the field's input.
            if (self.firstEmbed(index)) |input| self.restore = self.buffers.nodes[input].id;
        }
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
    /// Starts a single-selection list of full-width options bound to one
    /// value, named by `Style.name`. Put it in a `scroll` container for long
    /// lists: an option selected by input is scrolled into view on the next
    /// arrange. Close it with `end`.
    pub fn listBox(self: *View, style: Style) Error!void {
        _ = try self.open(.list_box, style);
    }
    /// Selects `option` on activation or arrow navigation; true when the
    /// selection changed.
    pub fn listItem(self: *View, comptime T: type, selected: *T, option: T, label: []const u8, style: Style) Error!bool {
        const changed = try self.choice(.list_item, .list_box, T, selected, option, label, style);
        if (changed) self.reveal = self.buffers.nodes[self.len - 1].id;
        return changed;
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
    /// Starts a labelled form field: the label, then the content built
    /// before `end`, then the error or help text from `info`. Controls inside
    /// announce that text as their description, are marked invalid while
    /// there is an error and take the label as their name when they have no
    /// name of their own. The content needs at least one node.
    pub fn field(self: *View, label: []const u8, info: Field, style: Style) Error!void {
        var value = style;
        if (value.gap == 0) value.gap = 4;
        const node = try self.open(.field, value);
        node.text = try self.copy(label);
        node.required = info.required;
        if (info.@"error") |message| {
            node.note = try self.copy(message);
            node.invalid = true;
        } else if (info.help.len > 0) node.note = try self.copy(info.help);
        const caption = try self.append(.text, .{});
        // The marker follows the label in the same storage, so both are one slice.
        const start = self.text_len;
        _ = try self.copy(label);
        if (info.required) _ = try self.copy(" *");
        caption.text = self.buffers.text[start..self.text_len];
    }
    /// Starts a column of related fields under a visible legend, announced
    /// as a group named by it. `Style.enabled = false` disables everything
    /// inside. Close it with `end`.
    pub fn fieldset(self: *View, legend: []const u8, style: Style) Error!void {
        var value = style;
        if (value.gap == 0) value.gap = 8;
        const node = try self.open(.fieldset, value);
        node.text = try self.copy(legend);
        if (legend.len > 0) try self.text(legend, .{});
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
    /// An animated indicator of work of unknown length, named by
    /// `Style.name` and exposed as an indeterminate progress bar. While it
    /// moves it asks for a pass every frame; under reduced motion or when
    /// paused it holds still and asks for none.
    pub fn loadingIndicator(self: *View, kind: LoadingKind, look: LoadingOptions, style: Style) Error!void {
        if (!std.math.isFinite(look.size) or look.size <= 0) return error.InvalidValue;
        const node = try self.append(.loading, style);
        const still = self.preferences.reduce_motion;
        const elapsed = if (still) 0 else if (look.timer) |timer| timer.elapsed(self.now, look.paused) else self.now;
        node.indicator = .{ .kind = kind, .phase = if (still) 0 else ui.loading.phase(kind, elapsed, look.duration), .color = look.color, .size = look.size, .variant = look.variant };
        if (!still and !look.paused) self.wakeAt(self.now + loading_frame_interval);
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

    /// Starts a tree of rows bound to `selection`, named by `Style.name`.
    /// Build its rows with `treeItem`, nesting each row's children before
    /// that row's `end`. Rows share one Tab stop on the selection's cursor;
    /// Up/Down, Home/End and PageUp/PageDown move it, Right expands a row
    /// or enters its first child, Left collapses it or returns to its
    /// parent, Enter activates it. With a multiple selection, Ctrl moves the
    /// cursor alone or toggles on Space and press, Shift extends a range
    /// from the anchor and Ctrl+A selects every built row. Put it in a
    /// `scroll` container for long trees. Close it with `end`.
    pub fn tree(self: *View, selection: *Selection, style: Style) Error!void {
        const node = try self.open(.tree, style);
        try self.openCollection(node, selection);
    }
    /// A tree row for the application's item `id`, unique in its tree, with
    /// its children (when `expanded` is set) built before the matching
    /// `end`. `expanded` is null for a leaf; expansion flips it. True once
    /// for the pass where Enter activates the row.
    pub fn treeItem(self: *View, id: u64, expanded: ?*bool, label: []const u8, style: Style) Error!bool {
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.kind != .tree and parent.kind != .tree_item) return error.NotContainer;
        const nested = parent.kind == .tree_item;
        const level: u16 = if (nested) self.buffers.nodes[parent.first_child].level +| 1 else 0;
        const semantic = if (nested) self.buffers.nodes[parent.first_child].id else parent.id;
        _ = try self.open(.tree_item, .{ .key = id, .enabled = style.enabled });
        var value = style;
        value.key = null;
        const leaf = try self.append(.tree_row, value);
        leaf.text = try self.copy(label);
        leaf.level = level;
        leaf.semantic_parent = semantic;
        return self.rowState(leaf, id, expanded);
    }

    /// Starts a table: a header row with one sortable title per column,
    /// then the rows built with `tableRow`, which may sit in a `scroll`
    /// container so the header stays put. Activating a sortable header sorts
    /// by it, ascending first and then flipping; the application sorts its
    /// rows from `sort`. Selection and keys follow `tree`, without
    /// expansion. `Style.gap` is the column gap (8 DIP when 0). True when
    /// `sort` changed. Close it with `end`.
    pub fn table(self: *View, columns: []const Column, sort: *?Sort, selection: *Selection, style: Style) Error!bool {
        if (columns.len == 0 or columns.len > ui.grid.max_tracks) return error.InvalidValue;
        if (sort.*) |current| if (current.column >= columns.len) return error.InvalidValue;
        if (self.tracks.len - self.track_len < columns.len) return error.TooManyItems;
        const tracks = self.tracks[self.track_len..][0..columns.len];
        for (columns, tracks) |entry, *track| track.* = entry.track;
        @memset(self.track_minimum[self.track_len..][0..columns.len], 0);
        @memset(self.track_preferred[self.track_len..][0..columns.len], 0);
        self.track_len += columns.len;
        var value = style;
        const column_gap = if (style.gap == 0) 8 else style.gap;
        value.gap = 0;
        const node = try self.open(.table, value);
        node.tracks = tracks;
        node.fraction = column_gap;
        try self.openCollection(node, selection);
        const header = try self.open(.table_header, .{ .gap = column_gap, .padding = row_padding, .enabled = style.enabled });
        header.tracks = tracks;
        header.semantic_parent = node.id;
        const header_index = self.stack[self.depth - 1];
        var changed = false;
        for (columns, 0..) |entry, index| {
            const cell = try self.append(.column_header, .{ .key = index });
            cell.text = try self.copy(entry.title);
            cell.checked = entry.sortable;
            if (self.take(cell.id) != null and entry.sortable) {
                const current = sort.*;
                sort.* = if (current != null and current.?.column == index) .{ .column = index, .direction = if (current.?.direction == .ascending) .descending else .ascending } else .{ .column = index };
                changed = true;
            }
        }
        var child = self.buffers.nodes[header_index].first_child;
        var index: usize = 0;
        while (child != none) : ({
            child = self.buffers.nodes[child].next_sibling;
            index += 1;
        }) {
            const current = sort.*;
            self.buffers.nodes[child].sort = if (current != null and current.?.column == index) current.?.direction else null;
        }
        try self.end();
        return changed;
    }
    /// Starts the row of the enclosing table for the application's item
    /// `id`, unique in its table; build one cell per column, then `end`.
    /// `name` is the row's accessible name, such as its first cell. True
    /// once for the pass where Enter activates the row.
    pub fn tableRow(self: *View, id: u64, name: []const u8, style: Style) Error!bool {
        var value = style;
        value.key = id;
        if (value.padding.left == 0 and value.padding.right == 0 and value.padding.top == 0 and value.padding.bottom == 0) value.padding = row_padding;
        const node = try self.open(.table_row, value);
        if (node.collection == none or self.buffers.nodes[node.collection].kind != .table) return error.NotContainer;
        const owner = &self.buffers.nodes[node.collection];
        node.tracks = owner.tracks;
        node.style.gap = owner.fraction;
        node.text = try self.copy(name);
        node.semantic_parent = owner.id;
        return self.rowState(node, id, null);
    }
    /// Space around the cells of a table's rows and header.
    pub const row_padding: Insets = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 };

    fn openCollection(self: *View, node: *Node, selection: *Selection) Error!void {
        node.selection = selection;
        // Other events for the collection, such as a reorder, are left
        // for the calls that follow.
        const pending = self.event orelse return;
        if (pending != .item or pending.item.collection != node.id) return;
        const value = self.take(node.id).?.item;
        switch (value.op) {
            .select => try selection.set(value.item),
            .toggle => {
                if (!selection.remove(value.item)) try selection.add(value.item);
                selection.anchor = value.item;
                selection.cursor = value.item;
            },
            .cursor => selection.cursor = value.item,
            .range, .range_add => if (selection.mode == .single) try selection.set(value.item) else {
                if (value.op == .range) selection.clear();
                const from = value.anchor orelse value.item;
                selection.anchor = from;
                selection.cursor = value.item;
                self.range = .{ .collection = node.id, .from = from, .to = value.item };
            },
            .select_all => if (selection.mode == .multiple) {
                self.range = .{ .collection = node.id, .from = null, .to = value.item };
            },
            .drag => if (selection.mode == .single) try selection.set(value.item) else {
                // The first step of a drag keeps the selection it began
                // with when it adds; every step rebuilds from it.
                if (!self.drag_base_taken) {
                    self.drag_base_taken = true;
                    self.drag_base_len = 0;
                    if (value.add) for (selection.items()) |id| {
                        if (self.drag_base_len == self.drag_base.len) break;
                        self.drag_base[self.drag_base_len] = id;
                        self.drag_base_len += 1;
                    };
                }
                selection.clear();
                for (self.drag_base[0..self.drag_base_len]) |id| try selection.add(id);
                const from = value.anchor orelse value.item;
                selection.anchor = from;
                selection.cursor = value.item;
                self.range = .{ .collection = node.id, .from = from, .to = value.item };
            },
            .expand, .collapse, .activate => {},
        }
        self.item_event = value;
    }
    /// Apply this pass's event to a tree or table row and record its state;
    /// true when Enter activated it.
    fn rowState(self: *View, node: *Node, id: u64, expanded: ?*bool) Error!bool {
        const owner = &self.buffers.nodes[node.collection];
        const selection = owner.selection.?;
        node.item = id;
        var activated = false;
        if (self.take(node.id)) |event| switch (event) {
            // Activation by an accessibility client or a test selects only
            // this row, like a plain press.
            .action => if (node.style.enabled) try selection.set(id),
            .value => |value| if (node.style.enabled and value.change == .set) {
                const code = value.change.set;
                if (code == @intFromEnum(ItemRequest.deselect)) {
                    _ = selection.remove(id);
                } else if (code == @intFromEnum(ItemRequest.add)) {
                    try selection.add(id);
                } else if (code == @intFromEnum(ItemRequest.collapse) or code == @intFromEnum(ItemRequest.expand)) {
                    if (expanded) |flag| flag.* = code == @intFromEnum(ItemRequest.expand);
                }
            },
            else => {},
        };
        if (self.item_event) |value| if (value.collection == owner.id and value.item == id) {
            switch (value.op) {
                .expand => if (expanded) |flag| {
                    flag.* = true;
                },
                .collapse => if (expanded) |flag| {
                    flag.* = false;
                },
                .activate => activated = true,
                else => {},
            }
            // The row the event reached takes focus and scrolls into view.
            self.restore = node.id;
            self.reveal = node.id;
        };
        if (self.range) |*range| if (range.collection == owner.id and !range.done) {
            const edge = if (range.from) |from| id == from or id == range.to else false;
            if (range.from == null or range.inside or edge) try selection.add(id);
            if (edge) {
                if (range.inside or range.from.? == range.to) range.done = true else range.inside = true;
            }
        };
        node.checked = selection.contains(id);
        node.cursor = if (selection.cursor) |cursor| cursor == id else false;
        node.expanded = if (expanded) |flag| flag.* else null;
        return activated;
    }

    /// Starts a token field: a wrapping row of tokens built with `token`,
    /// followed by the text input that adds them, usually an embedded text
    /// field with `Style.grow`. `suggestions` after its `end` opens a list
    /// under the whole field. Tokens share one Tab stop; Left/Right and
    /// Home/End move between them, Backspace or Delete removes the focused
    /// one, and Backspace or Left in the empty input moves to the last one.
    /// Named by `Style.name`. Gap and padding are 4 DIP unless set.
    pub fn tokenField(self: *View, style: Style) Error!void {
        var value = style;
        if (value.gap == 0) value.gap = 4;
        if (value.padding.left == 0 and value.padding.right == 0 and value.padding.top == 0 and value.padding.bottom == 0) value.padding = Insets.all(4);
        _ = try self.open(.token_field, value);
    }
    /// A token of the enclosing token field, keyed by `Style.key` when
    /// tokens can move. A press on it focuses it; its remove button,
    /// Backspace or Delete removes it. True once for the pass that removes
    /// it; remove it from the application's list in that branch.
    pub fn token(self: *View, label: []const u8, style: Style) Error!bool {
        const parent_index = self.stack[self.depth - 1];
        const parent = &self.buffers.nodes[parent_index];
        if (parent.kind != .token_field) return error.NotContainer;
        const group = parent.id;
        const node = try self.append(.token, style);
        node.text = try self.copy(label);
        node.radio_group = group;
        if (self.take(node.id) != null) self.restore = node.id;
        if (self.take(tokenRemoveId(node.id)) != null and node.style.enabled) {
            self.removed_token = parent_index;
            return true;
        }
        return false;
    }

    /// Starts an editable combo box: put its text input inside, usually an
    /// embedded text field with `Style.grow`, then `end` adds the button
    /// that opens the list. Build the list with `suggestions` and
    /// `suggestion` after `end`, filtered by the input's text. Gaining focus
    /// leaves the list closed; typing that changes the options opens it, and
    /// the button, Down, Alt+Down or F4 open it with the current options.
    /// Alt+Up, F4, Escape or a pick close it. `value` is the input's text,
    /// reported to accessibility clients; named by `Style.name`.
    pub fn editableComboBox(self: *View, value: []const u8, style: Style) Error!void {
        const node = try self.open(.combo_field, style);
        node.text = try self.copy(value);
    }
    fn comboToggle(self: *View, index: u32) Error!void {
        const toggle_node = try self.append(.combo_toggle, .{ .enabled = self.buffers.nodes[index].style.enabled, .name = "Open" });
        const combo = &self.buffers.nodes[index];
        if (self.take(toggle_node.id) == null or !combo.style.enabled) return;
        const shown = (if (self.popup.forced) |id| id == combo.id else false) or (if (self.overlay.popup) |list| list.anchor == combo.id else false);
        if (shown) {
            self.popup.forced = null;
            self.popup.close = combo.id;
        } else {
            self.popup.forced = combo.id;
            self.popup.close = null;
            if (self.popup.dismissed) |id| if (id == combo.id) {
                self.popup.dismissed = null;
            };
        }
        // Focus stays in, or returns to, the text input.
        if (self.firstEmbed(index)) |input| self.restore = self.buffers.nodes[input].id;
    }
    /// The first embedded leaf within the container at `index`; a container
    /// still open extends to the last node built.
    fn firstEmbed(self: *const View, index: u32) ?u32 {
        const all = self.buffers.nodes[0..self.len];
        const open_now = for (self.stack[0..self.depth]) |at| {
            if (at == index) break true;
        } else false;
        const stop = if (open_now) self.len else all[index].end;
        for (all[index + 1 .. stop], index + 1..) |*node, at| if (node.kind == .embed) return @intCast(at);
        return null;
    }
    /// What the text input of the anchor at `index` reports, if any.
    fn inputStatus(self: *const View, index: u32) EmbedStatus {
        const all = self.buffers.nodes[0..self.len];
        const at = if (all[index].kind == .embed) index else self.firstEmbed(index) orelse return .{};
        const content = all[at].embed orelse return .{};
        const status = content.status orelse return .{};
        return status(content.context);
    }

    /// The time of this pass in nanoseconds, from the host's monotonic clock.
    pub fn time(self: *const View) u64 {
        return self.now;
    }
    /// Ask for another pass at `deadline`, in the same clock as `time`. The
    /// earliest request of a pass wins; a host with a timer repaints then.
    pub fn wakeAt(self: *View, deadline: u64) void {
        self.wake = if (self.wake) |current| @min(current, deadline) else deadline;
    }

    /// Give the node just added a tooltip: `text` appears near it after the
    /// pointer rests on it or it holds focus for `Options.tooltip_delay`,
    /// and is announced as its description. A press or Escape hides it until
    /// the pointer or focus moves to another control. After `comboBox` and
    /// its options, it describes the combo box.
    pub fn tooltip(self: *View, value: []const u8) Error!void {
        if (self.depth == 0) return error.UnbalancedContainer;
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.last_child == none) return error.NotContainer;
        var target = &self.buffers.nodes[parent.last_child];
        if (target.kind == .popup) target = &self.buffers.nodes[target.anchor];
        target.tooltip = try self.copy(value);
    }

    /// A button with a chevron pointing along `direction`, such as Back or
    /// Forward in a page history. `Style.name` names it; the default is the
    /// direction in English. True once for the pass that delivers its
    /// activation.
    pub fn navButton(self: *View, direction: NavDirection, style: Style) Error!bool {
        const node = try self.append(.nav_button, style);
        node.direction = direction;
        node.text = try self.copy(if (style.name.len > 0) style.name else switch (direction) {
            .back => "Back",
            .forward => "Forward",
            .up => "Up",
            .down => "Down",
        });
        return self.take(node.id) != null;
    }

    /// A person or entity as a picture, or as the initials of `name` on a
    /// disk colored by `Style.background` or derived from the name. It is
    /// 32 DIP square unless `Style.width`/`height` say otherwise, takes no
    /// input and is announced as an image named `name`.
    pub fn avatar(self: *View, name: []const u8, picture: ?ImageView, style: Style) Error!void {
        const node = try self.append(.avatar, style);
        node.text = try self.copy(name);
        node.image = picture;
    }

    /// Starts a row holding a search input and its controls, announced as a
    /// search region named by `Style.name`. A gap of 8 DIP applies unless
    /// `Style.gap` is set. Close it with `end`.
    pub fn search(self: *View, style: Style) Error!void {
        var value = style;
        if (value.gap == 0) value.gap = 8;
        _ = try self.open(.search, value);
    }

    /// A field showing `current`, the label of the chosen option, that opens
    /// a list of options below it, or above when there is more room there.
    /// Build the options with `comboOption`, then close the list with `end`; they
    /// are measured every pass but only placed and drawn while it is open.
    /// Activation, Down or Up opens the list. While open, arrows and
    /// Home/End move the highlight, Enter or Space picks it, and Escape, a
    /// press outside or a pick closes it with focus back on the combo box.
    /// Named by `Style.name` or an enclosing field's label.
    pub fn comboBox(self: *View, current: []const u8, style: Style) Error!void {
        const anchor = try self.append(.combo_box, style);
        anchor.text = try self.copy(current);
        const id = anchor.id;
        const anchor_index: u32 = @intCast(anchor - self.buffers.nodes.ptr);
        if (self.take(id) != null and anchor.style.enabled) {
            const was_open = if (self.popup.open) |owner| owner == id else false;
            self.popup.open = if (was_open) null else id;
            self.popup.highlight = null;
            if (was_open) self.restore = id;
        }
        const list = try self.open(.popup, .{ .padding = Insets.all(4), .name = style.name });
        list.anchor = anchor_index;
    }
    /// An option of the open `comboBox` list: activation selects `value`,
    /// closes the list and returns focus to the combo box. True when the
    /// selection changed.
    pub fn comboOption(self: *View, comptime T: type, selected: *T, value: T, label: []const u8, style: Style) Error!bool {
        const list = self.enclosingPopup() orelse return error.NotContainer;
        const anchor = &self.buffers.nodes[list.anchor];
        if (anchor.kind != .combo_box) return error.NotContainer;
        const anchor_id = anchor.id;
        const node = try self.popupItem(list, label, style);
        var changed = false;
        if (self.take(node.id) != null) {
            changed = !std.meta.eql(selected.*, value);
            selected.* = value;
            self.popup.open = null;
            self.popup.highlight = null;
            self.restore = anchor_id;
        }
        node.checked = std.meta.eql(selected.*, value);
        return changed;
    }

    /// A field showing `value`, such as a chosen date, that opens a panel
    /// of its own: build a `popover` after it, shown while `expanded`.
    /// Drawn and announced like a combo box. True once for the pass that
    /// delivers its activation, by press, Enter or Space; flip the
    /// popover's flag in that branch. Named by `Style.name` or an enclosing
    /// field's label.
    pub fn popupButton(self: *View, value: []const u8, expanded: bool, style: Style) Error!bool {
        const node = try self.append(.popup_button, style);
        node.text = try self.copy(value);
        node.checked = expanded;
        return self.take(node.id) != null and node.style.enabled;
    }

    /// Starts a panel floating over the window beside the node just added,
    /// its anchor, shown while `is_open` is set: build its content only when
    /// this returns true, and close it with `end` either way. It goes where
    /// `placement` says, below the anchor by default. When it opens, focus
    /// moves to its first control. Escape, or a press outside the panel and
    /// its anchor, clears `is_open`; Escape, or the build clearing it while
    /// focus is inside, returns focus to the anchor, while a press outside
    /// leaves it where the press put it. A disabled anchor closes it. Named
    /// by `Style.name`; padding is 8 DIP unless set.
    pub fn popover(self: *View, is_open: *bool, placement: Placement, style: Style) Error!bool {
        if (self.depth == 0) return error.UnbalancedContainer;
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.last_child == none or self.buffers.nodes[parent.last_child].floats()) return error.NotContainer;
        const anchor_index = parent.last_child;
        if (!std.math.isFinite(placement.gap) or placement.gap < 0) return error.InvalidValue;
        var value = style;
        if (value.padding.top == 0 and value.padding.bottom == 0 and value.padding.left == 0 and value.padding.right == 0) value.padding = Insets.all(8);
        const node = try self.open(.popover, value);
        node.anchor = anchor_index;
        node.placement = placement;
        const id = node.id;
        const anchor = &self.buffers.nodes[anchor_index];
        if (self.popover_dismiss) |target| if (target == id) {
            self.popover_dismiss = null;
            is_open.* = false;
        };
        if (!anchor.style.enabled) is_open.* = false;
        node.checked = is_open.*;
        const shown = if (self.popover_shown) |current| current == id else false;
        if (is_open.* and !shown) {
            self.popover_shown = id;
            self.popover_within = false;
            self.popover_opened = id;
        } else if (!is_open.* and shown) {
            self.popover_shown = null;
            if (self.popover_within) self.restore = anchor.id;
            self.popover_within = false;
        }
        return is_open.*;
    }
    /// The first control within the container at `index` that can take
    /// focus, in build order.
    fn firstFocusable(self: *const View, index: u32) ?u32 {
        const all = self.buffers.nodes[0..self.len];
        for (all[index + 1 .. all[index].end], index + 1..) |*node, at| {
            if (!node.style.enabled) continue;
            const focusable = switch (node.kind) {
                .button, .link, .nav_button, .combo_box, .popup_button, .checkbox, .radio, .segment, .tab, .list_item, .disclosure, .toggle_switch, .slider, .stepper, .rating, .token => true,
                .embed => node.embed.?.focusable,
                else => false,
            };
            if (focusable) return @intCast(at);
        }
        return null;
    }

    /// Starts a list of suggestions for the node just added, usually a
    /// text input. The list opens below it while it or one of the
    /// suggestions has focus and at least one is built with `suggestion`;
    /// close it with `end`. Down, Up and Home/End move the highlight without
    /// moving focus, Enter picks the highlight, and Escape closes the list
    /// until its labels change. Named by `Style.name`.
    pub fn suggestions(self: *View, style: Style) Error!void {
        if (self.depth == 0) return error.UnbalancedContainer;
        const parent = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (parent.last_child == none or self.buffers.nodes[parent.last_child].floats()) return error.NotContainer;
        const anchor_index = parent.last_child;
        var value = style;
        if (value.padding.top == 0 and value.padding.bottom == 0 and value.padding.left == 0 and value.padding.right == 0) value.padding = Insets.all(4);
        const list = try self.open(.popup, value);
        list.anchor = anchor_index;
    }
    /// One suggestion. True once for the pass that picks it, by pointer or
    /// by Enter on the highlight; apply it to the input in that branch. The
    /// list then closes and focus returns to the input.
    pub fn suggestion(self: *View, label: []const u8, style: Style) Error!bool {
        const list = self.enclosingPopup() orelse return error.NotContainer;
        const anchor = &self.buffers.nodes[list.anchor];
        if (anchor.kind == .combo_box) return error.NotContainer;
        const anchor_id = anchor.id;
        const input_id = if (anchor.isContainer()) (if (self.firstEmbed(list.anchor)) |at| self.buffers.nodes[at].id else anchor_id) else anchor_id;
        const node = try self.popupItem(list, label, style);
        if (self.take(node.id) == null) return false;
        self.popup.highlight = null;
        self.popup.settle = anchor_id;
        if (self.popup.forced) |owner| if (owner == anchor_id) {
            self.popup.forced = null;
        };
        self.picked = true;
        self.restore = input_id;
        return true;
    }
    fn enclosingPopup(self: *const View) ?*Node {
        var depth = self.depth;
        while (depth > 1) {
            depth -= 1;
            const node = &self.buffers.nodes[self.stack[depth]];
            if (node.kind == .popup) return node;
        }
        return null;
    }
    fn popupItem(self: *View, list: *const Node, label: []const u8, style: Style) Error!*Node {
        const group = list.id;
        const node = try self.append(.list_item, style);
        node.text = try self.copy(label);
        node.radio_group = group;
        node.highlighted = if (self.popup.highlight) |id| id == node.id else false;
        return node;
    }
    /// Decide whether the popup closed at `index` is open, once its options
    /// are known, and keep the highlight on one of them.
    fn settlePopup(self: *View, index: u32) void {
        const all = self.buffers.nodes[0..self.len];
        const list = &all[index];
        const anchor = &all[list.anchor];
        const combo = anchor.kind == .combo_box;
        const editable = anchor.kind == .combo_field;
        const options_slice = all[index + 1 ..];
        var hasher = std.hash.Wyhash.init(anchor.id);
        var count: usize = 0;
        var selected: ?u64 = null;
        var focus_inside = if (self.focus) |id| id == anchor.id else false;
        // Focus on the input or button of an editable combo box or token
        // field is focus on the anchor.
        if (anchor.isContainer()) if (self.focus) |id| for (all[list.anchor..anchor.end]) |*inner| {
            if (inner.id == id) focus_inside = true;
        };
        var highlight_inside = false;
        for (options_slice) |*entry| {
            if (entry.kind != .list_item) continue;
            hasher.update(entry.text);
            hasher.update("\x00");
            count += 1;
            if (entry.checked and combo) selected = selected orelse entry.id;
            if (self.focus) |id| if (id == entry.id) {
                focus_inside = true;
            };
            if (self.popup.highlight) |id| if (id == entry.id) {
                highlight_inside = true;
            };
        }
        list.signature = hasher.final();
        const enabled = anchor.style.enabled;
        // While an input method composes, its candidate window owns the
        // keys and the options still describe the uncommitted text, so the
        // list stays hidden without forgetting why it was closed.
        if (!combo and self.inputStatus(list.anchor).composing) {
            list.checked = false;
            if (editable) anchor.checked = false;
            return;
        }
        const shown = if (combo) blk: {
            const owner = self.popup.open orelse break :blk false;
            if (owner != anchor.id) break :blk false;
            if (!enabled) self.popup.open = null;
            break :blk enabled;
        } else blk: {
            if (self.popup.settle) |owner| if (owner == anchor.id) {
                // A pick closes the list over the labels it produces, which
                // the next pass sees.
                self.popup.dismissed = anchor.id;
                self.popup.dismissed_signature = list.signature;
                if (!self.picked) self.popup.settle = null;
            };
            if (editable) self.trackComboField(anchor.id, focus_inside, list.signature);
            if (!focus_inside) {
                if (self.popup.dismissed) |owner| if (owner == anchor.id) {
                    if (self.popup.settle == null) self.popup.dismissed = null;
                };
                break :blk false;
            }
            if (self.popup.forced) |owner| if (owner == anchor.id) break :blk enabled and count > 0;
            if (self.popup.dismissed) |owner| if (owner == anchor.id) {
                if (self.popup.dismissed_signature == list.signature) break :blk false;
                self.popup.dismissed = null;
            };
            break :blk enabled and count > 0;
        };
        list.checked = shown;
        if (combo or editable) anchor.checked = shown;
        if (!shown) {
            if (highlight_inside) self.popup.highlight = null;
            return;
        }
        if (!highlight_inside) self.popup.highlight = selected;
        for (options_slice) |*entry| {
            if (entry.kind != .list_item) continue;
            entry.highlighted = if (self.popup.highlight) |id| id == entry.id else false;
            // A suggestion has no chosen value; the highlight is its selection.
            if (!combo) entry.checked = entry.highlighted;
        }
    }

    /// Keep an editable combo box closed when it gains focus, and forget
    /// an explicit opening or closing once focus leaves it.
    fn trackComboField(self: *View, id: u64, focus_inside: bool, signature: u64) void {
        const popup = &self.popup;
        if (popup.close) |owner| if (owner == id) {
            popup.close = null;
            popup.forced = null;
            popup.dismissed = id;
            popup.dismissed_signature = signature;
        };
        const within = if (popup.within) |owner| owner == id else false;
        if (focus_inside and !within) {
            popup.within = id;
            if (popup.forced == null or popup.forced.? != id) {
                popup.dismissed = id;
                popup.dismissed_signature = signature;
            }
        } else if (!focus_inside and within) {
            popup.within = null;
            if (popup.forced) |owner| if (owner == id) {
                popup.forced = null;
            };
        }
    }

    /// Starts the stack of `queue`'s messages, drawn over the window's
    /// bottom edge, newest last. Each message disappears after its duration,
    /// counted from the first pass that shows it, or when its close button
    /// is activated; its action button removes it and returns its id once.
    /// `queue` is a pointer to a `Toasts` value the application owns.
    pub fn toasts(self: *View, queue: anytype, style: Style) Error!?u64 {
        var value = style;
        if (value.gap == 0) value.gap = 8;
        _ = try self.open(.toasts, value);
        var acted: ?u64 = null;
        var index: usize = 0;
        while (index < queue.len) {
            const entry = &queue.entries[index];
            const shown = entry.shown orelse blk: {
                entry.shown = self.now;
                break :blk self.now;
            };
            if (entry.duration != 0) {
                const deadline = shown +| entry.duration;
                if (self.now >= deadline) {
                    queue.removeAt(index);
                    continue;
                }
                self.wakeAt(deadline);
            }
            const message = entry.message[0..entry.message_len];
            const action = entry.action[0..entry.action_len];
            const panel = try self.open(.toast, .{ .key = entry.id, .gap = 8, .padding = .{ .left = 12, .right = 4, .top = 4, .bottom = 4 }, .alignment = .center });
            panel.text = try self.copy(message);
            try self.text(message, .{ .grow = 1, .shrink = 1 });
            var remove = false;
            if (action.len > 0) if (try self.button(action, .{})) {
                acted = entry.id;
                remove = true;
            };
            if (try self.button("×", .{ .name = "Dismiss" })) remove = true;
            try self.end();
            if (remove) queue.removeAt(index) else index += 1;
        }
        try self.end();
        return acted;
    }

    /// Route a key to the open popup or the shown tooltip before normal
    /// focus handling, from the overlay of the last arranged pass. Call it
    /// with `focus` current. The host delivers any returned event and then
    /// focuses `restore`.
    pub fn routeKey(self: *View, input: z.KeyInput) KeyRoute {
        const mods = input.modifiers;
        const plain = !mods.control and !mods.alt and !mods.super and !mods.shift;
        const anchor = self.focusedAnchor();
        // Keys belong to the input method while it composes.
        if (anchor) |focused| if (focused.embed) |content| if (content.status) |status| {
            if (status(content.context).composing) return .ignored;
        };
        const alt_arrow = mods.alt and !mods.control and !mods.super and (input.key == .down or input.key == .up);
        const f4 = input.key == .f4 and !mods.control and !mods.alt and !mods.super;
        if (self.overlay.popup) |list| {
            if (list.editable and (alt_arrow or f4)) {
                self.closePopup(list, true);
                return .handled;
            }
            switch (input.key) {
                .escape => if (plain) {
                    self.closePopup(list, true);
                    return .handled;
                },
                .down, .up, .home, .end => if (plain) {
                    self.moveHighlight(input.key);
                    return .handled;
                },
                .enter, .space => if (plain and (input.key == .enter or list.combo)) {
                    if (input.repeat) return .handled;
                    if (self.popup.highlight) |id| return .{ .deliver = .{ .action = id } };
                    if (!list.combo) return .ignored;
                    self.closePopup(list, true);
                    return .handled;
                },
                .tab => if (!mods.control and !mods.alt and !mods.super) {
                    self.closePopup(list, list.combo);
                    return .pass;
                },
                else => {},
            }
            return .ignored;
        }
        if (self.overlay.popover) |panel| if (input.key == .escape and plain) {
            self.popover_dismiss = panel.id;
            self.popover_within = false;
            self.overlay.popover = null;
            self.restore = panel.anchor;
            return .handled;
        };
        if (self.routeRowKey(input)) |route| return route;
        if (self.routeTokenKey(input)) |route| return route;
        if (anchor) |focused| {
            const arrow = input.key == .down or input.key == .up;
            if (focused.combo and arrow and !mods.control and !mods.super and !mods.shift) return .{ .deliver = .{ .action = focused.id } };
            // The toggle_id, Down, Alt+Down and F4 open an editable combo box.
            if (focused.toggle) |toggle_id| if ((input.key == .down and plain) or alt_arrow or f4) return .{ .deliver = .{ .action = toggle_id } };
            // Down reopens suggestions that Escape closed.
            if (!focused.combo and input.key == .down and plain) if (self.popup.dismissed) |owner| if (owner == focused.id) {
                self.popup.dismissed = null;
                self.popup.settle = null;
                return .handled;
            };
        }
        if (input.key == .escape and plain and self.tip_index != none) {
            self.tip.dismissed = true;
            self.tip_index = none;
            return .handled;
        }
        return .ignored;
    }
    /// The combo box, suggestion input, editable combo box or token field
    /// whose control or input has focus.
    fn focusedAnchor(self: *const View) ?Overlay.Anchor {
        const focused = self.focus orelse return null;
        for (self.overlay.anchors[0..self.overlay.anchor_count]) |anchor| {
            if (anchor.id == focused) return anchor;
            if (anchor.input) |id| if (id == focused) return anchor;
        }
        return null;
    }

    /// Keys on a focused tree or table row.
    fn routeRowKey(self: *View, input: z.KeyInput) ?KeyRoute {
        const focused = self.focus orelse return null;
        const rows = self.overlay.rows[0..self.overlay.row_count];
        const at = for (rows, 0..) |current, i| {
            if (current.id == focused) break i;
        } else return null;
        const current = rows[at];
        const owner = for (self.overlay.collections[0..self.overlay.collection_count]) |entry| {
            if (entry.id == current.collection) break entry;
        } else return null;
        const mods = input.modifiers;
        if (mods.alt or mods.super) return null;
        const multiple = owner.multiple;
        var target: ?usize = null;
        switch (input.key) {
            .up, .down, .home, .end, .page_up, .page_down => {
                target = self.rowStep(at, input.key, owner.page);
                if (target == null) return .handled;
            },
            .right, .left => {
                // Table rows have no horizontal movement of their own.
                if (!owner.tree) return .handled;
                if (mods.control or mods.shift) return null;
                if (input.key == .right) {
                    if (current.expanded) |is_open| {
                        if (!is_open) return self.rowEvent(current, .expand, null);
                        // An is_open current's first child follows it directly.
                        if (at + 1 < rows.len and rows[at + 1].parent == at and rows[at + 1].enabled) target = at + 1;
                    }
                } else {
                    if (current.expanded) |is_open| if (is_open) return self.rowEvent(current, .collapse, null);
                    if (current.parent != none) target = current.parent;
                }
                if (target == null) return .handled;
                return self.rowEvent(rows[target.?], .select, null);
            },
            .space => {
                if (input.repeat) return .handled;
                if (multiple and mods.control) return self.rowEvent(current, .toggle, null);
                if (multiple and mods.shift) return self.rowEvent(current, .range, owner.anchor);
                return self.rowEvent(current, .select, null);
            },
            .enter => {
                if (input.repeat or mods.control or mods.shift) return .handled;
                return self.rowEvent(current, .activate, null);
            },
            .a => {
                if (!(mods.control and !mods.shift and multiple)) return null;
                return self.rowEvent(current, .select_all, null);
            },
            else => return null,
        }
        const next = rows[target.?];
        if (multiple and mods.control and mods.shift) return self.rowEvent(next, .range_add, owner.anchor);
        if (multiple and mods.control) return self.rowEvent(next, .cursor, null);
        if (multiple and mods.shift) return self.rowEvent(next, .range, owner.anchor);
        return self.rowEvent(next, .select, null);
    }
    fn rowEvent(_: *const View, target: Overlay.Row, op: ItemOp, anchor: ?u64) KeyRoute {
        return .{ .deliver = .{ .item = .{ .collection = target.collection, .item = target.item, .op = op, .anchor = anchor } } };
    }
    /// The enabled row of the same collection that a navigation key reaches
    /// from `at`, or null when it stays put.
    fn rowStep(self: *const View, at: usize, key_code: z.KeyCode, page: usize) ?usize {
        const rows = self.overlay.rows[0..self.overlay.row_count];
        const collection = rows[at].collection;
        const forward = key_code == .down or key_code == .end or key_code == .page_down;
        var count: usize = switch (key_code) {
            .up, .down => 1,
            .page_up, .page_down => @max(1, page),
            else => rows.len,
        };
        var index = at;
        var found: ?usize = null;
        while (count > 0) {
            const next = if (forward) (if (index + 1 < rows.len) index + 1 else break) else (if (index > 0) index - 1 else break);
            index = next;
            if (rows[next].collection != collection or !rows[next].enabled) continue;
            found = next;
            count -= 1;
        }
        return if (found) |value| (if (value == at) null else value) else null;
    }

    /// Keys on a focused token, or in the empty input of a token field.
    fn routeTokenKey(self: *View, input: z.KeyInput) ?KeyRoute {
        const focused = self.focus orelse return null;
        const mods = input.modifiers;
        if (mods.control or mods.alt or mods.super or mods.shift) return null;
        const tokens = self.overlay.tokens[0..self.overlay.token_count];
        for (self.overlay.token_fields[0..self.overlay.token_field_count]) |owner| {
            const input_id = owner.input orelse continue;
            if (input_id != focused or (input.key != .backspace and input.key != .left)) continue;
            const content = owner.embed orelse return null;
            const status = content.status orelse return null;
            if (!status(content.context).empty) return null;
            var last: ?u64 = null;
            for (tokens) |entry| if (entry.field == owner.id and entry.enabled) {
                last = entry.id;
            };
            self.restore = last orelse return null;
            return .handled;
        }
        const at = for (tokens, 0..) |entry, i| {
            if (entry.id == focused) break i;
        } else return null;
        const current = tokens[at];
        switch (input.key) {
            .backspace, .delete => {
                if (input.repeat and input.key == .delete) return .handled;
                return .{ .deliver = .{ .action = current.remove } };
            },
            .left, .right, .home, .end => {
                var target: ?u64 = null;
                for (tokens, 0..) |entry, i| {
                    if (entry.field != current.field or !entry.enabled) continue;
                    switch (input.key) {
                        .left => if (i < at) {
                            target = entry.id;
                        },
                        .right => if (i > at and target == null) {
                            target = entry.id;
                        },
                        .home => if (target == null) {
                            target = entry.id;
                        },
                        else => target = entry.id,
                    }
                }
                // Right from the last token, or End, goes on to the input.
                if (input.key == .right or input.key == .end) if (target == null or input.key == .end) {
                    for (self.overlay.token_fields[0..self.overlay.token_field_count]) |owner| if (owner.id == current.field) {
                        target = owner.input orelse target;
                    };
                };
                self.restore = target orelse return .handled;
                return .handled;
            },
            else => return null,
        }
    }

    /// Route a primary press with its modifiers on a tree or table row,
    /// before the Context sees it: Ctrl toggles and Shift extends a multiple
    /// selection, and the triangle of a tree row expands or collapses it.
    /// `hit` is the control the Context finds under the point, so presses on
    /// controls inside a row stay theirs. Null when the press is not on a row.
    pub fn rowPress(self: *const View, point: Point, modifiers: z.KeyModifiers, hit: ?u64, theme: Theme) ?Event {
        const rows = self.overlay.rows[0..self.overlay.row_count];
        var index = rows.len;
        while (index > 0) {
            index -= 1;
            const candidate = rows[index];
            if (!contains(candidate.rect, point)) continue;
            if (hit) |id| if (id != candidate.id) return null;
            if (!candidate.enabled) return null;
            const owner = for (self.overlay.collections[0..self.overlay.collection_count]) |entry| {
                if (entry.id == candidate.collection) break entry;
            } else return null;
            var op: ItemOp = .select;
            var anchor: ?u64 = null;
            if (candidate.expanded) |is_open| if (contains(ui.widgets.treeExpander(candidate.bounds, candidate.level, theme.metrics.indicator_size), point)) {
                op = if (is_open) .collapse else .expand;
            };
            if (op == .select and owner.multiple) {
                if (modifiers.control and modifiers.shift) {
                    op = .range_add;
                    anchor = owner.anchor;
                } else if (modifiers.control) op = .toggle else if (modifiers.shift) {
                    op = .range;
                    anchor = owner.anchor;
                }
            }
            return .{ .item = .{ .collection = candidate.collection, .item = candidate.item, .op = op, .anchor = anchor } };
        }
        return null;
    }
    fn closePopup(self: *View, list: Overlay.Popup, restore: bool) void {
        if (list.combo) self.popup.open = null else {
            self.popup.dismissed = list.anchor;
            self.popup.dismissed_signature = list.signature;
            if (self.popup.forced) |owner| if (owner == list.anchor) {
                self.popup.forced = null;
            };
        }
        self.popup.highlight = null;
        self.overlay.popup = null;
        if (restore) self.restore = list.input;
    }
    fn moveHighlight(self: *View, key_code: z.KeyCode) void {
        const items = self.overlay.items[0..self.overlay.item_count];
        if (items.len == 0) return;
        var current: ?usize = null;
        if (self.popup.highlight) |id| for (items, 0..) |region, i| {
            if (region.id == id) current = i;
        };
        const next: usize = switch (key_code) {
            .home => 0,
            .end => items.len - 1,
            .down => if (current) |i| (i + 1) % items.len else 0,
            else => if (current) |i| (i + items.len - 1) % items.len else items.len - 1,
        };
        self.popup.highlight = items[next].id;
        self.reveal = items[next].id;
    }

    /// Route a primary press before normal input: it hides a shown tooltip,
    /// and outside the open popup it closes the popup. A press outside a
    /// combo box list is consumed, as is one on the list between options.
    /// A press outside a shown popover and its anchor closes the popover
    /// and goes on to what lies under it.
    pub fn pointerDown(self: *View, point: Point) PointerRoute {
        var result: PointerRoute = .ignored;
        if (self.tip.target != null and !self.tip.dismissed) {
            self.tip.dismissed = true;
            if (self.tip_index != none) result = .changed;
        }
        if (self.overlay.popover) |panel| if (!contains(panel.rect, point) and !contains(panel.anchor_rect, point)) {
            self.popover_dismiss = panel.id;
            self.popover_within = false;
            self.overlay.popover = null;
            result = .changed;
        };
        const list = self.overlay.popup orelse return result;
        if (contains(list.rect, point)) {
            for (self.overlay.items[0..self.overlay.item_count]) |region| if (contains(region.rect, point)) return result;
            return .consumed;
        }
        if (contains(list.anchor_rect, point)) return result;
        self.closePopup(list, false);
        return if (list.combo) .consumed else .changed;
    }

    /// Record the pointer position, or null when it left the window, for
    /// tooltips; true when the control under it changed and the window
    /// should repaint.
    fn interactiveEmbed(self: *const View, id: ?u64) ?*const Overlay.Interactive {
        const wanted = id orelse return null;
        for (self.overlay.embeds[0..self.overlay.embed_count]) |*entry| if (entry.id == wanted) return entry;
        return null;
    }
    /// The topmost interactive embedded leaf at `point`; none while an
    /// open list covers it.
    fn embedAt(self: *const View, point: Point) ?*const Overlay.Interactive {
        if (self.overlay.popup) |list| if (contains(list.rect, point)) return null;
        const panel = self.popoverAt(point);
        var index = self.overlay.embed_count;
        while (index > 0) {
            index -= 1;
            const entry = &self.overlay.embeds[index];
            if (!contains(entry.rect, point)) continue;
            // A shown popover covers the leaves under it.
            if (panel) |rect| if (!inside(entry.rect, rect)) continue;
            return entry;
        }
        return null;
    }
    /// The shown popover's panel when `point` is on it.
    fn popoverAt(self: *const View, point: Point) ?Rect {
        const panel = self.overlay.popover orelse return null;
        return if (contains(panel.rect, point)) panel.rect else null;
    }
    fn local(entry: *const Overlay.Interactive, point: Point) Point {
        return .{ .x = point.x - entry.bounds.x, .y = point.y - entry.bounds.y };
    }
    /// Move the pointer to `point`, or off the window when null: the leaf
    /// it left sees `pointer_leave` and the leaf under it `pointer_move`.
    /// True when a leaf asked to repaint.
    pub fn embedPointerMove(self: *View, point: ?Point) bool {
        const target = if (point) |at| self.embedAt(at) else null;
        var repaint = false;
        if (self.embed_hover) |previous| if (target == null or target.?.id != previous) {
            if (self.interactiveEmbed(previous)) |entry| repaint = entry.embed.input.?(entry.embed.context, entry.id, .pointer_leave);
        };
        self.embed_hover = if (target) |entry| entry.id else null;
        if (target) |entry| repaint = entry.embed.input.?(entry.embed.context, entry.id, .{ .pointer_move = local(entry, point.?) }) or repaint;
        return repaint;
    }
    /// A primary press at `point`, routed after `pointerDown`. The leaf
    /// under it sees `pointer_down`; one that takes it captures the pointer
    /// and, when focusable, takes focus. Otherwise a press on a draggable
    /// area, a drag source, a reorderable item or a row of a tree or table
    /// that drag-selects is followed, and drags once it moves
    /// `drag_threshold`. `adjusting` tells that the press landed on a
    /// control that drags its own value, such as a slider, which keeps it.
    /// `now` is the time of the press, which counts double presses.
    pub fn pointerPress(self: *View, point: Point, modifiers: z.KeyModifiers, now: u64, adjusting: bool) PointerResult {
        var result: PointerResult = .{};
        self.capture = null;
        self.drop_over = null;
        self.drag_base_taken = false;
        if (self.embedAt(point)) |entry| {
            const last = self.last_press;
            const again = last.id == entry.id and now >= last.time and now - last.time <= double_press_time and distance(last.at, point) <= double_press_distance;
            const count: u8 = if (again) last.count +| 1 else 1;
            self.last_press = .{ .id = entry.id, .time = now, .at = point, .count = count };
            if (entry.embed.input.?(entry.embed.context, entry.id, .{ .pointer_down = .{ .position = local(entry, point), .count = count, .modifiers = modifiers } })) {
                self.capture = .{ .target = .{ .embed = entry.id }, .origin = point, .position = point, .modifiers = modifiers };
                result.consumed = true;
                result.repaint = true;
                result.settle = true;
                if (entry.embed.focusable) result.focus = entry.id;
                return result;
            }
        } else self.last_press.id = 0;
        if (adjusting) return result;
        const target = self.pressTarget(point, modifiers) orelse return result;
        self.capture = .{ .target = target, .origin = point, .position = point, .modifiers = modifiers };
        return result;
    }

    /// The innermost thing under `point` that a drag from it moves.
    fn pressTarget(self: *const View, point: Point, modifiers: z.KeyModifiers) ?Capture.Target {
        var best: ?Capture.Target = null;
        var depth: u32 = 0;
        for (self.overlay.regions[0..self.overlay.region_count]) |region| {
            if (region.role == .target or !contains(region.rect, point) or (best != null and region.index < depth)) continue;
            best = if (region.role == .area) .{ .area = region.id } else .{ .source = .{ .id = region.id, .payload = region.payload } };
            depth = region.index;
        }
        for (self.overlay.lists[0..self.overlay.list_count]) |list| {
            for (self.overlay.reorder_items[list.first..][0..list.count], 0..) |entry, at| {
                if (!contains(entry.rect, point) or (best != null and entry.index < depth)) continue;
                best = .{ .reorder = .{ .list = list.id, .from = at, .to = at } };
                depth = entry.index;
            }
        }
        for (self.overlay.rows[0..self.overlay.row_count]) |line| {
            if (!line.enabled or !contains(line.rect, point) or (best != null and line.index < depth)) continue;
            const owner = self.collectionEntry(line.collection) orelse continue;
            if (!owner.drag_select) continue;
            best = .{ .select = .{ .collection = line.collection, .item = line.item, .add = modifiers.control and owner.multiple, .last = line.item } };
            depth = line.index;
        }
        return best;
    }
    fn collectionEntry(self: *const View, id: u64) ?Overlay.Collection {
        for (self.overlay.collections[0..self.overlay.collection_count]) |entry| if (entry.id == id) return entry;
        return null;
    }

    /// The pointer moved to `point` while a press is followed. Null when
    /// none is, or it has not moved far enough to drag, so the move goes
    /// on to hover and the controls.
    pub fn captureMove(self: *View, point: Point) ?PointerResult {
        const capture = if (self.capture) |*value| value else return null;
        var result: PointerResult = .{};
        const delta: Point = .{ .x = point.x - capture.position.x, .y = point.y - capture.position.y };
        capture.position = point;
        const started = !capture.dragging and distance(capture.origin, point) >= drag_threshold;
        if (started) capture.dragging = true;
        if (capture.target == .embed) {
            result.consumed = true;
            const entry = self.interactiveEmbed(capture.target.embed) orelse {
                self.capture = null;
                return result;
            };
            result.repaint = entry.embed.input.?(entry.embed.context, entry.id, .{ .pointer_drag = .{ .position = local(entry, point), .origin = local(entry, capture.origin), .delta = delta, .dragging = capture.dragging } });
            result.settle = result.repaint;
            return result;
        }
        if (!capture.dragging) return null;
        result.consumed = true;
        result.repaint = true;
        result.cancel_press = started;
        switch (capture.target) {
            .embed => unreachable,
            .area => |id| result.push(.{ .drag = .{ .id = id, .phase = if (started) .start else .move, .origin = capture.origin, .position = point, .delta = if (started) .{ .x = point.x - capture.origin.x, .y = point.y - capture.origin.y } else delta, .modifiers = capture.modifiers } }),
            .source => |source| {
                self.drop_over = self.dropTargetAt(point, .{ .value = source.payload });
                if (self.edgeScroll(self.scrollAt(point), point)) |event| result.push(event);
            },
            .reorder => |*value| {
                const list = self.reorderList(value.list) orelse {
                    self.capture = null;
                    return result;
                };
                value.to = self.reorderSlot(list, point);
                if (self.edgeScroll(list.scroll, point)) |event| result.push(event);
            },
            .select => |*value| {
                const under = self.rowUnder(value.collection, point) orelse value.last;
                if (started or under != value.last) result.push(.{ .item = .{ .collection = value.collection, .item = under, .op = .drag, .anchor = value.item, .add = value.add } });
                value.last = under;
                if (self.collectionEntry(value.collection)) |owner| if (self.edgeScroll(owner.scroll, point)) |event| result.push(event);
            },
        }
        return result;
    }

    /// The primary button was released at `point`. A leaf holding the
    /// capture sees `pointer_up`; a drag ends, delivering its drop, and its
    /// press activates nothing. A press that never dragged is left to the
    /// controls, as a click.
    pub fn captureRelease(self: *View, point: Point) PointerResult {
        var result: PointerResult = .{};
        const capture = self.capture orelse return result;
        self.capture = null;
        self.drop_over = null;
        if (capture.target == .embed) {
            result.consumed = true;
            const entry = self.interactiveEmbed(capture.target.embed) orelse return result;
            result.repaint = entry.embed.input.?(entry.embed.context, entry.id, .{ .pointer_up = local(entry, point) });
            result.settle = result.repaint;
            return result;
        }
        if (!capture.dragging) return result;
        result.consumed = true;
        result.repaint = true;
        result.cancel_press = true;
        switch (capture.target) {
            .embed => unreachable,
            .area => |id| result.push(.{ .drag = .{ .id = id, .phase = .end, .origin = capture.origin, .position = point, .delta = .{ .x = point.x - capture.position.x, .y = point.y - capture.position.y }, .modifiers = capture.modifiers } }),
            .source => |source| if (self.dropTargetAt(point, .{ .value = source.payload })) |id| {
                result.push(.{ .drop = .{ .id = id, .data = .{ .value = source.payload }, .position = point } });
            },
            .reorder => |value| {
                const list = self.reorderList(value.list) orelse return result;
                const to = self.reorderSlot(list, point);
                // An item dropped where it is stays.
                if (to != value.from and to != value.from + 1) result.push(.{ .reorder = .{ .id = value.list, .move = .{ .from = value.from, .to = to } } });
            },
            .select => {},
        }
        return result;
    }

    /// The press was lost before its release: the window lost focus or the
    /// capture, or Escape gave the drag up. A leaf holding the capture sees
    /// `pointer_cancel`, a draggable area a `.cancel` drag, and a drag of a
    /// payload or an item drops nothing.
    pub fn captureCancel(self: *View) PointerResult {
        var result: PointerResult = .{};
        const capture = self.capture orelse return result;
        self.capture = null;
        self.drop_over = null;
        switch (capture.target) {
            .embed => |id| {
                const entry = self.interactiveEmbed(id) orelse return result;
                result.repaint = entry.embed.input.?(entry.embed.context, entry.id, .pointer_cancel);
                result.settle = result.repaint;
            },
            .area => |id| if (capture.dragging) result.push(.{ .drag = .{ .id = id, .phase = .cancel, .origin = capture.origin, .position = capture.position, .delta = .{}, .modifiers = capture.modifiers } }),
            else => {},
        }
        if (capture.dragging) {
            result.repaint = true;
            result.cancel_press = true;
        }
        return result;
    }

    /// Escape during a drag gives it up; null for any other key, or when
    /// nothing drags. A leaf holding the capture handles its own keys.
    pub fn dragKey(self: *View, input: z.KeyInput) ?PointerResult {
        const capture = self.capture orelse return null;
        if (input.key != .escape or !capture.dragging or capture.target == .embed) return null;
        var result = self.captureCancel();
        result.consumed = true;
        return result;
    }

    /// Wheel movement at `point`: the interactive leaf under it sees it
    /// first; true when it took it.
    pub fn embedWheel(self: *View, point: Point, delta: Point) bool {
        const entry = self.embedAt(point) orelse return false;
        return entry.embed.input.?(entry.embed.context, entry.id, .{ .wheel = .{ .position = local(entry, point), .delta = delta } });
    }

    /// The innermost visible scroll container at `point`.
    pub fn scrollAt(self: *const View, point: Point) ?u64 {
        var index = self.overlay.scroll_count;
        while (index > 0) {
            index -= 1;
            const region = self.overlay.scrolls[index];
            if (contains(region.rect, point)) return region.id;
        }
        return null;
    }

    /// A scroll of the container `id` toward the pointer near or past its
    /// top or bottom edge, faster nearer and past it.
    fn edgeScroll(self: *const View, id: ?u64, point: Point) ?Event {
        const wanted = id orelse return null;
        for (self.overlay.scrolls[0..self.overlay.scroll_count]) |region| {
            if (region.id != wanted) continue;
            const r = region.rect;
            const top = point.y - r.y;
            const bottom = r.y + r.height - point.y;
            const dy: f32 = if (top < drag_scroll_edge) -@min(drag_scroll_edge - top, 2 * drag_scroll_edge) / 2 else if (bottom < drag_scroll_edge) @min(drag_scroll_edge - bottom, 2 * drag_scroll_edge) / 2 else 0;
            if (dy == 0) return null;
            return .{ .scroll = .{ .id = wanted, .delta = .{ .x = 0, .y = dy } } };
        }
        return null;
    }

    /// The innermost drop target at `point` that takes `offer`.
    fn dropTargetAt(self: *const View, point: Point, offer: Offer) ?u64 {
        var index = self.overlay.region_count;
        while (index > 0) {
            index -= 1;
            const region = self.overlay.regions[index];
            if (region.role == .target and contains(region.rect, point) and region.accept.takes(offer)) return region.id;
        }
        return null;
    }

    fn reorderList(self: *const View, id: u64) ?Overlay.ReorderList {
        for (self.overlay.lists[0..self.overlay.list_count]) |list| if (list.id == id) return list;
        return null;
    }
    /// The item before which an item dropped at `point` goes: the first
    /// whose middle is past the point along the list, or the count of items.
    fn reorderSlot(self: *const View, list: Overlay.ReorderList, point: Point) usize {
        for (self.overlay.reorder_items[list.first..][0..list.count], 0..) |entry, at| {
            const b = entry.bounds;
            const past = if (list.axis == .row) point.x < b.x + b.width / 2 else point.y < b.y + b.height / 2;
            if (past) return at;
        }
        return list.count;
    }

    /// The application id of the visible row of `collection` level with
    /// `point`, or the first or last visible row when the point is above or
    /// below them.
    fn rowUnder(self: *const View, collection: u64, point: Point) ?u64 {
        var first: ?Overlay.Row = null;
        var last: ?Overlay.Row = null;
        for (self.overlay.rows[0..self.overlay.row_count]) |line| {
            if (line.collection != collection or !line.enabled or !(line.rect.height > 0)) continue;
            if (point.y >= line.rect.y and point.y < line.rect.y + line.rect.height) return line.item;
            if (first == null) first = line;
            last = line;
        }
        const top = first orelse return null;
        if (point.y < top.rect.y) return top.item;
        const bottom = last.?;
        if (point.y >= bottom.rect.y + bottom.rect.height) return bottom.item;
        return null;
    }

    /// Follow a drag from another application at `point`, or off the window
    /// with null, offering files or text; true when a drop target there
    /// takes it. `changed` tells that the target under it changed.
    pub fn systemDragOver(self: *View, point: ?Point, files: bool, plain: bool) struct { accepted: bool, changed: bool } {
        const before: ?u64 = if (self.system_drag) |drag| drag.over else null;
        const over = if (point) |at| self.dropTargetAt(at, .{ .files = files, .text = plain }) else null;
        self.system_drag = if (point != null) .{ .over = over, .files = files, .text = plain } else null;
        return .{ .accepted = over != null, .changed = !std.meta.eql(before, over) };
    }
    /// A drop from another application at `point`: the event that delivers
    /// it to the drop target there, or null when none takes it.
    pub fn systemDrop(self: *View, point: Point, data: Dropped) ?Event {
        self.system_drag = null;
        const offer: Offer = switch (data) {
            .files => .{ .files = true },
            .text => .{ .text = true },
            .value => |payload| .{ .value = payload },
        };
        const id = self.dropTargetAt(point, offer) orelse return null;
        return .{ .drop = .{ .id = id, .data = data, .position = point } };
    }
    /// A key for the focused leaf; true when it consumed the key.
    pub fn embedKey(self: *View, input: z.KeyInput) bool {
        const entry = self.interactiveEmbed(self.focus) orelse return false;
        return entry.embed.input.?(entry.embed.context, entry.id, .{ .key = input });
    }
    /// A key release for the focused leaf; true when it consumed it.
    pub fn embedKeyUp(self: *View, input: z.KeyInput) bool {
        const entry = self.interactiveEmbed(self.focus) orelse return false;
        return entry.embed.input.?(entry.embed.context, entry.id, .{ .key_up = input });
    }
    /// Ask the host to give keyboard focus to the focusable embedded leaf
    /// `id`, as its `place` or `paint` learned it, after this pass; a leaf
    /// that is not built by then is left unfocused.
    pub fn focusLeaf(self: *View, id: u64) void {
        self.focus_request = id;
    }
    /// Node `id` holds keyboard focus and its window has the keyboard.
    pub fn hasKeyboard(self: *const View, id: u64) bool {
        return self.window_focused and self.focus == id;
    }
    /// Ask assistive technology to announce `message` politely, as a status
    /// update with no visible text; longer text is cut at a character
    /// boundary. Takes effect from the next paint.
    pub fn announce(self: *View, message: []const u8) void {
        var length = @min(message.len, max_announcement);
        while (length > 0 and length < message.len and message[length] & 0xc0 == 0x80) length -= 1;
        @memcpy(self.announcement[0..length], message[0..length]);
        self.announcement_len = length;
        self.announcement_serial +%= 1;
    }
    pub fn hoverAt(self: *View, point: ?Point) bool {
        var target: ?u64 = null;
        if (point) |at| find: {
            if (self.overlay.popup) |list| if (contains(list.rect, at)) break :find;
            const panel = self.popoverAt(at);
            var index = self.overlay.tip_count;
            while (index > 0) {
                index -= 1;
                const region = self.overlay.tips[index];
                if (panel) |rect| if (!inside(region.rect, rect)) continue;
                if (contains(region.rect, at)) {
                    target = region.id;
                    break;
                }
            }
        }
        if (std.meta.eql(target, self.tip.hover)) return false;
        self.tip.hover = target;
        return true;
    }

    /// Choose the tooltip this pass shows, from hover first and then focus,
    /// and ask for a pass when its delay ends.
    fn settleTooltip(self: *View) void {
        const all = self.buffers.nodes[0..self.len];
        var candidate: u32 = none;
        inline for (.{ self.tip.hover, self.focus }) |wanted| if (candidate == none) if (wanted) |id| {
            for (all, 0..) |*node, i| if (node.id == id and node.tooltip.len > 0) {
                candidate = @intCast(i);
                break;
            };
        };
        const target: ?u64 = if (candidate == none) null else all[candidate].id;
        if (!std.meta.eql(target, self.tip.target)) {
            self.tip.target = target;
            self.tip.since = self.now;
            self.tip.dismissed = false;
        }
        if (candidate == none or self.tip.dismissed) return;
        const due = self.tip.since +| self.tooltip_delay;
        if (self.now >= due) self.tip_index = candidate else self.wakeAt(due);
    }

    /// Add a self-describing leaf; see `Embed`.
    pub fn embed(self: *View, content: Embed, style: Style) Error!void {
        const node = try self.append(.embed, style);
        node.embed = content;
    }

    /// Starts an area the pointer drags, laid out as a column. A primary
    /// press on it that moves `drag_threshold` starts a drag, followed
    /// wherever the pointer goes until the release, which ends it, or until
    /// Escape, focus loss or a lost capture cancels it. Each phase arrives
    /// in a pass of its own that updates `gesture` and returns the phase;
    /// other passes return null. A press on a button inside still clicks it
    /// unless it moves far enough to drag; sliders, splits and embedded
    /// leaves that take the press keep it. An area no longer built loses
    /// its drag, and the next build after that returns `.cancel` once.
    /// Close it with `end`.
    pub fn draggable(self: *View, gesture: *Gesture, style: Style) Error!?DragPhase {
        const node = try self.open(.drag_area, style);
        if (self.take(node.id)) |event| if (event == .drag) {
            const drag = event.drag;
            gesture.origin = drag.origin;
            gesture.position = drag.position;
            gesture.delta = drag.delta;
            gesture.modifiers = drag.modifiers;
            gesture.dragging = drag.phase == .start or drag.phase == .move;
            return drag.phase;
        };
        if (gesture.dragging and !self.dragging(.area, node.id)) {
            gesture.dragging = false;
            gesture.delta = .{};
            return .cancel;
        }
        return null;
    }

    /// Starts a drag source, laid out as a column: a primary press on it
    /// that moves `drag_threshold` drags `payload` within the window. A copy
    /// of it follows the pointer, and the innermost `dropTarget` under the
    /// pointer that takes the payload's kind gets it when released; Escape
    /// gives the drag up. Controls inside keep their clicks unless the press
    /// drags. True while it is dragged, to show it dimmed. Close it with
    /// `end`.
    pub fn dragSource(self: *View, payload: Payload, style: Style) Error!bool {
        const node = try self.open(.drag_source, style);
        node.payload = payload;
        return self.dragging(.source, node.id);
    }

    /// Starts a drop target, laid out as a column, that takes what `accept`
    /// names: payloads of its kind dragged from a `dragSource`, and files
    /// or text dragged in from other applications when the application
    /// routes them through `Host.systemDragOver` and `Host.systemDrop`.
    /// While a drag it takes is over it, it is outlined and returns `.over`;
    /// in the pass delivering a drop it returns `.dropped`. Close it with
    /// `end`.
    pub fn dropTarget(self: *View, accept: Accept, style: Style) Error!DropState {
        const node = try self.open(.drop_target, style);
        node.accept = accept;
        if (self.take(node.id)) |event| if (event == .drop) return .{ .dropped = .{ .data = event.drop.data, .position = event.drop.position } };
        if (self.drop_over) |over| if (over == node.id) if (self.capture) |capture| switch (capture.target) {
            .source => |source| return .{ .over = .{ .value = source.payload } },
            else => {},
        };
        if (self.system_drag) |drag| if (drag.over) |over| if (over == node.id) return .{ .over = .{ .files = drag.files, .text = drag.text } };
        return .none;
    }

    /// Let the pointer drag the items of the container just opened to
    /// another place among them: the rows of a table, the options of a list
    /// box, or the children of a column or row. Call it before building any
    /// item. A primary press on an item that moves `drag_threshold` picks it
    /// up; a copy follows the pointer, a line shows where it would go, and
    /// near or past the edge of a scroll container around the items the
    /// drag scrolls it. The release returns the move in its own pass; the
    /// application moves its items. Escape gives the drag up. A tree cannot
    /// reorder, and a table cannot both reorder and `dragSelect`.
    pub fn reorder(self: *View) Error!?Move {
        const index = self.stack[self.depth - 1];
        if (index == 0) return error.NotContainer;
        const node = &self.buffers.nodes[index];
        if (node.kind == .tree or node.drag_select) return error.InvalidValue;
        if (node.kind != .table and node.child_count != 0) return error.InvalidValue;
        node.reorder = true;
        if (self.take(node.id)) |event| if (event == .reorder) return event.reorder.move;
        return null;
    }

    /// Let a primary drag from a row of the tree or table just opened select
    /// the rows from that row to the one under the pointer, as Shift and a
    /// press would; with Ctrl held as the press began, it adds them to the
    /// rows already selected. Near or past the edge of a scroll container
    /// around the collection, the drag scrolls it.
    pub fn dragSelect(self: *View) Error!void {
        const node = &self.buffers.nodes[self.stack[self.depth - 1]];
        if (node.kind != .tree and node.kind != .table) return error.NotContainer;
        if (node.reorder) return error.InvalidValue;
        node.drag_select = true;
    }

    /// True while a press that began on the node with `id` drags it.
    fn dragging(self: *const View, comptime role: std.meta.Tag(Capture.Target), id: u64) bool {
        const capture = self.capture orelse return false;
        if (!capture.dragging) return false;
        return switch (capture.target) {
            .area => |value| role == .area and value == id,
            .source => |value| role == .source and value.id == id,
            else => false,
        };
    }

    fn captureBuilt(self: *const View, target: Capture.Target) bool {
        for (self.buffers.nodes[0..self.len]) |*node| switch (target) {
            .embed => |id| if (node.id == id and node.kind == .embed and node.embed.?.input != null) return true,
            .area => |id| if (node.id == id and node.kind == .drag_area) return true,
            .source => |source| if (node.id == source.id and node.kind == .drag_source) return true,
            .reorder => |value| if (node.id == value.list and node.reorder) return true,
            .select => |value| if (node.id == value.collection and node.drag_select) return true,
        };
        return false;
    }

    /// Validate balance after the build function returns.
    pub fn finish(self: *View) Error!void {
        if (self.depth != 1) return error.UnbalancedContainer;
        self.buffers.nodes[0].end = self.len;
        // A press on something no longer built is no longer followed; a
        // leaf that is gone is never called again.
        if (self.capture) |capture| if (!self.captureBuilt(capture.target)) {
            self.capture = null;
            self.drop_over = null;
        };
        // A combo box that is no longer built cannot keep its list open.
        if (self.popup.open) |owner| {
            const present = for (self.buffers.nodes[0..self.len]) |*node| {
                if (node.id == owner and node.kind == .combo_box) break true;
            } else false;
            if (!present) self.popup.open = null;
        }
        // Nor does a popover that is no longer built stay pending.
        inline for (.{ &self.popover_shown, &self.popover_dismiss }) |slot| if (slot.*) |owner| {
            const present = for (self.buffers.nodes[0..self.len]) |*node| {
                if (node.id == owner and node.kind == .popover) break true;
            } else false;
            if (!present) slot.* = null;
        };
        self.settleTooltip();
    }

    fn intrinsic(node: *const Node, theme: Theme, measurer: Measurer) layout.Measurement {
        if (node.embed) |content| return content.measure(content.context, theme);
        const metrics = theme.metrics;
        const font = if (node.kind == .text) node.style.font else null;
        const text_size = if (node.text.len > 0) measurer.textSize(node.text, font) else if (font) |value| measurer.textSize("", value) else Size{ .width = 0, .height = Measurer.line_height };
        const size: Size = switch (node.kind) {
            .text, .note => text_size,
            .spacer => .{},
            .list_item => .{ .width = text_size.width + 2 * metrics.content_inset, .height = text_size.height + metrics.content_inset },
            .button, .tab, .segment => .{ .width = text_size.width + 2 * (metrics.content_inset + 8), .height = @max(text_size.height, metrics.indicator_size) + 2 * metrics.content_inset },
            .nav_button => blk: {
                const side = @max(Measurer.line_height, metrics.indicator_size) + 2 * metrics.content_inset;
                break :blk .{ .width = side, .height = side };
            },
            .combo_box, .popup_button => .{ .width = @max(120, text_size.width + 3 * metrics.content_inset + metrics.indicator_size), .height = @max(text_size.height, metrics.indicator_size) + 2 * metrics.content_inset },
            .tree_row => .{ .width = ui.widgets.tree_indent * @as(f32, @floatFromInt(node.level)) + metrics.indicator_size + metrics.label_gap / 2 + text_size.width + metrics.content_inset, .height = text_size.height + metrics.content_inset },
            .column_header => .{ .width = text_size.width + metrics.indicator_size, .height = text_size.height + metrics.content_inset },
            .token => .{ .width = text_size.width + metrics.content_inset + text_size.height + 4, .height = text_size.height + 4 },
            .combo_toggle => .{ .width = metrics.indicator_size + metrics.content_inset, .height = metrics.indicator_size },
            .avatar => .{ .width = 32, .height = 32 },
            .link => .{ .width = text_size.width + 2 * metrics.content_inset, .height = text_size.height + 2 * metrics.content_inset },
            .badge => .{ .width = text_size.width + 2 * (metrics.content_inset + 4), .height = text_size.height + metrics.content_inset },
            .disclosure => .{ .width = metrics.indicator_size + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .checkbox, .radio => .{ .width = metrics.indicator_size + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .toggle_switch => .{ .width = metrics.indicator_size * 1.7 + metrics.label_gap + text_size.width, .height = @max(text_size.height, metrics.indicator_size) + metrics.content_inset },
            .progress, .meter => .{ .width = 160, .height = 12 },
            .loading => .{ .width = node.indicator.?.size * node.indicator.?.kind.aspect(), .height = node.indicator.?.size },
            .rating => .{ .width = @as(f32, @floatCast(node.range.maximum)) * Measurer.line_height, .height = Measurer.line_height + metrics.content_inset },
            .slider => .{ .width = 200, .height = metrics.thumb_size + 2 * metrics.content_inset },
            .stepper => .{ .width = 4 * (Measurer.line_height + metrics.content_inset), .height = Measurer.line_height + metrics.content_inset },
            .column, .row, .radio_group, .segmented, .tab_list, .list_box, .toolbar, .breadcrumbs, .accordion, .field, .fieldset, .split, .scroll, .grid, .search, .popup, .popover, .toasts, .toast, .tree, .tree_item, .table, .table_header, .table_row, .token_field, .combo_field, .drag_area, .drag_source, .drop_target, .embed => unreachable,
        };
        const minimum: Size = switch (node.kind) {
            .progress, .meter, .slider, .spacer => .{ .width = 0, .height = size.height },
            else => size,
        };
        return .{ .minimum = minimum, .preferred = size };
    }

    fn options(node: *const Node) layout.Options {
        const axis: Axis = switch (node.kind) {
            .row, .segmented, .tab_list, .toolbar, .breadcrumbs, .search, .toast, .combo_field, .token_field => .row,
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
            if (node.floats()) continue;
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
    /// Index of the first of a table's column tracks in `tracks`.
    fn trackOffset(self: *const View, node: *const Node) usize {
        return (@intFromPtr(node.tracks.ptr) - @intFromPtr(&self.tracks)) / @sizeOf(Track);
    }
    /// Widen the shared column content sizes by a header's or row's cells.
    fn gatherColumns(self: *View, node: *const Node, items: []const layout.Item) void {
        if (node.tracks.len == 0) return;
        const offset = self.trackOffset(node);
        var child = node.first_child;
        var i: usize = 0;
        var track_index: usize = 0;
        while (child != none) : (child = self.buffers.nodes[child].next_sibling) {
            const cell = &self.buffers.nodes[child];
            if (cell.floats()) continue;
            const span = @max(1, cell.style.column_span);
            if (span == 1 and track_index < node.tracks.len) {
                self.track_minimum[offset + track_index] = @max(self.track_minimum[offset + track_index], items[i].content_minimum.width);
                self.track_preferred[offset + track_index] = @max(self.track_preferred[offset + track_index], items[i].preferred.width);
            }
            track_index = (track_index + span) % node.tracks.len;
            i += 1;
        }
    }
    /// A table's column tracks resolved once from the shared content sizes,
    /// as fixed widths, so the header and every row line up.
    fn sharedColumns(self: *const View, node: *const Node, out: *[max_table_tracks]Track) Error![]const Track {
        const count = node.tracks.len;
        if (count == 0) return node.tracks;
        const offset = self.trackOffset(node);
        var cells: [max_table_tracks]ui.grid.AutoItem = undefined;
        for (cells[0..count], 0..) |*cell, track_index| cell.* = .{
            .row = 0,
            .column = track_index,
            .minimum = .{ .width = self.track_minimum[offset + track_index] },
            .preferred = .{ .width = self.track_preferred[offset + track_index] },
        };
        var rects: [max_table_tracks]Rect = undefined;
        var placements: [max_table_tracks]ui.grid.Placement = undefined;
        const solved = ui.grid.computeAuto(node.bounds, node.tracks, &.{}, cells[0..count], gridOptions(node), &rects, &placements) catch |err| return gridError(err);
        for (out[0..count], solved.layout.column_widths[0..count]) |*track, width| track.* = Track.fixed(width);
        return out[0..count];
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
            const node = &self.buffers.nodes[child];
            // Popups and toast stacks take no room in the flow.
            if (node.floats()) continue;
            self.buffers.items[at] = item(node);
            at += 1;
        }
        cursor.* = at;
        return self.buffers.items[start..at];
    }

    /// Measure bottom-up, then place every node within `bounds`.
    pub fn arrange(self: *View, bounds: Rect, theme: Theme, measurer: Measurer) Error!void {
        const all = self.buffers.nodes[0..self.len];
        // A token field's height depends on the width it wraps at, known
        // only once placed; a second round measures with the placed width.
        var round: usize = 0;
        while (true) : (round += 1) {
            try self.measure(theme, measurer);
            all[0].bounds = bounds;
            try self.place();
            if (round == 1 or !self.rememberFlowWidths()) break;
        }
        if (self.reveal) |id| {
            self.reveal = null;
            if (try self.revealNode(id)) try self.place();
        }
        self.record(measurer);
    }
    fn measure(self: *View, theme: Theme, measurer: Measurer) Error!void {
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
            if (node.isGrid()) {
                if (node.kind != .grid) self.gatherColumns(node, items);
                node.measured = try self.measureGrid(node, items);
                continue;
            }
            if (node.kind == .token_field) {
                node.measured = self.measureFlow(node, items);
                continue;
            }
            node.measured = try layout.measure(options(node), items);
            if (node.kind == .scroll) {
                // The viewport may shrink to nothing; its content keeps its size.
                node.content = node.measured.preferred;
                node.measured.minimum.height = 0;
            }
        }
    }

    /// The remembered inner width of the token field `id`, if any.
    fn flowWidth(self: *const View, id: u64) ?f32 {
        for (self.flow_widths[0..self.flow_count]) |entry| if (entry.id == id) return entry.width;
        return null;
    }
    /// Remember each token field's placed inner width; true when one changed.
    fn rememberFlowWidths(self: *View) bool {
        var changed = false;
        for (self.buffers.nodes[0..self.len]) |*node| {
            if (node.kind != .token_field) continue;
            const width = @max(0, node.bounds.width - node.style.padding.left - node.style.padding.right);
            if (self.flowWidth(node.id)) |known| if (@abs(known - width) < 0.5) continue;
            const known = for (self.flow_widths[0..self.flow_count]) |*entry| {
                if (entry.id == node.id) break entry;
            } else null;
            if (known) |entry| entry.width = width else {
                // The oldest entry makes room.
                if (self.flow_count == max_token_fields) {
                    std.mem.copyForwards(@TypeOf(self.flow_widths[0]), self.flow_widths[0 .. max_token_fields - 1], self.flow_widths[1..]);
                    self.flow_count -= 1;
                }
                self.flow_widths[self.flow_count] = .{ .id = node.id, .width = width };
                self.flow_count += 1;
            }
            changed = true;
        }
        return changed;
    }
    fn measureFlow(self: *const View, node: *const Node, items: []const layout.Item) layout.Measurement {
        const p = node.style.padding;
        const width = self.flowWidth(node.id) orelse std.math.inf(f32);
        const line = flow(items, node.style.gap, .{ .x = 0, .y = 0, .width = std.math.inf(f32), .height = 0 }, null);
        const wrapped = flow(items, node.style.gap, .{ .x = 0, .y = 0, .width = width, .height = 0 }, null);
        var narrowest: f32 = 0;
        for (items) |entry| narrowest = @max(narrowest, entry.content_minimum.width);
        const height = wrapped.height + p.top + p.bottom;
        return .{ .minimum = .{ .width = narrowest + p.left + p.right, .height = height }, .preferred = .{ .width = line.width + p.left + p.right, .height = height } };
    }

    /// Keep what input routing needs from this arrangement, and place the
    /// tooltip.
    fn record(self: *View, measurer: Measurer) void {
        const all = self.buffers.nodes[0..self.len];
        const overlay = &self.overlay;
        overlay.popup = null;
        overlay.popover = null;
        overlay.item_count = 0;
        overlay.tip_count = 0;
        overlay.anchor_count = 0;
        overlay.row_count = 0;
        overlay.collection_count = 0;
        overlay.token_count = 0;
        overlay.token_field_count = 0;
        overlay.embed_count = 0;
        overlay.region_count = 0;
        overlay.list_count = 0;
        overlay.reorder_item_count = 0;
        overlay.scroll_count = 0;
        const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (all, 0..) |*node, index| {
            switch (node.kind) {
                .embed => if (node.embed.?.input != null and node.style.enabled and overlay.embed_count < max_interactive_embeds) if (self.visible(node)) |rect| {
                    overlay.embeds[overlay.embed_count] = .{ .id = node.id, .bounds = node.bounds, .rect = rect, .embed = node.embed.? };
                    overlay.embed_count += 1;
                },
                .tree, .table => if (overlay.collection_count < max_collections) {
                    const selection = node.selection.?;
                    overlay.collections[overlay.collection_count] = .{ .id = node.id, .tree = node.kind == .tree, .multiple = selection.mode == .multiple, .anchor = null, .page = 1, .drag_select = node.drag_select and node.style.enabled, .scroll = self.scrollAround(node) };
                    overlay.collection_count += 1;
                },
                .tree_row, .table_row => if (overlay.row_count < max_collection_rows and node.collection != none) {
                    const owner = &all[node.collection];
                    var parent: u32 = none;
                    if (node.kind == .tree_row) {
                        const group = &all[node.parent];
                        if (group.parent < all.len and all[group.parent].kind == .tree_item) {
                            const above = all[all[group.parent].first_child].id;
                            var at = overlay.row_count;
                            while (at > 0) {
                                at -= 1;
                                if (overlay.rows[at].id == above) {
                                    parent = @intCast(at);
                                    break;
                                }
                            }
                        }
                    }
                    overlay.rows[overlay.row_count] = .{ .id = node.id, .item = node.item, .collection = owner.id, .level = node.level, .expanded = node.expanded, .parent = parent, .bounds = node.bounds, .rect = self.visible(node) orelse zero, .enabled = node.style.enabled, .index = @intCast(index) };
                    overlay.row_count += 1;
                },
                .token_field => if (overlay.token_field_count < max_token_fields) {
                    const input = self.firstEmbed(@intCast(index));
                    overlay.token_fields[overlay.token_field_count] = .{ .id = node.id, .input = if (input) |at| all[at].id else null, .embed = if (input) |at| all[at].embed else null };
                    overlay.token_field_count += 1;
                },
                .drag_area, .drag_source, .drop_target => if (node.style.enabled and overlay.region_count < max_drag_regions) {
                    overlay.regions[overlay.region_count] = .{
                        .id = node.id,
                        .index = @intCast(index),
                        .role = switch (node.kind) {
                            .drag_area => .area,
                            .drag_source => .source,
                            else => .target,
                        },
                        .bounds = node.bounds,
                        .rect = self.visible(node) orelse zero,
                        .payload = node.payload,
                        .accept = node.accept,
                    };
                    overlay.region_count += 1;
                },
                .scroll => if (overlay.scroll_count < max_scroll_regions) if (self.visible(node)) |rect| {
                    overlay.scrolls[overlay.scroll_count] = .{ .id = node.id, .rect = rect };
                    overlay.scroll_count += 1;
                },
                .token => if (overlay.token_count < max_tokens) {
                    overlay.tokens[overlay.token_count] = .{ .id = node.id, .remove = tokenRemoveId(node.id), .field = all[node.parent].id, .rect = self.visible(node) orelse zero, .enabled = node.style.enabled };
                    overlay.token_count += 1;
                },
                else => {},
            }
            if (node.kind == .popover and node.checked) {
                const anchor = &all[node.anchor];
                overlay.popover = .{ .id = node.id, .anchor = anchor.id, .rect = node.bounds, .anchor_rect = self.visible(anchor) orelse anchor.bounds };
            }
            if (node.kind == .popup) {
                const anchor = &all[node.anchor];
                const input = if (anchor.kind == .embed) node.anchor else if (anchor.isContainer()) self.firstEmbed(node.anchor) else null;
                const input_id = if (input) |at| all[at].id else anchor.id;
                if (anchor.style.enabled and overlay.anchor_count < max_popup_anchors) {
                    overlay.anchors[overlay.anchor_count] = .{
                        .id = anchor.id,
                        .combo = anchor.kind == .combo_box,
                        .input = if (input) |at| all[at].id else null,
                        .toggle = if (anchor.kind == .combo_field) all[anchor.last_child].id else null,
                        .embed = if (input) |at| all[at].embed else null,
                    };
                    overlay.anchor_count += 1;
                }
                if (!node.checked or overlay.popup != null) continue;
                overlay.popup = .{ .id = node.id, .anchor = anchor.id, .combo = anchor.kind == .combo_box, .rect = node.bounds, .anchor_rect = self.visible(anchor) orelse anchor.bounds, .signature = node.signature, .editable = anchor.kind == .combo_field, .input = input_id };
                for (all[index + 1 .. node.end]) |*entry| {
                    if (entry.kind != .list_item or !entry.style.enabled or overlay.item_count == max_popup_items) continue;
                    overlay.items[overlay.item_count] = .{ .id = entry.id, .rect = self.visible(entry) orelse .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
                    overlay.item_count += 1;
                }
            }
            if (node.tooltip.len > 0 and overlay.tip_count < max_tooltips) if (self.visible(node)) |rect| {
                overlay.tips[overlay.tip_count] = .{ .id = node.id, .rect = rect };
                overlay.tip_count += 1;
            };
        }
        self.recordCollections();
        self.recordReorders();
        self.recordDrag();
        if (self.tip_index == none) return;
        const anchor = self.visible(&all[self.tip_index]) orelse {
            self.tip_index = none;
            return;
        };
        const root_bounds = all[0].bounds;
        const text_size = measurer.measure(measurer.context, all[self.tip_index].tooltip);
        const pad = ui.widgets.tooltip_inset;
        const width = @min(text_size.width + 2 * pad, root_bounds.width);
        const height = text_size.height + 2 * pad;
        const below = anchor.y + anchor.height + popup_gap;
        const y = if (below + height > root_bounds.y + root_bounds.height and anchor.y - popup_gap - height >= root_bounds.y) anchor.y - popup_gap - height else below;
        const x = std.math.clamp(anchor.x, root_bounds.x, @max(root_bounds.x, root_bounds.x + root_bounds.width - width));
        self.tip_rect = .{ .x = x, .y = y, .width = width, .height = height };
    }

    /// The nearest scroll container around `node`.
    fn scrollAround(self: *const View, node: *const Node) ?u64 {
        const all = self.buffers.nodes[0..self.len];
        var parent = node.parent;
        while (parent < all.len) : (parent = all[parent].parent) if (all[parent].kind == .scroll) return all[parent].id;
        return null;
    }

    /// The items of each container that reorders: a table's rows, or the
    /// children of any other container.
    fn recordReorders(self: *View) void {
        const all = self.buffers.nodes[0..self.len];
        const overlay = &self.overlay;
        const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (all, 0..) |*node, index| {
            if (!node.reorder or !node.style.enabled or overlay.list_count == max_reorder_lists) continue;
            const first = overlay.reorder_item_count;
            if (node.kind == .table) {
                for (all[index + 1 .. node.end], index + 1..) |*entry, at| {
                    if (entry.kind != .table_row or entry.collection != index or overlay.reorder_item_count == max_reorder_items) continue;
                    overlay.reorder_items[overlay.reorder_item_count] = .{ .id = entry.id, .index = @intCast(at), .bounds = entry.bounds, .rect = if (entry.style.enabled) self.visible(entry) orelse zero else zero };
                    overlay.reorder_item_count += 1;
                }
            } else {
                var child = node.first_child;
                while (child != none and overlay.reorder_item_count < max_reorder_items) : (child = all[child].next_sibling) {
                    const entry = &all[child];
                    overlay.reorder_items[overlay.reorder_item_count] = .{ .id = entry.id, .index = child, .bounds = entry.bounds, .rect = if (entry.style.enabled) self.visible(entry) orelse zero else zero };
                    overlay.reorder_item_count += 1;
                }
            }
            overlay.lists[overlay.list_count] = .{ .id = node.id, .axis = options(node).axis, .rect = self.visible(node) orelse zero, .first = @intCast(first), .count = @intCast(overlay.reorder_item_count - first), .scroll = self.scrollAround(node) };
            overlay.list_count += 1;
        }
    }

    /// Where the copy of what a drag moves goes, the line showing where a
    /// reordered item would land, and the outline of the target under it.
    fn recordDrag(self: *View) void {
        const all = self.buffers.nodes[0..self.len];
        self.drag_ghost = null;
        self.drag_label = "";
        self.insert_mark = null;
        self.drop_mark = null;
        const over: ?u64 = self.drop_over orelse if (self.system_drag) |drag| drag.over else null;
        if (over) |id| for (all) |*node| if (node.id == id and node.kind == .drop_target) {
            self.drop_mark = self.visible(node);
            break;
        };
        const capture = self.capture orelse return;
        if (!capture.dragging) return;
        const moved: ?u32 = switch (capture.target) {
            .source => |source| for (all, 0..) |*node, index| {
                if (node.id == source.id and node.kind == .drag_source) break @intCast(index);
            } else null,
            .reorder => |value| reorder: {
                const list = self.reorderList(value.list) orelse break :reorder null;
                if (value.from >= list.count) break :reorder null;
                const items = self.overlay.reorder_items[list.first..][0..list.count];
                self.insert_mark = insertion(list, items, value.to);
                break :reorder items[value.from].index;
            },
            else => null,
        };
        const index = moved orelse return;
        const node = &all[index];
        const b = node.bounds;
        self.drag_ghost = .{ .x = b.x + capture.position.x - capture.origin.x, .y = b.y + capture.position.y - capture.origin.y, .width = b.width, .height = b.height };
        // The first text inside names what moves.
        for (all[index..node.end]) |*inner| if (inner.text.len > 0 and inner.kind != .fieldset) {
            self.drag_label = inner.text;
            break;
        };
    }

    /// A thin bar across a list at the gap before item `to`.
    fn insertion(list: Overlay.ReorderList, items: []const Overlay.ReorderItem, to: usize) ?Rect {
        if (items.len == 0) return null;
        const thickness: f32 = 2;
        const before = if (to < items.len) items[to].bounds else null;
        const after = if (to > 0) items[to - 1].bounds else null;
        const reference = before orelse after.?;
        if (list.axis == .row) {
            const x = if (before != null and after != null) (after.?.x + after.?.width + before.?.x) / 2 else if (before) |b| b.x else after.?.x + after.?.width;
            return .{ .x = x - thickness / 2, .y = reference.y, .width = thickness, .height = reference.height };
        }
        const y = if (before != null and after != null) (after.?.y + after.?.height + before.?.y) / 2 else if (before) |b| b.y else after.?.y + after.?.height;
        return .{ .x = reference.x, .y = y - thickness / 2, .width = reference.width, .height = thickness };
    }

    /// The anchor present among a collection's rows and how many rows a
    /// page moves, from its visible height.
    fn recordCollections(self: *View) void {
        const all = self.buffers.nodes[0..self.len];
        const overlay = &self.overlay;
        for (overlay.collections[0..overlay.collection_count]) |*entry| {
            const node = for (all) |*candidate| {
                if (candidate.id == entry.id) break candidate;
            } else continue;
            const selection = node.selection.?;
            var height: f32 = 0;
            for (overlay.rows[0..overlay.row_count]) |line| if (line.collection == entry.id) {
                if (height == 0) height = line.bounds.height;
                if (selection.anchor) |anchor| if (anchor == line.item) {
                    entry.anchor = anchor;
                };
            };
            const viewport = self.visible(node) orelse continue;
            if (height > 0) entry.page = @max(1, @as(usize, @intFromFloat(@floor(viewport.height / height))) -| 1);
        }
    }

    /// Scroll every scroll container around the node with `id` so it is in
    /// view; true when an offset changed.
    fn revealNode(self: *View, id: u64) Error!bool {
        const all = self.buffers.nodes[0..self.len];
        const target = for (all) |*node| {
            if (node.id == id) break node;
        } else return false;
        var moved = false;
        var parent = target.parent;
        while (parent < all.len) : (parent = all[parent].parent) {
            const container = &all[parent];
            const model = container.scroll orelse continue;
            const top = container.bounds.y - model.offset.y;
            const b = target.bounds;
            moved = (model.ensureVisible(.{ .x = 0, .y = b.y - top, .width = 0, .height = b.height }) catch return error.InvalidValue) or moved;
        }
        return moved;
    }

    /// Place every container's children from its arranged bounds, top-down.
    fn place(self: *View) Error!void {
        const all = self.buffers.nodes[0..self.len];
        var cursor: usize = 0;
        var index: usize = 0;
        while (index < all.len) : (index += 1) {
            const node = &all[index];
            // A closed popup's options keep no place.
            if (node.hidden()) {
                index = node.end - 1;
                continue;
            }
            if (!node.isContainer() or node.child_count == 0) continue;
            const start = cursor;
            const items = try self.childItems(node, &cursor);
            if (self.buffers.rects.len < cursor) return error.OutputTooSmall;
            const rects = self.buffers.rects[start..cursor];
            switch (node.kind) {
                .token_field => {
                    const p = node.style.padding;
                    const b = node.bounds;
                    _ = flow(items, node.style.gap, .{ .x = b.x + p.left, .y = b.y + p.top, .width = @max(0, b.width - p.left - p.right), .height = 0 }, rects);
                },
                .grid, .table_header, .table_row => {
                    var cells: [ui.grid.max_items]ui.grid.AutoItem = undefined;
                    var placements: [ui.grid.max_items]ui.grid.Placement = undefined;
                    var shared: [max_table_tracks]Track = undefined;
                    const tracks = if (node.kind == .grid) node.tracks else try self.sharedColumns(node, &shared);
                    _ = ui.grid.computeAuto(node.bounds, tracks, &.{}, self.gridItems(node, items, &cells, false), gridOptions(node), rects, &placements) catch |err| return gridError(err);
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
                if (all[child].floats()) continue;
                all[child].bounds = rects[i];
                i += 1;
            }
            // Floating children go over the flow once their anchors are placed.
            child = node.first_child;
            while (child != none) : (child = all[child].next_sibling) {
                if (all[child].floats()) all[child].bounds = self.floatingBounds(&all[child]);
            }
        }
    }

    /// A popup below its anchor, or above when there is more room there,
    /// within the window; a toast stack centred over the bottom edge.
    fn floatingBounds(self: *const View, node: *const Node) Rect {
        const root_bounds = self.buffers.nodes[0].bounds;
        const preferred = node.measured.preferred;
        if (node.kind == .toasts) {
            const width = @min(@max(preferred.width, 280), @max(0, root_bounds.width - 2 * toast_margin));
            const height = @min(preferred.height, @max(0, root_bounds.height - 2 * toast_margin));
            return .{ .x = root_bounds.x + (root_bounds.width - width) / 2, .y = root_bounds.y + @max(0, root_bounds.height - toast_margin - height), .width = width, .height = height };
        }
        const anchor = self.buffers.nodes[node.anchor].bounds;
        if (!node.checked) return .{ .x = anchor.x, .y = anchor.y + anchor.height, .width = 0, .height = 0 };
        if (node.kind == .popover) return placePopover(root_bounds, anchor, preferred, node.placement);
        const width = @min(@max(anchor.width, preferred.width), root_bounds.width);
        const below = root_bounds.y + root_bounds.height - (anchor.y + anchor.height + popup_gap);
        const above = anchor.y - popup_gap - root_bounds.y;
        var height = @min(preferred.height, max_popup_height);
        var y: f32 = undefined;
        if (height > below and above > below) {
            height = @min(height, @max(0, above));
            y = anchor.y - popup_gap - height;
        } else {
            height = @min(height, @max(0, below));
            y = anchor.y + anchor.height + popup_gap;
        }
        const x = std.math.clamp(anchor.x, root_bounds.x, @max(root_bounds.x, root_bounds.x + root_bounds.width - width));
        return .{ .x = x, .y = y, .width = width, .height = height };
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
    /// same recording methods. Popups and toasts are drawn after the tree,
    /// so they cover it and take input first, and the tooltip last.
    pub fn paint(self: *const View, target: anytype) !void {
        const all = self.buffers.nodes[0..self.len];
        const theme = target.currentTheme();
        var floating: [max_floating]u32 = undefined;
        var floating_len: usize = 0;
        try self.paintRange(target, theme, 0, all.len, &floating, &floating_len);
        for (floating[0..floating_len]) |index| {
            const node = &all[index];
            const bounds = node.bounds;
            if (node.kind == .popover) {
                const radius = if (node.style.radius > 0) node.style.radius else 6;
                target.roundedRect(bounds, radius, ui.Color.rgb(node.style.border orelse theme.palette.border));
                target.roundedRect(inset(bounds, theme.metrics.border / 2), @max(0, radius - theme.metrics.border / 2), ui.Color.rgb(node.style.background orelse theme.palette.background));
                // The anchor may publish its semantics later, so the panel
                // stays at the root, like a text input's list.
                try target.popover(node.id, bounds, node.style.name, ui.accessibility.root_id);
            }
            if (node.kind == .popup) {
                const anchor = &all[node.anchor];
                const name = if (node.style.name.len > 0) node.style.name else anchor.style.name;
                target.roundedRect(bounds, 4, ui.Color.rgb(theme.palette.border));
                target.roundedRect(inset(bounds, theme.metrics.border / 2), 4, ui.Color.rgb(theme.palette.inset));
                // A combo box owns its list; a text input's list stays at the
                // root because the input may publish its semantics later.
                try target.popupList(node.id, bounds, name, if (anchor.kind == .combo_box) anchor.id else ui.accessibility.root_id);
            }
            if (node.child_count == 0) continue;
            try target.pushClip(bounds);
            // Nothing floats inside a floating node; `open` refuses it.
            var nested: [max_floating]u32 = undefined;
            var nested_len: usize = 0;
            try self.paintRange(target, theme, index + 1, node.end, &nested, &nested_len);
            try target.popClip();
        }
        try self.paintDrag(target, theme);
        if (self.tip_index != none) {
            const node = &all[self.tip_index];
            try target.tooltip(tooltipId(node.id), self.tip_rect, node.tooltip);
        }
        // Each announcement is a new status, so clients announce it once.
        if (self.announcement_len > 0) try target.status(announcementId(self.announcement_serial), .{ .x = 0, .y = 0, .width = 0, .height = 0 }, self.announcement[0..self.announcement_len], ui.accessibility.root_id);
    }

    /// The outline of the target under a drag, the line where a reordered
    /// item would go, and a translucent copy of what moves, over the rest.
    fn paintDrag(self: *const View, target: anytype, theme: Theme) !void {
        var accent = ui.Color.rgb(theme.palette.accent);
        if (self.drop_mark) |rect| target.strokeRect(rect, 4, 2, accent);
        if (self.insert_mark) |rect| target.roundedRect(rect, 1, accent);
        const ghost = self.drag_ghost orelse return;
        const all_bounds = self.buffers.nodes[0].bounds;
        try target.pushClip(all_bounds);
        var fill = ui.Color.rgb(theme.palette.control);
        fill.a = 0xd0;
        target.roundedRect(ghost, 4, fill);
        accent.a = 0xa0;
        target.strokeRect(ghost, 4, 1, accent);
        if (self.drag_label.len > 0) {
            const pad = theme.metrics.content_inset + 4;
            target.label(.{ .x = ghost.x + pad, .y = ghost.y, .width = @max(0, ghost.width - 2 * pad), .height = ghost.height }, self.drag_label, theme.palette.text);
        }
        try target.popClip();
    }

    /// Paint nodes `start..stop` in order, skipping floating subtrees, whose
    /// indices are added to `floating` when they are shown.
    fn paintRange(self: *const View, target: anytype, theme: Theme, start: usize, stop: usize, floating: *[max_floating]u32, floating_len: *usize) !void {
        const all = self.buffers.nodes[0..self.len];
        // Clips and effects open in node order and close, innermost first,
        // where their node's subtree ends.
        var scopes: [3 * (max_depth + 1)]Scope = undefined;
        var scope_depth: usize = 0;
        var at = start;
        while (at < stop) {
            while (scope_depth > 0 and all[scopes[scope_depth - 1].index].end <= at) {
                scope_depth -= 1;
                try closeScope(&all[scopes[scope_depth].index], scopes[scope_depth].clip, target, theme);
            }
            const node = &all[at];
            if (node.floats()) {
                if (!node.hidden()) {
                    if (floating_len.* == max_floating) return error.TooManyItems;
                    floating[floating_len.*] = @intCast(at);
                    floating_len.* += 1;
                }
                at = node.end;
                continue;
            }
            // Rows scrolled out of sight record nothing, so long collections
            // spend controls only on what can be seen. The cursor row stays
            // to keep the collection's Tab stop.
            if ((node.kind == .tree_row or node.kind == .table_row) and !node.cursor and self.visible(node) == null) {
                at = if (node.isContainer()) node.end else at + 1;
                continue;
            }
            const bounds = node.bounds;
            const style = node.style;
            for (0..try self.openEffects(target, style, bounds)) |_| {
                scopes[scope_depth] = .{ .index = @intCast(at), .clip = false };
                scope_depth += 1;
            }
            var control: ui.widgets.Options = .{ .enabled = style.enabled, .name = style.name, .semantic_parent = node.semantic_parent };
            const annotation = self.annotationOf(node);
            control.description = annotation.description;
            control.invalid = annotation.invalid;
            control.required = annotation.required;
            if (control.name.len == 0) control.name = annotation.name;
            if (control.description.len == 0) control.description = node.tooltip;
            switch (node.kind) {
                .column, .row, .radio_group, .segmented, .tab_list, .list_box, .toolbar, .breadcrumbs, .accordion, .field, .fieldset, .split, .scroll, .grid, .search, .popup, .popover, .toasts, .toast, .tree, .tree_item, .table, .table_header, .table_row, .token_field, .combo_field, .drag_area, .drag_source, .drop_target => {
                    switch (node.kind) {
                        .radio_group, .segmented => try target.radioGroup(node.id, bounds, style.name),
                        .list_box => try target.listBox(node.id, bounds, style.name),
                        .tab_list => try target.tabList(node.id, bounds, style.name),
                        .toolbar => try target.toolbar(node.id, bounds, style.name),
                        .breadcrumbs => try target.navigation(node.id, bounds, style.name, node.semantic_parent),
                        .accordion => try target.group(node.id, bounds, style.name, node.semantic_parent),
                        .fieldset => try target.group(node.id, bounds, node.text, node.semantic_parent),
                        .search => try target.search(node.id, bounds, style.name, node.semantic_parent),
                        .tree => try target.treeView(node.id, bounds, style.name, node.selection.?.mode == .multiple, node.semantic_parent),
                        .table => try target.dataTable(node.id, bounds, style.name, node.selection.?.mode == .multiple, node.semantic_parent),
                        .table_header => {
                            try target.tableHeader(node.id, bounds, node.semantic_parent);
                            target.roundedRect(bounds, 0, ui.Color.rgb(theme.palette.control));
                            target.roundedRect(.{ .x = bounds.x, .y = bounds.y + @max(0, bounds.height - theme.metrics.border / 2), .width = bounds.width, .height = @min(bounds.height, theme.metrics.border / 2) }, 0, ui.Color.rgb(theme.palette.border));
                        },
                        .table_row => try target.tableRow(node.id, bounds, node.text, self.rowOptions(node, control)),
                        .token_field, .combo_field => {
                            if (node.kind == .token_field) try target.tokenField(node.id, bounds, style.name, node.semantic_parent) else try target.comboField(node.id, bounds, node.text, node.checked, control);
                            const focused = self.focusWithin(node);
                            target.roundedRect(bounds, 3, ui.Color.rgb(if (focused) theme.palette.focus else if (style.enabled) theme.palette.border else theme.palette.disabled_border));
                            target.roundedRect(inset(bounds, theme.metrics.border), 2, ui.Color.rgb(theme.palette.field));
                        },
                        .toast => {
                            try target.status(node.id, bounds, node.text, node.semantic_parent);
                            target.roundedRect(bounds, 6, ui.Color.rgb(theme.palette.border));
                            target.roundedRect(inset(bounds, theme.metrics.border / 2), 6, ui.Color.rgb(style.background orelse theme.palette.control));
                        },
                        else => {},
                    }
                    if (try self.paintRefraction(target, style, bounds)) {} else if (style.material) |material| target.backdropEffect(bounds, style.radius, material) else if (node.kind != .toast) if (style.background) |color| target.roundedRect(bounds, style.radius, ui.Color.rgb(color));
                    if (style.border) |color| target.strokeRect(bounds, style.radius, style.border_width, ui.Color.rgb(color));
                    if (node.kind == .breadcrumbs) self.paintSeparators(node, target, theme);
                    if (node.kind == .split) {
                        const p = style.padding;
                        const area: Rect = .{ .x = bounds.x + p.left, .y = bounds.y + p.top, .width = @max(0, bounds.width - p.left - p.right), .height = @max(0, bounds.height - p.top - p.bottom) };
                        try target.splitter(node.id, area, self.divider(node).?, node.value, node.range, .{ .control = control, .vertical = node.axis == .column });
                    }
                    if (node.clips() and node.child_count > 0) {
                        try target.pushClip(bounds);
                        scopes[scope_depth] = .{ .index = @intCast(at), .clip = true };
                        scope_depth += 1;
                    }
                },
                .text => target.labelFont(bounds, node.text, style.color orelse if (!style.enabled) theme.palette.disabled_text else if (node.row != none and all[node.row].checked) theme.palette.on_accent else theme.palette.text, style.font orelse .{}),
                .tree_row => try target.treeItem(node.id, bounds, node.text, self.rowOptions(node, control)),
                .column_header => try target.columnHeader(node.id, bounds, node.text, node.sort, node.checked, control),
                .token => {
                    var token_options = control;
                    token_options.radio_group = node.radio_group;
                    try target.tokenItem(node.id, tokenRemoveId(node.id), bounds, node.text, .{ .control = token_options });
                },
                .combo_toggle => try target.comboToggle(node.id, bounds, all[node.parent].checked, control),
                .note => target.label(bounds, node.text, if (node.invalid) theme.palette.caution else theme.palette.disabled_text),
                .spacer => {},
                .button => try target.buttonWithOptions(node.id, bounds, node.text, control),
                .link => try target.link(node.id, bounds, node.text, control),
                .nav_button => try target.navButton(node.id, bounds, node.direction, node.text, control),
                .combo_box, .popup_button => try target.comboBox(node.id, bounds, node.text, node.checked, control),
                .avatar => try target.avatar(node.id, bounds, node.text, .{ .image = node.image, .color = style.background, .semantic_parent = node.semantic_parent }),
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
                .list_item => {
                    var item_options = control;
                    item_options.radio_group = node.radio_group;
                    try target.listItem(node.id, bounds, node.text, node.checked, item_options);
                    if (node.highlighted) target.strokeRect(bounds, 0, theme.metrics.border, ui.Color.rgb(if (node.checked) theme.palette.on_accent else theme.palette.focus));
                },
                .tab => {
                    var tab_options = control;
                    tab_options.radio_group = node.radio_group;
                    try target.tab(node.id, bounds, node.text, node.checked, tab_options);
                },
                .toggle_switch => try target.toggleSwitch(node.id, bounds, node.text, node.checked, control),
                .progress => try target.progress(node.id, bounds, node.fraction, control),
                .loading => {
                    const indicator = node.indicator.?;
                    const color = indicator.color orelse if (style.enabled) theme.palette.text else theme.palette.disabled_text;
                    if (@TypeOf(target) == *ui.Frame) {
                        target.loadingIndicator(bounds, indicator.kind, indicator.phase, ui.Color.rgb(color), indicator.variant);
                        // Equal range bounds mark the progress indeterminate.
                        try target.semantic(.{ .id = node.id, .parent = node.semantic_parent, .role = .progress, .name = style.name, .bounds = bounds, .enabled = style.enabled, .read_only = true, .range_minimum = 0, .range_maximum = 0 });
                    } else try target.indicator(node.id, bounds);
                },
                .meter => try target.meter(node.id, bounds, node.value, node.range, .{ .control = control, .bands = node.bands }),
                .rating => try target.rating(node.id, bounds, node.value, @intFromFloat(node.range.maximum), control),
                .slider => try target.slider(node.id, bounds, node.value, node.range, .{ .control = control }),
                .stepper => try target.stepper(node.id, bounds, node.value, node.range, control),
                .embed => {
                    const content = node.embed.?;
                    if (content.annotate) |annotate| annotate(content.context, annotation);
                    // A focusable leaf is a Tab stop under its own id; the
                    // controls it paints itself stay above it.
                    if (content.focusable and @TypeOf(target) == *ui.Frame) try target.addControl(node.id, bounds, .{ .enabled = node.style.enabled });
                    if (@TypeOf(target) == *ui.Frame) try content.paint(content.context, target, node.id, bounds) else try target.embedded(node.id, bounds);
                },
            }
            at += 1;
        }
        while (scope_depth > 0) {
            scope_depth -= 1;
            try closeScope(&all[scopes[scope_depth].index], scopes[scope_depth].clip, target, theme);
        }
    }
    const Scope = struct { index: u32, clip: bool };
    fn closeScope(node: *const Node, clip: bool, target: anytype, theme: Theme) !void {
        if (!clip) return target.endEffect();
        paintEdges(node, target);
        try target.popClip();
        paintScrollIndicator(node, target, theme);
    }
    /// Open the pose, effect and opacity of a node, outermost first, and
    /// return how many opened. Opacity applies to the outermost one.
    fn openEffects(self: *const View, target: anytype, style: Style, bounds: Rect) !usize {
        var alpha: u8 = @intFromFloat(@round(style.opacity * 255));
        if (style.pose == null and style.effect == null and alpha == 255) return 0;
        var count: usize = 0;
        if (self.effects) |library| if (style.pose) |pose| {
            var values: ui.shader.Values = undefined;
            if (try library.pose(&values, pose, .{ bounds.width, bounds.height })) |effect| {
                try target.beginEffect(bounds, effect, .{ .opacity = alpha });
                alpha = 255;
                count += 1;
            } else if (!pose.isIdentity()) alpha = 0; // Flattened to nothing.
        };
        if (style.effect) |effect| {
            try target.beginEffect(bounds, effect, .{ .opacity = alpha });
            alpha = 255;
            count += 1;
        }
        if (alpha != 255) if (self.effects) |library| {
            try target.beginEffect(bounds, library.passthrough(), .{ .opacity = alpha });
            count += 1;
        };
        return count;
    }
    /// Paint a container's refraction, true when it replaces the fill.
    fn paintRefraction(self: *const View, target: anytype, style: Style, bounds: Rect) !bool {
        const glass = style.refraction orelse return false;
        const library = self.effects orelse return false;
        if (self.preferences.reduce_transparency or self.preferences.high_contrast) return false;
        var values: ui.shader.Values = undefined;
        target.backdropShader(bounds, style.radius, try library.glass(&values, glass, style.radius));
        return true;
    }

    /// Row options of a tree or table row from its collection.
    fn rowOptions(self: *const View, node: *const Node, control: ui.widgets.Options) ui.widgets.RowOptions {
        const owner = &self.buffers.nodes[node.collection];
        var value = control;
        value.radio_group = owner.id;
        value.name = "";
        return .{ .control = value, .selected = node.checked, .cursor = node.cursor, .multiple = owner.selection.?.mode == .multiple, .level = node.level, .expanded = node.expanded };
    }
    /// True when focus is on the node or a node inside it.
    fn focusWithin(self: *const View, node: *const Node) bool {
        const focused = self.focus orelse return false;
        const start = (@intFromPtr(node) - @intFromPtr(self.buffers.nodes.ptr)) / @sizeOf(Node);
        for (self.buffers.nodes[start..node.end]) |*inner| if (inner.id == focused) return true;
        return false;
    }

    /// What the enclosing field adds to a control's semantics; empty outside
    /// a field and for the field's own label and note.
    fn annotationOf(self: *const View, node: *const Node) Annotation {
        if (node.field == none or node.kind == .text or node.kind == .note) return .{};
        const owner = &self.buffers.nodes[node.field];
        return .{ .name = owner.text, .description = owner.note, .invalid = owner.invalid, .required = owner.required };
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
    fn paintEdges(node: *const Node, target: anytype) void {
        const edges = node.style.edges;
        const b = node.bounds;
        const height = @min(edges.height, b.height);
        if (edges.top) |edge| {
            var top = edge;
            top.bottom = false;
            target.backdropEffect(.{ .x = b.x, .y = b.y, .width = b.width, .height = height }, 0, .{ .scroll_edge = top });
        }
        if (edges.bottom) |edge| {
            var bottom = edge;
            bottom.bottom = true;
            target.backdropEffect(.{ .x = b.x, .y = b.y + b.height - height, .width = b.width, .height = height }, 0, .{ .scroll_edge = bottom });
        }
    }
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

/// Lay `items` out left to right in lines no wider than `inner.width`,
/// writing their rects when `rects` is given; returns the content size. A
/// growing item counts at its minimum width when lines break and then
/// shares the room left on its line.
fn flow(items: []const layout.Item, gap: f32, inner: Rect, rects: ?[]Rect) Size {
    var y: f32 = 0;
    var widest: f32 = 0;
    var start: usize = 0;
    while (start < items.len) {
        var stop = start;
        var line_width: f32 = 0;
        var line_height: f32 = 0;
        var grow: f32 = 0;
        while (stop < items.len) : (stop += 1) {
            const entry = items[stop];
            const width = if (entry.grow > 0) entry.content_minimum.width else entry.preferred.width;
            const next = if (stop == start) width else line_width + gap + width;
            if (stop > start and next > inner.width) break;
            line_width = next;
            line_height = @max(line_height, entry.preferred.height);
            grow += entry.grow;
        }
        if (rects) |out| {
            const extra = if (std.math.isFinite(inner.width)) @max(0, inner.width - line_width) else 0;
            var x = inner.x;
            for (items[start..stop], out[start..stop]) |entry, *rect| {
                var width = if (entry.grow > 0) entry.content_minimum.width + extra * entry.grow / grow else entry.preferred.width;
                if (std.math.isFinite(inner.width)) width = @min(width, inner.width);
                const height = @min(entry.preferred.height, line_height);
                rect.* = .{ .x = x, .y = inner.y + y + (line_height - height) / 2, .width = width, .height = height };
                x += width + gap;
            }
        }
        widest = @max(widest, line_width);
        y += line_height;
        if (stop < items.len) y += gap;
        start = stop;
    }
    return .{ .width = widest, .height = y };
}

/// The semantic id of the remove button of the token `id`.
pub fn tokenRemoveId(id: u64) u64 {
    const value = std.hash.Wyhash.hash(id, "remove");
    return if (value == 0) 1 else value;
}
/// The semantic id of the tooltip shown for the control `id`.
/// The status node id of the announcement with `serial`.
pub fn announcementId(serial: u64) u64 {
    const value = std.hash.Wyhash.hash(serial, "announcement");
    return if (value == 0) 1 else value;
}
pub fn tooltipId(id: u64) u64 {
    const value = std.hash.Wyhash.hash(id, "tooltip");
    return if (value == 0) 1 else value;
}
fn inset(rect: Rect, amount: f32) Rect {
    return .{ .x = rect.x + amount, .y = rect.y + amount, .width = @max(0, rect.width - 2 * amount), .height = @max(0, rect.height - 2 * amount) };
}
fn distance(a: Point, b: Point) f32 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}
/// True when `inner` lies within `outer`.
fn inside(inner: Rect, outer: Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height;
}

/// A popover panel of `size` beside `anchor` within `window`, as
/// `placement` asks: on its side, or the opposite one when the panel does
/// not fit there and that side has more room, then moved and cut to stay
/// within the window.
pub fn placePopover(window: Rect, anchor: Rect, size: Size, placement: Placement) Rect {
    const width = @min(if (placement.match_width) @max(size.width, anchor.width) else size.width, window.width);
    const height = @min(size.height, window.height);
    const gap = placement.gap;
    const below = window.y + window.height - (anchor.y + anchor.height + gap);
    const above = anchor.y - gap - window.y;
    const right = window.x + window.width - (anchor.x + anchor.width + gap);
    const left = anchor.x - gap - window.x;
    var side = placement.side;
    switch (side) {
        .bottom => if (height > below and above > below) {
            side = .top;
        },
        .top => if (height > above and below > above) {
            side = .bottom;
        },
        .right => if (width > right and left > right) {
            side = .left;
        },
        .left => if (width > left and right > left) {
            side = .right;
        },
    }
    var x: f32 = undefined;
    var y: f32 = undefined;
    switch (side) {
        .bottom, .top => {
            y = if (side == .bottom) anchor.y + anchor.height + gap else anchor.y - gap - height;
            x = switch (placement.alignment) {
                .start => anchor.x,
                .center => anchor.x + (anchor.width - width) / 2,
                .end => anchor.x + anchor.width - width,
            };
        },
        .left, .right => {
            x = if (side == .right) anchor.x + anchor.width + gap else anchor.x - gap - width;
            y = switch (placement.alignment) {
                .start => anchor.y,
                .center => anchor.y + (anchor.height - height) / 2,
                .end => anchor.y + anchor.height - height,
            };
        },
    }
    x = std.math.clamp(x, window.x, @max(window.x, window.x + window.width - width));
    y = std.math.clamp(y, window.y, @max(window.y, window.y + window.height - height));
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}

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

/// A monotonic time source in nanoseconds; only differences matter.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque) u64,
};

/// Arms a timer for the earliest deadline a build asked for, in the Host
/// clock, or cancels it for null; `now` is the current time. It runs as a
/// posted task after paint. `ziggurat_view_timer` provides one.
pub const Scheduler = struct {
    context: *anyopaque,
    schedule: *const fn (context: *anyopaque, deadline: ?u64, now: u64) void,
};

pub const Options = struct {
    /// Style of the implicit root column, which fills the window.
    root: Style = .{ .padding = Insets.all(24), .gap = 12, .alignment = .start },
    /// Window background; defaults to the theme background.
    background: ?u32 = null,
    measurer: Measurer = .{},
    /// Hover or focus time before a tooltip appears, in nanoseconds.
    tooltip_delay: u64 = 500 * std.time.ns_per_ms,
    /// The time passes see; the default is a monotonic timer started at the
    /// Host's first pass.
    clock: ?Clock = null,
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
    timer: ?std.time.Timer = null,
    scheduler: ?Scheduler = null,
    /// The deadline last handed to the scheduler.
    scheduled: ?u64 = null,
    schedule_queued: bool = false,
    /// A control asked for focus before any frame registered it, such as
    /// the first control of a popover that just opened; it takes focus
    /// after the next frame.
    pending_focus: ?u64 = null,
    focus_queued: bool = false,

    pub fn init(state: anytype, comptime build: fn (@TypeOf(state), *View) anyerror!void, buffers: Buffers, options: Options) Host {
        var view = View.init(buffers);
        view.tooltip_delay = options.tooltip_delay;
        return .{
            .context = ui.Context.init(undefined, draw, onAction),
            .view = view,
            .build = Build.bind(state, build),
            .options = options,
        };
    }

    /// The time the next pass will see, in nanoseconds.
    pub fn time(self: *Host) u64 {
        if (self.options.clock) |clock| return clock.now(clock.context);
        if (self.timer == null) self.timer = std.time.Timer.start() catch return 0;
        return self.timer.?.read();
    }
    /// Install or remove the timer that serves the build's deadlines; the
    /// next frame hands it the current one.
    pub fn setScheduler(self: *Host, scheduler: ?Scheduler) void {
        self.scheduler = scheduler;
        self.scheduled = null;
        if (self.context.window) |window| window.invalidate();
    }
    /// Ask assistive technology to announce `message`, such as a chart's newly
    /// selected point, and repaint so it takes effect; see `View.announce`.
    pub fn announce(self: *Host, message: []const u8) void {
        self.view.announce(message);
        self.invalidate();
    }
    /// Apply the system's accessibility appearance: reduced motion stills
    /// loading indicators, and reduced transparency or high contrast turn
    /// backdrop effects into opaque fills. Repaints when attached.
    pub fn setPreferences(self: *Host, value: Preferences) !void {
        try self.context.setBackdropPreferences(.{ .reduce_transparency = value.reduce_transparency, .high_contrast = value.high_contrast });
        self.view.preferences = value;
        self.invalidate();
    }
    /// Allocate the scratch planes that backdrop effects filter in; see
    /// `ui.Context.prepareBackdropEffects`. Call after `attach`.
    pub fn prepareBackdropEffects(self: *Host, allocator: std.mem.Allocator, options: ui.backdrop_effects.Options) !void {
        try self.context.prepareBackdropEffects(allocator, options);
    }
    /// Allocate the workspace that shader effects run in (see
    /// `ui.Context.prepareShaderEffects`) and draw `Style.opacity`, `pose`
    /// and `refraction` with `library`, which the application keeps alive
    /// while the host is attached. Call after `attach`; refraction also
    /// needs `prepareBackdropEffects`.
    pub fn prepareShaderEffects(self: *Host, allocator: std.mem.Allocator, library: *const ui.effects.Library, options: ui.shader_effects.Options) !void {
        try self.context.prepareShaderEffects(allocator, options);
        self.view.effects = library;
    }
    /// Called by the scheduler when the deadline it was given has passed.
    pub fn wakeFired(self: *Host) void {
        self.scheduled = null;
        if (self.context.window) |window| window.invalidate();
    }

    pub fn attach(self: *Host, window: z.Window) !void {
        self.context.state = self;
        self.context.on_value = onValue;
        self.context.on_input = onInput;
        self.context.on_key_release = onKeyRelease;
        try self.context.attach(window);
    }

    /// Run one build pass. Event passes record nothing; they only let the
    /// owning widget update application state immediately, so successive
    /// inputs are never merged by repaint coalescing.
    pub fn pass(self: *Host, event: ?Event) anyerror!void {
        if (self.building) return error.Busy;
        self.building = true;
        defer self.building = false;
        self.view.now = self.time();
        self.view.focus = self.context.input_state.focused;
        try self.build.run(&self.view, self.options.root, event);
    }

    fn deliver(self: *Host, event: Event) void {
        self.pass(event) catch |err| {
            self.last_error = err;
        };
        self.restoreFocus();
    }
    /// Return focus where the last pass or route asked, such as to a combo
    /// box whose list closed.
    fn restoreFocus(self: *Host) void {
        if (self.view.restore == null) {
            self.view.restore = self.view.focus_request;
        }
        self.view.focus_request = null;
        const id = self.view.restore orelse return;
        self.view.restore = null;
        if (self.context.input_state.focused == id) return;
        if (self.context.window != null and !self.context.input_state.available(id)) {
            self.pending_focus = id;
            self.invalidate();
            return;
        }
        self.focus(id);
    }
    fn focus(self: *Host, id: u64) void {
        self.context.focusControl(id) catch |err| switch (err) {
            error.NotAttached => self.context.input_state.setFocused(id),
            // The system kept another window in front, as Windows does for
            // a process without the foreground. The move is the window's
            // own, so the control still takes its focus, which keys reach
            // once the window is activated.
            error.FocusDenied => {
                if (self.context.input_state.available(id)) self.context.input_state.setFocused(id);
                self.invalidate();
            },
            else => self.last_error = err,
        };
    }
    fn invalidate(self: *Host) void {
        if (self.context.window) |window| window.invalidate();
    }
    /// An embedded leaf took a press or key and may have changed state
    /// it owns; a pass lets the build apply it at once, then focus goes
    /// where that pass asked, or to `leaf`.
    fn settleEmbed(self: *Host, leaf: ?u64) void {
        self.pass(null) catch |err| {
            self.last_error = err;
        };
        if (self.view.restore == null) self.view.restore = leaf;
        self.restoreFocus();
        self.invalidate();
    }
    /// Focus the control a pass asked for once a frame registered it.
    fn focusTask(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.focus_queued = false;
        const id = self.pending_focus orelse return;
        self.pending_focus = null;
        if (self.context.window == null or self.context.input_state.focused == id) return;
        if (self.context.input_state.available(id)) self.focus(id);
    }
    fn onAction(ptr: *anyopaque, id: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.deliver(.{ .action = id });
    }
    fn onValue(ptr: *anyopaque, id: u64, change: ValueChange) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.deliver(.{ .value = .{ .id = id, .change = change } });
    }
    /// Route popup, tooltip and toast input before the Context, follow
    /// presses that leaves capture or that drag, and send a wheel event to
    /// the leaf or the innermost visible scroll container under it.
    fn onInput(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.building) return false;
        switch (event) {
            .pointer_move => |point| {
                const at: Point = .{ .x = point.x, .y = point.y };
                if (self.view.captureMove(at)) |result| if (result.consumed) return self.apply(result);
                const hover = self.view.hoverAt(at);
                if (self.view.embedPointerMove(at) or hover) self.invalidate();
                return false;
            },
            .pointer_down => |press| {
                if (press.button != .primary) return false;
                const point: Point = .{ .x = press.position.x, .y = press.position.y };
                switch (self.view.pointerDown(point)) {
                    .ignored => {},
                    .changed => self.invalidate(),
                    .consumed => {
                        self.invalidate();
                        return true;
                    },
                }
                const hit = self.context.input_state.hit(.{ .x = point.x, .y = point.y });
                const adjusting = if (hit) |id| if (self.context.input_state.get(id)) |item| item.options.range != null else false else false;
                const pressed = self.view.pointerPress(point, press.modifiers, self.time(), adjusting);
                if (pressed.consumed) return self.apply(pressed);
                // A press on a tree or table row selects through the view,
                // which sees its modifiers; the pass then focuses the row.
                if (self.view.rowPress(point, press.modifiers, hit orelse return false, self.context.currentTheme())) |value| {
                    self.deliver(value);
                    self.invalidate();
                    return true;
                }
                return false;
            },
            .pointer_up => |release| {
                if (release.button != .primary) return false;
                const result = self.view.captureRelease(.{ .x = release.position.x, .y = release.position.y });
                return self.apply(result);
            },
            .cancel_input => {
                _ = self.apply(self.view.captureCancel());
                return false;
            },
            .focus => |focused| {
                // A window that loses focus leaves no tooltip behind, and
                // loses the press it followed.
                self.view.window_focused = focused;
                self.invalidate();
                if (!focused) {
                    _ = self.apply(self.view.captureCancel());
                    const hover = self.view.hoverAt(null);
                    if (self.view.embedPointerMove(null) or hover) self.invalidate();
                }
                return false;
            },
            .key_input => |input| {
                if (self.view.dragKey(input)) |result| return self.apply(result);
                self.view.focus = self.context.input_state.focused;
                switch (self.view.routeKey(input)) {
                    // Keys nothing else routes go to a focused embedded leaf.
                    .ignored => {
                        if (!self.view.embedKey(input)) return false;
                        self.settleEmbed(null);
                        return true;
                    },
                    // A consumed key bypasses the Context, so repaint here
                    // for the moved highlight or closed list.
                    .handled => {
                        self.restoreFocus();
                        self.invalidate();
                        return true;
                    },
                    .pass => {
                        self.restoreFocus();
                        self.invalidate();
                        return false;
                    },
                    .deliver => |value| {
                        self.deliver(value);
                        self.invalidate();
                        return true;
                    },
                }
            },
            .wheel => |wheel| {
                const at: Point = .{ .x = wheel.position.x, .y = wheel.position.y };
                const delta: Point = .{ .x = wheel.delta.x, .y = wheel.delta.y };
                if (self.view.embedWheel(at, delta)) {
                    self.invalidate();
                    return true;
                }
                const id = self.view.scrollAt(at) orelse return false;
                self.deliver(.{ .scroll = .{ .id = id, .delta = delta } });
                return self.view.consumed;
            },
            else => return false,
        }
    }
    /// Releases go to the focused embedded leaf only.
    fn onKeyRelease(ptr: *anyopaque, _: *ui.Context, input: z.KeyInput) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (self.building) return;
        self.view.focus = self.context.input_state.focused;
        if (self.view.embedKeyUp(input)) self.settleEmbed(null);
    }
    /// Apply what the view did with pointer input; true when it took it.
    fn apply(self: *Host, result: PointerResult) bool {
        if (result.cancel_press) self.context.input_state.cancelPress();
        if (result.settle) {
            self.settleEmbed(result.focus);
        } else if (result.focus) |id| {
            self.view.restore = id;
            self.restoreFocus();
        }
        for (result.events) |slot| if (slot) |value| self.deliver(value);
        if (result.repaint or result.events[0] != null) self.invalidate();
        return result.consumed;
    }
    /// Follow a drag from another application, such as one a
    /// `ziggurat_system` drop target reports from its hover callback, at a
    /// point in window DIP, or with null once it left the window. True when
    /// a `View.dropTarget` there takes files or text as offered.
    pub fn systemDragOver(self: *Host, point: ?Point, files: bool, text: bool) bool {
        const result = self.view.systemDragOver(point, files, text);
        if (result.changed) self.invalidate();
        return result.accepted;
    }
    /// Deliver a drop from another application at a window point to the
    /// `View.dropTarget` there; true when one took it. The bytes are only
    /// borrowed for the pass that delivers them.
    pub fn systemDrop(self: *Host, point: Point, data: Dropped) bool {
        const event = self.view.systemDrop(point, data) orelse {
            self.invalidate();
            return false;
        };
        self.deliver(event);
        self.invalidate();
        return self.view.consumed;
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
        self.requestWake();
        if (self.view.focus_request) |id| {
            self.view.focus_request = null;
            if (self.context.input_state.focused != id) self.pending_focus = id;
        }
        if (self.pending_focus != null and !self.focus_queued) if (self.context.window) |window| {
            if (window.app.post(.{ .context = self, .call = focusTask })) |_| {
                self.focus_queued = true;
            } else |err| {
                self.last_error = self.last_error orelse err;
                self.pending_focus = null;
            }
        };
    }

    /// Hand a changed deadline to the scheduler after this paint.
    fn requestWake(self: *Host) void {
        if (self.scheduler == null or self.schedule_queued or std.meta.eql(self.view.wake, self.scheduled)) return;
        const window = self.context.window orelse return;
        window.app.post(.{ .context = self, .call = scheduleTask }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.schedule_queued = true;
    }
    fn scheduleTask(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.schedule_queued = false;
        const scheduler = self.scheduler orelse return;
        if (self.context.window == null or std.meta.eql(self.view.wake, self.scheduled)) return;
        self.scheduled = self.view.wake;
        scheduler.schedule(scheduler.context, self.view.wake, self.time());
    }
};

const Recorder = struct {
    const Call = struct { kind: Kind, id: u64, bounds: Rect, checked: bool = false };
    calls: [64]Call = undefined,
    len: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    fills: usize = 0,
    effects: usize = 0,
    opened_effects: [16]struct { margin: f32, opacity: u8 } = undefined,
    effect_depth: usize = 0,
    effect_count: usize = 0,
    chooser: u64 = 0,
    tooltip_id: u64 = 0,
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
    pub fn backdropEffect(self: *Recorder, _: Rect, _: f32, _: ui.BackdropEffect) void {
        self.effects += 1;
    }
    pub fn backdropShader(self: *Recorder, _: Rect, _: f32, _: ui.ShaderEffect) void {
        self.effects += 1;
    }
    pub fn beginEffect(self: *Recorder, _: Rect, effect: ui.ShaderEffect, options: ui.EffectOptions) !void {
        self.opened_effects[self.effect_count] = .{ .margin = effect.margin, .opacity = options.opacity };
        self.effect_depth += 1;
        self.effect_count += 1;
    }
    pub fn endEffect(self: *Recorder) !void {
        if (self.effect_depth == 0) return error.EffectStackEmpty;
        self.effect_depth -= 1;
    }
    pub fn indicator(self: *Recorder, id: u64, bounds: Rect) !void {
        self.push(.loading, id, bounds, false);
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
    pub fn labelFont(self: *Recorder, bounds: Rect, _: []const u8, _: u32, _: Font) void {
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
    pub fn listBox(self: *Recorder, id: u64, _: Rect, _: []const u8) !void {
        self.chooser = id;
    }
    pub fn listItem(self: *Recorder, id: u64, bounds: Rect, _: []const u8, checked: bool, options: ui.widgets.Options) !void {
        if (options.radio_group == null or options.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.list_item, id, bounds, checked);
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
    pub fn comboBox(self: *Recorder, id: u64, bounds: Rect, _: []const u8, expanded: bool, _: ui.widgets.Options) !void {
        self.push(.combo_box, id, bounds, expanded);
    }
    pub fn popupList(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.chooser = id;
        self.push(.popup, id, bounds, false);
    }
    pub fn popover(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.popover, id, bounds, false);
    }
    pub fn navButton(self: *Recorder, id: u64, bounds: Rect, _: NavDirection, _: []const u8, _: ui.widgets.Options) !void {
        self.push(.nav_button, id, bounds, false);
    }
    pub fn avatar(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: ui.widgets.AvatarOptions) !void {
        self.push(.avatar, id, bounds, false);
    }
    pub fn tooltip(self: *Recorder, id: u64, bounds: Rect, _: []const u8) !void {
        self.tooltip_id = id;
        self.push(.text, id, bounds, false);
    }
    pub fn status(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.toast, id, bounds, false);
    }
    pub fn search(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.search, id, bounds, false);
    }
    pub fn treeView(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: bool, _: u64) !void {
        self.chooser = id;
        self.push(.tree, id, bounds, false);
    }
    pub fn treeItem(self: *Recorder, id: u64, bounds: Rect, _: []const u8, options: ui.widgets.RowOptions) !void {
        if (options.control.radio_group == null or options.control.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.tree_row, id, bounds, options.selected);
    }
    pub fn dataTable(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: bool, _: u64) !void {
        self.chooser = id;
        self.push(.table, id, bounds, false);
    }
    pub fn tableHeader(self: *Recorder, id: u64, bounds: Rect, _: u64) !void {
        self.push(.table_header, id, bounds, false);
    }
    pub fn columnHeader(self: *Recorder, id: u64, bounds: Rect, _: []const u8, sort: ?SortDirection, _: bool, _: ui.widgets.Options) !void {
        self.push(.column_header, id, bounds, sort != null);
    }
    pub fn tableRow(self: *Recorder, id: u64, bounds: Rect, _: []const u8, options: ui.widgets.RowOptions) !void {
        if (options.control.radio_group == null or options.control.radio_group.? != self.chooser) return error.MissingGroup;
        self.push(.table_row, id, bounds, options.selected);
    }
    pub fn tokenField(self: *Recorder, id: u64, bounds: Rect, _: []const u8, _: u64) !void {
        self.push(.token_field, id, bounds, false);
    }
    pub fn tokenItem(self: *Recorder, id: u64, _: u64, bounds: Rect, _: []const u8, _: ui.widgets.TokenOptions) !void {
        self.push(.token, id, bounds, false);
    }
    pub fn comboField(self: *Recorder, id: u64, bounds: Rect, _: []const u8, expanded: bool, _: ui.widgets.Options) !void {
        self.push(.combo_field, id, bounds, expanded);
    }
    pub fn comboToggle(self: *Recorder, id: u64, bounds: Rect, expanded: bool, _: ui.widgets.Options) !void {
        self.push(.combo_toggle, id, bounds, expanded);
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

test "loading indicators size by aspect, ask for frames while moving and hold still on request" {
    var storage: Storage(16, 256) = .{};
    var view = View.init(storage.buffers());
    view.now = 1000;
    view.reset(.{}, null);
    try view.loadingIndicator(.bouncing_dots, .{ .size = 10 }, .{ .name = "Loading" });
    try view.loadingIndicator(.arc, .{}, .{});
    try view.finish();
    try std.testing.expectEqual(@as(?u64, 1000 + loading_frame_interval), view.wake);
    try view.arrange(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, .{}, .{});
    try std.testing.expectEqual(@as(f32, 20), view.nodes()[1].measured.preferred.width);
    try std.testing.expectEqual(@as(f32, 10), view.nodes()[1].bounds.height);
    try std.testing.expectEqual(@as(f32, ui.loading.default_size), view.nodes()[2].bounds.height);
    try std.testing.expectApproxEqAbs(ui.loading.phase(.arc, 1000, 0), view.nodes()[2].indicator.?.phase, 1e-12);
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(Kind.loading, recorder.calls[0].kind);
    try std.testing.expectEqual(Kind.loading, recorder.calls[1].kind);
    // A paused indicator with a timer holds its pose and resumes from it.
    var timer: LoadingTimer = .{};
    view.reset(.{}, null);
    try view.loadingIndicator(.ring, .{ .timer = &timer }, .{});
    try view.finish();
    view.now = 5000;
    view.reset(.{}, null);
    try view.loadingIndicator(.ring, .{ .timer = &timer, .paused = true }, .{});
    try view.finish();
    try std.testing.expectEqual(@as(?u64, null), view.wake);
    const held = view.nodes()[1].indicator.?.phase;
    try std.testing.expectApproxEqAbs(ui.loading.phase(.ring, 4000, 0), held, 1e-12);
    view.now = 900000;
    view.reset(.{}, null);
    try view.loadingIndicator(.ring, .{ .timer = &timer, .paused = true }, .{});
    try view.finish();
    try std.testing.expectEqual(held, view.nodes()[1].indicator.?.phase);
    view.now = 1000000;
    view.reset(.{}, null);
    try view.loadingIndicator(.ring, .{ .timer = &timer }, .{});
    try view.finish();
    try std.testing.expectApproxEqAbs(held, view.nodes()[1].indicator.?.phase, 1e-12);
    // Reduced motion: a still pose and no frames.
    view.preferences.reduce_motion = true;
    view.now = 2000000;
    view.reset(.{}, null);
    try view.loadingIndicator(.ring, .{}, .{});
    try view.finish();
    try std.testing.expectEqual(@as(?u64, null), view.wake);
    try std.testing.expectEqual(@as(f64, 0), view.nodes()[1].indicator.?.phase);
    view.reset(.{}, null);
    try std.testing.expectError(error.InvalidValue, view.loadingIndicator(.ring, .{ .size = 0 }, .{}));
}

test "materials replace container backgrounds and edges paint inside the clip" {
    var storage: Storage(16, 256) = .{};
    var view = View.init(storage.buffers());
    var model: ScrollModel = .{};
    view.reset(.{}, null);
    try view.row(.{ .background = 0xff0000, .material = .{ .glass = .{} }, .radius = 12, .padding = Insets.all(8) });
    try view.text("on glass", .{});
    try view.end();
    try view.scroll(&model, .{ .height = 60, .edges = .{ .top = .{}, .bottom = .{ .hard = true }, .height = 20 } });
    try view.text("content", .{});
    try view.end();
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 200, .height = 200 }, .{}, .{});
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(@as(usize, 3), recorder.effects);
    try std.testing.expectEqual(@as(usize, 0), recorder.clip_depth);
}

test "opacity, pose and effects wrap a node's subtree, closing inside out" {
    const library = try ui.effects.Library.create(std.testing.allocator);
    defer library.destroy();
    var storage: Storage(16, 256) = .{};
    var view = View.init(storage.buffers());
    view.reset(.{}, null);
    // Without the library only a custom effect opens.
    try view.column(.{ .opacity = 0.5, .pose = .{ .y = 10 }, .clip = true });
    try view.text("faded", .{ .opacity = 0.25 });
    try view.end();
    try view.text("tinted", .{ .effect = library.passthrough() });
    try std.testing.expectError(error.InvalidValue, view.text("bad", .{ .opacity = 2 }));
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 200, .height = 200 }, .{}, .{});
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(@as(usize, 1), recorder.effect_count);
    view.effects = library;
    recorder = .{};
    try view.paint(&recorder);
    // The column's pose carries its opacity; the faded text and the tinted
    // one open one effect each.
    try std.testing.expectEqual(@as(usize, 3), recorder.effect_count);
    try std.testing.expectEqual(@as(u8, 128), recorder.opened_effects[0].opacity);
    try std.testing.expectEqual(@as(f32, 10), recorder.opened_effects[0].margin);
    try std.testing.expectEqual(@as(u8, 64), recorder.opened_effects[1].opacity);
    try std.testing.expectEqual(@as(usize, 0), recorder.effect_depth);
    try std.testing.expectEqual(@as(usize, 0), recorder.clip_depth);
}

test "presentColumn enters, exits and asks for frames only while moving" {
    var storage: Storage(16, 256) = .{};
    var view = View.init(storage.buffers());
    var presence: Presence = .{};
    const transition: Transition = .{ .enter = .{ .tween = .{ .duration_ns = 100, .easing = .linear } }, .exit = .{ .tween = .{ .duration_ns = 100, .easing = .linear } } };
    const Pass = struct {
        fn run(v: *View, p: *Presence, t: Transition, now: u64, visible: bool) !bool {
            v.reset(.{}, null);
            v.now = now;
            const shown = try v.presentColumn(p, visible, t, .{});
            if (shown) {
                try v.text("panel", .{});
                try v.end();
            }
            try v.finish();
            return shown;
        }
    };
    try std.testing.expect(try Pass.run(&view, &presence, transition, 1000, true));
    try std.testing.expectEqual(@as(f32, 0), view.nodes()[1].style.opacity);
    try std.testing.expect(view.wake != null);
    try std.testing.expect(try Pass.run(&view, &presence, transition, 1050, true));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), view.nodes()[1].style.opacity, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4), view.nodes()[1].style.pose.?.y, 1e-6);
    try std.testing.expect(try Pass.run(&view, &presence, transition, 1100, true));
    try std.testing.expectEqual(@as(f32, 1), view.nodes()[1].style.opacity);
    try std.testing.expect(view.nodes()[1].style.pose == null);
    try std.testing.expectEqual(@as(?u64, null), view.wake);
    // Exiting keeps the content until the motion ends.
    try std.testing.expect(try Pass.run(&view, &presence, transition, 2000, false));
    try std.testing.expect(try Pass.run(&view, &presence, transition, 2050, false));
    try std.testing.expect(!try Pass.run(&view, &presence, transition, 2100, false));
    // Reduced motion shows the content at once.
    view.preferences.reduce_motion = true;
    try std.testing.expect(try Pass.run(&view, &presence, transition, 3000, true));
    try std.testing.expectEqual(@as(f32, 1), view.nodes()[1].style.opacity);
    try std.testing.expectEqual(@as(?u64, null), view.wake);
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

test "open lists and toasts paint after the tree and tooltips paint last" {
    var storage: Storage(32, 512) = .{};
    var view = View.init(storage.buffers());
    var queue: Toasts(2) = .{};
    _ = try queue.show("Saved", .{});
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        view.reset(.{}, null);
        view.now = 1000;
        try view.comboBox("Sans", .{ .name = "Font" });
        var font: u8 = 1;
        _ = try view.comboOption(u8, &font, 0, "Serif", .{});
        _ = try view.comboOption(u8, &font, 1, "Sans", .{});
        try view.end();
        try view.tooltip("Typeface");
        _ = try view.button("Apply", .{});
        _ = try view.toasts(&queue, .{});
        // Open the list and focus the combo box for the second pass.
        view.popup.open = view.nodes()[1].id;
        view.focus = view.nodes()[1].id;
        try view.finish();
    }
    try std.testing.expectEqual(@as(?u64, 1000 + view.tooltip_delay), view.wake);
    view.now += view.tooltip_delay;
    view.reset(.{}, null);
    // Rebuild once more at the later time so the tooltip shows.
    try view.comboBox("Sans", .{ .name = "Font" });
    var font: u8 = 1;
    _ = try view.comboOption(u8, &font, 0, "Serif", .{});
    _ = try view.comboOption(u8, &font, 1, "Sans", .{});
    try view.end();
    try view.tooltip("Typeface");
    _ = try view.button("Apply", .{});
    _ = try view.toasts(&queue, .{});
    view.focus = view.nodes()[1].id;
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 640, .height = 480 }, .{}, .{});
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    const calls = recorder.calls[0..recorder.len];
    try std.testing.expectEqual(Kind.combo_box, calls[0].kind);
    try std.testing.expect(calls[0].checked);
    try std.testing.expectEqual(Kind.button, calls[1].kind);
    var popup_at: ?usize = null;
    var toast_at: ?usize = null;
    for (calls, 0..) |call, i| switch (call.kind) {
        .popup => popup_at = i,
        .toast => toast_at = i,
        else => {},
    };
    try std.testing.expect(popup_at.? > 1 and toast_at.? > popup_at.?);
    try std.testing.expectEqual(tooltipId(view.nodes()[1].id), recorder.tooltip_id);
    try std.testing.expectEqual(Kind.text, calls[calls.len - 1].kind);
    try std.testing.expectEqual(@as(usize, 0), recorder.clip_depth);
}

test "each announcement paints a new status node, cut at a character boundary" {
    var storage: Storage(8, 64) = .{};
    var view = View.init(storage.buffers());
    view.reset(.{}, null);
    try view.text("chart", .{});
    try view.finish();
    try view.arrange(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, .{}, .{});
    var recorder: Recorder = .{};
    try view.paint(&recorder);
    try std.testing.expectEqual(@as(usize, 1), recorder.len);

    view.announce("Bar 1");
    recorder = .{};
    try view.paint(&recorder);
    const first = recorder.calls[1];
    try std.testing.expectEqual(Kind.toast, first.kind);
    try std.testing.expectEqual(announcementId(1), first.id);
    view.announce("Bar 1");
    recorder = .{};
    try view.paint(&recorder);
    try std.testing.expect(recorder.calls[1].id != first.id);

    var long: [max_announcement + 1]u8 = @splat('a');
    @memcpy(long[max_announcement - 1 ..], "\xc3\xa9");
    view.announce(&long);
    try std.testing.expectEqual(max_announcement - 1, view.announcement_len);
}
