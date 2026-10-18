const std = @import("std");
const builtin = @import("builtin");
const z = @import("ziggurat");
const ui = @import("ziggurat_ui");
const t = @import("ziggurat_text_layout");
const d = @import("ziggurat_document");
const editing = @import("ziggurat_document_editor");
const diff = @import("ziggurat_document_diff");
const viewing = @import("ziggurat_document_diff_view");
const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NO_STRICT", "1");
    @cInclude("windows.h");
}) else struct {};
extern fn zlg_test_paint(*anyopaque, u32, u32) void;
extern fn zlg_resource_count() u32;
extern fn zlc_test_raw_pixel(*anyopaque, u32, u32) u32;
extern fn gtk_widget_get_scale_factor(*anyopaque) c_int;
extern fn gtk_bin_get_child(*anyopaque) ?*anyopaque;
extern fn gtk_widget_get_window(*anyopaque) ?*anyopaque;
extern fn gdk_event_new(c_int) ?*anyopaque;
extern fn gdk_event_free(*anyopaque) void;
extern fn g_object_ref(*anyopaque) *anyopaque;
extern fn g_signal_emit_by_name(*anyopaque, [*:0]const u8, ...) void;
const KeyEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, state: c_uint, keyval: c_uint, length: c_int, string: ?[*:0]u8, hardware_keycode: u16, group: u8, modifier_storage: c_uint };
const ButtonEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, axes: ?*anyopaque, state: c_uint, button: c_uint, device: ?*anyopaque, x_root: f64, y_root: f64 };
const ScrollEvent = extern struct { kind: c_int, window: ?*anyopaque, send_event: i8, time: u32, x: f64, y: f64, state: c_uint, direction: c_int, device: ?*anyopaque, x_root: f64, y_root: f64, delta_x: f64, delta_y: f64, stop_storage: c_uint };
const bounds: ui.Rect = .{ .x = 4, .y = 4, .width = 420, .height = 260 };
const original = "header\nleft 😀 a long wrapped original paragraph with two words\r\nremove one\nsame\nlast";
const modified = "header\nreplacement 文 a short paragraph\r\nadded two\nadded three\nsame\nlast";
const State = struct {
    window: z.Window = undefined,
    context: ui.Context = undefined,
    view: *viewing.View = undefined,
    inbox: *viewing.Inbox = undefined,
    viewport: ui.Rect = bounds,
    parameters: viewing.Parameters = .{ .font = .{ .size = 16, .wrap = .word_character, .width = 200 } },
    failure: ?anyerror = null,
    expected: ?anyerror = null,
    fail_frame: bool = false,
    close_frame: bool = false,
    paint_count: usize = 0,
    fn diagnostic(ptr: *anyopaque, value: z.diagnostics.Diagnostic) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        if (value.err) |actual| {
            if (self.expected) |wanted| {
                if (actual != wanted) self.failure = actual;
            } else self.failure = actual;
        } else if (self.expected != null) self.failure = error.UnexpectedDiagnostic;
    }
    fn action(_: *anyopaque, _: u64) void {}
    fn draw(ptr: *anyopaque, frame: *ui.Frame) void {
        const self: *State = @ptrCast(@alignCast(ptr));
        self.drawChecked(frame) catch |err| {
            self.failure = err;
        };
    }
    fn drawChecked(self: *State, frame: *ui.Frame) !void {
        frame.clear(0xffffff);
        try self.view.draw(frame, self.viewport, .{});
        self.paint_count += 1;
        try std.testing.expectError(error.ResourceInUse, self.view.close());
        try std.testing.expectError(error.ResourceInUse, self.view.prepare(self.viewport, self.parameters));
        if (self.fail_frame) frame.rect(.{ .x = 0, .y = 0, .width = -1, .height = 1 }, 0);
        if (self.close_frame) _ = try self.window.destroy();
    }
    fn input(ptr: *anyopaque, _: *ui.Context, event: z.Event) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        const used = self.view.handleEvent(event, self.viewport, self.parameters) catch |err| {
            self.failure = err;
            return true;
        };
        if (used and !self.window.isClosed()) {
            const borrow = self.inbox.borrow() catch |err| {
                self.failure = err;
                return true;
            };
            const valid = (borrow.display() catch null) != null;
            borrow.end();
            if (!valid) self.refresh() catch |err| {
                self.failure = err;
            };
        }
        return used;
    }
    fn refresh(self: *State) !void {
        const job = try self.inbox.begin();
        var result = diff.compare(std.heap.page_allocator, job.a, job.b, .{}) catch |err| {
            try job.release();
            _ = try self.inbox.finish(job.ticket);
            return err;
        };
        defer result.deinit();
        try job.release();
        defer _ = self.inbox.finish(job.ticket) catch unreachable;
        try self.inbox.publish(job.ticket, &result);
        try self.view.prepare(self.viewport, self.parameters);
    }
    fn nativeRecord(self: *State) *anyopaque {
        return self.window.app.windows.get(self.window.key).?.native.native.?;
    }
    fn paint(self: *State) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_PAINT, 0, 0) else zlg_test_paint(self.nativeRecord(), @intFromFloat(430 * self.parameters.scale), @intFromFloat(270 * self.parameters.scale));
        if (self.failure) |err| return err;
    }
    fn pixel(self: *State, x: f32, y: f32) !u32 {
        const xx: u32 = @intFromFloat(x * self.parameters.scale);
        const yy: u32 = @intFromFloat(y * self.parameters.scale);
        if (builtin.os.tag == .windows) {
            const color = c.GetPixel(self.context.renderer.dc, @intCast(xx), @intCast(yy));
            if (color == c.CLR_INVALID) return error.NoPixel;
            return ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255);
        }
        return zlc_test_raw_pixel(self.context.renderer.native.?, xx, yy);
    }
    fn key(self: *State, win: usize, gtk: u32) !void {
        if (builtin.os.tag == .windows) _ = c.SendMessageW(self.window.nativeHandle(), c.WM_KEYDOWN, win, 0) else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(8) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *KeyEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 8, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .state = 0, .keyval = gtk, .length = 0, .string = null, .hardware_keycode = 0, .group = 0, .modifier_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "key-press-event", native, &handled);
            try std.testing.expect(handled != 0);
        }
        if (self.failure) |err| return err;
    }
    fn click(self: *State, x: f32, y: f32) !void {
        if (builtin.os.tag == .windows) {
            const xx: u32 = @intFromFloat(x * self.parameters.scale);
            const yy: u32 = @intFromFloat(y * self.parameters.scale);
            const point: isize = @intCast(xx | (yy << 16));
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONDOWN, 0, point);
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_LBUTTONUP, 0, point);
        } else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(4) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *ButtonEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 4, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = x, .y = y, .axes = null, .state = 0, .button = 1, .device = null, .x_root = 0, .y_root = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "button-press-event", native, &handled);
            native.kind = 7;
            g_signal_emit_by_name(widget, "button-release-event", native, &handled);
        }
        if (self.failure) |err| return err;
    }
    fn wheel(self: *State) !void {
        if (builtin.os.tag == .windows) {
            var point: c.POINT = .{ .x = @intFromFloat(20 * self.parameters.scale), .y = @intFromFloat(80 * self.parameters.scale) };
            try std.testing.expect(c.ClientToScreen(self.window.nativeHandle(), &point) != 0);
            const delta: u16 = @bitCast(@as(i16, -120));
            const x: u16 = @bitCast(@as(i16, @intCast(point.x)));
            const y: u16 = @bitCast(@as(i16, @intCast(point.y)));
            _ = c.SendMessageW(self.window.nativeHandle(), c.WM_MOUSEWHEEL, @as(usize, delta) << 16, @intCast(@as(u32, x) | (@as(u32, y) << 16)));
        } else {
            const widget = gtk_bin_get_child(self.window.nativeHandle().?).?;
            const event = gdk_event_new(31) orelse return error.EventAllocationFailed;
            defer gdk_event_free(event);
            const native: *ScrollEvent = @ptrCast(@alignCast(event));
            native.* = .{ .kind = 31, .window = g_object_ref(gtk_widget_get_window(widget).?), .send_event = 1, .time = 0, .x = 20, .y = 80, .state = 0, .direction = 1, .device = null, .x_root = 0, .y_root = 0, .delta_x = 0, .delta_y = 0, .stop_storage = 0 };
            var handled: c_int = 0;
            g_signal_emit_by_name(widget, "scroll-event", native, &handled);
            try std.testing.expect(handled != 0);
        }
        if (self.failure) |err| return err;
    }
};
fn expectText(document: *d.Document, expected: []const u8) !void {
    var bytes: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(expected, bytes[0..try document.read(.{ .start = 0, .end = try document.byteLength() }, &bytes)]);
}
fn postedProbe(app: *z.App, inbox: *viewing.Inbox) !void {
    const Delivery = struct {
        app: *z.App,
        inbox: *viewing.Inbox,
        job: viewing.Job,
        result: ?diff.Result = null,
        details: ?viewing.intraline.Result = null,
        failure: ?anyerror = null,
        deliveries: usize = 0,
        fn run(self: *@This()) void {
            self.result = diff.compare(std.heap.page_allocator, self.job.a, self.job.b, .{}) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            if (self.result) |*result| self.details = viewing.intraline.compare(std.heap.page_allocator, self.job.a, self.job.b, result, .{ .cancellation = self.job.cancellation }) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.job.release() catch |err| {
                self.failure = err;
            };
            self.app.post(.{ .context = self, .call = receive }) catch |err| {
                self.failure = err;
            };
        }
        fn receive(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deliveries += 1;
            if (self.result) |*result| self.inbox.publishDetailed(self.job.ticket, result, if (self.details) |*details| details else null) catch |err| {
                self.failure = err;
            };
            _ = self.inbox.finish(self.job.ticket) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var delivery: Delivery = .{ .app = app, .inbox = inbox, .job = try inbox.begin() };
    // Test orchestration joins an explicitly created worker before dispatching
    // its accepted task; the Inbox itself starts no worker or blocking wait.
    const thread = try std.Thread.spawn(.{}, Delivery.run, .{&delivery});
    thread.join();
    defer if (delivery.result) |*result| result.deinit();
    defer if (delivery.details) |*details| details.deinit();
    if (delivery.failure) |err| {
        _ = try inbox.finish(delivery.job.ticket);
        return err;
    }
    try std.testing.expectEqual(@as(usize, 0), delivery.deliveries);
    try std.testing.expectError(error.JobsAlive, inbox.close());
    try app.dispatch();
    if (delivery.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), delivery.deliveries);
    try app.dispatch();
    try std.testing.expectEqual(@as(usize, 1), delivery.deliveries);
}
fn pairProbe(window: z.Window, a: *editing.Adapter, b: *editing.Adapter, scale: f32) !void {
    const rectangles: [2]ui.Rect = .{ .{ .x = 0, .y = 0, .width = 200, .height = 200 }, .{ .x = 220, .y = 0, .width = 200, .height = 200 } };
    var parameters: [2]editing.Parameters = @splat(.{ .font = .{ .size = 16, .wrap = .word_character }, .scale = scale });
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
    const before_a = try a.viewVersion();
    const before_b = try b.viewVersion();
    const resources = t.resourceCounts();
    parameters[0].font.size = 18;
    parameters[1].font.size = 18;
    var invalid = rectangles;
    invalid[1].width = -1;
    try std.testing.expectError(error.InvalidGeometry, editing.preparePair(window, a, b, invalid, parameters));
    try std.testing.expectEqual(before_a, try a.viewVersion());
    try std.testing.expectEqual(before_b, try b.viewVersion());
    try std.testing.expectEqual(resources, t.resourceCounts());
    try std.testing.expectError(error.SameAdapter, editing.preparePair(window, a, a, rectangles, parameters));
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
    try std.testing.expectEqual(before_a + 1, try a.viewVersion());
    try std.testing.expectEqual(before_b + 1, try b.viewVersion());
    const document = try a.sourceDocument();
    const line = try document.line(1);
    const ordinary = (try a.positionRect(try document.version(), line.start, .downstream)).?;
    const plan = try editing.ProjectionPlan.create(std.heap.page_allocator, document, &.{.{ .line = 1, .gap_before = 32, .minimum_height = 100 }}, .{});
    defer plan.close() catch unreachable;
    const other_plan = try editing.ProjectionPlan.create(std.heap.page_allocator, try b.sourceDocument(), &.{.{ .line = 1, .gap_before = 32, .minimum_height = 100 }}, .{});
    defer other_plan.close() catch unreachable;
    try a.setProjection(plan);
    try b.setProjection(other_plan);
    try std.testing.expectError(error.ClientsAlive, plan.close());
    _ = try a.prepare(rectangles[0], parameters[0]);
    const shifted = (try a.positionRect(try document.version(), line.start, .downstream)).?;
    try std.testing.expectApproxEqAbs(ordinary.y + 32, shifted.y, 0.001);
    const hit = try a.hitTest(rectangles[0], .{ .x = shifted.x, .y = shifted.y + shifted.height * 0.5 });
    try std.testing.expectEqual(line.start, hit.byte_offset);
    var marks: [128]t.Rect = undefined;
    const marked = try a.rangeRects(try document.version(), line, &marks);
    try std.testing.expect(marked.len != 0 and marked[0].y >= shifted.y);
    _ = try a.setSelection(.{ .anchor = line.start, .caret = line.start }, .downstream);
    _ = try a.prepare(rectangles[0], parameters[0]);
    try a.bind(window);
    const before_ime = try a.caretRect(rectangles[0], scale);
    try std.testing.expect(try a.handleEvent(window, .{ .text_preedit = .{ .text = "候\n选", .selection_start = 0, .selection_end = 0 } }, rectangles[0], parameters[0]));
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
    try std.testing.expect(!(try a.status()).projection_active and !(try b.status()).projection_active);
    const composing = try a.caretRect(rectangles[0], scale);
    try std.testing.expect(composing.y < before_ime.y);
    try std.testing.expect(try a.handleEvent(window, .text_preedit_cancel, rectangles[0], parameters[0]));
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
    try std.testing.expect((try a.status()).projection_active and (try b.status()).projection_active);
    const restored = try a.caretRect(rectangles[0], scale);
    try std.testing.expectApproxEqAbs(before_ime.y, restored.y, 0.001);
    try a.unbind();
    try a.setProjection(null);
    try b.setProjection(null);
    _ = try a.prepare(rectangles[0], parameters[0]);
    _ = try b.prepare(rectangles[1], parameters[1]);
    const Planner = struct {
        adapters: [2]*editing.Adapter,
        plans: [2]?*editing.ProjectionPlan = @splat(null),
        count: usize = 0,
        gap: f64 = 32,
        tiny_edge: bool = false,
        fn close(self: *@This()) void {
            for (&self.plans) |*value| if (value.*) |item| {
                item.close() catch unreachable;
                value.* = null;
            };
        }
        fn build(ptr: *anyopaque, probes: [2]*editing.LayoutProbe) !editing.PairProjection {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            try std.testing.expectError(error.Busy, self.adapters[0].status());
            try std.testing.expectError(error.Busy, self.adapters[1].sourceDocument());
            const left = try probes[0].paragraph(1);
            const right = try probes[1].paragraph(1);
            const maximum = @max(left.height, right.height);
            for (probes, 0..) |probe, side| self.plans[side] = try editing.ProjectionPlan.create(std.heap.page_allocator, try probe.sourceDocument(), &.{.{ .line = 1, .gap_before = self.gap, .minimum_height = maximum }}, .{});
            self.count += 1;
            const first = try probes[0].paragraph(0);
            const offset: u128 = if (self.tiny_edge) @as(u128, @intFromFloat(first.height * 4294967296)) + (@as(u128, 1000000000000) << 32) - 1 else 0;
            return .{ .plans = self.plans, .scroll_ticks = offset };
        }
    };
    var planner: Planner = .{ .adapters = .{ a, b } };
    defer planner.close();
    const projected = try editing.projectPair(window, a, b, rectangles, parameters, .{ .context = &planner, .build = Planner.build });
    try std.testing.expect(!projected.projection_suspended and planner.count == 1);
    const line_a = try document.line(2);
    const doc_b = try b.sourceDocument();
    const line_b = try doc_b.line(2);
    const next_a = (try a.positionRect(try document.version(), line_a.start, .downstream)).?;
    const next_b = (try b.positionRect(try doc_b.version(), line_b.start, .downstream)).?;
    try std.testing.expectApproxEqAbs(next_a.y, next_b.y, 0.001);
    try a.setProjection(null);
    try b.setProjection(null);
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
    planner.close();
    planner.gap = 1e12;
    planner.tiny_edge = true;
    _ = try editing.projectPair(window, a, b, rectangles, parameters, .{ .context = &planner, .build = Planner.build });
    const tiny = (try a.positionRect(try document.version(), line.start, .downstream)).?;
    try std.testing.expectEqual(@as(f32, 1.0 / 4294967296.0), tiny.y);
    try a.setProjection(null);
    try b.setProjection(null);
    _ = try editing.preparePair(window, a, b, rectangles, parameters);
}
fn pairCloseProbe(allocator: std.mem.Allocator, engine: *t.Engine, a: *d.Document, b: *d.Document) !void {
    const Witness = struct { closed: usize = 0, planner_ended: bool = false, failure: ?anyerror = null };
    const Context = struct {
        allocator: std.mem.Allocator,
        witness: *Witness,
        window: z.Window,
        a: *editing.Adapter,
        b: *editing.Adapter,
        fn closed(ptr: *anyopaque, _: z.Window) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (!self.witness.planner_ended) self.witness.failure = error.EarlyClose;
            self.a.close() catch |err| {
                self.witness.failure = err;
            };
            self.b.close() catch |err| {
                self.witness.failure = err;
            };
            self.witness.closed += 1;
            const source = self.allocator;
            source.destroy(self);
        }
        fn build(ptr: *anyopaque, probes: [2]*editing.LayoutProbe) !editing.PairProjection {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = try probes[0].paragraph(0);
            _ = try probes[1].paragraph(0);
            _ = try self.window.destroy();
            try std.testing.expectEqual(@as(usize, 0), self.witness.closed);
            try std.testing.expectError(error.Busy, self.a.close());
            try std.testing.expectError(error.Busy, self.b.close());
            self.witness.planner_ended = true;
            return error.TestPlannerClose;
        }
    };
    var witness: Witness = .{};
    const context = try allocator.create(Context);
    context.* = .{ .allocator = allocator, .witness = &witness, .window = undefined, .a = try editing.Adapter.create(allocator, a, engine, .{}), .b = try editing.Adapter.create(allocator, b, engine, .{}) };
    const app = try z.App.init(allocator);
    defer app.deinit();
    context.window = try app.createWindow(.{ .on_closed = .{ .context = context, .notify = Context.closed } });
    const rectangles: [2]ui.Rect = @splat(.{ .x = 0, .y = 0, .width = 200, .height = 200 });
    try std.testing.expectError(error.TestPlannerClose, editing.projectPair(context.window, context.a, context.b, rectangles, @splat(.{}), .{ .context = context, .build = Context.build }));
    try app.dispatch();
    if (witness.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), witness.closed);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
