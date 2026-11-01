//! An editable single-line or multiline text field for declarative views,
//! over an application-owned `ziggurat_document_editor.Field`. The view
//! places the field each frame; preparing it for new bounds runs as a posted
//! task after paint, never inside paint. Native text input, IME, focus,
//! clipboard and accessibility come from the Field and the UI Context.
const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const view = @import("ziggurat_view");
const editing = @import("ziggurat_document_editor");

pub const Options = struct {
    /// Accessible name of the text box; when empty inside a view field,
    /// the field's label.
    name: []const u8 = "",
    colors: editing.Colors = .{},
    /// Preferred width before the parent's flex layout applies.
    width: f32 = 200,
    /// Visible lines, used to size a multiline field.
    lines: u32 = 1,
    /// Draw the field's border and background. Turn it off inside an
    /// editable combo box or token field, which draw their own.
    frame: bool = true,
    /// Called once the field registered with the window, after the first
    /// frame that placed it: from then on it can take focus and text.
    attached: ?Callback = null,
    /// Text shown in the field while it is empty and nothing is being
    /// composed, such as "Search". A search, token field or editable combo
    /// box around the field gives its `Style.placeholder` when this is empty.
    placeholder: []const u8 = "",
    /// Color of the placeholder; null is the theme's muted text. Paint only:
    /// the text typed and the theme are unchanged.
    placeholder_color: ?u32 = null,
    /// Width of the caret in DIP, rounded to device pixels and at least one
    /// pixel wide, for a block-like caret, large print or a demonstration;
    /// 0 or less hides it while the field stays editable. Null keeps
    /// `colors.caret_style`, or the platform's one-pixel caret. Paint only:
    /// layout, input method placement and blinking are unchanged.
    caret_width: ?f32 = null,
};

pub const Callback = struct { context: ?*anyopaque = null, call: *const fn (?*anyopaque, *TextField) void };

