const std = @import("std");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const catalog = @import("virtual_list_catalog.zig");
const native = ui.accessibility.virtual_lists;

/// One owning selection model plus a bounded optional UI adapter. The plain
/// List does not allocate this object or carry recipient/selection metadata.
pub fn Control(comptime Access: type) type {
    return struct {
        const Self = @This();
        const Model = Access.SelectionControl;
        pub const RowToken = Model.Token;
        pub const Selection = Model.Selection;
        pub const Navigation = Model.Navigation;
        pub const NavigationSelection = Model.NavigationSelection;
        pub const Cursor = Model.Cursor;
        pub const Catalog = catalog.Prepared;
        pub const NativeCatalog = native.Prepared;
        pub const CatalogLimits = catalog.Limits;
        pub const Label = struct { id: u64, text: []const u8 };
        pub const Change = struct {
            selection: bool = false,
            caret: bool = false,
            anchor: bool = false,
            scroll: bool = false,
            model: bool = false,
            pub fn any(self: Change) bool {
                return self.selection or self.caret or self.anchor or self.scroll or self.model;
            }
        };
        pub const Result = struct { change: Change, presentation_error: ?anyerror = null };
        pub const RowView = struct { row: Access.RowView, token: RowToken, selected: bool, caret: bool, anchor: bool };
        pub const Renderer = struct { context: *anyopaque, draw: *const fn (*anyopaque, *ui.Frame, RowView) anyerror!void };
        pub const Options = struct {
            model: Model.Options = .{},
            adapter_bytes: usize = 4096,
            enabled: bool = true,
            native_semantics: bool = false,
            edge_max_speed: f64 = 1200,
            context: ?*anyopaque = null,
            changed: ?*const fn (?*anyopaque, z.Window, *Self, Change) void = null,
            activated: ?*const fn (?*anyopaque, z.Window, *Self, RowToken) void = null,
            /// Start/stop an explicit host-owned wake. The host calls
            /// advanceDragScrolling from its deadline callback, never paint.
            edge_scroll: ?*const fn (?*anyopaque, z.Window, *Self, bool) void = null,
        };

        allocator: std.mem.Allocator,
        owner: std.Thread.Id,
        selection: *Model,
        options: Options,
        token: ?ui.ControlToken = null,
        window: ?z.Window = null,
        scroll: f64 = 0,
        native_model: u64 = 0,
        drag: ?Model.DragToken = null,
        press: ?z.PointerPress = null,
        pointer: z.Point = .{ .x = 0, .y = 0 },
        edge_velocity: f64 = 0,
        edge_notified: bool = false,
        entered: usize = 0,
        drawing: bool = false,
        snapshotting: bool = false,
        retired: bool = false,
        closing: bool = false,
        withdrawn: bool = false,

        /// Row descriptors and their storage stay immutable through return.
        /// Scalar options are captured before any caller allocator callback.
        pub fn create(allocator: std.mem.Allocator, process_main_thread: std.Thread.Id, rows: []const Access.Row, options: Options) !*Self {
            return createFrozen(allocator.ptr, allocator.vtable, process_main_thread, rows.ptr, rows.len, options.model.list.rows, options.model.list.owned_bytes, options.model.list.peak_bytes, options.model.bytes, options.model.peak_bytes, options.adapter_bytes, options.enabled, options.native_semantics, options.edge_max_speed, options.context, options.changed, options.activated, options.edge_scroll);
        }
        // Scalar parameters cross this boundary before the first caller
        // allocation. A by-value aggregate may still alias its caller storage.
        noinline fn createFrozen(allocator_ptr: *anyopaque, allocator_vtable: *const std.mem.Allocator.VTable, process_main_thread: std.Thread.Id, rows_ptr: [*]const Access.Row, row_count: usize, list_rows: usize, list_bytes: usize, list_peak: usize, model_bytes: usize, model_peak: usize, adapter_bytes: usize, enabled: bool, native_semantics: bool, edge_max_speed: f64, context: ?*anyopaque, changed: @TypeOf(@as(Options, undefined).changed), activated: @TypeOf(@as(Options, undefined).activated), edge_scroll: @TypeOf(@as(Options, undefined).edge_scroll)) !*Self {
            const allocator: std.mem.Allocator = .{ .ptr = allocator_ptr, .vtable = allocator_vtable };
            const rows = rows_ptr[0..row_count];
            const options: Options = .{ .model = .{ .list = .{ .rows = list_rows, .owned_bytes = list_bytes, .peak_bytes = list_peak }, .bytes = model_bytes, .peak_bytes = model_peak }, .adapter_bytes = adapter_bytes, .enabled = enabled, .native_semantics = native_semantics, .edge_max_speed = edge_max_speed, .context = context, .changed = changed, .activated = activated, .edge_scroll = edge_scroll };
            if (std.Thread.getCurrentId() != process_main_thread) return error.WrongThread;
            if (!std.math.isFinite(options.edge_max_speed) or options.edge_max_speed < 0 or options.edge_max_speed > 100_000 or options.adapter_bytes > 64 * 1024) return error.InvalidListControlLimits;
            if (@sizeOf(Self) > options.adapter_bytes) return error.ListControlBudgetExceeded;
            const selection = try Model.create(allocator, process_main_thread, rows, options.model);
            errdefer selection.close() catch unreachable;
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .owner = process_main_thread, .selection = selection, .options = options };
            return self;
        }
        const RegistryPointer = @typeInfo(@FieldType(@FieldType(ui.Context, "input_state"), "fields")).optional.child;
        const Registry = @typeInfo(RegistryPointer).pointer.child;
        const Borrow = @typeInfo(@typeInfo(@TypeOf(Registry.borrow)).@"fn".return_type.?).error_union.payload;
        const Operation = struct {
            control: *Self,
            pin: ?z.CallbackScope = null,
            borrow: ?Borrow = null,
            fn end(operation: *@This()) void {
                std.debug.assert(operation.control.entered != 0);
                operation.control.entered -= 1;
                // Final releases may run foreign allocator/window callbacks.
                // Do not access Control or Context after either release.
                if (operation.borrow) |*borrow| borrow.end();
                if (operation.pin) |pin| pin.end();
            }
        };
        fn enter(self: *Self) !Operation {
            if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
            if (self.retired) return error.ListControlClosed;
            var pin: ?z.CallbackScope = null;
            errdefer if (pin) |value| value.end();
            self.entered = try std.math.add(usize, self.entered, 1);
            errdefer self.entered -= 1;
            var borrow: ?Borrow = null;
            if (self.token) |token| {
                const window = self.window orelse return error.NotAttached;
                pin = window.beginCallback() orelse return error.Closed;
                const fields = token.context.input_state.fields orelse return error.StaleTextField;
                try fields.requireKind(token.key, .control);
                borrow = try fields.borrow(token.key);
            }
            return .{ .control = self, .pin = pin, .borrow = borrow };
        }
        fn mutation(self: *Self) !void {
            if (self.drawing or self.snapshotting) return error.Busy;
            if (self.token) |token| {
                try token.validateRegistration();
                if (token.context.painting) return error.Busy;
            }
        }
        pub fn attach(self: *Self, context: *ui.Context, id: u64) !void {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            if (self.token != null) return error.AlreadyAttached;
            const window = context.window orelse return error.NotAttached;
            if (window.app.owner != self.owner) return error.WrongThread;
            const pin = window.beginCallback() orelse return error.Closed;
            defer pin.end();
            if (self.options.native_semantics) _ = try context.virtualListStats();
            self.token = try context.registerControlRecipient(id, .{ .context = self, .focus = focusCallback, .blur = blurCallback, .input = inputCallback, .action = actionCallback });
            self.window = window;
        }
        /// Retire ingress first. ResourceInUse leaves a closed shell; retry
        /// after the entered callback/paint has returned. Context must outlive
        /// every token use, including this final retirement attempt.
        pub fn close(self: *Self) !void {
            if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
            if (self.closing) return error.ResourceInUse;
            self.closing = true;
            errdefer self.closing = false;
            self.retired = true;
            if (!self.withdrawn) {
                if (self.token) |token| {
                    const available = token.close() catch |err| switch (err) {
                        error.StaleTextField => true,
                        else => return err,
                    };
                    if (!available) return error.ResourceInUse;
                }
                self.withdrawn = true;
            }
            if (self.entered != 0) return error.ResourceInUse;
            if (self.edge_notified) {
                self.edge_notified = false;
                if (self.options.edge_scroll) |callback| if (self.window) |window| callback(self.options.context, window, self, false);
            }
            try self.selection.close();
            const allocator = self.allocator;
            allocator.destroy(self);
        }
        pub fn model(self: *Self) !*const Access.List {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.model();
        }
        pub fn rowToken(self: *Self, id: u64) !RowToken {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.token(id);
        }
        pub fn selected(self: *Self, id: u64) !bool {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.selected(id);
        }
        pub fn selectedCount(self: *Self) !usize {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.selectedCount();
        }
        pub fn caret(self: *Self) !?RowToken {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.caret();
        }
        pub fn cursor(self: *Self) !Cursor {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.cursor();
        }
        pub fn nextSelected(self: *Self, cursor_: *Cursor) !?RowToken {
            var operation = try self.enter();
            defer operation.end();
            return self.selection.nextSelected(cursor_);
        }
        fn convert(change: Model.Change) Change {
            return .{ .selection = change.selection, .caret = change.caret, .anchor = change.anchor };
        }
        fn nativeDelta(self: *Self, change: Change) !void {
            if (!self.options.native_semantics or !change.selection) return;
            if (self.retired or (if (self.window) |window| window.isClosed() else false)) return error.Closed;
            const token = self.token orelse return error.NotAttached;
            const patch = try self.selection.selectionPatch();
            if (self.native_model != patch.model) return error.CatalogRequired;
            try token.context.applyVirtualListSelection(token, patch.model, patch.delta);
        }
        fn finish(self: *Self, change: Change, scope: ?*ui.ControlScope) Result {
            var result: Result = .{ .change = change };
            if (self.retired or (if (self.window) |window| window.isClosed() else false)) {
                result.presentation_error = error.Closed;
                return result;
            }
            if (self.token) |token| token.validateRegistration() catch |err| {
                result.presentation_error = err;
                return result;
            };
            self.nativeDelta(change) catch |err| {
                result.presentation_error = err;
            };
            if (change.any()) if (self.window) |window| {
                window.invalidate();
                if (self.options.changed) |callback| callback(self.options.context, window, self, change);
                if (self.retired or window.isClosed()) result.presentation_error = result.presentation_error orelse error.ListControlClosed else if (scope) |entered| {
                    _ = self.checkScope(entered) catch |err| {
                        result.presentation_error = result.presentation_error orelse err;
                    };
                }
            };
            return result;
        }
        pub fn select(self: *Self, target: RowToken, mode: Selection) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            try self.cancelGesture(null);
            return self.finish(convert(try self.selection.select(target, mode)), null);
        }
        pub fn selectAll(self: *Self) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            try self.cancelGesture(null);
            return self.finish(convert(try self.selection.selectAll()), null);
        }
        pub fn clearSelection(self: *Self) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            try self.cancelGesture(null);
            return self.finish(convert(try self.selection.clear()), null);
        }
        pub fn scrollOffset(self: *Self, viewport: f64) !f64 {
            var operation = try self.enter();
            defer operation.end();
            return (try self.selection.model()).clampScroll(self.scroll, viewport);
        }
        pub fn setScroll(self: *Self, offset: f64, viewport: f64) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            const next = try (try self.selection.model()).clampScroll(offset, viewport);
            const changed = self.scroll != next;
            self.scroll = next;
            return self.finish(.{ .scroll = changed }, null);
        }
        fn invalidateCatalog(self: *Self) void {
            self.native_model = 0;
            self.drag = null;
            if (!self.retired and (if (self.window) |window| !window.isClosed() else false)) if (self.token) |token| token.context.withdrawVirtualList(token) catch {};
        }
        /// Rows stay immutable through return, including allocator callbacks.
        pub fn replace(self: *Self, rows: []const Access.Row, viewport: f64) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            try self.cancelGesture(null);
            const list = try self.selection.model();
            const anchor = try list.anchor(self.scroll, viewport);
            try self.selection.replace(rows);
            self.invalidateCatalog();
            const next = try list.resolve(anchor, viewport);
            const changed_scroll = next != self.scroll;
            self.scroll = next;
            return self.finish(.{ .model = true, .selection = true, .caret = true, .anchor = true, .scroll = changed_scroll }, null);
        }
        pub fn setHeight(self: *Self, id: u64, height: f32, viewport: f64) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            try self.cancelGesture(null);
            const list = try self.selection.model();
            const anchor = try list.anchor(self.scroll, viewport);
            const changed = try self.selection.setHeight(id, height);
            if (!changed) return .{ .change = .{} };
            self.invalidateCatalog();
            const next = try list.resolve(anchor, viewport);
            const changed_scroll = next != self.scroll;
            self.scroll = next;
            return self.finish(.{ .model = true, .scroll = changed_scroll }, null);
        }
        /// Snapshot exact stored heights and row incarnations directly into
        /// one owned immutable Catalog. Explicit labels match every row ID in
        /// order; no title, adjacent position or drawing callback supplies them.
        /// Label descriptors and text stay immutable through return, including
        /// caller allocator callbacks. Limits are captured before allocation.
        pub fn snapshotCatalog(self: *Self, allocator: std.mem.Allocator, labels: []const Label, limits: CatalogLimits) !*Catalog {
            return self.snapshotCatalogFrozen(allocator.ptr, allocator.vtable, labels.ptr, labels.len, limits.rows, limits.bytes, limits.text_bytes, limits.label_bytes);
        }
        noinline fn snapshotCatalogFrozen(self: *Self, allocator_ptr: *anyopaque, allocator_vtable: *const std.mem.Allocator.VTable, labels_ptr: [*]const Label, label_count: usize, max_rows_: usize, bytes: usize, text_bytes: usize, label_bytes: usize) !*Catalog {
            const allocator: std.mem.Allocator = .{ .ptr = allocator_ptr, .vtable = allocator_vtable };
            const labels = labels_ptr[0..label_count];
            const limits: CatalogLimits = .{ .rows = max_rows_, .bytes = bytes, .text_bytes = text_bytes, .label_bytes = label_bytes };
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            const token = self.token orelse return error.NotAttached;
            const list = try self.selection.model();
            if (labels.len != try list.count()) return error.CatalogRowsMismatch;
            const Source = struct {
                control: *Self,
                labels: []const Label,
                pub fn row(source: @This(), index: usize) !catalog.Row {
                    const row_token = try source.control.selection.tokenAt(index);
                    const label = source.labels[index];
                    if (label.id != row_token.id) return error.CatalogRowsMismatch;
                    return .{ .id = row_token.id, .incarnation = row_token.incarnation, .height_ticks = try Access.heightTicks(source.control.selection.list, index), .label = label.text };
                }
                pub fn sortedIdentity(source: @This(), index: usize) !catalog.Identity {
                    const value = try Access.identityAt(source.control.selection.list, index);
                    return .{ .id = value.id, .index = value.index };
                }
            };
            self.snapshotting = true;
            defer self.snapshotting = false;
            const stamp = try self.selection.stamp();
            const product = try Catalog.prepareFrom(allocator, .{ .owner = token.key.epoch, .generation = token.key.serial, .model = stamp.model }, labels.len, Source{ .control = self, .labels = labels }, limits);
            errdefer product.close();
            if (self.retired or self.window.?.isClosed()) return error.ListControlClosed;
            try token.validateRegistration();
            try self.selection.validateStamp(stamp);
            return product;
        }
        /// Success consumes the C-only native product. Failure preserves it
        /// and the old front. Selection is seeded from the current one model;
        /// preparing labels on a worker cannot rewind newer UI selections.
        pub fn installCatalog(self: *Self, product: *NativeCatalog) !void {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            if (!self.options.native_semantics) return error.NativeListSemanticsNotEnabled;
            const token = self.token orelse return error.NotAttached;
            const info = try product.info();
            const stamp = try self.selection.stamp();
            if (info.owner != token.key.epoch or info.generation != token.key.serial or info.model != stamp.model or info.rows != self.selection.incarnations.len) return error.StaleNativeCollection;
            try token.context.installVirtualListCatalog(token, product, self.selection.selection.revision, self.selection.selection.bits);
            self.native_model = stamp.model;
            if (self.window) |window| window.invalidate();
        }
        pub fn focus(self: *Self) !void {
            var operation = try self.enter();
            defer operation.end();
            try (self.token orelse return error.NotAttached).focus();
        }
        pub fn blur(self: *Self) !void {
            var operation = try self.enter();
            defer operation.end();
            if (self.token) |token| try token.blur();
        }
        const Painting = struct {
            control: *Self,
            renderer: Renderer,
            fn draw(ptr: *anyopaque, frame: *ui.Frame, row: Access.RowView) !void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const control = self.control;
                const token = try control.selection.tokenAt(row.index);
                try self.renderer.draw(self.renderer.context, frame, .{ .row = row, .token = token, .selected = try control.selection.selectedAt(row.index), .caret = std.meta.eql(try control.selection.caret(), @as(?RowToken, token)), .anchor = std.meta.eql(try control.selection.anchor(), @as(?RowToken, token)) });
                if (control.retired) return error.ListControlClosed;
            }
        };
        pub fn draw(self: *Self, frame: *ui.Frame, bounds: ui.Rect, name: []const u8, renderer: Renderer, options: Access.DrawOptions) !Access.Range {
            var operation = try self.enter();
            defer operation.end();
            return self.drawBody(frame, bounds, name, renderer, options) catch |err| {
                frame.failure = frame.failure orelse err;
                return err;
            };
        }
        fn drawBody(self: *Self, frame: *ui.Frame, bounds: ui.Rect, name: []const u8, renderer: Renderer, options: Access.DrawOptions) !Access.Range {
            if (self.drawing or self.snapshotting) return error.Busy;
            const token = self.token orelse return error.NotAttached;
            if (token.context != frame.context) return error.ForeignFrame;
            const stamp = try self.selection.stamp();
            const list = try self.selection.model();
            const offset = try list.clampScroll(self.scroll, bounds.height);
            const receipt: ui.ControlFrame = .{ .model = stamp.model, .scroll = offset };
            const caret_ = try self.selection.caret();
            if (self.options.native_semantics) {
                if (self.native_model != stamp.model) return error.CatalogRequired;
                try frame.virtualListRecipient(token, bounds, self.options.enabled, name, receipt, self.selection.selection.revision, if (caret_) |value| .{ .id = value.id, .incarnation = value.incarnation } else null);
            } else {
                try frame.controlRecipientStamped(token, bounds, self.options.enabled, receipt);
                try frame.semantic(.{ .id = token.key.id, .role = .group, .name = name, .bounds = bounds, .enabled = self.options.enabled, .focused = frame.context.input_state.focused == token.key.id });
            }
            self.drawing = true;
            defer self.drawing = false;
            var painting: Painting = .{ .control = self, .renderer = renderer };
            return @constCast(list).render(frame, bounds, offset, options, .{ .context = &painting, .draw = Painting.draw });
        }
        fn checkScope(self: *Self, scope: *ui.ControlScope) !ui.ControlFrame {
            if (!self.options.enabled) return error.Disabled;
            try (self.token orelse return error.NotAttached).validate();
            const receipt = try scope.controlFrame();
            if (receipt.model != (try self.selection.stamp()).model) return error.StaleControlEvent;
            return receipt;
        }
        fn scopeSpace(self: *Self, scope: *ui.ControlScope) !ui.SpaceToken {
            _ = try self.checkScope(scope);
            const token = self.token.?;
            const space = try token.context.committedSpace(token.key.id);
            try space.checkWindow(scope.window());
            return space;
        }
        fn rowAt(self: *Self, scroll: f64, bounds: anytype, y: f64, clamp: bool) !?RowToken {
            const list = try self.selection.model();
            const total = try list.totalHeight();
            if (total == 0 or bounds.height <= 0) return null;
            var at = scroll + (y - bounds.y);
            if (clamp) at = std.math.clamp(at, 0, std.math.nextAfter(f64, total, 0));
            if (!std.math.isFinite(at) or at < 0 or at >= total) return null;
            var index = (try list.anchor(at, 0)).old_index;
            if (clamp) {
                const visible = try list.visibleRange(scroll, bounds.height);
                if (visible.first == visible.end) return null;
                index = std.math.clamp(index, visible.first, visible.end - 1);
            }
            return try self.selection.tokenAt(index);
        }
        fn setEdge(self: *Self, velocity: f64) void {
            self.edge_velocity = velocity;
            const requested = velocity != 0 and self.options.edge_scroll != null;
            if (requested == self.edge_notified) return;
            self.edge_notified = requested;
            if (self.options.edge_scroll) |callback| if (self.window) |window| callback(self.options.context, window, self, requested);
        }
        fn stopDrag(self: *Self) void {
            if (self.drag) |drag| self.selection.cancelDrag(drag) catch {};
            self.drag = null;
            self.press = null;
            self.setEdge(0);
        }
        fn cancelGesture(self: *Self, scope: ?*ui.ControlScope) !void {
            self.stopDrag();
            if (self.retired) return error.ListControlClosed;
            try self.mutation();
            if (scope) |entered| _ = try self.checkScope(entered);
        }
        fn controlResult(value: Result, handled: bool) ui.ControlResult {
            return .{ .handled = handled, .changed = value.change.any(), .presentation_error = value.presentation_error };
        }
        fn focusCallback(ptr: *anyopaque, scope: *ui.ControlScope) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var operation = try self.enter();
            defer operation.end();
            if (!self.options.enabled) return error.Disabled;
            try scope.validate();
        }
        fn blurCallback(ptr: *anyopaque, _: z.Window) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (std.Thread.getCurrentId() != self.owner) return error.WrongThread;
            // Root invokes the copied blur callback while holding its old
            // registry borrow and Window pin, after membership is withdrawn.
            // This callback needs lifetime, never fresh input authority.
            self.entered = try std.math.add(usize, self.entered, 1);
            defer self.entered -= 1;
            self.stopDrag();
        }
        fn inputCallback(ptr: *anyopaque, scope: *ui.ControlScope, event: z.Event) !ui.ControlResult {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var operation = try self.enter();
            defer operation.end();
            if (event == .cancel_input or (event == .focus and !event.focus)) {
                // Lifecycle withdrawal does not operate a row. It must stop
                // a host wake even if the old model receipt is now stale.
                self.stopDrag();
                return .{ .handled = true };
            }
            try self.mutation();
            const receipt = try self.checkScope(scope);
            const space = try self.scopeSpace(scope);
            const bounds = try space.localBounds();
            switch (event) {
                .pointer_down => |pointer| {
                    try self.cancelGesture(scope);
                    const local = try space.localPoint(pointer.position);
                    const target = try self.rowAt(receipt.scroll, bounds, local.y, false) orelse return .{ .handled = true };
                    if (pointer.button == .secondary) return controlResult(self.finish(convert(try self.selection.contextSelect(target)), scope), true);
                    if (pointer.button != .primary) return .{};
                    if (pointer.modifiers.control and !pointer.modifiers.shift) return controlResult(self.finish(convert(try self.selection.select(target, .toggle)), scope), true);
                    const mode: Selection = if (pointer.modifiers.shift) (if (pointer.modifiers.control) .add_extend else .extend) else .replace;
                    const started = try self.selection.beginDrag(target, mode);
                    self.drag = started.token;
                    self.press = if (pointer.press.sequence != 0) pointer.press else null;
                    self.pointer = pointer.position;
                    return controlResult(self.finish(convert(started.change), scope), true);
                },
                .pointer_move => |position| {
                    const drag = self.drag orelse return .{};
                    self.pointer = position;
                    const local = try space.localPoint(position);
                    const target = try self.rowAt(receipt.scroll, bounds, local.y, true) orelse return .{ .handled = true };
                    const distance = if (local.y < bounds.y) @as(f64, local.y) - bounds.y else @max(@as(f64, 0), @as(f64, local.y) - (bounds.y + bounds.height));
                    self.setEdge(std.math.clamp(distance * 20, -self.options.edge_max_speed, self.options.edge_max_speed));
                    _ = try self.checkScope(scope);
                    const change = convert(try self.selection.updateDrag(drag, target));
                    return controlResult(self.finish(change, scope), true);
                },
                .pointer_up => |pointer| {
                    if (pointer.button != .primary) return .{};
                    self.stopDrag();
                    return .{ .handled = true };
                },
                .wheel => |wheel| {
                    if (!try space.contains(wheel.position)) return .{};
                    const list = try self.selection.model();
                    const current = try list.clampScroll(self.scroll, bounds.height);
                    const next = try list.clampScroll(current + @as(f64, wheel.delta.y), bounds.height);
                    const changed = next != current;
                    self.scroll = next;
                    return controlResult(self.finish(.{ .scroll = changed }, scope), changed);
                },
                .key_input => |key_value| return self.key(scope, key_value, bounds.height),
                else => return .{},
            }
        }
        fn key(self: *Self, scope: *ui.ControlScope, input: z.KeyInput, viewport: f64) !ui.ControlResult {
            if (input.modifiers.alt or input.modifiers.super) return .{};
            if (input.key != .tab) try self.cancelGesture(scope);
            if (input.key == .a and input.modifiers.control) return controlResult(self.finish(convert(try self.selection.selectAll()), scope), true);
            if (input.key == .space) {
                const target = try self.selection.caret() orelse return .{ .handled = true };
                return controlResult(self.finish(convert(try self.selection.select(target, if (input.modifiers.control) .toggle else .replace)), scope), true);
            }
            if (input.key == .enter) {
                if (try self.selection.caret()) |target| if (self.options.activated) |callback| {
                    callback(self.options.context, scope.window(), self, target);
                    try scope.validate();
                };
                return .{ .handled = true };
            }
            const direction: Navigation = switch (input.key) {
                .up => .previous,
                .down => .next,
                .home => .first,
                .end => .last,
                .page_up => .page_previous,
                .page_down => .page_next,
                else => return .{},
            };
            const mode: NavigationSelection = if (input.modifiers.shift) (if (input.modifiers.control) .add_extend else .extend) else if (input.modifiers.control) .caret_only else .replace;
            const move = try self.selection.navigate(direction, mode, self.scroll, viewport);
            var change = convert(move.change);
            change.scroll = move.scroll != self.scroll;
            self.scroll = move.scroll;
            self.drag = null;
            self.setEdge(0);
            try scope.validate();
            return controlResult(self.finish(change, scope), true);
        }
        fn actionCallback(ptr: *anyopaque, scope: *ui.ControlScope, action: ui.ControlAction) !ui.ControlResult {
            const self: *Self = @ptrCast(@alignCast(ptr));
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            if (!self.options.enabled) return error.Disabled;
            try scope.validate();
            if (action == .focus) return .{ .handled = true };
            try self.cancelGesture(scope);
            const target: RowToken = switch (action) {
                .focus => unreachable,
                .native_row => |request| blk: {
                    const token = self.token.?;
                    const captured = request.authority;
                    const receipt = try self.checkScope(scope);
                    if (captured.owner != token.key.epoch or captured.generation != token.key.serial or captured.model != receipt.model or captured.model != self.native_model or captured.publication != try scope.controlPublication()) return error.StaleNativeCollection;
                    break :blk .{ .id = captured.row, .incarnation = captured.incarnation };
                },
                inline else => |value| .{ .id = value.row, .incarnation = value.incarnation },
            };
            _ = try self.selection.resolve(target);
            const kind: native.authority.Kind = switch (action) {
                .native_row => |request| try request.action(),
                .select => .select,
                .add_selection => .add_selection,
                .remove_selection => .remove_selection,
                .focus_row => .focus,
                .reveal => .reveal,
                .focus => unreachable,
            };
            var change: Change = .{};
            switch (kind) {
                .select => change = convert(try self.selection.select(target, .replace)),
                .add_selection => if (!try self.selection.selected(target.id)) {
                    change = convert(try self.selection.select(target, .toggle));
                },
                .remove_selection => if (try self.selection.selected(target.id)) {
                    change = convert(try self.selection.select(target, .toggle));
                },
                .focus => {
                    // Move the existing caret without replacing selection.
                    const list = try self.selection.model();
                    const viewport = try (try self.scopeSpace(scope)).localBounds();
                    const next = try list.reveal(target.id, self.scroll, viewport.height, .nearest);
                    change = convert(try self.selection.focusRow(target));
                    change.scroll = self.scroll != next;
                    self.scroll = next;
                },
                .reveal => {
                    const viewport = try (try self.scopeSpace(scope)).localBounds();
                    const next = try (try self.selection.model()).reveal(target.id, self.scroll, viewport.height, .nearest);
                    change.scroll = self.scroll != next;
                    self.scroll = next;
                },
            }
            return controlResult(self.finish(change, scope), true);
        }
        /// Called by a host-owned explicit deadline while edge_scroll(true)
        /// is outstanding. No hidden timer, worker or idle redraw is created.
        pub fn advanceDragScrolling(self: *Self, seconds: f64) !Result {
            var operation = try self.enter();
            defer operation.end();
            try self.mutation();
            if (!std.math.isFinite(seconds) or seconds < 0 or seconds > 1) return error.InvalidScrollInterval;
            if (self.drag == null or self.edge_velocity == 0) return .{ .change = .{} };
            const token = self.token orelse return error.NotAttached;
            const window = self.window orelse return error.NotAttached;
            if (token.context.input_state.active != token.key.id or !self.options.enabled) {
                self.stopDrag();
                return .{ .change = .{} };
            }
            const press = self.press orelse {
                self.stopDrag();
                return .{ .change = .{} };
            };
            window.pointerPressHeld(press, .primary) catch {
                self.stopDrag();
                return .{ .change = .{} };
            };
            const fields = token.context.input_state.fields orelse return error.StaleTextField;
            const receipt = try fields.controlFrame(token.key);
            if (receipt.model != (try self.selection.stamp()).model) {
                self.stopDrag();
                return error.StaleControlEvent;
            }
            const space = try token.context.committedSpace(token.key.id);
            const bounds = try space.localBounds();
            const list = try self.selection.model();
            const current = try list.clampScroll(self.scroll, bounds.height);
            const next = try list.clampScroll(current + self.edge_velocity * seconds, bounds.height);
            if (next == current) {
                self.setEdge(0);
                return .{ .change = .{} };
            }
            self.scroll = next;
            const point = try space.localPoint(self.pointer);
            const target = try self.rowAt(next, bounds, point.y, true) orelse return self.finish(.{ .scroll = true }, null);
            var change = convert(try self.selection.updateDrag(self.drag.?, target));
            change.scroll = true;
            return self.finish(change, null);
        }
    };
}
