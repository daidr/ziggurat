const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const e = @import("root.zig");

pub const Policy = struct { enabled: bool = true, read_only: bool = false };
/// Help or error text and form state announced with the text box.
pub const Description = struct { description: []const u8 = "", invalid: bool = false, required: bool = false };
pub const Options = struct {
    multiline: bool = false,
    accept_tab: bool = false,
    words: bool = false,
    policy: Policy = .{},
    /// Two bounded scratch buffers; neither is an editing authority.
    value_bytes: usize = 8192,
    storage_bytes: usize = 64 * 1024,
    adapter: e.Limits = .{},
    clipboard: ?ui.editor.Clipboard = null,
    context: ?*anyopaque = null,
    changed: ?*const fn (?*anyopaque, z.Window, u64) void = null,
    submit: ?*const fn (?*anyopaque, z.Window) void = null,
};

/// One stable field owns one Adapter and borrows the caller's sole Document
/// and Engine. Close before those owners, and before releasing Context storage.
/// ResourceInUse means ingress is already retired; retry after the callback.
pub fn Field(comptime Private: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        owner: std.Thread.Id,
        document: *d.Document,
        adapter: *e.Adapter,
        options: Options,
        storage: []u8,
        value: []u8,
        scratch: []u8,
        value_len: usize = 0,
        value_revision: u64 = 0,
        notified_text_version: u64,
        policy_generation: u64 = 1,
        token: ?ui.TextFieldToken = null,
        window: ?z.Window = null,
        observer: ?e.NativeObserverToken = null,
        bounds: ui.Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        parameters: e.Parameters = .{},
        entered: usize = 0,
        retired: bool = false,
        withdrawn: bool = false,
        closing: bool = false,
        ready: bool = false,
        scope: ?*ui.TextFieldScope = null,

        pub fn create(allocator: std.mem.Allocator, document: *d.Document, engine: *t.Engine, options: Options) !*Self {
            // An aggregate parameter may borrow the caller's storage. Give
            // the constructor its own address before a foreign allocator can
            // reenter and change the original limits or callback authority.
            var captured = options;
            return createCaptured(allocator, document, engine, &captured);
        }
        noinline fn createCaptured(allocator: std.mem.Allocator, document: *d.Document, engine: *t.Engine, options: *Options) !*Self {
            if (options.value_bytes == 0 or options.value_bytes > 16384 or options.accept_tab and !options.multiline) return error.InvalidFieldLimits;
            const bytes = try std.math.mul(usize, options.value_bytes, 2);
            if (try std.math.add(usize, @sizeOf(Self), bytes) > options.storage_bytes) return error.FieldBudgetExceeded;
            if (try document.selectionCount() != 1) return error.MultipleSelections;
            var limits = options.adapter;
            limits.selections = 1;
            const adapter = try e.Adapter.create(allocator, document, engine, limits);
            errdefer adapter.close() catch unreachable;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const storage = try allocator.alloc(u8, bytes);
            errdefer allocator.free(storage);
            self.* = .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .document = document, .adapter = adapter, .options = options.*, .storage = storage, .value = storage[0..options.value_bytes], .scratch = storage[options.value_bytes..], .notified_text_version = try document.committedTextVersion() };
            try self.copyValue();
            try adapter.setPreInputHook(.{ .context = self, .call = preInput });
            self.observer = try adapter.observeNativeChanges(.{ .context = self, .call = nativeChanged, .validate = nativeAuthority });
            return self;
        }
        fn enter(self: *Self) !void {
            if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
            if (self.retired) return error.FieldClosed;
            self.entered = try std.math.add(usize, self.entered, 1);
        }
        fn leave(self: *Self) void {
            std.debug.assert(self.entered != 0);
            self.entered -= 1;
        }
        fn copyValue(self: *Self) !void {
            const size = try self.document.byteLength();
            if (size > self.value.len) return error.FieldValueTooLarge;
            const count = try self.document.read(.{ .start = 0, .end = size }, self.value);
            try validateText(self.value[0..count], self.options.multiline);
            self.value_len = count;
            self.value_revision = try self.document.version();
        }
        fn validateText(text: []const u8, multiline: bool) !void {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EmbeddedNul;
            if (!multiline and (std.mem.indexOfAny(u8, text, "\r\n") != null or std.mem.indexOf(u8, text, "\xe2\x80\xa8") != null or std.mem.indexOf(u8, text, "\xe2\x80\xa9") != null)) return error.SingleLineRequired;
        }
        pub fn prepare(self: *Self, bounds: ui.Rect, parameters: e.Parameters) !void {
            try self.enter();
            defer self.leave();
            if (parameters.font.word_ranges != self.options.words) return error.FieldWordPolicyMismatch;
            if (try self.document.selectionCount() != 1) return error.MultipleSelections;
            try self.copyValue();
            const revision = self.value_revision;
            var actual = parameters;
            if (!self.options.multiline) actual.font.wrap = .none;
            _ = try self.adapter.prepare(bounds, actual);
            if (self.retired or try self.document.version() != revision) return error.StaleRevision;
            self.bounds = bounds;
            // Reuse the Adapter's captured font bytes, never the caller's
            // transient family/locale slices after this method returns.
            self.parameters = try Private.parameters(self.adapter);
            self.ready = true;
        }
        /// Register cold, after prepare and before the first visual frame.
        /// Context.prepareTextFields is explicit and creates no raster planes.
        pub fn attach(self: *Self, context: *ui.Context, id: u64) !void {
            try self.enter();
            defer self.leave();
            if (self.token != null) return error.AlreadyAttached;
            if (!self.ready) return error.LayoutRequired;
            const window = context.window orelse return error.NotAttached;
            const pin = window.beginCallback() orelse return error.Closed;
            defer pin.end();
            if (self.options.words) try Private.preparePointer(self.adapter, window);
            if (self.retired or window.isClosed()) return error.Closed;
            const token = try context.registerTextField(id, .{ .context = self, .focus = focusCallback, .blur = blurCallback, .input = inputCallback, .action = actionCallback });
            self.token = token;
            self.window = window;
        }
        pub fn draw(self: *Self, frame: *ui.Frame, colors: e.Colors, name: []const u8) !void {
            return self.drawDescribed(frame, colors, name, .{});
        }
        /// `draw` with help or error text and form state for accessibility.
        pub fn drawDescribed(self: *Self, frame: *ui.Frame, colors: e.Colors, name: []const u8, about: Description) !void {
            try self.enter();
            defer self.leave();
            errdefer |err| frame.failure = frame.failure orelse err;
            if (!self.ready or try self.document.version() != self.value_revision) return error.LayoutRequired;
            const token = self.token orelse return error.NotAttached;
            try frame.textField(token, self.bounds, self.options.policy.enabled);
            try self.adapter.draw(frame, self.bounds, colors);
            const selected = try self.document.selection();
            try frame.semantic(.{ .id = token.key.id, .role = .text_box, .name = name, .value = self.value[0..self.value_len], .description = about.description, .invalid = about.invalid, .required = about.required, .bounds = self.bounds, .enabled = self.options.policy.enabled, .read_only = self.options.policy.read_only, .focused = frame.context.input_state.focused == token.key.id, .selection_start = selected.range().start, .selection_end = selected.range().end });
        }
        pub fn focus(self: *Self) !void {
            try self.enter();
            defer self.leave();
            try (self.token orelse return error.NotAttached).focus();
        }
        pub fn blur(self: *Self) !void {
            try self.enter();
            defer self.leave();
            if (self.token) |token| try token.blur();
        }
        pub fn setValue(self: *Self, bytes: []const u8) !ui.TextFieldResult {
            try self.enter();
            defer self.leave();
            return try (self.token orelse return error.NotAttached).perform(.{ .set_value = bytes });
        }
        pub fn select(self: *Self, start_utf16: usize, end_utf16: usize) !ui.TextFieldResult {
            try self.enter();
            defer self.leave();
            return try (self.token orelse return error.NotAttached).perform(.{ .select_text = .{ .start_utf16 = start_utf16, .end_utf16 = end_utf16 } });
        }
        pub fn undo(self: *Self) !ui.TextFieldResult {
            try self.enter();
            defer self.leave();
            return try (self.token orelse return error.NotAttached).perform(.undo);
        }
        pub fn redo(self: *Self) !ui.TextFieldResult {
            try self.enter();
            defer self.leave();
            return try (self.token orelse return error.NotAttached).perform(.redo);
        }
        pub fn scrollBy(self: *Self, delta: ui.layout.Point) !bool {
            try self.enter();
            defer self.leave();
            const changed = try self.adapter.scrollBy(delta);
            if (changed) {
                _ = try self.adapter.prepare(self.bounds, self.parameters);
                if (self.retired) return error.FieldClosed;
                try self.copyValue();
                if (try self.adapter.isBound()) {
                    try self.adapter.syncNativeCaret();
                    if (self.retired) return error.FieldClosed;
                }
                if (self.window) |window| window.invalidate();
            }
            return changed;
        }
        pub fn setPolicy(self: *Self, policy: Policy) !void {
            try self.enter();
            defer self.leave();
            if (std.meta.eql(self.options.policy, policy)) return;
            if (self.policy_generation == std.math.maxInt(u64)) return error.IdExhausted;
            self.policy_generation += 1;
            self.options.policy = policy;
            if (self.window) |window| {
                if (!policy.enabled) {
                    try self.adapter.unbind();
                    if (self.token) |token| if (token.context.input_state.focused == token.key.id) try token.context.blurControls();
                } else if (policy.read_only and try self.document.composition() != null) {
                    try window.cancelTextComposition();
                    _ = try self.adapter.handleEvent(window, .text_preedit_cancel, self.bounds, self.parameters);
                }
                window.invalidate();
            }
        }
        pub fn close(self: *Self) !void {
            if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
            if (self.closing) return error.ResourceInUse;
            self.closing = true;
            // Only a failed retirement returns a live shell for retry. On
            // success the last allocator callback still sees closing=true.
            errdefer self.closing = false;
            self.retired = true;
            if (!self.withdrawn) {
                if (self.token) |token| {
                    const available = token.close() catch |err| switch (err) {
                        error.StaleTextField => true,
                        else => return err,
                    };
                    self.withdrawn = true;
                    if (!available) return error.ResourceInUse;
                } else self.withdrawn = true;
            }
            if (self.entered != 0) return error.ResourceInUse;
            if (self.window != null) {
                try self.adapter.unbind();
                self.window = null;
            }
            if (self.observer) |observer| {
                _ = try self.adapter.clearNativeObserver(observer);
                self.observer = null;
            }
            try self.adapter.setPreInputHook(null);
            try self.adapter.close();
            const allocator = self.allocator;
            const storage = self.storage;
            allocator.free(storage);
            allocator.destroy(self);
        }
        fn validate(self: *Self) !void {
            if (self.retired) return error.FieldClosed;
            if (!self.options.policy.enabled) return error.Disabled;
            try (self.token orelse return error.NotAttached).validate();
            if (self.scope) |scope| try scope.validate();
        }
        fn nativeAuthority(ptr: *anyopaque, _: z.Window, _: *e.Adapter, _: ?ui.SpaceBinding) !?u64 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.validate();
            return self.policy_generation;
        }
        fn nativeChanged(ptr: *anyopaque, window: z.Window, _: *e.Adapter, change: e.NativeChange) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.enter();
            defer self.leave();
            self.notify(window);
            if (change.layout_error == null and !self.retired) try self.copyValue();
        }
        fn notify(self: *Self, window: z.Window) void {
            const version = self.document.committedTextVersion() catch return;
            if (version == self.notified_text_version) return;
            // Record before invoking foreign application code, including close.
            self.notified_text_version = version;
            if (self.options.changed) |callback| callback(self.options.context, window, version);
        }
        fn mutatingKey(key: z.KeyInput) bool {
            return switch (key.key) {
                .backspace, .delete, .enter, .tab => true,
                .x, .v, .z, .y => key.modifiers.control,
                else => false,
            };
        }
        fn preInput(ptr: *anyopaque, _: z.Window, _: *e.Adapter, input: e.PreInput) e.PreInputDecision {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.validate() catch return .consume;
            const text: ?[]const u8 = switch (input) {
                .text => |value| value.text,
                .preedit => |value| value.text,
                .native_change => |change| if (change == .replace) change.replace.text else null,
                else => null,
            };
            const mutation = if (input == .key) mutatingKey(input.key) else text != null;
            if (mutation and self.options.policy.read_only) return .consume;
            if (text) |bytes| validateText(bytes, self.options.multiline) catch return .consume;
            if (text) |bytes| {
                const size = self.document.byteLength() catch return .consume;
                const replaced: d.Range = if (input == .native_change and input.native_change == .replace) .{ .start = self.document.byteOffsetFromUtf16(input.native_change.replace.range.start) catch return .consume, .end = self.document.byteOffsetFromUtf16(input.native_change.replace.range.end) catch return .consume } else if (self.document.composition() catch return .consume) |composition| composition.range else (self.document.selection() catch return .consume).range();
                if (replaced.start > replaced.end or replaced.end > size) return .consume;
                const total = std.math.add(usize, size - (replaced.end - replaced.start), bytes.len) catch return .consume;
                if (total > self.value.len) return .consume;
            }
            return .pass;
        }
        fn focusCallback(ptr: *anyopaque, scope: *ui.TextFieldScope) !z.TextClientToken {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.enter();
            defer self.leave();
            const previous = self.scope;
            self.scope = scope;
            defer self.scope = previous;
            try self.validate();
            const window = scope.window();
            try self.adapter.bind(window);
            errdefer self.adapter.unbind() catch {};
            try scope.validate();
            try self.adapter.setCommittedSpace(try self.token.?.context.committedSpace(self.token.?.key.id));
            if (self.options.words) try Private.activatePointer(self.adapter, scope);
            try scope.validate();
            return window.textClientToken() orelse error.NotBound;
        }
        fn blurCallback(ptr: *anyopaque, _: z.Window) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Withdrawal may have retired the field while the slot remains pinned.
            self.entered += 1;
            defer self.leave();
            try self.adapter.unbind();
        }
        fn inputCallback(ptr: *anyopaque, scope: *ui.TextFieldScope, event: z.Event) !ui.TextFieldResult {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.enter();
            defer self.leave();
            const previous = self.scope;
            self.scope = scope;
            defer self.scope = previous;
            try self.validate();
            const window = scope.window();
            const text_before = try self.document.committedTextVersion();
            var result: ui.TextFieldResult = .{};
            // Compatibility input enters the same single policy/clipboard
            // route as typed keys; Adapter does not hook legacy keys twice.
            const actual: z.Event = if (event == .edit_key) .{ .key_input = .{
                .key = switch (event.edit_key.key) {
                    inline else => |key| @field(z.KeyCode, @tagName(key)),
                },
                .modifiers = .{ .control = event.edit_key.control, .shift = event.edit_key.shift },
            } } else event;
            switch (actual) {
                .key_input => |key| {
                    if (key.key == .tab and !key.modifiers.control and !key.modifiers.alt and !key.modifiers.super and !self.options.accept_tab) return .{};
                    if (key.key == .enter and !self.options.multiline) {
                        if (!key.repeat) if (self.options.submit) |callback| callback(self.options.context, window);
                        return .{ .handled = true };
                    }
                    if (key.modifiers.control and (key.key == .c or key.key == .x or key.key == .v)) return try self.clipboardKey(scope, key);
                },
                else => {},
            }
            const handled = self.adapter.handleEvent(window, actual, self.bounds, self.parameters);
            if (handled) |value| result.handled = value else |err| {
                result.handled = true;
                if (try self.document.committedTextVersion() != text_before) result.presentation_error = err else result.input_error = err;
            }
            result.text_committed = try self.document.committedTextVersion() != text_before;
            self.notify(window);
            if (!self.retired and result.presentation_error == null and result.input_error == null) self.copyValue() catch |err| {
                result.presentation_error = err;
            };
            return result;
        }
        fn commandGate(ptr: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.validate();
            if (self.options.policy.read_only) return error.ReadOnly;
        }
        fn replaceSelection(self: *Self, scope: *ui.TextFieldScope, bytes: []const u8) !ui.TextFieldResult {
            try commandGate(self);
            try validateText(bytes, self.options.multiline);
            if (bytes.len > self.value.len) return error.FieldValueTooLarge;
            const selected = (try self.document.selection()).range();
            if (try std.math.add(usize, (try self.document.byteLength()) - (selected.end - selected.start), bytes.len) > self.value.len) return error.FieldValueTooLarge;
            var native = try self.adapter.beginNativeInput(scope.window());
            defer native.end();
            var selections: [2]d.Selection = undefined;
            const outcome = try self.adapter.runCommand(.{ .replace_selections = bytes }, .{ .context = self, .validate = commandGate, .expected_revision = try self.document.version() }, &selections);
            var result: ui.TextFieldResult = .{ .handled = true, .text_committed = outcome.text_changed, .presentation_error = outcome.post_commit_error };
            if (outcome.changed and result.presentation_error == null) _ = self.adapter.prepare(self.bounds, self.parameters) catch |err| {
                result.presentation_error = err;
            };
            self.notify(scope.window());
            if (!self.retired and result.presentation_error == null) try self.copyValue();
            return result;
        }
        fn clipboardKey(self: *Self, scope: *ui.TextFieldScope, key: z.KeyInput) !ui.TextFieldResult {
            if (key.key != .c and self.options.policy.read_only) return .{ .handled = true };
            const clipboard = self.options.clipboard orelse return error.ClipboardUnavailable;
            const revision = try self.document.version();
            if (key.key == .v) {
                const count = try clipboard.read(clipboard.context, self.scratch);
                if (count > self.scratch.len) return error.InvalidClipboard;
                try self.validate();
                if (try self.document.version() != revision) return error.StaleRevision;
                const bytes = try normalizePaste(self.scratch[0..count], self.options.multiline);
                return self.replaceSelection(scope, bytes);
            }
            const selected = (try self.document.selection()).range();
            if (selected.start == selected.end) return .{ .handled = true };
            const count = try self.document.read(selected, self.scratch);
            try clipboard.write(clipboard.context, self.scratch[0..count]);
            try self.validate();
            if (try self.document.version() != revision) return error.StaleRevision;
            if (key.key == .x) return self.replaceSelection(scope, "");
            return .{ .handled = true };
        }
        fn normalizePaste(bytes: []u8, multiline: bool) ![]const u8 {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
            if (multiline) return bytes;
            var used: usize = 0;
            var at: usize = 0;
            while (at < bytes.len) {
                const length = try std.unicode.utf8ByteSequenceLength(bytes[at]);
                const scalar = try std.unicode.utf8Decode(bytes[at..][0..length]);
                if (scalar == '\r' or scalar == '\n' or scalar == 0x2028 or scalar == 0x2029) {
                    bytes[used] = ' ';
                    used += 1;
                    if (scalar == '\r' and at + 1 < bytes.len and bytes[at + 1] == '\n') at += 1;
                } else {
                    std.mem.copyForwards(u8, bytes[used..][0..length], bytes[at..][0..length]);
                    used += length;
                }
                at += length;
            }
            return bytes[0..used];
        }
        fn actionCallback(ptr: *anyopaque, scope: *ui.TextFieldScope, action: ui.TextFieldAction) !ui.TextFieldResult {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.enter();
            defer self.leave();
            const previous = self.scope;
            self.scope = scope;
            defer self.scope = previous;
            try self.validate();
            switch (action) {
                .undo, .redo => {
                    try commandGate(self);
                    var native = try self.adapter.beginNativeInput(scope.window());
                    defer native.end();
                    var selections: [2]d.Selection = undefined;
                    const outcome = try self.adapter.runCommand(if (action == .undo) .undo else .redo, .{ .context = self, .validate = commandGate, .expected_revision = try self.document.version() }, &selections);
                    var result: ui.TextFieldResult = .{ .handled = true, .text_committed = outcome.text_changed, .presentation_error = outcome.post_commit_error };
                    if (outcome.changed and result.presentation_error == null) _ = self.adapter.prepare(self.bounds, self.parameters) catch |err| {
                        result.presentation_error = err;
                    };
                    self.notify(scope.window());
                    if (!self.retired and result.presentation_error == null) try self.copyValue();
                    return result;
                },
                .select_text => |range| {
                    const token = scope.window().textClientToken() orelse return error.NotBound;
                    _ = try scope.window().changeTextClient(token, .{ .select = .{ .anchor = range.start_utf16, .caret = range.end_utf16 } });
                    try self.copyValue();
                    return .{ .handled = true };
                },
                .set_value => |bytes| {
                    try commandGate(self);
                    try validateText(bytes, self.options.multiline);
                    if (bytes.len > self.value.len) return error.FieldValueTooLarge;
                    var native = try self.adapter.beginNativeInput(scope.window());
                    defer native.end();
                    const revision = try self.document.version();
                    const replacement = [_]d.Replacement{.{ .range = .{ .start = 0, .end = try self.document.byteLength() }, .text = bytes }};
                    const selected = [_]d.Selection{.{ .anchor = bytes.len, .caret = bytes.len }};
                    _ = try self.adapter.replaceManyWithSelections(revision, &replacement, &selected, 0);
                    var result: ui.TextFieldResult = .{ .handled = true, .text_committed = true };
                    _ = self.adapter.prepare(self.bounds, self.parameters) catch |err| {
                        result.presentation_error = err;
                    };
                    self.notify(scope.window());
                    if (!self.retired and result.presentation_error == null) try self.copyValue();
                    return result;
                },
            }
        }
    };
}
