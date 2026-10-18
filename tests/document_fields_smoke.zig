const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const d = @import("ziggurat_document");
const t = @import("ziggurat_text_layout");
const editing = @import("ziggurat_document_editor");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("NO_STRICT", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("uiautomation.h");
}) else struct {};
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gtk_widget_grab_focus(*anyopaque) void;
extern fn gdk_window_focus(*anyopaque, u32) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
extern fn cairo_image_surface_create(c_int, c_int, c_int) ?*anyopaque;
extern fn cairo_create(*anyopaque) ?*anyopaque;
extern fn cairo_destroy(*anyopaque) void;
extern fn cairo_surface_destroy(*anyopaque) void;
extern fn zlg_resource_count() u32;
const Button = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*f64, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const Motion = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*f64, state: c_uint, is_hint: i16, device: ?*anyopaque, x_root: f64, y_root: f64 };
const source = "alpha beta!\r\nlast";
const bounds: editing.Rect = .{ .x = 8, .y = 8, .width = 180, .height = 100 };
const checkpoint_message = 0x8000 + 196;
const Case = enum { identity, words, drag, ime, policy, clipboard, failed_frame, preprocess, queued_native, close };
extern fn zua_test_before_enqueue(*anyopaque, *const fn (*anyopaque) callconv(.c) c_int, *anyopaque) i32;

const Native = struct {
    pub fn area(window: z.Window) !*anyopaque {
        return gtk_bin_get_child(window.nativeHandle() orelse return error.MissingWindow) orelse error.MissingArea;
    }
    pub fn button(window: z.Window, point: z.Point, phase: z.PointerPhase, tick: u32, shift: bool) !void {
        if (builtin.os.tag == .windows) {
            const scale = (try window.contentSize()).scale;
            const x: i16 = @intFromFloat(@round(point.x * scale));
            const y: i16 = @intFromFloat(@round(point.y * scale));
            const encoded: u32 = @as(u32, @as(u16, @bitCast(y))) << 16 | @as(u16, @bitCast(x));
            const flags: usize = (if (phase == .down) @as(usize, c.MK_LBUTTON) else 0) | (if (shift) @as(usize, c.MK_SHIFT) else 0);
            if (c.PostMessageW(window.nativeHandle(), if (phase == .down) c.WM_LBUTTONDOWN else c.WM_LBUTTONUP, flags, @intCast(encoded)) == 0) return error.PostPointerFailed;
        } else {
            const widget = g_object_ref(try area(window));
            defer g_object_unref(widget);
            const native_window = g_object_ref(gtk_widget_get_window(widget) orelse return error.MissingNativeWindow);
            defer g_object_unref(native_window);
            var event: Button = .{ .kind = if (phase == .down) 4 else 7, .window = native_window, .send_event = 1, .time = tick, .x = point.x, .y = point.y, .axes = null, .state = (if (phase == .up) @as(c_uint, 1 << 8) else 0) | @as(c_uint, @intFromBool(shift)), .button = 1, .device = null, .x_root = point.x, .y_root = point.y };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, if (phase == .down) "button-press-event" else "button-release-event", &event, &handled);
        }
    }
    pub fn move(window: z.Window, point: z.Point, tick: u32, held: bool) !void {
        if (builtin.os.tag == .windows) {
            const scale = (try window.contentSize()).scale;
            const x: i16 = @intFromFloat(@round(point.x * scale));
            const y: i16 = @intFromFloat(@round(point.y * scale));
            const encoded: u32 = @as(u32, @as(u16, @bitCast(y))) << 16 | @as(u16, @bitCast(x));
            if (c.PostMessageW(window.nativeHandle(), c.WM_MOUSEMOVE, if (held) c.MK_LBUTTON else 0, @intCast(encoded)) == 0) return error.PostPointerFailed;
        } else {
            const widget = g_object_ref(try area(window));
            defer g_object_unref(widget);
            const native_window = g_object_ref(gtk_widget_get_window(widget) orelse return error.MissingNativeWindow);
            defer g_object_unref(native_window);
            var event: Motion = .{ .kind = 3, .window = native_window, .send_event = 1, .time = tick, .x = point.x, .y = point.y, .axes = null, .state = if (held) 1 << 8 else 0, .is_hint = 0, .device = null, .x_root = point.x, .y_root = point.y };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "motion-notify-event", &event, &handled);
        }
    }
    fn paint(window: z.Window) !void {
        if (builtin.os.tag == .windows) {
            _ = c.InvalidateRect(window.nativeHandle(), null, 0);
            _ = c.SendMessageW(window.nativeHandle(), c.WM_PAINT, 0, 0);
        } else {
            const surface = cairo_image_surface_create(0, 240, 160) orelse return error.SurfaceFailed;
            defer cairo_surface_destroy(surface);
            const context = cairo_create(surface) orelse return error.ContextFailed;
            defer cairo_destroy(context);
            var handled: c_int = 0;
            g_signal_emit_by_name(try area(window), "draw", context, &handled);
        }
    }
    fn checkpoint(host: *Host) !void {
        if (builtin.os.tag == .windows) {
            if (c.PostMessageW(host.window.nativeHandle(), checkpoint_message, 0, 0) == 0) return error.PostCheckpointFailed;
        } else try host.app.post(.{ .context = host, .call = Host.next });
    }
};