/// Keep TextField at a stable address while the view emits it and until
/// `detach`. The Field, its Document and Engine stay owned by the caller.
pub const TextField = struct {
    field: *editing.Field,
    host: *view.Host,
    parameters: editing.Parameters,
    options: Options,
    id: u64 = 0,
    /// Outer bounds the Field was last prepared for.
    prepared: ?view.Rect = null,
    pending: ?view.Rect = null,
    queued: bool = false,
    attached: bool = false,
    /// `focus` was called before the field had a node id.
    focus_pending: bool = false,
    /// The first error from deferred preparation or attach, for diagnostics.
    last_error: ?anyerror = null,
    /// What an enclosing form field adds for the paint that follows; its
    /// strings borrow the view's storage for that paint only.
    annotation: view.Annotation = .{},

    pub fn init(field: *editing.Field, host: *view.Host, parameters: editing.Parameters, options: Options) TextField {
        return .{ .field = field, .host = host, .parameters = parameters, .options = options };
    }

    /// The leaf to emit from a build function with `View.embed`. Give it a
    /// `Style.key` when siblings before it can change, so its id stays put.
    pub fn embed(self: *TextField) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint, .annotate = annotate, .status = status, .cursor = cursor };
    }

    /// Give the field keyboard focus: at once when it is attached, or as
    /// soon as the frame that attaches it lands. Call outside passes and
    /// paint, such as from a button's branch after the pass.
    pub fn focus(self: *TextField) void {
        if (self.id == 0) {
            self.focus_pending = true;
            return;
        }
        self.host.focusNode(self.id);
    }

    /// Shows or hides the text as a password, as an eye button beside the
    /// field does; the field is shaped again after the next paint.
    pub fn setPassword(self: *TextField, password: bool) !void {
        try self.field.setPassword(password);
        self.prepared = null;
        if (self.host.context.window) |window| window.invalidate();
    }

    /// Stop deferred work before the Field is closed. Closing the Field is
    /// still the caller's job and unregisters it from the Context.
    pub fn detach(self: *TextField) void {
        self.pending = null;
        self.attached = false;
        self.prepared = null;
    }

    fn inner(theme: ui.Theme, bounds: view.Rect) view.Rect {
        const inset = theme.metrics.border + theme.metrics.indicator_inset;
        return .{ .x = bounds.x + inset, .y = bounds.y + inset, .width = @max(0, bounds.width - 2 * inset), .height = @max(0, bounds.height - 2 * inset) };
    }

    fn measure(ptr: *anyopaque, theme: ui.Theme) view.layout.Measurement {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        const inset = theme.metrics.border + theme.metrics.indicator_inset;
        const line = @ceil(self.parameters.font.size * 1.5);
        const height = line * @as(f32, @floatFromInt(@max(1, self.options.lines))) + 2 * inset;
        return .{ .minimum = .{ .width = 2 * inset + line, .height = height }, .preferred = .{ .width = self.options.width, .height = height } };
    }

    fn place(ptr: *anyopaque, id: u64, bounds: view.Rect) void {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        if (self.attached and self.id != id) {
            // A new id means a different node; it needs a new registration.
            self.last_error = self.last_error orelse error.TextFieldIdChanged;
            return;
        }
        self.id = id;
        if (self.prepared) |current| if (std.meta.eql(current, bounds)) {
            self.pending = null;
            return;
        };
        self.pending = bounds;
        if (self.queued) return;
        const window = self.host.context.window orelse return;
        window.app.post(.{ .context = self, .call = run }) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.queued = true;
    }

    /// Posted after paint: prepare for the latest bounds, attach once, repaint.
    fn run(ptr: *anyopaque) void {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        self.queued = false;
        const bounds = self.pending orelse return;
        self.pending = null;
        const window = self.host.context.window orelse return;
        const theme = self.host.context.currentTheme();
        self.field.prepare(inner(theme, bounds), self.parameters) catch |err| {
            self.last_error = self.last_error orelse err;
            return;
        };
        self.prepared = bounds;
        if (!self.attached) {
            self.field.attach(&self.host.context, self.id) catch |err| {
                self.last_error = self.last_error orelse err;
                return;
            };
            self.attached = true;
            if (self.focus_pending) {
                self.focus_pending = false;
                self.host.focusNode(self.id);
            }
            if (self.options.attached) |callback| callback.call(callback.context, self);
        }
        window.invalidate();
    }

    /// Composition and emptiness from the Field's document; a document
    /// that cannot answer reports neither.
    fn status(ptr: *anyopaque) view.EmbedStatus {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        const document = self.field.document;
        const composing = if (document.composition()) |value| value != null else |_| false;
        const empty = if (document.byteLength()) |length| length == 0 else |_| false;
        return .{ .composing = composing, .empty = empty and !composing };
    }

    fn cursor(_: *anyopaque, _: u64, _: view.Point) ?view.Cursor {
        return .text;
    }

    fn annotate(ptr: *anyopaque, annotation: view.Annotation) void {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        self.annotation = annotation;
    }
    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        // Until the posted preparation lands, the box keeps its last prepared
        // place so focus and hit targets stay consistent with the text.
        const box = self.prepared orelse bounds;
        const focused = self.attached and frame.context.input_state.focused == self.id;
        const enabled = self.field.options.policy.enabled;
        if (self.options.frame) frame.roundedRect(box, 3, ui.Color.rgb(if (focused) theme.palette.focus else if (enabled) theme.palette.border else theme.palette.disabled_border));
        if (self.options.frame) frame.roundedRect(.{ .x = box.x + theme.metrics.border, .y = box.y + theme.metrics.border, .width = @max(0, box.width - 2 * theme.metrics.border), .height = @max(0, box.height - 2 * theme.metrics.border) }, 2, ui.Color.rgb(theme.palette.field));
        if (!self.attached) return;
        const about = self.annotation;
        self.annotation = .{};
        const placeholder = if (self.options.placeholder.len > 0) self.options.placeholder else about.placeholder;
        if (placeholder.len > 0 and status(self).empty) {
            const area = inner(theme, box);
            const line = @min(area.height, @ceil(self.parameters.font.size * 1.5));
            const color = self.options.placeholder_color orelse about.placeholder_color orelse theme.palette.disabled_text;
            frame.labelFont(.{ .x = area.x, .y = area.y, .width = area.width, .height = line }, placeholder, color, .{ .size = self.parameters.font.size });
        }
        // A field without a name of its own is named by its placeholder.
        const name = if (self.options.name.len > 0) self.options.name else if (about.name.len > 0) about.name else placeholder;
        try self.field.drawDescribed(frame, colorsFor(self.options, frame.size.scale), name, .{ .description = about.description, .invalid = about.invalid, .required = about.required });
    }

    /// The colors the field draws with, its caret `caret_width` wide.
    pub fn colorsFor(options: Options, scale: f32) editing.Colors {
        var colors = options.colors;
        const width = options.caret_width orelse return colors;
        var caret = colors.caret_style orelse editing.caret_visual.Style{};
        if (!std.math.isFinite(width) or width <= 0) {
            caret.enabled = false;
        } else {
            const pixels = @max(1, @round(width * scale));
            caret.thickness = pixels / scale;
            caret.terminal_width = caret.thickness;
        }
        colors.caret_style = caret;
        return colors;
    }
};

test "a caret width rounds to device pixels, at least one, and zero hides it" {
    const wide = TextField.colorsFor(.{ .caret_width = 2.4 }, 2).caret_style.?;
    try std.testing.expectEqual(@as(f32, 2.5), wide.thickness);
    try std.testing.expect(wide.enabled);
    const thin = TextField.colorsFor(.{ .caret_width = 0.1 }, 1).caret_style.?;
    try std.testing.expectEqual(@as(f32, 1), thin.thickness);
    try std.testing.expect(!TextField.colorsFor(.{ .caret_width = 0 }, 1).caret_style.?.enabled);
    try std.testing.expect(TextField.colorsFor(.{}, 1).caret_style == null);
}