fn run(allocator: std.mem.Allocator) !void {
    const a = try d.Document.create(allocator, std.Thread.getCurrentId(), original, .{});
    defer a.close() catch unreachable;
    const b = try d.Document.create(allocator, std.Thread.getCurrentId(), modified, .{});
    defer b.close() catch unreachable;
    const engine = try t.Engine.create(allocator, std.Thread.getCurrentId(), .{});
    defer engine.close() catch unreachable;
    const adapter_a = try editing.Adapter.create(allocator, a, engine, .{});
    defer adapter_a.close() catch unreachable;
    const adapter_b = try editing.Adapter.create(allocator, b, engine, .{});
    defer adapter_b.close() catch unreachable;
    try pairCloseProbe(allocator, engine, a, b);
    const inbox = try viewing.Inbox.create(allocator, .{ .a = a, .b = b }, .{});
    defer inbox.close() catch unreachable;
    var state: State = .{ .inbox = inbox };
    const app = try z.App.initWithOptions(allocator, .{ .diagnostics_sink = .{ .context = &state, .emit = State.diagnostic } });
    defer app.deinit();
    state.window = try app.createWindow(.{ .width = 430, .height = 270 });
    defer _ = state.window.destroy() catch unreachable;
    try postedProbe(app, inbox);
    state.parameters.scale = if (builtin.os.tag == .windows) @as(f32, @floatFromInt(c.GetDpiForWindow(state.window.nativeHandle()))) / 96 else @floatFromInt(gtk_widget_get_scale_factor(state.window.nativeHandle().?));
    try pairProbe(state.window, adapter_a, adapter_b, state.parameters.scale);
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    state.view = try viewing.View.create(failing.allocator(), inbox, adapter_a, adapter_b, engine, state.window, .{});
    defer state.view.close() catch unreachable;
    try std.testing.expectError(error.ClientsAlive, adapter_a.close());
    try std.testing.expectError(error.ClientsAlive, inbox.close());
    try state.refresh();
    state.context = ui.Context.init(&state, State.draw, State.action);
    state.context.on_input = State.input;
    state.context.render_mode = .gdi;
    try state.context.attach(state.window);
    try state.paint();
    const initial_headers = try state.view.stats();
    try std.testing.expectEqual(@as(u64, 3), initial_headers.header_layouts);
    try std.testing.expectEqual(@as(u64, 3), initial_headers.header_prepared);
    state.viewport.x += 1;
    try state.view.prepare(state.viewport, state.parameters);
    try state.paint();
    const moved_headers = try state.view.stats();
    try std.testing.expectEqual(initial_headers.header_layouts, moved_headers.header_layouts);
    try std.testing.expectEqual(initial_headers.header_prepared, moved_headers.header_prepared);
    try std.testing.expectEqual(initial_headers.header_reuses + 3, moved_headers.header_reuses);
    state.viewport = bounds;
    try state.view.prepare(bounds, state.parameters);
    var rows: [96]viewing.RowInfo = undefined;
    var blank = false;
    var changed = false;
    var colored = false;
    var glyph_pixels: usize = 0;
    for (try state.view.rowInfo(&rows)) |row| {
        if (row.a_content) |left| if (row.b_content) |right| try std.testing.expectEqual(left.y, right.y);
        if (row.hunk != null) {
            changed = true;
            if (row.a == null or row.b == null) blank = true;
            const bottom = @min(row.bounds.y + row.bounds.height, bounds.y + bounds.height);
            if (row.bounds.y >= bounds.y + 30 and bottom > row.bounds.y + 2) {
                const y = row.bounds.y + 1;
                const color_a: u32 = if (row.a != null) 0xffe9e9 else 0xeeeeee;
                const color_b: u32 = if (row.b != null) 0xe5f6e9 else 0xeeeeee;
                try std.testing.expectEqual(color_a, try state.pixel(bounds.x + (bounds.width - 8) / 2 - 2, y));
                try std.testing.expectEqual(color_b, try state.pixel(bounds.x + bounds.width - 2, y));
                colored = true;
            }
        }
        if (row.a_content) |content| {
            const end_y: usize = @intFromFloat(@min(content.y + content.height, bounds.y + bounds.height));
            const begin_y: usize = @intFromFloat(@max(content.y, bounds.y + 30));
            for (begin_y..@max(begin_y, end_y)) |y| for (10..90) |x| {
                const pixel = try state.pixel(@floatFromInt(x), @floatFromInt(y));
                if ((pixel & 255) < 128 and ((pixel >> 8) & 255) < 128 and ((pixel >> 16) & 255) < 128) glyph_pixels += 1;
            };
        }
    }
    try std.testing.expect(blank and changed and colored and glyph_pixels > 10);
    const info = try state.view.info();
    try std.testing.expect(info.rows > 2 and info.selected_hunk != null);
    try std.testing.expectEqual(@as(u32, 0xe1e6ef), try state.pixel(bounds.x + 2, bounds.y + 1));
    try std.testing.expect(try a.setSelection(.{ .anchor = 1, .caret = 1 }));
    try std.testing.expectError(error.LayoutRequired, state.view.info());
    failing.fail_index = failing.alloc_index;
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    failing.fail_index = std.math.maxInt(usize);
    const wide_height = rows[1].bounds.height;
    state.viewport.width = 220;
    try state.view.prepare(state.viewport, state.parameters);
    try state.paint();
    const narrow_rows = try state.view.rowInfo(&rows);
    try std.testing.expect(narrow_rows[1].bounds.height > wide_height);
    for (narrow_rows) |row| if (row.a_content) |left| if (row.b_content) |right| try std.testing.expectEqual(left.y, right.y);
    state.viewport = bounds;
    state.parameters.estimated_height = 24;
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    try state.key(0x76, 0xffc4); // F7 navigates a real changed region.
    try state.view.prepare(bounds, state.parameters);
    const button = (try state.view.info()).revert_button;
    try state.click(button.x + 8, button.y + 8);
    try expectText(b, original);
    try std.testing.expect((try state.view.info()).selected_hunk == null);
    _ = try adapter_b.undo();
    try expectText(b, modified);
    try state.refresh();
    try b.setComposition("候选", .{ .anchor = 0, .caret = 0 });
    try std.testing.expectError(error.CompositionActive, state.view.revert(0, .a_to_b));
    _ = try b.cancelComposition();
    try state.view.prepare(bounds, state.parameters);
    _ = try state.view.scrollBy(20);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.view.prepare(bounds, state.parameters));
    failing.fail_index = std.math.maxInt(usize);
    try state.view.prepare(bounds, state.parameters);
    const empty_cases = [_]struct { a: []const u8, b: []const u8 }{ .{ .a = "", .b = "" }, .{ .a = "", .b = "\n" }, .{ .a = "\n", .b = "" }, .{ .a = "x\n", .b = "x\n" }, .{ .a = "\r\n", .b = "\n" } };
    for (empty_cases) |pair| {
        _ = try a.replace(.{ .start = 0, .end = try a.byteLength() }, pair.a);
        _ = try b.replace(.{ .start = 0, .end = try b.byteLength() }, pair.b);
        try adapter_a.reindex();
        try adapter_b.reindex();
        try state.refresh();
        try state.paint();
        if (pair.a.len == 0 and pair.b.len == 0) try std.testing.expectEqual(@as(usize, 0), (try state.view.info()).total_rows);
        if (!std.mem.eql(u8, pair.a, pair.b)) {
            _ = try state.view.revert(0, .a_to_b);
            try expectText(b, pair.a);
            try state.refresh();
            try state.paint();
        }
    }
    _ = try a.replace(.{ .start = 0, .end = try a.byteLength() }, "");
    _ = try b.replace(.{ .start = 0, .end = try b.byteLength() }, "");
    try state.refresh();
    var partial_header_failure = false;
    for (0..7) |failure_at| {
        const before_failure = try state.view.stats();
        const resource_counts = t.resourceCounts();
        state.parameters.version += 1;
        failing.fail_index = failing.alloc_index + failure_at;
        state.view.prepare(bounds, state.parameters) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const after_failure = try state.view.stats();
            try std.testing.expectEqual(before_failure.reserved_bytes, after_failure.reserved_bytes);
            try std.testing.expectEqual(resource_counts, t.resourceCounts());
            partial_header_failure = partial_header_failure or after_failure.header_layouts > before_failure.header_layouts;
        };
        failing.fail_index = std.math.maxInt(usize);
        try state.view.prepare(bounds, state.parameters);
        try state.paint();
    }
    try std.testing.expect(partial_header_failure);
    const real_scale = state.parameters.scale;
    const scale_headers = try state.view.stats();
    state.parameters.scale = real_scale * 1.5;
    try state.view.prepare(bounds, state.parameters);
    try std.testing.expectEqual(scale_headers.header_layouts + 3, (try state.view.stats()).header_layouts);
    state.parameters.scale = real_scale;
    try state.view.prepare(bounds, state.parameters);
    state.parameters.font.size = 40;
    state.viewport.height = 40;
    try state.view.prepare(state.viewport, state.parameters);
    const short_headers = try state.view.stats();
    state.viewport.height = 80;
    try state.view.prepare(state.viewport, state.parameters);
    try std.testing.expectEqual(short_headers.header_layouts + 3, (try state.view.stats()).header_layouts);
    state.parameters.font.size = 16;
    state.viewport = bounds;
    const long = try allocator.alloc(u8, 100000 * 12);
    defer allocator.free(long);
    for (0..100000) |line| @memcpy(long[line * 12 ..][0..12], "same line x\n");
    const before_long = try state.view.stats();
    _ = try a.replace(.{ .start = 0, .end = try a.byteLength() }, long);
    _ = try b.replace(.{ .start = 0, .end = try b.byteLength() }, long);
    try state.refresh();
    const before_scroll = try state.view.stats();
    try std.testing.expect(before_scroll.indexed_rows == 100000 and before_scroll.shaped_bytes - before_long.shaped_bytes < long.len / 100);
    try std.testing.expect(before_scroll.shaped_batches - before_long.shaped_batches <= 8);
    for (0..8) |iteration| {
        _ = try state.view.scrollBy(if (iteration % 2 == 0) 20 else -20);
        try state.view.prepare(bounds, state.parameters);
    }
    const warm_scroll = try state.view.stats();
    try std.testing.expectEqual(before_scroll.header_layouts, warm_scroll.header_layouts);
    try std.testing.expectEqual(before_scroll.header_prepared, warm_scroll.header_prepared);
    try std.testing.expectEqual(before_scroll.shaped_batches, warm_scroll.shaped_batches);
    try std.testing.expectEqual(before_scroll.header_reuses + 24, warm_scroll.header_reuses);
    try state.wheel();
    try std.testing.expect((try state.view.info()).anchor_row > 0);
    _ = try state.view.scrollBy(1000000);
    _ = try state.view.scrollBy(1000000);
    _ = try state.view.scrollBy(1000000);
    try state.view.prepare(bounds, state.parameters);
    try state.paint();
    try std.testing.expect((try state.view.info()).anchor_row > 99000);
    _ = try state.view.scrollBy(-1000000);
    _ = try state.view.scrollBy(-1000000);
    _ = try state.view.scrollBy(-1000000);
    try state.view.prepare(bounds, state.parameters);
    try std.testing.expectEqual(@as(usize, 0), (try state.view.info()).anchor_row);
    state.fail_frame = true;
    state.expected = error.InvalidGeometry;
    try state.paint();
    state.fail_frame = false;
    state.expected = null;
    try state.view.prepare(bounds, state.parameters);
    state.close_frame = true;
    try state.paint();
    try app.dispatch();
    try std.testing.expect(state.window.isClosed() and state.context.window == null);
    try std.testing.expectEqual(@as(usize, 0), app.resourceStats().allocated_records);
}
pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const before = t.resourceCounts();
    const args = try std.process.argsAlloc(debug.allocator());
    defer std.process.argsFree(debug.allocator(), args);
    if (args.len > 1) {
        if (args.len != 2) return error.InvalidSmokeSelector;
        if (std.mem.eql(u8, args[1], "projection")) {
            try @import("document_projection_commit_smoke.zig").run(debug.allocator());
        } else if (std.mem.eql(u8, args[1], "observer")) {
            try @import("document_native_observer_smoke.zig").run(debug.allocator());
        } else if (std.mem.eql(u8, args[1], "context")) {
            try @import("document_diff_context_smoke.zig").run(debug.allocator());
        } else return error.InvalidSmokeSelector;
        try std.testing.expectEqual(before, t.resourceCounts());
        if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
        return;
    }
    try run(debug.allocator());
    try @import("document_diff_editable_smoke.zig").run(debug.allocator());
    std.debug.print("diff stage: projection commit\n", .{});
    try @import("document_projection_commit_smoke.zig").run(debug.allocator());
    std.debug.print("diff stage: native observer\n", .{});
    try @import("document_native_observer_smoke.zig").run(debug.allocator());
    std.debug.print("diff stage: unified\n", .{});
    try @import("document_diff_unified_smoke.zig").run(debug.allocator());
    std.debug.print("diff stage: intraline\n", .{});
    try @import("document_diff_intraline_smoke.zig").run(debug.allocator());
    std.debug.print("diff stage: paired folds\n", .{});
    try @import("document_fold_pair_smoke.zig").run(debug.allocator());
    try @import("document_diff_context_smoke.zig").run(debug.allocator());
    try std.testing.expectEqual(before, t.resourceCounts());
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u32, 0), zlg_resource_count());
    std.debug.print("document diff native passed: aligned wrapped text/pixels, blank/empty/EOF rows, native key/pointer/wheel, bounded visible shaping/scroll, one-undo revert, IME/OOM/failed frame/close resources=0\n", .{});
}