extern fn zlg_test_commit(*anyopaque, [*:0]const u8) void;
const Host = struct {
    case: Case,
    app: *z.App = undefined,
    app_ready: bool = false,
    window: z.Window = undefined,
    context: ui.Context = undefined,
    fields: [2]*editing.Field,
    documents: [2]*d.Document,
    engine: *t.Engine,
    parameters: editing.Parameters,
    failure: ?anyerror = null,
    stage: usize = 0,
    draws: usize = 0,
    actions: usize = 0,
    changes: usize = 0,
    submits: usize = 0,
    a: z.Point = undefined,
    drag_start: z.Point = undefined,
    b: z.Point = .{ .x = 20, .y = 122 },
    clipboard: [128]u8 = undefined,
    clipboard_len: usize = 0,
    fail_draw: bool = false,
    omit_first: bool = false,
    preprocess_close: bool = false,
    close_error: ?anyerror = null,
    old_closed: bool = false,
    focus_requested: bool = false,
    focus_ready_posted: bool = false,
    expected_diagnostics: usize = 0,
    diagnostics: usize = 0,
    worker: ?std.Thread = null,
    mta_provider: ?*anyopaque = null,
    mta_error: ?anyerror = null,
    mta_hresult: i32 = -1,
    mta_old_serial: u64 = 0,
    replacement_document: ?*d.Document = null,
    fn fail(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        std.debug.print("Document Field {s} stage={d} draws={d}: {s}\n", .{ @tagName(self.case), self.stage, self.draws, @errorName(err) });
        if (self.app_ready) self.app.quit();
    }
    fn diagnostic(ptr: *anyopaque, diagnostic_value: z.diagnostics.Diagnostic) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.diagnostics += 1;
        if (self.diagnostics > self.expected_diagnostics) self.fail(diagnostic_value.err orelse error.UnexpectedDiagnostic);
    }
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.draws += 1;
        frame.rect(.{ .x = 0, .y = 0, .width = 240, .height = 160 }, 0xffffff);
        if (!self.omit_first and !self.old_closed) self.fields[0].draw(frame, .{}, "First field") catch |err| {
            self.fail(err);
            return;
        };
        self.fields[1].draw(frame, .{}, "Second field") catch |err| {
            self.fail(err);
            return;
        };
        frame.button(90, .{ .x = 200, .y = 110, .width = 35, .height = 25 }, "OK") catch |err| {
            self.fail(err);
            return;
        };
        if (self.fail_draw) frame.failure = error.FieldFixtureRejected;
    }
    fn action(ptr: *anyopaque, _: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.actions += 1;
    }
    fn changed(ptr: ?*anyopaque, _: z.Window, _: u64) void {
        const self: *Host = @ptrCast(@alignCast(ptr.?));
        self.changes += 1;
    }
    fn submit(ptr: ?*anyopaque, _: z.Window) void {
        const self: *Host = @ptrCast(@alignCast(ptr.?));
        self.submits += 1;
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (builtin.os.tag == .linux and self.focus_requested and !self.focus_ready_posted and event == .focus and event.focus) {
            const actual = self.window.state() catch |err| {
                self.fail(err);
                return true;
            };
            if (!actual.focused) return false;
            self.focus_ready_posted = true;
            self.app.post(.{ .context = self, .call = start }) catch |err| self.fail(err);
        }
        if (self.preprocess_close and event == .pointer_down) {
            self.preprocess_close = false;
            self.fields[0].close() catch |err| {
                self.close_error = err;
            };
        }
        return false;
    }
    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (bytes.len > self.clipboard.len) return error.Full;
        @memcpy(self.clipboard[0..bytes.len], bytes);
        self.clipboard_len = bytes.len;
    }
    fn read(ptr: *anyopaque, bytes: []u8) !usize {
        const self: *Host = @ptrCast(@alignCast(ptr));
        if (bytes.len < self.clipboard_len) return error.Full;
        @memcpy(bytes[0..self.clipboard_len], self.clipboard[0..self.clipboard_len]);
        return self.clipboard_len;
    }
    fn message(ptr: *anyopaque, _: z.Window, kind: u32, _: usize, _: isize) ?isize {
        if (kind != checkpoint_message) return null;
        next(ptr);
        return 0;
    }
    fn serviceDestroy(_: *anyopaque) void {}
    fn start(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.begin() catch |err| self.fail(err);
    }
    fn begin(self: *Host) !void {
        if (builtin.os.tag == .windows) {
            _ = c.SetFocus(self.window.nativeHandle());
            try std.testing.expect(c.GetFocus() == self.window.nativeHandle());
        } else if (!self.focus_requested) {
            // Child keyboard focus is insufficient for an invisible toplevel.
            // In this private X server, request real native focus and wait for
            // the translated focus event before issuing the first raw press.
            self.focus_requested = true;
            try self.window.perform(.show);
            gtk_widget_grab_focus(try Native.area(self.window));
            gdk_window_focus(gtk_widget_get_window(self.window.nativeHandle().?) orelse return error.MissingNativeWindow, 0);
            return;
        } else try std.testing.expect(self.focus_ready_posted and (try self.window.state()).focused);
        try Native.paint(self.window);
        if (self.failure) |err| return err;
        try std.testing.expect(self.draws != 0);
        const stats = try self.context.transformStats();
        try std.testing.expect(stats.metadata_bytes != 0 and stats.layers.current_bytes == 0 and !stats.layers.software.prepared);
        if (stats.layers.gpu) |gpu| try std.testing.expect(!gpu.prepared and gpu.pixel_bytes == 0);
        if (builtin.os.tag == .windows and ui.capabilities.accessibility) {
            try std.testing.expectEqual(@as(u32, 1), ui.accessibility.geometryResourceCount());
            std.debug.print("Document Field semantic geometry: metadata={d} native owners=1 pixel planes=0\n", .{stats.metadata_bytes});
        }
        if (self.case == .policy) try self.fields[0].setPolicy(.{ .read_only = true });
        if (self.case == .preprocess) self.preprocess_close = true;
        try self.pair(self.a);
        try Native.checkpoint(self);
    }
    fn pair(self: *Host, point: z.Point) !void {
        const tick: u32 = @intCast(20 * self.stage + 100);
        try Native.button(self.window, point, .down, tick, false);
        try Native.button(self.window, point, .up, tick + 1, false);
    }
    fn next(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.advance() catch |err| self.fail(err);
    }
    fn key(self: *Host, code: z.KeyCode, control: bool, shift: bool) !void {
        try std.testing.expect(self.context.handleKeyInput(self.window, .{ .key = code, .modifiers = .{ .control = control, .shift = shift } }));
    }
    fn value(self: *Host, index: usize, expected: []const u8) !void {
        var bytes: [128]u8 = undefined;
        const count = try self.documents[index].read(.{ .start = 0, .end = try self.documents[index].byteLength() }, &bytes);
        try std.testing.expectEqualStrings(expected, bytes[0..count]);
    }
    fn nativeSetValue(self: *Host, value_utf16: [*:0]const u16) !i32 {
        const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try self.context.accessibility_bridge.retainProvider(1)));
        defer _ = simple.lpVtbl.*.Release.?(simple);
        var provider: ?*c.IValueProvider = null;
        if (simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IValueProvider, @ptrCast(&provider)) < 0) return error.ValueProviderUnavailable;
        defer _ = provider.?.lpVtbl.*.Release.?(provider.?);
        return provider.?.lpVtbl.*.SetValue.?(provider.?, value_utf16);
    }
    fn queueReplacement(ptr: *anyopaque) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(ptr));
        // Native has already copied the old key. This explicit worker boundary
        // queues replacement before the old action, without accessing UI state.
        self.app.post(.{ .context = self, .call = replaceNativeField }) catch return 0;
        return 1;
    }
    fn replaceNativeField(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.replaceNativeFieldChecked() catch |err| self.fail(err);
    }
    fn replaceNativeFieldChecked(self: *Host) !void {
        try std.testing.expectEqual(self.mta_old_serial, self.fields[0].token.?.key.serial);
        self.old_closed = true;
        self.fields[0].close() catch |err| {
            self.old_closed = false;
            return err;
        };
        const document = try d.Document.create(self.app.allocator, std.Thread.getCurrentId(), "replacement", .{});
        self.replacement_document = document;
        const replacement = try editing.Field.create(self.app.allocator, document, self.engine, .{ .context = self, .changed = changed, .submit = submit, .clipboard = .{ .context = self, .read = read, .write = write } });
        var adopted = false;
        errdefer if (!adopted) replacement.close() catch {};
        try replacement.prepare(bounds, self.parameters);
        try replacement.attach(&self.context, 1);
        try std.testing.expect(replacement.token.?.key.serial > self.mta_old_serial);
        self.fields[0] = replacement;
        self.old_closed = false;
        adopted = true;
        try Native.paint(self.window);
        try replacement.token.?.validate();
        self.stage = 1;
    }
    fn mtaRequest(self: *Host) void {
        const provider: *c.IValueProvider = @ptrCast(@alignCast(self.mta_provider.?));
        const initialized = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        defer if (initialized >= 0) c.CoUninitialize();
        defer _ = provider.lpVtbl.*.Release.?(provider);
        if (initialized < 0) {
            self.mta_error = error.NativeMtaInitializationFailed;
        } else {
            self.mta_hresult = provider.lpVtbl.*.SetValue.?(provider, std.unicode.utf8ToUtf16LeStringLiteral("stale queued value"));
        }
        // The native action was queued before SetValue returned. FIFO puts this
        // check after replacement and after the native dispatch/drop cleanup.
        self.app.post(.{ .context = self, .call = verifyNativeRequest }) catch |err| std.debug.panic("MTA verification post failed: {s}", .{@errorName(err)});
    }
    fn startNativeRequest(self: *Host) !void {
        const simple: *c.IRawElementProviderSimple = @ptrCast(@alignCast(try self.context.accessibility_bridge.retainProvider(1)));
        defer _ = simple.lpVtbl.*.Release.?(simple);
        var provider: ?*c.IValueProvider = null;
        if (simple.lpVtbl.*.QueryInterface.?(simple, &c.IID_IValueProvider, @ptrCast(&provider)) < 0) return error.ValueProviderUnavailable;
        errdefer _ = provider.?.lpVtbl.*.Release.?(provider.?);
        self.mta_provider = provider;
        self.mta_old_serial = self.fields[0].token.?.key.serial;
        try std.testing.expectEqual(@as(i32, c.S_OK), zua_test_before_enqueue(self.context.accessibility_bridge.native.?, queueReplacement, self));
        self.worker = try std.Thread.spawn(.{}, mtaRequest, .{self});
    }
    fn verifyNativeRequest(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.verifyNativeRequestChecked() catch |err| self.fail(err);
    }
    fn verifyNativeRequestChecked(self: *Host) !void {
        if (self.failure) |err| return err;
        if (self.mta_error) |err| return err;
        try std.testing.expectEqual(@as(i32, c.S_OK), self.mta_hresult);
        try std.testing.expectEqual(@as(usize, 1), self.stage);
        try self.value(0, "alpha");
        var bytes: [64]u8 = undefined;
        const replacement = self.replacement_document.?;
        const length = try replacement.read(.{ .start = 0, .end = try replacement.byteLength() }, &bytes);
        try std.testing.expectEqualStrings("replacement", bytes[0..length]);
        try std.testing.expectEqual(@as(usize, 0), self.changes);
        try std.testing.expectEqual(@as(u32, 0), ui.accessibility.resourceCounts().actions);
        try std.testing.expect(self.context.input_state.focused == null);
        std.debug.print("Document Field MTA: captured old serial={d}; replacement serial={d}; queued old SetValue dropped; both documents unchanged\n", .{ self.mta_old_serial, self.fields[0].token.?.key.serial });
        self.app.quit();
    }
    fn advance(self: *Host) !void {
        if (self.failure) |err| return err;
        if (self.case != .preprocess and self.stage == 0) try std.testing.expectEqual(@as(?u64, 1), self.context.input_state.focused);
        switch (self.case) {
            .words => {
                const selected = try self.documents[0].selection();
                const expected: d.Selection = switch (self.stage) {
                    0, 3 => .{ .anchor = 2, .caret = 2 },
                    1 => .{ .anchor = 0, .caret = 5 },
                    2 => .{ .anchor = 0, .caret = 13 },
                    else => unreachable,
                };
                try std.testing.expectEqualDeep(expected, selected);
                if (self.stage < 3) {
                    self.stage += 1;
                    try self.pair(self.a);
                    try Native.checkpoint(self);
                    return;
                }
                try std.testing.expectEqual(@as(usize, 0), self.changes);
            },
            .drag => {
                if (self.stage == 0) {
                    self.stage = 1;
                    // Start away from the initial probe click, so this is a
                    // fresh caret drag rather than a double-click word drag.
                    const target: z.Point = .{ .x = self.drag_start.x + 30, .y = self.drag_start.y };
                    try Native.button(self.window, self.drag_start, .down, 200, false);
                    try Native.move(self.window, target, 201, true);
                    try Native.move(self.window, .{ .x = bounds.x, .y = self.a.y }, 202, true);
                    try Native.button(self.window, .{ .x = bounds.x, .y = self.a.y }, .up, 203, false);
                    try Native.checkpoint(self);
                    return;
                }
                const selected = try self.documents[0].selection();
                try std.testing.expectEqualDeep(d.Selection{ .anchor = 8, .caret = 0 }, selected);
            },
            .identity => {
                const before = try self.documents[0].committedTextVersion();
                const token = self.window.textClientToken().?;
                _ = try self.window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = "Z" } });
                try std.testing.expectEqual(before + 1, try self.documents[0].committedTextVersion());
                try std.testing.expectEqual(@as(usize, 1), self.changes);
                if (builtin.os.tag == .windows and ui.capabilities.accessibility) {
                    try std.testing.expectEqual(@as(i32, c.S_OK), try self.nativeSetValue(std.unicode.utf8ToUtf16LeStringLiteral("UIA value")));
                    try self.value(0, "UIA value");
                    try std.testing.expectEqual(before + 2, try self.documents[0].committedTextVersion());
                    try std.testing.expectEqual(@as(usize, 2), self.changes);
                    std.debug.print("Document Field native UIA: IValueProvider.SetValue changed Document once\n", .{});
                }
                try self.key(.tab, false, false);
                try std.testing.expectEqual(@as(?u64, 2), self.context.input_state.focused);
                try self.key(.tab, false, false);
                try std.testing.expectEqual(@as(?u64, 90), self.context.input_state.focused);
                try std.testing.expect(!try self.window.hasTextClient());
                try self.key(.space, false, false);
                try std.testing.expectEqual(@as(usize, 1), self.actions);
            },
            .ime => {
                self.window.app.windows.get(self.window.key).?.emit(.{ .text_preedit = .{ .text = "候補", .selection_start = 0, .selection_end = 0 } });
                try std.testing.expect(try self.documents[0].composition() != null);
                try std.testing.expectEqual(@as(usize, 0), self.changes);
                self.window.app.windows.get(self.window.key).?.emit(.text_preedit_cancel);
                try std.testing.expect(try self.documents[0].composition() == null);
                try self.key(.down, false, false);
                try self.key(.down, false, false);
                if (builtin.os.tag == .linux) zlg_test_commit(self.app.windows.get(self.window.key).?.native.native.?, "Z") else {
                    const token = self.window.textClientToken().?;
                    _ = try self.window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = 0, .end = 0 }, .text = "Z" } });
                }
                try std.testing.expectEqual(@as(usize, 1), self.changes);
                const native_token = self.window.textClientToken().?;
                var text: [128]u8 = undefined;
                const before = try self.window.readTextClient(native_token, &text);
                const space = try self.context.committedSpace(1);
                const caret_before = try space.windowBounds(try self.fields[0].adapter.caretRect(bounds, self.parameters.scale));
                try std.testing.expect(try self.fields[0].scrollBy(.{ .x = 1.375, .y = 20 }));
                const caret_after = try space.windowBounds(try self.fields[0].adapter.caretRect(bounds, self.parameters.scale));
                try std.testing.expectApproxEqAbs(@as(f32, 1.375), caret_before.x - caret_after.x, 0.015625);
                try std.testing.expectApproxEqAbs(@as(f32, 20), caret_before.y - caret_after.y, 0.015625);
                try Native.paint(self.window);
                const after = try self.window.readTextClient(native_token, &text);
                try std.testing.expectEqualDeep(before.selection, after.selection);
                try std.testing.expectEqual(before.revision, after.revision);
                std.debug.print("Document Field native scroll: actual changed; mapped caret delta=1.375,20; native snapshot stable\n", .{});
            },
            .policy => {
                const before = try self.documents[0].version();
                const token = self.window.textClientToken().?;
                try std.testing.expectEqual(z.text.ChangeResult.rejected, try self.window.changeTextClient(token, .{ .replace = .{ .range = .{ .start = 0, .end = 1 }, .text = "NO" } }));
                try self.key(.backspace, false, false);
                try std.testing.expectError(error.ReadOnly, self.fields[0].setValue("NO"));
                if (builtin.os.tag == .windows and ui.capabilities.accessibility) {
                    // Publish the immediate policy change before asking the
                    // real native provider to reject a write at its own gate.
                    try Native.paint(self.window);
                    try std.testing.expectEqual(@as(i32, @bitCast(c.UIA_E_INVALIDOPERATION)), try self.nativeSetValue(std.unicode.utf8ToUtf16LeStringLiteral("NO")));
                    try self.value(0, "alpha");
                    try std.testing.expectEqual(@as(usize, 0), self.changes);
                    std.debug.print("Document Field native UIA: readonly SetValue rejected without edit\n", .{});
                }
                try std.testing.expectEqual(before, try self.documents[0].version());
                try self.fields[0].setPolicy(.{ .enabled = false });
                try Native.paint(self.window);
                try std.testing.expectError(error.StaleTextField, self.fields[0].focus());
                try self.fields[1].focus();
                try std.testing.expectEqual(@as(?u64, 2), self.context.input_state.focused);
            },
            .clipboard => {
                try self.key(.a, true, false);
                try self.key(.c, true, false);
                try std.testing.expectEqualStrings("alpha", self.clipboard[0..self.clipboard_len]);
                try self.key(.tab, false, false);
                try self.key(.a, true, false);
                try write(self, "a\r\nb");
                try self.key(.v, true, false);
                try self.value(1, "a b");
                const undo = try self.fields[1].undo();
                try std.testing.expect(undo.text_committed);
                try self.value(1, "other");
                const redo = try self.fields[1].redo();
                try std.testing.expect(redo.text_committed);
                try self.value(1, "a b");
                try self.key(.enter, false, false);
                try std.testing.expectEqual(@as(usize, 1), self.submits);
                try std.testing.expectError(error.SingleLineRequired, self.fields[1].setValue("not\na field"));
            },
            .failed_frame => {
                const generation = self.context.space_generation;
                self.fail_draw = true;
                self.omit_first = true;
                self.expected_diagnostics = 1;
                try Native.paint(self.window);
                try std.testing.expectEqual(generation, self.context.space_generation);
                try self.fields[0].token.?.validate();
                self.fail_draw = false;
                self.omit_first = false;
                try Native.paint(self.window);
                try std.testing.expect(self.context.space_generation > generation);
                try self.fields[0].token.?.validate();
                try std.testing.expectEqual(@as(usize, 1), self.diagnostics);
            },
            .preprocess => {
                try std.testing.expect(self.close_error.? == error.ResourceInUse);
                try std.testing.expect(self.context.input_state.focused == null);
                try self.fields[0].close();
                self.old_closed = true;
                try self.fields[1].focus();
                try std.testing.expectEqual(@as(?u64, 2), self.context.input_state.focused);
            },
            .queued_native => {
                if (builtin.os.tag == .windows and ui.capabilities.accessibility) {
                    try self.startNativeRequest();
                    return;
                }
                std.debug.print("Document Field MTA: native UIA capability unavailable\n", .{});
            },
            .close => {},
        }
        if (self.failure) |err| return err;
        self.app.quit();
    }
};

