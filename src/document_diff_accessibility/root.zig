const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const d = @import("ziggurat_document");
const ui = @import("ziggurat_ui");
const diff = @import("ziggurat_document_diff_view");
const a = @import("ziggurat_document_accessibility");
pub const controls = @import("controls.zig");

pub const Target = union(enum) {
    split: *diff.EditableSplit,
    unified: *diff.EditableUnified,
    fn coordinator(self: Target) *diff.EditableSplit {
        return switch (self) {
            .split => |value| value,
            .unified => |value| value.coordinator(),
        };
    }
};
/// Called during an accepted owner action. Queue explicit host work to prepare
/// again; calling prepare synchronously from this callback returns Busy.
pub const Changed = struct { context: *anyopaque, call: *const fn (*anyopaque, z.Window) anyerror!void };
pub const Options = struct {
    accessibility: a.Options = .{},
    original_name: []const u8 = "Original",
    modified_name: []const u8 = "Modified",
    changed: ?Changed = null,
    controls: ?*controls.Controls = null,
    /// Capture the whole Diff in one local scope. Required only with explicit
    /// affine_geometry. Typed Controls share this scope; custom auxiliary plans
    /// remain unsupported in that mode.
    affine_space_id: ?u64 = null,
};
pub const auxiliary = a.auxiliary;

