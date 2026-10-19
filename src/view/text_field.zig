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
    /// Accessible name of the text box.
    name: []const u8 = "",
    colors: editing.Colors = .{},
    /// Preferred width before the parent's flex layout applies.
    width: f32 = 200,
    /// Visible lines, used to size a multiline field.
    lines: u32 = 1,
};

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
    /// The first error from deferred preparation or attach, for diagnostics.
    last_error: ?anyerror = null,

    pub fn init(field: *editing.Field, host: *view.Host, parameters: editing.Parameters, options: Options) TextField {
        return .{ .field = field, .host = host, .parameters = parameters, .options = options };
    }

    /// The leaf to emit from a build function with `View.embed`. Give it a
    /// `Style.key` when siblings before it can change, so its id stays put.
    pub fn embed(self: *TextField) view.Embed {
        return .{ .context = self, .measure = measure, .place = place, .paint = paint };
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
        }
        window.invalidate();
    }

    fn paint(ptr: *anyopaque, frame: *ui.Frame, _: u64, bounds: view.Rect) anyerror!void {
        const self: *TextField = @ptrCast(@alignCast(ptr));
        const theme = frame.currentTheme();
        // Until the posted preparation lands, the box keeps its last prepared
        // place so focus and hit targets stay consistent with the text.
        const box = self.prepared orelse bounds;
        const focused = self.attached and frame.context.input_state.focused == self.id;
        const enabled = self.field.options.policy.enabled;
        frame.roundedRect(box, 3, ui.Color.rgb(if (focused) theme.palette.focus else if (enabled) theme.palette.border else theme.palette.disabled_border));
        frame.roundedRect(.{ .x = box.x + theme.metrics.border, .y = box.y + theme.metrics.border, .width = @max(0, box.width - 2 * theme.metrics.border), .height = @max(0, box.height - 2 * theme.metrics.border) }, 2, ui.Color.rgb(theme.palette.field));
        if (!self.attached) return;
        try self.field.draw(frame, self.options.colors, self.options.name);
    }
};