fn scenario(allocator: std.mem.Allocator, case: Case) !void {
    const words = case == .words or case == .drag;
    const multiline = words or case == .ime;
    const initial = if (case == .ime) "alpha beta!\r\nline one\r\nline two\r\nline three\r\nline four\r\nline five\r\nline six\r\nlast" else if (multiline) source else "alpha";
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const first = try d.Document.create(allocator, std.Thread.getCurrentId(), initial, .{});
    defer first.close() catch unreachable;
    const second = try d.Document.create(allocator, std.Thread.getCurrentId(), "other", .{});
    defer second.close() catch unreachable;
    var host: Host = .{ .case = case, .fields = undefined, .documents = .{ first, second }, .engine = engine, .parameters = .{ .font = .{ .word_ranges = words, .size = 16 } } };
    defer if (host.replacement_document) |document| document.close() catch unreachable;
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &host, .emit = Host.diagnostic } });
    defer {
        host.app_ready = false;
        app.deinit();
    }
    host.app = app;
    host.app_ready = true;
    host.window = try app.createWindow(.{ .width = 240, .height = 160, .native_pointer_clicks = words });
    host.parameters.scale = (try host.window.contentSize()).scale;
    host.context = ui.Context.init(&host, Host.draw, Host.action);
    host.context.render_mode = .gdi;
    host.context.on_input = Host.input;
    try host.context.attach(host.window);
    if (builtin.os.tag == .windows) try host.window.setService(.{ .context = &host, .message = Host.message, .native_destroying = Host.serviceDestroy });
    if (builtin.os.tag == .windows and ui.capabilities.accessibility and case == .queued_native) {
        const required = try host.context.recipientMetadata(8);
        try std.testing.expect(required.native_bytes != 0 and required.registry_bytes != 0);
        try std.testing.expectEqual(required.registry_bytes + required.native_bytes, required.total_bytes);
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        try std.testing.expectEqual(@as(u32, 0), ui.accessibility.collectionsResourceCount());
        try std.testing.expectError(error.TextFieldBudgetExceeded, host.context.prepareTextFields(failing.allocator(), .{ .bytes = required.total_bytes - 1 }));
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expect(host.context.input_state.fields == null and host.context.transforms == null);
        try std.testing.expectEqual(@as(u32, 0), ui.accessibility.collectionsResourceCount());
        try std.testing.expectEqual(@as(u32, 0), ui.accessibility.geometryResourceCount());
        std.debug.print("Document Field recipient budget: registry={d} native={d} total={d}; insufficient budget alloc0/native0\n", .{ required.registry_bytes, required.native_bytes, required.total_bytes });
    }
    try host.context.prepareTextFields(allocator, .{});
    if (builtin.os.tag == .windows and ui.capabilities.accessibility and case == .queued_native) {
        const required = try host.context.recipientsStats();
        try host.context.clearTextFields();
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        try std.testing.expectError(error.TextFieldBudgetExceeded, host.context.prepareTextFields(failing.allocator(), .{ .bytes = required.total_bytes - 1 }));
        try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
        try std.testing.expectEqual(@as(u32, 1), ui.accessibility.collectionsResourceCount());
        try host.context.prepareTextFields(allocator, .{ .bytes = required.total_bytes });
        try std.testing.expectEqualDeep(required, try host.context.recipientsStats());
    }
    host.fields[0] = try editing.Field.create(allocator, first, engine, .{ .words = words, .multiline = multiline, .context = &host, .changed = Host.changed, .submit = Host.submit, .clipboard = .{ .context = &host, .read = Host.read, .write = Host.write } });
    defer if (!host.old_closed) host.fields[0].close() catch unreachable;
    host.fields[1] = try editing.Field.create(allocator, second, engine, .{ .context = &host, .changed = Host.changed, .submit = Host.submit, .clipboard = .{ .context = &host, .read = Host.read, .write = Host.write } });
    defer host.fields[1].close() catch unreachable;
    try host.fields[0].prepare(bounds, host.parameters);
    var parameters = host.parameters;
    parameters.font.word_ranges = false;
    try host.fields[1].prepare(.{ .x = 8, .y = 110, .width = 180, .height = 35 }, parameters);
    try host.fields[0].attach(&host.context, 1);
    try host.fields[1].attach(&host.context, 2);
    const layout = try engine.layout(initial, host.parameters.font);
    const caret = try layout.caret(.{ .byte_offset = 2 });
    host.a = .{ .x = bounds.x + caret.x, .y = bounds.y + caret.y + caret.height * 0.5 };
    const drag_caret = try layout.caret(.{ .byte_offset = if (case == .drag) 8 else 0 });
    host.drag_start = .{ .x = bounds.x + drag_caret.x, .y = bounds.y + drag_caret.y + drag_caret.height * 0.5 };
    try layout.close();
    defer if (host.worker) |worker| worker.join();
    try app.post(.{ .context = &host, .call = Host.start });
    try app.run();
    if (host.worker) |worker| {
        worker.join();
        host.worker = null;
        if (host.mta_error) |err| return err;
        if (builtin.os.tag == .windows and ui.capabilities.accessibility) {
            const counts = ui.accessibility.resourceCounts();
            try std.testing.expect(counts.states == 0 and counts.providers == 0 and counts.ranges == 0 and counts.actions == 0);
            try std.testing.expectEqual(@as(u32, 0), ui.accessibility.collectionsResourceCount());
        }
    }
    if (host.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
    std.debug.print("Document Field native {s}: draws={d} changes={d} diagnostics={d} records=0\n", .{ @tagName(case), host.draws, host.changes, host.diagnostics });
}