/// Optional same-coordinate companion. It owns no editable text or history.
/// Close it before the retained Diff coordinator; allocator/App cover all uses.
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    view: *diff.EditableSplit,
    window: z.Window,
    native: ?*a.Bridge = null,
    owner: std.Thread.Id,
    changed: ?Changed,
    controls: ?*controls.Controls = null,
    context: ?*ui.Context = null,
    auxiliary_handler: ?a.AuxiliaryHandler = null,
    busy: bool = false,
    closing: bool = false,
    prepared_epoch: u64 = 0,
    prepared_bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    needs_prepare: bool = true,
    coordinates: ?*diff.editable.CoordinateBinding = null,

    pub fn create(allocator: std.mem.Allocator, window: z.Window, target: Target, options: Options) !*Bridge {
        if (builtin.os.tag != .windows) return error.UnsupportedCapability;
        if (options.accessibility.affine_geometry != (options.affine_space_id != null)) return error.UnsupportedGeometry;
        if (options.accessibility.affine_geometry and options.accessibility.auxiliary != null) return error.UnsupportedAuxiliaryConfiguration;
        if (options.accessibility.publication != null) return error.ConflictingPublicationOwner;
        const host_bytes = @sizeOf(Bridge) + (if (options.controls != null) @sizeOf(controls.Controls) else @as(usize, 0));
        if (options.accessibility.bytes <= host_bytes) return error.InvalidLimits;
        if (options.controls) |value| {
            if (options.accessibility.auxiliary != null) return error.ConflictingAuxiliaryOwner;
            if (value.bound) return error.Busy;
        }
        if (std.Thread.getCurrentId() != window.app.owner) return error.WrongThread;
        const scope = window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const view = target.coordinator();
        const pair = try view.sourcePair();
        if (!std.meta.eql(pair.window, window)) return error.ForeignWindow;
        try view.retainClient();
        errdefer view.releaseClient() catch unreachable;
        if (options.controls) |value| value.bound = true;
        errdefer if (options.controls) |value| {
            value.bound = false;
        };
        const self = try allocator.create(Bridge);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .view = view, .window = window, .owner = std.Thread.getCurrentId(), .changed = options.changed, .controls = options.controls };
        if (options.affine_space_id) |id| self.coordinates = try view.acquireCoordinates(id);
        errdefer if (self.coordinates) |binding| binding.close() catch unreachable;
        var native_options = options.accessibility;
        native_options.bytes -= host_bytes;
        native_options.presentation_epochs = true;
        if (self.coordinates) |binding| native_options.publication = try binding.publication();
        if (options.controls != null) native_options.auxiliary = .{ .limits = .{ .nodes = controls.max_nodes, .label_bytes = controls.label_bytes }, .handler = .{ .context = self, .validate = controlsValidate, .call = controlsCall, .focus = controlsFocus } };
        if (native_options.auxiliary) |*value| {
            self.auxiliary_handler = value.handler;
            value.handler = .{ .context = self, .validate = validateAuxiliary, .call = auxiliaryAction, .focus = if (value.handler.focus != null) auxiliaryFocus else null };
        }
        const actions: a.Actions = .{ .context = self, .validate = validateAction, .focus = focusAction, .select = selectAction, .scroll = scrollAction };
        const original: a.Source = .{ .adapter = pair.adapters[0], .name = options.original_name, .read_only = pair.mode == .unified, .selectable = pair.mode == .split, .focusable = pair.mode == .split, .actions = if (pair.mode == .split) actions else .{ .context = self, .validate = validateAction }, .changed = .{ .context = self, .call = changedAction } };
        var coordinate_scope = if (self.coordinates) |binding| try binding.pin() else null;
        defer if (coordinate_scope) |*pin| pin.end();
        self.native = try a.Bridge.create(allocator, window, &.{ original, .{ .adapter = pair.adapters[1], .name = options.modified_name, .actions = actions, .changed = .{ .context = self, .call = changedAction } } }, native_options);
        return self;
    }
    fn checked(self: *const Bridge) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        if (self.closing) return error.Closed;
    }
    pub fn attachContext(self: *Bridge, context: *ui.Context) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.native.?.attachContext(context);
        if (self.coordinates) |binding| try binding.attachContext(context);
        self.context = context;
    }
    /// Install only a capture tied to the accepted native geometry publication.
    /// Explicitly repeat after workspace recreation; old bindings cannot revive.
    pub fn setCommittedSpace(self: *Bridge, token: ui.SpaceToken) !void {
        try self.checked();
        const binding = self.coordinates orelse return error.UnsupportedGeometry;
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try binding.setCommittedSpace(token);
    }
    pub fn clearCommittedSpace(self: *Bridge) !void {
        try self.checked();
        const binding = self.coordinates orelse return error.UnsupportedGeometry;
        self.busy = true;
        defer self.busy = false;
        try binding.withdraw();
    }
    pub fn syncNativeCaret(self: *Bridge) !void {
        try self.checked();
        const binding = self.coordinates orelse return error.UnsupportedGeometry;
        try binding.syncCaret();
    }
    /// Explicit preparation after Diff.prepare, outside drawing. Full Readers
    /// are needed only for changed committed source text, never visible excerpts.
    pub fn prepare(self: *Bridge, readers: [2]?d.Reader) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        var rows: [96]diff.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        var ghosts: [96]usize = undefined;
        var count: usize = 0;
        if (presentation.mode == .unified and presentation.projected) for (presentation.rows) |row| {
            if (row.b == null) if (row.a) |line| {
                ghosts[count] = line;
                count += 1;
            };
        };
        const selections: [2]a.GeometrySelection = .{ if (presentation.mode == .split) .all else if (count == 0) .hidden else .{ .paragraphs = ghosts[0..count] }, .all };
        try self.native.?.prepareText(&readers);
        try self.view.validatePresentation(presentation.epoch);
        try self.native.?.prepareGeometrySelected(&selections, presentation.epoch);
        try self.view.validatePresentation(presentation.epoch);
        self.prepared_epoch = presentation.epoch;
        self.prepared_bounds = presentation.bounds;
        self.needs_prepare = false;
    }
    /// Pair drawing and recording prevents arming geometry for an omitted source.
    /// Commands, input and native geometry still commit only on successful front.
    pub fn draw(self: *Bridge, frame: *ui.Frame, colors: diff.Colors) !void {
        errdefer |err| frame.failure = frame.failure orelse err;
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.recordCheck();
        try self.view.draw(frame, self.prepared_bounds, colors);
        try self.native.?.recordGeometry(frame);
        if (self.coordinates) |binding| try binding.record(frame, self.prepared_epoch);
        if (self.controls) |value| {
            try value.draw(frame);
            if (self.coordinates != null) {
                const bank = &value.banks[value.active];
                try self.native.?.recordAuxiliaryLocal(frame, bank.bounds[0..bank.len]);
            } else try self.native.?.recordAuxiliary(frame);
        }
    }
    /// Use after drawing the same prepared Diff when integrating custom marks.
    pub fn record(self: *Bridge, frame: *ui.Frame) !void {
        errdefer |err| frame.failure = frame.failure orelse err;
        try self.checked();
        try self.recordCheck();
        try self.native.?.recordGeometry(frame);
        if (self.coordinates) |binding| try binding.record(frame, self.prepared_epoch);
    }
    /// Prepare only explicit controls that the host will actually draw. Their
    /// typed keys belong to this comparison; full text keeps A/B coordinates.
    pub fn prepareAuxiliary(self: *Bridge, plan: auxiliary.SemanticPlan) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        self.busy = true;
        defer self.busy = false;
        try self.recordCheck();
        var rows: [96]diff.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        for (plan.nodes) |node| if (node.key.comparison != presentation.comparison_serial) return error.StaleComparison;
        try self.native.?.prepareAuxiliary(plan);
        try self.recordCheck();
    }
    /// Call after recording the explicit Frame.semantic/button subtree.
    pub fn recordAuxiliary(self: *Bridge, frame: *ui.Frame) !void {
        try self.checked();
        try self.recordCheck();
        try self.native.?.recordAuxiliary(frame);
    }
    /// Prepare derived controls after prepare(), outside paint. A failed
    /// candidate cannot replace the successful native identity/input snapshot.
    pub fn prepareControls(self: *Bridge, plan: controls.Plan) !void {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        const workspace = self.controls orelse return error.NotSupported;
        self.busy = true;
        defer self.busy = false;
        try self.recordCheck();
        var rows: [96]diff.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        const candidate = try workspace.candidate(self.view, presentation, plan);
        try self.native.?.prepareAuxiliary(candidate);
        try self.recordCheck();
        workspace.publish();
    }
    pub fn controlAction(self: *Bridge, id: u64) !?controls.Outcome {
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (self.controls == null) return null;
        const window_state = try self.window.state();
        if (!window_state.enabled or window_state.modal_blocked) return error.Disabled;
        const accepted = self.native.?.acceptedAuxiliary(id) catch |err| if (err == error.NativeUnavailable) return null else return err;
        try validateAuxiliary(self, self.window, accepted.epoch, accepted.key);
        if (!accepted.enabled or !accepted.visible) return error.Disabled;
        self.busy = true;
        defer self.busy = false;
        return try self.executeControl(accepted.key, if (accepted.key.kind == .disclosure) !accepted.expanded else false);
    }
    /// Invoke from the host's on_input before any direct Diff routing. Control
    /// press/release/Tab remain owned by Context.Input; body input stays in View.
    pub fn handleEvent(self: *Bridge, event: z.Event, parameters: diff.Parameters) !bool {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.closing) return error.Closed;
        switch (event) {
            .cancel_input, .window_state, .window_position => return false,
            else => {},
        }
        if (event == .focus and self.busy) {
            // Core already revoked the physical client on focus loss. Do not
            // reenter an in-progress pair/Document transaction to re-layout.
            if (!event.focus) self.needs_prepare = true;
            return false;
        }
        try self.checked();
        const scope = self.window.beginCallback() orelse return error.Closed;
        defer scope.end();
        if (self.controls == null and self.coordinates == null) return error.NotSupported;
        const context = self.context orelse return error.NotAttached;
        try self.recordCheck();
        const coordinate = if (self.coordinates) |binding| try binding.check() else null;
        self.busy = true;
        defer self.busy = false;
        if (self.controls != null and event == .pointer_down) {
            if (try context.hitControl(event.pointer_down.position)) |hit| {
                const accepted = self.native.?.acceptedAuxiliary(hit.id) catch |err| switch (err) {
                    error.NativeUnavailable, error.StalePresentation, error.GeometryRequired => return true,
                    else => return err,
                };
                try self.validateControlInput(accepted, coordinate);
                if (hit.options.enabled and accepted.enabled and accepted.visible) {
                    errdefer context.blurControls() catch {};
                    try self.view.blurPresented(self.prepared_epoch);
                    try self.validateControlInput(accepted, coordinate);
                    if (hit.options.focusable) try context.focusControl(hit.id);
                    try self.validateControlInput(accepted, coordinate);
                }
                return false;
            }
            try context.blurControls();
        }
        if (self.controls != null and event == .key_input and event.key_input.key == .tab and !event.key_input.modifiers.control and !event.key_input.modifiers.alt and !event.key_input.modifiers.super) {
            if (context.input_state.focused == null) try self.view.blurPresented(self.prepared_epoch);
            try self.checkCoordinate(coordinate);
            return false;
        }
        if (self.controls != null and (context.input_state.focused != null or context.input_state.active != null)) switch (event) {
            .key_input, .key, .edit_key, .text_input, .pointer_move, .pointer_up => return false,
            else => {},
        };
        const used = try self.view.handleEvent(event, self.prepared_bounds, parameters);
        self.view.validatePresentation(self.prepared_epoch) catch {
            self.needs_prepare = true;
        };
        return used;
    }
    pub fn retainAuxiliaryProvider(self: *Bridge, key: auxiliary.Key) !*anyopaque {
        try self.checked();
        return self.native.?.retainAuxiliaryProvider(key);
    }
    fn recordCheck(self: *Bridge) !void {
        if (self.needs_prepare) return error.GeometryRequired;
        try self.view.validatePresentation(self.prepared_epoch);
    }
    fn checkCoordinate(self: *const Bridge, coordinate: ?u64) !void {
        if (self.coordinates) |binding| if (coordinate != try binding.check()) return error.StalePresentation;
    }
    fn validateControlInput(self: *Bridge, accepted: a.AcceptedAuxiliary, coordinate: ?u64) !void {
        try self.checkCoordinate(coordinate);
        if (self.closing or self.needs_prepare or accepted.epoch != self.prepared_epoch) return error.StalePresentation;
        try self.view.validatePresentation(accepted.epoch);
        const state = try self.window.state();
        if (!state.enabled or state.modal_blocked) return error.Disabled;
        const pair = try self.view.sourcePair();
        for (pair.adapters) |adapter| if (try (try adapter.sourceDocument()).composition() != null) return error.CompositionActive;
    }
    pub fn retainProvider(self: *Bridge, source: ?usize) !*anyopaque {
        try self.checked();
        return self.native.?.retainProvider(source);
    }
    pub fn stats(self: *const Bridge) !a.Stats {
        try self.checked();
        var result = try self.native.?.stats();
        const host_bytes = @sizeOf(Bridge) + (if (self.controls != null) @sizeOf(controls.Controls) else @as(usize, 0));
        result.requested_bytes += host_bytes;
        result.peak_reserved_bytes += host_bytes;
        result.byte_limit += host_bytes;
        return result;
    }
    pub fn needsPrepare(self: *const Bridge) !bool {
        try self.checked();
        return self.needs_prepare;
    }
    pub fn close(self: *Bridge) !void {
        if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
        if (self.busy) return error.Busy;
        const scope = self.window.app.beginTeardownCallback();
        defer scope.end();
        self.busy = true;
        errdefer self.busy = false;
        self.closing = true;
        if (self.coordinates) |binding| {
            try binding.withdraw();
            if (self.native) |native| {
                var pin = try binding.pin();
                native.close() catch |err| {
                    pin.end();
                    return err;
                };
                // Inner close completed, including its last foreign free.
                // Any later cleanup failure leaves only the remaining owners.
                self.native = null;
                pin.end();
            }
            try binding.close();
            self.coordinates = null;
        } else if (self.native) |native| {
            try native.close();
            self.native = null;
        }
        if (self.controls) |value| {
            value.bound = false;
            value.valid = false;
        }
        const view = self.view;
        const allocator = self.allocator;
        allocator.destroy(self);
        // Keep the host/allocator context retained across its final foreign free.
        // There must be no self access after that callback.
        view.releaseClient() catch unreachable;
    }
    fn validateAction(ptr: *anyopaque, window: z.Window, _: usize, epoch: u64) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        try self.checked();
        if (!std.meta.eql(window, self.window) or epoch != self.prepared_epoch or self.needs_prepare) return error.StalePresentation;
        if (self.coordinates) |binding| _ = try binding.check();
        try self.view.validatePresentation(epoch);
        const pair = try self.view.sourcePair();
        for (pair.adapters) |adapter| if (try (try adapter.sourceDocument()).composition() != null) return error.CompositionActive;
    }
    fn validateAuxiliary(ptr: *anyopaque, window: z.Window, epoch: u64, key: auxiliary.Key) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        try validateAction(ptr, window, 0, epoch);
        const coordinate = if (self.coordinates) |binding| try binding.check() else null;
        var rows: [96]diff.editable.Row = undefined;
        const presentation = try self.view.copyPresentation(&rows);
        if (key.comparison != presentation.comparison_serial) return error.StaleComparison;
        const handler = self.auxiliary_handler orelse return error.NotSupported;
        self.busy = true;
        defer self.busy = false;
        try handler.validate(handler.context, window, epoch, key);
        try self.checkCoordinate(coordinate);
        try self.view.validatePresentation(epoch);
    }
    fn auxiliaryAction(ptr: *anyopaque, window: z.Window, action: a.AuxiliaryAction) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        const handler = self.auxiliary_handler orelse return error.NotSupported;
        self.busy = true;
        defer self.busy = false;
        try handler.call(handler.context, window, action);
    }
    fn auxiliaryFocus(ptr: *anyopaque, window: z.Window, key: auxiliary.Key) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        const handler = self.auxiliary_handler orelse return error.NotSupported;
        const focus = handler.focus orelse return error.NotSupported;
        self.busy = true;
        defer self.busy = false;
        try focus(handler.context, window, key);
    }
    fn controlsValidate(ptr: *anyopaque, _: z.Window, _: u64, key: auxiliary.Key) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        _ = try self.controls.?.intent(key, false);
    }
    fn controlsCall(ptr: *anyopaque, _: z.Window, action: a.AuxiliaryAction) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        const expanded = switch (action.operation) {
            .invoke => false,
            .expanded => |value| value,
        };
        _ = try self.executeControl(action.key, expanded);
    }
    fn executeControl(self: *Bridge, key: auxiliary.Key, expanded: bool) !controls.Outcome {
        const intent = try self.controls.?.intent(key, expanded);
        const outcome: controls.Outcome = switch (intent) {
            .revert => |value| result: {
                const edited = try self.view.revertPresented(self.prepared_epoch, value.hunk, value.direction);
                break :result .{ .changed = edited.changed, .index_required = edited.index_required, .presentation_error = edited.presentation_error };
            },
            .context => |value| result: {
                const edited = try self.view.setContextPresented(self.prepared_epoch, value.key, value.collapsed);
                break :result .{ .changed = edited.changed, .presentation_error = edited.presentation_error };
            },
        };
        if (outcome.changed) {
            self.needs_prepare = true;
            if (self.changed) |callback| callback.call(callback.context, self.window) catch |err| {
                self.window.report(.{ .domain = .core, .operation = .resource_release, .err = err });
            };
        }
        if (outcome.presentation_error) |err| self.window.report(.{ .domain = .core, .operation = .resource_release, .err = err });
        return outcome;
    }
    fn controlsFocus(ptr: *anyopaque, _: z.Window, key: auxiliary.Key) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        const context = self.context orelse return error.NotAttached;
        const accepted = try self.native.?.acceptedAuxiliaryKey(key);
        const coordinate = if (self.coordinates) |binding| try binding.check() else null;
        try self.validateControlInput(accepted, coordinate);
        if (!accepted.enabled or !accepted.visible or !accepted.focusable) return error.ControlUnavailable;
        errdefer context.blurControls() catch {};
        try self.view.blurPresented(self.prepared_epoch);
        try self.validateControlInput(accepted, coordinate);
        try context.focusControl(accepted.frame_id);
        try self.validateControlInput(accepted, coordinate);
    }
    fn focusAction(ptr: *anyopaque, _: z.Window, source: usize) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.busy = true;
        defer self.busy = false;
        if (self.context) |context| try context.blurControls();
        try self.view.focusPresented(self.prepared_epoch, @enumFromInt(source));
    }
    fn selectAction(ptr: *anyopaque, window: z.Window, source: usize, selections: []const d.Selection, primary: usize) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.busy = true;
        defer self.busy = false;
        const result = try self.view.selectPresented(self.prepared_epoch, @enumFromInt(source), selections, primary);
        self.needs_prepare = true;
        if (result.presentation_error) |err| window.report(.{ .domain = .core, .operation = .resource_release, .err = err });
    }
    fn scrollAction(ptr: *anyopaque, _: z.Window, source: usize, range: d.Range, align_top: bool) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.busy = true;
        defer self.busy = false;
        try self.view.scrollPresented(self.prepared_epoch, @enumFromInt(source), range, align_top);
        self.needs_prepare = true;
    }
    fn changedAction(ptr: *anyopaque, window: z.Window, _: usize, _: @FieldType(a.Source, "adapter")) !void {
        const self: *Bridge = @ptrCast(@alignCast(ptr));
        self.busy = true;
        defer self.busy = false;
        self.needs_prepare = true;
        if (self.changed) |callback| try callback.call(callback.context, window);
    }
};

test "unsupported backend rejects before touching target or allocator" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var denied = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.UnsupportedCapability, Bridge.create(denied.allocator(), undefined, .{ .split = @ptrFromInt(1) }, .{}));
    try std.testing.expectEqual(@as(usize, 0), denied.allocations);
}
test {
    _ = controls;
}
test "unsupported affine combinations and impossible budgets reject before retaining sources" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var denied = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.UnsupportedGeometry, Bridge.create(denied.allocator(), undefined, .{ .split = @ptrFromInt(1) }, .{ .accessibility = .{ .affine_geometry = true } }));
    try std.testing.expectError(error.UnsupportedAuxiliaryConfiguration, Bridge.create(denied.allocator(), undefined, .{ .split = @ptrFromInt(1) }, .{ .accessibility = .{ .affine_geometry = true, .auxiliary = .{ .handler = undefined } }, .affine_space_id = 91 }));
    try std.testing.expectError(error.InvalidLimits, Bridge.create(denied.allocator(), undefined, .{ .split = @ptrFromInt(1) }, .{ .accessibility = .{ .bytes = 1 } }));
    try std.testing.expectEqual(@as(usize, 0), denied.allocations);
}