fn isolatedWindows() !void {
    var name: [80]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "Ziggurat.DocumentPointer.{d}", .{c.GetCurrentProcessId()});
    var wide: [80:0]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, label);
    wide[length] = 0;
    const desktop = c.CreateDesktopW(&wide, null, null, 0, c.DESKTOP_CREATEWINDOW | c.DESKTOP_CREATEMENU | c.DESKTOP_READOBJECTS | c.DESKTOP_WRITEOBJECTS, null) orelse return error.CreateDesktopFailed;
    defer std.debug.assert(c.CloseDesktop(desktop) != 0);
    var executable: [32768:0]u16 = undefined;
    const count = c.GetModuleFileNameW(null, &executable, executable.len);
    if (count == 0 or count >= executable.len) return error.ExecutablePathUnavailable;
    var command: [32768:0]u16 = undefined;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\" --desktop-child");
    if (count + 1 + suffix.len >= command.len) return error.CommandTooLong;
    command[0] = '"';
    @memcpy(command[1 .. count + 1], executable[0..count]);
    @memcpy(command[count + 1 .. count + 1 + suffix.len], suffix);
    command[count + 1 + suffix.len] = 0;
    var startup = std.mem.zeroes(c.STARTUPINFOW);
    startup.cb = @sizeOf(c.STARTUPINFOW);
    startup.lpDesktop = &wide;
    startup.dwFlags = c.STARTF_USESTDHANDLES;
    startup.hStdInput = c.GetStdHandle(c.STD_INPUT_HANDLE);
    startup.hStdOutput = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    startup.hStdError = c.GetStdHandle(c.STD_ERROR_HANDLE);
    var process: c.PROCESS_INFORMATION = undefined;
    if (c.CreateProcessW(&executable, &command, null, null, c.TRUE, c.CREATE_NO_WINDOW, null, null, &startup, &process) == 0) return error.CreateTestProcessFailed;
    defer _ = c.CloseHandle(process.hThread);
    defer _ = c.CloseHandle(process.hProcess);
    // Parent-process test deadline only. The child uses the real App queue;
    // it never blocks a UI callback or pumps a nested event loop.
    if (c.WaitForSingleObject(process.hProcess, 60000) != c.WAIT_OBJECT_0) {
        _ = c.TerminateProcess(process.hProcess, 1);
        _ = c.WaitForSingleObject(process.hProcess, c.INFINITE);
        return error.TestProcessTimeout;
    }
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.hProcess, &exit_code) == 0) return error.TestProcessStatusUnavailable;
    if (exit_code != 0) {
        std.debug.print("Document-pointer private-desktop child exit=0x{x}\n", .{exit_code});
        return error.TestProcessFailed;
    }
}
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();
    _ = args.next();
    var child = false;
    if (args.next()) |argument| {
        if (!std.mem.eql(u8, argument, "--desktop-child")) return error.InvalidArgument;
        child = true;
    }
    if (args.next() != null) return error.InvalidArgument;
    if (builtin.os.tag == .windows and !child) return isolatedWindows();
    const only = std.process.getEnvVarOwned(gpa.allocator(), "ZIGGURAT_FIELD_CASE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (only) |name| gpa.allocator().free(name);
    const selected = if (only) |name| std.meta.stringToEnum(Case, name) orelse return error.InvalidCase else null;
    const before = t.resourceCounts();
    const geometry_before = ui.accessibility.geometryResourceCount();
    for (std.meta.tags(Case)) |case| {
        if (selected != null and case != selected.?) continue;
        try scenario(gpa.allocator(), case);
        try std.testing.expectEqualDeep(before, t.resourceCounts());
        try std.testing.expectEqual(geometry_before, ui.accessibility.geometryResourceCount());
        if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    }
    if (builtin.os.tag == .windows) try std.testing.expectEqualDeep(ui.accessibility.ResourceCounts{ .states = 0, .providers = 0, .ranges = 0, .actions = 0 }, ui.accessibility.resourceCounts());
    try std.testing.expectEqual(@as(u32, 0), ui.accessibility.geometryResourceCount());
}
